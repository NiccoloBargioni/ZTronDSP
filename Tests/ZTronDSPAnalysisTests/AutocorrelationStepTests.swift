import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// The streaming `Autocorrelation` step (WP-515): parity with the direct sum, on samples and
/// on a feature-rate sequence, and what every step owes (STG-1).
@Suite("Autocorrelation step")
struct AutocorrelationStepTests {
    private let noise = TestSignal.whiteNoise(count: 6_000, seed: 515, amplitude: 0.5)

    /// The frames an offline slicing of `signal` gives: frame `k` is `signal[k·hop ..< k·hop + window]`.
    private func reference(_ signal: [Float], window: Int, hop: Int, maxLag: Int, normalization: CorrelationNormalization = .none) throws -> [[Float]] {
        var frames: [[Float]] = []
        var start = 0
        while start + window <= signal.count {
            frames.append(try DSP.autocorrelate(Array(signal[start ..< start + window]), maxLag: maxLag, normalization: normalization, strategy: .direct))
            start += hop
        }
        return frames
    }

    // MARK: Parity with direct (WP-515)

    @Test(arguments: [512, 441, 7, 1_000, 2_048])
    func theFramesEqualTheDirectSumForAnyBlockSize(blockSize: Int) throws {
        for (window, hop, maxLag) in [(256, 64, 128), (300, 300, 299), (64, 1, 63), (240, 100, 400)] {
            let frames: [[Float]] = try Pipeline { Autocorrelation(window: window, hop: hop, maxLag: maxLag) }.process(noise, format: mono48, blockSize: blockSize)
            let expected = try reference(noise, window: window, hop: hop, maxLag: maxLag)
            #expect(frames.count == expected.count && frames.count == (noise.count - window) / hop + 1, "\(window), \(hop): \(frames.count) frames")
            var worst = 0.0
            for (frame, wanted) in zip(frames, expected) {
                let peak = Double(wanted[0])
                for (a, b) in zip(frame, wanted) { worst = max(worst, abs(Double(a) - Double(b)) / peak) }
                #expect(frame.count == maxLag + 1)
            }
            #expect(worst <= 2e-6, "\(window), \(hop), \(maxLag), blocks of \(blockSize): off by \(worst) of the value at lag 0")
            // A lag past the window has no product.
            if maxLag >= window { #expect(frames.allSatisfy { $0[window...].allSatisfy { $0 == 0 } }) }
        }
    }

    @Test func theOutputDoesNotDependOnTheBlockSize() throws {
        let pipeline = Pipeline { Autocorrelation(window: 256, hop: 64, maxLag: 128, normalization: .coefficient) }
        let whole: [[Float]] = try pipeline.process(noise, format: mono48, blockSize: 6_000)
        for blockSize in [1, 13, 64, 441, 512] {
            let frames: [[Float]] = try pipeline.process(noise, format: mono48, blockSize: blockSize)
            #expect(frames == whole, "blocks of \(blockSize): bit for bit, the framer hands the transform the same frames")
        }
    }

    @Test func aPeriodicFixturePeaksAtItsPeriod() throws {
        // 441 Hz at 44.1 kHz: a period of exactly 100 samples.
        let tone = TestSignal.harmonic(fundamental: 441, amplitudes: [0.5, 0.3, 0.2, 0.1], sampleRate: 44_100, count: 22_050)
        let frames: [[Float]] = try Pipeline { Autocorrelation(window: 2_048, hop: 512, maxLag: 1_024, normalization: .coefficient) }
            .process(tone, format: SignalFormat(sampleRate: 44_100), blockSize: 441)
        #expect(frames.count == 40)
        for (index, frame) in frames.enumerated() {
            let peak = try #require((50 ... 1_024).max { frame[$0] < frame[$1] })
            #expect(peak == 100 && frame[0] == 1 && frame[100] > 0.9, "frame \(index): the largest value past lag 0 is at lag \(peak)")
        }
    }

    @Test func theNormalisationsAreThoseOfTheOneShotFunction() throws {
        for normalization in [CorrelationNormalization.none, .biased, .unbiased, .coefficient] {
            let frames: [[Float]] = try Pipeline { Autocorrelation(window: 200, hop: 50, maxLag: 230, normalization: normalization) }.process(noise, format: mono48)
            let expected = try reference(noise, window: 200, hop: 50, maxLag: 230, normalization: normalization)
            #expect(frames.count == expected.count)
            for (frame, wanted) in zip(frames, expected) { expectClose(frame, wanted, .absolute(2e-6 * Double(max(abs(wanted[0]), 1))), "\(normalization)") }
        }
        // Silence has no coefficient: zeros, not 0/0 (NUM-1); so has a signal under the floor.
        let silent: [[Float]] = try Pipeline { Autocorrelation(window: 64, hop: 64, normalization: .coefficient) }.process(TestSignal.silence(count: 640), format: mono48)
        #expect(silent.count == 10 && silent.allSatisfy { $0.allSatisfy { $0 == 0 } })
        let quiet = noise.map { $0 * 1e-4 }
        let under: [[Float]] = try Pipeline { Autocorrelation(window: 64, hop: 64, normalization: .coefficient, floor: 1e-3) }.process(quiet, format: mono48)
        let over: [[Float]] = try Pipeline { Autocorrelation(window: 64, hop: 64, normalization: .coefficient) }.process(quiet, format: mono48)
        #expect(under.allSatisfy { $0.allSatisfy { $0 == 0 } } && over.allSatisfy { $0[0] == 1 })
    }

    // MARK: Any sampled sequence

    @Test func aFeatureRateSequenceIsFramedValueByValue() throws {
        // A level track at 1 000 values per second, then its autocorrelation over 32 values.
        let level = Pipeline { Level(.rms, window: 0.004, hop: 0.001) }
        let track: [ScalarFrame] = try level.process(noise, format: mono48)
        let values = track.map { $0.value }
        let sink = CollectingSink<Lags>()
        try Pipeline { Level(.rms, window: 0.004, hop: 0.001); Autocorrelation(window: 32, hop: 8, maxLag: 20); Emit(to: sink) }.run(on: noise, format: mono48, blockSize: 441)
        let expected = try reference(values, window: 32, hop: 8, maxLag: 20)
        #expect(sink.reals.count == expected.count && expected.count == (values.count - 32) / 8 + 1)
        for (frame, wanted) in zip(sink.reals, expected) { expectClose(frame, wanted, .relativeToMaximum(2e-6)) }
        // The axis is in the units of the sequence it framed: lags of a millisecond.
        #expect(sink.axis == .lags(count: 21, sampleRate: 1_000) && sink.environment?.frameSize == 32 && sink.environment?.hopSize == 8)
        #expect(sink.environment?.featureRate == 125 && sink.environment?.sampleRate == 1_000)
        // A frame's time is the time of the newest value of its window.
        let scalars = CollectingSink<Scalar>()
        try level.emit(to: scalars).run(on: noise, format: mono48, blockSize: 441)
        #expect(sink.times == stride(from: 31, to: values.count, by: 8).map { scalars.times[$0] })
        // The fluent spelling on a scalar track, and a novelty curve would do as well.
        #expect(Pipeline().level(.rms).autocorrelation(window: 32, hop: 8) == Pipeline { Level(.rms); Autocorrelation(window: 32, hop: 8) })
        #expect(Autocorrelation.rule(.novelty) == .lags && Autocorrelation.rule(.scalar) == .lags && Autocorrelation.rule(.samples) == .lags)
    }

    @Test func downstreamTheAxisIsLagsAndTheTimesAreThoseOfTheNewestSample() throws {
        let sink = CollectingSink<Lags>()
        try Pipeline { Autocorrelation(window: 256, hop: 64, maxLag: 100); Emit(to: sink) }.run(on: noise, format: mono48, blockSize: 441)
        #expect(sink.axis == .lags(count: 101, sampleRate: 48_000) && sink.axis?.unit == .seconds)
        #expect(sink.environment?.frameSize == 256 && sink.environment?.hopSize == 64 && sink.environment?.featureRate == 750 && sink.environment?.latency == 0)
        #expect(sink.indices == Array(0 ..< sink.frameCount))
        for (index, time) in sink.times.enumerated() {
            expectClose(time, Double(index * 64 + 255) / 48_000, .absolute(1e-9))
        }
        // A heat map takes the frames as columns.
        let feed = HeatmapFeed(history: 32)
        try Pipeline { Autocorrelation(window: 256, hop: 64, maxLag: 100); Emit(to: feed) }.run(on: noise, format: mono48)
        #expect(feed.axis == .lags(count: 101, sampleRate: 48_000) && feed.rowCount == 101 && feed.columnCount == 32)
        // Every lag that has a product, by default.
        #expect(try environmentAtTheEnd(of: Pipeline { Autocorrelation(window: 128, hop: 32) }).frequencyAxis == .lags(count: 128, sampleRate: 48_000))
    }

    @Test func aSignalOfSeveralChannelsIsReducedAsAsked() throws {
        let left = noise, right = TestSignal.whiteNoise(count: 6_000, seed: 99, amplitude: 0.5)
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        func frames(_ policy: ChannelPolicy) throws -> [[Float]] {
            let sink = CollectingSink<Lags>()
            try run(Pipeline { Autocorrelation(window: 256, hop: 128, maxLag: 64, channels: policy); Emit(to: sink) }, channels: [left, right], format: stereo)
            return sink.reals
        }
        let mix = zip(left, right).map { ($0 + $1) / 2 }
        for (policy, signal) in [(ChannelPolicy.mixdown, mix), (.channel(0), left), (.channel(1), right)] {
            let expected = try reference(signal, window: 256, hop: 128, maxLag: 64)
            for (frame, wanted) in zip(try frames(policy), expected) { expectClose(frame, wanted, .relativeToMaximum(2e-6), "\(policy)") }
        }
        #expect(throws: DSPError.self) { _ = try frames(.channel(2)) }
        #expect(throws: DSPError.self) { _ = try frames(.perChannel) }
    }

    // MARK: Order, both tiers (O-1)

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() throws {
        for tag in [DomainTag.samples, .novelty, .scalar] { #expect(Autocorrelation.rule(tag) == .lags) }
        for tag in [DomainTag.spectrum(axis: .linear, values: .complex), .spectrum(axis: .mel, values: .decibel), .quefrency, .lags, .tempoSpectrum, .chroma, .envelope, .melCepstrum] {
            #expect(Autocorrelation.rule(tag) == nil, "\(tag)")
        }
        let step = Autocorrelation(window: 64, hop: 16).stageDescription
        #expect(try DynamicPipeline().appending(step).outputTag == .lags)
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256)).appending(step) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(step).appending(step) }
    }

    @Test func descriptionsSpellingsAndActivation() throws {
        // A block that begins with it, or with sequence stages and then it, starts from samples.
        let first: Pipeline<Samples, Lags> = Pipeline { Autocorrelation(window: 512, hop: 128, maxLag: 200, normalization: .biased) }
        #expect(first == Pipeline().autocorrelation(window: 512, hop: 128, maxLag: 200, normalization: .biased))
        let afterChain: Pipeline<Samples, Lags> = Pipeline { TestGain(0.5); Autocorrelation() }
        #expect(afterChain == Pipeline().appending(TestGain(0.5)).autocorrelation())
        #expect(Pipeline().autocorrelation() == Pipeline().autocorrelation(window: 2_048, hop: 512, maxLag: nil, normalization: .none, floor: 1e-20, channels: .mixdown, backend: .vDSP))
        #expect(Pipeline().autocorrelation() != Pipeline().autocorrelation(maxLag: 100) && Pipeline().autocorrelation() != Pipeline().autocorrelation(normalization: .coefficient))
        #expect(Pipeline().autocorrelation() != Pipeline().autocorrelation(isActive: false) && Pipeline().autocorrelation() != Pipeline().autocorrelation(channels: .channel(0)))
        #expect(Autocorrelation.stageName == "Autocorrelation" && Autocorrelation().backend is VDSPFFTBackend && Autocorrelation().maxLag == nil)
        // A branch on samples begins with it; the main line goes on untouched.
        let feed = HeatmapFeed(history: 8)
        let tapped = try Pipeline { Tap { Autocorrelation(window: 256, hop: 64); Emit(to: feed) }; TestGain(0.5) }.process(noise, format: mono48)
        #expect(tapped == noise.map { $0 * 0.5 } && feed.columnCount == 8 && feed.rowCount == 256)

        // Switched off, it suspends its branch (ACT-3): no frame reaches the sink.
        let dark = CollectingSink<Lags>()
        try Pipeline { Autocorrelation(window: 64, hop: 16, isActive: false); Emit(to: dark) }.run(on: noise, format: mono48)
        #expect(dark.frameCount == 0)
        // Equal steps in two taps are computed once (F5).
        let a = CollectingSink<Lags>(), b = CollectingSink<Lags>()
        let shared = Pipeline { Tap { Autocorrelation(window: 64, hop: 16); Emit(to: a) }; Tap { Autocorrelation(window: 64, hop: 16); Emit(to: b) } }
        #expect(nodeNames(try lowered(shared).steps) == ["Autocorrelation"])
        try shared.run(on: noise, format: mono48)
        #expect(a.reals == b.reals && a.frameCount > 300)
    }

    // MARK: Attach-time checks

    @Test func nonsenseIsRefusedWhenThePipelineIsAttached() {
        func refusal(_ step: Autocorrelation) -> String? {
            errorMessage { let _: [[Float]] = try Pipeline { step }.process(noise, format: mono48) }
        }
        #expect(refusal(Autocorrelation(window: 0, hop: 1))?.contains("Invalid parameter window") == true)
        #expect(refusal(Autocorrelation(window: 1 << 25, hop: 1))?.contains("Invalid parameter window") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 0))?.contains("Invalid parameter hop") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 65))?.contains("Invalid parameter hop") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 16, maxLag: -1))?.contains("Invalid parameter maxLag") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 16, floor: -1))?.contains("Invalid parameter floor") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 16, floor: .nan))?.contains("Invalid parameter floor") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 16, backend: UnwillingBackend()))?.contains("does not transform frames of 128 points") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 16, channels: .channel(3)))?.contains("channel 3 does not exist") == true)
        #expect(refusal(Autocorrelation(window: 64, hop: 64, maxLag: 0)) == nil, "lag 0 alone is the energy of each frame")
        #expect(refusal(Autocorrelation(window: 1, hop: 1)) == nil)
    }

    // MARK: Cold start, latency, settling (ACT-10, STG-1)

    @Test func aColdStartFramesTheSequenceAgainFromNothing() throws {
        let short = Array(noise[..<3_000])
        try expectAFreshStreamAfterAColdStart(of: Pipeline { Autocorrelation(window: 256, hop: 100, maxLag: 64) }, on: short, "Autocorrelation on samples")
        try expectAFreshStreamAfterAColdStart(
            of: Pipeline { Level(.rms, window: 0.004, hop: 0.001); Autocorrelation(window: 30, hop: 7, normalization: .coefficient) }, on: short,
            "Autocorrelation on a scalar track")
        let node = try AutocorrelationNode(
            window: 192, hop: 48, lagCount: 100, normalization: .none, floor: 0, transform: WienerKhinchin(frame: 192, lagCount: 100),
            mixer: ChannelMixer(channel: nil, channelCount: 1, maximumFrames: 512), sampleRate: 48_000)
        #expect(node.latencyFrames == 0 && node.settlingFrames == 192, "no delay; only new samples after one window")
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let lags = CountingSink<Lags>(), unbiased = CountingSink<Lags>(), track = CountingSink<Lags>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { Autocorrelation(window: 2_048, hop: 512, maxLag: 1_024, normalization: .coefficient); Emit(to: lags) }
            Tap { Autocorrelation(window: 300, hop: 100, normalization: .unbiased); Emit(to: unbiased) }
            Tap { Level(.rms, window: 0.004, hop: 0.001); Autocorrelation(window: 64, hop: 4, normalization: .biased); Emit(to: track) }
        })
        #expect(lags.frames > 990 && unbiased.frames > 5_000 && track.frames > 2_600, "\(lags.frames), \(unbiased.frames) and \(track.frames) frames")
    }
}
