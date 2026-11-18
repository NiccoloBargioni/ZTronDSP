import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `Level` step and its measuring spelling (WP-506).
@Suite("Level")
struct LevelTests {
    // MARK: Analytic signals (§6.2)

    @Test func aSineReadsItsPeakAndItsRootMeanSquare() throws {
        // 1 kHz at 48 kHz: the default window of 50 ms holds 50 whole periods.
        for amplitude in [1.0, 0.5, 0.01] {
            let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 24_000, amplitude: amplitude)
            let rms: [ScalarFrame] = try Pipeline { Level(.rms) }.process(sine, format: mono48)
            let peak: [ScalarFrame] = try Pipeline { Level(.peak) }.process(sine, format: mono48)
            #expect(rms.count == (24_000 - 2_400) / 480 + 1 && peak.count == rms.count, "one value per hop once a window is full")
            expectClose(rms.map { $0.value }, [Double](repeating: 20 * log10(amplitude / 2.0.squareRoot()), count: rms.count), .absolute(1e-3))
            expectClose(peak.map { $0.value }, [Double](repeating: 20 * log10(amplitude), count: peak.count), .absolute(1e-3))
            #expect(rms.allSatisfy { $0.confidence == 1 } && peak.allSatisfy { $0.confidence == 1 })
        }
    }

    @Test func constantsAndSilenceReadWhatTheyAre() throws {
        let constant: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.01, hop: 0.01) }.process(TestSignal.constant(-0.25, count: 4_800), format: mono48)
        expectClose(constant.map { $0.value }, [Double](repeating: 20 * log10(0.25), count: 10), .absolute(1e-4))
        let square: [ScalarFrame] = try Pipeline { Level(.rms) }.process(TestSignal.nyquist(count: 4_800), format: mono48)
        expectClose(square.map { $0.value }, [Double](repeating: 0, count: square.count), .absolute(1e-5), "a full-scale square wave is 0 dBFS RMS")
        for kind in [LevelKind.rms, .peak] {
            let silence: [ScalarFrame] = try Pipeline { Level(kind) }.process(TestSignal.silence(count: 9_600), format: mono48)
            #expect(silence.count == 16 && silence.allSatisfy { $0.value == -160 && $0.confidence == 1 }, "silence has a level: the floor, not −∞ (NUM-1)")
        }
        let impulse: [ScalarFrame] = try Pipeline { Level(.peak, window: 0.01, hop: 0.005) }.process(TestSignal.impulse(count: 2_400, at: 1_000, amplitude: -0.5), format: mono48)
        expectClose(impulse.map { $0.value }, [-160, -160, -160, -6.0206, -6.0206, -160, -160, -160, -160], .absolute(1e-3),
                    "the two windows that hold sample 1 000")
    }

    // MARK: The window and the hop are the step's own

    @Test(arguments: [1, 7, 64, 480, 512, 4_096])
    func theValuesDoNotDependOnTheBlockSize(blockSize: Int) throws {
        let signal = TestSignal.sum(TestSignal.whiteNoise(count: 20_000, seed: 506, amplitude: 0.3),
                                    TestSignal.chirp(from: 100, to: 4_000, sampleRate: 48_000, count: 20_000, amplitude: 0.5))
        for kind in [LevelKind.rms, .peak] {
            let pipeline = Pipeline { Level(kind, window: 0.0213, hop: 0.0041) }
            let reference: [ScalarFrame] = try pipeline.process(signal, format: mono48, blockSize: 512)
            let values: [ScalarFrame] = try pipeline.process(signal, format: mono48, blockSize: blockSize)
            #expect(values == reference && reference.count > 80, "\(kind), blocks of \(blockSize): bit for bit")
        }
    }

    @Test func theValuesEqualAReductionOfTheWholeSignal() throws {
        let signal = TestSignal.whiteNoise(count: 10_000, seed: 7, amplitude: 0.8)
        let rms: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.02, hop: 0.01) }.process(signal, format: mono48, blockSize: 333)
        let peak: [ScalarFrame] = try Pipeline { Level(.peak, window: 0.02, hop: 0.01) }.process(signal, format: mono48, blockSize: 333)
        for index in 0 ..< rms.count {
            let window = signal[index * 480 ..< index * 480 + 960]
            let meanSquare = window.reduce(0) { $0 + Double($1) * Double($1) } / 960
            expectClose(rms[index].value, 10 * log10(meanSquare), .absolute(1e-4))
            expectClose(peak[index].value, 20 * log10(Double(window.map { abs($0) }.max() ?? 0)), .absolute(1e-4))
        }
    }

    @Test func downstreamIsAScalarTrackAtTheHopRate() throws {
        let sink = CollectingSink<Scalar>(), scaled = CollectingSink<Scalar>()
        try Pipeline { Level(.rms, window: 0.05, hop: 0.01); Emit(to: sink); TestGain(0.5); Emit(to: scaled) }
            .run(on: TestSignal.whiteNoise(count: 9_600, seed: 2), format: mono48, blockSize: 100)
        #expect(sink.environment?.sampleRate == 100 && sink.environment?.nyquistFrequency == 50 && sink.environment?.isInSpectralScope == false)
        #expect(sink.axis == nil && sink.frameCount == 16 && sink.indices == Array(0 ..< 16))
        // A value describes the window that ends at its newest sample.
        expectClose(sink.times, (0 ..< 16).map { Double($0 * 480 + 2_399) / 48_000 }, .absolute(1e-12))
        #expect(scaled.scalars.map { $0.value } == sink.scalars.map { $0.value * 0.5 }, "sequence stages run on the track")
    }

    @Test func aMultichannelSignalIsReducedByTheChannelPolicy() throws {
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let left = TestSignal.constant(0.5, count: 4_800), right = TestSignal.constant(-0.25, count: 4_800)
        func level(_ policy: ChannelPolicy) throws -> Float {
            let sink = CollectingSink<Scalar>()
            try run(Pipeline { Level(.peak, channels: policy); Emit(to: sink) }, channels: [left, right], format: stereo)
            return try #require(sink.scalars.last).value
        }
        expectClose(try level(.mixdown), 20 * log10(0.125), .absolute(1e-4), "the mean of the channels")
        expectClose(try level(.channel(0)), 20 * log10(0.5), .absolute(1e-4))
        expectClose(try level(.channel(1)), 20 * log10(0.25), .absolute(1e-4))
        #expect(throws: DSPError.self) { _ = try level(.channel(2)) }
        #expect(throws: DSPError.self) { _ = try level(.perChannel) }
    }

    @Test func timesThatDoNotFitAreRefusedAtAttachTime() {
        let signal = TestSignal.silence(count: 480)
        func refused(_ level: Level<Scalar>) -> Bool {
            do {
                let _: [ScalarFrame] = try Pipeline { level }.process(signal, format: mono48)
                return false
            } catch {
                return error.stage?.stageName == "Level"
            }
        }
        #expect(refused(Level(.rms, window: 0)) && refused(Level(.rms, window: -1)) && refused(Level(.rms, window: .infinity)))
        #expect(refused(Level(.rms, hop: 0)) && refused(Level(.rms, hop: .nan)))
        #expect(refused(Level(.rms, window: 0.01, hop: 0.02)), "samples between two windows would not be measured")
        #expect(!refused(Level(.rms, window: 0.01, hop: 0.01)) && !refused(Level(.peak, window: 1e-9, hop: 1e-9)), "a window is at least one sample")
    }

    // MARK: The measuring spelling (OUT-1)

    @Test func theMeasuringSpellingIsItsTapExpansion() {
        let box = StateBox(Float(0)), other = StateBox(ScalarFrame.none)
        #expect(Pipeline { Level(.rms, window: 0.02, hop: 0.01, to: box.binding) } == Pipeline { Tap { Level(.rms, window: 0.02, hop: 0.01); Emit(to: box.binding) } })
        #expect(Pipeline { Level(.peak, to: box.binding, isActive: false) } == Pipeline { Tap(isActive: false) { Level(.peak); Emit(to: box.binding) } })
        #expect(Pipeline { Level(.rms, to: other.binding) } != Pipeline { Level(.rms, to: box.binding) }, "a value and a frame are different results")
        #expect(Pipeline().level(.rms, to: box.binding) == Pipeline { Level(.rms, to: box.binding) })
        #expect(Pipeline().level(.rms, window: 0.1, hop: 0.05, channels: .channel(0)) == Pipeline { Level(.rms, window: 0.1, hop: 0.05, channels: .channel(0)) })
        #expect(Level(.rms, to: box.binding, isActive: false).activation == .constant(false) && Level<Samples>.stageName == "Level")
        #expect(throws: DSPError.self) { var context = try lowering(); try Level(.rms, to: box.binding).lower(&context) }
    }

    @Test @MainActor func aMeasuringLevelPassesTheSamplesOnAndWritesItsBinding() throws {
        let level = StateBox(Float(1)), frame = StateBox(ScalarFrame.none), dark = StateBox(Float(1))
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 9_600, amplitude: 0.5)
        let output = try Pipeline {
            Level(.rms, to: level.binding)
            TestGain(2)
            Level(.peak, to: frame.binding)
            Level(.peak, to: dark.binding, isActive: false)
        }.process(sine, format: mono48)
        #expect(output == sine.map { $0 * 2 }, "the signal that follows is untouched")
        expectClose(level.value, 20 * log10(0.5 / 2.0.squareRoot()), .absolute(1e-3))
        expectClose(frame.value.value, 0, .absolute(1e-3), "the second level hears the signal after the gain")
        #expect(frame.value.confidence == 1 && level.writes == 1 && dark.writes == 0)
    }

    // MARK: Order, both tiers

    @Test func itFollowsSamplesOnly() throws {
        let transforming = try #require(Level(.rms).stageDescriptions.first)
        #expect(transforming.rule(.samples) == .scalar)
        for tag in [DomainTag.scalar, .novelty, .spectrum(axis: .linear, values: .complex), .quefrency, .envelope] {
            #expect(transforming.rule(tag) == nil, "\(tag)")
        }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(STFT(frame: 512, hop: 128)).appending(Level(.rms)) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(Level(.rms)).appending(Level(.rms)) }
        #expect(try DynamicPipeline().appending(Level(.rms, to: StateBox(Float(0)).binding)).outputTag == .samples)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let rms = CountingSink<Scalar>(), peak = CountingSink<Scalar>(), mixed = CountingSink<Scalar>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { Level(.rms); Emit(to: rms) }
            Tap { Level(.peak, window: 0.004, hop: 0.001); Emit(to: peak) }
        })
        #expect(rms.frames > 1_000 && peak.frames > 10_000)
        try expectNoAllocationsRunning(Pipeline { Level(.rms, window: 0.01, hop: 0.002); Emit(to: mixed) },
                                       format: SignalFormat(sampleRate: 44_100, channelCount: 2), blockSize: 300)
        #expect(mixed.frames > 3_000)
    }
}

/// The `Waveform` step (WP-536).
@Suite("Waveform")
struct WaveformTests {
    private let signal = TestSignal.sum(TestSignal.whiteNoise(count: 20_011, seed: 536, amplitude: 0.4),
                                        TestSignal.sine(frequency: 30, sampleRate: 48_000, count: 20_011, amplitude: 0.5))

    /// The least and the greatest sample of every whole stretch of `bucket` samples.
    private func reduction(_ samples: [Float], bucket: Int) -> (minima: [Float], maxima: [Float]) {
        var minima: [Float] = [], maxima: [Float] = []
        var start = 0
        while start + bucket <= samples.count {
            minima.append(samples[start ..< start + bucket].min() ?? 0)
            maxima.append(samples[start ..< start + bucket].max() ?? 0)
            start += bucket
        }
        return (minima, maxima)
    }

    @Test(arguments: [1, 7, 64, 239, 240, 241, 512, 4_096, 30_000])
    func thePairsEqualANaiveReductionForIrregularBlocks(blockSize: Int) throws {
        let sink = CollectingSink<Envelope>()
        try Pipeline { Waveform(resolution: 0.005); Emit(to: sink) }.run(on: signal, format: mono48, blockSize: blockSize)
        let expected = reduction(signal, bucket: 240)
        #expect(sink.minima.flatMap { $0 } == expected.minima && sink.maxima.flatMap { $0 } == expected.maxima, "blocks of \(blockSize): bit for bit")
        #expect(expected.minima.count == 83)
        // A frame carries the pairs its block completed, and the time of the first of them.
        var pair = 0
        for (index, minima) in sink.minima.enumerated() {
            expectClose(sink.times[index], Double(pair * 240) / 48_000, .absolute(1e-9))
            pair += minima.count
        }
    }

    @Test func aStretchIsTheResolutionInSamples() throws {
        for (resolution, rate, bucket) in [(0.005, 48_000.0, 240), (0.001, 44_100.0, 44), (1e-9, 48_000.0, 1), (0.25, 8_000.0, 2_000)] {
            let sink = CollectingSink<Envelope>()
            let samples = Array(signal[..<12_000])
            try Pipeline { Waveform(resolution: resolution); Emit(to: sink) }.run(on: samples, format: SignalFormat(sampleRate: rate), blockSize: 512)
            let expected = reduction(samples, bucket: bucket)
            #expect(sink.minima.flatMap { $0 } == expected.minima && sink.maxima.flatMap { $0 } == expected.maxima, "\(resolution) s at \(rate) Hz")
            #expect(sink.environment?.featureRate == rate / Double(bucket) && sink.environment?.hopSize == bucket, "downstream, the feature rate is the pair rate")
        }
    }

    @Test func aWaveformFeedSpacesThePairsOfAFrame() throws {
        let feed = WaveformFeed(history: 256)
        let output = try Pipeline { Tap { Waveform(resolution: 0.005); Emit(to: feed) }; TestGain(2) }.process(signal, format: mono48, blockSize: 1_000)
        #expect(output == signal.map { $0 * 2 })
        let snapshot = feed.snapshot()
        let expected = reduction(signal, bucket: 240)
        #expect(snapshot.minima == expected.minima && snapshot.maxima == expected.maxima)
        // The feed spaces the pairs of a frame by the feature rate, the first frame's (four
        // pairs, with blocks of 1 000) like every other.
        expectClose(snapshot.times, (0 ..< 83).map { Double($0) * 0.005 }, .absolute(1e-9), "each pair at the time of its own stretch")
        #expect(snapshot.times[0] == 0)
        #expect(feed.environment?.featureRate == 200)
    }

    @Test func channelsAreReducedAndBadResolutionsRefused() throws {
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let left = Array(signal[..<4_800]), right = left.map { -$0 * 0.5 }
        let sink = CollectingSink<Envelope>(), one = CollectingSink<Envelope>()
        try run(Pipeline { Waveform(); Emit(to: sink) }, channels: [left, right], format: stereo, blockSize: 100)
        try run(Pipeline { Waveform(channels: .channel(1)); Emit(to: one) }, channels: [left, right], format: stereo, blockSize: 100)
        let mean = reduction(zip(left, right).map { ($0 + $1) / 2 }, bucket: 240), second = reduction(right, bucket: 240)
        expectClose(sink.maxima.flatMap { $0 }, mean.maxima, .absolute(1e-7))
        #expect(one.minima.flatMap { $0 } == second.minima && one.maxima.flatMap { $0 } == second.maxima)
        for resolution in [0, -0.01, .infinity, .nan] {
            #expect(throws: DSPError.self) { try Pipeline { Waveform(resolution: resolution) }.run(on: left, format: mono48) }
        }
        #expect(throws: DSPError.self) { try run(Pipeline { Waveform(channels: .perChannel) }, channels: [left, right], format: stereo) }
    }

    @Test func descriptionOrderAndActivation() throws {
        #expect(Pipeline { Waveform(resolution: 0.01, channels: .channel(0)) } == Pipeline().waveform(resolution: 0.01, channels: .channel(0)))
        #expect(Pipeline { Waveform() } != Pipeline { Waveform(resolution: 0.01) } && Waveform.stageName == "Waveform")
        let description = try #require(Waveform().stageDescriptions.first)
        #expect(description.rule(.samples) == .envelope)
        for tag in [DomainTag.scalar, .envelope, .spectrum(axis: .linear, values: .power), .quefrency] { #expect(description.rule(tag) == nil, "\(tag)") }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(Waveform()).appending(Waveform()) }
        let feed = WaveformFeed()
        try Pipeline { Tap { Waveform(isActive: false); Emit(to: feed) } }.run(on: signal, format: mono48)
        #expect(feed.columnCount == 0, "switched off, it suspends its branch (ACT-3)")
        let a = WaveformFeed(), b = WaveformFeed()
        let shared = Pipeline { Tap { Waveform(); Emit(to: a) }; Tap { Waveform(); Emit(to: b) } }
        #expect(nodeNames(try lowered(shared).steps) == ["Waveform"], "equal framing is computed once (F5)")
    }

    @Test func theNodeRunsWithoutAllocating() throws {
        let feed = WaveformFeed(history: 512), sink = CountingSink<Envelope>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { Waveform(resolution: 0.005); Emit(to: feed) }
            Tap { Waveform(resolution: 0.0002); Emit(to: sink) }
        })
        #expect(feed.columnCount == 512 && sink.frames == 1_008)
        try expectNoAllocationsRunning(Pipeline { Waveform(resolution: 0.02); Emit(to: CountingSink<Envelope>()) },
                                       format: SignalFormat(sampleRate: 48_000, channelCount: 2), blockSize: 100)
    }
}
