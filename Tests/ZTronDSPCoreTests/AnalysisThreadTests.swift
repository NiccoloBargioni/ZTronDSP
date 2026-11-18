import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The analysis thread (WP-319a, WP-319b): created once, parked while nothing runs, woken by
/// polling at half a block and never under a millisecond; an `.asFastAsPossible` source runs
/// on a thread of its own.
@Suite("Analysis thread")
struct AnalysisThreadTests {
    private func thread(_ role: RunnerThread.Role, _ clock: any AnalysisClock) throws -> (RunnerThread, OpaquePointer) {
        let attention = try #require(ztd_atomic_create(0))
        return (try RunnerThread(role: role, clock: clock, attention: attention, notify: {}), attention)
    }

    @Test func startAndStopAreIdempotent() throws {
        let (thread, attention) = try thread(.analysis, MachClock())
        defer { ztd_atomic_destroy(attention) }
        #expect(!thread.isRunning)
        thread.stop()
        thread.start()
        thread.start()
        #expect(thread.isRunning)
        thread.stop()
        thread.stop()
        #expect(!thread.isRunning)
        thread.start()
        #expect(thread.isRunning, "a stopped thread starts again")
        thread.stop()
    }

    @Test func aThreadWithNothingToRunStaysParked() async throws {
        let (thread, attention) = try thread(.analysis, MachClock())
        defer { ztd_atomic_destroy(attention) }
        thread.start()
        #expect(await eventually { thread.parkCount == 1 })
        let turns = thread.turnCount
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(thread.turnCount == turns && thread.parkCount == 1, "no wake-up in one second while parked")
        thread.wake()
        #expect(await eventually { thread.parkCount == 2 }, "woken, it looks once and parks again")
        #expect(thread.turnCount == turns + 1)
        thread.stop()
    }

    @Test func anEngineWithoutRunningSessionsCausesNoWakeUps() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000))
        let session = try await engine.attach(Pipeline(), to: source)
        #expect(engine.core.analysisThread == nil, "attaching alone creates no thread")
        #expect(engine.analysisScheduling == .notStarted)
        try session.start()
        let thread = try #require(engine.core.analysisThread)
        #expect(await eventually { thread.turnCount > 10 }, "while a session runs, the thread polls")
        #expect(await eventually { engine.analysisScheduling != .notStarted }, "and has asked for its scheduling (RT-9)")
        session.stop()
        #expect(await eventually { thread.parkCount >= 1 })
        let turns = thread.turnCount, parks = thread.parkCount
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(thread.turnCount == turns && thread.parkCount == parks, "stopped, it parks")
        session.detach()
    }

    @Test func pollingComesRoundEveryHalfBlockAndNeverUnderAMillisecond() throws {
        for (blockSize, sampleRate, expected) in [(512, 48_000.0, 512.0 / 48_000 / 2), (64, 48_000.0, 0.001), (16, 192_000.0, 0.001), (4_096, 44_100.0, 4_096.0 / 44_100 / 2)] {
            let clock = TestClock()
            let (thread, attention) = try thread(.analysis, clock)
            defer { ztd_atomic_destroy(attention) }
            let hub = try HubRunner(attention: attention)
            let source = ManualPushSource(format: SignalFormat(sampleRate: sampleRate))
            let adapter = try SourceAdapter.make(for: source, blockSize: blockSize)
            let interval = max(0.001, Double(blockSize) / sampleRate / 2)
            hub.stage.publish(HubStage(mode: .polled, adapter: adapter, input: try AudioBuffer(channelCount: 1, capacity: blockSize), sessions: [],
                                       sampleRate: sampleRate, interval: interval, epoch: 1))
            thread.schedule.publish(HubList(hubs: [hub], interval: interval))
            var deadlines: [Double] = []
            for _ in 0 ..< 20 {
                let deadline = try #require(thread.turn())
                deadlines.append(deadline - clock.now)
                clock.sleep(until: deadline)
            }
            #expect(deadlines.allSatisfy { abs($0 - expected) < 1e-12 }, "\(blockSize) frames at \(sampleRate) Hz: \(deadlines[0]) s")
            #expect(deadlines.allSatisfy { $0 >= 0.001 })
        }
    }

    @Test func aPacedPullSourceIsAskedOncePerBlockDuration() throws {
        let clock = TestClock()
        let (thread, attention) = try thread(.analysis, clock)
        defer { ztd_atomic_destroy(attention) }
        let hub = try HubRunner(attention: attention)
        let source = ScriptedSource([Float](repeating: 0, count: 480 * 50), sampleRate: 48_000, batchSizes: [480], pacing: .realTime)
        let adapter = try SourceAdapter.make(for: source, blockSize: 480)
        hub.stage.publish(HubStage(mode: .paced, adapter: adapter, input: try AudioBuffer(channelCount: 1, capacity: 480), sessions: [],
                                   sampleRate: 48_000, interval: 0.005, epoch: 1))
        thread.schedule.publish(HubList(hubs: [hub], interval: 0.005))
        // 20 blocks of 10 ms: the engine paces itself, so each turn asks for exactly one block.
        for turn in 1 ... 20 {
            let deadline = try #require(thread.turn())
            #expect(source.renderCount == turn)
            #expect(abs(deadline - Double(turn) * 0.010) < 1e-9, "turn \(turn) sleeps until \(deadline)")
            clock.sleep(until: deadline)
        }
        // Held up for 35 ms, the thread catches up and returns to its grid.
        clock.advance(by: 0.035)
        _ = thread.turn()
        #expect(source.renderCount == 24)
    }

    @Test func anOfflineSessionDoesNotRunOnTheAnalysisThread() async throws {
        let engine = DSPEngine(blockSize: 64)
        let live = Locked<UInt64>(0), offline = Locked<UInt64>(0)
        func identify(_ slot: Locked<UInt64>) -> FeatureCallback<Samples> {
            FeatureCallback { _ in
                var identifier: UInt64 = 0
                pthread_threadid_np(nil, &identifier)
                slot.set(identifier)
            }
        }
        let paced = try await engine.attach(Pipeline().emit(to: identify(live)),
                                            to: GeneratorSource(.silence, duration: 0.05, pacing: .realTime))
        let fast = try await engine.attach(Pipeline().emit(to: identify(offline)),
                                           to: GeneratorSource(.silence, duration: 0.05, pacing: .asFastAsPossible))
        #expect(paced.environment.isRealTime && !fast.environment.isRealTime)
        try paced.start()
        try fast.start()
        #expect(await paced.reaches(.finished))
        #expect(await fast.reaches(.finished))
        var test: UInt64 = 0
        pthread_threadid_np(nil, &test)
        #expect(live.get() != 0 && offline.get() != 0)
        #expect(live.get() != offline.get(), "a source that is asked as fast as possible has a thread of its own (§4.3)")
        #expect(live.get() != test && offline.get() != test)
    }

    @Test func aRealTimePullSourceTakesAsLongAsItsSignal() async throws {
        let engine = DSPEngine(blockSize: 480)
        let sink = CountingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: GeneratorSource(.silence, duration: 0.3, pacing: .realTime))
        let started = Date()
        try session.start()
        #expect(await session.reaches(.finished))
        let elapsed = Date().timeIntervalSince(started)
        // The lower bound is the pacing; how much longer a busy machine takes is not the engine's.
        #expect(elapsed > 0.25, "0.3 s of signal at real-time pacing took \(elapsed) s")
        #expect(sink.frames == 30)
    }
}
