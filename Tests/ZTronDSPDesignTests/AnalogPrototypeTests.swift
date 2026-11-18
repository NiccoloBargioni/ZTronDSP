import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// The golden grid of STG-2 for WP-405…411: orders 1…12 (Butterworth to 20, Bessel to 25),
/// ripple 0.1, 1, 3 dB, attenuation 40, 60, 80 dB. Poles, zeros and gain within 1e-9
/// relative. Poles and zeros are matched as sets (see `expectRootsClose`).
@Suite("Analog prototypes (WP-405, 406, 407, 409, 411)")
struct AnalogPrototypeTests {
    private static let tolerance = 1e-9

    private func compare(_ prototype: ZeroPoleGain, _ golden: GoldenCase, _ package: String) throws {
        #expect(prototype.domain == .analog)
        expectRootsClose(prototype.poles, try golden.complexes("poles"), relative: Self.tolerance, "\(golden.name) poles",
                         measure: "\(package) poles, relative")
        expectRootsClose(prototype.zeros, try golden.complexes("zeros"), relative: Self.tolerance, "\(golden.name) zeros",
                         measure: "\(package) zeros, relative")
        let gain = try golden.scalar("gain")
        expectClose(prototype.gain, gain, .relative(Self.tolerance), "\(golden.name) gain")
        Measurements.shared.record("\(package) gain, relative", abs(prototype.gain - gain) / abs(gain), bound: Self.tolerance)
    }

    private func cases(_ family: String) throws -> [GoldenCase] {
        let file = try Golden.prototypes.get()
        let selected = try file.cases.filter { try $0.string("family") == family }
        try #require(!selected.isEmpty)
        return selected
    }

    // MARK: Golden

    @Test func butterworthMatchesTheOracleForOrdersOneToTwenty() throws {
        let golden = try cases("butterworth")
        #expect(golden.count == 20)
        for golden in golden {
            try compare(try AnalogPrototype.butterworth(order: try golden.integer("order")), golden, "WP-405 Butterworth")
        }
    }

    @Test func chebyshev1MatchesTheOracleOverTheGrid() throws {
        let golden = try cases("chebyshev1")
        #expect(golden.count == 12 * 3)
        for golden in golden {
            let prototype = try AnalogPrototype.chebyshev1(order: try golden.integer("order"), ripple: .decibels(try golden.number("ripple")))
            try compare(prototype, golden, "WP-406 Chebyshev I")
        }
    }

    @Test func chebyshev2MatchesTheOracleOverTheGrid() throws {
        let golden = try cases("chebyshev2")
        #expect(golden.count == 12 * 3)
        for golden in golden {
            let prototype = try AnalogPrototype.chebyshev2(order: try golden.integer("order"), stopband: .decibels(try golden.number("stopband")))
            try compare(prototype, golden, "WP-407 Chebyshev II")
        }
    }

    @Test func ellipticMatchesTheOracleOverTheGrid() throws {
        let golden = try cases("elliptic")
        #expect(golden.count == 12 * 3 * 3)
        for golden in golden {
            let prototype = try AnalogPrototype.elliptic(
                order: try golden.integer("order"), ripple: .decibels(try golden.number("ripple")),
                stopband: .decibels(try golden.number("stopband")))
            try compare(prototype, golden, "WP-409 elliptic")
        }
    }

    @Test func besselMatchesTheOracleForOrdersOneToTwentyFiveInThreeNormalisations() throws {
        let golden = try cases("bessel")
        #expect(golden.count == 25 * 3)
        for golden in golden {
            let normalization: BesselNormalization
            switch try golden.string("normalization") {
            case "phase": normalization = .phase
            case "delay": normalization = .delay
            default: normalization = .magnitude
            }
            try compare(try AnalogPrototype.bessel(order: try golden.integer("order"), normalization: normalization), golden,
                        "WP-411 Bessel")
        }
    }

    // MARK: What each prototype is, checked without the oracle

    private func gain(_ prototype: ZeroPoleGain, at frequency: Double) throws -> Double {
        try prototype.magnitudeResponse(at: [frequency])[0]
    }

    @Test func butterworthIsThreeDecibelsDownAtOneRadianPerSecondAndStable() throws {
        for order in [1, 2, 3, 7, 20, 64] {
            let prototype = try AnalogPrototype.butterworth(order: order)
            #expect(prototype.poles.count == order && prototype.zeros.isEmpty && prototype.gain == 1)
            #expect(prototype.poles.allSatisfy { abs($0.magnitude - 1) < 1e-15 && $0.real < 0 })
            expectClose(try gain(prototype, at: 1), 0.5.squareRoot(), .relative(1e-13))
            expectClose(try gain(prototype, at: 0), 1, .relative(1e-13))
            #expect(try prototype.isStable)
            if order % 2 == 1 { #expect(prototype.poles.contains(Complex(-1, 0)), "an odd order has an exactly real pole") }
        }
    }

    @Test func chebyshev1RipplesBetweenUnityAndTheRippleAndLeavesItAtTheEdge() throws {
        for (order, ripple) in [(1, 1.0), (4, 0.1), (5, 1.0), (8, 3.0)] {
            let prototype = try AnalogPrototype.chebyshev1(order: order, ripple: .decibels(ripple))
            let floor = pow(10, -ripple / 20)
            expectClose(try gain(prototype, at: 1), floor, .relative(1e-12), "gain at the edge")
            // An even order starts at the bottom of the ripple, an odd one at the top.
            expectClose(try gain(prototype, at: 0), order % 2 == 0 ? floor : 1, .relative(1e-12), "gain at DC")
            let band = try prototype.magnitudeResponse(at: (0 ... 400).map { Double($0) / 400 })
            #expect(band.allSatisfy { $0 <= 1 + 1e-12 && $0 >= floor - 1e-12 })
            #expect(try prototype.isStable)
        }
    }

    @Test func chebyshev2ReachesItsAttenuationAtTheEdgeAndNeverRisesAboveIt() throws {
        for (order, attenuation) in [(1, 40.0), (4, 60.0), (5, 40.0), (8, 80.0)] {
            let prototype = try AnalogPrototype.chebyshev2(order: order, stopband: .decibels(attenuation))
            let ceiling = pow(10, -attenuation / 20)
            expectClose(try gain(prototype, at: 1), ceiling, .relative(1e-9), "gain at the edge")
            expectClose(try gain(prototype, at: 0), 1, .relative(1e-12), "gain at DC")
            let band = try prototype.magnitudeResponse(at: (0 ... 400).map { 1 + Double($0) / 20 })
            #expect(band.allSatisfy { $0 <= ceiling * (1 + 1e-9) })
            // Finite zeros on the imaginary axis: an even order has n of them, an odd one n − 1.
            #expect(prototype.zeros.count == order - order % 2)
            #expect(prototype.zeros.allSatisfy { $0.real == 0 && abs($0.imaginary) >= 1 })
            #expect(try prototype.isStable)
        }
    }

    @Test func ellipticIsEquirippleInBothBands() throws {
        for (order, ripple, attenuation) in [(1, 1.0, 40.0), (2, 1.0, 40.0), (5, 0.1, 60.0), (8, 3.0, 80.0), (20, 1.0, 60.0)] {
            let prototype = try AnalogPrototype.elliptic(order: order, ripple: .decibels(ripple), stopband: .decibels(attenuation))
            let floor = pow(10, -ripple / 20)
            let ceiling = pow(10, -attenuation / 20)
            expectClose(try gain(prototype, at: 1), floor, .relative(1e-9), "order \(order): gain at the edge")
            expectClose(try gain(prototype, at: 0), order % 2 == 0 ? floor : 1, .relative(1e-11), "order \(order): gain at DC")
            let passband = try prototype.magnitudeResponse(at: (0 ... 400).map { Double($0) / 400 })
            #expect(passband.allSatisfy { $0 <= 1 + 1e-9 && $0 >= floor * (1 - 1e-9) }, "order \(order)")
            if order > 1 {
                // The stop band begins at the first frequency that reaches the attenuation, 1/k.
                let edge = try #require(prototype.zeros.map { abs($0.imaginary) }.min()) // the first zero lies just beyond it
                let stopband = try prototype.magnitudeResponse(at: (0 ... 400).map { edge * (1 + Double($0) / 10) })
                #expect(stopband.allSatisfy { $0 <= ceiling * (1 + 1e-6) }, "order \(order)")
                #expect(prototype.zeros.count == order - order % 2)
                #expect(prototype.zeros.allSatisfy { $0.real == 0 })
            }
            #expect(try prototype.isStable)
        }
    }

    @Test func besselNormalisationsAreWhatTheyClaim() throws {
        for order in [1, 2, 5, 12, 25] {
            // Delay: a group delay of one second at 0 rad/s, and a DC gain of 1.
            let delay = try AnalogPrototype.bessel(order: order, normalization: .delay)
            expectClose(try #require(try delay.groupDelay(at: [0])[0]), 1, .relative(1e-12), "order \(order)")
            expectClose(try gain(delay, at: 0), 1, .relative(1e-12))
            // Magnitude: −3 dB at 1 rad/s.
            let magnitude = try AnalogPrototype.bessel(order: order, normalization: .magnitude)
            expectClose(try gain(magnitude, at: 1), 0.5.squareRoot(), .relative(1e-12), "order \(order)")
            expectClose(try gain(magnitude, at: 0), 1, .relative(1e-12))
            // Phase: gain 1, and the poles multiply to 1, which gives Butterworth asymptotes.
            let phase = try AnalogPrototype.bessel(order: order, normalization: .phase)
            #expect(phase.gain == 1)
            var product = Complex.one
            for pole in phase.poles { product = product * (-pole) }
            expectClose(product.real, 1, .relative(1e-12))
            for prototype in [delay, magnitude, phase] {
                #expect(prototype.zeros.isEmpty && prototype.poles.count == order)
                #expect(try prototype.isStable)
            }
        }
        // The default is the phase normalisation.
        #expect(try AnalogPrototype.bessel(order: 3) == AnalogPrototype.bessel(order: 3, normalization: .phase))
    }

    @Test func rootsAreExactlyConjugateSymmetric() throws {
        let prototypes = [
            try AnalogPrototype.butterworth(order: 9), try AnalogPrototype.chebyshev1(order: 8, ripple: .decibels(1)),
            try AnalogPrototype.chebyshev2(order: 9, stopband: .decibels(60)),
            try AnalogPrototype.elliptic(order: 9, ripple: .decibels(1), stopband: .decibels(60)),
            try AnalogPrototype.bessel(order: 9),
        ]
        for prototype in prototypes {
            for root in prototype.poles + prototype.zeros where root.imaginary != 0 {
                #expect((prototype.poles + prototype.zeros).contains(root.conjugate))
            }
        }
    }

    // MARK: Stability (NUMS-2, §7.5 row 4)

    /// WP-405. A Butterworth prototype is written down pole by pole. The alternative, the
    /// roots of the Butterworth polynomial, is what a general design would do; at order 20 the
    /// roots of that polynomial have condition numbers of 3·10⁸, and coming back through the
    /// coefficients they miss the golden tolerance.
    @Test func stressButterworthPolesAreClosedFormNotRootsOfAPolynomial() throws {
        for order in [20, 511, 512] {
            let prototype = try AnalogPrototype.butterworth(order: order)
            // On the unit circle to the last place, in exact conjugate pairs, the real one exact.
            for pole in prototype.poles {
                #expect(abs(pole.magnitude - 1) <= 2 * Double.ulpOfOne, "order \(order)")
                #expect(prototype.poles.contains(pole.conjugate))
            }
            if order % 2 == 1 { #expect(prototype.poles[order / 2] == Complex(-1, 0)) }
            expectClose(try gain(prototype, at: 1), 0.5.squareRoot(), .relative(1e-12), "order \(order): −3 dB at the edge")
            expectClose(try gain(prototype, at: 0), 1, .relative(1e-12), "order \(order): unity at DC")
        }
        // The hazard, measured: the same twenty poles through the expanded denominator.
        let prototype = try AnalogPrototype.butterworth(order: 20)
        let expanded = try prototype.transferFunction()
        let recovered = RootMatching.bottleneck(try expanded.poles, prototype.poles)
        Measurements.shared.record("WP-405 stress: Butterworth order 20 poles through the expanded polynomial, relative (hazard)", recovered, bound: Self.tolerance)
        #expect(recovered > Self.tolerance, "through coefficients the poles are off by \(recovered)")
        #expect(try #require(try expanded.poleConditions.max()) > 1e8)
    }

    /// WP-406 and WP-407. The ripple factor ε² = 10^(dB/10) − 1 is formed through `expm1`.
    /// Written as a power minus one it loses, for a ripple of 10⁻⁹ dB, nine of its sixteen
    /// digits. ε is read back here from the poles: sinh(n·asinh(−Re p / cos θ)) = 1/ε.
    @Test func stressASmallRippleKeepsItsDigits() throws {
        let order = 5
        for ripple in [1e-9, 1e-6, 1e-3, 0.1] {
            let expected = expm1(M_LN10 * ripple / 10).squareRoot()
            let first = try AnalogPrototype.chebyshev1(order: order, ripple: .decibels(ripple))
            // The middle pole is real: θ = 0, and it sits at −sinh(μ).
            let mu = asinh(-first.poles[order / 2].real)
            let recovered = 1 / sinh(Double(order) * mu)
            expectClose(recovered, expected, .relative(1e-12), "Chebyshev I, ripple \(ripple) dB")
            Measurements.shared.record("WP-406 stress: ε read back from the poles, relative", abs(recovered - expected) / expected, bound: 1e-12)

            // Chebyshev II with the same number as its attenuation: the real pole is −1/sinh(μ),
            // with sinh(n·μ) = 1/δ = √(10^(dB/10) − 1), the same number.
            let second = try AnalogPrototype.chebyshev2(order: order, stopband: .decibels(ripple))
            let muSecond = asinh(-1 / second.poles[order / 2].real)
            let recoveredSecond = sinh(Double(order) * muSecond)
            expectClose(recoveredSecond, expected, .relative(1e-12), "Chebyshev II, attenuation \(ripple) dB")
            Measurements.shared.record("WP-407 stress: δ read back from the poles, relative", abs(recoveredSecond - expected) / expected, bound: 1e-12)
        }
    }

    /// WP-406 and WP-407 at the cap. The gain of a Chebyshev I prototype is 2^(1−n)/ε: at
    /// order 512 that is 3·10⁻¹⁵⁴, and it is the cap on the order that keeps it (and the
    /// products behind a Chebyshev II gain) inside the range of a double.
    @Test func stressTheHighestOrderIsStillRepresentable() throws {
        let first = try AnalogPrototype.chebyshev1(order: 512, ripple: .decibels(1))
        let epsilon = expm1(M_LN10 * 0.1).squareRoot()
        expectClose(first.gain, pow(2, -511) / epsilon, .relative(1e-11))
        #expect(first.gain > 0 && first.gain.isNormal)
        expectClose(try gain(first, at: 0), pow(10, -1.0 / 20), .relative(1e-10), "an even order starts at the bottom of the ripple")
        expectClose(try gain(first, at: 1), pow(10, -1.0 / 20), .relative(1e-9))
        #expect(try first.isStable)

        let second = try AnalogPrototype.chebyshev2(order: 512, stopband: .decibels(60))
        #expect(second.gain > 0 && second.gain.isNormal)
        expectClose(try gain(second, at: 0), 1, .relative(1e-10))
        expectClose(try gain(second, at: 1), 1e-3, .relative(1e-8))
        #expect(second.zeros.count == 512 && second.zeros.allSatisfy { $0.real == 0 })
        #expect(try second.isStable)
    }

    /// WP-409. At a high order the selectivity k approaches 1 and what matters is 1 − k²,
    /// which the degree equation delivers through the complementary nome instead of by
    /// subtraction. Order 50 at 1 dB / 60 dB has 1 − k² = 2·10⁻¹¹: the subtraction would keep
    /// five digits of it. The prototype is still equiripple to nine.
    @Test func stressAHighOrderEllipticPrototypeStaysEquiripple() throws {
        let floor = pow(10, -1.0 / 20)
        let ceiling = 1e-3
        for order in [30, 50, 60] {
            let prototype = try AnalogPrototype.elliptic(order: order, ripple: .decibels(1), stopband: .decibels(60))
            #expect(prototype.poles.count == order && prototype.zeros.count == order)
            let count = 20_000
            let passband = try prototype.magnitudeResponse(at: (0 ... count).map { Double($0) / Double(count) * 0.999 })
            let highest = try #require(passband.max())
            let lowest = try #require(passband.min())
            #expect(highest <= 1 + 1e-9, "order \(order): the pass band rises to \(highest)")
            #expect(lowest >= floor * (1 - 1e-9), "order \(order): the pass band falls to \(lowest)")
            // The ripple is really used: the response touches both bounds.
            #expect(highest > 1 - 1e-6 && lowest < floor * (1 + 1e-6))
            let firstZero = try #require(prototype.zeros.map { abs($0.imaginary) }.min())
            let stopband = try prototype.magnitudeResponse(at: (0 ... count).map { firstZero * (1 + 3 * Double($0) / Double(count)) })
            let loudest = try #require(stopband.max())
            #expect(loudest <= ceiling * (1 + 1e-9), "order \(order): the stop band rises to \(loudest)")
            #expect(loudest > ceiling * (1 - 1e-3))
            Measurements.shared.record("WP-409 stress: elliptic order \(order), excess over the ripple bounds, relative",
                                       max(highest - 1, 1 - lowest / floor, loudest / ceiling - 1), bound: 1e-9)
            #expect(try prototype.isStable)
        }
    }

    @Test func anEllipticOrderBeyondWhatADoubleResolvesIsRejected() {
        // At 1 dB / 60 dB the stop band of order 64 would begin 3·10⁻¹⁵ above the pass band.
        #expect(throws: Never.self) { _ = try AnalogPrototype.elliptic(order: 60, ripple: .decibels(1), stopband: .decibels(60)) }
        for order in [64, 100, 512] {
            let error = thrownError { _ = try AnalogPrototype.elliptic(order: order, ripple: .decibels(1), stopband: .decibels(60)) }
            #expect(error?.invalidParameterName == "order", "order \(order)")
            #expect(error?.description.contains("double precision") == true)
        }
        // A gentler pair of tolerances leaves room for a higher order.
        #expect(throws: Never.self) { _ = try AnalogPrototype.elliptic(order: 100, ripple: .decibels(0.01), stopband: .decibels(120)) }
    }

    /// WP-411. The Bessel prototype of order 25 against its definitions. Its poles have
    /// condition numbers of 8·10¹²: found through a polynomial in double precision they
    /// would be good to four digits, and so would everything measured below.
    @Test func stressBesselOrderTwentyFiveMeetsItsDefinitions() throws {
        let delay = try AnalogPrototype.bessel(order: 25, normalization: .delay)
        // A maximally flat delay: one second, and flat to the 25th order around 0 rad/s.
        let delays = try delay.groupDelay(at: [0, 1, 4, 8])
        for value in delays { expectClose(try #require(value), 1, .relative(1e-9)) }
        let magnitude = try AnalogPrototype.bessel(order: 25, normalization: .magnitude)
        expectClose(try gain(magnitude, at: 1), 0.5.squareRoot(), .relative(1e-12))
        // The hazard, measured: the same poles through their polynomial.
        let recovered = RootMatching.bottleneck(try delay.transferFunction().poles, delay.poles)
        Measurements.shared.record("WP-411 stress: Bessel order 25 poles through the expanded polynomial, relative (hazard)", recovered, bound: Self.tolerance)
        #expect(recovered > 1e-6, "through coefficients the poles are off by \(recovered)")
    }

    // MARK: Units of the ripple and the attenuation

    @Test func aRippleIsANumberOfDecibelsWhateverItsSignOrUnit() throws {
        let reference = try AnalogPrototype.chebyshev1(order: 4, ripple: .decibels(1))
        #expect(try AnalogPrototype.chebyshev1(order: 4, ripple: .decibels(-1)) == reference)
        let linear = try AnalogPrototype.chebyshev1(order: 4, ripple: .linear(pow(10, -1.0 / 20)))
        expectRootsClose(linear.poles, reference.poles, relative: 1e-12, "a ripple given as a factor")
        let attenuation = try AnalogPrototype.chebyshev2(order: 4, stopband: .linear(0.001))
        expectRootsClose(attenuation.poles, try AnalogPrototype.chebyshev2(order: 4, stopband: .decibels(60)).poles, relative: 1e-12, "an attenuation given as a factor")
    }

    // MARK: Negative paths

    @Test func invalidOrdersAreTypedErrors() {
        for order in [0, -1, 513, Int.min] {
            #expect(thrownError { _ = try AnalogPrototype.butterworth(order: order) }?.invalidParameterName == "order")
            #expect(thrownError { _ = try AnalogPrototype.chebyshev1(order: order, ripple: .decibels(1)) }?.invalidParameterName == "order")
            #expect(thrownError { _ = try AnalogPrototype.chebyshev2(order: order, stopband: .decibels(40)) }?.invalidParameterName == "order")
            #expect(thrownError { _ = try AnalogPrototype.elliptic(order: order, ripple: .decibels(1), stopband: .decibels(40)) }?.invalidParameterName == "order")
        }
        #expect(thrownError { _ = try AnalogPrototype.bessel(order: 0) }?.invalidParameterName == "order")
        #expect(thrownError { _ = try AnalogPrototype.bessel(order: -4) }?.invalidParameterName == "order")
        // Bessel is computed up to order 25.
        #expect(thrownError { _ = try AnalogPrototype.bessel(order: 26) }?.isUnsupportedConfiguration == true)
        #expect(AnalogPrototype.maximumOrder == 512)
        #expect(throws: Never.self) { _ = try AnalogPrototype.butterworth(order: 512) }
    }

    @Test func invalidRipplesAndAttenuationsAreTypedErrors() {
        for bad in [Amplification.decibels(0), .decibels(.nan), .decibels(.infinity), .linear(1), .decibels(1_001), .linear(0)] {
            #expect(thrownError { _ = try AnalogPrototype.chebyshev1(order: 3, ripple: bad) }?.invalidParameterName == "ripple", "\(bad)")
            #expect(thrownError { _ = try AnalogPrototype.chebyshev2(order: 3, stopband: bad) }?.invalidParameterName == "stopband", "\(bad)")
            #expect(thrownError { _ = try AnalogPrototype.elliptic(order: 3, ripple: bad, stopband: .decibels(40)) }?.invalidParameterName == "ripple", "\(bad)")
            #expect(thrownError { _ = try AnalogPrototype.elliptic(order: 3, ripple: .decibels(1), stopband: bad) }?.invalidParameterName == "stopband", "\(bad)")
        }
        // The stop band of an elliptic filter must lie below its pass-band ripple.
        #expect(thrownError { _ = try AnalogPrototype.elliptic(order: 3, ripple: .decibels(3), stopband: .decibels(3)) }?.invalidParameterName == "stopband")
        #expect(thrownError { _ = try AnalogPrototype.elliptic(order: 3, ripple: .decibels(3), stopband: .decibels(1)) }?.invalidParameterName == "stopband")
        // Values at which the prototype leaves the range of a double.
        #expect(thrownError { _ = try AnalogPrototype.chebyshev2(order: 400, stopband: .decibels(1_000)) } != nil
                    || (try? AnalogPrototype.chebyshev2(order: 400, stopband: .decibels(1_000)).isFinite) == true)
    }
}
