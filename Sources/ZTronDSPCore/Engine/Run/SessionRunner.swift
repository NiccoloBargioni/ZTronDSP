// The analysis-thread side of one attachment: it runs the session's plan on each block, applies
// what the control context and the main thread sent since the last block, and carries out a
// plan exchange (§5.5.4). Nothing here allocates, locks or logs (RT-2).

/// Who takes the main-line output of a session, as one immutable list handed over whole.
final class ConsumerList {
    let consumers: [any MainLineConsumer]

    init(_ consumers: [any MainLineConsumer]) {
        self.consumers = consumers
    }
}

final class SessionRunner: PlanOutput, @unchecked Sendable {
    /// Where a plan exchange stands.
    enum Phase: UInt64 {
        /// One plan runs.
        case steady = 0
        /// The new part of a new plan runs beside the old plan, its output discarded (SWAP-2).
        case prerolling = 1
        /// Old and new output are cross-faded.
        case fading = 2
    }

    // From the control context.
    let plans: Handoff<ExecutionPlan>
    let consumers: Handoff<ConsumerList>
    /// Value changes. One producer: the control context.
    let values: OpaquePointer
    /// Switch changes. One producer: the main thread (BIND-2).
    let switches: OpaquePointer

    // To the control context: single atomic words (RT-4).
    private let installed: OpaquePointer
    private let phaseWord: OpaquePointer
    private let happened: OpaquePointer
    /// The engine's attention word (not owned).
    private let attention: OpaquePointer

    /// What the runner says of an exchange it carried out, as bits: read by the control
    /// context when it books the exchange.
    static let outputChanged: UInt64 = 2

    // Set by the control context while the runner is off its thread.
    var sampleRate = 48_000.0
    /// The next block is the session's first: its clock starts there (§5.2).
    var needsOrigin = true

    // Analysis thread.
    private var current: ExecutionPlan?
    private var incoming: ExecutionPlan?
    private var phase = Phase.steady
    private var prerollLeft = 0
    private var fadeLength = 1
    private var fadePosition = 0
    private var stashed = 0
    private var origin = 0

    init(attention: OpaquePointer) throws(DSPError) {
        // The hand-overs free themselves; the cells and the queues are freed here when one of
        // them cannot be had, so a runner that is not made leaves nothing behind.
        let plans = try Handoff<ExecutionPlan>()
        let consumers = try Handoff<ConsumerList>()
        guard let cells = AtomicCells.make([0, 0, 0]) else {
            throw .resourceAllocationFailed(what: "the run-time half of a session")
        }
        guard let values = ztd_command_queue_create(256) else {
            AtomicCells.destroy(cells)
            throw .resourceAllocationFailed(what: "the run-time half of a session")
        }
        guard let switches = ztd_command_queue_create(256) else {
            AtomicCells.destroy(cells)
            ztd_command_queue_destroy(values)
            throw .resourceAllocationFailed(what: "the run-time half of a session")
        }
        self.plans = plans
        self.consumers = consumers
        installed = cells[0]
        phaseWord = cells[1]
        happened = cells[2]
        self.values = values
        self.switches = switches
        self.attention = attention
    }

    deinit {
        ztd_atomic_destroy(installed)
        ztd_atomic_destroy(phaseWord)
        ztd_atomic_destroy(happened)
        ztd_command_queue_destroy(values)
        ztd_command_queue_destroy(switches)
    }

    // MARK: Control context

    /// The generation of the plan that runs; 0 before the first.
    var installedGeneration: UInt32 { UInt32(truncatingIfNeeded: ztd_atomic_load(installed)) }

    /// True while a plan exchange is in flight.
    var isInTransition: Bool { ztd_atomic_load(phaseWord) != Phase.steady.rawValue }

    /// What the runner said of the exchanges it carried out since the last call, as bits. It
    /// is said before the generation of the plan shows (`install`), so whoever reads the
    /// generation first and this afterwards has all of it.
    func takeEvents() -> UInt64 {
        ztd_atomic_exchange(happened, 0)
    }

    /// True while the plan on its way in is being faded in: it is heard already, and can no
    /// longer be dropped without a click (CR-015, item 5).
    var isFading: Bool { ztd_atomic_load(phaseWord) == Phase.fading.rawValue }

    /// Does at once what the analysis thread would do over the coming blocks: takes a
    /// published plan and finishes an exchange in flight, without pre-roll and without a
    /// fade. For a session that is not running, where nothing can be heard.
    /// Control context, and only while no thread runs this session.
    func settle() {
        // What is queued reaches the plans it was made for before they are replaced (SWAP-4).
        let next = plans.take()
        drain(values, next)
        drain(switches, next)
        if let incoming { complete(incoming, outputChanged: false) }
        if let next { install(next, outputChanged: false) }
        consumers.refresh()
    }

    /// Lets a plan that is being faded in take over at once (CR-015, item 5). One that is
    /// still pre-rolled stays where it is.
    /// Control context, and only while no thread runs this session.
    func finishFade() {
        guard phase == .fading, let pending = incoming else { return }
        complete(pending, outputChanged: false)
    }

    /// Takes the plan on its way in out of the way for good, because a newer one replaces it
    /// (SWAP-4): the plan that is being pre-rolled, or `withdrawn`, which this runner had not
    /// taken yet. What was sent to it since the last block is applied to it first, so a kernel
    /// it shares with the plan that runs holds those values, as the next plan expects.
    /// Control context, and only while no thread runs this session; not while a plan is
    /// being faded in.
    func drop(_ withdrawn: ExecutionPlan?) {
        drain(values, withdrawn)
        drain(switches, withdrawn)
        guard let pending = incoming else { return }
        current?.shadow = nil
        pending.isShadow = false
        incoming = nil
        setPhase(.steady)
        plans.discard(pending)
    }

    // MARK: Analysis thread

    /// Runs one block of the source through the session.
    func run(_ block: FrameView) {
        boundary()
        guard let plan = current, let samples = block.samples else { return }
        if needsOrigin {
            origin = block.index
            needsOrigin = false
        }
        let index = block.index &- origin
        // The session's clock starts with its first block. What the hub's own clock is ahead of
        // or behind its frame count, the latency of a pipeline in front of a processed source,
        // stays in the time (§5.2).
        let offset = block.time - Double(block.index) / sampleRate
        plan.process(FrameView(samples: samples, index: index, time: Double(index) / sampleRate + offset))
        advance(block.count)
    }

    /// The block boundary: where a new plan, new values and new switch positions take effect.
    ///
    /// What was sent since the last block is applied before a new plan takes the place of the
    /// plan it was sent to: a value for the running plan reaches the kernel, and with it the
    /// plan that takes that kernel over at this very boundary (SWAP-4).
    @inline(__always)
    private func boundary() {
        var next: ExecutionPlan?
        if incoming == nil { next = plans.take() }
        drain(values, next)
        drain(switches, next)
        if let next { accept(next) }
        if let list = consumers.refresh() {
            var index = 0
            while index < list.consumers.count {
                list.consumers[index].boundary()
                index += 1
            }
        }
    }

    private func accept(_ next: ExecutionPlan) {
        guard let old = current, let transition = next.transition, !transition.mainLineUnchanged else {
            // The first plan, or one whose main line is the running one: nothing to settle.
            install(next, outputChanged: false)
            return
        }
        // Everything read of the plan here is a constant of it: its description is the control
        // context's, and may be replaced while the plan is on its way in (RT-4).
        let preroll = transition.prerollFrames
        guard preroll > 0 || transition.crossfades else {
            install(next, outputChanged: true)
            return
        }
        incoming = next
        next.isShadow = true
        old.shadow = next
        old.shadowStep = transition.oldStep
        old.shadowStart = transition.newStep
        old.shadowKernel = transition.kernel
        old.shadowStartKernel = transition.newKernel
        prerollLeft = preroll
        fadeLength = next.fadeLength
        fadePosition = 0
        setPhase(preroll > 0 ? .prerolling : .fading)
    }

    @inline(__always)
    private func advance(_ frames: Int) {
        switch phase {
        case .steady:
            break
        case .prerolling:
            prerollLeft -= frames
            guard prerollLeft <= 0, let next = incoming else { return }
            if next.transition?.crossfades == true, next.fade != nil {
                fadePosition = 0
                setPhase(.fading)
            } else {
                complete(next, outputChanged: true)
            }
        case .fading:
            fadePosition += frames
            if fadePosition >= fadeLength, let next = incoming { complete(next, outputChanged: false) }
        }
    }

    private func complete(_ next: ExecutionPlan, outputChanged: Bool) {
        current?.shadow = nil
        next.isShadow = false
        incoming = nil
        setPhase(.steady)
        install(next, outputChanged: outputChanged)
    }

    private func install(_ plan: ExecutionPlan, outputChanged: Bool) {
        // The runner lets go of the old plan before the slot retires it, so the last reference
        // to it is always dropped on the control context (RT-3).
        current = plan
        plans.install(plan)
        // A sink whose branch is not the one that fed it before holds stale frames (SWAP-3).
        var index = 0
        while index < plan.sinkSlots.count {
            let slot = plan.sinkSlots[index]
            if slot.isNewBranch {
                slot.sink.clearForNewBranch()
                slot.isNewBranch = false
            }
            index += 1
        }
        // What there is to say of the exchange first, the generation that shows it after: the
        // control context books an exchange when it sees the generation, whoever calls it to
        // (the service, the next update, a stop), and must find what was said with it (SWAP-2).
        if outputChanged {
            var seen = ztd_atomic_load(happened)
            while !ztd_atomic_compare_exchange(happened, seen, seen | SessionRunner.outputChanged) { seen = ztd_atomic_load(happened) }
        }
        ztd_atomic_store(installed, UInt64(plan.generation))
        ztd_atomic_store(attention, 1)
    }

    @inline(__always)
    private func setPhase(_ next: Phase) {
        phase = next
        ztd_atomic_store(phaseWord, next.rawValue)
    }

    // MARK: Commands

    /// Applies every queued command. `pending` is a plan that was published and has not been
    /// accepted yet.
    @inline(__always)
    private func drain(_ queue: OpaquePointer, _ pending: ExecutionPlan?) {
        var command = ztd_command_t()
        var last: UInt64 = 0
        while ztd_command_queue_pop(queue, &command) {
            apply(&command, pending)
            last = command.sequence
        }
        if last != 0 { ztd_command_queue_acknowledge(queue, last) }
    }

    /// A command names the generation of the plan it was made for in `flags`: it reaches that
    /// plan whether it runs, is on its way in or is about to be accepted, and no other
    /// (SWAP-4).
    private func apply(_ command: inout ztd_command_t, _ pending: ExecutionPlan?) {
        let plan: ExecutionPlan
        if let running = current, running.generation == command.flags {
            plan = running
        } else if let next = incoming, next.generation == command.flags {
            plan = next
        } else if let pending, pending.generation == command.flags {
            plan = pending
        } else {
            return
        }
        if command.kind == UInt32(ZTD_COMMAND_SET_ACTIVE) {
            plan.setSwitch(Int(command.target), command.scalar.0 != 0)
        } else {
            plan.applyValues(&command)
        }
    }

    // MARK: PlanOutput

    func take(_ frame: FrameView) {
        guard let list = consumers.installed, !list.consumers.isEmpty else { return }
        var output = frame
        if phase == .fading, stashed > 0, let mixed = crossfade(frame) { output = mixed }
        stashed = 0
        var index = 0
        while index < list.consumers.count {
            list.consumers[index].consume(output)
            index += 1
        }
    }

    /// The new plan's block, kept until the old plan's block of the same input arrives.
    func takeShadow(_ frame: FrameView) {
        guard phase == .fading, let buffer = incoming?.fade, let block = frame.samples else { return }
        var target = buffer.block()
        stashed = target.copy(from: block)
    }

    /// Old output moving into new output, linearly, over the length of the fade.
    private func crossfade(_ old: FrameView) -> FrameView? {
        guard let buffer = incoming?.fade, let block = old.samples, block.frameCount == stashed else { return nil }
        let step = 1 / Float(fadeLength)
        var channel = 0
        while channel < min(block.channelCount, buffer.channelCount) {
            let fresh = buffer.channel(channel), stale = block.channel(channel)
            var gain = Float(fadePosition) * step
            var index = 0
            while index < stashed {
                let weight = min(gain, 1)
                fresh[index] = stale[index] + weight * (fresh[index] - stale[index])
                gain += step
                index += 1
            }
            channel += 1
        }
        return FrameView(samples: buffer.block(frameCount: stashed), index: old.index, time: old.time)
    }
}
