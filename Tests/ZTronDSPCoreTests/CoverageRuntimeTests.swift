import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// An object that counts how many of its kind are alive.
private final class CoverageToken {
    private let alive: Locked<Int>

    init(_ alive: Locked<Int>) {
        self.alive = alive
        alive.withLock { $0 += 1 }
    }

    deinit {
        alive.withLock { $0 -= 1 }
    }
}

/// The hand-over between the control context and the analysis side, result slots, streams and
/// sources where the suites of M3 left lines unrun (COV-3).
@Suite("Hand-over, slots, streams and sources (COV-3)")
struct CoverageRuntimeTests {
    let format = SignalFormat(sampleRate: 48_000)

    // MARK: Handoff (RT-3, RT-4)

    /// RT-3: "All memory a plan needs is … freed when it is retired, off the analysis thread".
    /// The consumer of a hand-over never releases what it replaces: it puts it on a bounded
    /// retire list. When the list is full the surplus is kept aside, and no new value is taken
    /// until the control context has drained the list: nothing is freed on the consumer's side,
    /// nothing is lost, and nothing grows.
    @Test func aFullRetireListHoldsTheConsumerBackUntilItIsDrained() throws {
        let alive = Locked(0)
        let slot = try Handoff<CoverageToken>(retireCapacity: 2)
        func publish() -> ObjectIdentifier {
            let token = CoverageToken(alive)
            slot.publish(token)
            return ObjectIdentifier(token)
        }
        func installed() -> ObjectIdentifier? { slot.installed.map { ObjectIdentifier($0) } }

        #expect(slot.refresh() == nil && !slot.hasPending, "nothing was published yet")
        let first = publish()
        #expect(slot.hasPending && installed() == nil)
        #expect(slot.refresh().map { ObjectIdentifier($0) } == first && !slot.hasPending)

        // Three more: the first two replaced values fill the list of two, the third is kept aside.
        _ = publish()
        slot.refresh()
        _ = publish()
        slot.refresh()
        let fourth = publish()
        slot.refresh()
        #expect(installed() == fourth && alive.get() == 4, "four exchanges, and nothing was freed by the consumer")

        // A fifth is published, and the consumer cannot take it: it has nowhere to put the fourth.
        let fifth = publish()
        #expect(slot.refresh().map { ObjectIdentifier($0) } == fourth && slot.hasPending, "the installed value goes on running")
        #expect(slot.take() == nil && alive.get() == 5)

        // The control context drains the list: two values are freed there, and the consumer moves on.
        slot.drainRetired()
        #expect(alive.get() == 3, "the two on the list were released by the control context")
        #expect(slot.refresh().map { ObjectIdentifier($0) } == fifth && !slot.hasPending)
        slot.drainRetired()
        #expect(alive.get() == 1, "what was kept aside went onto the list, and was released from it")

        // A pending value the consumer never took is taken back by the control context, or
        // replaced by a newer one (the latest wins), or taken and discarded: each is released once.
        let sixth = publish()
        let withdrawn = slot.withdraw().map { ObjectIdentifier($0) }
        #expect(withdrawn == sixth && slot.withdraw() == nil && !slot.hasPending)
        #expect(alive.get() == 1, "withdrawn and let go")
        _ = publish()
        let eighth = publish()
        #expect(alive.get() == 2, "a pending value that is replaced never ran and is released at once")
        let discarded: ObjectIdentifier? = {
            guard let taken = slot.take() else { return nil }
            slot.discard(taken)
            return ObjectIdentifier(taken)
        }()
        #expect(discarded == eighth && installed() == fifth, "taken and discarded, never installed")
        #expect(alive.get() == 2, "a discarded value waits on the retire list like a replaced one")
        slot.drainRetired()
        #expect(alive.get() == 1, "and is released from it")
    }

    /// The same, to the end: a hand-over that goes away releases the installed value, the
    /// pending one, the one kept aside and those on the retire list, each exactly once.
    @Test func aHandOverThatGoesAwayReleasesEverythingItHolds() throws {
        let alive = Locked(0)
        do {
            let slot = try Handoff<CoverageToken>(retireCapacity: 2)
            // Four exchanges fill the retire list and leave one value aside; a fifth value stays pending.
            var round = 0
            while round < 4 {
                slot.publish(CoverageToken(alive))
                slot.refresh()
                round += 1
            }
            slot.publish(CoverageToken(alive))
            #expect(alive.get() == 5 && slot.hasPending)
        }
        #expect(alive.get() == 0, "installed, pending, kept aside and retired: all released")
    }

    /// §4.3: the control context may wait for the analysis side, never the other way round.
    /// `ControlWait.until` says whether the condition came to hold: at once, at a later look, or
    /// not at all before its time was up, in which case it has looked one last time.
    @Test func aControlWaitSaysWhetherItsConditionCameToHold() {
        var looks = 0
        let never = ControlWait.until(timeout: 0.01) {
            looks += 1
            return false
        }
        #expect(!never && looks >= 2, "it looked before it waited and after its time was up: \(looks) looks")

        looks = 0
        let atOnce = ControlWait.until(timeout: 60) {
            looks += 1
            return true
        }
        #expect(atOnce && looks == 1, "a condition that holds costs one look and no sleep")

        looks = 0
        let later = ControlWait.until(timeout: 60) {
            looks += 1
            return looks == 3
        }
        #expect(later && looks == 3)

        // With no time at all there are exactly two looks, before the wait and at its end, and
        // the one at the end counts: a condition that holds only then is one that came to hold.
        var held = 0, missed = 0
        var round = 0
        while round < 100 {
            looks = 0
            if ControlWait.until(timeout: 0, {
                looks += 1
                return looks == 2
            }) { held += 1 }
            if looks != 2 { missed += 1 }
            looks = 0
            if ControlWait.until(timeout: 0, {
                looks += 1
                return false
            }) || looks != 2 { missed += 1 }
            round += 1
        }
        #expect(held == 100 && missed == 0, "the last look decides: \(held) of 100 held, \(missed) went wrong")
    }

    // MARK: Result slots (OUT-2)

    /// OUT-2: "The analysis thread writes each result into a pre-allocated latest-value slot".
    /// A slot for one value keeps value and confidence of the newest scalar frame; a slot for a
    /// vector keeps the newest real frame, cut to the size it was prepared for; either ignores
    /// a frame of the other kind, and a slot that was never written has nothing to deliver.
    @Test func aResultSlotKeepsTheNewestFrameOfItsKind() throws {
        let value = try ResultSlot(kind: .value)
        #expect(value.writes == 0 && value.readVector() == nil)
        value.write(FrameView(scalar: ScalarFrame(value: 3, confidence: 0.5), index: 0, time: 0))
        value.write(FrameView(scalar: ScalarFrame(value: -7.25, confidence: 0.125), index: 1, time: 0))
        #expect(value.readScalar() == ScalarFrame(value: -7.25, confidence: 0.125) && value.writes == 2)
        let numbers: [Float] = [1, 2, 3, 4, 5]
        numbers.withUnsafeBufferPointer { value.write(FrameView(real: $0, index: 2, time: 0)) }
        #expect(value.writes == 2 && value.readVector() == nil, "a vector is not a value")

        let vector = try ResultSlot(kind: .vector)
        #expect(vector.readVector() == nil, "not prepared: no storage")
        try vector.claim(axis: nil, environment: DSPEnvironment(), domain: .chroma, format: .real(count: 3))
        #expect(vector.readVector() == nil && vector.writes == 0, "prepared and not written: nothing to deliver")
        numbers.withUnsafeBufferPointer { vector.write(FrameView(real: $0, index: 0, time: 0)) }
        #expect(vector.readVector() == [1, 2, 3] && vector.writes == 2, "cut to what it was prepared for; an even count: the write is complete")
        vector.write(FrameView(scalar: ScalarFrame(value: 9), index: 1, time: 0))
        #expect(vector.readVector() == [1, 2, 3] && vector.writes == 2, "a value is not a vector")
        let short: [Float] = [8]
        short.withUnsafeBufferPointer { vector.write(FrameView(real: $0, index: 2, time: 0)) }
        #expect(vector.readVector() == [8], "a shorter frame is delivered as it came")

        // Prepared for frames that are not real vectors, a vector slot takes the rows of the axis.
        let chroma = try ResultSlot(kind: .vector)
        try chroma.claim(axis: .pitchClasses, environment: DSPEnvironment(), domain: .chroma, format: .scalar)
        let twenty = [Float](repeating: 0.5, count: 20)
        twenty.withUnsafeBufferPointer { chroma.write(FrameView(real: $0, index: 0, time: 0)) }
        #expect(chroma.readVector() == [Float](repeating: 0.5, count: 12))
        vector.release()
    }

    // MARK: FeatureStream as a sink of its own (§5.11.1)

    /// §5.11.1: `FeatureSink` is the public contract of a sink: `claim`, `write`, `release`.
    /// Driven through it alone, as a harness outside the package would, a stream of one value
    /// per frame and a stream of real vectors are prepared for the frames of their domain, keep
    /// the newest `capacity` of them, count the rest as dropped, and end when they are finished.
    @Test func aStreamDrivenThroughThePublicSinkContractKeepsTheNewestFrames() async throws {
        let values = FeatureStream<Scalar>(capacity: 4)
        try values.claim(axis: nil, environment: DSPEnvironment())
        for index in 0 ..< 6 { values.write(FrameView(scalar: ScalarFrame(value: Float(index), confidence: 0.5), index: index, time: Double(index) / 10)) }
        #expect(values.droppedFrames == 2, "six frames into room for four")
        var iterator = values.makeAsyncIterator()
        var received: [FeatureFrame] = []
        for _ in 0 ..< 4 {
            if let frame = await iterator.next() { received.append(frame) }
        }
        let scalars = received.map { $0.scalar }, indices = received.map { $0.index }, times = received.map { $0.time }
        #expect(scalars == [2, 3, 4, 5].map { ScalarFrame(value: $0, confidence: 0.5) } && indices == [2, 3, 4, 5] && times == [0.2, 0.3, 0.4, 0.5])
        #expect(received.allSatisfy { $0.kind == .scalar })
        values.release()
        values.finish()
        let end = await iterator.next()
        #expect(end == nil, "finished and empty: the sequence ends")

        // A domain of real vectors: the frames have as many values as the axis has rows.
        let chroma = FeatureStream<Chroma>(capacity: 2)
        try chroma.claim(axis: .pitchClasses, environment: DSPEnvironment())
        let column = (0 ..< 20).map { Float($0) }
        column.withUnsafeBufferPointer { chroma.write(FrameView(real: $0, index: 0, time: 0)) }
        chroma.finish()
        var frames: [FeatureFrame] = []
        for await frame in chroma { frames.append(frame) }
        let first = frames.first?.values ?? []
        #expect(frames.count == 1 && first == Array(column[..<12]) && frames.allSatisfy { $0.kind == .real }, "twelve pitch classes: twelve values")
    }

    // MARK: Sources (§4.4, SRC-2)

    /// §4.4, §9.3: a push source is handed its ring when it is adapted. When the adapter's
    /// counters or the ring cannot be had, the adapter is not made, the error says what was
    /// asked for, and the source is not connected to anything; with memory to be had, the same
    /// call succeeds.
    @Test func aPushSourceWhoseRingCannotBeHadIsNotConnected() throws {
        let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        // The adapter asks for its two counters first; the ring then asks twice before it asks
        // for its storage: for itself, and for its table of channels.
        for request in 0 ..< 4 {
            var failure: DSPError?
            let asked = try CoverageAllocationSeam.refusing(request) {
                do throws(DSPError) {
                    _ = try SourceAdapter.make(for: source, blockSize: 64)
                } catch {
                    failure = error
                }
            }
            #expect(asked, "request \(request) was made")
            let expected = DSPError.resourceAllocationFailed(what: request < 2 ? "the counters of a source" : "a ring of 2 channels of 24000 frames")
            #expect(failure == expected, "request \(request) refused: \(String(describing: failure))")
        }
        #expect(source.connects == 0, "a source is connected to a ring that exists, or not at all")

        let adapter = try SourceAdapter.make(for: source, blockSize: 64)
        #expect(source.connects == 1 && adapter.kind == .push && adapter.pacing == .realTime && adapter.format == source.format)
        #expect(adapter.droppedFrames == 0 && adapter.nonFiniteCount == 0)
    }

    /// §4.4, ATT-2: "A source is one of two kinds", and the adapter is the one place that tells
    /// them apart. A source that adopts neither protocol is refused by name, every time it is
    /// offered, and never connected or asked for a sample; the same adapter serves a pull
    /// source without a ring.
    @Test func aSourceThatAdoptsNeitherKindIsRefusedByName() throws {
        let neither = CoverageNeitherSource()
        let expected = DSPError.unsupportedConfiguration(
            reason: "CoverageNeitherSource is neither a PushSampleSource nor a PullSampleSource; a source adopts one of the two")
        var round = 0
        while round < 64 {
            #expect(throws: expected) { _ = try SourceAdapter.make(for: neither, blockSize: 64) }
            round += 1
        }
        let pull = try SourceAdapter.make(for: BufferSource([1, 2, 3], sampleRate: 48_000), blockSize: 64)
        #expect(pull.kind == .pull && pull.pacing == .asFastAsPossible && pull.droppedFrames == 0)
    }

    /// SRC-2: a processed source can be prepared by itself: it prepares its upstream source and
    /// takes the format of its pipeline's output. Its own `start()` and `stop()` do nothing,
    /// because the engine starts and stops the upstream source with the attachments (ATT-6).
    @Test func aProcessedSourcePreparedByItselfResolvesItsFormatAndStartsNothing() async throws {
        let upstream = ManualPushSource(format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        let processed = upstream.processed(by: Pipeline { TestSubsample(by: 2) })
        #expect(processed.upstream === upstream && processed.format == upstream.format, "before it is prepared: the upstream format")
        try await processed.prepare()
        #expect(processed.format == SignalFormat(sampleRate: 24_000, channelCount: 2) && upstream.prepares == 1)
        try processed.start()
        processed.stop()
        #expect(upstream.starts == 0 && upstream.stops == 0 && upstream.connects == 0, "neither started nor stopped nor connected by it")

        // An upstream source without a format after it was prepared has nothing to process.
        let silent = ManualPushSource(format: SignalFormat(sampleRate: 0))
        let nothing = silent.processed(by: Pipeline())
        await #expect(throws: DSPError.sourceUnavailable(reason: "the upstream source reports the format \(silent.format) after it was prepared")) {
            try await nothing.prepare()
        }
        #expect(silent.prepares == 1 && nothing.format == silent.format)
        // And a pipeline that is not valid at the upstream format is refused with its stage (ORD-6).
        let refused = upstream.processed(by: Pipeline { TestGain(.nan) })
        await #expect(throws: DSPError.self) { try await refused.prepare() }
    }

    // MARK: Plans no machine can hold (RT-3, §9.3)

    /// §9.3, RT-3: every buffer of a plan is allocated when the plan is compiled, and a size the
    /// machine cannot hold "is an allocation that failed, not a trap". Scratch for 65 536
    /// channels of 2³¹ frames is 2⁴⁹ bytes: the plan is refused with a typed error.
    @Test func aPlanWhoseScratchNoMachineCanHoldIsATypedError() throws {
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 65_536, blockSize: 1 << 31)
        let lowered = try PlanCompiler(crossovers: .shipped).lower(Pipeline { TestGain(2) }.stages, environment: environment, blockSize: 1 << 31)
        #expect(throws: DSPError.resourceAllocationFailed(what: "a plan of 1 kernels")) {
            _ = try ExecutionPlan(lowered: lowered, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
        }
    }

    /// ACT-8, §9.3: a bound switch on a stage with latency needs a delay line of that latency
    /// per channel for the unprocessed path. A stage that declares 2³¹ frames of delay on 65 536
    /// channels asks for one no machine can hold: the plan is refused with a typed error, and
    /// what was made for it is freed. The same stage without a switch needs no such line.
    @Test func aSwitchWhoseDelayLineNoMachineCanHoldIsATypedError() throws {
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 65_536, blockSize: 16)
        let compiler = PlanCompiler(crossovers: .shipped)
        let bound = try compiler.lower(Pipeline { CoverageEndlessDelay(isActive: StateBox(true).binding) }.stages, environment: environment, blockSize: 16)
        #expect(bound.switches.count == 1)
        #expect(throws: DSPError.resourceAllocationFailed(what: "a switch")) {
            _ = try ExecutionPlan(lowered: bound, switchValues: [true], crossovers: .shipped, generation: 1, previous: nil)
        }
        let plain = try compiler.lower(Pipeline { CoverageEndlessDelay() }.stages, environment: environment, blockSize: 16)
        let plan = try ExecutionPlan(lowered: plain, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
        #expect(plan.kernelTargets.count == 1 && plan.switchTargets.isEmpty, "without a switch there is no unprocessed path to keep")
    }

    /// ACT-6, RT-3: a switched group of kernels is made whole or not at all. When one of its
    /// stages cannot make its kernel, the error names that stage, and the kernel that was made
    /// before it is freed with the plan it was made for.
    @Test func aGroupThatCannotBeMadeFreesWhatWasMadeForIt() throws {
        let witness = CoverageWitness()
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 2, blockSize: 64)
        // The channel gains name one channel too few: their kernel is refused after the witness was made.
        let pipeline = Pipeline {
            ZTronDSPCore.Group(isActive: StateBox(true).binding) { witness; TestChannelGains(factors: [2]) }
        }
        let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: 64)
        let isGroup = lowered.steps.count == 1 && lowered.steps[0].isKernelRegion
        #expect(isGroup, "one switched group of two kernels")

        var failure: DSPError?
        do throws(DSPError) {
            _ = try ExecutionPlan(lowered: lowered, switchValues: [true], crossovers: .shipped, generation: 1, previous: nil)
        } catch {
            failure = error
        }
        guard case .invalidParameter(let stage, let parameter, _)? = failure else {
            Issue.record("the channel gains were to be refused: \(String(describing: failure))")
            return
        }
        #expect(parameter == "factors" && stage.description == "Group[0] › TestChannelGains[1]", "the error names the stage inside the group: \(stage)")
        #expect(witness.counts.made.get() == 1 && witness.counts.alive.get() == 0, "the processor of the first stage was made, and freed with the group")

        // With gains for both channels the group is made, and holds the processor until the plan goes.
        let valid = Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { witness; TestChannelGains(factors: [2, 3]) } }
        do {
            let plan = try ExecutionPlan(
                lowered: try PlanCompiler(crossovers: .shipped).lower(valid.stages, environment: environment, blockSize: 64),
                switchValues: [true], crossovers: .shipped, generation: 1, previous: nil)
            #expect(plan.kernelTargets.count == 2 && witness.counts.alive.get() == 1)
        }
        #expect(witness.counts.made.get() == 2 && witness.counts.alive.get() == 0, "freed with its plan")
    }
}

/// A source that adopts neither `PushSampleSource` nor `PullSampleSource`.
private final class CoverageNeitherSource: SampleSource, @unchecked Sendable {
    // Threading: no state of its own; the channel is a constant.
    private let channel = SourceEventChannel()
    var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
    var events: AsyncStream<SourceEvent> { channel.stream }
    func prepare() async throws(DSPError) {}
    func start() throws(DSPError) {}
    func stop() {}
}

/// How many processors of a `CoverageWitness` were made, and how many are alive.
private final class CoverageWitnessCounts: Sendable {
    let made = Locked(0)
    let alive = Locked(0)
}

/// A stage that does nothing but exist: its processor copies, and says when it is made and when
/// it is freed.
private struct CoverageWitness: SequenceStage {
    let counts = CoverageWitnessCounts()

    static func == (lhs: CoverageWitness, rhs: CoverageWitness) -> Bool { lhs.counts === rhs.counts }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(counts)) }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let counts = counts
        context.emit(.processor(CustomProcessor(name: "CoverageWitness", key: self) { _ throws(DSPError) -> any SampleProcessor in
            CoverageWitnessProcessor(counts)
        }))
    }
}

private final class CoverageWitnessProcessor: SampleProcessor {
    private let counts: CoverageWitnessCounts

    init(_ counts: CoverageWitnessCounts) {
        self.counts = counts
        counts.made.withLock { $0 += 1 }
        counts.alive.withLock { $0 += 1 }
    }

    deinit {
        counts.alive.withLock { $0 -= 1 }
    }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }
    func process(_ block: inout AudioBlock) {}
    func reset() {}
}
