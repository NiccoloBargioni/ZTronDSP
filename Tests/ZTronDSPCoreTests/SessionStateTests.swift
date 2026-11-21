import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Every cell of the state table of §4.5 (WP-320a), repeated calls included.
@Suite("Session states")
struct SessionStateTests {
    let format = SignalFormat(sampleRate: 48_000)
    let block = [Float](repeating: 0.5, count: 64)

    private func attached(_ source: ManualPushSource, to engine: DSPEngine = DSPEngine(blockSize: 64),
                          sink: CollectingSink<Samples> = CollectingSink()) async throws -> PipelineSession {
        try await engine.attach(Pipeline().emit(to: sink), to: source)
    }

    @Test func idle() async throws {
        let source = ManualPushSource(format: format)
        let session = try await attached(source)
        let log = EventLog(session)
        #expect(session.state == .idle)
        session.stop()
        #expect(session.state == .idle, "stop has no effect on an idle session")
        try session.start()
        #expect(session.state == .running)
        try session.start()
        #expect(session.state == .running && source.starts == 1, "start has no effect on a running session")
        session.stop()
        session.stop()
        #expect(session.state == .idle && source.stops == 1)
        session.detach()
        session.detach()
        #expect(session.state == .detached)
        #expect(await eventually { log.states == [.running, .idle, .detached] })
    }

    @Test func detached() async throws {
        let source = ManualPushSource(format: format)
        let session = try await attached(source)
        session.detach()
        #expect(throws: DSPError.sessionDetached) { try session.start() }
        await #expect(throws: DSPError.sessionDetached) { try await session.update(Pipeline()) }
        session.stop()
        #expect(session.state == .detached, "stop and detach have no effect on a detached session")
        #expect(source.starts == 0 && source.stops == 0)
    }

    @Test func startThatFailsLeavesTheSessionIdle() async throws {
        let source = ManualPushSource(format: format, startError: .sourceUnavailable(reason: "no input"))
        let session = try await attached(source)
        #expect(throws: DSPError.sourceUnavailable(reason: "no input")) { try session.start() }
        #expect(session.state == .idle)
    }

    @Test func interruptionAndResumption() async throws {
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let engine = DSPEngine(blockSize: 64)
        let session = try await attached(source, to: engine, sink: sink)
        source.send(.interrupted)
        source.send(.resumed)
        // The engine is through with both events before the session starts: they are taken off
        // the source (its listener waits for a third), and the control context has done what it
        // was asked. Handled after the start they would interrupt and resume the running session.
        #expect(await eventually(timeout: 30) { source.eventsAreTaken }, "the engine listens to the source")
        engine.core.flush()
        #expect(session.state == .idle, "an idle session is not interrupted")

        try session.start()
        source.write(block)
        #expect(await eventually { sink.samples.count == 64 })
        source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        try session.start()
        #expect(session.state == .interrupted, "start has no effect while interrupted: the session resumes with its source")
        source.write(block)                               // what arrives while interrupted is not part of what follows
        source.send(.resumed)
        #expect(await session.reaches(.running))
        source.write(block)
        #expect(await eventually { sink.samples.count == 128 })
        #expect(sink.times.last == 0, "stages start cold after a resumption: the session's clock starts over (ACT-10)")
        source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        session.stop()
        #expect(session.state == .idle, "stop from interrupted")
        session.detach()
    }

    @Test func endOfTheStream() async throws {
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let engine = DSPEngine(blockSize: 64)
        let session = try await attached(source, to: engine, sink: sink)
        try session.start()
        source.write(block + [0.25, 0.25, 0.25])
        source.send(.ended)
        #expect(await session.reaches(.finished))
        #expect(sink.samples.count == 67, "what the ring held is delivered before the stream ends")
        #expect(source.stops == 1)
        source.send(.interrupted)
        source.send(.failed(.sourceUnavailable(reason: "late")))
        // The engine is through with both events (see `interruptionAndResumption`).
        #expect(await eventually(timeout: 30) { source.eventsAreTaken })
        engine.core.flush()
        #expect(session.state == .finished, "a finished session takes no source event")
        session.stop()
        #expect(session.state == .idle, "stop from finished")
        session.detach()
    }

    @Test func endWhileInterrupted() async throws {
        let source = ManualPushSource(format: format)
        let session = try await attached(source)
        try session.start()
        source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        source.send(.ended)
        #expect(await session.reaches(.finished))
    }

    @Test func failure() async throws {
        let error = DSPError.sourceUnavailable(reason: "unplugged")
        for precondition in ["idle", "running", "interrupted"] {
            let source = ManualPushSource(format: format)
            let session = try await attached(source)
            if precondition != "idle" { try session.start() }
            if precondition == "interrupted" {
                source.send(.interrupted)
                #expect(await session.reaches(.interrupted))
            }
            source.send(.failed(error))
            #expect(await session.reaches(.failed(error)), "from \(precondition)")
            session.stop()
            #expect(session.state == .idle, "stop from failed")
            session.detach()
        }
    }

    @Test func aFinishedSessionStartsAgainWithItsSourcePreparedAgain() async throws {
        let engine = DSPEngine(blockSize: 64)
        let signal = TestSignal.whiteNoise(count: 1_000, seed: 3)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: BufferSource(signal, sampleRate: 48_000))
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples == signal)
        try session.start()
        #expect(await eventually { sink.samples.count == 2 * signal.count })
        #expect(await session.reaches(.finished))
        #expect(sink.samples == signal + signal, "prepared again, a source that has an end starts over")
        #expect(sink.times[sink.times.count / 2] == 0, "and the session's clock with it")
    }

    @Test func aFailedSessionStartsAgain() async throws {
        let engine = DSPEngine(blockSize: 64)
        let error = DSPError.sourceUnavailable(reason: "scripted")
        let source = ScriptedSource(format: format, [.samples([block]), .failure(error)])
        let session = try await engine.attach(Pipeline(), to: source)
        try session.start()
        #expect(await session.reaches(.failed(error)))
        try session.start()
        #expect(await session.reaches(.failed(error)), "the script runs again from its first step and fails again")
        session.detach()
        #expect(throws: DSPError.sessionDetached) { try session.start() }
    }

    @Test func aSessionThatIsReleasedDetachesItself() async throws {
        let engine = DSPEngine(blockSize: 64)
        let sink = CollectingSink<Samples>()
        let source = ManualPushSource(format: format)
        do {
            let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
            try session.start()
        }
        #expect(await eventually { sink.releases == 1 && source.stops == 1 })
        let again = try await engine.attach(Pipeline().emit(to: sink), to: source)
        #expect(again.state == .idle)
    }
}

extension SessionStateTests {
    @Test func everyListenerHasAStreamOfItsOwn() async throws {
        let source = ManualPushSource(format: format)
        let session = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: source)
        let first = EventLog(session), second = EventLog(session)
        let cancelled = Task { for await _ in session.events {} }
        cancelled.cancel()
        try session.start()
        session.stop()
        #expect(await eventually { first.states == [.running, .idle] && second.states == [.running, .idle] }, "both hear everything")
        let late = EventLog(session)
        session.detach()
        #expect(await eventually { late.states == [.detached] && first.states.last == .detached }, "a later listener hears what follows")
        var ended = 0
        for await _ in session.events { ended += 1 }
        #expect(ended == 0, "after the detachment a stream ends at once")
    }
}

extension SessionStateTests {
    @Test func updateWhileInterruptedReplacesThePlan() async throws {
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let session = try await DSPEngine(blockSize: 64).attach(Pipeline().emit(to: sink), to: source)
        try session.start()
        source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        try await session.update(Pipeline { TestGain(2) }.emit(to: sink))
        #expect(session.state == .interrupted, "update leaves an interrupted session interrupted")
        #expect(session.core.runner.installedGeneration == 2, "the plan is replaced at once")
        source.send(.resumed)
        #expect(await session.reaches(.running))
        source.write(block)
        #expect(await eventually { sink.samples.count == 64 })
        #expect(sink.samples.allSatisfy { $0 == 1 }, "the replaced plan runs after the resumption")
        session.detach()
    }

    @Test func updateWhileFinishedOrFailedReplacesThePlan() async throws {
        for ending in ["finished", "failed"] {
            let source = ManualPushSource(format: format)
            let sink = CollectingSink<Samples>()
            let session = try await DSPEngine(blockSize: 64).attach(Pipeline().emit(to: sink), to: source)
            try session.start()
            let error = DSPError.sourceUnavailable(reason: "gone")
            let expected: SessionState = ending == "finished" ? .finished : .failed(error)
            source.send(ending == "finished" ? .ended : .failed(error))
            #expect(await session.reaches(expected))
            try await session.update(Pipeline { TestGain(2) }.emit(to: sink))
            #expect(session.state == expected, "update leaves the state: \(session.state)")
            #expect(session.core.runner.installedGeneration == 2, "plan replaced from \(ending)")
            try session.start()
            #expect(await session.reaches(.running), "from \(ending)")
            source.write(block)
            #expect(await eventually { sink.samples.count == 64 })
            #expect(sink.samples.allSatisfy { $0 == 1 })
            session.detach()
        }
    }

    @Test func detachWhileInterruptedAndWhileRunning() async throws {
        let source = ManualPushSource(format: format)
        let session = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: source)
        try session.start()
        source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        session.detach()
        #expect(session.state == .detached && source.stops == 1)
        let other = ManualPushSource(format: format)
        let running = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: other)
        try running.start()
        running.detach()
        #expect(running.state == .detached && other.stops == 1)
    }

    @Test func aFormatChangeWhileIdleAndWhileInterruptedRePlans() async throws {
        for precondition in ["idle", "interrupted"] {
            let source = ManualPushSource(format: format)
            let sink = CollectingSink<Samples>()
            let session = try await DSPEngine(blockSize: 64).attach(
                Pipeline { EnvironmentReader { environment in TestGain(Float(environment.sampleRate / 48_000)) } }.emit(to: sink), to: source)
            let log = EventLog(session)
            if precondition == "interrupted" {
                try session.start()
                source.send(.interrupted)
                #expect(await session.reaches(.interrupted))
            }
            source.changeFormat(to: SignalFormat(sampleRate: 96_000, channelCount: 2))
            #expect(await eventually { session.environment.sampleRate == 96_000 && session.environment.channelCount == 2 }, "re-plan from \(precondition)")
            #expect(session.state == (precondition == "idle" ? .idle : .interrupted), "the state stays: \(session.state)")
            #expect(await eventually { log.contains(.replanned(.formatChanged)) })
            if precondition == "idle" { try session.start() } else { source.send(.resumed) }
            #expect(await session.reaches(.running))
            source.write(block)
            #expect(await eventually { sink.samples.count == 64 })
            #expect(sink.samples.allSatisfy { $0 == 1 }, "the plan was compiled for the new environment")
            session.detach()
        }
    }
}
