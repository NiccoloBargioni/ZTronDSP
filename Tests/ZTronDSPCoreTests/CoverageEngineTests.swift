import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A switch whose first reading by a session has a consequence: the test says what happens when
/// the binding is read for the first time (BIND-4), and how often it was read.
///
/// SwiftUI reads a binding once when it is made, to have a value to start from. The binding is
/// therefore made once, here, and only what is read after that is counted.
private final class CoverageMovingSwitch: @unchecked Sendable {
    // Threading: the counts are behind the lock; the binding is a constant, read on the main
    // actor, as a session reads every binding (BIND-1).
    private let state: Locked<(isCounting: Bool, reads: Int)>
    let binding: Binding<Bool>

    init(onFirstRead: @escaping @Sendable () -> Void) {
        let state = Locked<(isCounting: Bool, reads: Int)>((false, 0))
        self.state = state
        binding = Binding(get: {
            let count = state.withLock { (state: inout (isCounting: Bool, reads: Int)) -> Int in
                guard state.isCounting else { return 0 }
                state.reads += 1
                return state.reads
            }
            if count == 1 { onFirstRead() }
            return true
        }, set: { _ in })
        state.withLock { $0.isCounting = true }
    }

    var readCount: Int { state.get().reads }
}

/// The paths of the engine that the suites of M3 never ran (COV-3), each as the rule it serves.
/// The engine is driven by hand, so every change lands at a block boundary the test chooses.
@Suite("Engine: switches, values and exchanges off the beaten path (COV-3)")
struct CoverageEngineTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 60, seed: 4_711)
    let ones = [Float](repeating: 1, count: 64)

    private func ones(_ blocks: Int) -> [Float] { [Float](repeating: 1, count: 64 * blocks) }

    // MARK: A group of kernels (ACT-6)

    /// ACT-6: stages under one `Group(isActive:)` are switched as one unit, and a group that
    /// holds kernels only runs as one kernel of the plan. Its latency is the sum of its stages'
    /// (REAL-5). A value change reaches the kernel inside it (§5.5.4); switched off, nothing
    /// inside it runs and the unprocessed signal is delayed by the group's latency (ACT-3,
    /// ACT-8); switched on, it starts cold and is pre-rolled (ACT-7); and a change of topology
    /// elsewhere keeps it, state included (SWAP-1).
    @Test func aGroupOfKernelsIsCommandedSwitchedAndKeptAsOne() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let counter = CallCounter()
        func pipeline(_ factor: Float) -> Pipeline<Samples, Samples> {
            Pipeline { ZTronDSPCore.Group(isActive: on.binding) { TestGain(factor); CountedDelay(counter, delay: 3) } }
        }
        let (session, probe) = try await rig.probed(pipeline(2))
        let plan = session.core.plan
        #expect(session.environment.latency == 3.0 / 48_000, "the delay of the stages inside")
        let isOneGroup = plan.lowered.steps.count == 1 && plan.lowered.steps[0].isKernelRegion
        #expect(isOneGroup && plan.kernelTargets.count == 2 && plan.switchTargets.count == 1, "one switched unit, two kernels a value can be sent to")

        // x[n − 3], the signal as the group delays it.
        let delayed = [Float](repeating: 0, count: 3) + noise
        func scaled(_ range: Range<Int>, by factor: Float) -> [Float] { delayed[range].map { (sample: Float) -> Float in sample * factor } }

        rig.feed(Array(noise[..<640]))
        #expect(probe.samples == scaled(0 ..< 640, by: 2))
        #expect(counter.blocks == 10)

        // Another value: the plan stays, the gain inside the group ramps for 10 ms and lands.
        try await session.update(pipeline(5))
        #expect(session.core.plan === plan && session.core.generation == 1, "the same topology: nothing is compiled")
        rig.feed(Array(noise[640 ..< 1_280]))
        #expect(Array(probe.samples[1_152...]) == scaled(1_152 ..< 1_280, by: 5), "480 frames of ramp, then the new factor exactly")
        let ramp = Array(probe.samples[640 ..< 1_152])
        let reference = scaled(640 ..< 1_152, by: 1)
        let gains = zip(ramp, reference).filter { abs($0.1) > 0.05 }.map { (pair: (Float, Float)) -> Float in pair.0 / pair.1 }
        #expect(gains.allSatisfy { $0 >= 1.999 && $0 <= 5.001 } && zip(gains, gains.dropFirst()).allSatisfy { $0 <= $1 + 1e-3 }, "the factor moves from 2 to 5 and never back")

        // Off: a fade of 10 ms to the input, three frames late; then the stages inside rest.
        let blocksBefore = counter.blocks
        await rig.set(on, to: false, of: session)
        rig.feed(Array(noise[1_280 ..< 1_920]))
        #expect(Array(probe.samples[1_760...]) == Array(delayed[1_760 ..< 1_920]), "bypassed: the unprocessed signal, at the group's latency")
        #expect(counter.blocks == blocksBefore + 8, "eight blocks of fade, and then not one call: \(counter.blocks - blocksBefore)")

        // On: reset, pre-rolled for its latency, faded in.
        let resetsBefore = counter.resets
        await rig.set(on, to: true, of: session)
        rig.feed(Array(noise[1_920 ..< 2_560]))
        #expect(counter.resets == resetsBefore + 1, "a stage that was off starts cold")
        #expect(Array(probe.samples[2_496...]) == scaled(2_496 ..< 2_560, by: 5), "after pre-roll and fade: the group's output, with the value it was last sent")

        // A tap added behind it: the group is taken over as it is, its delay line full.
        let sink = CollectingSink<Samples>()
        try await session.update(pipeline(5).tap { $0.emit(to: sink) })
        #expect(session.core.generation == 2)
        rig.feed(Array(noise[2_560 ..< 2_624]))
        #expect(sink.samples == scaled(2_560 ..< 2_624, by: 5), "the three frames of before the exchange come out first")
        #expect(counter.resets == resetsBefore + 1, "and nothing was reset")
        session.detach()
    }

    // MARK: A sink with a switch (ACT-3, ACT-11)

    /// ACT-3, §5.2 (`Emit`): "Switched off, the frames pass and the sink receives nothing".
    /// ACT-5: the switch is a flag in the plan; nothing is compiled, and the sink is neither
    /// released nor claimed again. ACT-11: a feed behind a switch that is off is not live.
    @Test func aBoundSwitchOnASinkStopsTheSinkAndNotTheSignal() async throws {
        let rig = Rig()
        let listening = StateBox(true)
        let sink = CollectingSink<Samples>()
        let feed = HeatmapFeed(history: 64)
        let (session, probe) = try await rig.probed(
            Pipeline { TestGain(2); Emit(to: sink, isActive: listening.binding); TestGain(3) }
                .tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: feed, isActive: listening.binding) })
        func doubled(_ range: Range<Int>) -> [Float] { noise[range].map { (sample: Float) -> Float in sample * 2 } }

        rig.feed(Array(noise[..<128]))
        #expect(sink.samples == doubled(0 ..< 128) && feed.columnCount == 2 && feed.isLive)

        await rig.set(listening, to: false, of: session)
        rig.feed(Array(noise[128 ..< 256]))
        #expect(sink.samples == doubled(0 ..< 128), "the sink receives nothing")
        #expect(feed.columnCount == 2 && !feed.isLive, "the feed keeps what it holds and is no longer live")

        await rig.set(listening, to: true, of: session)
        rig.feed(Array(noise[256 ..< 384]))
        #expect(sink.samples == doubled(0 ..< 128) + doubled(256 ..< 384), "switched on again, it receives what comes from then on")
        #expect(feed.columnCount == 4 && feed.isLive)

        let whole = noise[..<384].map { (sample: Float) -> Float in sample * 2 * 3 }
        #expect(probe.samples == whole, "the frames passed all the while")
        #expect(sink.claims == 1 && sink.releases == 0 && session.core.generation == 1, "a switch is not a new plan")
        session.detach()
    }

    // MARK: A group that holds a node (ACT-7)

    /// ACT-7: "On: the stage is reset and pre-rolled … and only then is faded in"; with nothing
    /// to settle the fade begins at once. A switch that is turned round in the middle of a fade
    /// goes on from where the fade stands (CLICK-1). ACT-3: bypassed, the stages inside do no
    /// work, and a sink inside the group receives nothing.
    @Test func aGroupWithANodeFadesInFromBypassedAndTurnsRoundInMidFade() async throws {
        let rig = Rig()
        let on = StateBox(false)
        let work = TestProbe()
        let inside = CollectingSink<Samples>()
        let (session, probe) = try await rig.probed(Pipeline {
            ZTronDSPCore.Group(isActive: on.binding) { TestGain(2); TestLate(latency: 0, chunk: 64, probe: work); Emit(to: inside) }
        })
        let resetsAtStart = work.framerResets

        rig.feed(ones(2))
        #expect(probe.samples == ones(2) && work.framesFramed == 0 && inside.samples.isEmpty, "bypassed from the start: the input passes, nothing inside runs")

        // On: two blocks into a fade of 480 frames …
        await rig.set(on, to: true, of: session)
        rig.feed(ones(2))
        #expect(work.framerResets == resetsAtStart + 1, "the stages inside start cold")
        // … and off again: two blocks back to the input, then bypassed.
        await rig.set(on, to: false, of: session)
        rig.feed(ones(3))
        #expect(work.framerResets == resetsAtStart + 1, "a fade that turns round resets nothing")

        // The input is 1 and the group makes −2 of it (the test node inverts). Frame j of the
        // fade has the weight j / 480 of the processed signal; turned round after 128 frames,
        // the fade is taken up at frame 480 − 128 of the way back.
        let step: Float = 1 / 480
        let unprocessed: Float = 1, processed: Float = -2
        var expected = ones(2)
        for frame in 0 ..< 128 { expected.append(unprocessed + Float(frame) * step * (processed - unprocessed)) }
        for frame in 0 ..< 128 { expected.append(processed + Float(352 + frame) * step * (unprocessed - processed)) }
        expected += ones(1)
        expectClose(probe.samples, expected, .absolute(1e-4), "in for 128 frames, back out for 128, then the input again")
        let largest = Click.largestStep(probe.samples, in: 0 ..< probe.samples.count), oneStep: Float = 3 * step * 1.01
        #expect(largest <= oneStep, "no jump where the fade begins, turns and ends: \(largest)")
        #expect(Array(probe.samples.suffix(64)) == ones(1), "bypassed again: the input, exactly")

        #expect(work.framesFramed == 4, "the stages inside ran while they were faded, four blocks, and then no more")
        let heard = inside.samples
        #expect(heard.count == 4 * 64 && heard.allSatisfy { $0 == processed }, "a sink inside the group hears the stages inside, while they run")
        rig.feed(ones(2))
        #expect(work.framesFramed == 4 && inside.samples.count == 4 * 64)
        session.detach()
    }

    /// ACT-3: a stage that keeps its domain is bypassed when it is off: "the signal passes
    /// through unchanged". On frames of bins that is no fade: the stage is skipped, and the
    /// frames pass as they came. ACT-5: a switch that is on changes nothing about what the stage
    /// does. ACT-10: switched on again, the stage starts cold.
    @Test func aBoundSwitchOnAStageOfBinsSkipsTheStageWhileItIsOff() async throws {
        typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
        let signal = Array(noise[..<(64 * 6)])
        let plain = try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().process(signal, format: format, blockSize: 64)
        func scaled(_ frames: ArraySlice<[Float]>, by factor: Float) -> [[Float]] {
            frames.map { (frame: [Float]) -> [Float] in frame.map { (value: Float) -> Float in value * factor } }
        }

        // With its switch on, the stage does what it does without one, whatever its factor.
        for factor in 1 ... 8 {
            let sink = CollectingSink<Magnitudes>()
            try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude()
                .appending(TestScaleBins(Float(factor), isActive: StateBox(true).binding)).emit(to: sink)
                .run(on: signal, format: format, blockSize: 64)
            #expect(sink.reals == scaled(plain[...], by: Float(factor)), "factor \(factor)")
        }

        // Live: off, the frames pass unscaled; on again, they are scaled, by a stage that was reset.
        let rig = Rig()
        let on = StateBox(true)
        let work = TestProbe()
        let sink = CollectingSink<Magnitudes>()
        let session = try await rig.engine.attach(
            Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestScaleBins(3, probe: work, isActive: on.binding)).emit(to: sink),
            to: rig.source)
        try session.start()
        let resetsAtStart = work.framerResets
        rig.feed(Array(signal[..<128]))
        await rig.set(on, to: false, of: session)
        rig.feed(Array(signal[128 ..< 256]))
        #expect(work.framerResets == resetsAtStart, "switching off resets nothing")
        await rig.set(on, to: true, of: session)
        rig.feed(Array(signal[256...]))
        #expect(sink.reals == scaled(plain[..<2], by: 3) + Array(plain[2 ..< 4]) + scaled(plain[4...], by: 3), "scaled, passed as they came, scaled again")
        #expect(work.framerResets == resetsAtStart + 1 && session.core.generation == 1, "switched on, the stage starts cold; nothing was compiled")
        session.detach()
    }

    /// ACT-5: every bound switch is read and forwarded (BIND-2), whatever became of its stage.
    /// A group whose content is off for good compiles to nothing (ACT-4): its switch then has
    /// nothing to move, and moving it changes neither the signal nor the plan.
    @Test func aSwitchWhoseStagesCompileToNothingMovesNothing() async throws {
        let rig = Rig()
        let idle = StateBox(true)
        let (session, probe) = try await rig.probed(
            Pipeline { TestGain(3); ZTronDSPCore.Group(isActive: idle.binding) { TestGain(4, isActive: false) } })
        #expect(session.core.plan.lowered.switches.count == 1 && session.core.plan.kernelTargets.count == 1, "one switch, and one kernel that is not its")
        rig.feed(ones(1))
        let sentBefore = await MainActor.run { session.core.pump.commandsSent }
        await rig.set(idle, to: false, of: session)
        rig.feed(ones(10))
        await rig.set(idle, to: true, of: session)
        rig.feed(ones(10))
        let sent = await MainActor.run { session.core.pump.commandsSent }
        #expect(sent == sentBefore + 2, "both changes were forwarded")
        #expect(probe.samples.count == 64 * 21 && probe.samples.allSatisfy { $0 == 3 }, "and neither changed a sample")
        #expect(session.core.generation == 1)
        session.detach()
    }

    // MARK: Values (§5.5.4)

    /// §5.5.4: "The same topology with different values … the new values travel through an SPSC
    /// command queue". Adjacent gains are one kernel (F1) and a gain per channel is another; each
    /// takes its new factors by command, the plan stays, and a change of value is no new topology.
    @Test func fusedGainsAndChannelGainsTakeNewFactorsByCommand() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); TestGain(3) })
        let plan = session.core.plan
        #expect(plan.kernelTargets.count == 1, "two gains, fused into one cascade")
        rig.feed(ones(1))
        #expect(probe.samples.last == 6)
        try await session.update(Pipeline { TestGain(2); TestGain(5) })
        rig.feed(ones(10))
        #expect(probe.samples.last == 10 && session.core.plan === plan, "the second factor was sent to the cascade that runs")
        try await session.update(Pipeline { TestGain(4); TestGain(0.5) })
        rig.feed(ones(10))
        #expect(probe.samples.last == 2 && session.core.generation == 1)
        session.detach()

        let stereo = Rig(channelCount: 2)
        let both = try await stereo.engine.attach(Pipeline { TestChannelGains(factors: [1, 2]) }, to: stereo.source)
        let channels = CoverageChannelProbe()
        stereo.engine.core.addProbe(channels, to: both.core)
        try both.start()
        stereo.feed(ones(1))
        try await both.update(Pipeline { TestChannelGains(factors: [3, 4]) })
        stereo.feed(ones(1))
        let left = channels.channels.first ?? [], right = channels.channels.last ?? []
        #expect(channels.channels.count == 2 && left == ones(1) + ones(1).map { (sample: Float) -> Float in sample * 3 })
        #expect(right == ones(1).map { (sample: Float) -> Float in sample * 2 } + ones(1).map { (sample: Float) -> Float in sample * 4 }, "each channel has its own factor, old and new")
        #expect(both.core.generation == 1)
        both.detach()
    }

    /// §5.5.4, RT-4: the command queue is bounded and never blocks. When it is full, because no
    /// block has been processed for 256 changes, a value is not lost and not reordered: the
    /// session applies what is queued and then the value itself, with its thread held off. The
    /// kernel ends on the value sent last, and every payload is freed once it was applied.
    @Test func aFullValueQueueLosesAndReordersNothing() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(0.5) })
        let plan = session.core.plan
        rig.feed(ones(1))
        // 800 changes and not one block between them: the queue holds 256.
        for index in 0 ..< 800 { try await session.update(Pipeline { TestGain(Float(index + 2)) }) }
        #expect(ztd_command_queue_overflows(session.core.runner.values) == 3,
                "every 257th change found the queue full; what was queued was applied then, and the queue was free again")
        #expect(session.core.plan === plan && session.core.generation == 1)

        rig.feed(ones(10))
        #expect(probe.samples.last == 801, "the value sent last is the one that holds")
        let ramp = Array(probe.samples[64...])
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 }, "one move from where the gain stood to the last value")
        try rig.engine.core.control.sync { rig.engine.core.service() }
        #expect(rig.pendingPayloads(of: session) == 0, "every payload was freed once its command had been applied")
        session.detach()
    }

    /// §5.5.4 through SRC-2: a session behind a processed source is live when every source up to
    /// the hardware delivers; its value changes then travel by the queue like any other's.
    @Test func valuesTravelToASessionBehindAProcessedSource() async throws {
        let rig = Rig()
        let processed = rig.source.processed(by: Pipeline { TestGain(2) })
        let session = try await rig.engine.attach(Pipeline { TestGain(3) }, to: processed)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        let plan = session.core.plan
        try session.start()
        rig.feed(ones(1))
        #expect(probe.samples.last == 6)
        for factor in [4, 7, 6, 9, 5] as [Float] { try await session.update(Pipeline { TestGain(factor) }) }
        #expect(rig.pendingPayloads(of: session) == 5, "queued for the thread that runs the session, not applied behind its back")
        rig.feed(ones(10))
        #expect(probe.samples.last == 10 && session.core.plan === plan && session.core.generation == 1, "applied in order: the last one holds")
        session.detach()
    }

    // MARK: Exchanges (SWAP-1…4)

    /// SWAP-1: "two descriptions with equal names and keys are the same stage, and an update
    /// keeps the kernel's state". A stage on the caller's own C kernel is taken into the new
    /// plan with what it has accumulated; one with another key is another stage and starts cold.
    @Test func aCustomKernelKeepsItsStateAcrossAnUpdateThatKeepsItsDescription() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { CoverageAccumulate(key: 1); TestGain(2) })
        rig.feed(ones(1))
        #expect(probe.samples.last == 128, "a running sum of 64 ones, doubled")

        // Another value behind it: nothing is compiled, and the kernel is compared, not replaced.
        try await session.update(Pipeline { CoverageAccumulate(key: 1); TestGain(3) })
        #expect(session.core.generation == 1)
        rig.feed(ones(1))
        // A tap behind it: a new plan that takes the kernel over.
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { CoverageAccumulate(key: 1); TestGain(3) }.tap { $0.emit(to: sink) })
        #expect(session.core.generation == 2)
        rig.feed(ones(10))
        #expect(probe.samples.last == Float(64 * 12) * 3, "the sum went on from where it stood")

        // Another key: another kernel, which starts from nothing when the new plan takes over.
        try await session.update(Pipeline { CoverageAccumulate(key: 2); TestGain(3) }.tap { $0.emit(to: sink) })
        rig.feed(ones(13))
        #expect(session.core.runner.installedGeneration == 3 && !session.core.runner.isInTransition)
        #expect(probe.samples.last == Float(64 * 13) * 3, "a new stage counts from its first block, not from the old one's \(64 * 25)")
        session.detach()
    }

    /// SWAP-2: what is new on the main line is pre-rolled for its settling time, a node's
    /// included, while the old plan produces the output. With a node in the new part the two
    /// outputs do not come out block for block, so they are not cross-faded: "the output changes
    /// at a block boundary and the session reports `.outputChanged`".
    @Test func aNodeBehindAReplacedStageIsPrerolledAndTheOutputChangesAtABoundary() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); TestLate(latency: 0, chunk: 64, settling: 128) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<256]))
        try await session.update(Pipeline { TestDelay(1); TestLate(latency: 0, chunk: 64, settling: 128) })
        #expect(session.core.generation == 2)
        // 1 frame of delay and 128 of settling: three blocks beside the old plan.
        rig.feed(Array(noise[256 ..< 448]))
        let old = noise[..<448].map { (sample: Float) -> Float in -(sample * 2) }
        #expect(probe.samples == old, "until the new stages have settled, the old plan produces the output (the test node inverts)")
        rig.feed(Array(noise[448 ..< 640]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(Array(probe.samples[448...]) == Array(noise[447 ..< 639]), "then the new plan's, its delay line already holding the frame before")
        await rig.drain()
        #expect(session.environment.latency == 1.0 / 48_000)
        #expect(await eventually(timeout: 30) { log.contains(.replanned(.update)) && log.contains(.outputChanged) })
        session.detach()
    }

    /// CR-015, item 5 (SWAP-4 names pre-roll only): "An update that arrives while a plan is being
    /// faded in lets that plan take over at once". The plan that was fading in is the one the
    /// next update is measured against, both exchanges are reported, and the session ends on the
    /// pipeline given last.
    @Test func anUpdateDuringAFadeLetsTheFadingPlanTakeOverAtOnce() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 64) })
        // One or two blocks of pre-roll, then a fade of 480 frames: five blocks on, it is fading.
        rig.feed(Array(noise[128 ..< 448]))
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1)

        try await session.update(Pipeline { TestDelay(2) })
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "the plan that was fading in runs, alone")
        #expect(session.core.generation == 3)
        rig.feed(Array(noise[448 ..< 640]))
        #expect(session.core.runner.installedGeneration == 3)

        let first = try Pipeline { TestSmoother(1, settling: 0) }.process(noise, format: format, blockSize: 64)
        // The second plan's smoother started cold where it was taken, at frame 128.
        let second = [Float](repeating: 0, count: 128) + (try Pipeline { TestSmoother(0.5, settling: 0) }.process(Array(noise[128...]), format: format, blockSize: 64))
        #expect(Array(probe.samples[..<192]) == Array(first[..<192]), "pre-roll: the first plan's output")
        let mixed = (192 ..< 448).allSatisfy { index in
            let low = min(first[index], second[index]) - 1e-5, high = max(first[index], second[index]) + 1e-5
            return probe.samples[index] >= low && probe.samples[index] <= high
        }
        #expect(mixed, "then, sample for sample, something between the two plans' outputs")
        #expect(Array(probe.samples[448 ..< 512]) == Array(second[448 ..< 512]), "cut short by the next update: the second plan's output, while the third is pre-rolled")
        let third = noise[510 ..< 638].map { (sample: Float) -> Float in -sample }
        #expect(Array(probe.samples[512...]) == third, "and then the third plan's: two frames late, inverted")

        await rig.drain()
        // The change of output is the last thing the session says; once it is there, everything before it is.
        #expect(await eventually(timeout: 30) { log.contains(.outputChanged) })
        let updates = log.all.filter { $0 == .replanned(.update) }.count, changes = log.all.filter { $0 == .outputChanged }.count
        #expect(updates == 2 && changes == 1, "both plans took over; only the last changed the latency: \(updates), \(changes)")
        session.detach()
    }

    /// SWAP-4: "Value changes that arrive in that window are applied to the plan that ends up
    /// running". A value sent while a plan is pre-rolled reaches that plan and not the one that
    /// still produces the output.
    @Test func aValueSentDuringPrerollReachesThePlanOnItsWayIn() async throws {
        let rig = Rig()
        func next(_ factor: Float) -> Pipeline<Samples, Samples> { Pipeline { TestSmoother(1, settling: 640); TestGain(factor) } }
        let (session, probe) = try await rig.probed(Pipeline { TestBarrier(); TestGain(3) })
        rig.feed(ones(2))
        try await session.update(next(2))
        rig.feed(ones(2))
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1)
        let incoming = session.core.plan

        try await session.update(next(5))
        #expect(session.core.plan === incoming && session.core.generation == 2, "the same topology as the plan on its way in: its values change, it is not replaced")
        rig.feed(ones(30))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(probe.samples.last == 5, "the plan that took over runs the value it was sent while it was pre-rolled")
        #expect(probe.samples[..<(64 * 12)].allSatisfy { $0 == 3 }, "the running plan, whose second kernel is a gain too, never saw the command")
        session.detach()
    }

    /// SWAP-4: a command names the plan it was made for and reaches no other. Values sent for a
    /// plan that is replaced before it ever ran are applied to that plan before it goes, and to
    /// nothing else: the plan that runs and the plan that came instead share no kernel with it
    /// here (their first stages differ), so neither moves towards them; and the payloads are
    /// freed.
    @Test func aValueForAPlanThatNeverRanReachesNoPlan() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestBarrier(); TestGain(3) })
        rig.feed(ones(1))
        // Updates and no block between them: a plan, twenty values for it, and another plan.
        try await session.update(Pipeline { TestDelay(1); TestGain(2) })
        for step in 0 ..< 20 { try await session.update(Pipeline { TestDelay(1); TestGain(Float(7 + step)) }) }
        #expect(rig.pendingPayloads(of: session) == 20, "the values wait for a block boundary")
        try await session.update(Pipeline { TestSmoother(1, settling: 0); TestGain(4) })
        #expect(session.core.generation == 3)

        rig.feed(ones(12))
        #expect(session.core.runner.installedGeneration == 3 && !session.core.runner.isInTransition)
        #expect(probe.samples.last == 4, "the last pipeline runs, with its own value")
        #expect(probe.samples.allSatisfy { $0 >= 2.9999 && $0 <= 4.0001 }, "nothing ever moved towards the values that were sent to a plan that never ran")
        try rig.engine.core.control.sync { rig.engine.core.service() }
        #expect(rig.pendingPayloads(of: session) == 0, "their payloads were freed all the same")
        session.detach()
    }

    /// SWAP-4: a command names the plan it was made for, and reaches no other. The main thread
    /// forwards a switch with the generation it captured last (BIND-2); when the plan was
    /// exchanged meanwhile, the command arrives for a plan that is gone. It is taken off the
    /// queue and moves nothing. ACT-5: a switch is a position, not an event: a command that
    /// names the position a switch has already changes nothing either, on a kernel's switch
    /// and on a group's: no fade, no reset.
    @Test func aCommandForAPlanThatIsGoneAndAPositionASwitchHasAlreadyMoveNothing() async throws {
        let rig = Rig()
        let first = StateBox(true), second = StateBox(true)
        let work = TestProbe()
        let counter = CallCounter()
        let (session, probe) = try await rig.probed(Pipeline {
            CountedDelay(counter, delay: 1, isActive: first.binding)
            ZTronDSPCore.Group(isActive: second.binding) { TestGain(2); TestLate(latency: 0, chunk: 64, probe: work) }
        })
        #expect(session.core.plan.switchTargets.count == 2)
        rig.feed(ones(2))
        let resets = (work.framerResets, counter.resets)

        // By hand and on the main thread, as the session's own forwarding does it.
        func send(_ ordinal: UInt32, isOn: Bool, generation: UInt32) async -> UInt64 {
            await MainActor.run {
                var command = ztd_command_t()
                command.target = ordinal
                command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
                command.scalar.0 = isOn ? 1 : 0
                command.flags = generation
                return ztd_command_queue_push(session.core.runner.switches, &command)
            }
        }
        let stale = [await send(0, isOn: false, generation: 99), await send(1, isOn: false, generation: 99)]
        let same = [await send(0, isOn: true, generation: 1), await send(1, isOn: true, generation: 1)]
        #expect(stale.allSatisfy { $0 != 0 } && same.allSatisfy { $0 != 0 }, "all four were queued")
        rig.feed(ones(10))
        #expect(ztd_command_queue_applied(session.core.runner.switches) == same[1], "and all four were taken off the queue")

        // One frame of delay, doubled, inverted by the test node; from the second sample on, −2.
        #expect(probe.samples.count == 64 * 12 && probe.samples[0] == 0 && probe.samples.dropFirst().allSatisfy { $0 == -2 },
                "no switch moved: not a sample of a fade, not a sample of the unprocessed signal")
        #expect(work.framerResets == resets.0 && counter.resets == resets.1, "and nothing was reset")
        #expect(session.core.generation == 1)
        session.detach()
    }

    // MARK: A switch inside a tap (ACT-3, SWAP-1)

    /// ACT-3: the bound switch of a stage that changes the rate suspends what follows it in its
    /// branch while it is off; in a tap that is the rest of the tap, and the main line passes
    /// as before. SWAP-1: a tap is found again by what it holds, the switch included, so an
    /// update that changes the main line behind the tap keeps the tap's stages, state and all.
    @Test func aSwitchedRateChangeInATapSuspendsTheRestOfTheTapAndIsKeptByAnUpdate() async throws {
        let rig = Rig()
        let listening = StateBox(true)
        let counter = CallCounter()
        let sink = CollectingSink<Samples>()
        func pipeline(delay: Int) -> Pipeline<Samples, Samples> {
            Pipeline { TestGain(2) }
                .tap { $0.appending(CountedDelay(counter, delay: 1)).appending(TestSubsample(by: 2, isActive: listening.binding)).emit(to: sink) }
                .appending(TestDelay(delay))
        }
        let (session, probe) = try await rig.probed(pipeline(delay: 1))
        #expect(session.core.plan.lowered.switches.count == 1)
        // What the tap hears: 2·x[n − 1], and of that every second sample.
        let delayed = [Float](repeating: 0, count: 1) + noise.map { (sample: Float) -> Float in sample * 2 }
        func heard(_ range: Range<Int>) -> [Float] { stride(from: range.lowerBound, to: range.upperBound, by: 2).map { delayed[$0] } }

        rig.feed(Array(noise[..<128]))
        #expect(sink.samples == heard(0 ..< 128))

        // Another delay on the main line, behind the tap: a new plan, which keeps the tap.
        let resets = counter.resets
        try await session.update(pipeline(delay: 2))
        #expect(session.core.generation == 2)
        rig.feed(Array(noise[128 ..< 384]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(sink.samples == heard(0 ..< 384), "the tap went on where it stood: its delay line was full, and its sink was fed all the while")
        #expect(counter.resets == resets && sink.claims == 1, "nothing in the tap was reset, and its sink was not prepared again")

        await rig.set(listening, to: false, of: session)
        rig.feed(Array(noise[384 ..< 512]))
        #expect(sink.samples == heard(0 ..< 384), "off: nothing passes the switch")
        await rig.set(listening, to: true, of: session)
        rig.feed(Array(noise[512 ..< 640]))
        #expect(sink.samples == heard(0 ..< 384) + heard(512 ..< 640), "on again: what comes from then on")
        // The main line never noticed: the signal doubled, inverted and delayed by the test delay.
        #expect(probe.samples.count == 640 && Array(probe.samples.suffix(64)) == noise[574 ..< 638].map { (sample: Float) -> Float in -2 * sample })
        session.detach()
    }

    // MARK: Source events that are the source's own business (§4.5)

    /// §4.5, MIC-4: a change of route and a reset of the media services are told to whoever
    /// listens to the source. The source has dealt with them itself, and says `.formatChanged`
    /// when its format moved; for the engine there is nothing to do. The session runs on:
    /// same plan, same state, the source neither prepared nor started again.
    @Test func aRouteChangeAndAMediaServicesResetChangeNothingAboutASession() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2) })
        let log = EventLog(session)
        rig.feed(ones(1))
        rig.source.send(.routeChanged(.inputChanged))
        rig.source.send(.mediaServicesReset)
        rig.source.send(.routeChanged(.other))
        // Events arrive in order: once the overrun is reported, the three before it were handled.
        rig.source.send(.overrun(droppedFrames: 7))
        #expect(await eventually(timeout: 30) { log.contains(.overrun(droppedFrames: 7)) })
        rig.feed(ones(1))
        #expect(session.state == .running && session.core.generation == 1 && probe.samples == ones(2).map { (sample: Float) -> Float in sample * 2 })
        #expect(rig.source.prepares == 1 && rig.source.starts == 1 && rig.source.stops == 0)
        let others = log.all.filter { (event: SessionEvent) -> Bool in
            switch event {
            case .overrun, .stateChanged(.running): false
            default: true
            }
        }
        #expect(others.isEmpty, "the session said nothing but the overrun: \(others)")
        session.detach()
    }

    // MARK: Plans that are abandoned (SWAP-4, ATT-5)

    /// SWAP-4, ATT-5: a plan that is replaced while it is pre-rolled never ran. A sink that was
    /// claimed for it alone received nothing (SWAP-2: its output is discarded) and is given back
    /// at once: another attachment may write it.
    @Test func aPlanAbandonedDuringPrerollGivesBackTheSinkClaimedForIt() async throws {
        let rig = Rig()
        let fresh = CollectingSink<Samples>()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 48_000) }.tap { $0.emit(to: fresh) })
        #expect(fresh.claims == 1 && SinkRegistry.isClaimed(ObjectIdentifier(fresh)))
        rig.feed(Array(noise[128 ..< 256]))
        #expect(session.core.runner.isInTransition && fresh.frameCount == 0, "pre-rolled beside the running plan: its sinks are idle")

        try await session.update(Pipeline { TestGain(-1) })
        #expect(fresh.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(fresh)), "the claim ends with the plan it was made for")
        rig.feed(Array(noise[256 ..< 896]))
        #expect(session.core.runner.installedGeneration == 3 && probe.samples.last == -noise[895])
        #expect(fresh.frameCount == 0 && fresh.claims == 1 && fresh.releases == 1)

        let other = try await rig.engine.attach(Pipeline().emit(to: fresh), to: BufferSource(noise, sampleRate: 48_000))
        #expect(other.state == .idle && fresh.claims == 2, "free for another writer")
        other.detach()
        session.detach()
    }

    /// CR-015, item 4: "A sink that an update moves … is prepared for the new frames at once, so
    /// the old plan stops writing it". When the plan it was prepared for is abandoned, the sink
    /// stays the session's (ATT-5: never released, never free for another writer) and is
    /// prepared anew for the plan that comes instead, which then feeds it again. The main line
    /// notices none of it (SWAP-1).
    @Test func aSinkMovedForAnAbandonedPlanIsPreparedAnewForTheNext() async throws {
        let rig = Rig()
        let moved = CollectingSink<Samples>()
        let original = Pipeline { TestSmoother(1, settling: 0) }.tap { $0.emit(to: moved) }
        let (session, probe) = try await rig.probed(original)
        rig.feed(Array(noise[..<128]))
        #expect(moved.claims == 1 && moved.samples.count == 128)

        try await session.update(Pipeline { TestSmoother(0.5, settling: 48_000) }.tap { $0.testGain(2).emit(to: moved) })
        #expect(moved.claims == 2, "prepared for the frames the new plan will give it")
        rig.feed(Array(noise[128 ..< 256]))
        #expect(moved.samples.count == 128, "nothing between the update and the exchange")

        try await session.update(original)
        #expect(moved.claims == 3 && moved.releases == 0 && SinkRegistry.isClaimed(ObjectIdentifier(moved)), "prepared again; never let go")
        rig.feed(Array(noise[256 ..< 384]))
        #expect(session.core.runner.installedGeneration == 3 && !session.core.runner.isInTransition)

        let reference = try Pipeline { TestSmoother(1, settling: 0) }.process(noise, format: format, blockSize: 64)
        #expect(probe.samples == Array(reference[..<384]), "the main line ran on: its stage was never replaced")
        #expect(moved.samples == Array(reference[..<128]) + Array(reference[256 ..< 384]), "the sink hears the plan that took over, from its first block")
        session.detach()
        #expect(moved.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(moved)))
    }

    /// ATT-5, §4.5 (`update`): "A pipeline that does not compile leaves the running one as it
    /// is". When the refused pipeline had moved a sink of the running plan, the sink is prepared
    /// again for what the running plan writes; a sink that refuses even that is taken from the
    /// running plan, which runs on without it, and is prepared anew by the next plan.
    @Test func aSinkThatRefusesToGoBackIsLeftOutUntilTheNextPlan() async throws {
        let rig = Rig()
        let fussy = CoverageFussySink()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); Emit(to: fussy) })
        rig.feed(ones(1))
        #expect(fussy.claims == 1 && fussy.samples.count == 64)

        // The update moves the sink (claim 2) and then fails on another; going back is claim 3.
        fussy.refused = [3]
        await #expect(throws: DSPError.self) {
            try await session.update(Pipeline { TestDelay(1); Emit(to: fussy); Emit(to: RefusingSink()) })
        }
        #expect(fussy.claims == 3 && fussy.releases == 0 && SinkRegistry.isClaimed(ObjectIdentifier(fussy)), "asked twice more; still the session's")
        rig.feed(ones(2))
        #expect(session.state == .running && session.core.runner.installedGeneration == 1 && probe.samples.last == 2, "the running plan runs on")
        #expect(fussy.samples.count == 64, "without the sink that would not be prepared for it again")

        try await session.update(Pipeline { TestGain(2); TestDelay(1); Emit(to: fussy) })
        rig.feed(ones(4))
        #expect(fussy.claims == 4 && fussy.samples.last == -2, "the next plan prepares it anew and feeds it (the test delay inverts)")
        session.detach()
        #expect(fussy.releases == 1)
    }

    // MARK: Format changes that arrive while bindings are read (ATT-4, BIND-4)

    /// BIND-4: `attach` reads the bindings on the main actor and compiles off it with what it
    /// read. ATT-4: the plan is compiled for the format the source delivers. When the format
    /// moves between the two, the attachment starts over: the bindings are read again, and the
    /// session, its plan and its sinks are made once, for the format that holds.
    ///
    /// The source is a pull source whose script changes format after one block, and the engine
    /// is driven by hand: the turn in which the source reaches the change is run by the binding
    /// itself, the first time it is read.
    @Test func aFormatThatMovesWhileAttachReadsTheBindingsIsTheOneCompiledFor() async throws {
        let engine = DSPEngine(blockSize: 64, drivenByHand: true)
        let source = ScriptedSource(format: format, [
            .samples([ones(1)]), .formatChange(SignalFormat(sampleRate: 96_000)), .samples([ones(4)]),
        ])
        // An attachment that runs already keeps the source delivering.
        let earlier = CollectingSink<Samples>()
        let first = try await engine.attach(Pipeline { TestGain(3) }.emit(to: earlier), to: source)
        try first.start()

        let moving = CoverageMovingSwitch { engine.core.runTurn() }
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestGain(2, isActive: moving.binding) }.emit(to: sink), to: source)
        #expect(moving.readCount == 2, "read once for the format that went, and again for the one that came")
        #expect(session.environment.sampleRate == 96_000 && session.core.generation == 1)
        #expect(sink.claims == 1 && sink.environment?.sampleRate == 96_000, "the sink was prepared once, for what it will get")
        #expect(first.environment.sampleRate == 96_000 && earlier.samples.count == 64, "the attachment that ran took the change, after its one block at 48 kHz")

        try session.start()
        engine.core.runTurn()
        let doubled = ones(4).map { (sample: Float) -> Float in sample * 2 }
        #expect(sink.samples == doubled, "the rest of the stream, at the new rate, through the plan that was compiled for it")
        #expect(earlier.samples.count == 64 * 5 && session.state == .finished && first.state == .finished)
        session.detach()
        first.detach()
    }

    /// The same for `update(_:)` (§5.5.4, ATT-4): the new topology is compiled for the format
    /// that holds when it is exchanged. Here the pipeline has a bound switch at 48 kHz and none
    /// at 96 kHz; the plan that runs is the one for 96 kHz, and the session reads no switch.
    @Test func aFormatThatMovesWhileUpdateReadsTheBindingsIsTheOneCompiledFor() async throws {
        let engine = DSPEngine(blockSize: 64, drivenByHand: true)
        let source = ScriptedSource(format: format, [
            .samples([ones(2)]), .formatChange(SignalFormat(sampleRate: 96_000)), .samples([ones(8)]),
        ])
        let session = try await engine.attach(Pipeline { TestGain(2) }, to: source)
        let probe = OutputProbe()
        engine.core.addProbe(probe, to: session.core)
        let log = EventLog(session)
        try session.start()

        // The first turn, with the two blocks at 48 kHz and the change of format, runs while the update reads its switch.
        let moving = CoverageMovingSwitch { engine.core.runTurn() }
        try await session.update(Pipeline {
            EnvironmentReader { environment in
                if environment.sampleRate == 48_000 { TestDelay(1, isActive: moving.binding) } else { TestDelay(1) }
            }
        })
        #expect(moving.readCount == 1, "the switch of the 48 kHz pipeline was read; at 96 kHz there is none to read")
        #expect(session.environment.sampleRate == 96_000 && session.state == .running)
        #expect(session.core.plan.lowered.switches.isEmpty && session.core.plan.lowered.sourceEnvironment.sampleRate == 96_000)
        #expect(probe.samples == ones(2).map { (sample: Float) -> Float in sample * 2 }, "what was delivered at 48 kHz went through the first pipeline")
        await MainActor.run {}
        engine.core.flush()
        let observing = await MainActor.run { session.core.pump.isObserving }
        #expect(!observing, "no bound switch: nothing to watch on the main run loop (BIND-2)")

        engine.core.runTurn()
        engine.core.flush()
        #expect(probe.samples.count == 64 * 10 && probe.samples.last == -1, "the pipeline given to the update runs at the new rate (the test delay inverts)")
        #expect(await eventually(timeout: 30) { log.contains(.replanned(.formatChanged)) && log.contains(.replanned(.update)) })
        session.detach()
    }

    // MARK: A stream and its consumer (§5.2, RT-2)

    /// §5.2 (`FeatureStream`): the analysis thread copies each frame "without allocating,
    /// locking or waking anyone; the consumer is woken from the engine's control context". A
    /// consumer that waits for the next frame is woken for each one as it arrives: every frame
    /// is delivered, in order, and none is counted as dropped.
    @Test func aConsumerThatWaitsIsWokenForEveryFrame() async throws {
        let rig = Rig()
        let stream = FeatureStream<Samples>(capacity: 8)
        let session = try await rig.engine.attach(Pipeline().emit(to: stream), to: rig.source)
        try session.start()
        let received = Locked<[Float]>([])
        let consumer = Task {
            for await frame in stream { received.withLock { $0.append(frame.samples(ofChannel: 0).first ?? -1) } }
        }
        let rounds = 120
        var arrived = 0
        for round in 0 ..< rounds {
            rig.feed([Float](repeating: Float(round), count: 64))
            let expected = round + 1
            if await eventually(timeout: 30, { received.get().count == expected }) { arrived += 1 }
            // Time for the consumer to come back and wait: the next frame then finds it waiting.
            try? await Task.sleep(nanoseconds: 200_000)
        }
        #expect(arrived == rounds, "each frame reached the consumer before the next was written: \(arrived) of \(rounds)")
        stream.finish()
        await consumer.value
        #expect(received.get() == (0 ..< rounds).map { Float($0) } && stream.droppedFrames == 0, "every frame, in order")
        session.detach()
    }

    // MARK: Attaching (§4.5)

    /// §4.5, §9.3: a block holds at least one frame. An engine made with less refuses every
    /// attachment with a typed error, before the source is touched.
    @Test func anEngineWithoutABlockRefusesToAttach() async throws {
        let source = ManualPushSource(format: format)
        for size in [0, -4] {
            await #expect(throws: DSPError.invalidParameter(stage: .none, parameter: "blockSize", reason: "a block holds at least one frame, not \(size)")) {
                _ = try await DSPEngine(blockSize: size, drivenByHand: true).attach(Pipeline(), to: source)
            }
        }
        #expect(source.prepares == 0 && source.connects == 0, "refused before the source was prepared")
        let session = try await DSPEngine(blockSize: 64, drivenByHand: true).attach(Pipeline(), to: source)
        #expect(session.state == .idle, "and the source is free for an engine that can run it")
        session.detach()
    }

    // MARK: Processed sources (SRC-2)

    /// SRC-2, §4.4: the events of a processed source are "those of the upstream source, with a
    /// format change reported in the format of the output". Interruptions, the resumption and
    /// the end of the upstream stream arrive as the processed source's own.
    @Test func aProcessedSourceReportsWhatHappensUpstreamInItsOwnFormat() async throws {
        let rig = Rig()
        let processed = rig.source.processed(by: Pipeline { TestSubsample(by: 2) })
        let events = CoverageSourceEventLog(processed.events)
        let sink = CollectingSink<Samples>()
        let session = try await rig.engine.attach(Pipeline { TestGain(3) }.emit(to: sink), to: processed)
        #expect(processed.format == SignalFormat(sampleRate: 24_000), "half the upstream rate")
        try session.start()
        rig.feed(ones(2))
        #expect(sink.samples == ones(1).map { (sample: Float) -> Float in sample * 3 })

        rig.source.changeFormat(to: SignalFormat(sampleRate: 96_000))
        #expect(await eventually(timeout: 30) { session.environment.sampleRate == 48_000 })
        #expect(await eventually(timeout: 30) { events.contains(.formatChanged(SignalFormat(sampleRate: 48_000))) }, "the format of the output: \(events.all)")
        #expect(!events.contains(.formatChanged(SignalFormat(sampleRate: 96_000))) && processed.format == SignalFormat(sampleRate: 48_000))

        rig.source.send(.interrupted)
        #expect(await session.reaches(.interrupted, timeout: 30))
        rig.source.send(.resumed)
        #expect(await session.reaches(.running, timeout: 30))
        #expect(await eventually(timeout: 30) { events.contains(.interrupted) && events.contains(.resumed) })

        rig.source.send(.ended)
        let engine = rig.engine
        #expect(await eventually(timeout: 30) {
            engine.core.runTurn()
            return session.state == .finished
        })
        #expect(await eventually(timeout: 30) { events.contains(.ended) })
        session.detach()
    }

    /// SRC-2, ORD-6: a processed source is the main-line output of a pipeline that ends in
    /// samples. Whatever the types claim, the order is checked on the descriptions; a pipeline
    /// that ends elsewhere is refused when it is attached, and nothing of the attempt stays
    /// behind: its sinks are released and the upstream source is free again.
    @Test func aProcessedSourceWhosePipelineDoesNotEndInSamplesIsRefused() async throws {
        typealias Bins = Spectrum<LinearFrequency, ComplexValues>
        let engine = DSPEngine(blockSize: 64, drivenByHand: true)
        let upstream = ManualPushSource(format: format)
        let inner = CollectingSink<Bins>()
        let spectra = Pipeline().testFramer(frame: 64, hop: 16).emit(to: inner)
        let processed = upstream.processed(by: Pipeline<Samples, Samples>(unchecked: spectra.stages))

        let expected = DSPError.unsupportedConfiguration(reason: "a processed source needs a pipeline that ends in samples, not in \(Bins.tag)")
        await #expect(throws: expected) { _ = try await engine.attach(Pipeline { TestGain(2) }, to: processed) }
        engine.core.flush()
        engine.core.flush()
        #expect(inner.claims == 1 && inner.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(inner)), "the pipeline in front was attached, and detached again")
        #expect(upstream.prepares == 1 && upstream.starts == 0)

        // Free again: another engine may attach the upstream source, and this one the processed source's pipeline, corrected.
        let elsewhere = try await DSPEngine(blockSize: 64, drivenByHand: true).attach(Pipeline(), to: upstream)
        #expect(elsewhere.state == .idle)
        elsewhere.detach()
    }
}
