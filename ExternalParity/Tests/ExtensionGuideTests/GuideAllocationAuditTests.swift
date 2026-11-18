import CExtensionGuide
import ExtensionGuide
import ExtensionGuideUI
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// The real-time audit of the guide's examples (RT-2, RT-7 layer 3): whatever an example runs
/// on the analysis thread runs 1 000 blocks without one request to the heap. The suite runs in
/// Debug and in Release (CR-002).
@Suite("Guide allocation audit", .disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
struct GuideAllocationAuditTests {
    let noise = TestSignal.whiteNoise(count: 512, seed: 23, amplitude: 0.5)

    @Test func theProcessorOfRowTwoRunsAThousandBlocksWithoutAllocating() throws {
        // snippet:begin audit-processor
        let processor = try DespikeProcessor(channelCount: 2)
        let buffer = try AudioBuffer(channels: [noise, noise])
        // One block outside the audit: a first call may instantiate metadata.
        var warm = buffer.block()
        processor.process(&warm)
        expectNoAllocations("DespikeProcessor, 1 000 blocks of 512 frames") {
            var block = buffer.block()
            var index = 0
            while index < 1_000 {
                processor.process(&block)
                if index % 100 == 99 { processor.reset() }
                index += 1
            }
        }
        // snippet:end audit-processor
        #expect(buffer.array(ofChannel: 1).allSatisfy { $0.isFinite })
    }

    @Test func theKernelOfRowThreeRunsAThousandBlocksWithoutAllocating() throws {
        // The kernel in a C plan of the public plan runner, as an engine runs it, with a bound
        // switch that goes off and on again: fade, bypass, reset, pre-roll, fade.
        let plan = try #require(ztd_plan_create(1, 2, 512))
        defer { ztd_plan_destroy(plan) }
        try #require(ztd_plan_append(plan, extg_comb_create(2, 48, 0.5), true) == 0)
        try #require(ztd_plan_make_switchable(plan, 0, 512, true))
        let input = try AudioBuffer(channels: [noise, noise])
        let output = try AudioBuffer(channelCount: 2, capacity: 512)
        let source = input.block().constantChannelTable, target = output.block().channelTable
        #expect(ztd_plan_run(plan, source, target, 2, 512) == 512)
        expectNoAllocations("extg_comb, 1 000 blocks of 512 frames") {
            var command = ztd_command_t()
            var index = 0
            while index < 1_000 {
                if index % 100 == 50 {
                    command.target = 0
                    command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
                    command.scalar.0 = index % 200 == 50 ? 0 : 1
                    ztd_plan_command(plan, &command)
                }
                _ = ztd_plan_run(plan, source, target, 2, 512)
                index += 1
            }
            ztd_plan_reset(plan)
        }
        #expect(output.array(ofChannel: 0).allSatisfy { $0.isFinite })
    }

    @Test func theStagesOfTheGuideRunOnAnEngineThreadWithoutAllocating() async throws {
        // Rows 1 to 5 and 9 in one pipeline, each where it runs in an app: the processor, the
        // kernel and the stock kernel of the emphasis on the main line; the two nodes and the
        // sink in branches.
        // snippet:begin audit-engine
        let flux = CollectingCount<Novelty>(), meter = PeakHoldMeter()
        let normalized = CollectingCount<Spectrum<LinearFrequency, MagnitudeValues>>()
        let pipeline = Pipeline()
            .despiked()
            .feedbackComb(delay: 0.001, feedback: 0.5)
            .preEmphasis()
            .tap { $0.stft(frame: 1_024, hop: 256).magnitude().spectralFlux().emit(to: flux) }
            .tap { $0.stft(frame: 1_024, hop: 256).magnitude().peakNormalized().emit(to: normalized) }
            .tap { $0.level(.rms).emit(to: meter) }
        try await expectNoAllocationsOnTheEngineThread(pipeline, "the stages of the guide")
        // snippet:end audit-engine
        #expect(flux.frames >= 1_000 && normalized.frames >= 1_000 && meter.peak > -60, "\(flux.frames) values of flux, \(normalized.frames) frames, a level of \(meter.peak)")
        // Two channels, blocks that are not a power of two.
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline().despiked().feedbackComb(delay: 0.002, feedback: -0.7), format: SignalFormat(sampleRate: 44_100, channelCount: 2), blockSize: 333,
            "the processor and the kernel, two channels, blocks of 333")
    }

    @Test func theStagesOfTheGuideRunOnTheRealTimeAnalysisThreadWithoutAllocating() async throws {
        // A source paced in real time is run on the engine's analysis thread itself: 1 000 blocks
        // of 64 frames there, a block every 1.3 ms.
        let flux = CollectingCount<Novelty>(), meter = PeakHoldMeter()
        let pipeline = Pipeline()
            .despiked()
            .feedbackComb(delay: 0.001, feedback: 0.5)
            .preEmphasis()
            .tap { $0.stft(frame: 256, hop: 64).magnitude().peakNormalized().spectralFlux().emit(to: flux) }
            .tap { $0.level(.rms, window: 0.01, hop: 0.005).emit(to: meter) }
        try await expectNoAllocationsOnTheEngineThread(pipeline, blockSize: 64, pacing: .realTime, "the stages of the guide on the analysis thread")
        #expect(flux.frames >= 1_000 && meter.peak > -60, "\(flux.frames) values of flux, a level of \(meter.peak)")
        // The metronome paced in real time renders on that thread too.
        let clicks = CollectingCount<Novelty>()
        let source = ClickSource(beatsPerMinute: 300, duration: Double((16 + 1_000 + 4) * 64) / 48_000)
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline().tap { $0.stft(frame: 256, hop: 64).magnitude().spectralFlux().emit(to: clicks) }, on: source, blockSize: 64,
            "ClickSource paced in real time")
        #expect(source.pacing == .realTime && clicks.frames >= 1_000)
    }

    @Test func theSourceOfRowSixRendersOnTheThreadThatRunsThePlanWithoutAllocating() async throws {
        // `.asFastAsPossible`: the engine asks the source for its blocks on the thread that
        // processes them, so the audit of that thread covers `render`.
        let blocks = 1_000, warmUp = 16
        let source = ClickSource(beatsPerMinute: 120, duration: Double((warmUp + blocks + 4) * 512) / 48_000, pacing: .asFastAsPossible)
        let flux = CollectingCount<Novelty>()
        try await expectNoAllocationsOnTheEngineThread(
            Pipeline().tap { $0.stft(frame: 1_024, hop: 256).magnitude().spectralFlux().emit(to: flux) }, on: source, blocks: blocks, warmUp: warmUp,
            "ClickSource and the flux of its clicks")
        #expect(flux.frames >= 1_000)
    }

    @Test func theAnalysisOfRowElevenRunsOnAnEngineThreadWithoutAllocating() async throws {
        let feed = HeatmapFeed(history: 256)
        try await expectNoAllocationsOnTheEngineThread(NormalizedSpectrogram.analysis(into: feed), "the analysis behind NormalizedSpectrogram")
        #expect(feed.rowCount == 513 && feed.columnCount > 0, "\(feed.rowCount) rows, \(feed.columnCount) columns")
    }
}
