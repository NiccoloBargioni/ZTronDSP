import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Envelopes into a `WaveformFeed`, frames of every kind as values, switches on frames of
/// bins, and the small value types around stages (WP-301, WP-304, WP-321, WP-330b, WP-334).
@Suite("Envelopes, frames and stage values")
struct EnvelopeAndValueTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 50, seed: 77)

    private func reduced(_ samples: ArraySlice<Float>, bucket: Int) -> (minima: [Float], maxima: [Float]) {
        let buckets = stride(from: samples.startIndex, to: samples.endIndex, by: bucket).map { samples[$0 ..< min($0 + bucket, samples.endIndex)] }
        return (buckets.map { $0.min()! }, buckets.map { $0.max()! })
    }

    // MARK: WaveformFeed (WP-334)

    @Test func aWaveformFeedHoldsTheNaiveReductionOfTheSignal() throws {
        let feed = WaveformFeed(history: 128, minimumHistory: 16)
        #expect(feed.history == 128 && feed.minimumHistory == 16 && feed.columnCount == 0 && !feed.isLive && feed.environment == nil)
        #expect(feed.snapshot().columnCount == 0 && feed.snapshot().content == .waveform)
        let generation = feed.generation
        try Pipeline().appending(TestEnvelope(bucket: 16)).emit(to: feed).run(on: noise, format: format, blockSize: 64)
        let expected = reduced(noise[...], bucket: 16)
        let snapshot = feed.snapshot()
        #expect(snapshot.columnCount == 128 && feed.columnCount == 128, "the newest 128 of \(expected.minima.count) pairs")
        #expect(snapshot.minima == Array(expected.minima.suffix(128)) && snapshot.maxima == Array(expected.maxima.suffix(128)), "≡ the naive reduction")
        #expect(feed.generation == generation + 1 + UInt64(expected.minima.count), "one new layout, then one step per pair")
        #expect(feed.environment?.featureRate == 3_000 && feed.environment?.hopSize == 16)
        #expect(zip(snapshot.times, snapshot.times.dropFirst()).allSatisfy { abs($1 - $0 - 16.0 / 48_000) < 1e-12 }, "one bucket between two pairs")
        var cursor = FeedCursor()
        var pairs = [Float](repeating: 0, count: 2 * 128), times = [Double](repeating: 0, count: 128)
        let read = pairs.withUnsafeMutableBufferPointer { buffer in times.withUnsafeMutableBufferPointer { feed.read(&cursor, into: buffer, times: $0) } }
        #expect(read.columnCount == 128 && read.rowCount == 2 && pairs[0] == snapshot.minima[0] && pairs[1] == snapshot.maxima[0] && times == snapshot.times)
        #expect(snapshot.pyramid().levels.count == 8 && snapshot.pyramid().levels.last?.minima == [snapshot.minima.min()!])
    }

    @Test func aLiveWaveformFeedFollowsItsSession() async throws {
        let rig = Rig()
        let feed = WaveformFeed(history: 64, minimumHistory: 8)
        let stream = FeatureStream<Envelope>(capacity: 512)
        let changes = Locked<[Bool]>([])
        let observation = feed.onLivenessChange { live in changes.withLock { $0.append(live) } }
        let session = try await rig.engine.attach(Pipeline().tap { $0.appending(TestEnvelope(bucket: 32)).emit(to: feed).emit(to: stream) }, to: rig.source)
        try session.start()
        #expect(feed.isLive)
        rig.feed(Array(noise[..<640]))
        #expect(feed.columnCount == 20)
        // A changed branch feeds the sink from now on: what it held is stale (SWAP-3).
        try await session.update(Pipeline { TestGain(0.5) }.tap { $0.appending(TestEnvelope(bucket: 32)).emit(to: feed).emit(to: stream) })
        rig.feed(Array(noise[640 ..< 1_280]))
        let expected = reduced(noise[640 ..< 1_280].map { $0 * 0.5 }[...], bucket: 32)
        // The gain ramps in from the old plan's output during its fade; what the feed holds comes from the new branch alone.
        #expect(feed.columnCount <= 20 && feed.snapshot().maxima.last == expected.maxima.last, "cleared at the exchange, then refilled")
        // Critical memory pressure trims the feed to its minimum (MEM-1).
        rig.feed(Array(noise[1_280 ..< 3_200]))
        try rig.engine.core.control.sync { rig.engine.core.respond(to: .critical) }
        rig.feed(Array(noise[..<64]))
        #expect(feed.history == 8 && feed.columnCount == 8)
        session.stop()
        #expect(!feed.isLive)
        #expect(await eventually { changes.get() == [true, false] })
        observation.cancel()
        session.detach()
        // The stream took the same frames as values: minima and maxima side by side.
        stream.finish()
        var frames: [FeatureFrame] = []
        for await frame in stream { frames.append(frame) }
        #expect(!frames.isEmpty && frames.allSatisfy { $0.kind == .envelope && $0.values.count == 2 && $0.secondary.count == 2 && $0.count == 2 })
        #expect(frames.allSatisfy { frame in zip(frame.values, frame.secondary).allSatisfy { $0 <= $1 } })
    }

    // MARK: Frames as values

    @Test func aFrameOfEveryKindCanBeKept() throws {
        let block = try AudioBuffer(channels: [[1, 2, 3], [4, 5, 6]])
        let samples = FeatureFrame(FrameView(samples: block.block(), index: 7, time: 0.5))
        #expect(samples.kind == .samples && samples.channelCount == 2 && samples.count == 3 && samples.index == 7 && samples.time == 0.5)
        #expect(Array(samples.samples(ofChannel: 1)) == [4, 5, 6] && samples.samples(ofChannel: 2).isEmpty && samples.values == [1, 2, 3, 4, 5, 6])
        let real: [Float] = [1, 2], imaginary: [Float] = [3, 4]
        real.withUnsafeBufferPointer { re in
            imaginary.withUnsafeBufferPointer { im in
                let complex = FeatureFrame(FrameView(real: re, imaginary: im, index: 1, time: 0))
                #expect(complex.kind == .complex && complex.values == [1, 2] && complex.secondary == [3, 4] && complex.count == 2)
                let envelope = FeatureFrame(FrameView(minima: re, maxima: im, index: 2, time: 0))
                #expect(envelope.kind == .envelope && envelope.values == [1, 2] && envelope.secondary == [3, 4])
                let vector = FeatureFrame(FrameView(real: re, index: 3, time: 0))
                #expect(vector.kind == .real && vector.values == [1, 2] && vector.secondary.isEmpty && vector.samples(ofChannel: 0).isEmpty)
            }
        }
        let scalar = FeatureFrame(FrameView(scalar: ScalarFrame(value: 3, confidence: 0.5), index: 4, time: 1))
        #expect(scalar.kind == .scalar && scalar.scalar == ScalarFrame(value: 3, confidence: 0.5) && scalar.count == 1 && scalar.values.isEmpty)
        #expect(scalar == FeatureFrame(kind: .scalar, index: 4, time: 1, scalar: ScalarFrame(value: 3, confidence: 0.5)))
    }

    // MARK: A switch on frames of bins (ACT-3, ACT-10)

    @Test func aBoundStepOnASpectrumIsBypassedFrameByFrame() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let probe = TestProbe()
        let sink = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let session = try await rig.engine.attach(
            Pipeline().tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().appending(TestScaleBins(3, probe: probe, isActive: on.binding)).emit(to: sink) },
            to: rig.source)
        try session.start()
        let plain = try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().process(noise, format: format, blockSize: 64)
        rig.feed(Array(noise[..<640]))
        #expect(sink.reals == plain[..<10].map { $0.map { $0 * 3 } })
        on.value = false
        await session.syncBindings()
        rig.feed(Array(noise[640 ..< 1_280]))
        #expect(Array(sink.reals[10...]) == Array(plain[10 ..< 20]), "off, the frames pass unchanged")
        let resets = probe.framerResets
        on.value = true
        await session.syncBindings()
        rig.feed(Array(noise[1_280 ..< 1_920]))
        #expect(Array(sink.reals[20...]) == plain[20 ..< 30].map { $0.map { $0 * 3 } } && probe.framerResets == resets + 1, "on again, the step starts cold")
    }

    // MARK: Stage values

    @Test func aRecipeIsItsExpansionAndASwitchKeepsAStagesValues() throws {
        let recipe = Pipeline().appending(TestTwoGains(first: 0.5, second: 4))
        #expect(recipe == Pipeline { TestGain(0.5); TestGain(4) }, "a pipeline that holds a recipe equals one that holds its expansion")
        #expect(try recipe.process([1, 1], format: format) == [2, 2])
        // `.active(_:)` on a sequence stage and on a self-typed stage: the switch is added, the values stay animatable.
        let switched = Pipeline().appending(TestGain(0.5).active(false)).appending(TestGain(2).active(true))
        #expect(switched.parameters.count == 2 && switched.stages[0].activation == .constant(false))
        #expect(try switched.process([1, 1], format: format) == [2, 2], "a stage switched off for good is compiled away")
        let moved = switched.replacingParameters(ParameterVector([0.5, 3]))
        #expect(try moved.process([1, 1], format: format) == [3, 3] && moved.stages[0].activation == .constant(false))
        let framed = Pipeline().appending(TestFramer(frame: 64, hop: 64).active(true)).testMagnitude()
        #expect(framed == Pipeline().testFramer(frame: 64, hop: 64).testMagnitude() && TestFramer(frame: 64, hop: 64).active(true).parameters.isEmpty)
        #expect(ActivatedStage<TestFramer>.stageName == "TestFramer" && ActivatedSequenceStage<TestGain>.stageName == "TestGain")
        // A recipe, a tap and a group are structure: they are never lowered themselves.
        #expect(throws: DSPError.self) { try Pipeline<Samples, Samples>(unchecked: [StageDescription(TestTwoGains(first: 1, second: 2), rule: .sequence)]).process([1], format: format) }
    }

    @Test func builtInEnvironmentKeysReadTheEnvironment() {
        let environment = DSPEnvironment(sampleRate: 44_100, channelCount: 2, blockSize: 256, isRealTime: true)
        #expect(environment[SampleRateKey.self] == 44_100 && environment[NyquistFrequencyKey.self] == 22_050 && environment[ChannelCountKey.self] == 2)
        #expect(environment[BlockSizeKey.self] == 256 && environment[FrameSizeKey.self] == nil && environment[HopSizeKey.self] == nil)
        #expect(environment[FrequencyResolutionKey.self] == nil && environment[FeatureRateKey.self] == nil && environment[FrequencyAxisKey.self] == nil)
        #expect(environment[LatencyKey.self] == 0 && environment[IsRealTimeKey.self] && environment[SourceKindKey.self] == .offline)
        // The defaults are what a key gives where the environment has nothing to say.
        #expect(SampleRateKey.defaultValue == 48_000 && NyquistFrequencyKey.defaultValue == 24_000 && ChannelCountKey.defaultValue == 1 && BlockSizeKey.defaultValue == 512)
        #expect(FrameSizeKey.defaultValue == nil && HopSizeKey.defaultValue == nil && FrequencyResolutionKey.defaultValue == nil && FeatureRateKey.defaultValue == nil)
        #expect(FrequencyAxisKey.defaultValue == nil && LatencyKey.defaultValue == 0 && !IsRealTimeKey.defaultValue && SourceKindKey.defaultValue == .offline)
    }

    @Test func aRingWriterReportsItsRingAndNeverBlocksUnlessAsked() throws {
        let ring = try SampleRing(channelCount: 2, capacity: 1_000)
        let writer = RingWriter(ring)
        #expect(writer.channelCount == 2 && writer.capacity >= 1_000 && writer.availableSpace == writer.capacity && writer.droppedFrames == 0)
        let interleaved: [Float] = [1, -1, 2, -2, 3, -3]
        #expect(writer.write(interleaved: interleaved, frameCount: 3) == 3)
        let block = try AudioBuffer(channels: [[4, 5], [-4, -5]])
        #expect(writer.writeWaiting(block.block()) == 2, "with room in the ring a waiting write returns at once")
        #expect(writer.availableSpace == writer.capacity - 5)
        let out = try AudioBuffer(channelCount: 2, capacity: 8)
        #expect(ztd_ring_read(writer.ring, UnsafePointer(out.block().channelTable), 5) == 5)
        #expect(out.array(ofChannel: 0, frameCount: 5) == [1, 2, 3, 4, 5] && out.array(ofChannel: 1, frameCount: 5) == [-1, -2, -3, -4, -5])
        let flood = try AudioBuffer(channelCount: 2, capacity: writer.capacity + 10)
        #expect(writer.write(flood.block()) == writer.capacity && writer.droppedFrames == 10, "the newest frames are dropped and counted (RT-8)")
        #expect(throws: DSPError.self) { _ = try SampleRing(channelCount: 0, capacity: 16) }
    }

    @Test func resultBindingsAreNamedByWhatTheyHold() {
        let value = StateBox(Float(0)), frame = StateBox(ScalarFrame.none), vector = StateBox([Float]())
        #expect(value.binding.boundResult.name == "Binding<Float>" && frame.binding.boundResult.name == "Binding<ScalarFrame>")
        #expect(vector.binding.boundResult.name == "Binding<[Float]>" && vector.binding.boundResult.kind == .vector)
        #expect(value.binding.boundResult == value.binding.boundResult && value.binding.boundResult != frame.binding.boundResult)
    }
}
