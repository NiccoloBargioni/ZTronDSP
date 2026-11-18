import Foundation
import os

/// The engine behind `DSPEngine`: its control context, its threads, its hubs, and every step
/// that changes what runs (§4.5, §5.5.4).
///
/// One rule keeps the two sides apart. The analysis side runs whatever stage a hub was last
/// handed, and looks for a new one at the top of every turn. The control context changes
/// something only in one of three ways: it hands over a new immutable object (a stage, a
/// plan, a list) through an atomic slot; it sends a command through an SPSC queue; or it
/// first hands the hub an idle stage, waits until the thread has taken it, and then works on
/// what the thread no longer touches (`pause` … `resume`). Nothing else crosses (RT-4).
///
/// Threading: every method without a note belongs to the control context.
final class EngineCore: @unchecked Sendable {
    let blockSize: Int
    let crossovers: CrossoverTable
    let control: ControlContext
    /// True for an engine that has no thread: a test runs its turns by hand (`runTurn`).
    let isManual: Bool
    let clock: any AnalysisClock
    private let attention: OpaquePointer?
    private let attentionSignal: DispatchSourceUserDataAdd
    private let log = Logger(subsystem: "com.zombietron.ztrondsp", category: "engine")

    // Control context only.
    private var hubs: [ObjectIdentifier: SourceHub] = [:]
    private var analysis: RunnerThread?
    /// The hubs the analysis thread runs.
    private var polled: [SourceHub] = []
    private var pressure: DispatchSourceMemoryPressure?

    init(blockSize: Int, crossovers: CrossoverTable, isManual: Bool = false, clock: any AnalysisClock = MachClock()) {
        self.blockSize = blockSize
        self.crossovers = crossovers
        self.isManual = isManual
        self.clock = clock
        control = ControlContext(label: "com.zombietron.ztrondsp.control")
        attention = ztd_atomic_create(0)
        attentionSignal = DispatchSource.makeUserDataAddSource(queue: control.queue)
        attentionSignal.setEventHandler { [weak self] in self?.service() }
        attentionSignal.resume()
    }

    deinit {
        attentionSignal.cancel()
        pressure?.cancel()
        analysis?.stop()
        for hub in hubs.values { hub.thread?.stop() }
        if let attention { ztd_atomic_destroy(attention) }
    }

    /// How the analysis thread is scheduled (RT-9). Any thread.
    var scheduling: AnalysisScheduling {
        (try? control.sync { analysis?.scheduling ?? .notStarted }) ?? .notStarted
    }

    // MARK: Attach

    /// Attaches a description to a source: prepares the source once, compiles a plan for its
    /// format, claims the sinks. Any thread that may suspend.
    func attach(_ stages: [StageDescription], to source: any SampleSource) async throws(DSPError) -> SessionCore {
        guard blockSize >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "blockSize", reason: "a block holds at least one frame, not \(blockSize)")
        }
        let hub = try await preparedHub(for: source)
        do throws(DSPError) {
            while true {
                let lowered = try await control.run { () throws(DSPError) in try self.lower(stages, for: hub) }
                // Bindings are read on the main actor, and the plan compiled off it (BIND-4).
                let values = await MainActor.run { lowered.switches.map { $0.read() } }
                let made = try await control.run { () throws(DSPError) in try self.register(stages, lowered, values, on: hub) }
                guard let made else { continue }                // the format moved meanwhile: again
                let session = made.session, slots = made.slots
                await MainActor.run {
                    session.pump.capture(
                        switches: lowered.switches, compiledValues: values, results: lowered.results, slots: slots,
                        generation: 1, resultRate: lowered.sourceEnvironment.resultRate)
                }
                return session
            }
        } catch {
            control.async {
                hub.pendingAttaches -= 1
                self.discardIfUnused(hub)
            }
            throw error
        }
    }

    private func lower(_ stages: [StageDescription], for hub: SourceHub) throws(DSPError) -> LoweredPipeline {
        try PlanCompiler(crossovers: crossovers).lower(stages, environment: hub.environment, blockSize: hub.maximumFrames)
    }

    /// Builds the plan and the session. `nil` when the hub's format changed since `lowered`
    /// was compiled.
    private func register(
        _ stages: [StageDescription], _ lowered: LoweredPipeline, _ values: [Bool], on hub: SourceHub
    ) throws(DSPError) -> (session: SessionCore, slots: [ResultSlot])? {
        guard lowered.sourceEnvironment == hub.environment else { return nil }
        let runner = try SessionRunner(attention: hub.attention)
        runner.sampleRate = hub.format.sampleRate
        let plan = try ExecutionPlan(lowered: lowered, switchValues: values, crossovers: crossovers, generation: 1, previous: nil)
        let session = SessionCore(engine: self, hub: hub, runner: runner, stages: stages, plan: plan)
        try adoptSinks(of: plan, for: session, replacing: nil)
        plan.output = runner
        runner.plans.publish(plan)
        runner.settle()
        _ = runner.takeEvents()
        session.board.install(generation: plan.generation, sinks: plan.sinks.map(\.sink), gates: plan.sinkGates, compiledValues: values)
        hub.sessions.append(session)
        hub.pendingAttaches -= 1
        startWatchingMemory()
        return (session, plan.resultSlots)
    }

    // MARK: Hubs

    /// The hub of `source`, prepared. Every attachment that arrives while the source is being
    /// prepared waits for the same preparation (ATT-6).
    private func preparedHub(for source: any SampleSource) async throws(DSPError) -> SourceHub {
        let (hub, preparation) = try await control.run { () throws(DSPError) -> (SourceHub, Task<Result<Bool, DSPError>, Never>) in
            let hub = try self.hub(for: source)
            hub.pendingAttaches += 1
            if let running = hub.preparation { return (hub, running) }
            let task = Task<Result<Bool, DSPError>, Never>.detached(priority: .utility) {
                await self.prepare(hub)
            }
            hub.preparation = task
            return (hub, task)
        }
        switch await preparation.value {
        case .success:
            return hub
        case .failure(let error):
            control.async {
                hub.pendingAttaches -= 1
                hub.preparation = nil
                self.discardIfUnused(hub)
            }
            throw error
        }
    }

    private func hub(for source: any SampleSource) throws(DSPError) -> SourceHub {
        let identity = ObjectIdentifier(source)
        if let existing = hubs[identity] { return existing }
        guard let attention else { throw .resourceAllocationFailed(what: "the engine's signalling") }
        // The hub first: one that cannot be made has claimed nothing.
        let hub = try SourceHub(source: source, attention: attention)
        try SourceRegistry.claim(identity, for: ObjectIdentifier(self))
        hubs[identity] = hub
        return hub
    }

    /// Prepares a hub's source and makes the hub ready for attachments. Not on the control
    /// context: it suspends.
    private func prepare(_ hub: SourceHub) async -> Result<Bool, DSPError> {
        do throws(DSPError) {
            if let processed = hub.processed {
                // A processed source is fed by a session of its pipeline on its upstream source.
                let inner = try await attach(processed.stages, to: processed.upstream)
                do throws(DSPError) {
                    try await control.run { () throws(DSPError) in
                        inner.derivedHub = hub
                        hub.inner = inner
                        inner.runner.consumers.publish(ConsumerList([hub.runner] + inner.probes))
                        inner.runner.consumers.refresh()
                        try self.adoptSource(hub)
                    }
                } catch {
                    control.async {
                        hub.inner = nil
                        inner.derivedHub = nil
                        self.detachNow(inner)
                    }
                    throw error
                }
            } else {
                try await hub.source.prepare()
                let deliver = eventHandler(for: hub)
                try await control.run { () throws(DSPError) in
                    try self.adoptSource(hub)
                    SourceEventRouter.route(hub.source, to: deliver)
                }
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    /// What the hub's source says reaches the hub on the control context, for as long as both
    /// the engine and the hub live.
    private func eventHandler(for hub: SourceHub) -> @Sendable (SourceEvent) -> Void {
        { [weak self, weak hub] event in
            guard let self, let hub else { return }
            self.control.async { self.handle(event, from: hub) }
        }
    }

    /// Takes what the source is after it was prepared: its adapter and input block, and the
    /// format the hub's sessions are compiled for. Sessions compiled for another format are
    /// compiled again (ATT-4). Only while the hub's stage is idle.
    private func adoptSource(_ hub: SourceHub) throws(DSPError) {
        let before = (hub.format, hub.maximumFrames)
        if let inner = hub.inner {
            let output = inner.plan.lowered.output
            guard output.domain == .samples else {
                throw .unsupportedConfiguration(reason: "a processed source needs a pipeline that ends in samples, not in \(output.domain)")
            }
            hub.format = output.environment.format
            hub.maximumFrames = max(output.maximumFrames, 1)
            hub.environment = output.environment
                .withSource(kind: .derived, isRealTime: inner.hub.environment.isRealTime)
                .withBlockSize(hub.maximumFrames)
            hub.processed?.setFormat(hub.format)
        } else {
            hub.adapter?.close()
            let adapter = try SourceAdapter.make(for: hub.source, blockSize: blockSize)
            hub.adapter = adapter
            hub.input = try AudioBuffer(channelCount: adapter.format.channelCount, capacity: blockSize)
            hub.format = adapter.format
            hub.maximumFrames = blockSize
            let isRealTime = adapter.pacing == .realTime
            hub.environment = DSPEnvironment(
                sampleRate: adapter.format.sampleRate, channelCount: adapter.format.channelCount, blockSize: blockSize, isRealTime: isRealTime
            ).withSource(kind: adapter.kind, isRealTime: isRealTime)
            hub.lastDropped = 0
            hub.lastNonFinite = 0
        }
        hub.isPrepared = true
        hub.epoch += 1
        if before != (hub.format, hub.maximumFrames), !hub.sessions.isEmpty {
            for session in hub.sessions { recompile(session) }
            hub.processed?.send(.formatChanged(hub.format))
        }
    }

    /// Lets go of a hub nothing is attached to: stops its source, ends its thread, frees the
    /// source for another engine.
    private func discardIfUnused(_ hub: SourceHub) {
        guard hub.sessions.isEmpty, hub.pendingAttaches <= 0, hubs[ObjectIdentifier(hub.source)] === hub else { return }
        stopSource(hub)
        if let index = polled.firstIndex(where: { $0 === hub }) {
            polled.remove(at: index)
            publishPolled()
        }
        hub.thread?.stop()
        hub.thread = nil
        hubs[ObjectIdentifier(hub.source)] = nil
        if hub.processed == nil { SourceEventRouter.unroute(hub.source) }
        SourceRegistry.release(ObjectIdentifier(hub.source), from: ObjectIdentifier(self))
        if let inner = hub.inner {
            hub.inner = nil
            inner.derivedHub = nil
            detach(inner)
        }
    }

    private func root(of hub: SourceHub) -> SourceHub {
        var current = hub
        while let inner = current.inner { current = inner.hub }
        return current
    }

    // MARK: What a hub runs

    /// The thread that runs a root hub now, if one does.
    private func driver(of hub: SourceHub) -> RunnerThread? {
        guard !isManual else { return nil }
        if let thread = hub.thread, thread.isRunning { return thread }
        if let analysis, analysis.isRunning, polled.contains(where: { $0 === hub }) { return analysis }
        return nil
    }

    private func publishPolled() {
        guard let analysis else { return }
        let interval = polled.map(\.pollInterval).min() ?? 0
        analysis.schedule.publish(HubList(hubs: polled.map(\.runner), interval: interval))
        analysis.wake()
        if analysis.isRunning { ControlWait.until { !analysis.schedule.hasPending } }
        analysis.schedule.drainRetired()
    }

    /// Makes sure a thread runs the hub: its own for a source that is asked as fast as
    /// possible, the engine's analysis thread otherwise (§4.3).
    private func ensureDriver(for hub: SourceHub) throws(DSPError) {
        guard !isManual, !hub.isDerived else { return }
        let attention = hub.attention
        let signal = attentionSignal
        let notify: @Sendable () -> Void = { signal.add(data: 1) }
        if hub.isFreeRunning {
            if let index = polled.firstIndex(where: { $0 === hub }) {
                polled.remove(at: index)
                publishPolled()
            }
            if hub.thread == nil {
                let thread = try RunnerThread(role: .offline, clock: clock, attention: attention, notify: notify)
                thread.schedule.publish(HubList(hubs: [hub.runner], interval: 0))
                hub.thread = thread
            }
            hub.thread?.start()
        } else {
            if let thread = hub.thread {
                thread.stop()
                hub.thread = nil
            }
            if analysis == nil { analysis = try RunnerThread(role: .analysis, clock: clock, attention: attention, notify: notify) }
            if !polled.contains(where: { $0 === hub }) {
                polled.append(hub)
                analysis?.start()
                publishPolled()
            }
            analysis?.start()
        }
    }

    /// Hands the hub the stage that matches the control context's view of it.
    private func publishStage(_ hub: SourceHub) {
        let live = hub.isStarted && !hub.isInterrupted && hub.pauseDepth == 0
        // A hub that is fed by another session's output is run by that session, not by a thread.
        var mode = HubStage.Mode.idle
        if live, !hub.isDerived, let adapter = hub.adapter {
            mode = adapter.kind == .push ? .polled : (adapter.pacing == .asFastAsPossible ? .free : .paced)
        }
        hub.stageSerial += 1
        hub.runner.stage.publish(HubStage(
            mode: mode, adapter: hub.adapter, input: hub.input, sessions: live ? hub.scheduled.map(\.runner) : [],
            sampleRate: hub.format.sampleRate, interval: hub.pollInterval, epoch: hub.epoch,
            latency: hub.isDerived ? hub.environment.latency : 0, serial: hub.stageSerial))
    }

    /// Waits until the thread of a root hub runs the stage that was published last, or takes
    /// it on the thread's behalf when no thread runs the hub.
    private func settle(_ hub: SourceHub) {
        if let thread = driver(of: hub) {
            thread.wake()
            if !ControlWait.until({ !hub.runner.stage.hasPending }) {
                log.fault("The analysis thread did not take a new stage within five seconds")
            }
        } else {
            hub.runner.stage.refresh()
        }
        hub.runner.stage.drainRetired()
    }

    /// Makes the analysis side run exactly what the control context says the hub runs.
    private func commit(_ hub: SourceHub) {
        if hub.isDerived {
            // A hub fed by a session looks for a new stage only when that session gets a block.
            // The root is paused instead, and the stage taken here.
            let top = root(of: hub)
            pause(top)
            publishStage(hub)
            hub.runner.stage.refresh()
            hub.runner.stage.drainRetired()
            resume(top)
        } else {
            publishStage(hub)
            settle(hub)
        }
    }

    /// Takes a root hub off its thread: from here to `resume`, the control context alone
    /// touches the hub, its sessions, and everything fed by them.
    private func pause(_ hub: SourceHub) {
        hub.pauseDepth += 1
        guard hub.pauseDepth == 1 else { return }
        publishStage(hub)
        settle(hub)
    }

    private func resume(_ hub: SourceHub) {
        hub.pauseDepth -= 1
        guard hub.pauseDepth == 0 else { return }
        publishStage(hub)
        settle(hub)
    }

    // MARK: Start and stop

    func start(_ session: SessionCore) throws(DSPError) {
        try control.sync { () throws(DSPError) in
            switch session.state {
            case .detached:
                throw DSPError.sessionDetached
            case .running, .interrupted:
                return
            case .idle:
                // A stream that is over delivers nothing more: its source is prepared again,
                // as for a session that finished with it.
                if session.hub.streamOver, !session.hub.isStarted { restart(session) } else { try activate(session) }
            case .finished, .failed:
                restart(session)
            }
        }
    }

    func stop(_ session: SessionCore) {
        try? control.sync { () throws(DSPError) in
            switch session.state {
            case .idle, .detached:
                return
            case .running, .interrupted, .finished, .failed:
                session.restartToken += 1
                deactivate(session)
                session.setState(.idle)
            }
        }
    }

    func detach(_ session: SessionCore) {
        try? control.sync { () throws(DSPError) in detachNow(session) }
    }

    private func detachNow(_ session: SessionCore) {
        guard session.state != .detached else { return }
        session.restartToken += 1
        deactivate(session)
        settleDirectly(session)
        session.setState(.detached)
        session.board.clear()
        releaseSinks(session.installedPlan.sinks.compactMap { entry in
            if let identity = entry.description.sink.identity, session.releasedSinks.contains(identity) { return nil }
            return (entry.sink, entry.description.sink.identity)
        })
        session.releasedSinks = []
        session.staleSinks = []
        session.freeAllPayloads()
        dropPipeline(of: session)
        let pump = session.pump
        DispatchQueue.main.async { pump.release() }
        let hub = session.hub
        hub.sessions.removeAll { $0 === session }
        session.finishEvents()
        discardIfUnused(hub)
    }

    /// Lets go of everything a detached session was compiled from: its description, its plans
    /// with their kernels and nodes, and with them every binding the description held (BIND-6).
    /// What is left is an empty plan, so the session's handle stays a valid object.
    private func dropPipeline(of session: SessionCore) {
        session.stages = []
        guard let lowered = try? PlanCompiler(crossovers: crossovers).lower([], environment: session.hub.environment, blockSize: session.hub.maximumFrames),
              let empty = try? ExecutionPlan(lowered: lowered, switchValues: [], crossovers: crossovers, generation: session.generation &+ 1, previous: nil)
        else { return }
        session.generation &+= 1
        session.plan = empty
        session.installedPlan = empty
        session.runner.plans.publish(empty)
        session.runner.settle()
        _ = session.runner.takeEvents()
        session.runner.plans.drainRetired()
    }

    /// Starts the hub's source, if it is not delivering.
    private func startSource(_ hub: SourceHub) throws(DSPError) {
        guard !hub.isStarted else { return }
        if let adapter = hub.adapter {
            adapter.rewind()
            hub.lastDropped = 0
            hub.lastNonFinite = adapter.nonFiniteCount
            try hub.source.start()
            try ensureDriver(for: hub)
        }
        hub.isStarted = true
        hub.isInterrupted = false
        hub.epoch += 1
    }

    /// Stops the hub's source, if it is delivering.
    private func stopSource(_ hub: SourceHub) {
        guard hub.isStarted else { return }
        hub.isStarted = false
        hub.isInterrupted = false
        commit(hub)
        if let inner = hub.inner {
            deactivate(inner)
            switch inner.state {
            case .running, .interrupted: inner.setState(.idle)
            default: break
            }
        } else {
            // A reader thread that waits for room in the ring is let go before it is joined.
            hub.adapter?.close()
            hub.source.stop()
        }
    }

    /// Makes a session run: its source delivering, its plan cold, its runner in the stage.
    private func activate(_ session: SessionCore) throws(DSPError) {
        guard !session.isScheduled else { return }
        let hub = session.hub
        coldStart(session)
        session.isScheduled = true
        if let inner = hub.inner, !hub.isStarted {
            // Behind a processed source the session is in place before the pipeline in front
            // starts to deliver: a source that is asked as fast as possible would otherwise be
            // through before anyone listened.
            hub.isStarted = true
            hub.isInterrupted = false
            hub.epoch += 1
            commit(hub)
            do throws(DSPError) {
                try activate(inner)
            } catch {
                hub.isStarted = false
                session.isScheduled = false
                commit(hub)
                throw error
            }
        } else {
            do throws(DSPError) {
                try startSource(hub)
            } catch {
                session.isScheduled = false
                throw error
            }
            commit(hub)
        }
        session.setState(.running)
        session.board.setRunning(true)
        setPumpRunning(session, true)
        innerStateChanged(session)
    }

    /// Takes a session out of what runs; stops the source with the last one.
    private func deactivate(_ session: SessionCore) {
        guard session.isScheduled else { return }
        session.isScheduled = false
        let hub = session.hub
        commit(hub)
        settleDirectly(session)
        session.board.setRunning(false)
        setPumpRunning(session, false)
        if hub.scheduled.isEmpty { stopSource(hub) }
    }

    /// A session that finished or failed is started again: the source is prepared anew, then
    /// the session runs (§4.5). Preparing suspends, so the outcome arrives as a state.
    private func restart(_ session: SessionCore) {
        let hub = session.hub
        session.restartToken += 1
        let token = session.restartToken
        if hub.isStarted {
            // Another attachment has brought the source back already.
            do throws(DSPError) { try activate(session) } catch { session.setState(.failed(error)) }
            return
        }
        let preparation: Task<Result<Bool, DSPError>, Never>
        if let running = hub.preparation, !hub.isPrepared {
            preparation = running
        } else {
            hub.isPrepared = false
            let task = Task<Result<Bool, DSPError>, Never>.detached(priority: .utility) { await self.prepareAgain(hub) }
            hub.preparation = task
            preparation = task
        }
        Task.detached(priority: .utility) {
            let result = await preparation.value
            self.control.async {
                // A preparation that failed is over: the next `start()` prepares again (§4.5).
                if case .failure = result, hub.preparation == preparation { hub.preparation = nil }
                guard session.restartToken == token else { return }
                switch session.state {
                case .finished, .failed, .idle: break
                default: return
                }
                do throws(DSPError) {
                    _ = try result.get()
                    try self.activate(session)
                } catch {
                    session.setState(.failed(error))
                }
            }
        }
    }

    /// Prepares the source of a hub that was prepared before, and the sources upstream of it.
    private func prepareAgain(_ hub: SourceHub) async -> Result<Bool, DSPError> {
        do throws(DSPError) {
            if let inner = hub.inner {
                let upstream = inner.hub
                let needed = try await control.run { !upstream.isStarted }
                if needed { _ = try await prepareAgain(upstream).get() }
            } else {
                try await hub.source.prepare()
            }
            try await control.run { () throws(DSPError) in
                if !hub.isStarted {
                    try self.adoptSource(hub)
                    hub.streamOver = false
                }
                hub.isPrepared = true
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    /// A cold start: the plan as it is after compilation, the session's clock at zero
    /// (ACT-10). Only while the session is off its thread.
    private func coldStart(_ session: SessionCore) {
        settleDirectly(session)
        session.installedPlan.resetAll()
        session.runner.needsOrigin = true
        session.runner.sampleRate = session.hub.format.sampleRate
    }

    /// Finishes at once whatever exchange the session has in flight: afterwards the latest
    /// plan is the one that runs. Only while the session is off its thread.
    private func settleDirectly(_ session: SessionCore) {
        // What the runner retired is released first, so that it has room to retire the plan
        // it now replaces and takes the one that waits for it.
        session.runner.plans.drainRetired()
        session.runner.settle()
        bookExchange(of: session)
    }

    private func setPumpRunning(_ session: SessionCore, _ running: Bool) {
        let pump = session.pump
        DispatchQueue.main.async { pump.setRunning(running) }
    }

    // MARK: Update (§5.5.4)

    /// What the first step of an update found.
    private enum UpdateStep: Sendable {
        /// The pipeline is the running one, or differs from it in values that have been sent:
        /// only its bindings are captured.
        case recapture(switches: [BoundSwitch], results: [BoundResult], resultRate: Double)
        /// Another topology, or values for a stage the plan runs no kernel for: a plan has to
        /// be compiled.
        case compile(LoweredPipeline)
    }

    /// Changes a running pipeline: the session works out the smallest thing to do.
    /// Any thread that may suspend.
    func update(_ session: SessionCore, to stages: [StageDescription]) async throws(DSPError) {
        let step = try await control.run { () throws(DSPError) in try self.beginUpdate(session, stages) }
        switch step {
        case .recapture(let switches, let results, let rate):
            await MainActor.run { session.pump.recapture(switches: switches, results: results, resultRate: rate) }
        case .compile(let lowered):
            let values = await MainActor.run { lowered.switches.map { $0.read() } }
            let handover = try await control.run { () throws(DSPError) in try self.exchange(session, stages, lowered, values) }
            await MainActor.run {
                session.pump.capture(
                    switches: handover.switches, compiledValues: handover.values, results: handover.results, slots: handover.slots,
                    generation: handover.generation, resultRate: handover.resultRate)
            }
        }
    }

    private func beginUpdate(_ session: SessionCore, _ stages: [StageDescription]) throws(DSPError) -> UpdateStep {
        guard session.state != .detached else { throw DSPError.sessionDetached }
        let current = session.plan.lowered
        let rate = current.sourceEnvironment.resultRate

        // An equal pipeline: one description comparison, and its bindings (ACT-12).
        if let resolved = PlanCompiler.resolve(stages, readerEnvironments: current.readerEnvironments), resolved == current.resolved,
           let bindings = PlanCompiler.bindings(of: resolved, switchSites: current.switchSites, resultSites: current.resultSites) {
            session.stages = stages
            // The bindings captured before are let go everywhere, the plan included (BIND-6).
            session.plan.adoptBindings(resolved: resolved, switches: bindings.switches, results: bindings.results)
            return .recapture(switches: bindings.switches, results: bindings.results, resultRate: rate)
        }

        let lowered = try lower(stages, for: session.hub)
        // The same topology with other values: the values travel to the kernels that run. The
        // topology is that of the skeleton, in which a gain keeps its place whatever its value:
        // a gain that reaches 0 dB is sent the value like any other and stays a kernel. One
        // that leaves 0 dB in a plan that was compiled without a kernel for it (F4) has none to
        // send the value to: that plan is replaced by one that has.
        if IRStep.sameStructure(lowered.skeleton, current.skeleton), lowered.switches.count == current.switches.count,
           lowered.results == current.results, lowered.output == current.output, session.plan.canTakeValues(of: lowered) {
            sendValues(of: lowered, replacing: current, to: session)
            session.plan.adoptValues(of: lowered)
            session.stages = stages
            return .recapture(switches: lowered.switches, results: lowered.results, resultRate: lowered.sourceEnvironment.resultRate)
        }
        return .compile(lowered)
    }

    private struct PlanHandover: Sendable {
        let switches: [BoundSwitch]
        let values: [Bool]
        let results: [BoundResult]
        let slots: [ResultSlot]
        let generation: UInt32
        let resultRate: Double
    }

    /// Compiles the plan of another topology and hands it to the session's runner, which
    /// exchanges it at a block boundary (SWAP-1…4).
    ///
    /// The session changes only once the new plan is certain: compiled, and every sink of it
    /// claimed and prepared. An update that is refused before that leaves the session as it
    /// is, and with it the plan of an earlier update that is still on its way in (§4.5).
    private func exchange(
        _ session: SessionCore, _ stages: [StageDescription], _ compiled: LoweredPipeline, _ read: [Bool]
    ) throws(DSPError) -> PlanHandover {
        guard session.state != .detached else { throw DSPError.sessionDetached }
        var lowered = compiled
        var values = read
        if lowered.sourceEnvironment != session.hub.environment {
            // The format moved while the bindings were read: compile for the one that holds now.
            lowered = try lower(stages, for: session.hub)
            if lowered.switches.count != values.count { values = [Bool](repeating: true, count: lowered.switches.count) }
        }
        let top = root(of: session.hub)
        // The plan this one replaces is the plan that runs. One that is being faded in runs
        // already: it takes over at once (CR-015, item 5).
        settleFade(of: session)
        let running = session.installedPlan
        // The latest update wins (SWAP-4): a plan that is still pre-rolled, or that the runner
        // has not taken yet, is replaced by this one. Until this one is certain it stays on its
        // way in.
        let replaced = session.plan !== running ? session.plan : nil

        session.generation += 1
        let plan = try ExecutionPlan(lowered: lowered, switchValues: values, crossovers: crossovers, generation: session.generation,
                                     previous: running)
        if let replaced {
            // From here on the plan on its way in must stay where it is: the hub is held off
            // its thread.
            pause(top)
            if session.runner.installedGeneration == replaced.generation || session.runner.isFading {
                // It went on while this plan was compiled, and is no longer one to replace: this
                // plan was compiled against a plan that it will not follow. Once more, against
                // the plan that takes over now; nothing is on its way in then.
                resume(top)
                return try exchange(session, stages, lowered, values)
            }
            do throws(DSPError) {
                try adoptSinks(of: plan, for: session, replacing: running, insteadOf: replaced)
            } catch {
                resume(top)
                throw error
            }
            session.runner.drop(session.runner.plans.withdraw())
            session.plan = running
            session.runner.plans.drainRetired()
            resume(top)
        } else {
            try adoptSinks(of: plan, for: session, replacing: running)
        }

        plan.output = session.runner
        session.stages = stages
        session.plan = plan
        session.runner.plans.publish(plan)
        // A stage that was an identity in the plan before has its kernel now, made as that
        // identity: its values follow it like any change of values (§5.5.4).
        for arrival in plan.takeArrivals() {
            if let payload = arrival.kernel.spec.commandPayload() { send(payload, to: arrival.target, of: session) }
            arrival.box.source = .kernel(arrival.kernel)
        }
        if !session.isScheduled || !isLive(session.hub) {
            // Nothing can be heard: the plan takes over at once.
            pause(top)
            settleDirectly(session)
            resume(top)
        }
        session.freeAppliedPayloads()
        return PlanHandover(switches: lowered.switches, values: values, results: lowered.results, slots: plan.resultSlots,
                            generation: plan.generation, resultRate: lowered.sourceEnvironment.resultRate)
    }

    /// True when blocks reach the hub's sessions: started, not interrupted, and so all the way
    /// up to the source.
    private func isLive(_ hub: SourceHub) -> Bool {
        var current = hub
        while true {
            guard current.isStarted, !current.isInterrupted else { return false }
            guard let inner = current.inner else { return true }
            guard inner.isScheduled else { return false }
            current = inner.hub
        }
    }

    /// Books an exchange the runner has carried out, and lets a plan that is being faded in
    /// take over at once. A plan that is pre-rolled, or that the runner has not taken yet,
    /// stays as it is.
    private func settleFade(of session: SessionCore) {
        guard session.plan !== session.installedPlan else { return }
        if session.runner.installedGeneration != session.plan.generation {
            guard session.runner.isFading else { return }
            let top = root(of: session.hub)
            pause(top)
            session.runner.finishFade()
            resume(top)
        }
        bookExchange(of: session)
    }

    /// Books an exchange the runner has carried out, whoever comes to it first: the service
    /// after a block, the next update, a stop.
    ///
    /// An exchange is there to be booked when the generation of the session's latest plan is
    /// the one that runs. The runner says what it has to say of an exchange before it shows
    /// that generation (`SessionRunner.install`), so what is read here, after the generation,
    /// is whole: an output that changed at a block boundary is reported as `.outputChanged`
    /// with the exchange it belongs to (SWAP-2).
    private func bookExchange(of session: SessionCore) {
        guard session.plan !== session.installedPlan, session.runner.installedGeneration == session.plan.generation else { return }
        let outputChanged = session.runner.takeEvents() & SessionRunner.outputChanged != 0
        let old = session.installedPlan
        let plan = session.plan
        session.installedPlan = plan
        session.releasedSinks = []
        session.board.install(generation: plan.generation, sinks: plan.sinks.map(\.sink), gates: plan.sinkGates, compiledValues: plan.switchValues)
        session.setEnvironment(SessionCore.environment(of: plan))
        session.runner.plans.drainRetired()
        session.emit(.replanned(.update))
        let was = old.lowered.output, now = plan.lowered.output
        if outputChanged || was.domain != now.domain || was.environment.format != now.environment.format
            || was.environment.latency != now.environment.latency {
            session.emit(.outputChanged)
        }
    }

    // MARK: Values

    /// Sends every changed value of `lowered` to the kernel that runs it (§5.5.4). The plan has
    /// a kernel for each of them (`ExecutionPlan.canTakeValues`).
    private func sendValues(of lowered: LoweredPipeline, replacing current: LoweredPipeline, to session: SessionCore) {
        let before = IRStep.kernels(of: current.skeleton)
        for (index, kernel) in IRStep.kernels(of: lowered.skeleton).enumerated() where kernel.spec != before[index].spec {
            if let payload = kernel.spec.commandPayload() { send(payload, to: index, of: session) }
        }
        if !session.isScheduled || !isLive(session.hub) {
            // Nobody takes commands off the queue: they are applied here.
            let top = root(of: session.hub)
            pause(top)
            settleDirectly(session)
            resume(top)
        }
        session.freeAppliedPayloads()
    }

    /// Queues the values of one kernel for the session's latest plan; `index` counts the
    /// kernels of its skeleton. The payload is freed once the command has been applied.
    private func send(_ payload: (pointer: UnsafeMutableRawPointer, count: Int), to index: Int, of session: SessionCore) {
        var command = ztd_command_t()
        command.target = UInt32(index)
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        command.count = UInt32(payload.count)
        command.values = UnsafeRawPointer(payload.pointer)
        command.flags = session.plan.generation
        let sequence = ztd_command_queue_push(session.runner.values, &command)
        if sequence != 0 {
            session.payloads.append((sequence, payload.pointer))
        } else {
            // The queue is full: the analysis thread is far behind. The value is applied
            // with the thread held off.
            let top = root(of: session.hub)
            pause(top)
            settleDirectly(session)
            session.plan.applyValues(&command)
            payload.pointer.deallocate()
            resume(top)
        }
    }

    // MARK: Sinks (ATT-5)

    /// Claims the sinks `plan` writes that the session does not hold, and prepares every sink
    /// whose branch is new for the frames it will get. A sink the running plan also writes,
    /// from another place, is taken from it first: a sink has one writer.
    ///
    /// `pending` is the plan on its way in that `plan` replaces (SWAP-4). It stays as it is
    /// until every sink of `plan` is prepared: what was claimed or prepared for it then goes
    /// over to `plan`, or is given back. When a sink refuses, nothing has changed hands, and
    /// what was touched is prepared again for the plan that will write it after all (§4.5).
    private func adoptSinks(
        of plan: ExecutionPlan, for session: SessionCore, replacing old: ExecutionPlan?, insteadOf pending: ExecutionPlan? = nil
    ) throws(DSPError) {
        var named = Set<ObjectIdentifier>()
        for entry in plan.sinks {
            guard let identity = entry.description.sink.identity else { continue }
            guard named.insert(identity).inserted else { throw DSPError.sinkInUse(sink: entry.description.sink.name) }
        }
        // What the session holds: the sinks of the running plan, less those an earlier update
        // has already given up …
        let held = Set(old?.sinks.compactMap { $0.description.sink.identity } ?? []).subtracting(session.releasedSinks)
        // … and, through the plan on its way in: sinks claimed for that plan alone, and sinks
        // of the running plan that were prepared for it.
        var pendingOnly = Set<ObjectIdentifier>(), pendingMoved = Set<ObjectIdentifier>()
        if let pending {
            for (index, entry) in pending.sinks.enumerated() {
                guard let identity = entry.description.sink.identity else { continue }
                if !held.contains(identity) {
                    pendingOnly.insert(identity)
                } else if pending.sinkSlots[index].isNewBranch {
                    pendingMoved.insert(identity)
                }
            }
        }
        let added = plan.sinks.compactMap { entry -> (identity: ObjectIdentifier, name: String)? in
            guard let identity = entry.description.sink.identity, !held.contains(identity), !pendingOnly.contains(identity) else { return nil }
            return (identity, entry.description.sink.name)
        }
        try SinkRegistry.claim(added)

        var moved: [ObjectIdentifier] = []
        for (index, entry) in plan.sinks.enumerated() {
            guard let identity = entry.description.sink.identity else { continue }
            // Prepared for frames this plan does not bring: for a plan that was withdrawn, for
            // nothing since an update gave it up, or for the plan this one replaces.
            if session.staleSinks.contains(identity) || session.releasedSinks.contains(identity) || pendingMoved.contains(identity) {
                plan.sinkSlots[index].isNewBranch = true
            }
            if held.contains(identity), plan.sinkSlots[index].isNewBranch { moved.append(identity) }
        }
        let dropped = (old?.sinks ?? []).compactMap { entry -> (sink: any PlanSink, identity: ObjectIdentifier?)? in
            guard let identity = entry.description.sink.identity, held.contains(identity), !named.contains(identity) else { return nil }
            return (entry.sink, identity)
        }
        // What was claimed for the plan on its way in alone, and this plan does not write.
        let orphaned = (pending?.sinks ?? []).compactMap { entry -> (sink: any PlanSink, identity: ObjectIdentifier?)? in
            guard let identity = entry.description.sink.identity, pendingOnly.contains(identity), !named.contains(identity) else { return nil }
            return (entry.sink, identity)
        }
        // The running plan must not write a sink while it is prepared for other frames or
        // handed to another writer: the hub is held off its thread for that long. (A plan on
        // its way in writes no sink: SWAP-2.)
        let top = root(of: session.hub)
        let holds = (!moved.isEmpty || !dropped.isEmpty) && session.isScheduled
        if holds { pause(top) }
        defer { if holds { resume(top) } }

        func retire(_ identities: Set<ObjectIdentifier>) {
            guard let old else { return }
            for (index, entry) in old.sinks.enumerated() {
                if let identity = entry.description.sink.identity, identities.contains(identity) { old.sinkSlots[index].isRetired = true }
            }
        }
        var prepared: [(any PlanSink, ObjectIdentifier?)] = []
        do throws(DSPError) {
            // A result slot is made anew with every plan, so it is prepared with every plan,
            // whether or not its branch is the one that fed the binding before (OUT-2).
            for (index, entry) in plan.sinks.enumerated()
            where plan.sinkSlots[index].isNewBranch || entry.description.sink.identity == nil {
                let position = entry.description.position
                try entry.sink.claim(axis: position.environment.frequencyAxis, environment: position.environment,
                                     domain: position.domain, format: position.format)
                entry.sink.connect(attention: attention)
                prepared.append((entry.sink, entry.description.sink.identity))
            }
        } catch {
            // A pipeline that cannot be attached leaves the session as it is. What was claimed
            // for this plan alone is given back. A sink of the session that was already
            // prepared for this plan is prepared again for the plan that writes it: the one on
            // its way in when it had been prepared for that one, the running plan otherwise.
            // Only a sink that refuses that is taken from its plan, to be prepared anew by the
            // next one.
            releaseSinks(prepared.filter { item in item.1.map { !held.contains($0) && !pendingOnly.contains($0) } ?? false })
            SinkRegistry.release(added.map(\.identity).filter { identity in !prepared.contains { $0.1 == identity } })
            let touched = Set(prepared.compactMap(\.1)).intersection(held.union(pendingOnly))
            func prepareAgain(_ entry: (sink: any PlanSink, description: IRSink)) -> Bool {
                let position = entry.description.position
                do throws(DSPError) {
                    try entry.sink.claim(axis: position.environment.frequencyAxis, environment: position.environment,
                                         domain: position.domain, format: position.format)
                    entry.sink.connect(attention: attention)
                    return true
                } catch {
                    return false
                }
            }
            var lost = Set<ObjectIdentifier>()
            if let pending {
                for (index, entry) in pending.sinks.enumerated() {
                    guard let identity = entry.description.sink.identity, touched.contains(identity),
                          pendingOnly.contains(identity) || pendingMoved.contains(identity) else { continue }
                    if !prepareAgain(entry) {
                        pending.sinkSlots[index].isRetired = true
                        session.staleSinks.insert(identity)
                    }
                }
            }
            for entry in old?.sinks ?? [] {
                guard let identity = entry.description.sink.identity, touched.contains(identity), !pendingMoved.contains(identity) else { continue }
                if !prepareAgain(entry) { lost.insert(identity) }
            }
            retire(lost)
            session.staleSinks.formUnion(lost)
            throw error
        }
        // From here on the plan will be published. The running plan stops writing what moved
        // and what went, and what went is free for another writer at once (ATT-5); so is what
        // only the plan that is replaced held.
        retire(Set(moved).union(dropped.compactMap(\.identity)))
        releaseSinks(dropped)
        releaseSinks(orphaned)
        session.releasedSinks.formUnion(dropped.compactMap(\.identity))
        session.releasedSinks.subtract(named)
        session.staleSinks.subtract(prepared.compactMap(\.1))
    }

    /// Ends the claim on sinks: they are no longer live, their attachment is over, and another
    /// attachment may write them.
    private func releaseSinks(_ sinks: [(sink: any PlanSink, identity: ObjectIdentifier?)]) {
        for entry in sinks {
            entry.sink.setLive(false)
            entry.sink.connect(attention: nil)
            entry.sink.release()
        }
        SinkRegistry.release(sinks.compactMap(\.identity))
    }

    // MARK: Re-planning (ATT-4)

    /// Compiles a session's pipeline again, for the format its hub has now. Stage state is
    /// reset. Only while the session is off its thread.
    private func recompile(_ session: SessionCore) {
        guard session.state != .detached else { return }
        settleDirectly(session)
        do throws(DSPError) {
            let lowered = try lower(session.stages, for: session.hub)
            let old = session.installedPlan
            // Bindings are read on the main actor only; the positions last seen there stand in.
            let values = lowered.switches.count == old.switchValues.count
                ? old.switchValues : [Bool](repeating: true, count: lowered.switches.count)
            session.generation += 1
            let plan = try ExecutionPlan(lowered: lowered, switchValues: values, crossovers: crossovers, generation: session.generation, previous: nil)
            for slot in old.sinkSlots { slot.isRetired = true }
            try adoptSinks(of: plan, for: session, replacing: old)
            plan.output = session.runner
            session.plan = plan
            session.runner.sampleRate = session.hub.format.sampleRate
            session.runner.needsOrigin = true
            session.runner.plans.publish(plan)
            session.runner.settle()
            _ = session.runner.takeEvents()
            session.installedPlan = plan
            session.releasedSinks = []
            session.board.install(generation: plan.generation, sinks: plan.sinks.map(\.sink), gates: plan.sinkGates, compiledValues: values)
            session.setEnvironment(SessionCore.environment(of: plan))
            session.runner.plans.drainRetired()
            session.freeAllPayloads()
            let pump = session.pump
            let rate = lowered.sourceEnvironment.resultRate
            DispatchQueue.main.async {
                pump.capture(switches: lowered.switches, compiledValues: values, results: lowered.results, slots: plan.resultSlots,
                             generation: plan.generation, resultRate: rate)
            }
            session.emit(.replanned(.formatChanged))
            if let derived = session.derivedHub {
                do throws(DSPError) { try adoptSource(derived) } catch { failStream(of: derived, error) }
            }
        } catch {
            fail(session, error)
        }
    }

    // MARK: Source events (§4.5)

    private func handle(_ event: SourceEvent, from hub: SourceHub) {
        guard hubs[ObjectIdentifier(hub.source)] === hub, hub.isPrepared else { return }
        switch event {
        case .formatChanged(let format):
            guard format != hub.format, hub.inner == nil else { return }
            replan(hub)
        case .interrupted:
            interrupt(hub)
        case .resumed:
            resumeAfterInterruption(hub)
        case .overrun(let frames):
            reportOverrun(frames, on: hub)
        case .ended:
            guard hub.isStarted else { return }
            if hub.isInterrupted {
                // Nothing is being delivered: there is nothing to wait for.
                finishStream(of: hub)
            } else {
                // What the ring still holds is delivered first; the hub says when it is through.
                hub.adapter?.endAfterDraining()
                driver(of: hub)?.wake()
            }
        case .failed(let error):
            failStream(of: hub, error)
        case .routeChanged, .mediaServicesReset:
            break
        }
    }

    /// Frames were dropped on their way into `hub` (RT-8): the sessions that run on it are
    /// told, and so is everything behind them. A session that feeds a processed source has
    /// lost those frames for that source too: the source says so on its own `events`, and the
    /// sessions attached to it hear it as the sessions here do, counted in the frames of the
    /// processed signal (as many as the frames lost would have become, and at least one).
    private func reportOverrun(_ frames: Int, on hub: SourceHub) {
        for session in hub.scheduled {
            session.emit(.overrun(droppedFrames: frames))
            guard frames > 0, let derived = session.derivedHub, derived.isPrepared else { continue }
            let scaled = (Double(frames) * derived.format.sampleRate / hub.format.sampleRate).rounded(.up)
            let lost = scaled < 9e18 ? max(Int(scaled), 1) : Int.max
            derived.processed?.send(.overrun(droppedFrames: lost))
            reportOverrun(lost, on: derived)
        }
    }

    /// Samples that were not finite arrived at `hub` and were replaced by zeros where they
    /// entered (NUM-1): the sessions that run on it are told, and so is every session behind
    /// them. A session attached to a processed source got those zeros with the processed
    /// signal, whatever the pipeline in front made of them; what it is told is what the
    /// event counts, the samples that were replaced at the source adapter, the same figure
    /// all the way down a chain of processed sources.
    private func reportNonFinite(_ count: Int, on hub: SourceHub) {
        for session in hub.scheduled {
            session.emit(.nonFiniteInput(count: count))
            if let derived = session.derivedHub, derived.isPrepared { reportNonFinite(count, on: derived) }
        }
    }

    /// The source delivers another format: a new adapter, and every session compiled again.
    private func replan(_ hub: SourceHub) {
        pause(hub)
        do throws(DSPError) {
            try adoptSource(hub)
        } catch {
            resume(hub)
            failStream(of: hub, error)
            return
        }
        resume(hub)
        // Sessions whose pipeline does not compile for the new format have failed; a source
        // that nobody listens to any more is stopped.
        if hub.isStarted, hub.scheduled.isEmpty { stopSource(hub) }
    }

    private func interrupt(_ hub: SourceHub) {
        guard hub.isStarted, !hub.isInterrupted else { return }
        hub.isInterrupted = true
        commit(hub)
        for session in hub.sessions where session.state == .running {
            session.setState(.interrupted)
            session.board.setRunning(false)
            // Bindings are read and written while a session runs (BIND-2): not while it waits.
            setPumpRunning(session, false)
            innerStateChanged(session)
        }
    }

    private func resumeAfterInterruption(_ hub: SourceHub) {
        guard hub.isStarted, hub.isInterrupted else { return }
        // Stages start cold, and what arrived before the interruption is not part of what follows.
        hub.adapter?.discardPending()
        for session in hub.scheduled { coldStart(session) }
        hub.isInterrupted = false
        hub.epoch += 1
        commit(hub)
        for session in hub.sessions where session.state == .interrupted {
            session.setState(.running)
            session.board.setRunning(true)
            setPumpRunning(session, true)
            innerStateChanged(session)
        }
    }

    /// The stream is over: the sessions that ran have finished, and the source is stopped.
    private func finishStream(of hub: SourceHub) {
        var ended: [SessionCore] = []
        for session in hub.sessions {
            switch session.state {
            case .running, .interrupted:
                session.isScheduled = false
                ended.append(session)
            default:
                break
            }
        }
        stopSource(hub)
        hub.streamOver = true
        for session in ended {
            settleDirectly(session)
            session.board.setRunning(false)
            setPumpRunning(session, false)
            session.setState(.finished)
            innerStateChanged(session)
        }
        hub.processed?.send(.ended)
    }

    /// The source cannot go on: every session that could still have run has failed.
    private func failStream(of hub: SourceHub, _ error: DSPError) {
        var failed: [SessionCore] = []
        for session in hub.sessions {
            switch session.state {
            case .idle, .running, .interrupted:
                session.isScheduled = false
                failed.append(session)
            default:
                break
            }
        }
        stopSource(hub)
        hub.streamOver = true
        for session in failed {
            settleDirectly(session)
            session.board.setRunning(false)
            setPumpRunning(session, false)
            session.setState(.failed(error))
            innerStateChanged(session)
        }
        hub.processed?.send(.failed(error))
    }

    /// One session cannot go on: its plan could not be compiled for a new format.
    private func fail(_ session: SessionCore, _ error: DSPError) {
        let wasScheduled = session.isScheduled
        session.isScheduled = false
        session.board.setRunning(false)
        setPumpRunning(session, false)
        session.setState(.failed(error))
        innerStateChanged(session)
        if wasScheduled, session.hub.scheduled.isEmpty, session.hub.pauseDepth == 0 { stopSource(session.hub) }
    }

    /// A session that feeds a processed source changed state: to the sessions attached to that
    /// source, this is what their source did.
    private func innerStateChanged(_ session: SessionCore) {
        guard let derived = session.derivedHub, derived.isPrepared else { return }
        switch session.state {
        case .interrupted:
            interrupt(derived)
            derived.processed?.send(.interrupted)
        case .running where derived.isInterrupted:
            resumeAfterInterruption(derived)
            derived.processed?.send(.resumed)
        case .finished:
            finishStream(of: derived)
        case .failed(let error):
            failStream(of: derived, error)
        case .running, .idle, .detached:
            break
        }
    }

    // MARK: Service

    /// The control context's turn after the analysis side asked for attention: a stream that
    /// ended, an exchange that was carried out, frames that were dropped or replaced, a sink
    /// with something to hand on.
    func service() {
        for hub in Array(hubs.values) { service(hub) }
    }

    private func service(_ hub: SourceHub) {
        // What happened to the samples is told to the sessions that got them, before a stream
        // that ended takes those sessions out of what runs.
        if let adapter = hub.adapter {
            let dropped = adapter.droppedFrames, replaced = adapter.nonFiniteCount
            if dropped > hub.lastDropped { reportOverrun(dropped - hub.lastDropped, on: hub) }
            if replaced > hub.lastNonFinite { reportNonFinite(replaced - hub.lastNonFinite, on: hub) }
            hub.lastDropped = dropped
            hub.lastNonFinite = replaced
        }
        // The end of a stream counts only for the stream that runs now: after a re-plan the
        // old stream's end is history (ATT-4).
        if hub.runner.takeEnded() == hub.epoch, hub.isStarted, hub.inner == nil {
            let now = hub.source.format
            // A pull source ends the stream of its old format and goes on in the new one (ATT-4).
            if now.isValid, now != hub.format { replan(hub) } else { finishStream(of: hub) }
        }
        for session in hub.sessions {
            bookExchange(of: session)
            session.freeAppliedPayloads()
            for entry in session.installedPlan.sinks { entry.sink.service() }
        }
    }

    // MARK: Memory pressure (MEM-1)

    private func startWatchingMemory() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: control.queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.respond(to: source.data.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        pressure = source
    }

    /// On a warning: the plans waiting to be destroyed are destroyed, and nothing else. On a
    /// critical event: every feed that was created with a smaller minimum history also drops
    /// its oldest columns. A running plan is never altered.
    func respond(to level: MemoryPressureLevel) {
        for hub in hubs.values {
            hub.runner.stage.drainRetired()
            for session in hub.sessions {
                session.runner.plans.drainRetired()
                session.runner.consumers.drainRetired()
                session.freeAppliedPayloads()
                if level == .critical {
                    for entry in session.installedPlan.sinks { _ = entry.sink.trimForMemoryPressure() }
                }
                session.emit(.memoryPressure(level))
            }
        }
        analysis?.schedule.drainRetired()
    }

    // MARK: An engine driven by hand

    /// Runs one turn of every hub on the calling thread, then the control context's service.
    /// For an engine without threads; a test calls it instead of waiting for a clock.
    func runTurn(now: Double? = nil) {
        precondition(isManual, "runTurn drives an engine that has no thread")
        let time = now ?? clock.now
        let runners = (try? control.sync { hubs.values.filter { $0.inner == nil }.map(\.runner) }) ?? []
        for runner in runners { _ = runner.turn(now: time) }
        if let attention, ztd_atomic_exchange(attention, 0) != 0 { try? control.sync { service() } }
    }

    /// The runners of the hubs that are fed by a source: what an audited loop turns by hand.
    func rootRunners() -> [HubRunner] {
        (try? control.sync { hubs.values.filter { $0.inner == nil }.map(\.runner) }) ?? []
    }

    /// Adds a consumer of a session's main-line output: what a test listens with.
    func addProbe(_ probe: any MainLineConsumer, to session: SessionCore) {
        try? control.sync {
            session.probes.append(probe)
            let top = root(of: session.hub)
            pause(top)
            var consumers = session.probes
            if let derived = session.derivedHub { consumers.insert(derived.runner, at: 0) }
            session.runner.consumers.publish(ConsumerList(consumers))
            session.runner.consumers.refresh()
            session.runner.consumers.drainRetired()
            resume(top)
        }
    }

    /// The thread counters a test of parking and pacing reads.
    var analysisThread: RunnerThread? {
        (try? control.sync { analysis }) ?? nil
    }

    /// Waits until the control context has done everything that was asked of it so far.
    func flush() {
        try? control.sync {}
    }
}
