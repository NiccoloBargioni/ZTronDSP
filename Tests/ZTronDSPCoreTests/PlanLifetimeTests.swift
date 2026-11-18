import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Plan ownership (WP-311b), shared framing under switches (WP-310, ACT-9) and the measuring
/// spelling (WP-336).
@Suite("Plan lifetime and shared work")
struct PlanLifetimeTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 40, seed: 61)

    // MARK: WP-311b

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aThousandPlansLeaveNothingBehind() throws {
        let stages = Pipeline { TestGain(0.5); TestBiquad(count: 4); TestFIR([0.25, 0.5, 0.25]); TestDelay(8) }
            .tap { $0.testFramer(frame: 256, hop: 64).testMagnitude().emit(to: CountingSink()) }.stages
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 2, blockSize: 256)
        func cycle() throws {
            let lowered = try compiler.lower(stages, environment: environment, blockSize: 256)
            let plan = try ExecutionPlan(lowered: lowered, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
            let block = try AudioBuffer(channelCount: 2, capacity: 256)
            plan.process(FrameView(samples: block.block(), index: 0, time: 0))
        }
        for _ in 0 ..< 20 { try cycle() }                           // caches and lazy statics are warm
        var failure: DSPError?
        let counts = try countAllocations {
            var count = 0
            while count < 1_000 {
                do { try cycle() } catch { failure = error as? DSPError }
                count += 1
            }
        }
        #expect(failure == nil)
        #expect(counts.allocations > 1_000, "the probe saw the plans being made")
        #expect(counts.allocations == counts.deallocations, "10³ create / destroy cycles free everything they allocated: \(counts)")
    }

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func nothingIsFreedOnTheThreadThatRunsThePlan() async throws {
        // A plan exchange on a running session: the old plan, its kernels and its buffers are
        // released by the control context, never by the thread that ran them (RT-3).
        let rig = Rig()
        let session = try await rig.engine.attach(Pipeline { TestSmoother(0.5, settling: 0); TestDelay(3) }, to: rig.source)
        try session.start()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [Array(noise[..<64])])
        for step in 0 ..< 30 {
            try await session.update(Pipeline { TestSmoother(0.5 + Float(step) * 0.01, settling: 64); TestDelay(3 + step % 2) })
            let counts = try countAllocations {
                var count = 0
                while count < 12 {
                    rig.source.write(block.block())
                    _ = runner.turn(now: 0)
                    count += 1
                }
            }
            #expect(counts.allocations == 0 && counts.deallocations == 0, "exchange \(step): \(counts)")
            #expect(session.core.runner.installedGeneration == UInt32(step + 2))
            rig.engine.core.flush()
        }
    }

    // MARK: WP-310, ACT-9

    @Test func sharedFramingRunsOnlyWhileAConsumerNeedsIt() async throws {
        let rig = Rig()
        let probe = TestProbe()
        let first = StateBox(true), second = StateBox(true)
        let a = CountingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), b = CountingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let c = CountingSink<Scalar>()
        let session = try await rig.engine.attach(
            Pipeline()
                .tap(isActive: first.binding) { $0.testFramer(frame: 64, hop: 64, probe: probe).testMagnitude(probe: probe).emit(to: a) }
                .tap(isActive: second.binding) { $0.testFramer(frame: 64, hop: 64, probe: probe).testMagnitude(probe: probe).emit(to: b) }
                .tap(isActive: second.binding) { $0.testFramer(frame: 64, hop: 64, probe: probe).testMagnitude(probe: probe).appending(TestMean()).emit(to: c) },
            to: rig.source)
        try session.start()
        rig.feed(Array(noise[..<640]))
        #expect(probe.framerNodesMade == 1 && probe.magnitudeNodesMade == 1, "three taps with one framing share it (F5)")
        #expect(probe.framesFramed == 10 && probe.magnitudesTaken == 10 && a.frames == 10 && b.frames == 10 && c.frames == 10, "one transform per hop")
        second.value = false
        await session.syncBindings()
        rig.feed(Array(noise[640 ..< 1_280]))
        #expect(probe.framesFramed == 20 && a.frames == 20 && b.frames == 10 && c.frames == 10, "the shared step runs for the consumer that is left")
        first.value = false
        await session.syncBindings()
        rig.feed(Array(noise[1_280 ..< 1_920]))
        #expect(probe.framesFramed == 20 && probe.magnitudesTaken == 20, "and not at all when every consumer is inactive (ACT-9)")
        first.value = true
        await session.syncBindings()
        rig.feed(Array(noise[1_920...]))
        #expect(probe.framesFramed == 30 && a.frames == 30 && b.frames == 10)
    }

    // MARK: WP-336

    @Test func aMeasuringStepLeavesTheSignalThatFollowsUntouched() async throws {
        let value = StateBox(Float(-1)), other = StateBox(Float(-1))
        let sink = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), plain = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let measured = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(Measuring(TestMean(), to: value.binding)).emit(to: sink)
        let expanded = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().tap { $0.appending(TestMean()).emit(to: other.binding) }.emit(to: sink)
        #expect(measured == expanded, "the measuring spelling equals its Tap expansion (OUT-1)")
        #expect(Measuring(TestMean(), to: value.binding, isActive: false).activation == .constant(false))
        let scalars = try await MainActor.run { () throws -> [ScalarFrame] in
            try measured.run(on: noise, format: format, blockSize: 64)
            try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: plain).run(on: noise, format: format, blockSize: 64)
            return try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestMean()).process(noise, format: format, blockSize: 64)
        }
        #expect(sink.reals == plain.reals, "the signal that follows a measuring step is bit-identical to the signal without it")
        #expect(value.value == scalars.last?.value && value.writes == 1)
    }
}
