import Foundation
import Testing
import ZTronDSPTesting
@testable import ZTronDSPCore

/// The compiled plan at work, driven offline: the same plan and the same blocks the engine
/// runs, without a thread or a clock (WP-311a, WP-321a, WP-323, WP-326, WP-339).
@Suite("Plan execution")
struct ExecutionTests {
    private let format = SignalFormat(sampleRate: 48_000, channelCount: 1)
    private let signal = TestSignal.whiteNoise(count: 4_800, seed: 311)

    // MARK: Kernels

    @Test func aChainOfGainsIsWhatItsDescriptionSays() throws {
        let output = try Pipeline { TestGain(0.5); TestGain(4); TestGain(0.25) }.process(signal, format: format)
        #expect(output == signal.map { ($0 * 0.5) * 4 * 0.25 }, "the factors are applied in sequence")
        #expect(try Pipeline().process(signal, format: format) == signal, "an empty pipeline passes the signal")
        #expect(try Pipeline { TestGain(1) }.process(signal, format: format) == signal)
    }

    /// F1 and F4: the fused plan is bit-identical to the unfused one.
    @Test func fusedAndUnfusedGainsAgreeBitForBit() throws {
        let fused = Pipeline { TestGain(0.37); TestGain(1); TestGain(2.9); TestGain(0.11) }
        // A kernel of the caller's own between the gains keeps them apart (EXT-2).
        let unfused = Pipeline { TestGain(0.37); TestBarrier(); TestGain(1); TestBarrier(); TestGain(2.9); TestBarrier(); TestGain(0.11) }
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000)
        #expect(try compiler.lower(fused.stages, environment: environment, blockSize: 512).steps.count == 1)
        #expect(try compiler.lower(unfused.stages, environment: environment, blockSize: 512).steps.count == 6)
        #expect(try fused.process(signal, format: format) == unfused.process(signal, format: format))
    }

    @Test(arguments: [1, 7, 64, 480, 512, 4_096])
    func theOutputDoesNotDependOnTheBlockSize(blockSize: Int) throws {
        let pipeline = Pipeline { TestGain(0.5); TestDelay(37); TestGain(3); TestHalve() }
        let reference = try pipeline.process(signal, format: format, blockSize: 512)
        #expect(try pipeline.process(signal, format: format, blockSize: blockSize) == reference)
        #expect(reference.count == signal.count / 2)
    }

    @Test func implementationsBoundBySizeComputeTheSameThing() throws {
        // A block of 512 binds the gain kernel to vDSP, a block of 64 to the C loop (SEL-3).
        let pipeline = Pipeline { TestGain(0.731) }
        let large = try pipeline.process(signal, format: format, blockSize: 512)
        let small = try pipeline.process(signal, format: format, blockSize: 64)
        #expect(large == small, "the element-wise implementations agree bit for bit (SEL-6)")
        let forced = try pipeline.environment(\.implementation, .native).process(signal, format: format, blockSize: 512)
        #expect(forced == large)
    }

    // MARK: Stages written outside the core (WP-339)

    @Test func aSampleProcessorRunsLikeAnyStage() throws {
        let output = try Pipeline { TestGain(2); TestDelay(10) }.process(signal, format: format)
        let expected = [Float](repeating: 0, count: 10) + signal.dropLast(10).map { -($0 * 2) }
        #expect(output == expected)
        #expect(try Pipeline { TestDelay(0) }.process(signal, format: format) == signal.map { -$0 })
    }

    @Test func aCustomKernelMayChangeTheRate() throws {
        let stream = CollectingSink<Samples>()
        let output = try Pipeline { TestHalve(); TestGain(2); Emit(to: stream) }.process(signal, format: format, blockSize: 63)
        #expect(output == stride(from: 0, to: signal.count, by: 2).map { signal[$0] * 2 }, "every second sample, whatever the block size")
        #expect(stream.samples == output)
        // Downstream of the rate change the sequence runs at half the rate (ENV-1).
        #expect(stream.environment?.sampleRate == 24_000 && stream.environment?.nyquistFrequency == 12_000)
        expectClose(stream.times.last ?? 0, Double(stream.indices.last ?? 0) / 24_000, .absolute(1e-9))
    }

    @Test func latencyIsAccountedForInTheEnvironmentAndInFrameTimes() throws {
        let stream = CollectingSink<Samples>()
        _ = try Pipeline { TestDelay(480); Emit(to: stream) }.process(signal, format: format)
        #expect(stream.environment?.latency == 0.01, "480 frames at 48 kHz (REAL-5)")
        #expect(stream.times.first == -0.01, "the first block out describes the signal 10 ms before the first sample in")
        // The reported latency equals the measured delay of an impulse.
        let impulse = TestSignal.impulse(count: 2_000, at: 100)
        let delayed = try Pipeline { TestDelay(480) }.process(impulse, format: format)
        #expect(delayed.firstIndex { $0 != 0 } == 100 + 480)
    }

    @Test func multichannelBlocksKeepTheirChannelsApart() throws {
        let stereo = SignalFormat(sampleRate: 44_100, channelCount: 2)
        let left = TestSignal.whiteNoise(count: 1_000, seed: 1), right = TestSignal.whiteNoise(count: 1_000, seed: 2)
        let output = try Pipeline { TestGain(0.5); TestDelay(3) }.process(channels: [left, right], format: stereo)
        #expect(output.count == 2)
        #expect(output[0] == [0, 0, 0] + left.dropLast(3).map { -($0 * 0.5) })
        #expect(output[1] == [0, 0, 0] + right.dropLast(3).map { -($0 * 0.5) })
    }

    // MARK: Nodes, branches and sinks (WP-321a, WP-326)

    @Test func aBranchLeavesTheMainLineBitIdentical() throws {
        let frames = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let plain = Pipeline { TestGain(0.5); TestDelay(5); TestGain(3) }
        let tapped = Pipeline {
            TestGain(0.5)
            Tap { TestFramer(frame: 64, hop: 16); TestMagnitude(); Emit(to: frames) }
            TestDelay(5)
            Tap { TestGain(100) }
            TestGain(3)
        }
        #expect(try tapped.process(signal, format: format) == plain.process(signal, format: format))
        #expect(frames.frameCount == (signal.count - 64) / 16 + 1, "one frame per hop once the first frame is full")
    }

    @Test func nodesRunInDeclaredOrderAtTheirTapPosition() throws {
        let complex = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>()
        let magnitudes = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let means = CollectingSink<Scalar>()
        let input = (0 ..< 400).map { Float($0) }
        try Pipeline {
            TestGain(2)                                 // the tap hears the signal after the gain
            Tap {
                TestFramer(frame: 8, hop: 4)
                Emit(to: complex)
                TestMagnitude()
                Emit(to: magnitudes)
                TestMean()
                Emit(to: means)
            }
        }.run(on: input, format: format, blockSize: 30)

        // Frame k ends at sample 7 + 4k and holds, as its five "bins", the newest five samples.
        #expect(complex.frameCount == 99 && magnitudes.frameCount == 99 && means.frameCount == 99)
        for k in [0, 1, 50, 98] {
            let newest = (0 ..< 5).map { Float(2 * (7 + 4 * k - 4 + $0)) }
            #expect(complex.reals[k] == newest)
            expectClose(magnitudes.reals[k], newest.map { $0 * Float(2).squareRoot() }, .relative(1e-6))
            expectClose(means.scalars[k].value, newest.reduce(0, +) / 5 * Float(2).squareRoot(), .relative(1e-6))
            #expect(means.scalars[k].confidence == 1)
        }
        #expect(complex.indices == Array(0 ..< 99), "frames are numbered from 0 in their own stream")
        #expect(magnitudes.indices == Array(0 ..< 99) && means.indices == Array(0 ..< 99))
        // A causal frame is stamped with the time of its newest sample.
        expectClose(complex.times, (0 ..< 99).map { Double(7 + 4 * $0) / 48_000 }, .absolute(1e-12))
        #expect(magnitudes.times == complex.times && means.times == complex.times, "a frame keeps its time down the branch")
    }

    @Test func aSinkLearnsWhatItsRowsAre() throws {
        let frames = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let values = CollectingSink<Scalar>()
        try Pipeline {
            Tap { TestFramer(frame: 64, hop: 16); TestMagnitude(); Emit(to: frames); TestMean(); Emit(to: values) }
        }.run(on: signal, format: format)
        #expect(frames.axis == .linearFrequency(binCount: 33, nyquist: 24_000))
        #expect(frames.environment?.frameSize == 64 && frames.environment?.hopSize == 16 && frames.environment?.featureRate == 3_000)
        #expect(values.axis == nil && values.environment?.sampleRate == 3_000, "a scalar track is a sequence at the feature rate")
        #expect(frames.claims == 1 && frames.releases == 1 && values.claims == 1 && values.releases == 1)
    }

    @Test func sequenceStagesRunOnAFeatureRateSequence() throws {
        let plain = CollectingSink<Scalar>(), scaled = CollectingSink<Scalar>()
        try Pipeline {
            TestFramer(frame: 64, hop: 16)
            TestMagnitude()
            TestMean()
            Emit(to: plain)
            TestGain(2)
            TestGain(1.5)
            Emit(to: scaled)
        }.run(on: signal, format: format)
        #expect(scaled.frameCount == plain.frameCount && plain.frameCount > 100)
        #expect(scaled.scalars.map(\.value) == plain.scalars.map { ($0.value * 2) * 1.5 })
        #expect(scaled.scalars.allSatisfy { $0.confidence == 1 }, "a filter changes the value, not the confidence of the measurement")
    }

    @Test func theMainLineMayEndInAnyDomain() throws {
        let frames: [[Float]] = try Pipeline { TestFramer(frame: 64, hop: 16); TestMagnitude() }.process(signal, format: format)
        #expect(frames.count == (signal.count - 64) / 16 + 1 && frames[0].count == 33)
        let scalars: [ScalarFrame] = try Pipeline { TestFramer(frame: 64, hop: 16); TestMagnitude(); TestMean() }.process(signal, format: format)
        #expect(scalars.count == frames.count)
        expectClose(scalars[3].value, frames[3].reduce(0, +) / 33, .relative(1e-6))
    }

    // MARK: Shared work (WP-310, F5)

    @Test func threeTapsWithOneFramingCostOneFramePerHop() throws {
        let probe = TestProbe()
        let a = CountingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), b = CountingSink<Scalar>()
        let c = CountingSink<Spectrum<LinearFrequency, ComplexValues>>()
        try Pipeline {
            Tap { TestFramer(frame: 64, hop: 16, probe: probe); TestMagnitude(probe: probe); Emit(to: a) }
            Tap { TestFramer(frame: 64, hop: 16, probe: probe); TestMagnitude(probe: probe); TestMean(); Emit(to: b) }
            Tap { TestFramer(frame: 64, hop: 16, probe: probe); Emit(to: c) }
        }.run(on: signal, format: format)
        let hops = (signal.count - 64) / 16 + 1
        #expect(probe.framerNodesMade == 1, "one framer for three taps")
        #expect(probe.framesFramed == hops, "one frame per hop, not three")
        #expect(probe.magnitudeNodesMade == 1 && probe.magnitudesTaken == hops, "and the equal step that follows is shared too")
        #expect(a.frames == hops && b.frames == hops && c.frames == hops, "every tap still gets every frame")
    }

    // MARK: Constant activations (ACT-3, ACT-4)

    @Test func aConstantSwitchIsCompiledAway() throws {
        let off = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>(), on = CollectingSink<Samples>()
        let pipeline = Pipeline {
            TestGain(0.5)
            TestDelay(10, isActive: false)                      // bypassed: the signal passes unchanged
            Tap(isActive: .bypassed) { TestFramer(frame: 64, hop: 16); Emit(to: off) }
            Tap { Emit(to: on); TestFramer(frame: 64, hop: 16, isActive: false); Emit(to: off) }
            TestGain(2, isActive: true)
        }
        #expect(try pipeline.process(signal, format: format) == signal.map { ($0 * 0.5) * 2 })
        #expect(off.frameCount == 0 && off.claims == 0, "a sink in a removed branch is not even claimed")
        #expect(on.samples == signal.map { $0 * 0.5 }, "what precedes the suspended stage still runs")
    }

    // MARK: Sinks (ATT-5)

    @Test func aSinkHasOneWriter() throws {
        let sink = CollectingSink<Samples>()
        #expect(throws: DSPError.sinkInUse(sink: "CollectingSink<Samples>")) {
            try Pipeline { Emit(to: sink); TestGain(2); Emit(to: sink) }.run(on: signal, format: format)
        }
        #expect(sink.claims == 0, "a pipeline that names one sink twice claims nothing")

        // A sink held by a live attachment cannot be claimed by another.
        let first = try OfflineRunner(stages: Pipeline().emit(to: sink).stages, format: format, blockSize: 512, crossovers: .shipped)
        #expect(SinkRegistry.isClaimed(ObjectIdentifier(sink)))
        #expect(throws: DSPError.sinkInUse(sink: "CollectingSink<Samples>")) {
            try Pipeline().emit(to: sink).run(on: signal, format: format)
        }
        first.finish()
        #expect(!SinkRegistry.isClaimed(ObjectIdentifier(sink)))
        #expect(throws: Never.self) { try Pipeline().emit(to: sink).run(on: signal, format: format) }
        #expect(sink.claims == 2 && sink.releases == 2, "once the first is gone, the sink can be written again")
    }

    @Test func aSinkThatRefusesItsClaimFailsTheAttachmentAndReleasesTheOthers() throws {
        final class Refusing: FeatureSink, @unchecked Sendable {
            typealias Domain = Samples
            func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) { throw .resourceAllocationFailed(what: "storage") }
            func write(_ frame: FrameView) {}
            func release() {}
        }
        let good = CollectingSink<Samples>()
        #expect(throws: DSPError.self) { try Pipeline { Emit(to: good); Emit(to: Refusing()) }.run(on: signal, format: format) }
        #expect(good.claims == 1 && good.releases == 1)
        #expect(!SinkRegistry.isClaimed(ObjectIdentifier(good)))
    }

    // MARK: Results (OUT-1)

    @Test @MainActor func aBoundResultReceivesTheLatestValue() throws {
        let value = StateBox(Float(-1)), frame = StateBox(ScalarFrame.none), vector = StateBox([Float]())
        let scalars: [ScalarFrame] = try Pipeline {
            TestFramer(frame: 64, hop: 16)
            TestMagnitude()
            Emit(to: vector.binding)
            TestMean()
            Emit(to: value.binding)
            Emit(to: frame.binding)
        }.process(signal, format: format)
        let last = try #require(scalars.last)
        #expect(value.value == last.value && frame.value == last, "the binding holds the last result")
        #expect(vector.value.count == 33)
        #expect(value.writes == 1 && frame.writes == 1 && vector.writes == 1)
        // A pipeline that produced no result writes nothing.
        let untouched = StateBox(Float(7))
        try Pipeline { TestFramer(frame: 64, hop: 16); TestMagnitude(); TestMean(); Emit(to: untouched.binding) }
            .run(on: [Float](repeating: 0, count: 10), format: format)
        #expect(untouched.value == 7 && untouched.writes == 0)
    }

    // MARK: Guards

    @Test func nonFiniteInputBecomesZero() throws {
        let fixture = StressFixture.nonFiniteSignal(count: 2_000)
        let output = try Pipeline { TestGain(2) }.process(fixture.samples, format: format)
        #expect(output.allSatisfy { $0.isFinite }, "no NaN and no infinity gets past the input (NUM-1)")
        #expect(output == fixture.samples.map { $0.isFinite ? $0 * 2 : 0 })
        let runner = try OfflineRunner(stages: [], format: format, blockSize: 512, crossovers: .shipped)
        runner.run([fixture.samples])
        #expect(runner.nonFiniteCount == fixture.nonFiniteCount)
    }

    @Test func invalidOfflineRequestsAreTypedErrors() {
        #expect(throws: DSPError.self) { try Pipeline().process(signal, format: SignalFormat(sampleRate: 0)) }
        #expect(throws: DSPError.self) { try Pipeline().process(signal, format: format, blockSize: 0) }
        #expect(throws: DSPError.self) { try Pipeline().process(channels: [signal], format: SignalFormat(sampleRate: 48_000, channelCount: 2)) }
        #expect(throws: DSPError.self) { try Pipeline { TestGain(.infinity) }.process(signal, format: format) }
        #expect(throws: Never.self) { try Pipeline().process([Float](), format: format) }
    }

    // MARK: The real-time audit (RT-7, layer 3)

    @Test func aPlanWithKernelsNodesBranchesAndSinksRunsWithoutAllocating() throws {
        let frames = CountingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), values = CountingSink<Scalar>()
        let samples = CountingSink<Samples>()
        let pipeline = Pipeline {
            TestGain(0.5)
            TestDelay(17)
            Tap { TestFramer(frame: 256, hop: 64); TestMagnitude(); Emit(to: frames); TestMean(); TestGain(2); Emit(to: values) }
            Tap { TestFramer(frame: 256, hop: 64); TestMagnitude(); TestMean(); Emit(to: CountingSink<Scalar>()) }
            TestHalve()
            TestGain(3)
            Emit(to: samples)
        }
        let runner = try OfflineRunner(stages: pipeline.stages, format: format, blockSize: 512, crossovers: .shipped)
        defer { runner.finish() }
        let buffer = try AudioBuffer(channels: [TestSignal.whiteNoise(count: 512, seed: 5)])
        let plan = runner.plan
        plan.output = nil       // the runner's own collection of the main line allocates; the plan must not
        // One pass outside the audit: first calls may instantiate metadata.
        plan.process(FrameView(samples: buffer.block(), index: 0, time: 0))
        expectNoAllocations {
            var block = 1
            while block <= 1_000 {
                plan.process(FrameView(samples: buffer.block(), index: block &* 512, time: Double(block) * 512 / 48_000))
                block += 1
            }
        }
        #expect(frames.frames > 7_000 && values.frames == frames.frames && samples.frames == 1_001)
    }
}
