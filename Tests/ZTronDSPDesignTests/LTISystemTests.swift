import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-428a: zeros, poles and gain of the three representations, for digital and analog
/// systems, with the stability and minimum-phase criteria read from them. Acceptance:
/// fixtures including a pole on the unit circle and an analog system.
@Suite("LTISystem: zeros, poles, gain, stability (WP-428a)")
struct LTISystemRootsTests {
    // MARK: Zeros, poles and gain

    @Test func aDesignReportsTheSameRootsFromEveryForm() throws {
        for item in try DesignCase.all(analog: false) where item.order <= 5 {
            let system = item.design.zeroPoleGain
            // Zero-pole-gain form: what was stored.
            let generic: any LTISystem = system
            #expect(try generic.zeros == system.zeros && generic.poles == system.poles && generic.gain == system.gain)

            // Sections: closed form per section, no root finder. (The pairing of an odd order
            // adds a zero and a pole at the origin, which cancel again on reading.)
            let sections = try item.design.secondOrderSections
            expectRootsClose(sections.poles, system.poles, relative: 1e-12, "\(item.golden.name): poles from sections",
                             measure: "WP-428a poles read from sections, relative")
            // A double zero at ±1 read from b = [1, ±2, 1] is exact; a quadruple one is not a
            // property of the reading but of the pairing, which keeps them in pairs.
            expectRootsClose(sections.zeros, system.zeros, relative: 1e-12, "\(item.golden.name): zeros from sections",
                             measure: "WP-428a zeros read from sections, relative")
            expectClose(sections.gain, system.gain, .relative(1e-13), "\(item.golden.name): gain from sections")
        }
    }

    @Test func coefficientsGiveTheirRootsThroughTheRootFinder() throws {
        // Orders 1 and 2: well-conditioned, so the finder returns the design's poles.
        for analog in [true, false] {
            for item in try DesignCase.all(analog: analog) where item.order <= 2 {
                let system = item.design.zeroPoleGain
                let coefficients = try item.design.transferFunction
                expectRootsClose(try coefficients.poles, system.poles, relative: 1e-9, "\(item.golden.name): poles from coefficients",
                                 measure: "WP-428a poles found from coefficients (orders 1, 2), relative")
                expectClose(try coefficients.gain, system.gain, .relative(1e-13), item.golden.name)
                #expect(try coefficients.zeros.count == system.zeros.count)
                #expect(try coefficients.isStable == true)
            }
        }
    }

    // MARK: Fixture: a pole on the unit circle

    @Test func aPoleOnTheUnitCircleIsNotStable() throws {
        // One pole on the circle among poles inside it decides: the largest radius counts.
        let mixed = ZeroPoleGain(zeros: [], poles: [Complex(0.5), Complex(1), Complex(0.2, 0.3), Complex(0.2, -0.3)], gain: 1, domain: .digital)
        #expect(try mixed.isStable == false && mixed.stabilityMargin == 0)
        // Through coefficients the pole at 1 is *found*, to rounding: the margin is zero to
        // the last bits, and which side of zero it falls on is noise. Stability is judged in
        // zero-pole or section form.
        expectClose(try mixed.transferFunction().stabilityMargin, 0, .absolute(1e-14))
        let tame = ZeroPoleGain(zeros: [], poles: [Complex(0.2), Complex(0.9), Complex(-0.5)], gain: 1, domain: .digital)
        #expect(try tame.isStable)
        expectClose(try tame.stabilityMargin, 0.1, .relative(1e-14))
        expectClose(try tame.transferFunction().stabilityMargin, 0.1, .relative(1e-12))

        // An accumulator, y[n] = x[n] + y[n − 1]: H = z / (z − 1).
        let accumulator = ZeroPoleGain(zeros: [.zero], poles: [Complex(1)], gain: 1, domain: .digital)
        #expect(accumulator.poles == [Complex(1)] && accumulator.zeros == [.zero] && accumulator.gain == 1)
        #expect(try accumulator.isStable == false)
        #expect(try accumulator.stabilityMargin == 0)
        #expect(try accumulator.isMinimumPhase)

        // The same system as coefficients and as a section.
        let coefficients = TransferFunction.differenceEquation(b: [1], a: [1, -1])
        #expect(try coefficients.poles == [Complex(1)])
        #expect(try coefficients.isStable == false)
        #expect(try coefficients.stabilityMargin == 0)
        let section = SecondOrderSections(sections: [.init(b0: 1, b1: 0, b2: 0, a1: -1, a2: 0)])
        #expect(section.poles == [Complex(1)] && section.zeros == [.zero])
        #expect(try section.isStable == false)
        #expect(section.stabilityMargin == 0)

        // An undamped resonator: a conjugate pair exactly on the circle, written as a section
        // with a2 = 1. The radius is read as √a2 and is exactly 1 at every angle.
        for angle in [0.1, 1.0, Double.pi / 3, 2.5] {
            let resonator = SecondOrderSections(sections: [.init(b0: 1, b1: 0, b2: 0, a1: -2 * cos(angle), a2: 1)])
            #expect(resonator.stabilityMargin == 0, "angle \(angle)")
            #expect(try resonator.isStable == false)
            let poles = resonator.poles
            #expect(poles.count == 2 && poles[0] == poles[1].conjugate)
            expectClose(poles[0].phase, angle, .relative(1e-14))
            expectClose(poles[0].magnitude, 1, .relative(1e-15))
        }
        // Poles at −1 and at ±j.
        let nyquist = ZeroPoleGain(zeros: [], poles: [Complex(-1), Complex(0, 1), Complex(0, -1)], gain: 1, domain: .digital)
        #expect(try nyquist.isStable == false && nyquist.stabilityMargin == 0)
        // Inside by a hair is stable, outside is not, and the margin says by how much.
        let inside = ZeroPoleGain(zeros: [], poles: [Complex(0.999)], gain: 1, domain: .digital)
        #expect(try inside.isStable)
        expectClose(try inside.stabilityMargin, 0.001, .relative(1e-12))
        let outside = ZeroPoleGain(zeros: [], poles: [Complex(0.6, 0.9), Complex(0.6, -0.9)], gain: 1, domain: .digital)
        #expect(try outside.isStable == false)
        expectClose(try outside.stabilityMargin, 1 - (0.36 + 0.81).squareRoot(), .relative(1e-14))
    }

    // MARK: Fixture: an analog system

    @Test func anAnalogSystemIsJudgedByTheHalfPlane() throws {
        // (s² + 9) / ((s + 0.5)(s² + 2s + 5)): zeros on the imaginary axis, poles in the left half plane.
        let system = ZeroPoleGain(zeros: [Complex(0, 3), Complex(0, -3)], poles: [Complex(-1, 2), Complex(-1, -2), Complex(-0.5)],
                                  gain: 2, domain: .analog)
        #expect(try system.isStable)
        #expect(try system.stabilityMargin == 0.5, "the distance of the rightmost pole from the imaginary axis")
        #expect(try system.isMinimumPhase, "zeros on the axis are in the closed left half plane")
        // The same poles would be far outside the unit circle: the digital criterion says no.
        let misread = ZeroPoleGain(zeros: system.zeros, poles: system.poles, gain: 2, domain: .digital)
        #expect(try misread.isStable == false)
        #expect(try misread.isMinimumPhase == false)

        // Coefficients: (2s² + 18) / (s³ + 2.5s² + 6s + 2.5).
        let coefficients = try system.transferFunction()
        expectClose(coefficients.denominator.coefficients, [1, 2.5, 6, 2.5], .relative(1e-15))
        expectClose(coefficients.numerator.coefficients, [2, 0, 18], .absolute(1e-15))
        expectRootsClose(try coefficients.poles, system.poles, relative: 1e-14, "poles from coefficients")
        expectRootsClose(try coefficients.zeros, system.zeros, relative: 1e-14, "zeros from coefficients")
        #expect(try coefficients.isStable && coefficients.isMinimumPhase)
        expectClose(try coefficients.stabilityMargin, 0.5, .relative(1e-14))

        // An analog cascade: 1/(s² + 2s + 5) · 2(s² + 9)/(s² + 0.5s + 0)… written with its sections.
        let cascade = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1, a1: 2, a2: 5), .init(b0: 2, b1: 0, b2: 18, a1: 0.5, a2: 0.0625)], domain: .analog)
        #expect(cascade.poles.count == 4 && cascade.zeros == [Complex(0, 3), Complex(0, -3)] && cascade.gain == 2)
        #expect(try cascade.isStable)
        #expect(cascade.stabilityMargin == 0.25, "a double pole at −0.25")

        // On the axis, and beyond it.
        let integrator = ZeroPoleGain(zeros: [], poles: [.zero], gain: 1, domain: .analog)
        #expect(try integrator.isStable == false && integrator.stabilityMargin == 0)
        let oscillator = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1, a1: 0, a2: 4)], domain: .analog)
        #expect(oscillator.poles == [Complex(0, 2), Complex(0, -2)])
        #expect(oscillator.stabilityMargin == 0)
        #expect(try oscillator.isStable == false)
        let growing = ZeroPoleGain(zeros: [Complex(1)], poles: [Complex(0.25, 3), Complex(0.25, -3)], gain: 1, domain: .analog)
        #expect(try growing.isStable == false && growing.stabilityMargin == -0.25)
        #expect(try growing.isMinimumPhase == false, "a zero in the right half plane")

        // The analog designs of the matrix: all stable, with the margin of their rightmost pole.
        for item in try DesignCase.all(analog: true) where item.order == 5 {
            let design = item.design.zeroPoleGain
            #expect(try design.isStable, "\(item.golden.name)")
            #expect(try design.stabilityMargin == -(design.poles.map(\.real).max() ?? 0))
        }
    }

    // MARK: Minimum phase and systems without poles

    @Test func minimumPhaseLooksAtTheZeros() throws {
        // Every digital design of the matrix has its zeros on the unit circle: minimum phase,
        // and reported so in spite of rounding.
        for item in try DesignCase.all(analog: false) {
            #expect(try item.design.zeroPoleGain.isMinimumPhase, "\(item.golden.name)")
            #expect(try item.design.secondOrderSections.isMinimumPhase, "\(item.golden.name)")
        }
        let maximumPhase = SecondOrderSections(sections: [.init(b0: 1, b1: -2.5, b2: 1, a1: 0, a2: 0)])   // zeros at 2 and 0.5
        #expect(try maximumPhase.isMinimumPhase == false)
        #expect(try SecondOrderSections(sections: [.init(b0: 1, b1: -1, b2: 0.25, a1: 0, a2: 0)]).isMinimumPhase)   // a double zero at 0.5
        #expect(try ZeroPoleGain(zeros: [Complex(1.000001)], poles: [], gain: 1, domain: .digital).isMinimumPhase == false)
        #expect(try ZeroPoleGain(zeros: [Complex(0, 1e9)], poles: [], gain: 1, domain: .analog).isMinimumPhase)
        #expect(try ZeroPoleGain(zeros: [Complex(1, 1e9)], poles: [], gain: 1, domain: .analog).isMinimumPhase == false)
    }

    @Test func aSystemWithoutPolesIsStable() throws {
        let gain = ZeroPoleGain(zeros: [], poles: [], gain: 3, domain: .digital)
        #expect(try gain.isStable && gain.stabilityMargin == 1 && gain.isMinimumPhase)
        let analogGain = ZeroPoleGain(zeros: [], poles: [], gain: 3, domain: .analog)
        #expect(try analogGain.isStable && analogGain.stabilityMargin == .greatestFiniteMagnitude)
        let fir = SecondOrderSections(sections: [.init(b0: 0.25, b1: 0.5, b2: 0.25, a1: 0, a2: 0)])
        #expect(fir.poles == [.zero, .zero] && fir.stabilityMargin == 1)
        #expect(SecondOrderSections(sections: []).stabilityMargin == 1)
        #expect(SecondOrderSections(sections: [], domain: .analog).stabilityMargin == .greatestFiniteMagnitude)
        #expect(SecondOrderSections(sections: [.init(b0: 2, b1: 0, b2: 0, a1: 0, a2: 0)], domain: .analog).stabilityMargin == .greatestFiniteMagnitude)
        // An analog section with a real pole pair.
        let overdamped = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1, a1: 5, a2: 4)], domain: .analog)
        #expect(overdamped.stabilityMargin == 1)
    }

    @Test func aConformerOnlyNeedsItsRoots() throws {
        /// A delay line, described by nothing but its poles: everything else is the default.
        struct Delay: LTISystem {
            let samples: Int
            var domain: SystemDomain { .digital }
            var zeros: [Complex] { [] }
            var poles: [Complex] { [Complex](repeating: .zero, count: samples) }
            var gain: Double { 1 }
        }
        let delay = Delay(samples: 3)
        #expect(try delay.isStable && delay.stabilityMargin == 1 && delay.isMinimumPhase)
        let frequencies = (0 ..< 64).map { Double($0) * 0.05 }
        let response = try delay.frequencyResponse(at: frequencies)
        for (value, frequency) in zip(response, frequencies) {
            let expected = Complex(magnitude: 1, phase: -3 * frequency)
            #expect((value - expected).magnitude <= 1e-14)
        }
        #expect(try delay.magnitudeResponse(at: frequencies).allSatisfy { abs($0 - 1) <= 1e-14 })
        expectClose(try delay.phaseResponse(at: frequencies, unwrapped: true), frequencies.map { -3 * $0 }, .absolute(1e-13))
        #expect(try delay.groupDelay(at: frequencies).allSatisfy { $0 != nil && abs($0! - 3) <= 1e-13 })
    }
}

/// WP-429: the frequency, magnitude and unwrapped phase responses. Golden, on the matrix of
/// STG-2: family × response × orders 1, 2, 5, 8; 512 frequencies; the complex response within
/// 1e-9 (of the largest value of the response, which is the filter's pass-band gain).
@Suite("LTISystem: frequency, magnitude and phase responses (WP-429)")
struct LTISystemResponseTests {
    private static let tolerance = 1e-9

    @Test func digitalResponsesMatchTheOracle() throws {
        let curves = try DesignCurves(domain: "digital", key: "curves")
        let grid = try DesignCurves.grid("digital")
        #expect(grid.count == 512 && grid[0] == 0)
        for item in try DesignCase.all(analog: false) {
            let expected = curves.complexCurve(row: try item.golden.integer("row"))
            // The sections, as the kernel runs them: the product of section responses.
            let sections = try item.design.secondOrderSections
            expectResponseClose(try sections.frequencyResponse(at: grid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), sections",
                                measure: "WP-429 digital response from sections, relative to the peak")
            // The zeros and poles: the same response, up to the delay that the pairing's
            // padding at the origin adds for an odd number of poles (none here: zeros = poles).
            expectResponseClose(try item.design.zeroPoleGain.frequencyResponse(at: grid), expected, relativeToPeak: Self.tolerance,
                                "\(item.golden.name), zeros and poles", measure: "WP-429 digital response from zeros and poles, relative to the peak")
        }
    }

    @Test func analogResponsesMatchTheOracle() throws {
        let curves = try DesignCurves(domain: "analog", key: "curves")
        let grid = try DesignCurves.grid("analog")
        #expect(grid.count == 512)
        for item in try DesignCase.all(analog: true) {
            let expected = curves.complexCurve(row: try item.golden.integer("row"))
            expectResponseClose(try item.design.zeroPoleGain.frequencyResponse(at: grid), expected, relativeToPeak: Self.tolerance,
                                "\(item.golden.name)", measure: "WP-429 analog response from zeros and poles, relative to the peak")
        }
    }

    @Test func theCoefficientFormMatchesTheOracleForLowOrders() throws {
        // From the oracle's own coefficients, so that only the evaluation is under test:
        // freqs for the analog designs, freqz for the digital ones.
        for domain in ["analog", "digital"] {
            let curves = try DesignCurves(domain: domain, key: domain == "analog" ? "curves" : "tf_curves")
            let grid = try DesignCurves.grid(domain)
            let cases = try DesignCase.all(analog: domain == "analog").filter { $0.order <= 2 }
            #expect(cases.count == 40)
            for item in cases {
                let system = TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"),
                                              domain: domain == "analog" ? .analog : .digital)
                let expected = curves.complexCurve(row: try item.golden.integer(domain == "analog" ? "row" : "tf_row"))
                expectResponseClose(try system.frequencyResponse(at: grid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), coefficients",
                                    measure: "WP-429 \(domain) response from coefficients (orders 1, 2), relative to the peak")
            }
        }
    }

    @Test func magnitudesMatchTheOracleInBothScales() throws {
        let curves = try DesignCurves(domain: "digital", key: "curves")
        let grid = try DesignCurves.grid("digital")
        for item in try DesignCase.all(analog: false) {
            let expected = curves.complexCurve(row: try item.golden.integer("row")).map(\.magnitude)
            let sections = try item.design.secondOrderSections
            let linear = try sections.magnitudeResponse(at: grid, in: .linear)
            expectClose(linear, expected, .relativeToMaximum(Self.tolerance), "\(item.golden.name)")
            #expect(try sections.magnitudeResponse(at: grid) == linear, "linear is the default")
            // Decibels: 20·log₁₀ of the same magnitudes, clamped at the floor.
            let decibels = try sections.magnitudeResponse(at: grid, in: .decibels)
            let deep = try sections.magnitudeResponse(at: grid, in: .decibels(floor: -600))
            for index in grid.indices {
                let level = expected[index] > 0 ? 20 * log10(expected[index]) : -Double.infinity
                // 1e-9 of the peak is what the response is known to; in decibels that is a
                // relative error of 1e-9 / |H|.
                let slack = 8.7e-9 / max(expected[index], 1e-9) + 1e-9
                if level > -159 { #expect(abs(decibels[index] - level) <= slack, "\(item.golden.name), point \(index)") }
                if level > -599 && expected[index] > 1e-6 { #expect(abs(deep[index] - level) <= slack) }
                #expect(decibels[index] >= -160 && deep[index] >= -600)
            }
        }
        #expect(MagnitudeScale.decibels.floor == -160 && MagnitudeScale.decibels(floor: -90).floor == -90)
        #expect(MagnitudeScale.decibels != MagnitudeScale.linear && MagnitudeScale.decibels(floor: -160) == .decibels)
    }

    @Test func aZeroOfTheResponseIsTheFloorInDecibelsNotMinusInfinity() throws {
        let highPass = try IIRDesign(.butterworth, .highPass(cutoff: 3_000), order: 4, domain: .digital(sampleRate: 48_000)).secondOrderSections
        #expect(try highPass.magnitudeResponse(at: [0], in: .linear) == [0])
        #expect(try highPass.magnitudeResponse(at: [0], in: .decibels) == [-160])
        #expect(try highPass.magnitudeResponse(at: [0], in: .decibels(floor: -300)) == [-300])
        #expect(try highPass.phaseResponse(at: [0]) == [0], "the phase of a zero response is 0")
    }

    @Test func unwrappedPhasesMatchTheOracle() throws {
        let curves = try DesignCurves(domain: "digital", key: "curves")
        let grid = try DesignCurves.grid("digital")
        var compared = 0
        for item in try DesignCase.all(analog: false) {
            let row = try item.golden.integer("row")
            let response = curves.complexCurve(row: row)
            let expected = curves.curve(row: row, channel: 3)
            let sections = try item.design.secondOrderSections
            let unwrapped = try sections.phaseResponse(at: grid, unwrapped: true)
            let wrapped = try sections.phaseResponse(at: grid, unwrapped: false)
            let peak = response.map(\.magnitude).max() ?? 1
            // Where the response is tiny its phase is noise, and a step of ±π there may be
            // unwrapped either way: both curves are followed up to the first such point.
            var index = 0
            while index < grid.count, response[index].magnitude >= 1e-6 * peak || index == 0 {
                // A response known to 1e-9 of its peak has a phase known to 1e-9·peak/|H|.
                let slack = Self.tolerance * peak / max(response[index].magnitude, 1e-300)
                if response[index].magnitude >= 1e-6 * peak {
                    #expect(abs(unwrapped[index] - expected[index]) <= slack, "\(item.golden.name), point \(index): \(unwrapped[index]) against \(expected[index])")
                    Measurements.shared.record("WP-429 unwrapped phase, radians, where the magnitude is at least 1e-6 of the peak", abs(unwrapped[index] - expected[index]), bound: 1e-3)
                    // The wrapped phase is the same angle modulo 2π, in −π … π.
                    let turns = (unwrapped[index] - wrapped[index]) / (2 * .pi)
                    #expect(abs(turns - turns.rounded()) <= 1e-9 && abs(wrapped[index]) <= .pi)
                    compared += 1
                }
                index += 1
            }
        }
        #expect(compared > 80 * 100, "the comparison covers the pass bands and the skirts: \(compared) points")
    }

    @Test func unwrappingRemovesJumpsOfTwoPiAndNothingElse() throws {
        // A delay of 20 samples: the phase is −20ω, wrapped many times over 0 … π.
        let delay = ZeroPoleGain(zeros: [], poles: [Complex](repeating: .zero, count: 20), gain: 1, domain: .digital)
        let frequencies = (0 ..< 400).map { Double($0) * .pi / 400 }
        let wrapped = try delay.phaseResponse(at: frequencies)
        let unwrapped = try delay.phaseResponse(at: frequencies, unwrapped: true)
        #expect(wrapped.allSatisfy { abs($0) <= .pi })
        #expect(wrapped != unwrapped)
        expectClose(unwrapped, frequencies.map { -20 * $0 }, .absolute(1e-11))
        // A response without jumps is returned as it is, as are one point and none.
        let gentle = try ZeroPoleGain(zeros: [], poles: [Complex(0.5)], gain: 1, domain: .digital).phaseResponse(at: frequencies)
        #expect(try ZeroPoleGain(zeros: [], poles: [Complex(0.5)], gain: 1, domain: .digital).phaseResponse(at: frequencies, unwrapped: true) == gentle)
        #expect(try delay.phaseResponse(at: [1.0], unwrapped: true) == delay.phaseResponse(at: [1.0]))
        #expect(try delay.phaseResponse(at: [], unwrapped: true).isEmpty)
        // A sign change of a real response is a step of π, and stays one.
        let comb = ZeroPoleGain(zeros: [Complex(0, 1), Complex(0, -1)], poles: [.zero, .zero], gain: 1, domain: .digital)   // 1 + z⁻²
        let steps = try comb.phaseResponse(at: [1.0, 2.0], unwrapped: true)
        expectClose(steps[1] - steps[0], Double.pi - 1, .absolute(1e-12))
    }

    @Test func theResponseAtAPoleIsTheLargestFiniteNumber() throws {
        let accumulator = ZeroPoleGain(zeros: [.zero], poles: [Complex(1)], gain: 1, domain: .digital)
        let forms: [any LTISystem] = [accumulator, try accumulator.transferFunction(), try accumulator.secondOrderSections()]
        for system in forms {
            let response = try system.frequencyResponse(at: [0, 1])
            #expect(response[0] == Complex(.greatestFiniteMagnitude, 0), "\(type(of: system))")
            #expect(response[1].isFinite && response[1].magnitude < 2)
            #expect(try system.magnitudeResponse(at: [0], in: .linear) == [.greatestFiniteMagnitude])
            #expect(try system.magnitudeResponse(at: [0], in: .decibels)[0].isFinite)
            #expect(try system.phaseResponse(at: [0]) == [0])
            #expect(try system.groupDelay(at: [0, 1]) [0] == nil, "the delay is undefined at the pole")
            #expect(try system.groupDelay(at: [0, 1]) [1] != nil, "and defined beside it")
        }
        let integrator = ZeroPoleGain(zeros: [], poles: [.zero], gain: 1, domain: .analog)
        #expect(try integrator.frequencyResponse(at: [0]) == [Complex(.greatestFiniteMagnitude, 0)])
        expectClose(try integrator.magnitudeResponse(at: [4])[0], 0.25, .relative(1e-15))
    }

    @Test func aFrequencyThatIsNotFiniteIsATypedError() throws {
        let system = try IIRDesign(.butterworth, .lowPass(cutoff: 3_000), order: 3, domain: .digital(sampleRate: 48_000))
        let forms: [any LTISystem] = [system.zeroPoleGain, try system.secondOrderSections, try system.transferFunction]
        for form in forms {
            for bad in [Double.nan, .infinity, -.infinity] {
                #expect(thrownError { _ = try form.frequencyResponse(at: [0.1, bad]) }?.invalidParameterName == "frequencies")
                #expect(thrownError { _ = try form.magnitudeResponse(at: [bad], in: .decibels) }?.invalidParameterName == "frequencies")
                #expect(thrownError { _ = try form.phaseResponse(at: [bad], unwrapped: true) }?.invalidParameterName == "frequencies")
                #expect(thrownError { _ = try form.groupDelay(at: [bad]) }?.invalidParameterName == "frequencies")
            }
            #expect(try form.frequencyResponse(at: []).isEmpty && form.groupDelay(at: []).isEmpty)
            // A digital response is periodic and conjugate-symmetric.
            let pair = try form.frequencyResponse(at: [0.7, -0.7, 0.7 + 2 * .pi])
            #expect((pair[1] - pair[0].conjugate).magnitude <= 1e-14 && (pair[2] - pair[0]).magnitude <= 1e-13)
        }
    }
}

/// WP-430, the group delay: golden within 1e-6 samples; a linear-phase delay equals
/// (K − 1)/2; a point on a unit-circle zero is reported undefined.
@Suite("LTISystem: group delay (WP-430)")
struct LTISystemGroupDelayTests {
    private static let tolerance = 1e-6

    /// Compares where the delay is defined. Where the oracle's response is below 1e-12 of its
    /// peak the delay must be `nil`; a factor of two around that threshold is left to either.
    private func compare(_ delays: [Double?], _ expected: [Double], response: [Complex], _ name: String, label: String) -> Int {
        let peak = response.map(\.magnitude).max() ?? 0
        var compared = 0
        for index in delays.indices {
            let magnitude = response[index].magnitude
            if magnitude >= 2e-12 * peak {
                guard let delay = delays[index] else {
                    Issue.record("\(name), point \(index): the delay is reported undefined where |H| is \(magnitude / peak) of the peak")
                    continue
                }
                #expect(abs(delay - expected[index]) <= Self.tolerance, "\(name), point \(index): \(delay) samples against \(expected[index])")
                Measurements.shared.record(label, abs(delay - expected[index]), bound: Self.tolerance)
                compared += 1
            } else if magnitude <= 0.5e-12 * peak {
                #expect(delays[index] == nil, "\(name), point \(index): |H| is \(magnitude / peak) of the peak, the delay must be undefined")
            }
        }
        return compared
    }

    @Test func digitalGroupDelaysMatchTheOracle() throws {
        let curves = try DesignCurves(domain: "digital", key: "curves")
        let grid = try DesignCurves.grid("digital")
        var compared = 0
        var undefined = 0
        for item in try DesignCase.all(analog: false) {
            let row = try item.golden.integer("row")
            let response = curves.complexCurve(row: row)
            let expected = curves.curve(row: row, channel: 2)
            // The sections: closed form per section, from the coefficients.
            let fromSections = try item.design.secondOrderSections.groupDelay(at: grid)
            compared += compare(fromSections, expected, response: response, "\(item.golden.name), sections",
                                label: "WP-430 group delay from sections, samples")
            // The zeros and poles: a sum over the roots.
            let fromRoots = try item.design.zeroPoleGain.groupDelay(at: grid)
            _ = compare(fromRoots, expected, response: response, "\(item.golden.name), zeros and poles",
                        label: "WP-430 group delay from zeros and poles, samples")
            undefined += fromSections.filter { $0 == nil }.count
        }
        #expect(compared > 80 * 400, "\(compared) points compared")
        #expect(undefined > 0, "the matrix holds responses with zeros on the unit circle")
    }

    /// The coefficient form, against `group_delay` applied to the oracle's own coefficients.
    ///
    /// The comparison stops at 1 % of the peak. Below that the oracle's formula, which works
    /// on the expanded polynomials, has itself lost its digits: beside the notch of the
    /// order-2 band-stop designs it differs from the section-wise oracle by up to 1.3e-3
    /// samples. (A coefficient form cannot be better there: rounding its coefficients splits
    /// the double zero. That is what the sections are for.)
    @Test func theCoefficientFormMatchesTheOracleForLowOrders() throws {
        let curves = try DesignCurves(domain: "digital", key: "tf_curves")
        let sectionwise = try DesignCurves(domain: "digital", key: "curves")
        let grid = try DesignCurves.grid("digital")
        var compared = 0
        for item in try DesignCase.all(analog: false) where item.order <= 2 {
            let row = try item.golden.integer("tf_row")
            let system = TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"), domain: .digital)
            let delays = try system.groupDelay(at: grid)
            let expected = curves.curve(row: row, channel: 2)
            let accurate = sectionwise.curve(row: try item.golden.integer("row"), channel: 2)
            let response = curves.complexCurve(row: row)
            let peak = response.map(\.magnitude).max() ?? 0
            for index in grid.indices where response[index].magnitude >= 1e-2 * peak {
                let delay = try #require(delays[index], "\(item.golden.name), point \(index)")
                #expect(abs(delay - expected[index]) <= Self.tolerance, "\(item.golden.name), point \(index): \(delay) samples against \(expected[index])")
                Measurements.shared.record("WP-430 group delay from coefficients (orders 1, 2; magnitude at least 1 % of the peak), samples", abs(delay - expected[index]), bound: Self.tolerance)
                // Against the section-wise oracle of the same design the agreement is far closer:
                // most of the figure above is the coefficient-form oracle's own error.
                #expect(abs(delay - accurate[index]) <= Self.tolerance)
                Measurements.shared.record("WP-430 group delay from coefficients against the section-wise oracle, samples", abs(delay - accurate[index]), bound: Self.tolerance)
                compared += 1
            }
        }
        #expect(compared > 40 * 100)
    }

    // MARK: Linear phase

    @Test func aLinearPhaseSystemDelaysByHalfItsLengthMinusOne() throws {
        // Symmetric taps of length K: the delay is (K − 1)/2 at every frequency where the
        // response does not vanish.
        let frequencies = (1 ..< 100).map { Double($0) * 0.03 }
        let taps: [[Double]] = [[0.25, 0.5, 0.25], [1, 2, 3, 2, 1], [1, 3, 3, 1], [-1, 0, 1], [0.1, 0.4, 0.8, 1, 0.8, 0.4, 0.1]]
        for coefficients in taps {
            let expected = Double(coefficients.count - 1) / 2
            let system = TransferFunction.differenceEquation(b: coefficients, a: [1])
            let delays = try system.groupDelay(at: frequencies)
            let response = try system.frequencyResponse(at: frequencies)
            let peak = response.map(\.magnitude).max() ?? 0
            for (delay, value) in zip(delays, response) where value.magnitude > 1e-6 * peak {
                expectClose(try #require(delay), expected, .absolute(1e-6), "taps \(coefficients)")
                Measurements.shared.record("WP-430 linear-phase delay against (K − 1)/2, samples", abs((delay ?? 0) - expected), bound: 1e-6)
            }
        }
        // The same through sections and through zeros and poles: [0.25, 0.5, 0.25] is one section.
        let section = SecondOrderSections(sections: [.init(b0: 0.25, b1: 0.5, b2: 0.25, a1: 0, a2: 0)])
        #expect(try section.groupDelay(at: frequencies).allSatisfy { $0 != nil && abs($0! - 1) <= 1e-12 })
        #expect(try section.zeroPoleGain().groupDelay(at: frequencies).allSatisfy { $0 != nil && abs($0! - 1) <= 1e-12 })
    }

    // MARK: Undefined points

    @Test func aPointOnAUnitCircleZeroIsReportedUndefined() throws {
        // [0.25, 0.5, 0.25] has a double zero at z = −1: the Nyquist frequency.
        let section = SecondOrderSections(sections: [.init(b0: 0.25, b1: 0.5, b2: 0.25, a1: 0, a2: 0)])
        let forms: [any LTISystem] = [section, section.zeroPoleGain(), TransferFunction.differenceEquation(b: [0.25, 0.5, 0.25], a: [1])]
        for system in forms {
            let delays = try system.groupDelay(at: [0, 1, .pi])
            #expect(delays[0] != nil && delays[1] != nil, "\(type(of: system))")
            #expect(delays[2] == nil, "\(type(of: system)): the delay at the zero must be undefined")
        }
        // A notch at a quarter of the sample rate: zeros at ±j.
        let notch = SecondOrderSections(sections: [.init(b0: 1, b1: 0, b2: 1, a1: 0, a2: 0.81)])
        let delays = try notch.groupDelay(at: [1.0, .pi / 2, 2.0])
        #expect(delays[0] != nil && delays[2] != nil && delays[1] == nil)
        // A high-pass has its zeros at 0 Hz, a band-stop at its centre.
        let highPass = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .highPass(cutoff: 3_000), order: 5,
                                     domain: .digital(sampleRate: 48_000)).secondOrderSections
        #expect(try highPass.groupDelay(at: [0, 0.5]) [0] == nil)
        // "Below 1e-12 of the largest magnitude among the frequencies": a response that is merely small is defined…
        let small = SecondOrderSections(sections: [.init(b0: 1e-9, b1: 0, b2: 0, a1: -0.5, a2: 0)])
        #expect(try small.groupDelay(at: [0.3, 1.2]).allSatisfy { $0 != nil })
        // …and the threshold follows the peak of what was asked for: 1e-13 of the peak is undefined.
        let steep = try IIRDesign(.butterworth, .lowPass(cutoff: 300), order: 8, domain: .digital(sampleRate: 48_000)).secondOrderSections
        let levels = try steep.magnitudeResponse(at: [0, 2.6])
        #expect(levels[1] < 1e-12 * levels[0] && levels[1] > 0)
        #expect(try steep.groupDelay(at: [0, 2.6]) [1] == nil)
        #expect(try steep.groupDelay(at: [2.6]) [0] != nil, "asked on its own, the same point is its own peak")
        // A system that passes nothing has no delay anywhere.
        let silent = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 0, a1: -0.5, a2: 0)])
        #expect(try silent.groupDelay(at: [0.1, 0.2]) == [nil, nil])
    }

    // MARK: Analog systems

    @Test func theDelayOfAnAnalogSystemIsInSeconds() throws {
        // One pole at −a: τ(ω) = a / (a² + ω²).
        let a = 250.0
        let frequencies: [Double] = [0, 10, 250, 4_000]
        let forms: [any LTISystem] = [
            ZeroPoleGain(zeros: [], poles: [Complex(-a)], gain: a, domain: .analog),
            TransferFunction(numerator: [a], denominator: [1, a], domain: .analog),
            SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: a, a1: a, a2: 0)], domain: .analog),   // a/(s·(s + a))·s: the pole at 0 is cancelled by nothing here
        ]
        for system in forms.prefix(2) {
            let delays = try system.groupDelay(at: frequencies)
            for (delay, frequency) in zip(delays, frequencies) {
                expectClose(try #require(delay), a / (a * a + frequency * frequency), .relative(1e-13), "\(type(of: system))")
            }
        }
        // A Bessel filter in the delay normalisation holds one second across its pass band.
        let bessel = try AnalogPrototype.bessel(order: 8, normalization: .delay)
        for delay in try bessel.groupDelay(at: [0, 0.5, 1, 2]) {
            expectClose(try #require(delay), 1, .relative(1e-6))
        }
        // Any design: the delay is minus the derivative of the unwrapped phase.
        let design = try IIRDesign(.chebyshev1(ripple: .decibels(1)), .bandPass(from: 900, to: 1_100), order: 3, domain: .analog).zeroPoleGain
        let step = 1e-4
        for frequency in [850.0, 950, 1_000, 1_080] {
            let phases = try design.phaseResponse(at: [frequency - step, frequency + step], unwrapped: true)
            let numeric = -(phases[1] - phases[0]) / (2 * step)
            expectClose(try #require(try design.groupDelay(at: [frequency])[0]), numeric, .relative(1e-6), "\(frequency) rad/s")
            // And the three forms agree.
            expectClose(try #require(try design.transferFunction().groupDelay(at: [frequency])[0]), numeric, .relative(1e-6))
        }
        // An analog cascade of sections against its own zeros and poles.
        let cascade = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1, a1: 2, a2: 5), .init(b0: 2, b1: 0, b2: 18, a1: 0.5, a2: 0.0625)], domain: .analog)
        let fromSections = try cascade.groupDelay(at: [0.3, 1, 2.2, 7])
        let fromRoots = try cascade.zeroPoleGain().groupDelay(at: [0.3, 1, 2.2, 7])
        for (left, right) in zip(fromSections, fromRoots) {
            expectClose(try #require(left), try #require(right), .relative(1e-12))
        }
        #expect(try cascade.groupDelay(at: [3]) == [nil], "the analog zero at 3 rad/s")
        _ = forms
    }

    @Test func theDelayIsTheDerivativeOfThePhaseForADigitalDesign() throws {
        let design = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 4,
                                   domain: .digital(sampleRate: 48_000))
        let sections = try design.secondOrderSections
        let step = 1e-5
        for frequency in [0.2, 0.3, 0.45, 0.6, 0.7] {
            let phases = try sections.phaseResponse(at: [frequency - step, frequency + step], unwrapped: true)
            let numeric = -(phases[1] - phases[0]) / (2 * step)
            expectClose(try #require(try sections.groupDelay(at: [frequency])[0]), numeric, .relative(1e-6), "\(frequency) rad per sample")
            expectClose(try #require(try design.zeroPoleGain.groupDelay(at: [frequency])[0]), numeric, .relative(1e-6))
            expectClose(try #require(try design.transferFunction.groupDelay(at: [frequency])[0]), numeric, .relative(1e-5))
        }
    }
}
