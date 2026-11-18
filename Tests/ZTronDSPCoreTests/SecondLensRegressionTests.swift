import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// Stages written as a client of the core writes them, for the checks below.

/// Counts what a `SampleProcessor` is asked to do.
final class CallCounter: Hashable, @unchecked Sendable {
    // Threading: touched only by the thread that runs the plan under test.
    var blocks = 0
    var resets = 0
    static func == (lhs: CallCounter, rhs: CallCounter) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A pure delay of `delay` frames as a `SampleProcessor`, counting the blocks it is given.
struct CountedDelay: SequenceStage {
    let counter: CallCounter
    let delay: Int
    var activation: StageActivation = .active

    init(_ counter: CallCounter, delay: Int = 0, isActive: some ActivationSource = .active) {
        self.counter = counter
        self.delay = delay
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let counter = counter, delay = delay
        context.emit(.processor(CustomProcessor(name: "CountedDelay", key: self, latencyFrames: delay) { _ throws(DSPError) -> any SampleProcessor in
            CountedDelayProcessor(counter: counter, delay: delay)
        }))
    }
}

final class CountedDelayProcessor: SampleProcessor {
    let counter: CallCounter
    let delay: Int
    private let ring: UnsafeMutablePointer<Float>
    private var position = 0

    init(counter: CallCounter, delay: Int) {
        self.counter = counter
        self.delay = delay
        ring = .allocate(capacity: max(delay, 1))
        ring.initialize(repeating: 0, count: max(delay, 1))
    }

    deinit {
        ring.deallocate()
    }

    var latencyFrames: Int { delay }
    var settlingFrames: Int { 0 }

    func process(_ block: inout AudioBlock) {
        counter.blocks += 1
        guard delay > 0 else { return }
        let samples = block.channel(0)
        var frame = 0
        while frame < block.frameCount {
            let incoming = samples[frame]
            samples[frame] = ring[position]
            ring[position] = incoming
            position += 1
            if position == delay { position = 0 }
            frame += 1
        }
    }

    func reset() {
        counter.resets += 1
        position = 0
        var index = 0
        while index < max(delay, 1) {
            ring[index] = 0
            index += 1
        }
    }
}

/// Calls of the kernel below. A C function pointer captures nothing, so the count is global.
nonisolated(unsafe) var kernelDelayCalls = 0

/// A pure delay of `delay` frames on the caller's own C kernel (one channel).
struct KernelDelay: SequenceStage {
    let delay: Int
    var activation: StageActivation = .active

    init(_ delay: Int, isActive: some ActivationSource = .active) {
        self.delay = delay
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let delay = delay
        context.emit(.custom(CustomKernel(name: "KernelDelay", key: self, latencyFrames: delay) { _, _, _ in
            // State: [position, length, ring…].
            let state = UnsafeMutablePointer<Float>.allocate(capacity: delay + 2)
            state.initialize(repeating: 0, count: delay + 2)
            state[1] = Float(delay)
            return ztd_kernel_t(
                process: { state, input, output, _, frames in
                    kernelDelayCalls += 1
                    let values = state!.assumingMemoryBound(to: Float.self)
                    let length = Int(values[1])
                    var position = Int(values[0])
                    let ring = values + 2
                    let source = input![0]!, target = output![0]!
                    var index = 0
                    while index < Int(frames) {
                        let incoming = source[index]
                        if length == 0 {
                            target[index] = incoming
                        } else {
                            target[index] = ring[position]
                            ring[position] = incoming
                            position += 1
                            if position == length { position = 0 }
                        }
                        index += 1
                    }
                    values[0] = Float(position)
                    return frames
                },
                command: nil,
                reset: { state in
                    let values = state!.assumingMemoryBound(to: Float.self)
                    let length = Int(values[1])
                    values[0] = 0
                    var index = 0
                    while index < length {
                        values[2 + index] = 0
                        index += 1
                    }
                },
                destroy: { state in state!.assumingMemoryBound(to: Float.self).deallocate() },
                state: UnsafeMutableRawPointer(state), latency_frames: UInt32(delay), settling_frames: 0)
        }))
    }
}

/// A sink that refuses every claim.
final class RefusingSink: FeatureSink, @unchecked Sendable {
    typealias Domain = Samples
    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) { throw .resourceAllocationFailed(what: "storage") }
    func write(_ frame: FrameView) {}
    func release() {}
}

/// A push source whose second preparation fails.
final class MoodySource: PushSampleSource, @unchecked Sendable {
    private let channel = SourceEventChannel()
    let prepares = Locked(0)
    var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
    var events: AsyncStream<SourceEvent> { channel.stream }

    func prepare() async throws(DSPError) {
        let count = prepares.withLock { (value: inout Int) -> Int in value += 1; return value }
        if count == 2 { throw .sourceUnavailable(reason: "the second preparation") }
    }

    func start() throws(DSPError) {}
    func stop() {}
    func connect(to ring: RingWriter) {}
    func send(_ event: SourceEvent) { channel.send(event) }
}

/// A clock that sleeps for real and records how long it was asked to.
final class SleepLog: AnalysisClock, @unchecked Sendable {
    let sleeps = Locked<[Double]>([])
    var now: Double { ztd_thread_now() }

    func sleep(until deadline: Double) {
        let wanted = deadline - ztd_thread_now()
        sleeps.withLock { $0.append(wanted) }
        ztd_thread_sleep_until(deadline)
    }
}

/// Defects and blind spots found by the second verification of the engine, each kept as a
/// test of the rule it concerns.
@Suite("Engine: what the second verification found")
struct SecondLensRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 40, seed: 77)
    let ones = [Float](repeating: 1, count: 64)

    private func kinds(_ steps: [IRStep]) -> [String] {
        steps.map {
            switch $0 {
            case .kernel: "kernel"
            case .node(let node): "node:\(node.step.name)"
            case .emission: "emit"
            case .branch(let branch): (branch.isShared ? "shared" : "branch") + "[" + kinds(branch.steps).joined(separator: ",") + "]"
            case .region(let region): "region[" + kinds(region.steps).joined(separator: ",") + "]"
            case .gate: "gate"
            }
        }
    }

    // MARK: Constants that suspend (ACT-3, ACT-4)

    @Test func aStageOffForGoodInsideAGroupOrAReaderSuspendsTheRestOfItsBranch() throws {
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)
        typealias Bins = Spectrum<LinearFrequency, ComplexValues>

        // Written directly in the tap, in a group, and produced by a reader: the same plan.
        let direct = CollectingSink<Bins>(), grouped = CollectingSink<Bins>(), read = CollectingSink<Bins>()
        let probe = TestProbe()
        let pipelines: [(String, Pipeline<Samples, Samples>, CollectingSink<Bins>)] = [
            ("direct", Pipeline { Tap { TestFramer(frame: 64, hop: 16, isActive: false); Emit(to: direct); TestMagnitude(probe: probe) } }, direct),
            ("in a group", Pipeline { Tap { ZTronDSPCore.Group { TestFramer(frame: 64, hop: 16, isActive: false) }; Emit(to: grouped); TestMagnitude(probe: probe) } }, grouped),
            ("from a reader", Pipeline { Tap { EnvironmentReader { _ in TestFramer(frame: 64, hop: 16, isActive: false) }; Emit(to: read); TestMagnitude(probe: probe) } }, read),
        ]
        for (name, pipeline, sink) in pipelines {
            let lowered = try compiler.lower(pipeline.stages, environment: environment, blockSize: 64)
            #expect(lowered.steps.isEmpty && !lowered.isSuspended, "\(name): the branch is removed whole: \(kinds(lowered.steps))")
            try pipeline.run(on: noise, format: format, blockSize: 64)
            #expect(sink.claims == 0 && sink.frameCount == 0, "\(name): a sink behind the stage is not claimed and receives nothing")
        }
        #expect(probe.magnitudeNodesMade == 0, "no node is made for a stage behind one that is off for good")

        // What stands before the group in the branch stays, and a tap ends the suspension:
        // the main line after the tap runs.
        let before = CollectingSink<Samples>(), after = CollectingSink<Samples>()
        let mixed = Pipeline {
            Tap { Emit(to: before); ZTronDSPCore.Group { TestFramer(frame: 64, hop: 16, isActive: false) }; TestMagnitude() }
            TestGain(2)
            Emit(to: after)
        }
        #expect(kinds(try compiler.lower(mixed.stages, environment: environment, blockSize: 64).steps) == ["branch[emit]", "kernel", "emit"])
        #expect(try mixed.process(noise, format: format, blockSize: 64) == noise.map { $0 * 2 })
        #expect(before.samples == noise && after.samples == noise.map { $0 * 2 })

        // A group that is itself bypassed for good passes the signal on, whatever it holds.
        let passing = Pipeline { ZTronDSPCore.Group(isActive: false) { TestGain(4) }; TestGain(2) }
        #expect(try passing.process(noise, format: format, blockSize: 64) == noise.map { $0 * 2 })
        // The rest is still validated.
        #expect(throws: DSPError.self) {
            try Pipeline { ZTronDSPCore.Group { TestSubsample(by: 2, isActive: false) }; TestGain(.nan) }.process(noise, format: format)
        }
    }

    @Test func aRateChangerOffForGoodOnTheMainLineSuspendsItLikeABoundOne() async throws {
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)
        let before = CollectingSink<Samples>(), behind = CollectingSink<Samples>()
        let constant = Pipeline { TestGain(0.5); Emit(to: before); TestSubsample(by: 2, isActive: false); TestGain(3); Emit(to: behind) }
        let lowered = try compiler.lower(constant.stages, environment: environment, blockSize: 64)
        #expect(lowered.isSuspended && kinds(lowered.steps) == ["kernel", "emit"], "what follows the stage is removed: \(kinds(lowered.steps))")
        #expect(lowered.output.environment.sampleRate == 24_000, "the output is declared as it would be with the stage on")
        let out = try constant.process(noise, format: format, blockSize: 64)
        #expect(out.isEmpty, "nothing leaves a suspended main line (ACT-3): \(out.count) samples")
        #expect(before.samples == noise.map { $0 * 0.5 } && behind.claims == 0, "what precedes the stage runs; what follows is not even claimed")

        // The same pipeline with the switch bound and off.
        let off = StateBox(false)
        let bound = Pipeline { TestGain(0.5); TestSubsample(by: 2, isActive: off.binding); TestGain(3) }
        let boundOut = try await MainActor.run { try bound.process(noise, format: format, blockSize: 64) }
        #expect(boundOut.isEmpty, "a constant and a binding suspend the main line alike")

        // As a processed source: it delivers what its format says, or nothing.
        let engine = DSPEngine(blockSize: 64)
        let processed = BufferSource(noise, sampleRate: 48_000).processed(by: Pipeline { TestSubsample(by: 2, isActive: false) })
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestGain(2); TestBiquad(count: 2) }.emit(to: sink), to: processed)
        #expect(session.environment.sampleRate == 24_000 && session.environment.blockSize <= 33)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples.isEmpty, "no block of another rate reaches the session behind: \(sink.samples.count) samples")
        session.detach()

        // An update that flips the constant is heard: the output changes.
        let rig = Rig()
        let live = try await rig.engine.attach(Pipeline { TestSubsample(by: 2, isActive: false) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: live.core)
        let log = EventLog(live)
        try live.start()
        rig.feed(Array(noise[..<640]))
        #expect(probe.samples.isEmpty)
        try await live.update(Pipeline { TestSubsample(by: 2) })
        await rig.drain()
        rig.feed(Array(noise[640 ..< 1_280]))
        await rig.drain()
        #expect(probe.samples == subsampled(Array(noise[640 ..< 1_280]), by: 2), "switched on by an update, the main line runs, from a cold start")
        #expect(await eventually { log.contains(.outputChanged) })
        live.detach()
    }

    @Test func aPlanNeverWritesPastItsBuffers() throws {
        // Whatever a caller hands it: a block longer than the plan was made for is cut, not
        // written past the scratch tables (the C layer's own guard).
        let plan = try #require(ztd_plan_create(2, 1, 32))
        defer { ztd_plan_destroy(plan) }
        _ = ztd_plan_append(plan, ztd_gain_cascade_create(1, [0.5], 1, 0, ZTD_IMPLEMENTATION_NATIVE), true)
        _ = ztd_plan_append(plan, ztd_gain_cascade_create(1, [4], 1, 0, ZTD_IMPLEMENTATION_NATIVE), true)
        #expect(ztd_plan_count(plan) == 2)
        let input = try AudioBuffer(channels: [[Float](repeating: 1, count: 64)])
        let output = try AudioBuffer(channelCount: 1, capacity: 64)
        output.channel(0).update(repeating: -1, count: 64)
        let written = ztd_plan_run(plan, input.block().constantChannelTable, output.block().channelTable, 1, 64)
        #expect(written == 32, "64 frames into a plan of 32: \(written) are processed")
        #expect(output.array(ofChannel: 0, frameCount: 64) == [Float](repeating: 2, count: 32) + [Float](repeating: -1, count: 32))
    }

    // MARK: Cold resume (ACT-9, ACT-10)

    @Test func sharedFramingStartsColdWhenItsLastConsumerResumes() async throws {
        let rig = Rig()
        let first = StateBox(true), second = StateBox(true)
        typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
        let a = CollectingSink<Magnitudes>(), b = CollectingSink<Magnitudes>()
        let probe = TestProbe()
        let session = try await rig.engine.attach(
            Pipeline()
                .tap(isActive: first.binding) { $0.testFramer(frame: 256, hop: 64, probe: probe).testMagnitude().emit(to: a) }
                .tap(isActive: second.binding) { $0.testFramer(frame: 256, hop: 64, probe: probe).testMagnitude().emit(to: b) },
            to: rig.source)
        try session.start()
        let signal = TestSignal.whiteNoise(count: 64 * 30, seed: 2)
        rig.feed(Array(signal[..<640]))
        #expect(probe.framerNodesMade == 1, "the two taps share one framer (F5)")
        let before = a.frameCount
        #expect(before == 7 && b.frameCount == 7)
        first.value = false
        second.value = false
        await session.syncBindings()
        rig.feed(Array(signal[640 ..< 1_280]))
        #expect(a.frameCount == before && probe.framesFramed == before, "no consumer: the shared framer does not run (ACT-9)")
        first.value = true
        await session.syncBindings()
        rig.feed(Array(signal[1_280...]))
        let resumed = Array(a.reals[before...])
        let cold = try Pipeline().testFramer(frame: 256, hop: 64).testMagnitude().process(Array(signal[1_280...]), format: format, blockSize: 64)
        #expect(resumed.count == cold.count, "\(resumed.count) frames after the resume, a cold start gives \(cold.count)")
        #expect(resumed == cold, "no stale frame: a branch that resumes starts as it does at session start (ACT-10)")
        #expect(b.frameCount == before, "the branch that stayed off received nothing")

        // While another consumer keeps the framer running, a branch that comes back joins it warm.
        second.value = true
        await session.syncBindings()
        let resets = probe.framerResets
        rig.feed(Array(signal[..<640]))
        #expect(probe.framerResets == resets, "a shared prefix that is running is not reset for a late-comer")
        session.detach()
    }

    // MARK: The state table (§4.5)

    @Test func aRestartWhosePreparationFailsCanBeTriedAgain() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = MoodySource()
        let session = try await engine.attach(Pipeline { TestGain(2) }, to: source)
        try session.start()
        #expect(await session.reaches(.running))
        source.send(.ended)
        #expect(await session.reaches(.finished))
        try session.start()
        #expect(await session.reaches(.failed(.sourceUnavailable(reason: "the second preparation"))), "the second preparation fails: \(session.state)")
        try session.start()
        #expect(await session.reaches(.running), "the source is prepared again, then running: \(session.state)")
        #expect(source.prepares.get() == 3, "prepared once per start that needed it: \(source.prepares.get())")
        session.detach()
    }

    @Test func aFailedSessionStartsAgainAndRuns() async throws {
        // `start()` in `failed` does something: the source is prepared again and blocks flow.
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestDelay(5) }.emit(to: sink), to: source)
        try session.start()
        source.write(ones)
        #expect(await eventually { sink.samples.count == 64 })
        let error = DSPError.sourceUnavailable(reason: "gone")
        source.send(.failed(error))
        #expect(await session.reaches(.failed(error)))
        #expect(source.stops == 1, "a failed stream stops its source")
        try session.start()
        #expect(await session.reaches(.running))
        #expect(source.prepares == 2 && source.starts == 2, "prepared and started again: \(source.prepares), \(source.starts)")
        source.write(ones)
        #expect(await eventually { sink.samples.count == 128 })
        #expect(Array(sink.samples.suffix(64).prefix(6)) == [0, 0, 0, 0, 0, -1], "and the stages start cold (the test delay inverts)")
        session.detach()
    }

    @Test func stagesStartColdAfterAResumption() async throws {
        let rig = Rig()
        let sink = CollectingSink<Samples>()
        let session = try await rig.engine.attach(Pipeline { TestDelay(5) }.emit(to: sink), to: rig.source)
        try session.start()
        rig.feed(ones)
        rig.source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        rig.source.send(.resumed)
        #expect(await session.reaches(.running))
        rig.feed(ones)
        #expect(Array(sink.samples.suffix(64).prefix(6)) == [0, 0, 0, 0, 0, -1], "resumed: the delay line starts empty (CAP-8, ACT-10)")
        #expect(sink.times.last == 0 - 5.0 / 48_000 || sink.times.last == 0, "and the session's clock starts again")
        session.detach()
    }

    @Test func aDetachedSessionStopsRunningWhileItsSourceServesAnother() async throws {
        let rig = Rig()
        let gone = CollectingSink<Samples>(), kept = CollectingSink<Samples>()
        let first = try await rig.engine.attach(Pipeline().emit(to: gone), to: rig.source)
        let second = try await rig.engine.attach(Pipeline().emit(to: kept), to: rig.source)
        try first.start()
        try second.start()
        rig.feed(ones + ones)
        first.detach()
        #expect(first.state == .detached && gone.releases == 1 && !first.core.isScheduled)
        rig.feed(ones + ones)
        #expect(gone.samples.count == 128 && kept.samples.count == 256, "detached from running: its plan runs no more; the other attachment goes on")
        #expect(rig.source.stops == 0, "and the source keeps running for it")
        second.detach()
        #expect(rig.source.stops == 1)
    }

    @Test func aFinishedSessionJoinsASourceThatRunsAgain() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let a = CollectingSink<Samples>(), b = CollectingSink<Samples>()
        let first = try await engine.attach(Pipeline { TestGain(2) }.emit(to: a), to: source)
        let second = try await engine.attach(Pipeline { TestGain(3) }.emit(to: b), to: source)
        try first.start()
        try second.start()
        source.write(ones)
        #expect(await eventually { a.samples.count == 64 && b.samples.count == 64 })
        source.send(.ended)
        #expect(await first.reaches(.finished))
        #expect(await second.reaches(.finished))
        try first.start()
        #expect(await first.reaches(.running))
        #expect(second.state == .finished, "the other attachment stays finished: \(second.state)")
        try second.start()
        #expect(await second.reaches(.running))
        source.write(ones)
        #expect(await eventually { a.samples.count == 128 && b.samples.count == 128 }, "both receive the next block: \(a.samples.count), \(b.samples.count)")
        #expect(source.prepares == 2, "prepared once more for the restart, not once per session: \(source.prepares)")
        first.detach()
        second.detach()
    }

    @Test func aStartThatThrowsBehindAProcessedSourceLeavesTheSessionIdle() async throws {
        let engine = DSPEngine(blockSize: 64)
        let upstream = ManualPushSource(format: format, startError: .sourceUnavailable(reason: "no start"))
        let session = try await engine.attach(Pipeline { TestGain(3) }, to: upstream.processed(by: Pipeline { TestGain(2) }))
        #expect(throws: DSPError.sourceUnavailable(reason: "no start")) { try session.start() }
        #expect(session.state == .idle, "a start() that throws leaves the session idle: \(session.state)")
        #expect(throws: DSPError.self) { try session.start() }
        session.detach()
        #expect(session.state == .detached)
    }

    @Test func aSourceThatReportsAFormatThatIsNotOneFailsAndComesBack() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestGain(2) }.emit(to: sink), to: source)
        try session.start()
        source.write(ones)
        #expect(await eventually { sink.samples.count == 64 })
        source.changeFormat(to: SignalFormat(sampleRate: 0))
        #expect(await eventually { if case .failed = session.state { true } else { false } }, "a format that is not valid fails the session: \(session.state)")
        source.changeFormat(to: SignalFormat(sampleRate: 44_100))
        try? await Task.sleep(nanoseconds: 20_000_000)
        try session.start()
        #expect(await session.reaches(.running), "start() from failed: prepared again, then running")
        #expect(await eventually { session.environment.sampleRate == 44_100 })
        source.write(ones)
        #expect(await eventually { sink.samples.count == 128 })
        session.detach()
    }

    // MARK: Sinks across an update that is refused (ATT-5)

    @Test func aRefusedUpdateLeavesTheRunningPlanAsItIs() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let keep = CollectingSink<Samples>(), good = CollectingSink<Samples>()

        // At attach: what was claimed before the refusal is given back.
        await #expect(throws: DSPError.self) { _ = try await engine.attach(Pipeline { Emit(to: good); Emit(to: RefusingSink()) }, to: source) }
        #expect(good.claims == 1 && good.releases == 1 && !SinkRegistry.isClaimed(ObjectIdentifier(good)))

        let session = try await engine.attach(Pipeline { Emit(to: keep); TestGain(2); Emit(to: good) }, to: source)
        try session.start()
        source.write(ones)
        #expect(await eventually { good.samples.count == 64 && keep.samples.count == 64 })

        // The refusing sink stands before the sink that moves, and after it.
        let refused: [Pipeline<Samples, Samples>] = [
            Pipeline { Emit(to: keep); TestGain(2); Emit(to: good); Emit(to: RefusingSink()) },
            Pipeline { Emit(to: keep); TestGain(3); Emit(to: RefusingSink()); TestDelay(1); Emit(to: good) },
            Pipeline { Emit(to: keep); TestGain(3); TestDelay(1); Emit(to: good); Emit(to: RefusingSink()) },
        ]
        var expected = 64
        for (index, pipeline) in refused.enumerated() {
            await #expect(throws: DSPError.self) { try await session.update(pipeline) }
            #expect(session.state == .running && session.core.runner.installedGeneration == 1, "refusal \(index): the running plan stays")
            #expect(SinkRegistry.isClaimed(ObjectIdentifier(good)), "refusal \(index): the running plan keeps its sink")
            source.write(ones)
            expected += 64
            let wanted = expected
            #expect(await eventually { good.samples.count == wanted && keep.samples.count == wanted },
                    "refusal \(index): both sinks of the running plan go on: \(keep.samples.count), \(good.samples.count) of \(wanted)")
            #expect(good.samples.suffix(64) == [Float](repeating: 2, count: 64))
        }

        // A valid update afterwards goes through.
        try await session.update(Pipeline { Emit(to: keep); TestGain(5); TestDelay(1); Emit(to: good) })
        // A sink that moves receives nothing until the new plan has taken over (CR-015, item 4).
        let held = expected
        var blocks = 0
        while blocks < 20, good.samples.count == held {
            source.write(ones)
            blocks += 1
            _ = await eventually(timeout: 0.2) { good.samples.count > held }
        }
        #expect(good.samples.count > held, "the valid update takes over within a few blocks")
        #expect(Array(good.samples.suffix(3)) == [-5, -5, -5], "and the sink hears the new plan (the test delay inverts)")
        session.detach()
        #expect(!SinkRegistry.isClaimed(ObjectIdentifier(good)) && !SinkRegistry.isClaimed(ObjectIdentifier(keep)))
    }

    // MARK: Several attachments on one source (ATT-6)

    @Test func attachmentsOnOneSourceSeeIdenticalBlocks() async throws {
        let rig = Rig()
        let a = CollectingSink<Samples>(), b = CollectingSink<Samples>(), c = CollectingSink<Samples>()
        let first = try await rig.engine.attach(Pipeline().emit(to: a), to: rig.source)
        let second = try await rig.engine.attach(Pipeline().emit(to: b), to: rig.source)
        let third = try await rig.engine.attach(Pipeline { TestGain(2) }.emit(to: c), to: rig.source)
        try first.start()
        try second.start()
        try third.start()
        rig.feed(noise)
        #expect(a.samples == noise && b.samples == noise && c.samples == noise.map { $0 * 2 }, "every attachment sees the same blocks")
        #expect(a.times == b.times && a.indices == b.indices && a.times == c.times, "at the same times")
        #expect(a.frameCount == 40, "block for block")
        #expect(rig.source.starts == 1 && rig.source.prepares == 1)
        // A late attachment joins at a block boundary and sees what follows.
        let d = CollectingSink<Samples>()
        let late = try await rig.engine.attach(Pipeline().emit(to: d), to: rig.source)
        try late.start()
        rig.feed(Array(noise[..<640]))
        #expect(d.samples == Array(noise[..<640]) && a.samples.count == noise.count + 640)
        #expect(d.times.first == 0, "its own clock starts with its first block")
        for session in [first, second, third, late] { session.detach() }
    }

    @Test func servingSeveralSessionsAllocatesNothing() async throws {
        let rig = Rig()
        let s1 = try await rig.engine.attach(Pipeline { TestGain(2) }.emit(to: CountingSink<Samples>()), to: rig.source)
        let s2 = try await rig.engine.attach(Pipeline { TestBiquad(count: 2) }.emit(to: CountingSink<Samples>()), to: rig.source)
        let s3 = try await rig.engine.attach(Pipeline().emit(to: CountingSink<Samples>()), to: rig.source.processed(by: Pipeline { TestGain(0.5) }))
        try s1.start()
        try s2.start()
        try s3.start()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [Array(noise[..<64])])
        rig.source.write(block.block())
        _ = runner.turn(now: 0)
        expectNoAllocations {
            var count = 0
            while count < 1_000 {
                rig.source.write(block.block())
                _ = runner.turn(now: 0)
                count += 1
            }
        }
        for session in [s1, s2, s3] { session.detach() }
    }

    // MARK: The polling period (§4.3)

    @Test(arguments: [(512, 48_000.0), (64, 48_000.0), (16, 192_000.0), (4_096, 44_100.0)])
    func theEnginePollsAtHalfABlockAndNeverUnderAMillisecond(blockSize: Int, sampleRate: Double) async throws {
        // Through the engine's own computation of the interval, with a clock that records
        // what the analysis thread asks of it.
        let clock = SleepLog()
        let core = EngineCore(blockSize: blockSize, crossovers: .shipped, clock: clock)
        let source = ManualPushSource(format: SignalFormat(sampleRate: sampleRate))
        let session = try await core.attach(Pipeline().stages, to: source)
        try core.start(session)
        #expect(await eventually(timeout: 20) { clock.sleeps.get().count >= 12 })
        core.stop(session)
        core.detach(session)
        let sleeps = Array(clock.sleeps.get().dropFirst(2).prefix(8))
        let expected = max(0.001, Double(blockSize) / sampleRate / 2)
        // Each sleep ends at the next wake-up: what is asked for is the period less the turn's own time.
        #expect(!sleeps.isEmpty && sleeps.allSatisfy { $0 <= expected + 1e-6 }, "no sleep is longer than half a block: \(sleeps) against \(expected)")
        #expect(sleeps.contains { $0 > expected * 0.5 }, "and the period is half a block, not a fraction of it: \(sleeps) against \(expected)")
        #expect(expected >= 0.001)
    }

    // MARK: Stages written outside the core (EXT-1, §5.11.1)

    @Test func aBoundSwitchWorksOnAProcessorAndOnACKernelWithNoCodeInTheStage() async throws {
        for kind in ["processor", "kernel"] {
            let rig = Rig()
            let on = StateBox(true)
            let counter = CallCounter()
            let pipeline: Pipeline<Samples, Samples> = kind == "processor"
                ? Pipeline { CountedDelay(counter, delay: 37, isActive: on.binding) }
                : Pipeline { KernelDelay(37, isActive: on.binding) }
            let session = try await rig.engine.attach(pipeline, to: rig.source)
            let probe = OutputProbe()
            rig.engine.core.addProbe(probe, to: session.core)
            try session.start()
            #expect(session.environment.latency == 37.0 / 48_000, "\(kind): latency is accounted for")
            let signal = TestSignal.whiteNoise(count: 64 * 120, seed: 9)
            func calls() -> Int { kind == "processor" ? counter.blocks : kernelDelayCalls }
            rig.feed(Array(signal[..<(64 * 30)]))
            let whileOn = calls()
            on.value = false
            await session.syncBindings()
            rig.feed(Array(signal[(64 * 30) ..< (64 * 60)]))
            let afterFade = calls()
            rig.feed(Array(signal[(64 * 60) ..< (64 * 70)]))
            let whileOff = calls()
            on.value = true
            await session.syncBindings()
            rig.feed(Array(signal[(64 * 70)...]))
            let expected = [Float](repeating: 0, count: 37) + signal.dropLast(37)
            #expect(probe.samples == expected, "\(kind): a pure delay under a switch is the delayed signal throughout (ACT-8)")
            #expect(whileOff == afterFade && afterFade < whileOn + 12, "\(kind): switched off, the stage does no work: \(whileOn), \(afterFade), \(whileOff)")
            #expect(calls() > whileOff && session.core.generation == 1, "\(kind): switched on again, it runs; nothing was compiled")
            session.detach()
        }
    }

    @Test func aStageWhoseDescriptionAndObjectDisagreeAboutItsLatencyIsRefused() throws {
        // REAL-5: the environment downstream is computed from the description; a processor
        // that delays by another amount would stamp everything behind it with the wrong time.
        struct Liar: SequenceStage {
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                context.emit(.processor(CustomProcessor(name: "Liar", key: self, latencyFrames: 0) { _ throws(DSPError) -> any SampleProcessor in
                    CountedDelayProcessor(counter: CallCounter(), delay: 5)
                }))
            }
        }
        #expect(throws: DSPError.self) { try Pipeline { Liar() }.process(ones, format: format) }
        do {
            _ = try Pipeline { TestGain(2); Liar() }.process(ones, format: format)
        } catch {
            #expect("\(error)".contains("Liar") && "\(error)".contains("5"), "the error names the stage and the two figures: \(error)")
        }
    }

    // MARK: Streams and the pump

    @Test func aSecondConsumerOfAStreamDoesNotSpinBesideTheFirst() async throws {
        let stream = FeatureStream<Scalar>()
        try stream.claim(axis: nil, environment: DSPEnvironment(), domain: .scalar, format: .scalar)
        let received = Locked<[Float]>([])
        let first = Task.detached {
            for await frame in stream { received.withLock { $0.append(frame.scalar.value) } }
        }
        // Let the first consumer start to wait.
        try await Task.sleep(nanoseconds: 30_000_000)
        let secondEnded = Locked(false)
        let second = Task.detached {
            for await _ in stream {}
            secondEnded.set(true)
        }
        #expect(await eventually(timeout: 2) { secondEnded.get() }, "the second consumer is told there is nothing for it")
        stream.write(FrameView(scalar: ScalarFrame(value: 3), index: 0, time: 0))
        stream.service()
        #expect(await eventually(timeout: 2) { received.get() == [3] }, "the first consumer still gets the frames: \(received.get())")
        stream.finish()
        await first.value
        await second.value
    }

    @Test func thePumpRestsWhileItsSessionIsInterrupted() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: on.binding) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        await rig.drain()
        let pump = session.core.pump
        #expect(await MainActor.run { pump.isObserving })
        rig.source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        await rig.drain()
        #expect(await MainActor.run { !pump.isObserving }, "no observer on the run loop while the session is interrupted (BIND-2)")
        on.value = false                                             // written while nobody reads
        rig.source.send(.resumed)
        #expect(await session.reaches(.running))
        await rig.drain()
        #expect(await MainActor.run { pump.isObserving })
        await session.syncBindings()
        rig.feed([Float](repeating: 1, count: 64 * 20))
        #expect(probe.samples.last == 1, "the switch that moved during the interruption is seen once the session runs again")
        session.detach()
    }

    // MARK: Generators (WP-316)

    private func render(_ source: GeneratorSource, frames: Int, into fill: Float = 0) async throws -> [[Float]] {
        try await source.prepare()
        let channels = source.format.channelCount
        let buffer = try AudioBuffer(channels: [[Float]](repeating: [Float](repeating: fill, count: frames), count: channels))
        var block = buffer.block(frameCount: 0)
        let produced = source.render(into: &block)
        return (0 ..< channels).map { buffer.array(ofChannel: $0, frameCount: produced) }
    }

    @Test func silenceOverwritesWhatTheBlockHeld() async throws {
        let rendered = try await render(GeneratorSource(.silence, channelCount: 2, duration: 0.01), frames: 64, into: 7)
        #expect(rendered == [[Float](repeating: 0, count: 64), [Float](repeating: 0, count: 64)])
    }

    @Test func chirpsFollowTheirFormulasThroughAndPastTheirEnd() async throws {
        let rate = 48_000.0, f0 = 200.0, f1 = 3_200.0, length = 0.5
        let frames = [0, 1, 100, 5_000, 12_000, 23_999, 24_000, 24_001, 30_000, 47_999]

        // Logarithmic: amplitude · sin(2π f₀ T / ln r · (r^(t/T) − 1)); after T, a sine at f₁ with unbroken phase.
        let ratio = f1 / f0
        let logarithmic = try await render(
            GeneratorSource(.logarithmicChirp(from: .hertz(f0), to: .hertz(f1), duration: length, amplitude: 0.5), sampleRate: rate, duration: 1), frames: 48_000)[0]
        #expect(logarithmic.count == 48_000)
        var worst = 0.0
        for n in frames {
            let t = Double(n) / rate
            let phase = t < length
                ? 2 * Double.pi * f0 * length / log(ratio) * (pow(ratio, t / length) - 1)
                : 2 * Double.pi * f0 * length / log(ratio) * (ratio - 1) + 2 * .pi * f1 * (t - length)
            worst = max(worst, abs(Double(logarithmic[n]) - 0.5 * sin(phase)))
        }
        #expect(worst < 1e-5, "logarithmic chirp at amplitude 0.5: largest error \(worst)")

        // Linear: amplitude · sin(2π (f₀ t + (f₁ − f₀) t² / 2T)); after T, a sine at f₁ with unbroken phase.
        let linear = try await render(
            GeneratorSource(.chirp(from: .hertz(f0), to: .hertz(f1), duration: length, amplitude: 0.25), sampleRate: rate, duration: 1), frames: 48_000)[0]
        worst = 0
        for n in frames {
            let t = Double(n) / rate
            let phase = t < length
                ? 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * length))
                : 2 * Double.pi * (f0 * length + (f1 - f0) * length / 2) + 2 * .pi * f1 * (t - length)
            worst = max(worst, abs(Double(linear[n]) - 0.25 * sin(phase)))
        }
        #expect(worst < 1e-5, "linear chirp at amplitude 0.25: largest error \(worst)")
    }

    @Test func pinkNoiseIsSeededScaledAndStartsOverWhenPreparedAgain() async throws {
        let pink = GeneratorSource(.pinkNoise(amplitude: 0.5, seed: 4), duration: 0.01)
        let once = try await render(pink, frames: 480)[0], twice = try await render(pink, frames: 480)[0]
        let otherSeed = try await render(GeneratorSource(.pinkNoise(amplitude: 0.5, seed: 5), duration: 0.01), frames: 480)[0]
        let fullScale = try await render(GeneratorSource(.pinkNoise(amplitude: 1, seed: 4), duration: 0.01), frames: 480)[0]
        #expect(once.count == 480 && once == twice, "prepared again, the same noise from its first sample")
        #expect(once != otherSeed, "another seed, another noise")
        #expect(once == fullScale.map { $0 * 0.5 }, "the amplitude scales it")
    }

    // MARK: The writing end of a ring (WP-315)

    @Test func aRingWriterTakesChannelsInterleavedSamplesAndBlocks() throws {
        let ring = try SampleRing(channelCount: 2, capacity: 256)
        let writer = RingWriter(ring)
        #expect(writer.channelCount == 2 && writer.capacity >= 256 && writer.availableSpace == writer.capacity && writer.droppedFrames == 0)
        let interleaved = (0 ..< 20).map { Float($0) }
        #expect(interleaved.withUnsafeBufferPointer { writer.write(interleaved: $0.baseAddress!, frameCount: 10) } == 10)
        let block = try AudioBuffer(channels: [[1, 2, 3], [4, 5, 6]])
        #expect(writer.writeWaiting(block.block()) == 3 && writer.availableSpace == writer.capacity - 13)
        let out = try AudioBuffer(channelCount: 2, capacity: 13)
        #expect(Int(ztd_ring_read(writer.ring, out.block().channelTable, 13)) == 13)
        #expect(out.array(ofChannel: 0) == [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 1, 2, 3])
        #expect(out.array(ofChannel: 1) == [1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 4, 5, 6])
        // A writer that does not wait drops what does not fit and says how much.
        let full = try AudioBuffer(channels: [[Float](repeating: 1, count: writer.capacity + 40), [Float](repeating: 1, count: writer.capacity + 40)])
        #expect(writer.write(full.block()) == writer.capacity && writer.availableSpace == 0)
        #expect(writer.droppedFrames == 40, "\(writer.droppedFrames) frames dropped")
    }
}
