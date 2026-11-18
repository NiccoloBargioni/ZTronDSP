import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A gain that reaches 0 dB, or leaves it, while its pipeline runs (§5.5.4, F4, SWAP-1,
/// SWAP-3, CLICK-1; what a hosted animation does when it lands on 0 dB: ANI-2…ANI-5).
///
/// By the topology rule of §5.5.4 two pipelines that differ in a gain amount have the same
/// topology, so such an update is a change of values: "the new values travel through an SPSC
/// command queue … A gain ramps over 10 ms." Fusion F4 removes a unity gain when a plan is
/// compiled, and the defect was that the update was therefore taken for a change of topology:
/// the kernel went or came with a new plan, everything behind it was keyed anew, the feed of a
/// branch behind the gain was cleared and withheld until its new nodes had refilled, and the
/// branch heard the gain step. Now the place of such a stage is part of the structure a plan
/// is built and compared by, whatever its value: a kernel that is sent 0 dB stays and ramps;
/// a stage that leaves 0 dB in a plan compiled without its kernel gets the kernel, made as the
/// identity it was, in a plan that takes over at once, and its value is sent after it.
@Suite("A gain at 0 dB is a value like any other (§5.5.4, F4)")
struct UnityGainRegressionTests {
    typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
    let format = SignalFormat(sampleRate: 48_000)

    private func ones(_ blocks: Int) -> [Float] { [Float](repeating: 1, count: 64 * blocks) }

    /// The gain, and behind it a branch that frames the signal and hands the magnitudes of each
    /// frame to a sink and to a heat-map feed.
    private func pipeline(_ gain: Float, _ work: TestProbe, _ sink: CollectingSink<Magnitudes>, _ feed: HeatmapFeed) -> Pipeline<Samples, Samples> {
        Pipeline { TestGain(gain) }.tap { $0.testFramer(frame: 64, hop: 64, probe: work).testMagnitude().emit(to: sink).emit(to: feed) }
    }

    /// The gain each frame of the branch heard, with ones as the signal: the test framer keeps
    /// the newest samples as bins, real and negated imaginary, so a magnitude is √2 times the sample.
    private func heard(_ sink: CollectingSink<Magnitudes>) -> [Float] {
        sink.reals.map { (frame: [Float]) -> Float in (frame.last ?? 0) / Float(2).squareRoot() }
    }

    /// True when two gains are one, to the last bits of a square root and a division.
    private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-5 }

    /// Reads what arrived in `feed` since `cursor` last read.
    private func read(_ feed: HeatmapFeed, _ cursor: inout FeedCursor) -> FeedRead {
        var values = [Float](repeating: 0, count: 64 * 512)
        return values.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
    }

    // MARK: The structure does not move with the value

    /// §5.5.4, "Topology": gain amounts are not structure. The steps a fresh plan runs leave a
    /// unity gain out (F4); the skeleton a plan is built and compared by keeps its place, and
    /// fuses adjacent gains whatever their values (F1), so a value never moves a kernel.
    @Test func theSkeletonOfAPipelineKeepsThePlaceOfAUnityGain() throws {
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)
        func lowered(_ pipeline: Pipeline<Samples, Samples>) throws -> LoweredPipeline {
            try compiler.lower(pipeline.stages, environment: environment, blockSize: 64)
        }
        let unity = try lowered(Pipeline { TestGain(1) }), two = try lowered(Pipeline { TestGain(2) })
        #expect(unity.steps.isEmpty, "what a fresh plan runs: nothing (F4)")
        #expect(unity.skeleton.count == 1 && IRStep.kernels(of: unity.skeleton).first?.spec == .gain(factor: 1, ramp: 0.010))
        #expect(IRStep.sameStructure(unity.skeleton, two.skeleton) && two.skeleton == two.steps, "one structure for both values")

        let fused = try lowered(Pipeline { TestGain(0.5); TestGain(1); TestGain(4) })
        #expect(IRStep.kernels(of: fused.steps).map { $0.spec } == [.gainCascade(factors: [0.5, 4], ramp: 0.010)])
        #expect(IRStep.kernels(of: fused.skeleton).map { $0.spec } == [.gainCascade(factors: [0.5, 1, 4], ramp: 0.010)])
        let other = try lowered(Pipeline { TestGain(0.5); TestGain(3); TestGain(4) })
        #expect(IRStep.sameStructure(fused.skeleton, other.skeleton) && !IRStep.sameStructure(fused.steps, other.steps))

        // A single unit tap is an identity by its value too; a cascade without sections is one by its structure.
        let tap = try lowered(Pipeline { TestFIR([1]) }), none = try lowered(Pipeline { TestBiquad(count: 0) })
        #expect(tap.steps.isEmpty && tap.skeleton.count == 1 && none.steps.isEmpty && none.skeleton.isEmpty)
        #expect(KernelSpec.gain(factor: 1, ramp: 0).isIdentityByValue && KernelSpec.fir(taps: [1], latency: 0).isIdentityByValue)
        #expect(!KernelSpec.biquad(sections: [], precision: .single).isIdentityByValue && !KernelSpec.gain(factor: 2, ramp: 0).isIdentityByValue)
        #expect(!KernelSpec.subsample(factor: 1, phase: 0).isIdentityByValue)

        // A plan compiled from nothing makes no kernel for the identity (F4), and knows its place.
        let plan = try ExecutionPlan(lowered: unity, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
        #expect(plan.kernelTargets.count == 1 && plan.kernelTargets[0] == nil && plan.root.steps.count == 1, "no kernel run: only the output")
        #expect(plan.canTakeValues(of: unity) && !plan.canTakeValues(of: two), "it has no kernel to send another value to")
        let running = try ExecutionPlan(lowered: two, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
        #expect(running.kernelTargets[0] != nil && running.canTakeValues(of: unity) && running.canTakeValues(of: two), "a kernel takes any value, 0 dB too")
    }

    // MARK: To 0 dB: the kernel stays and ramps

    /// A running gain is sent 0 dB: nothing is compiled, the gain ramps for 10 ms on the main
    /// line and for the branch behind it, the branch keeps its node, its sink and its feed's
    /// history, and not one block is withheld. Sent away from 0 dB again, it ramps again.
    @Test func aGainSentToZeroDecibelsStaysAKernelAndRamps() async throws {
        let rig = Rig()
        let work = TestProbe(), sink = CollectingSink<Magnitudes>(), feed = HeatmapFeed(history: 256)
        let (session, probe) = try await rig.probed(pipeline(2, work, sink, feed))
        let plan = session.core.plan
        var cursor = FeedCursor()
        rig.feed(ones(4))
        let first = read(feed, &cursor)
        #expect(first.columnCount == 4 && heard(sink).count == 4 && heard(sink).allSatisfy { near($0, 2) })
        let resets = work.framerResets

        try await session.update(pipeline(1, work, sink, feed))
        #expect(session.core.plan === plan && session.core.generation == 1, "a change of values: nothing is compiled")
        rig.feed(ones(12))
        #expect(session.core.runner.installedGeneration == 1 && !session.core.runner.isInTransition)

        // The main line: 480 frames from 2 to 1, sample for sample the gain's own ramp, then 1 exactly.
        #expect(probe.samples.count == 64 * 16, "no block is withheld")
        let ramp = (0 ..< 480).map { (frame: Int) -> Float in 1 - (-1.0 / 480) * Float(479 - frame) }
        expectClose(Array(probe.samples[256 ..< 736]), ramp, .absolute(1e-6), "the gain ramps for 10 ms")
        #expect(probe.samples[735] == 1 && probe.samples[736...].allSatisfy { $0 == 1 }, "and lands on 0 dB exactly")

        // The branch: every frame, the gain it heard moving with the main line, its history whole.
        let gains = heard(sink)
        #expect(gains.count == 16 && zip(gains, gains.dropFirst()).allSatisfy { $0 >= $1 - 1e-5 }, "the branch hears every frame, and never a gain that goes back: \(gains)")
        #expect(near(gains[3], 2) && gains[4] < 1.9 && gains[4] > 1.8 && gains[10] > 1 && near(gains[15], 1), "a ramp, not a step: \(gains)")
        let second = read(feed, &cursor)
        #expect(!second.isReset && second.skipped == 0 && second.columnCount == 12 && second.firstColumn == 4 && feed.columnCount == 16,
                "the feed continues: \(second)")
        #expect(work.framerNodesMade == 1 && work.framerResets == resets && sink.claims == 1 && sink.releases == 0, "its node and its sink are the ones it had")

        // Away from 0 dB: the kernel is there to take the value.
        try await session.update(pipeline(3, work, sink, feed))
        #expect(session.core.plan === plan && session.core.generation == 1)
        rig.feed(ones(10))
        #expect(probe.samples.last == 3 && near(heard(sink).last ?? 0, 3) && feed.columnCount == 26)
        let rising = Array(probe.samples[(64 * 16)...])
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 } && rising[0] > 1 && rising[0] < 1.01)
        session.detach()
    }

    // MARK: Away from 0 dB: the kernel arrives as an identity and ramps

    /// A pipeline is attached with its gain at 0 dB, so its plan has no kernel for it (F4). The
    /// gain is then given 6 dB. A plan with the kernel takes over at the next block boundary,
    /// with nothing to settle and nothing to fade, because the kernel arrives as the identity
    /// the stage was; the value follows it and the gain ramps from 0 dB, on the main line and
    /// for the branch behind it. The branch keeps its node, its sink and its feed's history
    /// (SWAP-1, SWAP-3), and the session reports one exchange and no change of output.
    @Test func aGainThatLeavesZeroDecibelsGetsItsKernelAndRampsFromThere() async throws {
        let rig = Rig()
        let work = TestProbe(), sink = CollectingSink<Magnitudes>(), feed = HeatmapFeed(history: 256)
        let (session, probe) = try await rig.probed(pipeline(1, work, sink, feed))
        let log = EventLog(session)
        #expect(session.core.plan.kernelTargets.count == 1 && session.core.plan.kernelTargets[0] == nil, "0 dB when it was compiled: no kernel")
        var cursor = FeedCursor()
        rig.feed(ones(4))
        #expect(probe.samples == ones(4) && read(feed, &cursor).columnCount == 4)
        let resets = work.framerResets

        try await session.update(pipeline(2, work, sink, feed))
        #expect(session.core.generation == 2, "a plan that has the kernel")
        rig.feed(ones(1))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "it takes over at the first boundary: nothing to settle, nothing to fade")
        rig.feed(ones(11))

        #expect(probe.samples.count == 64 * 16, "no block is withheld")
        let ramp = (0 ..< 480).map { (frame: Int) -> Float in 2 - (1.0 / 480) * Float(479 - frame) }
        expectClose(Array(probe.samples[256 ..< 736]), ramp, .absolute(1e-6), "the gain ramps for 10 ms, from 0 dB")
        #expect(probe.samples[735] == 2 && probe.samples[736...].allSatisfy { $0 == 2 })

        let gains = heard(sink)
        #expect(gains.count == 16 && zip(gains, gains.dropFirst()).allSatisfy { $0 <= $1 + 1e-5 }, "the branch hears every frame, and never a gain that goes back: \(gains)")
        #expect(near(gains[3], 1) && gains[4] > 1.1 && gains[4] < 1.2 && gains[10] < 2 && near(gains[15], 2), "a ramp, not a step: \(gains)")
        let second = read(feed, &cursor)
        #expect(!second.isReset && second.skipped == 0 && second.columnCount == 12 && second.firstColumn == 4 && feed.columnCount == 16,
                "the feed is not cleared and misses no column: \(second)")
        #expect(work.framerNodesMade == 1 && work.framerResets == resets && sink.claims == 1 && sink.releases == 0, "its node and its sink are the ones it had")

        await rig.drain()
        #expect(await eventually(timeout: 30) { log.contains(.replanned(.update)) })
        #expect(!log.contains(.outputChanged), "the output did not change in domain, rate or latency")

        // From here the kernel is there: back to 0 dB and away again are values, and the plan stays.
        let plan = session.core.plan
        try await session.update(pipeline(1, work, sink, feed))
        rig.feed(ones(10))
        try await session.update(pipeline(4, work, sink, feed))
        rig.feed(ones(10))
        #expect(session.core.plan === plan && session.core.generation == 2 && probe.samples.last == 4 && near(heard(sink).last ?? 0, 4))
        #expect(feed.columnCount == 36 && !read(feed, &cursor).isReset && work.framerNodesMade == 1)
        session.detach()
    }

    /// CLICK-1: "A full-scale 1 kHz sine at 48 kHz runs through the change. The largest
    /// sample-to-sample difference of the output, during the change and for one block after it,
    /// does not exceed 1.5 times the largest such difference in steady state on either side."
    /// Through a gain that leaves 0 dB for −6 dB, and through one that comes back to it.
    @Test func leavingAndReachingZeroDecibelsUnderASineMakesNoClick() async throws {
        // Both changes land on a block boundary where the sine stands at 0.87 of full scale: a
        // gain that stepped there would show.
        let signal = Click.probeSignal(count: 64 * 91)
        let first = 64 * 31, second = 64 * 61
        #expect(abs(signal[first]) > 0.8 && abs(signal[second]) > 0.8)
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(1) })
        rig.feed(Array(signal[..<first]))
        try await session.update(Pipeline { TestGain(0.5) })
        rig.feed(Array(signal[first ..< second]))
        try await session.update(Pipeline { TestGain(1) })
        rig.feed(Array(signal[second...]))
        #expect(probe.samples.count == signal.count && session.core.generation == 2)

        let leaving = Click.measure(Array(probe.samples[..<(64 * 45)]), change: first ..< (first + 480 + 64), settle: 64)
        #expect(leaving.passes, "leaving 0 dB: \(leaving)")
        let returning = Click.measure(Array(probe.samples[(64 * 45)...]), change: (64 * 16) ..< (64 * 16 + 480 + 64), settle: 64)
        #expect(returning.passes, "reaching 0 dB: \(returning)")
        // What comes out is the signal times the gain, and nothing else.
        #expect(Array(probe.samples[..<first]) == Array(signal[..<first]), "at 0 dB: the signal")
        let half = signal[(64 * 41) ..< second].map { (sample: Float) -> Float in sample * 0.5 }
        #expect(Array(probe.samples[(64 * 41) ..< second]) == half, "at −6 dB: half of it")
        #expect(Array(probe.samples[(64 * 71)...]) == Array(signal[(64 * 71)...]), "at 0 dB again: the signal")
        let moving = zip(probe.samples[first ..< (first + 480)], signal[first ..< (first + 480)]).enumerated().allSatisfy { entry in
            let factor: Float = 0.5 - (-0.5 / 480) * Float(479 - entry.offset)
            return abs(entry.element.0 - entry.element.1 * factor) < 1e-6
        }
        #expect(moving, "between them: the signal times the gain's ramp")
        session.detach()
    }

    // MARK: The other kernels that can be identities by their values

    /// F1 with F4: adjacent gains are one kernel, whatever their values. A factor that reaches
    /// 0 dB or leaves it is a value of that kernel; and gains that are all at 0 dB when the plan
    /// is compiled are no kernel, until one of them moves.
    @Test func fusedGainsStayOneKernelWhenOneOfThemIsAtZeroDecibels() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); TestGain(3) })
        let plan = session.core.plan
        rig.feed(ones(1))
        try await session.update(Pipeline { TestGain(2); TestGain(1) })
        rig.feed(ones(10))
        try await session.update(Pipeline { TestGain(1); TestGain(1) })
        rig.feed(ones(10))
        #expect(probe.samples.last == 1 && session.core.plan === plan && session.core.generation == 1, "values, all the way to an identity")
        try await session.update(Pipeline { TestGain(1); TestGain(5) })
        rig.feed(ones(10))
        #expect(probe.samples.last == 5 && session.core.plan === plan && session.core.generation == 1)
        #expect(probe.samples.count == 64 * 31)
        session.detach()

        // Compiled as an identity: no kernel. One factor moves: the kernel arrives and ramps.
        let other = Rig()
        let (idle, output) = try await other.probed(Pipeline { TestGain(1); TestGain(1) })
        #expect(idle.core.plan.kernelTargets.count == 1 && idle.core.plan.kernelTargets[0] == nil)
        other.feed(ones(2))
        try await idle.update(Pipeline { TestGain(1); TestGain(3) })
        other.feed(ones(10))
        #expect(idle.core.generation == 2 && idle.core.runner.installedGeneration == 2 && output.samples.count == 64 * 12)
        #expect(output.samples[128] > 1 && output.samples[128] < 1.01 && output.samples.last == 3)
        #expect(zip(output.samples, output.samples.dropFirst()).allSatisfy { $0 <= $1 }, "one ramp from 1 to 3")
        idle.detach()
    }

    /// A gain per channel and a filter of one tap are identities by their values too. A gain
    /// per channel that was compiled at 0 dB gets its kernel when a channel moves, in a plan
    /// that takes over at once; its ramp is the one its stage declares (none, here). A single
    /// tap that leaves 1 is cross-faded to its new value over 10 ms, like any change of taps.
    @Test func channelGainsAndASingleTapLeaveAndReachTheirIdentitiesAsValues() async throws {
        let stereo = Rig(channelCount: 2)
        let session = try await stereo.engine.attach(Pipeline { TestChannelGains(factors: [1, 1]) }, to: stereo.source)
        let channels = CoverageChannelProbe()
        stereo.engine.core.addProbe(channels, to: session.core)
        try session.start()
        #expect(session.core.plan.kernelTargets[0] == nil)
        stereo.feed(ones(2))
        try await session.update(Pipeline { TestChannelGains(factors: [2, 1]) })
        stereo.feed(ones(2))
        #expect(session.core.generation == 2 && session.core.runner.installedGeneration == 2)
        let plan = session.core.plan
        try await session.update(Pipeline { TestChannelGains(factors: [1, 1]) })
        stereo.feed(ones(2))
        try await session.update(Pipeline { TestChannelGains(factors: [1, 3]) })
        stereo.feed(ones(2))
        #expect(session.core.plan === plan && session.core.generation == 2, "from then on: values")
        let left = channels.channels.first ?? [], right = channels.channels.last ?? []
        #expect(left == ones(2) + ones(2).map { (sample: Float) -> Float in sample * 2 } + ones(4), "the left channel: 1, 2, 1, 1")
        #expect(right == ones(6) + ones(2).map { (sample: Float) -> Float in sample * 3 }, "the right channel: 1, 1, 1, 3")
        session.detach()

        let rig = Rig()
        let (filtered, probe) = try await rig.probed(Pipeline { TestFIR([1]) })
        #expect(filtered.core.plan.kernelTargets[0] == nil)
        rig.feed(ones(2))
        try await filtered.update(Pipeline { TestFIR([0.5]) })
        rig.feed(ones(12))
        #expect(filtered.core.generation == 2 && filtered.core.runner.installedGeneration == 2 && probe.samples.count == 64 * 14)
        #expect(probe.samples.last == 0.5 && probe.samples.allSatisfy { $0 >= 0.4999 && $0 <= 1.0001 })
        #expect(zip(probe.samples, probe.samples.dropFirst()).allSatisfy { $0 >= $1 - 1e-6 }, "one fade from the unit tap to the new one")
        let kept = filtered.core.plan
        try await filtered.update(Pipeline { TestFIR([1]) })
        rig.feed(ones(12))
        #expect(filtered.core.plan === kept && probe.samples.last == 1)
        filtered.detach()
    }

    /// A stage of a switched group of kernels (ACT-6) reaches and leaves 0 dB as a value as
    /// well: the group is made whole, a kernel for every stage, so there is always one to send
    /// the value to, and the group keeps its state.
    @Test func aGainInsideASwitchedGroupReachesAndLeavesZeroDecibelsAsAValue() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let counter = CallCounter()
        func group(_ factor: Float) -> Pipeline<Samples, Samples> {
            Pipeline { ZTronDSPCore.Group(isActive: on.binding) { TestGain(factor); CountedDelay(counter, delay: 3) } }
        }
        let (session, probe) = try await rig.probed(group(1))
        let plan = session.core.plan
        #expect(plan.kernelTargets.count == 2 && plan.kernelTargets[0] != nil, "a group is made whole")
        let resets = counter.resets
        rig.feed(ones(2))
        try await session.update(group(2))
        rig.feed(ones(10))
        try await session.update(group(1))
        rig.feed(ones(10))
        #expect(session.core.plan === plan && session.core.generation == 1 && counter.resets == resets, "values: nothing is compiled, nothing starts over")
        #expect(probe.samples.count == 64 * 22 && probe.samples[64 * 11 + 63] == 2 && probe.samples.last == 1)
        session.detach()
    }

    /// SWAP-1 across a real change of topology: a gain that is at 0 dB in both plans keeps its
    /// place in both, so what stands behind it is found where it was and keeps its state.
    @Test func aStageBehindAGainAtZeroDecibelsKeepsItsStateAcrossAChangeOfTopology() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(1); CoverageAccumulate(key: 1) })
        rig.feed(ones(2))
        #expect(probe.samples.last == 128)
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestGain(1); CoverageAccumulate(key: 1) }.tap { $0.emit(to: sink) })
        rig.feed(ones(2))
        #expect(session.core.generation == 2 && probe.samples.last == 256, "the sum went on from where it stood")
        // The gain leaves 0 dB in the same update that removes the tap: the sum goes on, and hears the ramp.
        try await session.update(Pipeline { TestGain(2); CoverageAccumulate(key: 1) })
        rig.feed(ones(10))
        #expect(session.core.generation == 3 && session.core.runner.installedGeneration == 3)
        let steps = zip(probe.samples.dropFirst(256), probe.samples.dropFirst(255)).map { (pair: (Float, Float)) -> Float in pair.0 - pair.1 }
        #expect(steps.allSatisfy { $0 >= 0.9999 && $0 <= 2.0001 } && abs((steps.last ?? 0) - 2) < 1e-3, "it adds what the gain hands it: 1, rising to 2")
        session.detach()
    }
}
