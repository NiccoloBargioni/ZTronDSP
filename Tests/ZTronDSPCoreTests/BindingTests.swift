import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Bound switches and bound results on a running session (WP-330b, WP-331, WP-332).
@Suite("Bindings on a running session")
struct BindingTests {
    let ones = [Float](repeating: 1, count: 64)

    // MARK: Switches (BIND-1…6)

    @Test func aWriteOnTheMainThreadIsForwardedByTheRunLoopItself() async throws {
        let rig = Rig()
        let active = StateBox(true)
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: active.binding) }, to: rig.source)
        let pump = session.core.pump
        #expect(await MainActor.run { !pump.isObserving }, "an idle session keeps no observer")
        try session.start()
        await rig.drain()
        await MainActor.run {
            #expect(pump.isObserving && !pump.hasHeartbeat, "one observer while it runs; switches need no timer")
            let sent = pump.commandsSent
            active.value = false
            // One pass of the main run loop: it goes to wait, and the observer fires before it does.
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
            #expect(pump.commandsSent == sent + 1, "the write is forwarded in the same turn of the loop (BIND-2)")
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            #expect(pump.commandsSent == sent + 1, "an unchanged switch sends nothing")
            // An idle loop does no work: the pump reads its switches when the loop turns for a
            // reason of its own, and keeps nothing that would turn it.
            #expect(!pump.hasHeartbeat)
        }
        #expect(active.writes == 0, "the session never writes a switch (BIND-5)")
        session.stop()
        await rig.drain()
        #expect(await MainActor.run { !pump.isObserving }, "stopped: the observer is gone")
        session.detach()
    }

    @Test func aWriteOffTheMainThreadIsSeenBySyncBindings() async throws {
        let rig = Rig()
        let active = StateBox(true)
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: active.binding) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        rig.feed(ones)
        #expect(probe.samples.last == 0.5)
        active.value = false                                    // off the main thread: the test's task
        await session.syncBindings()
        rig.feed([Float](repeating: 1, count: 64 * 12))
        #expect(probe.samples.last == 1, "bypassed after a fade")
        let fading = probe.samples[64...].filter { $0 > 0.5 && $0 < 1 }.count
        #expect(fading >= 470 && fading <= 480, "the switch is a cross-fade of 10 ms (ACT-7): \(fading) frames")
        #expect(zip(probe.samples, probe.samples.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(session.core.generation == 1, "flipping a binding compiles nothing (ACT-5)")
    }

    @Test func switchesAreCapturedWithTheirValuesWhenThePipelineIsAttached() async throws {
        let rig = Rig()
        let off = StateBox(false)
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: off.binding) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        rig.feed(ones)
        #expect(probe.samples == ones, "a stage whose binding is false starts bypassed (BIND-4)")
        off.value = true
        await session.syncBindings()
        rig.feed([Float](repeating: 1, count: 64 * 12))
        #expect(probe.samples.last == 0.5)
    }

    // MARK: Activation at run time (WP-330b)

    @Test func aSuspendedBranchRunsNoNodeAndStartsColdWhenItResumes() async throws {
        let rig = Rig()
        let shown = StateBox(true)
        let probe = TestProbe()
        let sink = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let session = try await rig.engine.attach(
            Pipeline().tap(isActive: shown.binding) { $0.testFramer(frame: 256, hop: 64, probe: probe).testMagnitude(probe: probe).emit(to: sink) },
            to: rig.source)
        try session.start()
        let noise = TestSignal.whiteNoise(count: 64 * 30, seed: 2)
        rig.feed(Array(noise[..<640]))
        let framed = probe.framesFramed, taken = probe.magnitudesTaken
        #expect(framed > 0 && taken == framed && sink.frameCount == framed)

        shown.value = false
        await session.syncBindings()
        rig.feed(Array(noise[640 ..< 1_280]))
        #expect(probe.framesFramed == framed && probe.magnitudesTaken == taken, "a suspended branch runs no node (ACT-3)")
        #expect(sink.frameCount == framed)

        shown.value = true
        await session.syncBindings()
        rig.feed(Array(noise[1_280...]))
        #expect(probe.framerResets == 2, "once when the session started, once more when the branch resumed (ACT-10)")
        let resumed = Array(sink.reals[framed...])
        let cold = try Pipeline().testFramer(frame: 256, hop: 64).testMagnitude().process(Array(noise[1_280...]), format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        #expect(resumed == cold, "no stale frame: what comes out is what a fresh start on the signal from the resume gives")
        #expect(session.core.generation == 1 && probe.framerNodesMade == 1, "nothing was compiled")
    }

    @Test func aBoundStageThatChangesTheDomainSuspendsWhatFollowsIt() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let probe = TestProbe()
        let sink = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let before = CollectingSink<Samples>()
        var framer = TestFramer(frame: 64, hop: 64, probe: probe)
        framer.activation = on.binding.stageActivation
        let session = try await rig.engine.attach(Pipeline().emit(to: before).appending(framer).testMagnitude(probe: probe).emit(to: sink), to: rig.source)
        try session.start()
        rig.feed([Float](repeating: 0.5, count: 256))
        #expect(sink.frameCount == 4 && before.samples.count == 256)
        on.value = false
        await session.syncBindings()
        rig.feed([Float](repeating: 0.5, count: 256))
        #expect(sink.frameCount == 4 && probe.framesFramed == 4, "everything after the stage is suspended")
        #expect(before.samples.count == 512, "what precedes it runs on")
    }

    // MARK: Results (OUT-2…5)

    @Test func aResultIsDeliveredOnTheMainThreadOncePerChange() async throws {
        let rig = Rig()
        final class Readout: @unchecked Sendable {
            // Threading: written by the binding's setter on whatever thread calls it, which is
            // what the test is about, and read by the test while the session runs: behind the lock.
            private let state = Locked<(value: Float, writes: Int, offMain: Int)>((-1, 0, 0))
            var value: Float { state.get().value }
            var writes: Int { state.get().writes }
            var offMain: Int { state.get().offMain }
            var binding: Binding<Float> {
                let state = state
                return Binding(get: { state.get().value }, set: { newValue in
                    let isMain = Thread.isMainThread
                    state.withLock { (state: inout (value: Float, writes: Int, offMain: Int)) in
                        state.value = newValue
                        state.writes += 1
                        if !isMain { state.offMain += 1 }
                    }
                })
            }
        }
        let readout = Readout()
        let vector = StateBox([Float]())
        let session = try await rig.engine.attach(
            Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: vector.binding).appending(TestMean()).emit(to: readout.binding)
                .environment(\.resultRate, 200),
            to: rig.source)
        let pump = session.core.pump
        #expect(await MainActor.run { !pump.hasHeartbeat }, "no timer while the session does not run")
        try session.start()
        await rig.drain()
        #expect(await MainActor.run { pump.hasHeartbeat }, "a heartbeat at the result rate while results are bound")

        rig.feed([Float](repeating: 0.5, count: 64 * 4))
        #expect(await eventually { readout.writes == 1 })
        let first = readout.value
        rig.feed([Float](repeating: 0.5, count: 64 * 20))
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(readout.writes == 1 && vector.writes == 1, "twenty more frames with the same value: never written with an unchanged value (OUT-3)")
        rig.feed([Float](repeating: 0.25, count: 64 * 4))
        #expect(await eventually { readout.writes == 2 && vector.writes == 2 })
        #expect(readout.value != first && readout.offMain == 0, "written on the main thread only (BIND-1)")
        #expect(vector.value.count == 33, "a Binding<[Float]> receives a new array per delivery (OUT-5)")

        session.stop()
        await rig.drain()
        #expect(await MainActor.run { !pump.hasHeartbeat }, "stopped: no timer")
        // Counted from after the stop: how many beats fall between a reading and the stop is
        // the machine's business, that none follows it is the session's.
        let beats = await MainActor.run { pump.beats }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await MainActor.run { pump.beats == beats }, "and no beat after it")
        #expect(readout.value != -1, "a binding keeps its last value when the session stops")
        session.detach()
    }

    @Test func aPipelineWithoutBindingsKeepsNothingOnTheRunLoop() async throws {
        let rig = Rig()
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5) }, to: rig.source)
        try session.start()
        await rig.drain()
        let pump = session.core.pump
        #expect(await MainActor.run { !pump.isObserving && !pump.hasHeartbeat })
    }

    @Test func detachingReleasesTheBindings() async throws {
        let rig = Rig()
        let active = StateBox(true)
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: active.binding) }, to: rig.source)
        try session.start()
        session.detach()
        await rig.drain()
        let pump = session.core.pump
        await MainActor.run {
            #expect(!pump.isObserving)
            let sent = pump.commandsSent
            active.value = false
            session.syncBindings()
            #expect(pump.commandsSent == sent, "captured bindings are released by detach (BIND-6)")
        }
    }

    // MARK: The result rate (OUT-2, OD-15, ENV-3)

    /// OUT-2: "A heartbeat timer at the result rate (`resultRate`, default 30 per second)";
    /// OD-15: "the key changes it per pipeline"; ENV-3: `.environment(\.key, value)` on a
    /// pipeline or a `Group` overrides a settable key for that scope. So the heartbeat of a
    /// session runs at the rate set around its bound results, the highest of them when they
    /// stand in several scopes, and follows an update that changes nothing else.
    ///
    /// The defect: the engine read the result rate of the environment at the source, which no
    /// pipeline can set, so every heartbeat ran at the default whatever the pipeline said.
    @Test func theHeartbeatRunsAtTheRateThePipelineSets() async throws {
        let rig = Rig()
        let readout = StateBox(Float(0)), second = StateBox(Float(0))
        let measured = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestMean()).emit(to: readout.binding)
        let session = try await rig.engine.attach(measured.environment(\.resultRate, 200), to: rig.source)
        let pump = session.core.pump
        try session.start()
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 200, "200 times a second, as the pipeline says")

        // Another rate around the same stages: the heartbeat follows the update.
        try await session.update(measured.environment(\.resultRate, 50))
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 50)
        // No rate of its own: the default.
        try await session.update(measured)
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 30)

        // Two results in two scopes: one heartbeat, at the higher of the two rates. The inner
        // scope is the one its result stands in; the result behind it stands in the outer one.
        try await session.update(measured.environment(\.resultRate, 60).emit(to: second.binding).environment(\.resultRate, 120))
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 120)
        try await session.update(measured.environment(\.resultRate, 60).emit(to: second.binding).environment(\.resultRate, 20))
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 60)
        session.detach()
    }

    /// §9.3: a result rate that is no rate would be handed to a timer as it is (the pump keeps
    /// a rate between 1 and 1 000 per second, and a value that is no number passes both
    /// bounds). It is refused where it is set, by the name of the scope that sets it, when
    /// the pipeline is attached, updated or processed.
    @Test func aResultRateThatIsNoRateIsRefusedWhereItIsSet() async throws {
        let rig = Rig()
        let readout = StateBox(Float(0))
        let measured = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestMean()).emit(to: readout.binding)
        #expect(!(Double.nan >= 1) && !(Double.nan <= 1_000), "no number is inside the pump's bounds, and none outside")
        for rate in [Double.nan, 0, -30, .infinity] {
            let error = await #expect(throws: DSPError.self) { _ = try await rig.engine.attach(measured.environment(\.resultRate, rate), to: rig.source) }
            guard case .invalidParameter(let stage, let parameter, _)? = error else {
                Issue.record("a rate of \(rate): \(String(describing: error))")
                continue
            }
            #expect("\(stage).\(parameter)" == "Group[0].resultRate", "a rate of \(rate): \(stage).\(parameter)")
        }

        // A session that runs refuses such an update and keeps its heartbeat.
        let session = try await rig.engine.attach(measured.environment(\.resultRate, 200), to: rig.source)
        let pump = session.core.pump
        try session.start()
        await rig.drain()
        await #expect(throws: DSPError.self) { try await session.update(measured.environment(\.resultRate, .nan)) }
        await rig.drain()
        #expect(await MainActor.run { pump.heartbeatInterval } == 1.0 / 200 && session.state == .running)
        session.detach()

        // The rate is judged where it is set, whether or not a result is bound inside.
        #expect(throws: DSPError.self) {
            _ = try Pipeline { TestGain(2) }.environment(\.resultRate, 0).process([1, 2], format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        }
        // What is a rate stays one: the pump keeps it between 1 and 1 000 per second.
        let fast = try await rig.engine.attach(measured.environment(\.resultRate, 1e6), to: rig.source)
        try fast.start()
        await rig.drain()
        #expect(await MainActor.run { fast.core.pump.heartbeatInterval } == 1.0 / 1_000)
        fast.detach()
    }

    @Test func thePumpCostsLittlePerTurn() async throws {
        // §5.7: the binding pump with 16 bound switches takes at most 2 µs per main-run-loop turn.
        let rig = Rig()
        let switches = (0 ..< 16).map { _ in StateBox(true) }
        var pipeline = Pipeline()
        for box in switches { pipeline = pipeline.testGain(0.9, isActive: box.binding) }
        let session = try await rig.engine.attach(pipeline, to: rig.source)
        try session.start()
        await rig.drain()
        let pump = session.core.pump
        let result = await MainActor.run {
            Benchmark.measure("binding pump, 16 switches, per turn", iterations: 1_000) { pump.sample() }
        }
        Benchmark.record([result])
        #expect(result.median > 0, "the turn was measured")
        // The budget is 2 µs per turn (§5.7). It is held in a benchmark run: an optimised build,
        // one test at a time, which is the only run whose timings mean anything. Beside other
        // tests the figure is recorded, not judged.
        #if !DEBUG
        if Benchmark.isRecording {
            #expect(result.median <= 2_000, "\(result.median) ns per turn")
        }
        #endif
    }
}
