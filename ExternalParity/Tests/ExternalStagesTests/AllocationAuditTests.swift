import CExternalKernels
import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// The real-time audit of the three stages (RT-2, RT-7 layer 3; EXT-4): 1 000 blocks without
/// one request to the heap. The suite runs in Debug and in Release (CR-002).
///
/// A processor and a kernel are objects of the suite's own, so the test runs them on its own
/// thread inside `expectNoAllocations`. A node only runs inside a plan: `expectNoAllocationsRunning`
/// runs one block by block on the test's own thread, so the node is held to RT-2 there as the
/// stock stages are (EXT-3). Every stage is also audited where it runs in an app: on an
/// engine's thread, with `ThreadAllocationAudit`.
@Suite("Allocation audit", .disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
struct AllocationAuditTests {
    let noise = TestSignal.whiteNoise(count: 512, seed: 17, amplitude: 0.5)

    @Test func theProbeCountsWhatAnAllocatingStageDoes() async throws {
        // The control case: a stage that allocates in `process` fails the audit, so a pass means something.
        final class Leaky: SampleProcessor {
            var latencyFrames: Int { 0 }
            var settlingFrames: Int { 0 }
            func process(_ block: inout AudioBlock) { forceAllocation(byteCount: 48) }
            func reset() {}
        }
        struct LeakyStage: SequenceStage {
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                context.emit(.processor(CustomProcessor(name: "Leaky", key: 0) { _ throws(DSPError) -> any SampleProcessor in Leaky() }))
            }
        }
        let processor = Leaky()
        let buffer = try AudioBuffer(channelCount: 1, capacity: 8)
        let direct = try countAllocations {
            var block = buffer.block()
            processor.process(&block)
        }
        #expect(direct.allocations == 1 && direct.deallocations == 1, "the probe is live: \(direct)")
        await withKnownIssue("the control case of the engine audit: a stage that allocates is counted") {
            try await expectNoAllocationsOnTheEngineThread(Pipeline { LeakyStage() }, blocks: 50, "a stage that allocates")
        }
    }

    @Test func theGainProcessorRunsAThousandBlocksWithoutAllocating() throws {
        let processor = try ExternalGainProcessor(factors: [0.5, -2])
        let buffer = try AudioBuffer(channels: [noise, noise])
        // One block outside the audit: a first call may instantiate metadata.
        var warm = buffer.block()
        processor.process(&warm)
        expectNoAllocations("ExternalGainProcessor, 1 000 blocks of 512 frames") {
            var block = buffer.block()
            var index = 0
            while index < 1_000 {
                processor.process(&block)
                processor.reset()
                index += 1
            }
        }
        // Small blocks take the plain loop of the toolkit, large ones vDSP: neither allocates.
        expectNoAllocations("ExternalGainProcessor, blocks of 1 to 511 frames") {
            var frames = 1
            while frames < 512 {
                var block = buffer.block(frameCount: frames)
                processor.process(&block)
                frames += 1
            }
        }
        #expect(buffer.array(ofChannel: 0).allSatisfy { $0.isFinite })
    }

    @Test func theGainProcessorRampsOutOfPlaceAThousandBlocksWithoutAllocating() throws {
        // What a plan calls: one block read, another written, and new factors between two blocks,
        // each a ramp of 480 frames that spans blocks, for every channel or one per channel.
        let processor = try ExternalGainProcessor(factors: [0.5, -2], rampFrames: 480)
        let input = try AudioBuffer(channels: [noise, noise])
        let output = try AudioBuffer(channelCount: 3, capacity: 512)
        let every: [Double] = [0.25], each: [Double] = [1, -0.5]
        var warm = output.block()
        processor.process(input.block(), into: &warm)
        every.withUnsafeBufferPointer { every in
            each.withUnsafeBufferPointer { each in
                expectNoAllocations("ExternalGainProcessor out of place, 1 000 blocks of 512 frames with value updates") {
                    var block = output.block()
                    var index = 0
                    while index < 1_000 {
                        if index % 10 == 3 { processor.setValues(index % 20 == 3 ? every : each) }
                        processor.process(input.block(), into: &block)
                        if index == 700 { processor.reset() }
                        index += 1
                    }
                }
            }
        }
        #expect(output.array(ofChannel: 1).allSatisfy { $0.isFinite })
    }

    @Test func theMelNodeRunsOnTheTestsThreadWithoutAllocating() throws {
        // The node in a plan that the test's own thread runs block by block (EXT-3): no engine,
        // no thread of its own. Banded products of every length, then the dense product of 128
        // bands of 8 193 bins, in blocks large enough that the transform is full before the
        // audit opens.
        typealias Mel = Spectrum<MelFrequency, PowerValues>
        let banded = CollectingCount<Mel>()
        let counts = try expectNoAllocationsRunning(
            Pipeline { STFT(frame: 2_048, hop: 512); Power(); ExternalMelScale(bands: 128); Emit(to: banded) }, "ExternalMelScale, banded, on the test's thread")
        #expect(counts.allocations == 0 && counts.deallocations == 0, "\(counts)")
        #expect(banded.frames >= 1_000, "the node did run: \(banded.frames) frames")
        let dense = CollectingCount<Mel>()
        try expectNoAllocationsRunning(
            Pipeline { STFT(frame: 16_384, hop: 512); Power(); ExternalMelScale(bands: 128); Emit(to: dense) }, blockSize: 4_096, blocks: 100,
            "ExternalMelScale, dense, on the test's thread")
        #expect(dense.frames >= 800, "the node did run: \(dense.frames) frames")
        // The three stages of the suite in one plan, on this thread.
        try expectNoAllocationsRunning(
            Pipeline {
                ExternalGain(.decibels(-3))
                ExternalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
                Tap { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40); Emit(to: CollectingCount<Mel>()) }
            }, "gain, low-pass and mel projection on the test's thread")
        try expectNoAllocationsRunning(
            Pipeline { ExternalGain(channels: [.decibels(-3), .linear(-1)]); ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 6) },
            format: SignalFormat(sampleRate: 44_100, channelCount: 2), blockSize: 333, "gain and low-pass, two channels in blocks of 333, on the test's thread")
    }

    @Test(arguments: [false, true])
    func theBiquadKernelRunsAThousandBlocksWithoutAllocating(isDouble: Bool) throws {
        // The kernel in a C plan of the public plan runner, as an engine runs it: with a bound
        // switch that goes off and on again, and with new coefficients set while it runs.
        let coefficients = try BiquadKernelTests.coefficients()
        let other = try BiquadKernelTests.coefficients(cutoff: 2_500)
        let plan = try #require(ztd_plan_create(1, 2, 512))
        defer { ztd_plan_destroy(plan) }
        try #require(ztd_plan_append(plan, extk_biquad_create(2, 3, coefficients, isDouble, ZTD_IMPLEMENTATION_ACCELERATE), true) == 0)
        try #require(ztd_plan_make_switchable(plan, 0, 512, true))
        let input = try AudioBuffer(channels: [noise, noise])
        let output = try AudioBuffer(channelCount: 2, capacity: 512)
        let source = input.block().constantChannelTable, target = output.block().channelTable
        #expect(ztd_plan_run(plan, source, target, 2, 512) == 512)
        _ = other.withUnsafeBufferPointer { values in
            expectNoAllocations("extk_biquad, double precision \(isDouble), 1 000 blocks of 512 frames") {
                var command = ztd_command_t()
                var index = 0
                while index < 1_000 {
                    if index % 100 == 50 {
                        // Off at one block, on again a few blocks later: fade, bypass, pre-roll, fade.
                        command.target = 0
                        command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
                        command.scalar.0 = index % 200 == 50 ? 0 : 1
                        ztd_plan_command(plan, &command)
                    }
                    if index % 250 == 125 {
                        command.target = 0
                        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
                        command.count = UInt32(values.count)
                        command.values = UnsafeRawPointer(values.baseAddress)
                        ztd_plan_command(plan, &command)
                    }
                    _ = ztd_plan_run(plan, source, target, 2, 512)
                    index += 1
                }
                ztd_plan_reset(plan)
            }
        }
        #expect(output.array(ofChannel: 0).allSatisfy { $0.isFinite })
    }

    @Test func theMultichannelKernelRunsAThousandBlocksWithoutAllocating() throws {
        // Three channels: the form on vDSP_biquadm, with a channel that goes quiet and is parked,
        // new coefficients while it runs, and a reset.
        let coefficients = try BiquadKernelTests.coefficients()
        let other = try BiquadKernelTests.coefficients(cutoff: 2_500)
        var kernel = extk_biquad_create(3, UInt32(coefficients.count / 5), coefficients, false, ZTD_IMPLEMENTATION_ACCELERATE)
        defer { ztd_kernel_destroy(&kernel) }
        try #require(!ztd_kernel_is_null(&kernel))
        let loud = try AudioBuffer(channels: [noise, noise, noise])
        let partly = try AudioBuffer(channels: [noise, [Float](repeating: 0, count: 512), noise])
        let output = try AudioBuffer(channelCount: 3, capacity: 512)
        let process = try #require(kernel.process), command = try #require(kernel.command), reset = try #require(kernel.reset)
        let state = kernel.state
        let sources = [loud.block().constantChannelTable, partly.block().constantChannelTable], target = output.block().channelTable
        #expect(process(state, sources[0], target, 3, 512) == 512)
        _ = other.withUnsafeBufferPointer { values in
            expectNoAllocations("extk_biquad on vDSP_biquadm, 1 000 blocks of 512 frames") {
                var message = ztd_command_t()
                message.kind = UInt32(ZTD_COMMAND_SET_VALUES)
                message.count = UInt32(values.count)
                message.values = UnsafeRawPointer(values.baseAddress)
                var index = 0
                while index < 1_000 {
                    // Blocks 100 to 199 of every 300 leave the second channel quiet: it is parked and woken.
                    _ = process(state, sources[index % 300 >= 100 && index % 300 < 200 ? 1 : 0], target, 3, 512)
                    if index % 250 == 125 { command(state, &message) }
                    if index == 700 { reset(state) }
                    index += 1
                }
            }
        }
        #expect(output.array(ofChannel: 2).allSatisfy { $0.isFinite })
    }

    @Test func theThreeRunOnTheRealTimeAnalysisThreadWithoutAllocating() async throws {
        // The audits above run on the thread a source is paced on as fast as it is processed. A
        // source paced in real time is run on the engine's analysis thread itself: 1 000 blocks
        // of 64 frames there, a block every 1.3 ms.
        typealias Mel = Spectrum<MelFrequency, PowerValues>
        let sink = CollectingCount<Mel>()
        let pipeline = Pipeline {
            ExternalGain(.decibels(-3))
            ExternalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
            Tap { STFT(frame: 256, hop: 64); Power(); ExternalMelScale(bands: 20); Emit(to: sink) }
        }
        try await expectNoAllocationsOnTheEngineThread(pipeline, blockSize: 64, pacing: .realTime, "gain, low-pass and mel projection on the analysis thread")
        #expect(sink.frames >= 1_000)
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 6) }, format: SignalFormat(sampleRate: 48_000, channelCount: 3),
            blockSize: 64, pacing: .realTime, "the low-pass on three channels, on the analysis thread")
    }

    @Test func theGainRunsOnAnEngineThreadWithoutAllocating() async throws {
        try await expectNoAllocationsOnTheEngineThread(Pipeline { ExternalGain(.decibels(-3)) }, "ExternalGain")
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        try await expectNoAllocationsOnTheEngineThread(Pipeline { ExternalGain(channels: [.decibels(-3), .linear(-1)]) }, format: stereo, "ExternalGain, a gain per channel")
    }

    @Test func theLowPassRunsOnAnEngineThreadWithoutAllocating() async throws {
        try await expectNoAllocationsOnTheEngineThread(Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 8) }, "ExternalLowPass, single precision")
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 8) }.environment(\.biquadPrecision, .double), "ExternalLowPass, double precision")
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { ExternalLowPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), cutoff: .hertz(3_000), order: 5) },
            format: SignalFormat(sampleRate: 44_100, channelCount: 2), blockSize: 333, "ExternalLowPass, two channels, blocks of 333")
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 8) }, format: SignalFormat(sampleRate: 48_000, channelCount: 4),
            "ExternalLowPass, four channels on one setup")
    }

    @Test func theMelNodeRunsOnAnEngineThreadWithoutAllocating() async throws {
        typealias Mel = Spectrum<MelFrequency, PowerValues>
        // Banded products: bands of every length, so the scalar loop, the 8-lane loop and vDSP all run.
        let banded = CollectingCount<Mel>()
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { STFT(frame: 2_048, hop: 512); Power(); ExternalMelScale(bands: 128); Emit(to: banded) }, "ExternalMelScale, banded")
        #expect(banded.frames >= 1_000, "the node did run: \(banded.frames) frames")
        // The dense product: 128 bands of 8 193 bins.
        let dense = CollectingCount<Mel>()
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline { STFT(frame: 16_384, hop: 512); Power(); ExternalMelScale(bands: 128); Emit(to: dense) }, blocks: 300, warmUp: 40, "ExternalMelScale, dense")
        #expect(dense.frames >= 300)
    }

    @Test func theThreeTogetherRunTenThousandBlocksWithoutAllocating() async throws {
        // What RT-7 asks of a stock pipeline: 10 000 blocks.
        typealias Mel = Spectrum<MelFrequency, DecibelValues>
        let sink = CollectingCount<Mel>()
        let pipeline = Pipeline {
            ExternalGain(.decibels(-3))
            ExternalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
            Tap { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40); Decibels(); Emit(to: sink) }
        }
        try await expectNoAllocationsOnTheEngineThread(pipeline, blockSize: 256, blocks: 10_000, "gain, low-pass and mel projection")
        #expect(sink.frames >= 10_000)
    }
}
