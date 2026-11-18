import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-418a and WP-418b. The golden matrix of STG-2: family × response × orders 1, 2, 5, 8,
/// against `scipy.signal.iirfilter`, in the analog and in the digital domain.
@Suite("IIRDesign (WP-418a, 418b)")
struct IIRDesignTests {
    private static let tolerance = 1e-9

    // MARK: Golden, analog (WP-418a)

    @Test func analogDesignsMatchTheOracleInZeroPoleForm() throws {
        for item in try DesignCase.all(analog: true) {
            let system = item.design.zeroPoleGain
            #expect(system.domain == .analog)
            let poleCount = (item.responseName == "bandpass" || item.responseName == "bandstop") ? 2 * item.order : item.order
            #expect(system.poles.count == poleCount, "\(item.golden.name)")
            expectRootsClose(system.poles, try item.golden.complexes("poles"), relative: Self.tolerance, "\(item.golden.name) poles",
                             measure: "WP-418a analog design, poles, relative")
            expectRootsClose(system.zeros, try item.golden.complexes("zeros"), relative: Self.tolerance, "\(item.golden.name) zeros",
                             measure: "WP-418a analog design, zeros, relative")
            let gain = try item.golden.scalar("gain")
            expectClose(system.gain, gain, .relative(Self.tolerance), "\(item.golden.name) gain")
            Measurements.shared.record("WP-418a analog design, gain, relative", abs(system.gain - gain) / abs(gain), bound: Self.tolerance)
            #expect(try system.isStable, "\(item.golden.name)")
        }
    }

    @Test func analogDesignsMatchTheOracleInCoefficientForm() throws {
        for item in try DesignCase.all(analog: true) {
            let coefficients = try item.design.transferFunction
            #expect(coefficients.domain == .analog)
            let system = item.design.zeroPoleGain
            expectCoefficientsClose(coefficients.denominator.coefficients, try item.golden.real("a"), roots: system.poles, leading: 1,
                                    relative: Self.tolerance, "\(item.golden.name) denominator",
                                    measure: "WP-418a analog design, coefficients, relative to each coefficient's scale")
            expectCoefficientsClose(coefficients.numerator.coefficients, try item.golden.real("b"), roots: system.zeros, leading: system.gain,
                                    relative: Self.tolerance, "\(item.golden.name) numerator",
                                    measure: "WP-418a analog design, coefficients, relative to each coefficient's scale")
        }
    }

    @Test func anAnalogDesignHasNoSections() throws {
        let analog = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain: .analog)
        #expect(thrownError { _ = try analog.secondOrderSections }?.isUnsupportedConfiguration == true)
    }

    // MARK: Golden, digital (WP-418b)

    @Test func digitalDesignsMatchTheOracleInZeroPoleForm() throws {
        for item in try DesignCase.all(analog: false) {
            let system = item.design.zeroPoleGain
            #expect(system.domain == .digital)
            #expect(system.zeros.count == system.poles.count, "\(item.golden.name): the bilinear transform leaves no zero at infinity")
            expectRootsClose(system.poles, try item.golden.complexes("poles"), relative: Self.tolerance, "\(item.golden.name) poles",
                             measure: "WP-418b digital design, poles, relative")
            expectRootsClose(system.zeros, try item.golden.complexes("zeros"), relative: Self.tolerance, "\(item.golden.name) zeros",
                             measure: "WP-418b digital design, zeros, relative")
            let gain = try item.golden.scalar("gain")
            expectClose(system.gain, gain, .relative(Self.tolerance), "\(item.golden.name) gain")
            Measurements.shared.record("WP-418b digital design, gain, relative", abs(system.gain - gain) / abs(gain), bound: Self.tolerance)
            #expect(try system.isStable, "\(item.golden.name)")
        }
    }

    @Test func digitalDesignsMatchTheOracleSectionForSection() throws {
        for item in try DesignCase.all(analog: false) {
            let sections = try item.design.secondOrderSections
            #expect(sections.domain == .digital)
            let poleCount = item.design.zeroPoleGain.poles.count
            #expect(sections.sections.count == (poleCount + 1) / 2, "\(item.golden.name)")
            try SectionPairingTests.compare(sections, item.golden,
                                            label: "WP-418b digital design, section coefficients against iirfilter(output='sos'), relative to the section's largest")
            #expect(sections.coefficients.count == 5 * sections.sections.count)
        }
    }

    @Test func digitalDesignsMatchTheOracleInCoefficientForm() throws {
        for item in try DesignCase.all(analog: false) {
            let coefficients = try item.design.transferFunction
            let system = item.design.zeroPoleGain
            expectCoefficientsClose(coefficients.denominator.coefficients, try item.golden.real("a"), roots: system.poles, leading: 1,
                                    relative: Self.tolerance, "\(item.golden.name) denominator",
                                    measure: "WP-418b digital design, coefficients, relative to each coefficient's scale")
            expectCoefficientsClose(coefficients.numerator.coefficients, try item.golden.real("b"), roots: system.zeros, leading: system.gain,
                                    relative: Self.tolerance, "\(item.golden.name) numerator",
                                    measure: "WP-418b digital design, coefficients, relative to each coefficient's scale")
        }
    }

    // MARK: What a design is, checked without the oracle

    @Test func aDigitalEdgeLandsExactlyWhereItWasAskedFor() throws {
        let sampleRate = 44_100.0
        func level(_ design: IIRDesign, at hertz: Double) throws -> Double {
            try design.zeroPoleGain.magnitudeResponse(at: [2 * .pi * hertz / sampleRate])[0]
        }
        let halfPower = 0.5.squareRoot()
        for order in [1, 2, 5, 8] {
            for cutoff in [50.0, 1_000, 10_000, 19_845] {   // 0.45·fs: the pre-warp is strongest there
                let lowPass = try IIRDesign(.butterworth, .lowPass(cutoff: cutoff), order: order, domain: .digital(sampleRate: sampleRate))
                expectClose(try level(lowPass, at: cutoff), halfPower, .relative(1e-11), "low-pass, order \(order), \(cutoff) Hz")
                expectClose(try level(lowPass, at: 0), 1, .relative(1e-11))
                let highPass = try IIRDesign(.butterworth, .highPass(cutoff: cutoff), order: order, domain: .digital(sampleRate: sampleRate))
                expectClose(try level(highPass, at: cutoff), halfPower, .relative(1e-11), "high-pass, order \(order), \(cutoff) Hz")
                expectClose(try level(highPass, at: sampleRate / 2), 1, .relative(1e-11))
            }
            let bandPass = try IIRDesign(.butterworth, .bandPass(from: 2_000, to: 5_000), order: order, domain: .digital(sampleRate: sampleRate))
            expectClose(try level(bandPass, at: 2_000), halfPower, .relative(1e-11))
            expectClose(try level(bandPass, at: 5_000), halfPower, .relative(1e-11))
            #expect(bandPass.zeroPoleGain.poles.count == 2 * order)
            let bandStop = try IIRDesign(.butterworth, .bandStop(from: 2_000, to: 5_000), order: order, domain: .digital(sampleRate: sampleRate))
            expectClose(try level(bandStop, at: 2_000), halfPower, .relative(1e-11))
            expectClose(try level(bandStop, at: 5_000), halfPower, .relative(1e-11))
            expectClose(try level(bandStop, at: 0), 1, .relative(1e-11))
        }
    }

    @Test func aSampleRateOfOnePutsTheEdgesInCyclesPerSample() throws {
        let hertz = try IIRDesign(.chebyshev1(ripple: .decibels(1)), .bandPass(from: 2_400, to: 7_200), order: 3, domain: .digital(sampleRate: 48_000))
        let normalized = try IIRDesign(.chebyshev1(ripple: .decibels(1)), .bandPass(from: 0.05, to: 0.15), order: 3, domain: .digital(sampleRate: 1))
        expectRootsClose(normalized.zeroPoleGain.poles, hertz.zeroPoleGain.poles, relative: 1e-14, "poles")
        expectClose(normalized.zeroPoleGain.gain, hertz.zeroPoleGain.gain, .relative(1e-13))
    }

    /// §7.5 row 4 (WP-418b): the designs that crowd 0 Hz and the Nyquist frequency, from the
    /// stress library. Pre-warping, the bilinear transform and the pairing all act on roots,
    /// so the poles are where the closed form puts them, to twelve digits.
    @Test func stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles() throws {
        for fixture in StressFixture.filtersNearZero + StressFixture.filtersNearNyquist {
            let response: FilterResponse = fixture.response == .lowPass ? .lowPass(cutoff: fixture.cutoff) : .highPass(cutoff: fixture.cutoff)
            let design = try IIRDesign(.butterworth, response, order: fixture.order, domain: .digital(sampleRate: fixture.sampleRate))
            let system = design.zeroPoleGain
            #expect(try system.isStable, "\(fixture.name)")
            let edge = try system.magnitudeResponse(at: [fixture.normalizedAngle])[0]
            expectClose(edge, 0.5.squareRoot(), .relative(1e-9), "\(fixture.name): −3 dB at the cutoff")
            // In zero-pole form the poles sit where the closed form puts them: an order-n
            // Butterworth low-pass has its poles on a circle in the warped plane, so every
            // analog pole p satisfies |p| = 2·tan(π·f/fs) exactly (for an internal rate of 1).
            let warped = 2 * tan(fixture.normalizedAngle / 2)
            for pole in system.poles {
                let analog = 2 * (pole - Complex.one) / (pole + Complex.one)   // the inverse bilinear map
                let radius = fixture.response == .lowPass ? analog.magnitude : warped * warped / analog.magnitude
                Measurements.shared.record("WP-418b stress fixtures: pole radius in the warped plane, relative", abs(radius - warped) / warped, bound: 1e-9)
                expectClose(radius, warped, .relative(1e-9), "\(fixture.name)")
            }
        }
    }

    @Test func aDesignIsAValue() throws {
        let design = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 4,
                                   domain: .digital(sampleRate: 48_000))
        #expect(design.order == 4)
        #expect(design.response == .bandPass(from: 2_000, to: 5_000))
        #expect(design.domain == .digital(sampleRate: 48_000))
        #expect(design.domain.system == .digital && IIRDesign.Domain.analog.system == .analog)
        #expect(design.family == AnyStrategy(EllipticFamily(ripple: .decibels(1), stopband: .decibels(60))))
        let same = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 4,
                                 domain: .digital(sampleRate: 48_000))
        #expect(same == design)
        #expect(same.hashValue == design.hashValue)
        let other = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(61)), .bandPass(from: 2_000, to: 5_000), order: 4,
                                  domain: .digital(sampleRate: 48_000))
        #expect(other != design)
        #expect(try IIRDesign(.butterworth, .lowPass(cutoff: 1), order: 2, domain: .analog) != IIRDesign(.butterworth, .highPass(cutoff: 1), order: 2, domain: .analog))
        // The responses.
        #expect(FilterResponse.lowPass(cutoff: 3).edges == [3] && !FilterResponse.highPass(cutoff: 3).isBand)
        #expect(FilterResponse.bandStop(from: 1, to: 2).edges == [1, 2] && FilterResponse.bandPass(from: 1, to: 2).isBand)
    }

    @Test func aFamilyWrittenOutsideThePackageIsDesignedTheSameWay() throws {
        /// A two-pole prototype with a notch: nothing the package ships.
        struct Notched: FilterFamily {
            let depth: Double
            func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
                guard order == 2 else { throw .invalidParameter(stage: .none, parameter: "order", reason: "only order 2") }
                return ZeroPoleGain(zeros: [Complex(0, depth), Complex(0, -depth)], poles: [Complex(-0.5, 0.8), Complex(-0.5, -0.8)],
                                    gain: 0.89 / (depth * depth), domain: .analog)
            }
        }
        let design = try IIRDesign(Notched(depth: 3), .lowPass(cutoff: 2_000), order: 2, domain: .digital(sampleRate: 48_000))
        #expect(design.family == AnyStrategy(Notched(depth: 3)))
        #expect(design.family != AnyStrategy(Notched(depth: 4)))
        #expect(try design.secondOrderSections.sections.count == 1)
        // The notch of the prototype, at 3 rad/s, lands at the frequency the pre-warp sends it to.
        let warpedEdge = try DSP.prewarpedAngularFrequency(hertz: 2_000, sampleRate: 48_000)
        let notch = 2 * atan(3 * warpedEdge / (2 * 48_000))
        #expect(try design.zeroPoleGain.magnitudeResponse(at: [notch])[0] < 1e-12)
        expectClose(try design.zeroPoleGain.magnitudeResponse(at: [0])[0], 1, .relative(1e-12))
        #expect(thrownError { _ = try IIRDesign(Notched(depth: 3), .lowPass(cutoff: 2_000), order: 3, domain: .analog) }?.invalidParameterName == "order")
        // A family that hands back something that is not an analog prototype is refused.
        struct Confused: FilterFamily {
            func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
                ZeroPoleGain(zeros: [], poles: [Complex(0.5)], gain: 1, domain: .digital)
            }
        }
        #expect(thrownError { _ = try IIRDesign(Confused(), .lowPass(cutoff: 1), order: 1, domain: .analog) }?.invalidParameterName == "system")
    }

    // MARK: Negative paths

    @Test func invalidDesignsAreTypedErrors() {
        let digital = IIRDesign.Domain.digital(sampleRate: 48_000)
        func failure(_ response: FilterResponse, order: Int = 4, domain: IIRDesign.Domain = digital) -> DSPError? {
            thrownError { _ = try IIRDesign(.butterworth, response, order: order, domain: domain) }
        }
        // Orders.
        #expect(failure(.lowPass(cutoff: 1_000), order: 0)?.invalidParameterName == "order")
        #expect(failure(.lowPass(cutoff: 1_000), order: -3)?.invalidParameterName == "order")
        #expect(failure(.lowPass(cutoff: 1_000), order: 513)?.invalidParameterName == "order")
        // Digital edges: strictly between 0 and Nyquist.
        for bad in [0.0, -100, 24_000, 30_000, .nan, .infinity] {
            #expect(failure(.lowPass(cutoff: bad))?.invalidParameterName == "cutoff", "\(bad)")
            #expect(failure(.highPass(cutoff: bad))?.invalidParameterName == "cutoff", "\(bad)")
            #expect(failure(.bandPass(from: bad, to: 5_000))?.invalidParameterName == "response", "\(bad)")
            #expect(failure(.bandStop(from: 2_000, to: bad))?.invalidParameterName == "response", "\(bad)")
        }
        // Analog edges: positive and finite.
        for bad in [0.0, -1, .nan, .infinity] {
            #expect(failure(.lowPass(cutoff: bad), domain: .analog)?.invalidParameterName == "cutoff")
            #expect(failure(.bandPass(from: 1, to: bad), domain: .analog)?.invalidParameterName == "response")
        }
        #expect(failure(.lowPass(cutoff: 30_000), domain: .analog) == nil, "an analog edge has no Nyquist limit")
        // Band edges must ascend.
        #expect(failure(.bandPass(from: 5_000, to: 2_000))?.invalidParameterName == "response")
        #expect(failure(.bandStop(from: 3_000, to: 3_000))?.invalidParameterName == "response")
        #expect(failure(.bandPass(from: 5, to: 2), domain: .analog)?.invalidParameterName == "response")
        // Sample rates.
        for bad in [0.0, -48_000, .nan, .infinity] {
            #expect(failure(.lowPass(cutoff: 1_000), domain: .digital(sampleRate: bad))?.invalidParameterName == "sampleRate")
        }
        // The family's own parameters.
        #expect(thrownError { _ = try IIRDesign(.chebyshev1(ripple: .decibels(0)), .lowPass(cutoff: 1_000), order: 4, domain: digital) }?.invalidParameterName == "ripple")
        #expect(thrownError { _ = try IIRDesign(.bessel(), .lowPass(cutoff: 1_000), order: 26, domain: digital) }?.isUnsupportedConfiguration == true)
    }
}
