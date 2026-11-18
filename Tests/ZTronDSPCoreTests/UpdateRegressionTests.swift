import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A copy on the caller's own C kernel whose making has a consequence the test chooses: what
/// the analysis side does while the control context compiles a plan.
private struct HookedKernel: SequenceStage {
    let key: Int
    let onMake: @Sendable () -> Void

    static func == (lhs: HookedKernel, rhs: HookedKernel) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let onMake = onMake
        context.emit(.custom(CustomKernel(name: "HookedKernel", key: key) { _, _, _ in
            onMake()
            return ztd_kernel_identity()
        }))
    }
}

/// A push source whose ring a thread of the test's own fills, waiting for room: what a file
/// reader is to the engine.
private final class ReaderFedSource: PushSampleSource, @unchecked Sendable {
    // Threading: the writer is behind the lock; the engine sets it once, when the source is adapted.
    private let writer = Locked<RingWriter?>(nil)
    private let channel = SourceEventChannel()

    var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
    var events: AsyncStream<SourceEvent> { channel.stream }

    func prepare() async throws(DSPError) {}
    func start() throws(DSPError) {}
    func stop() {}
    func connect(to ring: RingWriter) { writer.set(ring) }

    /// Writes `block`, waiting for room. Fewer frames than the block holds once the engine
    /// has closed the ring; none before the source was adapted.
    func writeWaiting(_ block: AudioBlock) -> Int {
        writer.get()?.writeWaiting(block) ?? 0
    }
}

/// Updates that meet: a value and a new topology at one block boundary, an update that is
/// refused while another is on its way in, a plan that is replaced after values were sent to
/// it (§4.5, §5.5.4, SWAP-4). Each was a defect; each test fails without its correction. The
/// engine is driven by hand, so every change lands at a block boundary the test chooses.
@Suite("Updates that meet: values, exchanges and refusals (SWAP-4)")
struct UpdateRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 120, seed: 5_150)

    private func ones(_ blocks: Int) -> [Float] { [Float](repeating: 1, count: 64 * blocks) }

    // MARK: A value and a new plan at one boundary (SWAP-4)

    /// SWAP-4: "Value changes that arrive in that window are applied to the plan that ends up
    /// running." §5.5.4: a change of value travels to the kernel that runs.
    ///
    /// A value is sent to the running plan and, before the next block, a change of topology
    /// arrives that keeps the kernel (a tap added behind it). The session's description then
    /// says 5, and the kernel must end on 5.
    ///
    /// The defect: a command names the generation it was queued for. At the block boundary the
    /// new plan was installed first, the command then matched neither the plan that ran nor
    /// one on its way in, and was dropped. The new plan had taken the kernel over as it was,
    /// so the gain stayed 2 for good; an update to the same pipeline is "equal" and sends
    /// nothing. Commands are now applied before a newer plan takes the place of theirs.
    @Test func aValueChangeFollowedAtOnceByANewTopologyIsNotLost() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2) })
        rig.feed(ones(1))
        #expect(probe.samples.last == 2)
        try await session.update(Pipeline { TestGain(5) })
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestGain(5) }.tap { $0.emit(to: sink) })
        rig.feed(ones(12))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(probe.samples.last == 5, "the gain the session was last given is 5; the kernel runs \(probe.samples.last ?? -1)")
        // Saying it again changes nothing: the description is equal to the one the session holds.
        try await session.update(Pipeline { TestGain(5) }.tap { $0.emit(to: sink) })
        rig.feed(ones(12))
        #expect(probe.samples.last == 5, "and an equal update leaves it there: \(probe.samples.last ?? -1)")
        session.detach()
    }

    /// The same where no block boundary comes: a value is queued while the session runs, the
    /// source is interrupted, and a new topology arrives during the interruption. Nothing can
    /// be heard, so the control context installs the plan itself (§5.5.4); what was queued for
    /// the plan it replaces is applied first, and the kernel the new plan took over holds the
    /// value when the source resumes.
    @Test func aValueQueuedBeforeAnInterruptionReachesThePlanExchangedDuringIt() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2) })
        rig.feed(ones(1))
        try await session.update(Pipeline { TestGain(5) })
        #expect(rig.pendingPayloads(of: session) == 1, "queued for the next block")
        rig.source.send(.interrupted)
        #expect(await session.reaches(.interrupted, timeout: 30))

        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestGain(5) }.tap { $0.emit(to: sink) })
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "installed by the control context, at once")
        #expect(rig.pendingPayloads(of: session) == 0, "the value was applied before its plan went")

        rig.source.send(.resumed)
        #expect(await session.reaches(.running, timeout: 30))
        rig.feed(ones(2))
        #expect(probe.samples.count == 64 * 3 && Array(probe.samples[64...]) == ones(2).map { (sample: Float) -> Float in sample * 5 },
                "after the interruption the stages start cold, on the value the session was last given")
        #expect(sink.samples == Array(probe.samples[64...]))
        session.detach()
    }

    /// SWAP-4, once more: a plan is published, a value is sent to it, and before a single
    /// block has passed another topology replaces it. The plan that is replaced never ran; but
    /// it shared the gain's kernel with the plan that runs, and the plan that replaces it takes
    /// that kernel over on the strength of the description, which says 5.
    ///
    /// The defect: the value was dropped with the plan it named, the kernel kept 2, and the
    /// plan that ended up running ran 2 under a description that says 5. What was sent to a
    /// plan is now applied to it before it goes.
    @Test func aValueSentToAPlanThatIsReplacedReachesTheKernelItSharedWithTheNext() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2) })
        rig.feed(ones(1))
        try await session.update(Pipeline { TestGain(2); TestSmoother(1, settling: 4_800) })
        let onItsWayIn = session.core.plan
        try await session.update(Pipeline { TestGain(5); TestSmoother(1, settling: 4_800) })
        #expect(session.core.plan === onItsWayIn && session.core.generation == 2 && rig.pendingPayloads(of: session) == 1,
                "the same topology as the plan on its way in: a value for it")
        try await session.update(Pipeline { TestGain(5); TestDelay(1) })
        #expect(session.core.generation == 3 && session.core.runner.installedGeneration == 1)

        rig.feed(ones(12))
        #expect(session.core.runner.installedGeneration == 3 && !session.core.runner.isInTransition)
        #expect(probe.samples.last == -5, "the gain is the one the session was last given (the test delay inverts): \(probe.samples.last ?? 0)")
        let magnitudes = probe.samples.map { (sample: Float) -> Float in abs(sample) }
        #expect(magnitudes.allSatisfy { $0 >= 1.9999 && $0 <= 5.0001 } && zip(magnitudes, magnitudes.dropFirst()).allSatisfy { $0 <= $1 + 1e-4 },
                "one move from 2 to 5, and never back")
        try rig.engine.core.control.sync { rig.engine.core.service() }
        #expect(rig.pendingPayloads(of: session) == 0)
        session.detach()
    }

    // MARK: An update that is refused (§4.5)

    /// §4.5 (`update`): "A pipeline that does not compile leaves the running one as it is."
    /// SWAP-4: "The latest update wins": a refused update is not one.
    ///
    /// An update is accepted and is being pre-rolled when a second update arrives that is
    /// refused (it names a sink another attachment writes). The first update was accepted; it
    /// must still take over when its pre-roll is done.
    ///
    /// The defect: the exchange settled the transition in flight before it knew whether the
    /// new pipeline could be attached. The plan that was pre-rolled was abandoned, the refusal
    /// thrown, and the session ran its first plan for good under the description of the
    /// abandoned one. A plan on its way in is now replaced only once its successor is certain.
    @Test func aRefusedUpdateDoesNotCancelTheUpdateBeforeIt() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 4_800) })
        rig.feed(Array(noise[128 ..< 256]))
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1, "pre-rolled for a tenth of a second")

        let taken = CollectingSink<Samples>()
        let holder = try await rig.engine.attach(Pipeline().emit(to: taken), to: BufferSource(noise, sampleRate: 48_000))
        await #expect(throws: DSPError.sinkInUse(sink: String(describing: CollectingSink<Samples>.self))) {
            try await session.update(Pipeline { TestGain(-1) }.emit(to: taken))
        }
        // A tenth of a second of pre-roll, 10 ms of fade, and some blocks more.
        rig.feed(Array(noise[256 ..< 256 + 4_800 + 1_280]))
        #expect(session.core.runner.installedGeneration == 2, "the update that was accepted takes over: generation \(session.core.runner.installedGeneration) runs")
        let accepted = try Pipeline { TestSmoother(0.5, settling: 0) }.process(Array(noise[128...]), format: format, blockSize: 64)
        let last = probe.samples.count - 1
        #expect(abs(probe.samples[last] - accepted[last - 128]) < 1e-6, "and the output is its pipeline's")
        holder.detach()
        session.detach()
    }

    /// The same when the refusal comes late: the refused pipeline names a sink that was claimed
    /// for the plan on its way in, that sink has already been prepared for the refused plan,
    /// and then another of its sinks cannot be had. The sink is prepared again for the plan on
    /// its way in, never released, and that plan takes over and feeds it (ATT-5, §4.5).
    @Test func aRefusedUpdateLeavesTheSinksOfThePlanOnItsWayInAsTheyWere() async throws {
        let rig = Rig()
        let fresh = CollectingSink<Samples>()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 640) }.tap { $0.emit(to: fresh) })
        rig.feed(Array(noise[128 ..< 256]))
        #expect(session.core.runner.isInTransition && fresh.claims == 1 && fresh.frameCount == 0, "pre-rolled: its sink is claimed and idle")

        await #expect(throws: DSPError.self) {
            try await session.update(Pipeline { TestGain(-1) }.tap { $0.testGain(2).emit(to: fresh) }.emit(to: RefusingSink()))
        }
        #expect(fresh.claims == 3 && fresh.releases == 0 && SinkRegistry.isClaimed(ObjectIdentifier(fresh)),
                "prepared for the refused plan, and again for the plan it belongs to; never let go")
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1, "the plan on its way in is still on its way in")

        rig.feed(Array(noise[256 ..< 256 + 640 + 1_280]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(fresh.frameCount > 0 && fresh.samples == Array(probe.samples.suffix(fresh.samples.count)), "and feeds its sink from the block it takes over")
        session.detach()
        #expect(fresh.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(fresh)))
    }

    /// And when the sink then refuses to be prepared again for the plan it was claimed for:
    /// that plan takes over all the same, without the sink, which is prepared for frames that
    /// will not come. The session keeps its claim (ATT-5), and the next plan that names the
    /// sink prepares it anew and feeds it.
    @Test func aSinkThatCannotGoBackToThePlanOnItsWayInWaitsForTheNextPlan() async throws {
        let rig = Rig()
        let fussy = CoverageFussySink()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 640) }.tap { $0.emit(to: fussy) })
        rig.feed(Array(noise[128 ..< 256]))
        #expect(session.core.runner.isInTransition && fussy.claims == 1, "pre-rolled: its sink is claimed")

        // The refused update prepares the sink for itself (claim 2); giving it back is claim 3.
        fussy.refused = [3]
        await #expect(throws: DSPError.self) {
            try await session.update(Pipeline { TestGain(-1) }.tap { $0.testGain(2).emit(to: fussy) }.emit(to: RefusingSink()))
        }
        #expect(fussy.claims == 3 && fussy.releases == 0 && SinkRegistry.isClaimed(ObjectIdentifier(fussy)), "asked twice more; still the session's")
        rig.feed(Array(noise[256 ..< 256 + 640 + 1_280]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "the plan on its way in takes over")
        #expect(fussy.samples.isEmpty, "without the sink that would not be prepared for it again")

        // The same tap, and another main line behind it: the sink's branch is the one it had,
        // and the next plan prepares the sink anew all the same.
        try await session.update(Pipeline { TestSmoother(0.5, settling: 640) }.tap { $0.emit(to: fussy) }.testGain(-1))
        #expect(fussy.claims == 4 && session.core.generation == 4, "the next plan prepares it anew")
        rig.feed(Array(noise[2_176 ..< 3_200]))
        #expect(session.core.runner.installedGeneration == 4 && !session.core.runner.isInTransition)
        #expect(!fussy.samples.isEmpty && fussy.samples == probe.samples.suffix(fussy.samples.count).map { (sample: Float) -> Float in -sample },
                "and feeds it, from the block it takes over (the main line inverts behind the tap)")
        session.detach()
        #expect(fussy.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(fussy)))
    }

    /// CR-015, item 5: a plan that is being faded in is heard already, so an update that
    /// arrives then lets it take over at once. That holds for an update that is refused too:
    /// the plan that was fading in runs, alone, and the session is the one its update made.
    @Test func anUpdateRefusedDuringAFadeLetsTheFadingPlanTakeOver() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 64) })
        // One block of pre-roll, then a fade of 480 frames: five blocks on, it is fading.
        rig.feed(Array(noise[128 ..< 448]))
        #expect(session.core.runner.isInTransition && session.core.runner.isFading && session.core.runner.installedGeneration == 1)

        let taken = CollectingSink<Samples>()
        let holder = try await rig.engine.attach(Pipeline().emit(to: taken), to: BufferSource(noise, sampleRate: 48_000))
        await #expect(throws: DSPError.sinkInUse(sink: String(describing: CollectingSink<Samples>.self))) {
            try await session.update(Pipeline { TestGain(-1) }.emit(to: taken))
        }
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "the plan that was fading in runs, alone")
        rig.feed(Array(noise[448 ..< 640]))
        let second = [Float](repeating: 0, count: 128) + (try Pipeline { TestSmoother(0.5, settling: 0) }.process(Array(noise[128...]), format: format, blockSize: 64))
        #expect(Array(probe.samples[448...]) == Array(second[448 ..< 640]), "its output, from the block after the refusal")
        holder.detach()
        session.detach()
    }

    /// SWAP-4 beside a thread that does not wait: while the control context compiles the plan
    /// of an update, the plan of the update before it goes on, here from its pre-roll into its
    /// fade. What was compiled replaces a plan that is no longer the one to replace: the plan
    /// that fades in takes over, and the update is compiled again, against it. The session
    /// ends on the pipeline given last, and no plan is made for a plan that does not run.
    @Test func aPlanThatStartsToFadeWhileItsSuccessorIsCompiledTakesOverFirst() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 128) })
        rig.feed(Array(noise[128 ..< 192]))
        #expect(session.core.runner.isInTransition && !session.core.runner.isFading, "two blocks of pre-roll: one is through")

        // The kernel of the next pipeline is made on the control context. The first time, the
        // analysis side runs three blocks meanwhile: the rest of the pre-roll, and into the fade.
        let makes = Locked(0)
        let meanwhile = Array(noise[192 ..< 384])
        let hooked = HookedKernel(key: 1) {
            let count = makes.withLock { (value: inout Int) -> Int in
                value += 1
                return value
            }
            if count == 1 { rig.feed(meanwhile) }
        }
        try await session.update(Pipeline { hooked; TestGain(-1) })
        #expect(makes.get() == 2, "compiled against the plan that ran, and again against the one that took over meanwhile: \(makes.get())")
        #expect(session.core.runner.installedGeneration == 2 && session.core.generation == 4, "generation 3 was compiled for a plan it never followed")

        rig.feed(Array(noise[384 ..< 1_280]))
        #expect(session.core.runner.installedGeneration == 4 && !session.core.runner.isInTransition)
        #expect(probe.samples.count == 1_280 && Array(probe.samples[1_216...]) == noise[1_216 ..< 1_280].map { (sample: Float) -> Float in -sample },
                "the pipeline given last runs")
        await rig.drain()
        #expect(await eventually(timeout: 30) { log.all.filter { $0 == .replanned(.update) }.count == 2 }, "two plans took over: \(log.all)")
        session.detach()
    }

    // MARK: Who books an exchange (SWAP-2)

    /// SWAP-2: where old and new output cannot be cross-faded, "the output changes at a block
    /// boundary and the session reports `.outputChanged`". The analysis side says so with the
    /// exchange it carried out, and the control context books the exchange when it next serves
    /// the session, or earlier, when an update arrives before that. Here the next update
    /// arrives first: the exchange it finds carried out is reported with what was said of it.
    ///
    /// The defect: booked by the update, the exchange was reported as `.replanned(.update)`
    /// alone; what the analysis side had said was read afterwards, when the plan of the next
    /// update was already on its way in, and was dropped there.
    @Test func anExchangeBookedByTheNextUpdateStillReportsThatTheOutputChanged() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0); TestLate(latency: 0, chunk: 64) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<128]))
        // Another smoother in front of the node: nothing to settle, and with a node in what is
        // new no cross-fade. Same format, same latency: only the exchange itself tells.
        try await session.update(Pipeline { TestSmoother(0.5, settling: 0); TestLate(latency: 0, chunk: 64) })
        // One block, turned by hand, without the control context's turn that follows a block:
        // the plans are exchanged, and the control context has not heard of it.
        let runner = try #require(rig.engine.core.rootRunners().first)
        rig.source.write(Array(noise[128 ..< 192]))
        _ = runner.turn(now: 0)
        #expect(session.core.runner.installedGeneration == 2 && session.core.installedPlan.generation == 1, "carried out, and not booked")

        // The next update books it. Its own plan is pre-rolled for a tenth of a second.
        try await session.update(Pipeline { TestSmoother(0.25, settling: 4_800); TestLate(latency: 0, chunk: 64) })
        #expect(session.core.installedPlan.generation == 2 && session.core.generation == 3)
        rig.feed(Array(noise[192 ..< 320]))
        #expect(session.core.runner.isInTransition && probe.samples.count == 320)
        await rig.drain()
        #expect(await eventually(timeout: 30) { log.contains(.replanned(.update)) })
        #expect(await eventually(timeout: 30) { log.contains(.outputChanged) }, "the exchange was reported without the change of output: \(log.all)")
        session.detach()
    }

    /// The same when the session is stopped before the control context has served it: the
    /// exchange is booked by the stop, and is reported whole.
    @Test func anExchangeBookedWhenTheSessionStopsStillReportsThatTheOutputChanged() async throws {
        let rig = Rig()
        let (session, _) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0); TestLate(latency: 0, chunk: 64) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 0); TestLate(latency: 0, chunk: 64) })
        let runner = try #require(rig.engine.core.rootRunners().first)
        rig.source.write(Array(noise[128 ..< 192]))
        _ = runner.turn(now: 0)
        #expect(session.core.runner.installedGeneration == 2 && session.core.installedPlan.generation == 1, "carried out, and not booked")

        session.stop()
        #expect(session.core.installedPlan.generation == 2 && session.state == .idle)
        await rig.drain()
        #expect(await eventually(timeout: 30) { log.contains(.replanned(.update)) })
        #expect(await eventually(timeout: 30) { log.contains(.outputChanged) }, "the exchange was reported without the change of output: \(log.all)")
        session.detach()
    }

    // MARK: What the analysis side reads of a plan (RT-4)

    /// RT-4: nothing crosses between the control context and the thread that runs a plan but
    /// what is handed over whole. A plan's description is the control context's: it is
    /// replaced when a value changes, also on a plan that is on its way in, because it is
    /// what the next update is compared with. So the thread that runs the plan reads nothing
    /// of it; what it needs when it takes a plan over, the length of the fade and of the
    /// pre-roll, are constants of the plan (`ExecutionPlan.fadeLength`, `PlanTransition`).
    ///
    /// This is the case in which the two met. The engine runs on its own thread, a third
    /// thread writes blocks all the while, and nothing orders either with the updates: a
    /// change of topology, and at once a change of a value for the plan that is on its way
    /// in. The test shows that the session ends on the pipeline it was given last and, under
    /// the Thread Sanitizer, that the threads share nothing the sanitizer sees.
    ///
    /// It does not by itself show that the analysis thread leaves the description alone. The
    /// sanitizer does not see a struct replaced as a whole: with the old read of the
    /// description put back it reports nothing here, while a counter written beside the
    /// description and read where the plan is taken over is reported at once. That part rests
    /// on the plan itself, where everything the analysis side reads is a `let`.
    @Test func aValueForAPlanOnItsWayInTouchesNothingTheAnalysisThreadReads() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ReaderFedSource()
        // The blocks that arrive are counted in a tap in front of everything: a branch no update changes.
        let arrived = CountingSink<Samples>()
        func pipeline(_ coefficient: Float, settling: Int, gain: Float) -> Pipeline<Samples, Samples> {
            Pipeline { Tap { Emit(to: arrived) }; TestSmoother(coefficient, settling: settling); TestGain(gain) }
        }
        let session = try await engine.attach(pipeline(1, settling: 0, gain: 1.5), to: source)
        // Read once the session has stopped: until then it belongs to the thread that runs the session.
        let probe = OutputProbe()
        engine.core.addProbe(probe, to: session.core)
        try session.start()

        let stop = Locked(false), finished = Locked(false)
        let writer = Thread {
            if let buffer = try? AudioBuffer(channels: [[Float](repeating: 1, count: 64)]) {
                while !stop.get() { _ = source.writeWaiting(buffer.block()) }
            }
            finished.set(true)
        }
        writer.start()

        let rounds = 40
        for round in 0 ..< rounds {
            // Another smoother is another stage: a plan, which is pre-rolled for a tenth of a second …
            let coefficient = 0.5 + Float(round) * 0.01
            try await session.update(pipeline(coefficient, settling: 4_800, gain: 2))
            // … and a value for that plan, before it has taken over.
            try await session.update(pipeline(coefficient, settling: 4_800, gain: 3))
        }
        let last = try engine.core.control.sync { session.core.plan.generation }
        #expect(last > UInt32(rounds), "a plan for every round: generation \(last)")
        #expect(await eventually(timeout: 60) { session.core.runner.installedGeneration == last && !session.core.runner.isInTransition },
                "the plan given last takes over")
        // Long enough for its gain to have ramped to the value it was sent while it was on its way in.
        let blocks = arrived.frames
        #expect(await eventually(timeout: 60) { arrived.frames >= blocks + 32 })

        stop.set(true)
        session.stop()
        #expect(await eventually(timeout: 60) { finished.get() }, "the reader is let go when the ring is closed")
        #expect(abs((probe.samples.last ?? 0) - 3) < 1e-3, "the session ends on the pipeline it was given last: \(probe.samples.last ?? 0)")
        session.detach()
    }

    // MARK: What the two plans of an exchange share (SWAP-1, SWAP-2)

    /// SWAP-1: "A kernel or node whose own description and whole upstream path are equal in
    /// both plans is moved into the new plan with its state." SWAP-2: while what is new on the
    /// main line is pre-rolled and faded in, "the old plan still produces the output while the
    /// new stages run beside it".
    ///
    /// An update changes a value and the topology at once: another gain, and a tap. The delay
    /// behind the gain is described as before, but its upstream path is not equal: the gain in
    /// front of it changed. It must not be moved.
    ///
    /// The defect: a place in the signal is keyed without the values a kernel takes by
    /// command, so the delay was found at its place and taken over, behind a gain that was
    /// made anew. From the gain on, both plans ran, and both ran the one delay line: twice for
    /// every block, on two signals. The output of the transition was neither plan's. The main
    /// line now takes over what the running plan runs, object for object, up to the first
    /// that differs; what stands behind it is made anew.
    @Test func aStageBehindAStageThatChangedIsNotSharedByTheTwoPlans() async throws {
        let rig = Rig()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); TestDelay(3) })
        rig.feed(Array(noise[..<256]))
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestGain(3); TestDelay(3) }.tap { $0.emit(to: sink) })
        rig.feed(Array(noise[256 ..< 1_920]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)

        // The test delay inverts: −2·x[n − 3] before, −3·x[n − 3] after, and between them a cross-fade.
        let delayed = [Float](repeating: 0, count: 3) + noise
        let strays = probe.samples.indices.filter { index in
            let low = min(-2 * delayed[index], -3 * delayed[index]) - 1e-5, high = max(-2 * delayed[index], -3 * delayed[index]) + 1e-5
            return probe.samples[index] < low || probe.samples[index] > high
        }
        #expect(strays.isEmpty, "\(strays.count) samples are neither plan's nor between the two; the first is \(strays.first ?? -1)")
        #expect(Array(probe.samples[..<256]) == delayed[..<256].map { (sample: Float) -> Float in -2 * sample })
        #expect(Array(probe.samples.suffix(64)) == delayed[1_856 ..< 1_920].map { (sample: Float) -> Float in -3 * sample }, "after the exchange: the new plan's output")
        #expect(sink.samples == Array(probe.samples.suffix(sink.samples.count)))
        session.detach()
    }

    /// The same for a gain that goes to 0 dB in an update that also changes the topology: the
    /// new plan has no kernel for it (F4), the running plan has one, and the delay behind it is
    /// behind a difference of the two main lines. It is made anew, and the two plans are
    /// cross-faded.
    @Test func aStageBehindAGainThatAnUpdateRemovesIsNotSharedEither() async throws {
        let rig = Rig()
        let counter = CallCounter()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(2); CountedDelay(counter, delay: 3) })
        rig.feed(Array(noise[..<256]))
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestGain(1); CountedDelay(counter, delay: 3) }.tap { $0.emit(to: sink) })
        #expect(session.core.generation == 2 && session.core.plan.kernelTargets.count == 2 && session.core.plan.kernelTargets[0] == nil)
        rig.feed(Array(noise[256 ..< 1_920]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)

        let delayed = [Float](repeating: 0, count: 3) + noise
        let strays = probe.samples.indices.filter { index in
            let low = min(delayed[index], 2 * delayed[index]) - 1e-5, high = max(delayed[index], 2 * delayed[index]) + 1e-5
            return probe.samples[index] < low || probe.samples[index] > high
        }
        #expect(strays.isEmpty, "\(strays.count) samples are neither plan's nor between the two; the first is \(strays.first ?? -1)")
        #expect(Array(probe.samples.suffix(64)) == Array(delayed[1_856 ..< 1_920]), "after the exchange: the delayed signal, at 0 dB")
        session.detach()
    }

    /// And where the two meet: in one update a gain leaves 0 dB in front of a delay that stays,
    /// and the stage behind the delay is replaced. The gain's kernel arrives as an identity;
    /// the delay stands before the first stage that differs, so it is moved, and it is run by
    /// one plan at a time, once per block; the new stage is pre-rolled and faded in behind it;
    /// and once the new plan runs, the gain ramps from 0 dB.
    @Test func aGainThatLeavesZeroDecibelsInFrontOfAStageThatIsReplacedStillRamps() async throws {
        let rig = Rig()
        let counter = CallCounter()
        let (session, probe) = try await rig.probed(Pipeline { TestGain(1); CountedDelay(counter, delay: 3); TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<256]))
        #expect(counter.blocks == 4)
        // The smoother's settling time is part of its description: another one is another stage,
        // which does the same (a coefficient of 1 passes the signal).
        try await session.update(Pipeline { TestGain(2); CountedDelay(counter, delay: 3); TestSmoother(1, settling: 128) })
        #expect(session.core.generation == 2)
        rig.feed(Array(noise[256 ..< 384]))
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1, "the new stage is pre-rolled for 128 frames")
        rig.feed(Array(noise[384 ..< 2_560]))
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition)
        #expect(counter.blocks == 40, "the delay ran once for every block, in whichever plan: \(counter.blocks)")

        let delayed = [Float](repeating: 0, count: 3) + noise
        // Two blocks of pre-roll and 480 frames of fade between two plans that do the same: the
        // delayed signal (to the last bits of what the smoother's arithmetic makes of it).
        expectClose(Array(probe.samples[..<896]), Array(delayed[..<896]), .absolute(1e-6), "until the new plan runs, the gain is at 0 dB")
        let gains = (896 ..< 2_560).filter { abs(delayed[$0]) > 0.05 }.map { (index: Int) -> Float in probe.samples[index] / delayed[index] }
        #expect(gains.allSatisfy { $0 >= 0.9999 && $0 <= 2.0001 } && zip(gains, gains.dropFirst()).allSatisfy { $0 <= $1 + 1e-3 }, "then it ramps, and never back")
        #expect((gains.first ?? 0) < 1.05, "from 0 dB: \(gains.first ?? 0)")
        expectClose(Array(probe.samples.suffix(64)), delayed[2_496 ..< 2_560].map { (sample: Float) -> Float in 2 * sample }, .absolute(1e-6), "to 6 dB")
        session.detach()
    }

    /// ATT-5, SWAP-4: a sink that was claimed for a plan on its way in goes over to the plan
    /// that replaces it, when that plan writes it too: it is prepared for the frames it will
    /// get, never released in between, and never free for another writer.
    @Test func aSinkOfAPlanThatIsReplacedGoesOverToThePlanThatReplacesIt() async throws {
        let rig = Rig()
        let fresh = CollectingSink<Samples>()
        let (session, probe) = try await rig.probed(Pipeline { TestSmoother(1, settling: 0) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 48_000) }.tap { $0.emit(to: fresh) })
        rig.feed(Array(noise[128 ..< 256]))
        #expect(session.core.runner.isInTransition && fresh.claims == 1)

        try await session.update(Pipeline { TestGain(-1) }.tap { $0.emit(to: fresh) })
        #expect(fresh.claims == 2 && fresh.releases == 0 && SinkRegistry.isClaimed(ObjectIdentifier(fresh)), "prepared for the plan that came instead; never let go")
        rig.feed(Array(noise[256 ..< 896]))
        #expect(session.core.runner.installedGeneration == 3 && probe.samples.last == -noise[895])
        #expect(fresh.frameCount > 0 && fresh.samples == Array(probe.samples.suffix(fresh.samples.count)), "and fed by it")
        session.detach()
        #expect(fresh.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(fresh)))
    }
}
