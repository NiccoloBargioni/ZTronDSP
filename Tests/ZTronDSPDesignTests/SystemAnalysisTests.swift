import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

private func design(of fixture: StressFixture.FilterCase) throws -> IIRDesign {
    try IIRDesign(.butterworth, fixture.response == .lowPass ? .lowPass(cutoff: fixture.cutoff) : .highPass(cutoff: fixture.cutoff),
                  order: fixture.order, domain: .digital(sampleRate: fixture.sampleRate))
}

/// WP-428b. Stability, minimum and linear phase; the numerical figures of §6.3.8.
/// Acceptance: figures for the stress fixtures (WP-016) equal recorded values; analog criteria
/// use the half plane.
@Suite("System analysis: verdicts and numerical figures (WP-428b)")
struct SystemAnalysisFigureTests {
    /// The figures of the stress fixtures, as they were measured on the iOS 27.0 simulator
    /// (Debug and Release agree): stability margin, single against double in dB, round-off
    /// gain of the cascade in dB for single and for double precision, recommended precision.
    private static let recorded: [String: (margin: Double, deviation: Double, single: Double, double: Double, precision: BiquadPrecision)] = [
        "hp-90Hz-48k-order8": (0.0022956655111259217, -60.15, -82.647, -257.244, .double),
        "hp-20Hz-96k-order8": (0.00025533996217064203, -44.28, -54.058, -228.655, .double),
        "lp-10Hz-192k-order8": (6.384111960278105e-05, -27.87, -34.746, -209.343, .double),
        "hp-10Hz-44k1-order2": (0.001006949134693902, -51.91, -63.613, -238.211, .double),
        "lp-0.45fs-48k-order8": (0.05857389455836004, -108.69, -124.122, -298.719, .single),
        "hp-0.45fs-44k1-order4": (0.11202492162488153, -120.34, -127.894, -302.491, .single),
        "lp-0.49fs-48k-order2": (0.04345630794958788, -92.22, -112.569, -287.167, .double),
    ]

    @Test func theFiguresOfTheStressFixturesEqualTheirRecordedValues() throws {
        let fixtures = StressFixture.filtersNearZero + StressFixture.filtersNearNyquist
        #expect(fixtures.count == Self.recorded.count)
        for fixture in fixtures {
            let designed = try design(of: fixture)
            let report = try SystemAnalysis.analyse(designed.zeroPoleGain, sampleRate: fixture.sampleRate)
            let deviation = try #require(report.singleVersusDoubleDeviation, "\(fixture.name)")
            let single = try #require(report.roundOffNoiseGain(precision: .single)), double = try #require(report.roundOffNoiseGain(precision: .double))
            let expected = try #require(Self.recorded[fixture.name], "\(fixture.name) has no recorded figures")
            // The margin is closed form on the design: equal to rounding.
            expectClose(report.stabilityMargin, expected.margin, .relative(1e-9), "\(fixture.name): stability margin")
            // The deviation is measured on vDSP_biquad: equal to a quarter of a decibel.
            expectClose(deviation, expected.deviation, .absolute(0.25), "\(fixture.name): single against double")
            // The round-off gain is computed in double precision: equal to a hundredth of a decibel.
            expectClose(single, expected.single, .absolute(0.01), "\(fixture.name): round-off gain, single")
            expectClose(double, expected.double, .absolute(0.01), "\(fixture.name): round-off gain, double")
            #expect(report.recommendedPrecision == expected.precision, "\(fixture.name)")
            // The structural members.
            #expect(report.isStable && report.kind == .infiniteImpulseResponse && !report.isLinearPhase && report.domain == .digital)
            #expect(report.order == fixture.order && report.poles.count == fixture.order && report.zeros.count == fixture.order)
            #expect(report.sections?.sections.count == (fixture.order + 1) / 2 && report.taps == nil)
            #expect(report.isMinimumPhase, "\(fixture.name): the zeros of a Butterworth filter lie on the unit circle")
            #expect(report.rootConditions.largest == nil, "a design's roots are not found from coefficients")
            // The two precisions differ by the ratio of their rounding units, and `.automatic` is the recommended one.
            expectClose(single - double, 20 * log10(pow(2.0, 29)), .absolute(1e-9))
            #expect(report.roundOffNoiseGain() == (report.recommendedPrecision == .double ? double : single))
            // What the report says is what the stage runs.
            #expect(report.sections == (try designed.secondOrderSections.spreadingGain()))
            #expect(deviation == (try designed.secondOrderSections.singleVersusDoubleDeviation()))
        }
    }

    @Test func theRootConditionsOfThePolynomialFixturesAreReported() throws {
        // A system given as coefficients has its roots found, and each is known to its condition.
        for fixture in StressFixture.wellConditionedPolynomials {
            let report = try SystemAnalysis.analyse(TransferFunction(numerator: [1], denominator: fixture.coefficients, domain: .digital), sampleRate: 48_000)
            #expect(report.rootConditions.poles.count == fixture.degree && report.rootConditions.zeros.isEmpty)
            expectClose(try #require(report.rootConditions.largest), fixture.largestConditionNumber, .relative(1e-6), fixture.name)
            #expect(report.rootConditions.poles.allSatisfy { $0 != nil })
        }
        // Wilkinson's polynomial, as a numerator: the recorded figure, to the 1 % its own rounding allows.
        let wilkinson = try SystemAnalysis.analyse(TransferFunction(numerator: StressFixture.wilkinson20.coefficients, denominator: [1], domain: .analog), sampleRate: 48_000)
        expectClose(try #require(wilkinson.rootConditions.largest), StressFixture.wilkinson20.largestConditionNumber, .relative(0.05))
        #expect(wilkinson.zeros.count == 20 && wilkinson.rootConditions.poles.isEmpty)
        // The expanded Butterworth denominator: the figure saturates beyond 1/ε, and says what matters.
        let butterworth = try SystemAnalysis.analyse(TransferFunction(numerator: [1], denominator: StressFixture.butterworth16Expanded.coefficients, domain: .digital), sampleRate: 48_000)
        #expect((butterworth.rootConditions.largest ?? 0) > 1e12, "\(String(describing: butterworth.rootConditions.largest))")
        // A triple root: an infinite condition, or one beyond anything a double can use.
        let triple = try SystemAnalysis.analyse(TransferFunction(numerator: [1], denominator: StressFixture.tripleRoot.coefficients, domain: .digital), sampleRate: 48_000)
        #expect((triple.rootConditions.largest ?? 0) > 1e4)
        // In a system, only the roots of a difference equation carry a condition.
        let mixed = IIRSystem { Zero(onUnitCircleAt: .hertz(50)); DifferenceEquation(b: [1, 0.5], a: [1, -0.6, 0.25]); Pole(radius: 0.9, frequency: .hertz(100)) }
        let report = try SystemAnalysis.analyse(mixed, sampleRate: 48_000)
        #expect(report.rootConditions.zeros.count == report.zeros.count && report.rootConditions.poles.count == report.poles.count)
        #expect(report.rootConditions.poles.compactMap { $0 }.count == 2 && report.rootConditions.zeros.compactMap { $0 }.count == 1)
        expectClose(try #require(report.rootConditions.largest), 2.0, .relative(1e-9), "the pole pair of z² − 0.6z + 0.25: the well-conditioned quadratic")
        // An FIR system's zeros are found from its taps.
        let fir = try SystemAnalysis.analyse(FIRSystem { Taps([1, -0.6, 0.25]) }, sampleRate: 48_000)
        #expect(fir.rootConditions.zeros.compactMap { $0 } == [2, 2] && fir.rootConditions.poles == [nil, nil])
    }

    @Test func theAnalogCriteriaUseTheHalfPlane() throws {
        // Stable: every pole strictly in the left half plane; the margin is how far.
        let stable = ZeroPoleGain(zeros: [Complex(-3)], poles: [Complex(-1, 2), Complex(-1, -2), Complex(-0.25)], gain: 2, domain: .analog)
        let report = try SystemAnalysis.analyse(stable, sampleRate: 48_000)
        #expect(report.domain == .analog && report.isStable && report.stabilityMargin == 0.25 && report.isMinimumPhase)
        #expect(report.kind == .infiniteImpulseResponse && report.order == 3 && !report.isLinearPhase)
        // Poles of magnitude above 1 are stable in the s plane when they lie on the left.
        let far = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [], poles: [Complex(-10, 50), Complex(-10, -50)], gain: 1, domain: .analog), sampleRate: 48_000)
        #expect(far.isStable && far.stabilityMargin == 10)
        // On the imaginary axis, and to its right: not stable.
        let marginal = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [], poles: [Complex(0, 1), Complex(0, -1)], gain: 1, domain: .analog), sampleRate: 48_000)
        #expect(!marginal.isStable && marginal.stabilityMargin == 0)
        let unstable = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [], poles: [Complex(0.1)], gain: 1, domain: .analog), sampleRate: 48_000)
        #expect(!unstable.isStable && unstable.stabilityMargin == -0.1)
        // Minimum phase: every zero in the closed left half plane.
        let right = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [Complex(0.5)], poles: [Complex(-1)], gain: 1, domain: .analog), sampleRate: 48_000)
        #expect(!right.isMinimumPhase && right.isStable)
        let onAxis = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [Complex(0, 3), Complex(0, -3)], poles: [Complex(-1), Complex(-2)], gain: 1, domain: .analog), sampleRate: 48_000)
        #expect(onAxis.isMinimumPhase)
        // A digital system with the same roots is judged by the unit circle.
        let digital = try SystemAnalysis.analyse(ZeroPoleGain(zeros: [Complex(-3)], poles: [Complex(-0.25), Complex(0.5)], gain: 2, domain: .digital), sampleRate: 48_000)
        #expect(digital.isStable && digital.stabilityMargin == 0.5 && !digital.isMinimumPhase)
        // An analog design, as the analog half of the parity matrix returns it.
        let design = try IIRDesign(.chebyshev1(ripple: .decibels(1)), .bandPass(from: 2 * .pi * 1_000, to: 2 * .pi * 3_000), order: 3, domain: .analog)
        let analysed = try SystemAnalysis.analyse(design.zeroPoleGain, sampleRate: 48_000)
        #expect(analysed.isStable && analysed.poles.count == 6 && analysed.stabilityMargin > 0)
        // No kernel runs an analog system: no cascade, no measured figures, no sampled responses.
        #expect(report.sections == nil && report.taps == nil && report.singleVersusDoubleDeviation == nil && report.roundOffNoiseGain() == nil)
        #expect(report.recommendedPrecision == .single)
        #expect(thrownError { _ = try report.impulseResponse(count: 16) }?.isUnsupportedConfiguration == true)
        #expect(thrownError { _ = try report.stepResponse(count: 16) }?.isUnsupportedConfiguration == true)
        // Its responses are functions of radians per second, and of hertz through `Frequency`.
        let direct = try stable.frequencyResponse(at: [2 * .pi * 100])[0]
        #expect(try report.frequencyResponse(at: [2 * .pi * 100])[0] == direct)
        #expect(try report.frequencyResponse(at: [.hertz(100)])[0] == direct)
        expectClose(try #require(try report.groupDelay(at: [.hertz(0)])[0]), try #require(try stable.groupDelay(at: [0])[0]), .relative(1e-12))
    }

    @Test func linearPhaseIsReadFromTheTaps() throws {
        func isLinear(_ system: some LTISystem) throws -> Bool { try SystemAnalysis.analyse(system, sampleRate: 48_000).isLinearPhase }
        // Symmetric and antisymmetric taps, of odd and of even length.
        #expect(try isLinear(FIRSystem { Taps([1, 2, 3, 2, 1]) }) && isLinear(FIRSystem { Taps([1, 2, 2, 1]) }))
        #expect(try isLinear(FIRSystem { Taps([1, 2, 0, -2, -1]) }) && isLinear(FIRSystem { Taps([1, -1]) }))
        // A delay in front, or zeros behind, change nothing about the phase being linear.
        #expect(try isLinear(FIRSystem { Taps([0, 0, 1, 2, 1, 0]) }) && isLinear(FIRSystem { Taps([1]) }))
        #expect(try !isLinear(FIRSystem { Taps([1, 2, 3]) }) && !isLinear(FIRSystem { Taps([1, 0.5, 0.2]) }))
        // The designed filters are linear-phase; a minimum-phase filter is not.
        #expect(try isLinear(FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 63) }))
        #expect(try isLinear(FIRSystem { BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 101) }))
        // Coefficients whose denominator is a power of z are taps.
        #expect(try isLinear(TransferFunction.differenceEquation(b: [1, 2, 1], a: [1])))
        #expect(try isLinear(TransferFunction(numerator: [1, 0, -1], denominator: [1, 0, 0, 0], domain: .digital)))
        // An IIR system of zeros alone has a finite impulse response; its phase is linear when its taps are symmetric.
        let zeros = try SystemAnalysis.analyse(IIRSystem { Zero(onUnitCircleAt: .hertz(12_000)); Zero(at: Complex(-1)) }, sampleRate: 48_000)
        #expect(zeros.kind == .finiteImpulseResponse && zeros.isLinearPhase && zeros.taps == nil && zeros.sections?.sections.count == 2)
        #expect(try !isLinear(IIRSystem { Zero(at: Complex(0.5)) }))
        // Nothing with a pole away from the origin has linear phase.
        #expect(try !isLinear(IIRSystem { LowPass(.bessel(), cutoff: .hertz(1_000), order: 4) }))
        // A report on taps: finite, every pole at the origin, the group delay (K − 1) / 2.
        let fir = try SystemAnalysis.analyse(FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 63) }, sampleRate: 48_000)
        #expect(fir.kind == .finiteImpulseResponse && fir.order == 62 && fir.poles.allSatisfy { $0 == .zero } && fir.stabilityMargin == 1 && fir.isStable)
        #expect(fir.taps?.count == 63 && fir.sections == nil && fir.singleVersusDoubleDeviation == nil && fir.recommendedPrecision == .single)
        expectClose(try #require(try fir.groupDelay(at: [.hertz(1_000)])[0]), 31.0, .absolute(1e-9))
        #expect(!fir.isMinimumPhase, "a linear-phase low-pass has zeros outside the unit circle")
    }

    @Test func theRoundOffGainIsTheEnergyOfWhatFollowsEachSummingNode() throws {
        // One pole at a: 1 / (1 − a·z⁻¹), whose impulse response has the energy 1 / (1 − a²).
        let unit = 20 * log10(pow(2.0, -24))
        for a in [0.5, 0.9, 0.999] {
            let report = try SystemAnalysis.analyse(IIRSystem { Pole(at: Complex(a)) }, sampleRate: 48_000)
            expectClose(try #require(report.roundOffNoiseGain(precision: .single)), 10 * log10(1 / (1 - a * a)) + unit, .absolute(1e-4), "a pole at \(a)")
        }
        // Two sections: the node of the first is followed by the second, the node of the second by nothing.
        let first = SecondOrderSections.Section(b0: 1, b1: 0, b2: 0, a1: -0.5, a2: 0), second = SecondOrderSections.Section(b0: 1, b1: 0.5, b2: 0, a1: 0.25, a2: 0)
        let cascade = SecondOrderSections(sections: [first, second])
        let realised = cascade.spreadingGain().biquadSections
        // G₁ = 1/(1 − 0.5z⁻¹) · s·(1 + 0.5z⁻¹)/(1 + 0.25z⁻¹), G₂ = 1/(1 + 0.25z⁻¹): by their impulse responses.
        func energy(_ sections: [SecondOrderSections.Section]) -> Double {
            cascadeReference(TestSignal.impulse(count: 400), SecondOrderSections(sections: sections)).map { $0 * $0 }.reduce(0, +)
        }
        let scale = realised[1].b0
        let expected = energy([.init(b0: 1, b1: 0, b2: 0, a1: -0.5, a2: 0), .init(b0: scale, b1: 0.5 * scale, b2: 0, a1: 0.25, a2: 0)]) + energy([.init(b0: 1, b1: 0, b2: 0, a1: 0.25, a2: 0)])
        expectClose(try RoundOffNoise.powerGain(of: realised, checkpoint: nil), expected, .relative(1e-6))
        // Taps have no recursion: a round-off at the output is there once.
        let fir = try SystemAnalysis.analyse(FIRSystem { Taps([0.25, 0.5, 0.25]) }, sampleRate: 48_000)
        expectClose(try #require(fir.roundOffNoiseGain(precision: .single)), unit, .absolute(1e-9))
        expectClose(try #require(fir.roundOffNoiseGain(precision: .double)), 20 * log10(pow(2.0, -53)), .absolute(1e-9))
        // A system that is not stable is not run: no figure.
        let unstable = try SystemAnalysis.analyse(IIRSystem { Pole(at: Complex(1.1)) }, sampleRate: 48_000)
        #expect(!unstable.isStable && unstable.roundOffNoiseGain() == nil && unstable.singleVersusDoubleDeviation == nil && unstable.stabilityMargin < 0)
        expectClose(try #require(thrownError { _ = try unstable.impulseResponse(count: 8) }?.unstableRadius), 1.1, .absolute(1e-12))
    }

    @Test func aPoleOnTheUnitCircleIsNotStableInEveryForm() throws {
        // A pair written onto the unit circle is reported there, not a rounding error to either side of it.
        let section = SecondOrderSections(sections: [.init(b0: 1, b1: 0, b2: 0, a1: -2 * cos(0.3), a2: 1)])
        let report = try SystemAnalysis.analyse(section, sampleRate: 48_000)
        #expect(!report.isStable && report.stabilityMargin == 0)
        let system = try SystemAnalysis.analyse(IIRSystem { Pole(radius: 1, frequency: .radiansPerSample(0.3)) }, sampleRate: 48_000)
        #expect(!system.isStable && system.stabilityMargin == 0)
    }
}

/// WP-430 (the part that needs the kernels) and WP-428b: the time responses of a report, by
/// running the realised kernels offline, so that analysis and execution cannot disagree.
@Suite("System analysis: impulse and step responses")
struct SystemAnalysisTimeResponseTests {
    @Test func theImpulseResponseIsWhatThePipelineRuns() throws {
        let hum = IIRSystem {
            Zero(onUnitCircleAt: .hertz(50))
            Pole(radius: 0.985, frequency: .hertz(50))
            HighPass(.butterworth, cutoff: .hertz(30), rollOff: .decibelsPerOctave(12))
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
        }
        let report = try SystemAnalysis.analyse(hum, sampleRate: 48_000)
        let impulse = try report.impulseResponse(count: 2_048)
        // Bit for bit what a pipeline with the same system produces.
        #expect(impulse == (try Pipeline { Filter(hum) }.process(TestSignal.impulse(count: 2_048), format: SignalFormat(sampleRate: 48_000))))
        // And the recurrence of the reported cascade, to the accuracy of the kernel.
        let sections = try #require(report.sections)
        expectClose(impulse, cascadeReference(TestSignal.impulse(count: 2_048), sections), .deviationBelow(decibels: -120))
        // The step response is the running sum of the impulse response.
        let step = try report.stepResponse(count: 2_048)
        var sum = 0.0
        let summed = cascadeReference(TestSignal.impulse(count: 2_048), sections).map { value -> Double in sum += value; return sum }
        expectClose(step, summed, .deviationBelow(decibels: -100))
        #expect(step == (try Pipeline { Filter(hum) }.process(TestSignal.step(count: 2_048), format: SignalFormat(sampleRate: 48_000))))
        // Counts.
        #expect(try report.impulseResponse(count: 0).isEmpty && report.stepResponse(count: 1).count == 1)
        #expect(thrownError { _ = try report.impulseResponse(count: -1) }?.invalidParameterName == "count")
    }

    @Test func theResponsesOfTapsAreTheTapsAndTheirRunningSum() throws {
        let system = FIRSystem { Taps([0.25, 0.5, 0.25]); Taps([1, -1]) }
        let report = try SystemAnalysis.analyse(system, sampleRate: 48_000)
        #expect(try report.impulseResponse(count: 6) == [0.25, 0.25, -0.25, -0.25, 0, 0])
        #expect(try report.stepResponse(count: 6) == [0.25, 0.5, 0.25, 0, 0, 0])
        // Every representation that is digital has them: a design's roots, its sections, coefficients.
        let design = try IIRDesign(.butterworth, .lowPass(cutoff: 3_000), order: 3, domain: .digital(sampleRate: 48_000))
        let fromRoots = try SystemAnalysis.analyse(design.zeroPoleGain, sampleRate: 48_000).impulseResponse(count: 256)
        let fromSections = try SystemAnalysis.analyse(try design.secondOrderSections, sampleRate: 48_000).impulseResponse(count: 256)
        let fromCoefficients = try SystemAnalysis.analyse(try design.transferFunction, sampleRate: 48_000).impulseResponse(count: 256)
        let reference = cascadeReference(TestSignal.impulse(count: 256), try design.secondOrderSections)
        expectClose(fromRoots, reference, .deviationBelow(decibels: -110))
        expectClose(fromSections, reference, .deviationBelow(decibels: -110))
        expectClose(fromCoefficients, reference, .deviationBelow(decibels: -90), "roots found from coefficients carry their condition")
        // Coefficients with a delay keep it: z⁻² · 0.5.
        let delayed = try SystemAnalysis.analyse(TransferFunction(numerator: [0.5], denominator: [1, 0, 0], domain: .digital), sampleRate: 48_000)
        #expect(try delayed.impulseResponse(count: 4) == [0, 0, 0.5, 0] && delayed.kind == .finiteImpulseResponse)
        // A step into a low-pass arrives at the gain at 0 Hz.
        let settled = try SystemAnalysis.analyse(design.zeroPoleGain, sampleRate: 48_000).stepResponse(count: 2_000)
        expectClose(try #require(settled.last), 1, .absolute(1e-5))
    }

    @Test func theResponsesInHertzAreThoseInRadiansPerSample() throws {
        let design = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 4, domain: .digital(sampleRate: 48_000))
        let report = try SystemAnalysis.analyse(design.zeroPoleGain, sampleRate: 48_000)
        let hertz = [0.0, 100, 2_000, 3_500, 5_000, 12_000, 24_000]
        let omega = hertz.map { 2 * Double.pi * $0 / 48_000 }
        let frequencies = hertz.map { Frequency.hertz($0) }
        #expect(try report.frequencyResponse(at: frequencies) == report.frequencyResponse(at: omega))
        #expect(try report.magnitudeResponse(at: frequencies, in: .decibels) == report.magnitudeResponse(at: omega, in: .decibels))
        #expect(try report.magnitudeResponse(at: frequencies) == report.magnitudeResponse(at: omega))
        #expect(try report.phaseResponse(at: frequencies, unwrapped: true) == report.phaseResponse(at: omega, unwrapped: true))
        #expect(try report.phaseResponse(at: frequencies) == report.phaseResponse(at: omega))
        #expect(try report.groupDelay(at: frequencies) == report.groupDelay(at: omega))
        // Other units resolve against the report's sample rate.
        #expect(try report.frequencyResponse(at: [.fractionOfNyquist(0.5), .normalized(0.25), .radiansPerSample(.pi / 2)]) == report.frequencyResponse(at: [.hertz(12_000), .hertz(12_000), .hertz(12_000)]))
        // The report's response is the design's, from the sections that run.
        expectResponseClose(try report.frequencyResponse(at: omega), try design.zeroPoleGain.frequencyResponse(at: omega), relativeToPeak: 1e-10, "report against design")
        #expect(thrownError { _ = try report.frequencyResponse(at: [Frequency.hertz(.nan)]) } != nil)
        #expect(thrownError { _ = try report.frequencyResponse(at: [Double.infinity]) }?.invalidParameterName == "frequencies")
        #expect(thrownError { _ = try report.groupDelay(at: [Double.nan]) }?.invalidParameterName == "frequencies")
    }
}

/// A system written outside the package: it supplies its roots and nothing else, and records
/// where it was asked for them.
private struct OutsideSystem: LTISystem {
    let witness: Witness

    final class Witness: @unchecked Sendable {
        // Threading: written by the thread that analyses, read by the test afterwards.
        var onMainThread = false
        var onBackgroundExecutor = false
        var reads = 0
    }

    var domain: SystemDomain { .digital }
    var zeros: [Complex] {
        witness.reads += 1
        if Thread.isMainThread { witness.onMainThread = true }
        if BackgroundWork.isCurrent { witness.onBackgroundExecutor = true }
        return [Complex(-1)]
    }
    var poles: [Complex] { [Complex(0.5)] }
    var gain: Double { 0.25 }
}

/// WP-439. Asynchronous entry points for system analysis on `BackgroundWork` (BG-1).
/// Acceptance: runs off the main thread; can be cancelled; the result is an immutable value.
@Suite("System analysis: the asynchronous entry point (WP-439)")
struct SystemAnalysisAsyncTests {
    @Test @MainActor func theAnalysisRunsOffTheMainThread() async throws {
        let witness = OutsideSystem.Witness()
        let report = try await OutsideSystem(witness: witness).analysis(sampleRate: 48_000)
        #expect(witness.reads >= 1 && !witness.onMainThread && witness.onBackgroundExecutor, "the work ran on the background executor (BG-1)")
        // A conformer that supplies its roots alone gets the whole report.
        #expect(report.zeros == [Complex(-1)] && report.poles == [Complex(0.5)] && report.gain == 0.25)
        #expect(report.isStable && report.stabilityMargin == 0.5 && report.sections?.sections.count == 1)
        expectClose(try report.magnitudeResponse(at: [.hertz(0)])[0], 1.0, .absolute(1e-12))
        #expect(try report.impulseResponse(count: 3) == [0.25, 0.375, 0.1875])
        // The export runs there too.
        let script = try await report.matlabScript()
        #expect(script.contains("z = [") && Thread.isMainThread)
    }

    @Test func theResultIsAnImmutableValue() async throws {
        let hum = IIRSystem { Zero(onUnitCircleAt: .hertz(50)); Pole(radius: 0.985, frequency: .hertz(50)) }
        let first = try await hum.analysis(sampleRate: 48_000)
        let second = try await hum.analysis(sampleRate: 48_000)
        // Equal systems, equal reports: a report is a value (BG-2), and it crosses tasks.
        #expect(first == second && first.hashValue == second.hashValue)
        let other = try await hum.analysis(sampleRate: 44_100)
        #expect(first != other && other.sampleRate == 44_100)
        let moved = await Task.detached { first }.value
        #expect(moved == first)
        // The same report from the synchronous work the entry point wraps.
        #expect(first == (try SystemAnalysis.analyse(hum, sampleRate: 48_000)))
        // Every representation has the entry point.
        let design = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate: 48_000))
        let viaRoots = try await design.zeroPoleGain.analysis(sampleRate: 48_000)
        let viaSections = try await design.secondOrderSections.analysis(sampleRate: 48_000)
        let viaCoefficients = try await design.transferFunction.analysis(sampleRate: 48_000)
        let viaTaps = try await FIRSystem { Taps([1, 1]) }.analysis(sampleRate: 48_000)
        let viaReport = try await viaRoots.analysis(sampleRate: 48_000)
        #expect(viaRoots.order == 4 && viaSections.order == 4 && viaCoefficients.order == 4 && viaTaps.order == 1 && viaReport.order == 4)
        #expect(viaCoefficients.rootConditions.largest != nil && viaRoots.rootConditions.largest == nil)
        // Errors are typed and arrive through the await.
        #expect(await thrownErrorAsync { _ = try await hum.analysis(sampleRate: 0) }?.invalidParameterName == "sampleRate")
        #expect(await thrownErrorAsync { _ = try await hum.analysis(sampleRate: 80) }?.invalidParameterName == "frequency")
        let long = FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 601) }
        #expect(await thrownErrorAsync { _ = try await long.analysis(sampleRate: 48_000) }?.isUnsupportedConfiguration == true, "roots are found up to degree 512 (§6.3.8)")
    }

    /// What a task failed with, when it failed with a `DSPError`.
    private func failure<Value: Sendable>(of task: Task<Value, any Error>) async -> DSPError? {
        switch await task.result {
        case .success: nil
        case .failure(let error): error as? DSPError
        }
    }

    @Test func aCancelledCallThrowsCancelled() async throws {
        let system = IIRSystem { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
        // Cancelled before it starts: the work does not run.
        let early = Task { () async throws -> SystemAnalysis in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await system.analysis(sampleRate: 48_000)
        }
        let earlyFailure = await failure(of: early)
        #expect(earlyFailure?.isCancelled == true, "\(String(describing: earlyFailure))")
        // Cancelled while it runs: eight notches whose poles lie within 10⁻⁷ of the unit
        // circle ring for longer than the 2²² samples the round-off figure sums at most, per
        // section: seconds of work, stopped at a checkpoint between two of its steps (BG-3).
        let slow = IIRSystem {
            for index in 0 ..< 8 {
                Zero(onUnitCircleAt: .hertz(1_000 + 500 * Double(index)))
                Pole(radius: 0.9999999, frequency: .hertz(1_000 + 500 * Double(index)))
            }
        }
        let started = Date()
        let late = Task { () async throws -> SystemAnalysis in try await slow.analysis(sampleRate: 48_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        late.cancel()
        let lateFailure = await failure(of: late)
        let elapsed = Date().timeIntervalSince(started)
        Measurements.shared.record("WP-439 seconds from the call to `cancelled`, for an analysis cancelled 30 ms in", elapsed, bound: 5)
        // That it ended as cancelled is the evidence that it stopped at a checkpoint: run to
        // its end it would have returned its analysis. The time is recorded, not asserted, since
        // a busy machine stretches it.
        #expect(lateFailure?.isCancelled == true, "\(String(describing: lateFailure))")
        // The export is cancelled the same way.
        let report = try await system.analysis(sampleRate: 48_000)
        let export = Task { () async throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await report.matlabScript()
        }
        let exportFailure = await failure(of: export)
        #expect(exportFailure?.isCancelled == true, "\(String(describing: exportFailure))")
        // Not cancelled, the same call returns.
        #expect(thrownError { _ = try SystemAnalysis.analyse(system, sampleRate: 48_000, checkpoint: nil) } == nil)
    }
}

/// A MATLAB script read back: what each line assigns, or the line itself.
private enum ScriptLine: Equatable {
    /// `name = value;` or `name = [values];`. A complex vector has imaginary parts.
    case assignment(name: String, real: [Double], imaginary: [Double]?)
    case statement(String)

    var name: String? {
        if case .assignment(let name, _, _) = self { return name }
        return nil
    }

    /// One number as MATLAB writes it: a real, or `a+bi` / `a-bi`.
    private static func number(_ text: Substring) -> (real: Double, imaginary: Double?)? {
        if !text.hasSuffix("i") { return Double(text).map { ($0, nil) } }
        let body = text.dropLast()
        // The sign that separates the parts: the last one that is not an exponent's and not the first character.
        var split: Substring.Index?
        var index = body.index(before: body.endIndex)
        while index > body.startIndex {
            let character = body[index], previous = body[body.index(before: index)]
            if (character == "+" || character == "-") && previous != "e" && previous != "E" { split = index; break }
            index = body.index(before: index)
        }
        guard let split, let real = Double(body[..<split]), let imaginary = Double(body[split...]) else { return nil }
        return (real, imaginary)
    }

    static func parse(_ text: String) -> [ScriptLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line -> ScriptLine in
            guard !line.hasPrefix("%"), let equals = line.range(of: " = "), line.hasSuffix(";") else { return .statement(String(line)) }
            let name = String(line[..<equals.lowerBound])
            var body = line[equals.upperBound...].dropLast()
            if body.hasPrefix("[") && body.hasSuffix("]") { body = body.dropFirst().dropLast() }
            let parts = body.split(separator: " ").map { number($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return .statement(String(line)) }
            let numbers = parts.compactMap { $0 }
            let isComplex = numbers.contains { $0.imaginary != nil }
            return .assignment(name: name, real: numbers.map(\.real), imaginary: isComplex ? numbers.map { $0.imaginary ?? 0 } : nil)
        }
    }
}

/// WP-440. MATLAB export of a system analysis (§6.14).
/// Acceptance: golden script; it runs under Octave in the generator environment.
///
/// The golden script, `Golden/system_analysis.m`, is written by
/// `Tests/Golden/generators/system_analysis_matlab.py` from SciPy's values for the same
/// system, and that generator runs it under GNU Octave when Octave is installed.
@Suite("System analysis: MATLAB export (WP-440)")
struct SystemAnalysisExportTests {
    /// The system of the golden script: a mains-hum notch, a rumble filter and one section, at 48 kHz.
    private static let hum = IIRSystem {
        Zero(onUnitCircleAt: .hertz(50))
        Pole(radius: 0.985, frequency: .hertz(50))
        HighPass(.butterworth, cutoff: .hertz(30), order: 2)
        Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
    }

    /// How far each variable may lie from the oracle's, relative to the variable's largest
    /// magnitude: the responses are computed in double precision from the same roots; the
    /// time responses come out of the realised kernels as `Float` (REAL-3: within −100 dB).
    private static let tolerances: [String: Double] = [
        "sample_rate": 0, "z": 1e-12, "p": 1e-12, "k": 1e-12, "f": 1e-12, "magnitude_db": 1e-10,
        "phase_rad": 1e-10, "group_delay": 1e-9, "n": 0, "impulse": 1e-5, "step": 1e-5,
    ]

    private static func goldenScript() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "system_analysis", withExtension: "m", subdirectory: "Golden"), "Golden/system_analysis.m is not in the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theScriptOfASystemIsTheGoldenScript() async throws {
        let script = try await Self.hum.analysis(sampleRate: 48_000).matlabScript()
        let actual = ScriptLine.parse(script), expected = ScriptLine.parse(try Self.goldenScript())
        try #require(actual.count == expected.count, "the script has \(actual.count) lines, the golden script \(expected.count)")
        var compared = 0
        for (index, (mine, golden)) in zip(actual, expected).enumerated() {
            switch (mine, golden) {
            case (.statement(let text), .statement(let goldenText)):
                // Comments and plot commands: the text itself.
                #expect(text == goldenText, "line \(index + 1)")
            case (.assignment(let name, let real, let imaginary), .assignment(let goldenName, let goldenReal, let goldenImaginary)):
                #expect(name == goldenName, "line \(index + 1)")
                let tolerance = try #require(Self.tolerances[name], "\(name) is not a variable of the golden script")
                try #require(real.count == goldenReal.count && (imaginary == nil) == (goldenImaginary == nil), "\(name): \(real.count) elements, the golden script has \(goldenReal.count)")
                let scale = zip(goldenReal, goldenImaginary ?? goldenReal.map { _ in 0 }).map { ($0 * $0 + $1 * $1).squareRoot() }.filter(\.isFinite).max() ?? 0
                var worst = 0.0
                for element in real.indices {
                    #expect(real[element].isNaN == goldenReal[element].isNaN, "\(name)(\(element + 1)): NaN in one script only")
                    guard !goldenReal[element].isNaN else { continue }
                    let difference = hypot(real[element] - goldenReal[element], (imaginary?[element] ?? 0) - (goldenImaginary?[element] ?? 0))
                    worst = max(worst, difference)
                }
                #expect(worst <= tolerance * scale, "\(name): \(worst) from the golden script, where \(tolerance * scale) is allowed")
                if tolerance > 0 { Measurements.shared.record("WP-440 \(name): deviation from the oracle's script, relative to the variable's peak", scale > 0 ? worst / scale : 0, bound: tolerance) }
                compared += 1
            default:
                Issue.record("line \(index + 1) is \(mine), the golden script has \(golden)")
            }
        }
        #expect(compared == Self.tolerances.count, "every variable of the golden script was compared")
    }

    /// The values a script assigns to a variable.
    private static func values(_ name: String, in lines: [ScriptLine]) -> [Double]? {
        for line in lines {
            if case .assignment(name, let real, _) = line { return real }
        }
        return nil
    }

    /// MAT-2: data first, then plots; core MATLAB only.
    private static func expectCoreCommandsOnly(_ script: String, _ label: String) {
        let commands = ["plot(", "semilogx(", "loglog(", "stem(", "imagesc(", "subplot(", "xlabel(", "ylabel(", "title(", "grid on;", "grid off;", "axis ", "axis(", "colorbar;", "hold on;", "hold off;"]
        let functions: Set<String> = ["real", "imag", "cos", "sin", "linspace", "pi"]
        let lines = ScriptLine.parse(script)
        var defined: Set<String> = []
        var plotting = false
        for (index, line) in lines.enumerated() {
            switch line {
            case .assignment(let name, _, _):
                #expect(!plotting, "\(label), line \(index + 1): \(name) is defined after the plots began")
                defined.insert(name)
            case .statement(let text):
                if text.hasPrefix("% ") {
                    #expect(index == 0, "\(label), line \(index + 1): a comment below the head")
                    continue
                }
                plotting = true
                #expect(commands.contains { text.hasPrefix($0) } && text.hasSuffix(";"), "\(label), line \(index + 1): '\(text)' is not a core plot command")
                // What a plotting command draws is a variable of the script, or a core function of one.
                guard ["plot(", "semilogx(", "stem("].contains(where: { text.hasPrefix($0) }) else { continue }
                let unquoted = text.split(separator: "'", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 0 }.map { String($0.element) }.joined()
                let words = unquoted.split(whereSeparator: { !($0.isLetter || $0 == "_") }).dropFirst().map(String.init)
                for word in words {
                    #expect(defined.contains(word) || functions.contains(word), "\(label), line \(index + 1): '\(word)' is neither a variable of the script nor a core function")
                }
            }
        }
        #expect(plotting && script.hasSuffix(";\n"), "\(label)")
        // Axis labels carry their units.
        #expect(script.contains("xlabel('Frequency (Hz)');") && script.contains("ylabel('Magnitude (dB)');") && script.contains("ylabel('Phase (rad)');"), "\(label)")
    }

    @Test func aScriptIsDataThenCorePlotCommands() async throws {
        let digital = try await Self.hum.analysis(sampleRate: 48_000).matlabScript()
        Self.expectCoreCommandsOnly(digital, "IIR")
        let taps = try await FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 31) }.analysis(sampleRate: 48_000).matlabScript()
        Self.expectCoreCommandsOnly(taps, "FIR")
        let analog = try await IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(40)), .lowPass(cutoff: 2 * .pi * 1_000), order: 5, domain: .analog).zeroPoleGain.analysis(sampleRate: 48_000).matlabScript()
        Self.expectCoreCommandsOnly(analog, "analog")
        let unstable = try await IIRSystem { Pole(radius: 1.01, frequency: .hertz(1_000)) }.analysis(sampleRate: 48_000).matlabScript()
        Self.expectCoreCommandsOnly(unstable, "not stable")
        // The package returns text and writes no file (MAT-5); the type exports through the protocol (MAT-1).
        let exportable: any MATLABExportable = try await Self.hum.analysis(sampleRate: 48_000)
        #expect(try await exportable.matlabScript() == digital)
    }

    @Test func equalAnalysesGiveEqualText() async throws {
        // MAT-4: no date and no machine name; two analyses made apart give the same text.
        let first = try await Self.hum.analysis(sampleRate: 48_000).matlabScript()
        let again = IIRSystem {
            Zero(onUnitCircleAt: .hertz(50))
            Pole(radius: 0.985, frequency: .hertz(50))
            HighPass(.butterworth, cutoff: .hertz(30), order: 2)
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
        }
        let second = try await again.analysis(sampleRate: 48_000).matlabScript()
        #expect(first == second)
        #expect(first.hasPrefix("% ZTronDSP system analysis: a digital system of order 6, infinite impulse response, stable.\nsample_rate = 48000;\n"))
        // Another rate is another script.
        let other = try await Self.hum.analysis(sampleRate: 44_100).matlabScript()
        #expect(other != first && other.contains("sample_rate = 44100;"))
        // The synchronous work the entry point wraps gives the same lines.
        #expect(try SystemAnalysis.analyse(Self.hum, sampleRate: 48_000).script().text == first)
    }

    @Test func theNumbersReadBackExactly() async throws {
        // MAT-3: 17 significant digits from a double and 9 from a single.
        let report = try await Self.hum.analysis(sampleRate: 48_000)
        let lines = ScriptLine.parse(try await report.matlabScript())
        let hertz = report.exportedFrequencies()
        let omega = hertz.map { 2 * Double.pi * $0 / 48_000 }
        #expect(hertz.count == SystemAnalysis.exportedFrequencyCount && hertz.first == 48_000.0 / 4_096 && hertz.last == 24_000)
        #expect(Self.values("f", in: lines) == hertz)
        #expect(Self.values("magnitude_db", in: lines) == (try report.magnitudeResponse(at: omega, in: .decibels)))
        #expect(Self.values("phase_rad", in: lines) == (try report.phaseResponse(at: omega, unwrapped: true)))
        #expect(Self.values("group_delay", in: lines) == (try report.groupDelay(at: omega).map { $0 ?? .nan }))
        #expect(Self.values("k", in: lines) == [report.gain] && Self.values("sample_rate", in: lines) == [48_000])
        #expect(Self.values("z", in: lines) == report.zeros.map(\.real) && Self.values("p", in: lines) == report.poles.map(\.real))
        let impulse = try #require(Self.values("impulse", in: lines)).map { Float($0) }, step = try #require(Self.values("step", in: lines)).map { Float($0) }
        #expect(impulse == (try report.impulseResponse(count: SystemAnalysis.exportedSampleCount)))
        #expect(step == (try report.stepResponse(count: SystemAnalysis.exportedSampleCount)))
        #expect(Self.values("n", in: lines) == (0 ..< 256).map { Double($0) })
        // Complex numbers keep both parts.
        guard case .assignment(_, _, let imaginary)? = lines.first(where: { $0.name == "p" }) else { Issue.record("p is not a variable"); return }
        #expect(imaginary == report.poles.map(\.imaginary))
    }

    @Test func anUndefinedGroupDelayIsWrittenAsNaN() async throws {
        // A low-pass has its zeros at z = −1, and the last exported frequency is the Nyquist frequency.
        let lowPass = IIRSystem { LowPass(.butterworth, cutoff: .hertz(8_000), order: 2) }
        let report = try await lowPass.analysis(sampleRate: 48_000)
        #expect(try report.groupDelay(at: [Double.pi])[0] == nil)
        let script = try await report.matlabScript()
        let lines = ScriptLine.parse(script)
        let delay = try #require(Self.values("group_delay", in: lines))
        #expect(delay.count == 512 && delay[511].isNaN && delay[..<511].allSatisfy(\.isFinite))
        // That is the only place a NaN appears (MAT-3), and nothing is infinite.
        #expect(script.components(separatedBy: "NaN").count == 2 && !script.contains("Inf"))
        let magnitude = try #require(Self.values("magnitude_db", in: lines))
        #expect(magnitude.allSatisfy(\.isFinite) && magnitude[511] == DSP.decibelFloor, "the response at a zero is the floor of the decibel scale (NUM-1), not −∞: \(magnitude[511]) dB")
        Self.expectCoreCommandsOnly(script, "NaN")
        // Taps with a zero at Nyquist say the same.
        let taps = try await FIRSystem { Taps([0.25, 0.5, 0.25]) }.analysis(sampleRate: 48_000).matlabScript()
        let tapLines = ScriptLine.parse(taps)
        let tapDelay = try #require(Self.values("group_delay", in: tapLines))
        #expect(tapDelay[511].isNaN && tapDelay[..<511].allSatisfy { abs($0 - 1) < 1e-9 })
        #expect(try #require(Self.values("impulse", in: tapLines)).prefix(4) == [0.25, 0.5, 0.25, 0])
        #expect(taps.hasPrefix("% ZTronDSP system analysis: a digital system of order 2, finite impulse response, stable.\n"))
        #expect(Self.values("p", in: tapLines) == [0, 0])
    }

    @Test func whatNoKernelRunsExportsWithoutTimeResponses() async throws {
        // An analog system: the half plane, radians per second inside, hertz on the axes.
        let design = try IIRDesign(.butterworth, .bandPass(from: 2 * .pi * 1_000, to: 2 * .pi * 3_000), order: 3, domain: .analog)
        let report = try await design.zeroPoleGain.analysis(sampleRate: 48_000)
        let script = try await report.matlabScript()
        let lines = ScriptLine.parse(script)
        #expect(script.hasPrefix("% ZTronDSP system analysis: a analog system of order 6, infinite impulse response, stable.\n") == false, "the head reads as a sentence")
        #expect(script.hasPrefix("% ZTronDSP system analysis: an analog system of order 6, infinite impulse response, stable.\n"))
        #expect(Self.values("impulse", in: lines) == nil && Self.values("step", in: lines) == nil && Self.values("n", in: lines) == nil)
        #expect(script.contains("subplot(2, 2, 4);") && !script.contains("subplot(3, 2") && !script.contains("linspace"))
        #expect(script.contains("ylabel('Group delay (s)');") && script.contains("title('Poles (x) and zeros (o)');"))
        // The frequencies span the roots: from a hundredth of the slowest to a hundred times the fastest.
        let hertz = try #require(Self.values("f", in: lines))
        let rates = (report.zeros + report.poles).map(\.magnitude).filter { $0 > 0 }
        expectClose(try #require(hertz.first), try #require(rates.min()) / (2 * .pi) / 100, .relative(1e-12))
        expectClose(try #require(hertz.last), try #require(rates.max()) / (2 * .pi) * 100, .relative(1e-12))
        // The magnitude is the design's own, at 2π·f radians per second: −3 dB at both edges.
        let magnitude = try #require(Self.values("magnitude_db", in: lines))
        #expect(magnitude == (try design.zeroPoleGain.magnitudeResponse(at: hertz.map { 2 * Double.pi * $0 }, in: .decibels)))
        let peak = try #require(magnitude.max())
        expectClose(peak, 0, .absolute(0.01), "the pass band of a Butterworth band-pass")
        // A digital system that is not stable is not run either.
        let unstable = try await IIRSystem { Pole(radius: 1.01, frequency: .hertz(1_000)) }.analysis(sampleRate: 48_000).matlabScript()
        #expect(unstable.hasPrefix("% ZTronDSP system analysis: a digital system of order 2, infinite impulse response, not stable.\n"))
        #expect(!unstable.contains("impulse = [") && !unstable.contains("stem(") && unstable.contains("subplot(2, 2, 1);") && unstable.contains("linspace"))
    }
}
