import Foundation

/// Runs pipelines on sources (§4.5).
///
/// An engine owns one analysis thread, on which every real-time attachment runs, and one
/// control context, on which plans are compiled and exchanged. Attaching a pipeline to a
/// source compiles a plan for the source's format and returns the session that runs it:
///
/// ```swift
/// let live = try await engine.attach(analysis(into: micFeed), to: HardwareInputSource())
/// try live.start()
/// ```
///
/// A pipeline holds no run-time state: attaching it N times yields N independent plans, each
/// with its own filter memory, buffers and analysis state (ATT-1). A source may carry several
/// attachments of one engine; it is prepared once, started with the first that starts and
/// stopped with the last that stops, and all of them see the same blocks (ATT-6).
///
/// Threading: every method may be called from any thread except the analysis thread, and may
/// allocate. `attach` suspends while the source is prepared and the plan compiled, both off
/// the main thread.
public final class DSPEngine: Sendable {
    /// The engine an app uses unless it needs more than one.
    public static let shared = DSPEngine()

    let core: EngineCore

    /// An engine that processes blocks of `blockSize` frames and chooses implementations by
    /// the crossover table (§7.4).
    public init(blockSize: Int = 512, crossovers: CrossoverTable = .shipped) {
        core = EngineCore(blockSize: blockSize, crossovers: crossovers)
    }

    /// An engine for the package's own tests: one that has no thread and is driven turn by
    /// turn, or one with a clock of the test's.
    package init(blockSize: Int, crossovers: CrossoverTable = .shipped, drivenByHand: Bool) {
        core = EngineCore(blockSize: blockSize, crossovers: crossovers, isManual: drivenByHand)
    }

    /// Frames per processing block.
    public var blockSize: Int { core.blockSize }

    /// The sizes at which each primitive changes implementation.
    public var crossovers: CrossoverTable { core.crossovers }

    /// How the analysis thread is scheduled: under a time-constraint policy, or, when the
    /// system refused one, at its quality of service alone (RT-9).
    public var analysisScheduling: AnalysisScheduling { core.scheduling }

    /// Attaches `pipeline` to `source` and returns the session, idle.
    ///
    /// The source is prepared if this engine has not prepared it yet: permission, session,
    /// format discovery. The plan is compiled for the source's format; every stage checks its
    /// order and its parameters against the environment at its position, and an error names
    /// the stage.
    ///
    /// - Throws: what the source's `prepare()` throws; `invalidStageOrder` or
    ///   `invalidParameter` for a pipeline that is not valid at this format; `sinkInUse` when
    ///   the pipeline writes a feed, a stream or a callback that another live attachment
    ///   writes, or names one sink twice (ATT-5); `sourceUnavailable` when the source is
    ///   attached to another engine.
    public func attach<Output>(_ pipeline: Pipeline<Samples, Output>, to source: any SampleSource) async throws(DSPError) -> PipelineSession {
        PipelineSession(core: try await core.attach(pipeline.stages, to: source))
    }

    /// Attaches a pipeline assembled from data. Equal stages give the same plan as a typed
    /// pipeline (ORD-5).
    public func attach(_ pipeline: DynamicPipeline, to source: any SampleSource) async throws(DSPError) -> PipelineSession {
        PipelineSession(core: try await core.attach(pipeline.stages, to: source))
    }
}

/// One attachment of a pipeline to a source: the handle the app starts, stops, updates and
/// detaches (§4.5).
///
/// | Call or event | `idle` | `running` | `interrupted` | `finished`, `failed` | `detached` |
/// |---|---|---|---|---|---|
/// | `start()` | `running` | no effect | no effect | the source is prepared again, then `running` | throws |
/// | `stop()` | no effect | `idle` | `idle` | `idle` | no effect |
/// | `update(_:)` | plan replaced | §5.5.4 | plan replaced | plan replaced | throws |
/// | `detach()` | `detached` | `detached` | `detached` | `detached` | no effect |
///
/// A session that is released without being detached detaches itself.
///
/// Threading: every member may be used from any thread except the analysis thread, and may
/// allocate. `start()`, `stop()` and `detach()` wait for the engine's control context, which
/// is busy for as long as a plan takes to compile.
public final class PipelineSession: Sendable, Identifiable {
    let core: SessionCore

    init(core: SessionCore) {
        self.core = core
    }

    deinit {
        let core = self.core
        core.engine.control.async { core.engine.detach(core) }
    }

    /// What tells this attachment from every other, for as long as the process lives. Any thread.
    public var id: UUID { core.id }

    /// The environment resolved for this attachment: the values at the source, and as
    /// `latency` the delay of the whole main line (ATT-3, REAL-5).
    public var environment: DSPEnvironment { core.environment }

    /// The state the session is in now (§4.5). Any thread; one atomic read, no allocation.
    /// A change is also announced on `events`.
    public var state: SessionState { core.state }

    /// What happens to the session, from now on. Every access gives a stream of its own, so
    /// several listeners do not take events from one another; each keeps the newest 256 events
    /// its consumer has not taken yet. The streams end when the session is detached.
    public var events: AsyncStream<SessionEvent> { core.events }

    /// Starts the session. From `idle` the source is started, if it is not delivering yet, and
    /// the stages start cold. From `finished` or `failed` the source is prepared again first;
    /// that suspends, so the session becomes `running`, or `failed`, a moment later.
    ///
    /// - Throws: `sessionDetached`; what the source's `start()` throws.
    public func start() throws(DSPError) {
        try core.engine.start(core)
    }

    /// Stops the session. The source is stopped with the last attachment that stops.
    public func stop() {
        core.engine.stop(core)
    }

    /// Changes the running pipeline; the session works out the smallest thing to do (§5.5.4).
    ///
    /// An equal pipeline costs one comparison. The same topology with other values sends the
    /// values to the kernels that run: a gain ramps, a filter keeps its memory. Another
    /// topology compiles a new plan, which takes over at a block boundary: what is unchanged
    /// keeps running, what is new is pre-rolled and faded in. In every case the bindings of
    /// the pipeline given here are the ones the session reads and writes from now on.
    ///
    /// - Throws: `sessionDetached`; what compiling the pipeline throws. A pipeline that does
    ///   not compile leaves the running one as it is.
    public func update<Output>(_ pipeline: Pipeline<Samples, Output>) async throws(DSPError) {
        try await core.engine.update(core, to: pipeline.stages)
    }

    /// Changes the running pipeline to one assembled from data.
    public func update(_ pipeline: DynamicPipeline) async throws(DSPError) {
        try await core.engine.update(core, to: pipeline.stages)
    }

    /// Reads every bound switch now, instead of at the main run loop's next turn (BIND-3).
    /// A write made off the main thread is seen when the loop next turns, which an idle app
    /// may delay; hopping to the main actor to call this is what wakes it.
    @MainActor
    public func syncBindings() {
        core.pump.sample()
    }

    /// Ends the attachment: the plan is released, and so are the claims on its sinks and the
    /// bindings it captured (ATT-5, BIND-6). The session cannot be started or updated again.
    public func detach() {
        core.engine.detach(core)
    }
}
