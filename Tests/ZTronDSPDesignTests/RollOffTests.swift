import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-419: what a roll-off means per family (§6.3.4). Acceptance: the slope is within
/// ±0.5 dB per octave where the table says exact or bounded; the nominal cases are documented
/// (and shown to be nominal); a band-stop takes the order only.
@Suite("Roll-off semantics per family (WP-419)")
struct RollOffTests {
    private static let perOrder = RollOff.decibelsPerOctavePerOrder      // 20·log₁₀2
    private static let sampleRate = 48_000.0

    /// The all-pole families, for which a slope is a property of the response.
    private var allPole: [(name: String, family: any FilterFamily)] {
        [("Butterworth", ButterworthFamily()), ("Chebyshev I", Chebyshev1Family(ripple: .decibels(1))),
         ("Bessel, phase", BesselFamily(normalization: .phase)), ("Bessel, delay", BesselFamily(normalization: .delay)),
         ("Bessel, magnitude", BesselFamily(normalization: .magnitude))]
    }

    /// The slopes under test: 2, 4, 8 and 16 orders, the "12, 24, 48 and 96 dB per octave" of
    /// §6.3.4 to all their digits, so that a deviation is the filter's and not the rounding of
    /// the figure.
    private static let slopes = [2, 4, 8, 16].map { Double($0) * perOrder }

    private func rollOffDesign(_ family: any FilterFamily, _ response: FilterResponse, _ slope: Double, _ domain: IIRDesign.Domain,
                               rounding: RollOffRounding = .exact()) throws -> IIRDesign {
        func open(_ family: some FilterFamily) throws -> IIRDesign {
            try IIRDesign(family, response, rollOff: .decibelsPerOctave(slope), rounding: rounding, domain: domain)
        }
        return try open(family)
    }

    /// The fall of the magnitude over the octave `from … 2·from`, in decibels: positive when
    /// the response falls with frequency.
    private func fall(_ design: IIRDesign, from: Double, to: Double) throws -> Double {
        let levels = try design.zeroPoleGain.magnitudeResponse(at: [from, to], in: .decibels(floor: -2_000))
        return levels[0] - levels[1]
    }

    // MARK: The mapping

    @Test func aSlopeIsAWholeNumberOfOrders() throws {
        for (slope, order) in [(12.0, 2), (24.0, 4), (48.0, 8), (96.0, 16), (6.0206, 1)] {
            #expect(try rollOffDesign(ButterworthFamily(), .lowPass(cutoff: 1_000), slope, .digital(sampleRate: Self.sampleRate)).order == order)
        }
        // 25 dB per octave is not a whole number of orders: an error by default, order 5 rounded up, 4 to the nearest.
        let error = thrownError { _ = try rollOffDesign(ButterworthFamily(), .lowPass(cutoff: 1_000), 25, .analog) }
        #expect(error?.invalidParameterName == "rollOff")
        #expect(try rollOffDesign(ButterworthFamily(), .lowPass(cutoff: 1_000), 25, .analog, rounding: .up).order == 5)
        #expect(try rollOffDesign(ButterworthFamily(), .lowPass(cutoff: 1_000), 25, .analog, rounding: .nearest).order == 4)
        // The other units of a roll-off.
        #expect(try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), rollOff: .decibelsPerDecade(60), domain: .analog).order == 3)
        #expect(try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), rollOff: .order(7), domain: .analog).order == 7)
        #expect(thrownError { _ = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), rollOff: .decibelsPerOctave(-12), domain: .analog) }?.invalidParameterName == "rollOff")
        #expect(thrownError { _ = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), rollOff: .decibelsPerOctave(1), domain: .analog) }?.invalidParameterName == "rollOff")
        // A design by roll-off is the design by the order it names.
        #expect(try rollOffDesign(Chebyshev1Family(ripple: .decibels(1)), .highPass(cutoff: 300), 24, .digital(sampleRate: Self.sampleRate))
                    == IIRDesign(.chebyshev1(ripple: .decibels(1)), .highPass(cutoff: 300), order: 4, domain: .digital(sampleRate: Self.sampleRate)))
    }

    // MARK: Exact: the analog prototype of an all-pole family

    @Test func theAnalogSkirtOfAnAllPoleFamilyHasExactlyTheSlope() throws {
        for (name, family) in allPole {
            for slope in Self.slopes {
                let lowPass = try rollOffDesign(family, .lowPass(cutoff: 1), slope, .analog)
                // The asymptote, ten octaves into the stop band.
                let measured = try fall(lowPass, from: 1_024, to: 2_048)
                expectClose(measured, slope, .absolute(0.5), "\(name), \(slope) dB per octave, analog low-pass")
                Measurements.shared.record("WP-419 analog low-pass skirt, deviation from the slope, dB per octave", abs(measured - slope), bound: 0.5)
                // A high-pass falls towards 0 rad/s by the same slope.
                let highPass = try rollOffDesign(family, .highPass(cutoff: 1), slope, .analog)
                let towardsZero = -(try fall(highPass, from: 1.0 / 2_048, to: 1.0 / 1_024))
                expectClose(towardsZero, slope, .absolute(0.5), "\(name), \(slope) dB per octave, analog high-pass")
                Measurements.shared.record("WP-419 analog high-pass skirt, deviation from the slope, dB per octave", abs(towardsZero - slope), bound: 0.5)
            }
        }
    }

    // MARK: Exact: a digital high-pass, towards 0 Hz

    @Test func aDigitalHighPassFallsTowardsZeroHertzByExactlyTheSlope() throws {
        for (name, family) in allPole {
            for slope in Self.slopes {
                let design = try rollOffDesign(family, .highPass(cutoff: 4_000), slope, .digital(sampleRate: Self.sampleRate))
                let angle = 2 * Double.pi * 4_000 / Self.sampleRate
                let measured = -(try fall(design, from: angle / 2_048, to: angle / 1_024))
                expectClose(measured, slope, .absolute(0.5), "\(name), \(slope) dB per octave")
                Measurements.shared.record("WP-419 digital high-pass towards 0 Hz, deviation from the slope, dB per octave", abs(measured - slope), bound: 0.5)
            }
        }
    }

    // MARK: Bounded: a digital low-pass, well below Nyquist

    @Test func aDigitalLowPassHasTheSlopeInOctavesThatEndBelowAThirtySecondOfTheSampleRate() throws {
        // A cutoff of 5 Hz at 48 kHz: the octave 640 … 1 280 Hz ends below fs/32 = 1 500 Hz and
        // lies seven octaves into the stop band, where the prototype's own skirt is straight.
        // What is left is the bilinear transform: 0.021 dB per octave and order at fs/32.
        let cutoff = 5.0
        for (name, family) in allPole {
            for slope in Self.slopes {
                let design = try rollOffDesign(family, .lowPass(cutoff: cutoff), slope, .digital(sampleRate: Self.sampleRate))
                let from = 2 * Double.pi * 640 / Self.sampleRate
                let measured = try fall(design, from: from, to: 2 * from)
                #expect(2 * 640 <= Self.sampleRate / 32)
                expectClose(measured, slope, .absolute(0.5), "\(name), \(slope) dB per octave")
                #expect(measured >= slope, "\(name): the transform can only steepen the skirt")
                Measurements.shared.record("WP-419 digital low-pass below fs/32, deviation from the slope, dB per octave", abs(measured - slope), bound: 0.5)
            }
        }
    }

    @Test func aDigitalLowPassSteepensTowardsNyquist() throws {
        // The bilinear transform puts n zeros at the Nyquist frequency: in the octave
        // fs/8 … fs/4 the skirt falls by 20·log₁₀(tan(π/4)/tan(π/8)) = 7.66 dB per order.
        for slope in Self.slopes {
            let design = try rollOffDesign(ButterworthFamily(), .lowPass(cutoff: 40), slope, .digital(sampleRate: Self.sampleRate))
            let from = 2 * Double.pi / 8
            let measured = try fall(design, from: from, to: 2 * from)
            let expected = Double(design.order) * 20 * log10(tan(Double.pi / 4) / tan(Double.pi / 8))
            expectClose(measured, expected, .absolute(0.01), "\(slope) dB per octave")
            #expect(measured > slope + 0.5, "steeper than the nominal slope: \(measured) dB")
        }
    }

    // MARK: Band-pass: each skirt; the filter has twice the order

    @Test func aBandPassHasTheSlopeOnEachSkirtAndTwiceTheOrder() throws {
        for (name, family) in allPole {
            for slope in Self.slopes.prefix(3) {
                let order = Int((slope / Self.perOrder).rounded())
                // Analog: both skirts are exact.
                let analog = try rollOffDesign(family, .bandPass(from: 0.8, to: 1.25), slope, .analog)
                #expect(analog.order == order && analog.zeroPoleGain.poles.count == 2 * order, "\(name)")
                let upper = try fall(analog, from: 2_048, to: 4_096)
                let lower = -(try fall(analog, from: 1.0 / 4_096, to: 1.0 / 2_048))
                expectClose(upper, slope, .absolute(0.5), "\(name), upper skirt")
                expectClose(lower, slope, .absolute(0.5), "\(name), lower skirt")
                Measurements.shared.record("WP-419 analog band-pass skirts, deviation from the slope, dB per octave", max(abs(upper - slope), abs(lower - slope)), bound: 0.5)

                // Digital: the lower skirt towards 0 Hz is exact, the upper one well below Nyquist.
                let digital = try rollOffDesign(family, .bandPass(from: 4, to: 6), slope, .digital(sampleRate: Self.sampleRate))
                #expect(digital.zeroPoleGain.poles.count == 2 * order)
                let towardsZero = 2 * Double.pi * 4 / Self.sampleRate / 4_096
                let digitalLower = -(try fall(digital, from: towardsZero, to: 2 * towardsZero))
                let above = 2 * Double.pi * 640 / Self.sampleRate
                let digitalUpper = try fall(digital, from: above, to: 2 * above)
                expectClose(digitalLower, slope, .absolute(0.5), "\(name), digital lower skirt")
                expectClose(digitalUpper, slope, .absolute(0.5), "\(name), digital upper skirt")
                Measurements.shared.record("WP-419 digital band-pass skirts, deviation from the slope, dB per octave", max(abs(digitalUpper - slope), abs(digitalLower - slope)), bound: 0.5)
            }
        }
    }

    // MARK: Band-stop: the order only

    @Test func aBandStopTakesTheOrderOnly() throws {
        for (name, family) in allPole {
            let design = try rollOffDesign(family, .bandStop(from: 1_000, to: 2_000), 24, .digital(sampleRate: Self.sampleRate))
            #expect(design.order == 4 && design.zeroPoleGain.poles.count == 8, "\(name)")
            #expect(design == (try ZTronDSPDesignTests.design(family, .bandStop(from: 1_000, to: 2_000), order: 4, domain: .digital(sampleRate: Self.sampleRate))))
            // A notch has no skirt to measure: the gain falls without bound at the centre and
            // returns to the prototype's own DC gain on both sides.
            let passGain = try family.prototype(order: 4).magnitudeResponse(at: [0])[0]
            let centre = 2 * atan((tan(.pi * 1_000 / Self.sampleRate) * tan(.pi * 2_000 / Self.sampleRate)).squareRoot())
            let levels = try design.zeroPoleGain.magnitudeResponse(at: [1e-6, centre, .pi - 1e-6])
            expectClose(levels[0], passGain, .relative(1e-6), "\(name), at 0 Hz")
            #expect(levels[1] < 1e-12, "\(name), at the centre: \(levels[1])")
            expectClose(levels[2], passGain, .relative(1e-6), "\(name), at Nyquist")
        }
    }

    // MARK: Nominal: Chebyshev II and elliptic

    @Test func forChebyshevTwoAndEllipticTheSlopeOnlyNamesTheOrder() throws {
        let families: [(String, any FilterFamily, Double)] = [
            ("Chebyshev II", Chebyshev2Family(stopband: .decibels(60)), 60),
            ("elliptic", EllipticFamily(ripple: .decibels(1), stopband: .decibels(60)), 60),
        ]
        for (name, family, attenuation) in families {
            // The mapping is the all-pole one: 24 dB per octave is order 4, and nothing else.
            let design = try rollOffDesign(family, .lowPass(cutoff: 1), 24, .analog)
            #expect(design.order == 4, "\(name)")
            #expect(design == (try ZTronDSPDesignTests.design(family, .lowPass(cutoff: 1), order: 4, domain: .analog)))

            // And it is nominal. The stop band is bounded by the attenuation, not by a slope: an
            // even order levels off there, where an all-pole filter of the same order would be
            // 24 dB lower with every octave.
            let far = try fall(design, from: 1_024, to: 2_048)
            #expect(abs(far) < 0.01, "\(name): the stop band is flat far out, \(far) dB per octave, not 24")
            let floor = try design.zeroPoleGain.magnitudeResponse(at: [2_048], in: .decibels(floor: -400))[0]
            expectClose(floor, -attenuation, .absolute(0.01), "\(name): the stop band sits at the stated attenuation")
            // The real transition is steeper than the nominal slope: the response reaches the
            // stop band within the first octave beyond the edge.
            let firstOctave = try design.zeroPoleGain.magnitudeResponse(at: [2], in: .decibels(floor: -400))[0]
            let nominal = try IIRDesign(.butterworth, .lowPass(cutoff: 1), order: 4, domain: .analog).zeroPoleGain
                .magnitudeResponse(at: [2], in: .decibels(floor: -400))[0]
            #expect(firstOctave < nominal - 10, "\(name): \(firstOctave) dB one octave out, against \(nominal) dB for the all-pole filter")
            // An odd order keeps one zero at infinity: 6 dB per octave in the end, whatever the order.
            let odd = try rollOffDesign(family, .lowPass(cutoff: 1), 30.103, .analog)
            #expect(odd.order == 5)
            expectClose(try fall(odd, from: 1_048_576, to: 2_097_152), Self.perOrder, .absolute(0.01), "\(name), order 5")
        }
    }
}
