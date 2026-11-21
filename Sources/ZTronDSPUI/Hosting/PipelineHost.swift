import os
import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// Counts what a pipeline host does, for the tests of its life cycle (WP-816) and of its
/// animation (WP-817). Injected through the environment; a host that is given none counts
/// nothing.
///
/// Threading: main actor.
@MainActor
final class PipelineHostProbe {
    /// Attachments asked of an engine: `attach` was called for them. At most one more than
    /// have landed, because a host asks for one at a time.
    private(set) var requests = 0
    /// Pipelines attached to a source.
    private(set) var attaches = 0
    /// Sessions detached.
    private(set) var detaches = 0
    /// The continuous values of every pipeline handed to a session's `update(_:)`, in order.
    private(set) var updates: [ParameterVector] = []
    /// Updates the session has taken or refused: `update(_:)` has returned for them.
    private(set) var settled = 0
    /// What attaching, starting or updating threw.
    private(set) var failures: [DSPError] = []
    /// The state of every session that arrived too late, as the host left it when it turned
    /// to what the view wants now: detached.
    private(set) var late: [SessionState] = []
    /// The session the host keeps now.
    private(set) weak var session: PipelineSession?

    func requestedAttach() {
        requests += 1
    }

    func attached(_ session: PipelineSession) {
        attaches += 1
        self.session = session
    }

    func detached() {
        detaches += 1
        session = nil
    }

    func updated(_ parameters: ParameterVector) {
        updates.append(parameters)
    }

    func settledUpdate() {
        settled += 1
    }

    /// True when no update is on its way.
    var isIdle: Bool { settled == updates.count }

    func failed(_ error: DSPError) {
        failures.append(error)
    }

    func arrivedLate(_ session: PipelineSession) {
        late.append(session.state)
    }
}

private struct PipelineHostProbeKey: EnvironmentKey {
    static let defaultValue: PipelineHostProbe? = nil
}

extension EnvironmentValues {
    /// The probe the pipeline hosts of a hierarchy count into, when a test injects one.
    var dspPipelineHostProbe: PipelineHostProbe? {
        get { self[PipelineHostProbeKey.self] }
        set { self[PipelineHostProbeKey.self] = newValue }
    }
}

/// The session a view hosts: attached when the view appears, updated when the pipeline
/// changes, detached when the view leaves (ANI-3).
///
/// Attaching and updating suspend, off the main thread, while a plan is compiled. The model
/// keeps one of them on its way at a time and remembers the newest pipeline that was asked
/// for meanwhile: when the one on its way has landed, the newest is sent, and whatever lay
/// between is dropped. That is the rule of ANI-5 for an animation that outruns the design of
/// its stages, and it keeps the updates in the order they were asked for.
///
/// The same holds across the view's comings and goings. A view that leaves, or is given
/// another source or engine, while an attachment is on its way does not ask for the next one
/// until that one has landed and has been detached: a session that arrives too late still
/// holds the sinks of its pipeline (ATT-5), and an attachment made beside it would be refused
/// them. So whatever happens while a plan is compiled, the view ends with the one attachment
/// it asked for last, or with none when it has left. The price is that an attachment which
/// waits for its source to be prepared, a permission prompt for one, is waited for.
///
/// Threading: main actor.
@MainActor
final class PipelineHostModel<Output: SignalDomain> {
    private var session: PipelineSession?
    private var source: (any SampleSource)?
    private var engine: DSPEngine?
    /// The pipeline the session was last handed.
    private var running: Pipeline<Samples, Output>?
    /// The newest pipeline the view asked for.
    private var wanted: Pipeline<Samples, Output>?
    /// A pipeline the engine refused: it is not sent again until another one is asked for.
    private var refused: Pipeline<Samples, Output>?
    /// True while an attach or an update is on its way, whichever appearance asked for it.
    private var isBusy = false
    /// Counts appearances and disappearances, so that what lands late is recognised.
    private var epoch = 0
    private var renderProbe: RenderProbe?
    private var hostProbe: PipelineHostProbe?

    private static var log: Logger { Logger(subsystem: "com.zombietron.ztrondsp", category: "pipeline-host") }

    /// The view came into the hierarchy: attach `pipeline` to `source` and start it.
    func appear(_ pipeline: Pipeline<Samples, Output>, on source: any SampleSource, engine: DSPEngine, renderProbe: RenderProbe?, hostProbe: PipelineHostProbe?) {
        leave()
        self.source = source
        self.engine = engine
        self.renderProbe = renderProbe
        self.hostProbe = hostProbe
        wanted = pipeline
        attach()
    }

    /// The view left the hierarchy: detach.
    func disappear() {
        leave()
        source = nil
        engine = nil
    }

    /// The view was given a pipeline: update the session, unless this is the pipeline it runs.
    func want(_ pipeline: Pipeline<Samples, Output>) {
        guard source != nil else { return }
        wanted = pipeline
        if session == nil { attach() } else { send() }
    }

    /// The view was evaluated again, with what it hosts now. On the source and the engine it
    /// is attached to, that is `want(_:)`: an update of the session, unless the pipeline is
    /// the one it runs. Another source, or another engine, is another attachment: the one
    /// the view has is ended, and the pipeline is attached where it belongs now. A view that
    /// is not in the hierarchy keeps none either way.
    func show(_ pipeline: Pipeline<Samples, Output>, on source: any SampleSource, engine: DSPEngine) {
        guard let current = self.source, let currentEngine = self.engine else { return }
        if current === source, currentEngine === engine {
            want(pipeline)
        } else {
            appear(pipeline, on: source, engine: engine, renderProbe: renderProbe, hostProbe: hostProbe)
        }
    }

    private func leave() {
        epoch += 1
        if let session {
            session.detach()
            hostProbe?.detached()
        }
        session = nil
        running = nil
        wanted = nil
        refused = nil
        // What is on its way stays on its way: it lands, is let go, and only then is the
        // engine asked again.
    }

    private func attach() {
        guard !isBusy, session == nil, let source, let engine, let pipeline = wanted, pipeline != refused else { return }
        isBusy = true
        hostProbe?.requestedAttach()
        let epoch = epoch
        Task { [weak self] in
            let result: Result<PipelineSession, DSPError>
            do throws(DSPError) { result = .success(try await engine.attach(pipeline, to: source)) } catch { result = .failure(error) }
            guard let self else {
                if case .success(let late) = result { late.detach() }
                return
            }
            self.isBusy = false
            guard self.epoch == epoch else {
                // The view left, or was given another source or engine, while the plan was
                // compiled. The session that comes too late is let go here and now, its sinks
                // and its source with it, before what the view wants now is asked for: left
                // to itself it would be detached when it is released, a moment too late for
                // an attachment on another engine.
                if case .success(let late) = result {
                    late.detach()
                    self.hostProbe?.arrivedLate(late)
                }
                self.attach()
                return
            }
            switch result {
            case .success(let session):
                self.session = session
                self.running = pipeline
                self.renderProbe?.recordAttach()
                self.hostProbe?.attached(session)
                do throws(DSPError) { try session.start() } catch { self.failed(error) }
                self.send()
            case .failure(let error):
                self.refused = pipeline
                self.failed(error)
                self.attach()
            }
        }
    }

    /// Hands the session the newest pipeline, when it is not the one it runs.
    private func send() {
        guard !isBusy, let session, let next = wanted, next != running, next != refused else { return }
        isBusy = true
        let epoch = epoch, previous = running
        running = next
        hostProbe?.updated(next.parameters)
        Task { [weak self] in
            var failure: DSPError?
            do throws(DSPError) { try await session.update(next) } catch { failure = error }
            guard let self else { return }
            self.isBusy = false
            self.hostProbe?.settledUpdate()
            guard self.epoch == epoch else {
                // The session this update was for is gone: what the view wants now is attached.
                self.attach()
                return
            }
            if let failure {
                // A pipeline that does not compile leaves the running one as it is.
                self.running = previous
                self.refused = next
                self.failed(failure)
            }
            self.send()
        }
    }

    private func failed(_ error: DSPError) {
        hostProbe?.failed(error)
        Self.log.error("A hosted pipeline was refused: \(String(describing: error), privacy: .public)")
    }
}

/// A view that hosts a pipeline: what `.pipeline(_:on:)` returns.
///
/// The host is `Animatable` over the pipeline's continuous values (ANI-3). When a state
/// change inside `withAnimation` gives it a pipeline of the same topology with other values,
/// SwiftUI hands it one interpolated vector per display frame, and each goes to the session
/// as one same-topology update: the values travel to the kernels that run, a gain ramps, a
/// filter keeps its memory (§5.5.4). A pipeline of another topology is applied at once
/// (ANI-4).
///
/// Threading: main actor.
struct PipelineHost<Content: View, Output: SignalDomain>: View, Animatable {
    let content: Content
    /// The pipeline the view was given: where an animation ends.
    let pipeline: Pipeline<Samples, Output>
    let source: any SampleSource
    /// The continuous values this frame runs with.
    var parameters: AnimatableParameters

    init(content: Content, pipeline: Pipeline<Samples, Output>, source: any SampleSource) {
        self.content = content
        self.pipeline = pipeline
        self.source = source
        parameters = AnimatableParameters(pipeline)
    }

    nonisolated var animatableData: AnimatableParameters {
        get { parameters }
        set { parameters = newValue }
    }

    /// The pipeline this frame runs: the one the view was given, with the values of an
    /// animation that is on its way. Values of another length belong to another topology and
    /// leave the pipeline as it is.
    var shownPipeline: Pipeline<Samples, Output> {
        pipeline.replacingParameters(parameters.vector)
    }

    var body: some View {
        PipelineAttachment(content: content, pipeline: shownPipeline, source: source)
    }
}

/// What a view hosts: a pipeline, the source it runs on, and the engine that runs it. Two are
/// equal when the pipelines are, and the source and the engine are the same objects.
///
/// An immutable value; everything in it is `Sendable`.
struct HostedPipeline<Output: SignalDomain>: Equatable, Sendable {
    let pipeline: Pipeline<Samples, Output>
    let source: any SampleSource
    let engine: DSPEngine

    static func == (lhs: HostedPipeline, rhs: HostedPipeline) -> Bool {
        lhs.source === rhs.source && lhs.engine === rhs.engine && lhs.pipeline == rhs.pipeline
    }
}

/// Keeps the session of a hosted pipeline for as long as the view is in the hierarchy.
///
/// Threading: main actor. The only state it writes is the model that keeps the session, once,
/// when the view first appears. The view keeps that model when it leaves and comes back, so
/// that what was on its way when it left is settled before anything else is attached.
struct PipelineAttachment<Content: View, Output: SignalDomain>: View {
    let content: Content
    let pipeline: Pipeline<Samples, Output>
    let source: any SampleSource

    @Environment(\.dspEngine) private var engine
    @Environment(\.dspRenderProbe) private var renderProbe
    @Environment(\.dspPipelineHostProbe) private var hostProbe
    /// The session's keeper: made when the view first appears, kept for as long as the
    /// view's state.
    @State private var model: PipelineHostModel<Output>?

    var body: some View {
        content
            .onAppear {
                let model = model ?? PipelineHostModel<Output>()
                if self.model == nil { self.model = model }
                model.appear(pipeline, on: source, engine: engine, renderProbe: renderProbe, hostProbe: hostProbe)
            }
            .onDisappear {
                model?.disappear()
            }
            .onChange(of: HostedPipeline(pipeline: pipeline, source: source, engine: engine)) { hosted in
                // An equal pipeline on the same source and engine never gets here: `onChange`
                // compares. What changed is read off the value handed over, never off this
                // view: SwiftUI calls the closure of the evaluation before the change, whose
                // view still holds the source, the engine and the pipeline of that time.
                model?.show(hosted.pipeline, on: hosted.source, engine: hosted.engine)
            }
    }
}

extension View {
    /// Hosts `pipeline` on `source` for as long as this view is in the hierarchy (ANI-3): the
    /// pipeline is attached and started when the view appears, the session is updated when
    /// the pipeline value changes, and it is detached when the view leaves.
    ///
    /// ```swift
    /// @State private var cutoff = 1_000.0
    ///
    /// SpectrogramView(feed: feed)
    ///     .pipeline(Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4); MelSpectrogram(to: feed) }, on: mic)
    /// Button("Open up") { withAnimation(.easeInOut(duration: 2)) { cutoff = 8_000 } }   // the cutoff glides
    /// ```
    ///
    /// The pipeline runs on the engine found in the environment, `DSPEngine.shared` unless
    /// `.dspEngine(_:)` says otherwise. An equal pipeline causes no update. A pipeline of the
    /// same topology with other values is a value update, and inside `withAnimation` the
    /// session receives one interpolated update per display frame (ANI-3); frequencies glide
    /// evenly in pitch and gains in decibels (ANI-2). A pipeline of another topology is
    /// applied at once (ANI-4). When a stage's design is not finished by the time the next
    /// frame arrives, the newest frame wins (ANI-5).
    ///
    /// The source is something the app keeps, in state or in a model, not something made in
    /// a `body`; it may serve other attachments at the same time (ATT-6). Another source
    /// object, or another engine in the environment, is another attachment: the session is
    /// detached and the pipeline attached where it belongs now. A pipeline the engine refuses
    /// (an invalid order, a sink another attachment writes) leaves the view as it was and is
    /// logged.
    ///
    /// Threading: main actor, like every view modifier; it may allocate, for the state of the
    /// attachment it keeps. Attaching and updating suspend off the main thread.
    public func pipeline<Output: SignalDomain>(_ pipeline: Pipeline<Samples, Output>, on source: any SampleSource) -> some View {
        PipelineHost(content: self, pipeline: pipeline, source: source)
    }
}
