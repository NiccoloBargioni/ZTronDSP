import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// What every stage of the target owes besides its values (STG-1): a cold start that is one
/// (ACT-10), the latency and the settling time its node states, and a typed refusal where it
/// is lowered without the scope it needs.
@Suite("Cold starts, latency and settling")
struct ColdStartTests {
    /// 3 000 samples are not a whole number of hops, frames, stretches or blocks below: a plan
    /// that kept its state would frame a second pass differently.
    private let noise = TestSignal.whiteNoise(count: 3_000, seed: 77, amplitude: 0.5)

    /// After a cold start a plan gives, for the same samples, the frames of a fresh stream:
    /// values and times. Without one it gives another stream, or the check would pass for a
    /// reset that does nothing.
    private func expectAFreshStream<D: SignalDomain>(
        after pipeline: Pipeline<Samples, D>, on samples: [Float], _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let cold = try twoPasses(of: pipeline, on: samples, coldStart: true)
        let warm = try twoPasses(of: pipeline, on: samples, coldStart: false)
        func repeats<T: Equatable>(_ values: [T]) -> Bool {
            values.count % 2 == 0 && Array(values[..<(values.count / 2)]) == Array(values[(values.count / 2)...])
        }
        #expect(cold.frameCount >= 2, "\(name): \(cold.frameCount) frames in two passes", sourceLocation: sourceLocation)
        #expect(repeats(cold.times) && repeats(cold.blockLengths), "\(name): the second pass has the times of a fresh stream", sourceLocation: sourceLocation)
        #expect(repeats(cold.reals) && repeats(cold.imaginaries) && repeats(cold.minima) && repeats(cold.maxima) && repeats(cold.scalars) && repeats(cold.samples),
                "\(name): the second pass has the values of a fresh stream", sourceLocation: sourceLocation)
        #expect(warm.reals != cold.reals || warm.imaginaries != cold.imaginaries || warm.scalars != cold.scalars || warm.samples != cold.samples
                || warm.maxima != cold.maxima || warm.times != cold.times, "\(name): without a cold start the second pass is another stream", sourceLocation: sourceLocation)
    }

    // MARK: Cold starts (ACT-10)

    @Test func framingStartsAgainFromNothing() throws {
        // Centred framing reflects the first half frame again; causal framing waits for a whole frame again.
        try expectAFreshStream(after: Pipeline { STFT(frame: 256, hop: 64, alignment: .centered) }, on: noise, "a centred STFT")
        try expectAFreshStream(after: Pipeline { STFT(frame: 256, hop: 64) }, on: noise, "a causal STFT")
        try expectAFreshStream(after: Pipeline { STFT(frame: 240, hop: 100, window: .hamming, paddedTo: 256, normalization: .power) }, on: noise, "a padded STFT")
    }

    @Test func synthesisBeginsWithItsDelayAgain() throws {
        // The output of a round trip begins with frame − hop zeros: after a cold start it does so again.
        let roundTrip = Pipeline { STFT(frame: 256, hop: 64); InverseSTFT() }
        try expectAFreshStream(after: roundTrip, on: noise, "STFT and InverseSTFT")
        let cold = try twoPasses(of: roundTrip, on: noise, coldStart: true)
        let half = cold.samples.count / 2
        #expect(half > 192 && cold.samples[..<192].allSatisfy { $0 == 0 } && cold.samples[half ..< half + 192].allSatisfy { $0 == 0 })
        #expect(cold.samples[half + 192 ..< half + 256].contains { $0 != 0 }, "and then the signal")
        let centred = STFT(frame: 256, hop: 64, alignment: .centered)
        try expectAFreshStream(after: Pipeline { centred; centred.inverse }, on: noise, "a centred round trip")
    }

    @Test func levelsAndWaveformsStartTheirWindowsAgain() throws {
        try expectAFreshStream(after: Pipeline { Level(.rms, window: 0.004, hop: 0.001) }, on: noise, "Level(.rms)")
        try expectAFreshStream(after: Pipeline { Level(.peak, window: 0.004, hop: 0.001) }, on: noise, "Level(.peak)")
        try expectAFreshStream(after: Pipeline { Waveform(resolution: 0.001) }, on: noise, "Waveform")
    }

    @Test func aCentroidForgetsItsLastValue() throws {
        // Silence, then noise: the frames of silence have no centroid and repeat the last
        // value there was, which before the first, and after a cold start, is 0.
        let signal = TestSignal.silence(count: 700) + Array(noise[700...])
        let pipeline = Pipeline { STFT(frame: 256, hop: 64); Magnitude(); SpectralCentroid() }
        try expectAFreshStream(after: pipeline, on: signal, "SpectralCentroid")
        let cold = try twoPasses(of: pipeline, on: signal, coldStart: true)
        let half = cold.scalars.count / 2
        #expect(cold.scalars[half - 1].confidence == 1 && cold.scalars[half - 1].value > 1_000, "the first pass ends on a centroid")
        #expect(cold.scalars[half ..< half + 7].allSatisfy { $0.confidence == 0 && $0.value == 0 }, "and the second begins without one: \(cold.scalars[half ..< half + 7])")
    }

    @Test func aPitchForgetsItsLastValue() throws {
        let tone = TestSignal.harmonic(fundamental: 220, amplitudes: (1 ... 12).map { 0.3 / Double($0) }, sampleRate: 48_000, count: 4_500)
        let signal = TestSignal.silence(count: 1_500) + tone
        let pipeline = Pipeline { STFT(frame: 1_024, hop: 256); Cepstrum(); CepstralPitch(range: .hertz(100 ... 1_000)) }
        try expectAFreshStream(after: pipeline, on: signal, "CepstralPitch")
        let cold = try twoPasses(of: pipeline, on: signal, coldStart: true)
        let half = cold.scalars.count / 2
        let last = cold.scalars[half - 1]
        #expect(abs(last.value - 220) < 3, "the first pass ends on a pitch: \(last.value) Hz")
        #expect(last.confidence > 0)
        let head = Array(cold.scalars[half ..< half + 2])
        #expect(head.allSatisfy { $0.confidence == 0 && $0.value == 0 }, "and the second begins without one")
    }

    @Test func stepsThatKeepNothingAreUnchangedByAColdStart() throws {
        // One frame in, one frame out: the frames after a cold start are those of the framing before them.
        let framing = Pipeline { STFT(frame: 1_024, hop: 256) }
        let chains: [(String, Pipeline<Samples, Spectrum<MelFrequency, PowerValues>>)] = [
            ("the mel chain", framing.power().melScale(bands: 40).decibels().cepstralCoefficients(count: 13).inverseCepstralCoefficients(bands: 40).inverseDecibels(.power)),
            ("the dense mel chain", framing.power().melScale(bands: 40).environment(\.implementation, .accelerate)
                .decibels().cepstralCoefficients(count: 40).inverseCepstralCoefficients(bands: 40).inverseDecibels(.power)),
            ("a basis that is not a fast length", framing.power().melScale(bands: 30).decibels().cepstralCoefficients(count: 13).inverseCepstralCoefficients(bands: 30)
                .inverseDecibels(.power)),
            ("a band count vDSP transforms", framing.power().melScale(bands: 64).decibels().cepstralCoefficients(count: 20).inverseCepstralCoefficients(bands: 64)
                .inverseDecibels(.power)),
        ]
        for (name, chain) in chains { try expectAFreshStream(after: chain, on: noise, name) }
        try expectAFreshStream(after: framing.cepstrum(.complex).lifter(.lowTime(0.002)).inverseCepstrum().magnitude(), on: noise, "the cepstral chain")
        try expectAFreshStream(after: framing.cepstrum(.power).lifter(.sinusoidal(22)), on: noise, "a power cepstrum")
        // The packing step of the reports ends a pipeline no sink can follow: its frames are
        // read from the main line, as the reports read them.
        let runner = try OfflineRunner(stages: framing.stages + [ComplexPacking().stageDescription], format: mono48, blockSize: 512, crossovers: .shipped)
        runner.run([noise])
        runner.plan.resetAll()
        runner.run([noise])
        runner.finish()
        let packed = runner.frames, half = packed.count / 2
        #expect(half >= 1 && packed.count == 2 * half && packed.allSatisfy { $0.count == 2 * 513 } && Array(packed[..<half]) == Array(packed[half...]))
    }

    // MARK: Latency and settling (STG-1)

    @Test func everyNodeStatesItsLatencyAndItsSettlingTime() throws {
        func mixer() throws -> ChannelMixer { try ChannelMixer(channel: nil, channelCount: 1, maximumFrames: 512) }
        func plan() throws -> any FFTPlan { try VDSPFFTBackend().makePlan(length: 64) }
        let hann = try Window.hann.samples(count: 64)

        // A centred frame is known half a frame after the sample it is centred on. Either way
        // a frame holds nothing from before a cold start once a whole frame has arrived.
        let centred = try STFTNode(frame: 64, hop: 16, taper: hann, alignment: .centered, plan: plan(), mixer: mixer(), sampleRate: 48_000)
        #expect(centred.latencyFrames == 32 && centred.settlingFrames == 32)
        let causal = try STFTNode(frame: 64, hop: 16, taper: hann, alignment: .causal, plan: plan(), mixer: mixer(), sampleRate: 48_000)
        #expect(causal.latencyFrames == 0 && causal.settlingFrames == 64)

        // Synthesis counts in frames of its input, which are hops: a sample waits for the last
        // frame that covers it, and is covered by all of its frames a frame after the start.
        let synthesis = try InverseSTFTNode(frame: 64, hop: 16, window: hann, scale: 1, alignment: .causal, preroll: 48, ownDelay: 48, plan: plan(), sampleRate: 48_000)
        #expect(synthesis.latencyFrames == 3 && synthesis.settlingFrames == 4)
        let sparse = try InverseSTFTNode(frame: 64, hop: 50, window: hann, scale: 1, alignment: .causal, preroll: 14, ownDelay: 14, plan: plan(), sampleRate: 48_000)
        #expect(sparse.latencyFrames == 1 && sparse.settlingFrames == 2, "rounded up to whole hops")

        // A level and a waveform add no delay; they hold only new samples after one window.
        let level = try LevelNode(kind: .rms, window: 192, hop: 48, bound: Vector.Bound(count: 192), mixer: mixer(), sampleRate: 48_000)
        #expect(level.latencyFrames == 0 && level.settlingFrames == 192)
        let waveform = try WaveformNode(bucket: 48, mixer: mixer(), sampleRate: 48_000)
        #expect(waveform.latencyFrames == 0 && waveform.settlingFrames == 48)

        // Steps that turn one frame into one frame keep no history: no latency, nothing to settle.
        let bank = try MelFilterBank(bands: 8, binCount: 33, nyquist: 24_000)
        let frameSteps: [any AnalysisNode] = [
            SpectralValueNode(.magnitude, bins: 33), try BandedMelNode(bank, crossovers: .shipped, requested: .automatic), try DenseMelNode(bank),
            try SpectralCentroidNode(firstBin: 0, count: 33, binWidth: 750, floor: 1e-10, bound: Vector.Bound(count: 33)),
            try CepstrumNode(kind: .real, floor: 1e-10, length: 64), try InverseCepstrumNode(length: 64),
            try LifterNode(weights: [Float](repeating: 1, count: 33), bound: Vector.Bound(count: 33)), CepstralPitchNode(first: 4, count: 20, sampleRate: 48_000),
            try CosineTransformNode(bands: 16, count: 13), try CosineBasisNode(bands: 30, count: 13, isInverse: false), ComplexPackingNode(bins: 33),
        ]
        for node in frameSteps {
            #expect(node.latencyFrames == 0 && node.settlingFrames == 0, "\(type(of: node))")
        }
    }

    // MARK: A step where its scope is missing (ORD-6, ENV-1)

    private func refusal<D: SignalDomain>(_ pipeline: Pipeline<Samples, D>) -> String? {
        errorMessage { try pipeline.emit(to: CollectingSink<D>()).run(on: noise, format: mono48) }
    }

    @Test func aStepLoweredWithoutItsScopeIsATypedError() {
        // Frames of the right domain from a stage that opens no scope: the types agree, and
        // the step finds no axis to work on when the pipeline is attached.
        let frame = [Float](repeating: 1, count: 33)
        typealias Complex = Spectrum<LinearFrequency, ComplexValues>
        typealias Powers = Spectrum<LinearFrequency, PowerValues>
        #expect(refusal(Pipeline { FixedFrames<Complex>(frame); Cepstrum() })?.contains("Cepstrum needs the spectra of an STFT") == true)
        #expect(refusal(Pipeline { FixedFrames<Quefrency>(frame); InverseCepstrum() })?.contains("InverseCepstrum needs a cepstrum") == true)
        #expect(refusal(Pipeline { FixedFrames<Quefrency>(frame); Lifter(.lowTime(0.001)) })?.contains("Lifter needs a cepstrum") == true)
        #expect(refusal(Pipeline { FixedFrames<Quefrency>(frame); CepstralPitch() })?.contains("CepstralPitch needs a cepstrum") == true)
        #expect(refusal(Pipeline { FixedFrames<Spectrum<MelFrequency, DecibelValues>>(frame); CepstralCoefficients() })?
            .contains("CepstralCoefficients needs the bands of a mel spectrum") == true)
        #expect(refusal(Pipeline { FixedFrames<MelCepstrum>(frame); InverseCepstralCoefficients(bands: 33) })?
            .contains("InverseCepstralCoefficients needs cepstral coefficients") == true)
        #expect(refusal(Pipeline { FixedFrames<Powers>(frame); MelScale(bands: 8) })?.contains("MelScale needs the frames of a spectral scope") == true)
        #expect(refusal(Pipeline { FixedFrames<Powers>(frame); SpectralCentroid() })?.contains("SpectralCentroid needs the frames of a spectral scope") == true)

        // The reports read complex frames through a packing step of their own: the same refusal.
        let context = InversionContext(samples: noise, sampleRate: 48_000, upstream: Pipeline { FixedFrames<Complex>(frame) }.stages)
        #expect(context.samples == noise && context.sampleRate == 48_000 && context.upstream.count == 1)
        #expect(errorMessage { _ = try context.complexFrames() }?.contains("there is no spectrum to read at this position") == true)
        #expect(errorMessage { try context.check() } == nil, "a context made outside a report is never cancelled")
    }

    @Test func synthesisChecksTheSpectraItIsGiven() {
        // Spectra of 129 bins come from a transform of 256 points: a frame of 512 samples does not fit it.
        let short = FixedFrames<Spectrum<LinearFrequency, ComplexValues>>(
            [Float](repeating: 0, count: 129), scope: .spectral(frameSize: 512, hopSize: 128, axis: .linearFrequency(binCount: 129, nyquist: 24_000)))
        #expect(refusal(Pipeline { short; InverseSTFT() })?.contains("shorter than the frame of 512") == true)
        #expect(refusal(Pipeline { STFT(frame: 256, hop: 64); InverseSTFT(backend: UnwillingBackend()) })?.contains("does not transform frames of 256 points") == true)
    }

    // MARK: Numbers a signal would not give

    @Test func aCentroidThatOverflowsIsNoCentroid() throws {
        // One bin at the Nyquist frequency, 10³⁵ high: the sum of the weights is a number, the
        // sum of frequency times weight is not.
        var frame = [Float](repeating: 0, count: 33)
        frame[32] = 1e35
        let spectrum = FixedFrames<Spectrum<LinearFrequency, MagnitudeValues>>(
            frame, scope: .spectral(frameSize: 64, hopSize: 512, axis: .linearFrequency(binCount: 33, nyquist: 24_000)))
        let sink = CollectingSink<Scalar>()
        try Pipeline { spectrum; SpectralCentroid() }.emit(to: sink).run(on: noise, format: mono48)
        #expect(sink.scalars.count == 6 && sink.scalars.allSatisfy { $0.value == 0 && $0.confidence == 0 }, "no NaN, no infinity (NUM-1): \(sink.scalars)")
        // The same bin at a height single precision can multiply: the Nyquist frequency.
        frame[32] = 1e30
        let finite = CollectingSink<Scalar>()
        try Pipeline {
            FixedFrames<Spectrum<LinearFrequency, MagnitudeValues>>(frame, scope: .spectral(frameSize: 64, hopSize: 512, axis: .linearFrequency(binCount: 33, nyquist: 24_000)))
            SpectralCentroid()
        }.emit(to: finite).run(on: noise, format: mono48)
        #expect(finite.scalars.allSatisfy { $0.value == 24_000 && $0.confidence == 1 })
    }

    @Test func aWindowWithoutEnergyHasNoPowerNormalisation() throws {
        #expect(throws: DSPError.self) { _ = try WindowNormalization.power.factor(window: [0, 0, 0, 0], transformLength: 4) }
        #expect(throws: DSPError.self) { _ = try WindowNormalization.power.factor(window: [1, 1], transformLength: 0) }
        #expect(try WindowNormalization.power.factor(window: [1, 1, 1, 1], transformLength: 4) == (2.0 / 16).squareRoot())
        #expect(try WindowNormalization.none.factor(window: [], transformLength: 0) == 1)
    }

    // MARK: Spellings

    @Test func theFluentInverseCepstrumIsTheStage() throws {
        let framing = Pipeline { STFT(frame: 1_024, hop: 512) }
        #expect(framing.cepstrum(.complex).inverseCepstrum().stages == Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.complex); InverseCepstrum() }.stages)
        #expect(framing.cepstrum(.complex).inverseCepstrum(isActive: false).stages != framing.cepstrum(.complex).inverseCepstrum().stages)
    }

    @Test func theDecibelsOfAReportLowerAsTheStepDoes() throws {
        // The report pairs Decibels with one kind of value; what it runs is the step itself.
        var plain = try lowering(), paired = try lowering()
        let spectral = AnalysisStep(name: "Opening", key: 0, output: .real(count: 33),
                                    scope: .spectral(frameSize: 64, hopSize: 16, axis: .linearFrequency(binCount: 33, nyquist: 24_000))) {
            () throws(DSPError) -> any AnalysisNode in try FixedFramesNode([Float](repeating: 1, count: 33))
        }
        plain.emit(.analysis(spectral))
        paired.emit(.analysis(spectral))
        let step = Decibels(reference: 2, floor: -90)
        try step.lower(&plain)
        try DecibelsInversion<PowerValues>(base: step).lower(&paired)
        #expect(plain.specs == paired.specs && plain.specs.count == 2)
        #expect(DecibelsInversion<PowerValues>.stageName == "Decibels" && DecibelsInversion<MagnitudeValues>(base: step).inverse == InverseDecibels(.magnitude, reference: 2))
    }
}
