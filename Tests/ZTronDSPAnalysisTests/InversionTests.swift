import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `InvertibleStage` and `InversionReport` (WP-537), the report of `STFT` (WP-538), and the
/// reports of subsampling, `Decibels`, `Cepstrum` and `CepstralCoefficients` (WP-539).
@Suite("Inversion reports")
struct InversionTests {
    private let noise = TestSignal.gaussianNoise(count: 24_000, seed: 537, standardDeviation: 0.2)

    private func fixture(_ name: String) throws -> (samples: [Float], rate: Double) {
        let golden = try GoldenFile(named: "fixtures", in: .module).require(name)
        return (try golden.floats("samples"), try golden.number("sampleRate"))
    }

    // MARK: An exact pair (WP-537)

    @Test func theReportOfAnExactPairIsExact() async throws {
        let onBackground = Observed()
        let report = try await DSP.inversionReport(ofUpsampling: noise, by: 3, sampleRate: 44_100)
        #expect(report.stage == "Upsample" && report.inverse == "Subsample" && report.conditions.isEmpty && report.isExactlyInvertible, "no condition: every sample is kept")
        #expect(report.predictedError == 0)
        let measured = try #require(report.measuredError)
        #expect(measured.signalToNoiseRatio == .infinity && measured.largestError == 0 && measured.relativeError == 0 && measured.count == 24_000, "bit for bit")
        #expect(report.roundTrip?.original == noise && report.roundTrip?.reconstruction == noise && report.sampleRate == 44_100)
        await #expect(throws: DSPError.self) { _ = try await DSP.inversionReport(ofUpsampling: noise, by: 0) }

        // A stage outside the package gets the same report through the public protocol, and
        // its work runs on the background executor (BG-1).
        let own = try await Negate(probe: onBackground).inversionReport(for: noise, sampleRate: 48_000)
        #expect(own.stage == "Negate" && own.inverse == "Negate" && own.isExactlyInvertible && own.measuredError?.largestError == 0)
        #expect(own.conditions.map { $0.name } == ["an involution"] && onBackground.lengths == [1, 1], "conditions and round trip, both off the main thread")
        let bare = try await Negate(probe: nil).inversionReport()
        #expect(bare.measuredError == nil && bare.roundTrip == nil && bare.conditions.count == 1, "without a signal: the conditions alone")
    }

    @Test func aReportCanBeCancelledAndRefusesNonsense() async {
        let signal = noise
        let task = Task { try await STFT(frame: 2_048, hop: 512).inversionReport(for: signal + signal + signal + signal, sampleRate: 48_000) }
        task.cancel()
        let result = await task.result
        #expect(throws: DSPError.cancelled) { _ = try result.get() }
        await #expect(throws: DSPError.self) { _ = try await STFT(frame: 2_048, hop: 512).inversionReport(for: signal, sampleRate: 0) }
        await #expect(throws: DSPError.self) { _ = try await STFT(frame: 0, hop: 0).inversionReport() }
        await #expect(throws: DSPError.self) { _ = try await STFT(frame: 1_000, hop: 250).inversionReport(for: signal) }
    }

    @Test func aMeasurementIsWhatItsNameSays() {
        let exact = InversionMeasurement(InversionRoundTrip(original: [1, -2, 3], reconstruction: [1, -2, 3]))
        #expect(exact.signalToNoiseRatio == .infinity && exact.largestError == 0 && exact.relativeError == 0 && exact.count == 3)
        let off = InversionMeasurement(InversionRoundTrip(original: [1, -2, 3, 0], reconstruction: [1, -2, 2.7, 0, 9]))
        expectClose(off.largestError, 0.3, .absolute(1e-6))
        expectClose(off.relativeError, 0.1, .absolute(1e-6))
        expectClose(off.signalToNoiseRatio, 10 * log10(14 / 0.09), .absolute(1e-4))
        #expect(off.count == 4, "the longer array is cut to the shorter")
        // Frames are held against their own maximum (§6.1).
        let frames = InversionMeasurement(InversionRoundTrip(original: [10, 0, 0.1, 0.05], reconstruction: [10, 0.01, 0.1, 0.06], frameLength: 2))
        expectClose(frames.relativeError, 0.1, .absolute(1e-6), "0.01 against 0.1 in the second frame, not against 10")
        let empty = InversionMeasurement(InversionRoundTrip(original: [], reconstruction: []))
        #expect(empty.count == 0 && empty.signalToNoiseRatio == 0 && empty.largestError == 0)
        let silent = InversionMeasurement(InversionRoundTrip(original: [0, 0], reconstruction: [0, 0.5]))
        #expect(silent.relativeError == .infinity && silent.largestError == 0.5)
        let report = InversionReport(stage: "A", inverse: "B", conditions: [
            InversionCondition(name: "one", theorem: "", quantity: "", observed: 0, holds: true, margin: 1, predictedError: 0.25),
            InversionCondition(name: "two", theorem: "", quantity: "", observed: 0, holds: false, margin: -1, isNecessary: false, predictedError: 0.5),
            InversionCondition(name: "three", theorem: "", quantity: "", observed: 0, holds: true, margin: 1, predictedError: 0.5),
        ])
        #expect(report.predictedError == 1.25 && report.isExactlyInvertible && report.measuredError == nil, "the sum of what each accounts for")
    }

    // MARK: STFT (WP-538)

    @Test(arguments: [
        STFT(frame: 2_048, hop: 512), STFT(frame: 1_024, hop: 512, window: .hamming), STFT(frame: 1_024, hop: 256, window: .blackman, paddedTo: 2_048),
        STFT(frame: 2_048, hop: 512, window: .kaiser(beta: 8), normalization: .amplitude, alignment: .centered), STFT(frame: 512, hop: 512, window: .rectangular),
        STFT(frame: 1_024, hop: 700), STFT(frame: 1_024, hop: 900, window: .kaiser(beta: 4)),
    ])
    func thePredictedBoundOfAnSTFTIsAtOrAboveTheMeasuredErrorOnTheFixtures(stft: STFT) async throws {
        for name in ["speech", "music"] {
            let (samples, rate) = try fixture(name)
            let report = try await stft.inversionReport(for: samples, sampleRate: rate)
            let measured = try #require(report.measuredError)
            #expect(report.stage == "STFT" && report.inverse == "InverseSTFT" && report.isExactlyInvertible)
            #expect(report.predictedError >= measured.relativeError, "\(name): predicted \(report.predictedError), measured \(measured.relativeError) (SNR \(measured.signalToNoiseRatio) dB)")
            #expect(report.predictedError < 1e-2 && measured.signalToNoiseRatio > 80 && measured.count > 10_000)
            let nonZero = try #require(report.conditions.first { $0.name == "non-zero overlap-add" })
            #expect(nonZero.holds && nonZero.isNecessary && nonZero.margin > 0 && nonZero.observed <= 1 && nonZero.theorem.contains("Griffin & Lim"))
        }
    }

    @Test func theConditionsOfAnSTFTAreItsFrameBounds() async throws {
        let tight = try await STFT(frame: 1_024, hop: 256).inversionReport()
        #expect(tight.conditions.map { $0.name } == ["non-zero overlap-add", "constant overlap-add"] && tight.measuredError == nil)
        #expect(tight.conditions.allSatisfy { $0.holds } && tight.isExactlyInvertible)
        expectClose(tight.conditions[0].observed, 1, .absolute(1e-12), "a Hann window at a quarter-frame hop is a tight frame: A = B")
        expectClose(tight.predictedError, InversionRoundOff.transform(length: 1_024), .relative(1e-9))

        // Not constant, but non-zero: exactly invertible, with round-off amplified by B/A.
        let loose = try await STFT(frame: 1_024, hop: 700).inversionReport()
        let analysis = try await Window.hann.analysis(frame: 1_024, hop: 700)
        #expect(loose.isExactlyInvertible && loose.conditions[0].holds && !loose.conditions[1].holds && !loose.conditions[1].isNecessary)
        expectClose(1 / loose.conditions[0].observed, try #require(analysis.frameBoundRatio), .relative(1e-12), "the same B/A the window analysis reports")
        expectClose(loose.predictedError, InversionRoundOff.transform(length: 1_024) * (try #require(analysis.frameBoundRatio)), .relative(1e-9))
    }

    @Test func aFailingWindowIsReportedNotThrown() async throws {
        // A Hann window at a hop of one frame weighs the samples where frames meet by zero.
        let (samples, rate) = try fixture("music")
        let report = try await STFT(frame: 1_024, hop: 1_024).inversionReport(for: samples, sampleRate: rate)
        let nonZero = try #require(report.conditions.first)
        #expect(!nonZero.holds && nonZero.margin < 0 && !report.isExactlyInvertible && report.predictedError == 1, "the condition fails: reported (INV-3)")
        let measured = try #require(report.measuredError)
        #expect(measured.relativeError <= report.predictedError && measured.relativeError > 1e-3 && measured.signalToNoiseRatio < 60,
                "what the round trip loses is measured: \(measured.relativeError), SNR \(measured.signalToNoiseRatio) dB")
        // The pipeline itself refuses the pair (O-17); the report does not.
        #expect(throws: DSPError.self) { _ = try Pipeline { STFT(frame: 1_024, hop: 1_024); InverseSTFT() }.process(samples, format: SignalFormat(sampleRate: rate)) }
        let gapped = try await STFT(frame: 1_024, hop: 512, window: .custom { $0 < 0.25 ? 1 : 0 }).inversionReport(for: samples, sampleRate: rate)
        #expect(!gapped.isExactlyInvertible && gapped.conditions[0].observed == 0 && (gapped.measuredError?.signalToNoiseRatio ?? 99) < 10)
    }

    @Test func theReportFollowsWhatPrecedesTheStage() async throws {
        let (samples, rate) = try fixture("speech")
        let report = try await STFT(frame: 1_024, hop: 256).inversionReport(for: samples, sampleRate: rate, after: Pipeline { TestGain(0.5) })
        let original = try #require(report.roundTrip?.original)
        #expect(original == Array(samples[1_024 ..< 1_024 + original.count]).map { $0 * 0.5 }, "the round trip is measured on what arrives at the stage")
        #expect((report.measuredError?.signalToNoiseRatio ?? 0) > 100)
    }

    // MARK: Subsampling: the sampling theorem, tested on the signal (WP-539)

    @Test func aBandLimitedFixturePassesTheSamplingTheorem() async throws {
        // Tones below 0.8 of the Nyquist frequency after subsampling by 4: 6 kHz at 48 kHz.
        let signal = TestSignal.sum(TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 48_000, amplitude: 0.4),
                                    TestSignal.sine(frequency: 2_500, sampleRate: 48_000, count: 48_000, amplitude: 0.3, phase: 1),
                                    TestSignal.sine(frequency: 4_700, sampleRate: 48_000, count: 48_000, amplitude: 0.2, phase: 2))
        let report = try await DSP.inversionReport(ofSubsampling: signal, by: 4, sampleRate: 48_000)
        let condition = try #require(report.conditions.first)
        #expect(report.stage == "Subsample" && report.inverse == "Interpolate" && condition.name == "sampling theorem" && condition.theorem.contains("Shannon 1949"))
        #expect(condition.holds && report.isExactlyInvertible && condition.observed <= 1e-10 && condition.margin >= 0, "the share above 6 kHz is \(condition.observed)")
        let measured = try #require(report.measuredError)
        #expect(measured.signalToNoiseRatio > 100 && report.predictedError < 2e-5, "SNR \(measured.signalToNoiseRatio) dB, predicted \(report.predictedError)")
        // Every phase keeps other samples of the same band-limited signal.
        let shifted = try await DSP.inversionReport(ofSubsampling: signal, by: 4, phase: 3, sampleRate: 48_000)
        #expect(shifted.isExactlyInvertible && (shifted.measuredError?.signalToNoiseRatio ?? 0) > 100)
    }

    @Test(arguments: [(0.3, 0.3), (0.5, 0.05), (0.1, 0.4), (0.4, 0.002)])
    func anAliasingFixtureFailsWithTheAliasedEnergyWithinOneDecibel(inBand: Double, above: Double) async throws {
        // One tone in the band, one above the new Nyquist frequency of 6 kHz: its energy is what aliases.
        let signal = TestSignal.sum(TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 48_000, amplitude: inBand),
                                    TestSignal.sine(frequency: 9_000, sampleRate: 48_000, count: 48_000, amplitude: above, phase: 0.7))
        let truth = above * above / (inBand * inBand + above * above)
        let report = try await DSP.inversionReport(ofSubsampling: signal, by: 4, sampleRate: 48_000)
        let condition = try #require(report.conditions.first)
        #expect(!condition.holds && !report.isExactlyInvertible && condition.margin < 0, "the condition fails")
        let deviation = abs(10 * log10(condition.observed / truth))
        #expect(deviation <= 1, "aliased share \(condition.observed), truth \(truth): \(deviation) dB apart")
        // What is lost is the part above and its image: the measured error agrees with the prediction.
        let measured = try #require(report.measuredError)
        expectClose(report.predictedError, (2 * truth).squareRoot(), .relative(0.12))
        expectClose(pow(10, -measured.signalToNoiseRatio / 20), (2 * truth).squareRoot(), .relative(0.15), "measured: \(measured.signalToNoiseRatio) dB")
    }

    @Test func subsamplingByOneLosesNothing() async throws {
        let report = try await DSP.inversionReport(ofSubsampling: noise, by: 1, sampleRate: 48_000)
        #expect(report.isExactlyInvertible && report.conditions[0].observed == 0 && report.measuredError?.largestError == 0)
        await #expect(throws: DSPError.self) { _ = try await DSP.inversionReport(ofSubsampling: noise, by: 0) }
        await #expect(throws: DSPError.self) { _ = try await DSP.inversionReport(ofSubsampling: noise, by: 2, sampleRate: -1) }
        #expect(try SamplingTheorem.shareOfEnergy(of: [], atOrAbove: 0.25, checkpoint: nil) == 0)
        #expect(try SamplingTheorem.shareOfEnergy(of: noise, atOrAbove: 0, checkpoint: nil) == 1)
        expectClose(try SamplingTheorem.shareOfEnergy(of: noise, atOrAbove: 0.25, checkpoint: nil), 0.5, .absolute(0.03), "white noise: half its energy above a quarter of the rate")
    }

    // MARK: Decibels (WP-539)

    @Test func decibelsInvertWhereNoValueIsAtTheFloor() async throws {
        let (samples, rate) = try fixture("music")
        let power = Pipeline { STFT(frame: 1_024, hop: 512); Power() }
        let clean = try await Decibels().inversionReport(for: samples, sampleRate: rate, after: power)
        let condition = try #require(clean.conditions.first)
        #expect(clean.stage == "Decibels" && clean.inverse == "InverseDecibels" && condition.name == "values above the floor")
        #expect(condition.holds && condition.observed == 0 && clean.isExactlyInvertible, "nothing at −160 dB")
        let measured = try #require(clean.measuredError)
        #expect(measured.relativeError <= clean.predictedError && measured.relativeError < 1e-5, "predicted \(clean.predictedError), measured \(measured.relativeError)")
        #expect(clean.roundTrip?.frameLength == 513)

        // A floor inside the signal: the share of bins at it is reported, and they come back as the floor.
        let clamped = try await Decibels(floor: -20).inversionReport(for: samples, sampleRate: rate, after: power)
        let share = try #require(clamped.conditions.first)
        #expect(!share.holds && share.observed > 0.05 && share.observed < 1 && share.margin == -share.observed && !clamped.isExactlyInvertible)
        let lost = try #require(clamped.measuredError)
        #expect(lost.relativeError <= clamped.predictedError && lost.relativeError > 1e-4, "predicted \(clamped.predictedError), measured \(lost.relativeError)")
        // Magnitudes use the other exponent; without a signal there is no condition to evaluate.
        let magnitude = try await Decibels(reference: 2).inversionReport(for: samples, sampleRate: rate, after: Pipeline { STFT(frame: 1_024, hop: 512); Magnitude() })
        #expect(magnitude.isExactlyInvertible && (magnitude.measuredError?.relativeError ?? 1) < 1e-5)
        let bare = try await Decibels().inversionReport(after: power)
        #expect(bare.conditions.isEmpty && bare.measuredError == nil)
        #expect(Decibels(reference: 3).inverse(of: .power) == InverseDecibels(.power, reference: 3))
    }

    // MARK: Cepstrum (WP-539)

    @Test func theComplexCepstrumInvertsAndTheOthersDoNot() async throws {
        let (samples, rate) = try fixture("music")
        let stft = Pipeline { STFT(frame: 1_024, hop: 512) }
        let complex = try await Cepstrum(.complex).inversionReport(for: samples, sampleRate: rate, after: stft)
        #expect(complex.stage == "Cepstrum" && complex.inverse == "InverseCepstrum")
        #expect(complex.conditions.map { $0.name } == ["the phase is kept", "a finite log spectrum", "a phase unwrapped without ambiguity"])
        #expect(complex.conditions[0].holds && complex.conditions[1].holds && complex.conditions[1].margin > 0 && complex.isExactlyInvertible)
        #expect(!complex.conditions[2].isNecessary && complex.conditions[2].observed >= 0 && complex.conditions[2].observed <= .pi)
        let measured = try #require(complex.measuredError)
        #expect(measured.relativeError <= complex.predictedError && measured.relativeError <= 1e-5, "predicted \(complex.predictedError), measured \(measured.relativeError)")
        #expect(complex.roundTrip?.frameLength == 2 * 513)

        for kind in [CepstrumKind.real, .power] {
            let report = try await Cepstrum(kind).inversionReport(for: samples, sampleRate: rate, after: stft)
            #expect(!report.conditions[0].holds && !report.isExactlyInvertible && report.predictedError >= 1 && report.measuredError == nil, "the phase is discarded: reported, not thrown")
        }
        let bare = try await Cepstrum(.complex).inversionReport()
        #expect(bare.conditions.count == 1 && bare.isExactlyInvertible && bare.measuredError == nil)
    }

    @Test func binsAtTheFloorOfTheLogarithmAreCounted() async throws {
        // The speech fixture pauses: whole frames of silence, every bin at the floor.
        let (samples, rate) = try fixture("speech")
        let report = try await Cepstrum(.complex).inversionReport(for: samples, sampleRate: rate, after: Pipeline { STFT(frame: 256, hop: 256) })
        let finite = report.conditions[1]
        #expect(!finite.holds && finite.margin <= 0 && finite.quantity.contains("bins are at the floor") && !report.isExactlyInvertible)
        // A floor inside a frame's spectrum loses what lies below it, relative to that frame's maximum.
        let raised = try await Cepstrum(.complex, floor: 0.5).inversionReport(for: samples, sampleRate: rate, after: Pipeline { STFT(frame: 1_024, hop: 512) })
        let measured = try #require(raised.measuredError)
        #expect(!raised.conditions[1].holds && raised.predictedError > 1e-3 && measured.relativeError <= raised.predictedError,
                "predicted \(raised.predictedError), measured \(measured.relativeError)")
    }

    // MARK: Cepstral coefficients (WP-539)

    @Test func cepstralCoefficientsInvertAtFullRank() async throws {
        let (samples, rate) = try fixture("speech")
        let mel = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 40); Decibels() }
        let full = try await CepstralCoefficients(count: 40).inversionReport(for: samples, sampleRate: rate, after: mel)
        let rank = try #require(full.conditions.first)
        #expect(full.stage == "CepstralCoefficients" && full.inverse == "InverseCepstralCoefficients" && rank.name == "full rank")
        #expect(rank.holds && rank.margin == 0 && rank.observed == 0 && full.isExactlyInvertible)
        let measured = try #require(full.measuredError)
        #expect(measured.relativeError <= full.predictedError && measured.relativeError < 1e-5, "predicted \(full.predictedError), measured \(measured.relativeError)")

        // Thirteen of forty: the energy of the dropped coefficients is what the conditions predict, and what is measured.
        let truncated = try await CepstralCoefficients(count: 13).inversionReport(for: samples, sampleRate: rate, after: mel)
        let dropped = try #require(truncated.conditions.first)
        #expect(!dropped.holds && dropped.margin == -27 && !truncated.isExactlyInvertible && dropped.quantity.contains("13 of 40"))
        let lost = try #require(truncated.measuredError)
        expectClose(pow(10, -lost.signalToNoiseRatio / 20), truncated.predictedError, .relative(0.01), "the share of the energy that is gone")
        #expect(truncated.predictedError > 0.01 && truncated.predictedError < 1)

        // Without a signal the bands are still known from the pipeline; without the pipeline they are not.
        let bare = try await CepstralCoefficients(count: 13).inversionReport(sampleRate: rate, after: mel)
        #expect(bare.conditions.first?.holds == false && bare.measuredError == nil && bare.predictedError == 1)
        await #expect(throws: DSPError.self) { _ = try await CepstralCoefficients(count: 13).inversionReport(for: samples, sampleRate: rate) }
    }
}

/// A stage written against the public API, with its inverse and its report (INV-1).
struct Negate: SequenceStage, InvertibleStage {
    let probe: Observed?

    static func == (lhs: Negate, rhs: Negate) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.gain(factor: -1, ramp: 0))
    }

    var inverse: Negate { self }

    func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        if BackgroundWork.isCurrent && !Thread.isMainThread { probe?.note(1) }
        return [InversionCondition(name: "an involution", theorem: "−(−x) = x", quantity: "nothing to measure", observed: 0, holds: true, margin: 0)]
    }

    func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil else { return nil }
        if BackgroundWork.isCurrent && !Thread.isMainThread { probe?.note(1) }
        try context.check()
        return InversionRoundTrip(original: try context.samples(), reconstruction: try context.samples(after: stageDescriptions + inverse.stageDescriptions))
    }
}
