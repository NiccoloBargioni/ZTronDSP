import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// What the engine's own objects do when the system refuses them memory (RT-3, §9.3): the
/// atomic cells, queues, plan slots, parkers and plans of the C layer ask the seam of
/// `ztd_internal.h` before every request, so a test can refuse each request in turn. Refused,
/// an initialiser throws a typed error and leaves nothing behind: what it had made up to then
/// is freed, the cells made before the one that was refused included.
@Suite("Creation that the system refuses, in the engine",
       .disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
struct EngineCreationFailureTests {
    let format = SignalFormat(sampleRate: 48_000)

    /// Makes something with each of its requests for memory refused in turn, and returns how
    /// many requests it makes. Refused, `make` must throw one of `errors` and free everything
    /// it allocated; with nothing refused it must succeed.
    private func refusals(_ name: String, _ errors: Set<String>, _ make: () throws(DSPError) -> Void) throws -> Int {
        var request = 0
        while request < 200 {
            // Once unmeasured, so that whatever the runtime sets up on first use is set up.
            var outcomes: [(failed: Bool, known: Bool, counts: AllocationCounts)] = []
            var asked = true
            var round = 0
            while round < 2 {
                var failed = false, known = false
                var counts = AllocationCounts(allocations: 0, deallocations: 0, bytes: 0)
                asked = try CoverageAllocationSeam.refusing(request) {
                    counts = (try? countAllocations {
                        do throws(DSPError) {
                            try make()
                        } catch {
                            failed = true
                            if case .resourceAllocationFailed(let what, _) = error { known = errors.contains(what) }
                        }
                    }) ?? AllocationCounts(allocations: -1, deallocations: 0, bytes: 0)
                }
                outcomes.append((failed, known, counts))
                round += 1
            }
            guard let outcome = outcomes.last else { break }
            if !asked {
                #expect(!outcome.failed, "\(name): with nothing refused it is made")
                break
            }
            #expect(outcome.failed && outcome.known, "\(name), request \(request) refused: a typed error that says what could not be had")
            #expect(outcome.counts.allocations == outcome.counts.deallocations, "\(name), request \(request) refused: \(outcome.counts), so something was not freed")
            request += 1
        }
        return request
    }

    // MARK: Hand-overs, runners, threads

    /// A hand-over is one plan slot: the slot, and the list of what it retires.
    @Test func aHandOverThatCannotBeHadIsATypedError() throws {
        let requests = try refusals("a hand-over", ["a hand-over slot"]) { () throws(DSPError) in _ = try Handoff<ConsumerList>() }
        #expect(requests == 3, "the slot, its retire list, the list's storage: \(requests)")
    }

    /// The analysis-side half of a hub is a hand-over and one atomic word; that of a session
    /// two hand-overs, three words and two command queues; a thread a hand-over, a parker and
    /// four words. Whichever request is refused, the initialiser throws and leaks nothing: the
    /// cells and queues made before the refusal are freed.
    @Test func runnersAndThreadsThatCannotBeHadLeaveNothingBehind() throws {
        let attention = try #require(ztd_atomic_create(0))
        defer { ztd_atomic_destroy(attention) }

        let hub = try refusals("a hub's runner", ["a hand-over slot", "a source hub"]) { () throws(DSPError) in _ = try HubRunner(attention: attention) }
        #expect(hub == 4, "a hand-over and a cell: \(hub)")

        let session = try refusals("a session's runner", ["a hand-over slot", "the run-time half of a session"]) { () throws(DSPError) in
            _ = try SessionRunner(attention: attention)
        }
        #expect(session == 13, "two hand-overs, three cells, two queues of two requests each: \(session)")

        let thread = try refusals("an analysis thread", ["a hand-over slot", "an analysis thread"]) { () throws(DSPError) in
            _ = try RunnerThread(role: .analysis, clock: MachClock(), attention: attention, notify: {})
        }
        #expect(thread == 8, "a hand-over, a parker, four cells: \(thread)")

        let source = BufferSource([1, 2, 3], sampleRate: 48_000)
        let sourceHub = try refusals("a source hub", ["a hand-over slot", "a source hub"]) { () throws(DSPError) in
            _ = try SourceHub(source: source, attention: attention)
        }
        #expect(sourceHub == 4)
    }

    // MARK: Sources, slots, feeds

    /// The counters of a source adapter, of a result slot and of a feed's layout are made
    /// together: all of them, or none.
    @Test func countersThatCannotBeHadLeaveNothingBehind() throws {
        let pull = BufferSource([1, 2, 3], sampleRate: 48_000)
        let adapter = try refusals("a source adapter", ["the counters of a source"]) { () throws(DSPError) in _ = try SourceAdapter.make(for: pull, blockSize: 64) }
        #expect(adapter == 2, "ended, and replaced samples: \(adapter)")

        for kind in [BoundResult.Kind.value, .frame, .vector] {
            let slot = try refusals("a result slot", ["a result slot"]) { () throws(DSPError) in _ = try ResultSlot(kind: kind) }
            #expect(slot == 3, "the value, its version, its length: \(slot)")
        }

        let layout = try refusals("a feed's layout", ["the counters of a feed"]) { () throws(DSPError) in
            _ = try ColumnLayout(identifier: 1, rowCount: 8, capacity: 16, axis: nil, environment: nil, columnDuration: 0, inherits: false)
        }
        #expect(layout == 4, "started, completed, floor, epoch: \(layout)")
        // A history no machine holds is refused before a single counter is asked for.
        var asked = true
        var failure: DSPError?
        asked = try CoverageAllocationSeam.refusing(0) {
            do throws(DSPError) {
                _ = try ColumnLayout(identifier: 1, rowCount: 1 << 20, capacity: 1 << 20, axis: nil, environment: nil, columnDuration: 0, inherits: false)
            } catch {
                failure = error
            }
        }
        #expect(!asked && failure == .resourceAllocationFailed(what: "a feed of \(1 << 20) columns of \(1 << 20) values"))
    }

    /// A feed and a stream make their counters when they are created, where nothing can be
    /// thrown: one that could not have them is an object that refuses to be attached, with a
    /// typed error, and is empty for whoever reads it.
    @Test func aFeedOrAStreamWithoutItsCountersRefusesToBeAttached() throws {
        typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
        let signal = [Float](repeating: 1, count: 256)
        var request = 0
        while request < 5 {
            var made: HeatmapFeed?
            let asked = try CoverageAllocationSeam.refusing(request) { made = HeatmapFeed(history: 32) }
            let feed = try #require(made)
            #expect(asked, "a feed asks five times: its hand-over, its generation, its liveness")
            #expect(throws: DSPError.resourceAllocationFailed(what: "the counters of a feed")) {
                try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: feed).run(on: signal, format: format, blockSize: 64)
            }
            feed.setLive(true)
            var cursor = FeedCursor()
            var values = [Float](repeating: 0, count: 64)
            let read = values.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
            #expect(read.columnCount == 0 && feed.columnCount == 0 && feed.rowCount == 0 && feed.snapshot().columnCount == 0)
            if request == 3 { #expect(feed.generation == 0, "without its generation word it never moves") }
            if request == 4 { #expect(!feed.isLive, "without its liveness word it is never live") }
            request += 1
        }
        var whole: HeatmapFeed?
        let sixth = try CoverageAllocationSeam.refusing(5) { whole = HeatmapFeed(history: 32) }
        #expect(!sixth, "and no sixth time")
        try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: try #require(whole)).run(on: signal, format: format, blockSize: 64)
        #expect(whole?.columnCount == 4)

        request = 0
        while request < 2 {
            var made: FeatureStream<Magnitudes>?
            let asked = try CoverageAllocationSeam.refusing(request) { made = FeatureStream<Magnitudes>(capacity: 4) }
            let stream = try #require(made)
            #expect(asked, "a stream asks twice: frames begun, frames completed")
            #expect(throws: DSPError.resourceAllocationFailed(what: "the counters of a feature stream")) {
                try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: stream).run(on: signal, format: format, blockSize: 64)
            }
            #expect(stream.droppedFrames == 0)
            request += 1
        }
    }

    /// MEM-1: under critical memory pressure a feed gives up history, down to the minimum it
    /// declared. The smaller history has counters of its own; when they cannot be had the feed
    /// has nothing to give: it says so and keeps what it holds, whole, and gives when it can.
    @Test func aFeedThatCannotHaveASmallerHistoryKeepsTheOneItHas() async throws {
        let rig = Rig()
        let feed = HeatmapFeed(history: 16, minimumHistory: 4)
        let session = try await rig.engine.attach(Pipeline().tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: feed) }, to: rig.source)
        try session.start()
        rig.feed(TestSignal.whiteNoise(count: 64 * 12, seed: 99))
        let before = feed.snapshot()
        #expect(before.columnCount == 12 && feed.history == 16)

        var gave = true
        let asked = try CoverageAllocationSeam.refusing(0) { gave = feed.trimForMemoryPressure() }
        #expect(asked && !gave, "the counters of the smaller history were refused")
        let kept = feed.snapshot()
        #expect(feed.history == 16 && kept.columnCount == 12 && Array(kept.values) == Array(before.values), "nothing was given, and nothing lost")

        #expect(feed.trimForMemoryPressure() && feed.history == 4, "asked again, it gives")
        let after = feed.snapshot()
        #expect(after.columnCount == 4 && Array(after.values) == Array(before.values.suffix(33 * 4)), "down to the newest columns")
        session.detach()
    }

    // MARK: Plans

    /// RT-3: everything a plan needs is allocated when it is compiled; when something of it
    /// cannot be had the plan is not made, the error says what was missing, and what was made
    /// for it up to then is freed: the kernels, the C plans, the switches.
    @Test func aPlanThatCannotBeHadLeavesNothingBehind() throws {
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 2, blockSize: 64)
        let compiler = PlanCompiler(crossovers: .shipped)
        let on = StateBox(true)
        // A run of kernels with a switch on a kernel with latency, and a group of kernels behind it.
        let pipeline = Pipeline {
            TestGain(2)
            TestFIR([0.25, 0.5, 0.25], isActive: on.binding)
            TestBiquad(count: 2)
            ZTronDSPCore.Group(isActive: on.binding) { TestGain(3); TestFIR([0.5, 0.5]) }
        }
        let lowered = try compiler.lower(pipeline.stages, environment: environment, blockSize: 64)
        #expect(lowered.switches.count == 2 && lowered.skeleton.last?.isKernelRegion == true)
        let known: Set<String> = [
            "the kernel of TestGain", "the kernel of TestFIR", "the kernel of TestBiquad", "a plan of 4 kernels", "the plan of a group", "a switch",
        ]
        // Which of them were met, kept in place: the audit counts what the test itself allocates.
        let kinds = known.sorted()
        var met = [Bool](repeating: false, count: kinds.count)
        let requests = try refusals("a plan", known) { () throws(DSPError) in
            do throws(DSPError) {
                _ = try ExecutionPlan(lowered: lowered, switchValues: [true, true], crossovers: .shipped, generation: 1, previous: nil)
            } catch {
                if case .resourceAllocationFailed(let what, _) = error, let index = kinds.firstIndex(of: what) { met[index] = true }
                throw error
            }
        }
        #expect(requests > 30, "kernels, plans and switches: \(requests) requests, each refused once")
        let missed = zip(kinds, met).filter { !$0.1 }.map { $0.0 }
        #expect(missed.isEmpty, "every kind of refusal was met; not met: \(missed)")
    }

    /// An engine that could not have its attention word runs nothing, and says so with a
    /// typed error when a pipeline is attached to it.
    @Test func anEngineWithoutItsSignallingRefusesToAttach() async throws {
        var made: DSPEngine?
        let asked = try CoverageAllocationSeam.refusing(0) { made = DSPEngine(blockSize: 64, drivenByHand: true) }
        let engine = try #require(made)
        #expect(asked)
        let source = ManualPushSource(format: format)
        await #expect(throws: DSPError.resourceAllocationFailed(what: "the engine's signalling")) {
            _ = try await engine.attach(Pipeline { TestGain(2) }, to: source)
        }
        #expect(source.prepares == 0 && source.connects == 0, "refused before the source was touched")
        engine.core.runTurn()
        let elsewhere = try await DSPEngine(blockSize: 64, drivenByHand: true).attach(Pipeline(), to: source)
        #expect(elsewhere.state == .idle, "and the source is free for an engine that can run it")
        elsewhere.detach()
    }
}
