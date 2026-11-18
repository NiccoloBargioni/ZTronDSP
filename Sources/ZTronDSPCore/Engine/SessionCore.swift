import Foundation

/// The state of a session (§4.5).
public enum SessionState: Sendable, Hashable {
    /// Attached and not running: before the first `start()`, or after `stop()`.
    case idle
    /// Blocks flow through the plan.
    case running
    /// The source stopped delivering and may resume by itself.
    case interrupted
    /// The source has nothing more to deliver.
    case finished
    /// The source, or a re-plan after a format change, failed.
    case failed(DSPError)
    /// The session was detached; it cannot be started or updated again.
    case detached
}

/// Why a session compiled a new plan.
public enum ReplanReason: Sendable, Hashable {
    /// The source delivers another format (ATT-4). Stage state was reset.
    case formatChanged
    /// `update(_:)` was given a pipeline of another topology (§5.5.4).
    case update
}

/// How hard the system is pressed for memory (MEM-1).
public enum MemoryPressureLevel: Sendable, Hashable {
    /// Plans waiting to be destroyed were destroyed.
    case warning
    /// Feeds created with a smaller `minimumHistory` also dropped their oldest columns.
    case critical
}

/// What happens to a session while it lives (§4.5).
public enum SessionEvent: Sendable, Hashable {
    case stateChanged(SessionState)
    /// A new plan took over.
    case replanned(ReplanReason)
    /// The main line's output changed in domain, rate or latency, or could not be cross-faded:
    /// it switched at a block boundary (SWAP-2).
    case outputChanged
    /// The source dropped frames because the analysis fell behind (RT-8).
    case overrun(droppedFrames: Int)
    /// Samples that were not finite arrived and were replaced by zeros (NUM-1).
    case nonFiniteInput(count: Int)
    case memoryPressure(MemoryPressureLevel)
}

/// One attachment of a pipeline to a source, as the engine holds it: the control side of a
/// session. `PipelineSession` is the handle the app holds on it.
///
/// Threading: `state`, `environment` and `events` may be read anywhere. Everything else
/// belongs to the engine's control context.
final class SessionCore: @unchecked Sendable {
    let id = UUID()
    let engine: EngineCore
    let hub: SourceHub
    let runner: SessionRunner
    let board = LivenessBoard()
    let pump: BindingPump
    /// Everyone who listens to the session's events, each with a stream of their own.
    private let listeners = Locked<[UUID: AsyncStream<SessionEvent>.Continuation]>([:])
    private let isOver = Locked(false)

    private struct Visible {
        var state = SessionState.idle
        var environment: DSPEnvironment
    }

    private let visible: Locked<Visible>

    // Control context only.
    /// The description the latest plan was compiled from.
    var stages: [StageDescription]
    /// The latest plan: the one that runs, or the one on its way in.
    var plan: ExecutionPlan
    /// The plan the runner runs.
    var installedPlan: ExecutionPlan
    var generation: UInt32 = 1
    /// True while the runner is part of its hub's published stage.
    var isScheduled = false
    /// Counts restarts, so that a restart that was overtaken by `stop()` or `detach()` does nothing.
    var restartToken = 0
    /// Sinks claimed for a plan that was withdrawn: they are claimed anew for the next plan.
    var staleSinks: Set<ObjectIdentifier> = []
    /// Sinks of the running plan whose claim an update has already given up (ATT-5): the
    /// running plan writes them no more, and a later plan that names one claims it anew.
    var releasedSinks: Set<ObjectIdentifier> = []
    /// Payloads of value commands the analysis thread has not applied yet.
    var payloads: [(sequence: UInt64, pointer: UnsafeMutableRawPointer)] = []
    /// The hub of a processed source this session feeds, when it is the inner session of one.
    weak var derivedHub: SourceHub?
    /// Probes on the main line's output.
    var probes: [any MainLineConsumer] = []

    init(engine: EngineCore, hub: SourceHub, runner: SessionRunner, stages: [StageDescription], plan: ExecutionPlan) {
        self.engine = engine
        self.hub = hub
        self.runner = runner
        self.stages = stages
        self.plan = plan
        self.installedPlan = plan
        self.pump = BindingPump(runner: runner, board: board)
        visible = Locked(Visible(environment: SessionCore.environment(of: plan)))
    }

    deinit {
        for payload in payloads { payload.pointer.deallocate() }
        for listener in listeners.get().values { listener.finish() }
    }

    /// The environment a session reports: the values at the source, with the latency of the
    /// whole main line (ENV-4, REAL-5).
    static func environment(of plan: ExecutionPlan) -> DSPEnvironment {
        let source = plan.lowered.sourceEnvironment
        return source.addingLatency(plan.lowered.output.environment.latency - source.latency)
    }

    // MARK: Any thread

    var state: SessionState { visible.withLock { $0.state } }

    /// A stream of the session's events from now on. Every call gives a stream of its own, so
    /// the app, a view's environment bridge and a test can each listen without taking events
    /// from one another; a stream that is dropped or whose task is cancelled just leaves.
    var events: AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .bufferingNewest(256))
        if isOver.get() {
            continuation.finish()
            return stream
        }
        let key = UUID()
        listeners.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { $0[key] = nil }
        }
        return stream
    }
    var environment: DSPEnvironment { visible.withLock { $0.environment } }

    // MARK: Control context

    /// Moves the session to `next` and says so. Returns false when it already was there.
    @discardableResult
    func setState(_ next: SessionState) -> Bool {
        let changed = visible.withLock { visible -> Bool in
            guard visible.state != next else { return false }
            visible.state = next
            return true
        }
        guard changed else { return false }
        emit(.stateChanged(next))
        return true
    }

    func setEnvironment(_ environment: DSPEnvironment) {
        visible.withLock { $0.environment = environment }
    }

    func emit(_ event: SessionEvent) {
        for listener in listeners.get().values { listener.yield(event) }
    }

    func finishEvents() {
        isOver.set(true)
        let all = listeners.withLock { listeners -> [AsyncStream<SessionEvent>.Continuation] in
            defer { listeners = [:] }
            return Array(listeners.values)
        }
        for listener in all { listener.finish() }
    }

    /// Frees the payloads of value commands that have been applied.
    func freeAppliedPayloads() {
        guard !payloads.isEmpty else { return }
        let applied = ztd_command_queue_applied(runner.values)
        payloads.removeAll { payload in
            guard payload.sequence <= applied else { return false }
            payload.pointer.deallocate()
            return true
        }
    }

    /// Frees every payload: nothing will read them any more.
    func freeAllPayloads() {
        for payload in payloads { payload.pointer.deallocate() }
        payloads = []
    }
}
