import CoreFoundation
import Foundation

/// Which sinks of a session are live (ACT-11): the session runs, and every switch between
/// the sink and the source is on. Both halves are known off the analysis thread, the state on
/// the control context and the switches on the main thread, so this board is what tells a
/// feed, and through it a view's display link, without the analysis thread waking anyone.
///
/// Threading: any thread but the analysis thread; guarded by a lock.
final class LivenessBoard: Sendable {
    private struct State {
        var isRunning = false
        var generation: UInt32 = 0
        var values: [Bool] = []
        var sinks: [any PlanSink] = []
        var gates: [[Int]] = []
    }

    private let state = Locked(State())

    /// The session started or stopped running.
    func setRunning(_ running: Bool) {
        state.withLock { state in
            state.isRunning = running
            LivenessBoard.publish(state)
        }
    }

    /// A plan took over: these are its sinks, the switches each depends on, and the switch
    /// positions it was compiled with. Positions the main thread has reported for this
    /// generation since are newer and are kept.
    func install(generation: UInt32, sinks: [any PlanSink], gates: [[Int]], compiledValues: [Bool]) {
        state.withLock { state in
            let dropped = state.sinks.filter { old in !sinks.contains { $0 === old } }
            for sink in dropped { sink.setLive(false) }
            if state.generation != generation || state.values.count != compiledValues.count {
                state.generation = generation
                state.values = compiledValues
            }
            state.sinks = sinks
            state.gates = gates
            LivenessBoard.publish(state)
        }
    }

    /// The main thread saw the switches of `generation` at these positions.
    func setValues(_ values: [Bool], generation: UInt32) {
        state.withLock { state in
            state.generation = generation
            state.values = values
            LivenessBoard.publish(state)
        }
    }

    /// The session is gone: nothing is live.
    func clear() {
        state.withLock { state in
            for sink in state.sinks { sink.setLive(false) }
            state = State()
        }
    }

    private static func publish(_ state: State) {
        for (index, sink) in state.sinks.enumerated() {
            let gates = index < state.gates.count ? state.gates[index] : []
            let open = gates.allSatisfy { $0 < state.values.count ? state.values[$0] : true }
            sink.setLive(state.isRunning && open)
        }
    }
}

/// How a session reads its bound switches and writes its bound results (§5.9, §5.10).
///
/// While the session runs and its pipeline has a bound switch or a bound result, the pump
/// keeps one observer on the main run loop, before waiting, in the common modes. On each pass
/// it reads every captured switch and sends a command for each value that changed, so a write
/// made on the main thread is forwarded in the same turn of the loop, and an idle loop does no
/// work (BIND-2). A heartbeat timer at the result rate exists only while there are bound
/// results; on each beat the pump copies every result that changed into its binding, at most
/// once per beat and never with a value equal to the last one written (OUT-2, OUT-3).
///
/// A binding is read and written here and nowhere else (BIND-1). The pump never writes a
/// switch (BIND-5).
@MainActor
final class BindingPump {
    /// The queue of switch commands; this pump, on the main thread, is its one producer.
    private nonisolated(unsafe) let commands: OpaquePointer
    private let runner: SessionRunner
    private let board: LivenessBoard

    private var switches: [BoundSwitch] = []
    private var sent: [Bool] = []
    private var results: [BoundResult] = []
    private var slots: [ResultSlot] = []
    private var seen: [UInt64] = []
    private var lastScalars: [ScalarFrame?] = []
    private var lastVectors: [[Float]?] = []
    private var generation: UInt32 = 0
    private var resultRate = 30.0
    private var isRunning = false
    /// Set by `release()` for good: a detached session captures nothing more, whatever
    /// update was still on its way when it was detached.
    private var isReleased = false

    private let hooks = RunLoopHooks()
    private var observer: CFRunLoopObserver? {
        get { hooks.observer }
        set { hooks.observer = newValue }
    }
    private var timer: CFRunLoopTimer? {
        get { hooks.timer }
        set { hooks.timer = newValue }
    }

    /// Passes of the observer and deliveries of the timer: what the tests of BIND-2 and OUT-2
    /// count.
    private(set) var passes = 0
    private(set) var beats = 0
    private(set) var commandsSent = 0

    nonisolated init(runner: SessionRunner, board: LivenessBoard) {
        self.runner = runner
        self.commands = runner.switches
        self.board = board
    }

    /// True while the pump keeps an observer on the main run loop.
    var isObserving: Bool { observer != nil }
    /// True while the heartbeat timer exists.
    var hasHeartbeat: Bool { timer != nil }

    // MARK: Capture (BIND-4, BIND-6)

    /// Takes the bindings of a plan that was just published and lets go of the ones captured
    /// before. `compiledValues` are the switch positions the plan was compiled with; a switch
    /// that has moved since is forwarded at once.
    func capture(
        switches: [BoundSwitch], compiledValues: [Bool], results: [BoundResult], slots: [ResultSlot], generation: UInt32,
        resultRate: Double
    ) {
        guard !isReleased else { return }
        self.switches = switches
        self.sent = compiledValues
        self.results = results
        self.slots = slots
        self.seen = [UInt64](repeating: 0, count: slots.count)
        self.lastScalars = [ScalarFrame?](repeating: nil, count: slots.count)
        self.lastVectors = [[Float]?](repeating: nil, count: slots.count)
        self.generation = generation
        self.resultRate = resultRate
        board.setValues(compiledValues, generation: generation)
        reschedule()
        if isRunning { sample() }
    }

    /// Takes the bindings of a pipeline equal to the running one, or of one that differs from
    /// it in values only: the plan, its switches and its result slots stay.
    func recapture(switches: [BoundSwitch], results: [BoundResult], resultRate: Double) {
        guard !isReleased, switches.count == self.switches.count, results.count == self.results.count else { return }
        self.switches = switches
        self.results = results
        if resultRate != self.resultRate {
            self.resultRate = resultRate
            reschedule()
        }
        if isRunning { sample() }
    }

    /// Lets go of every binding (BIND-6).
    func release() {
        isReleased = true
        switches = []
        sent = []
        results = []
        slots = []
        seen = []
        lastScalars = []
        lastVectors = []
        isRunning = false
        reschedule()
    }

    /// The session started or stopped running.
    func setRunning(_ running: Bool) {
        guard !isReleased, running != isRunning else { return }
        isRunning = running
        reschedule()
        if running { sample() }
    }

    // MARK: Switches

    /// Reads every captured switch and sends a command for each value that changed (BIND-2).
    func sample() {
        passes += 1
        var changed = false
        var index = 0
        while index < switches.count {
            let value = switches[index].read()
            if value != sent[index] {
                var command = ztd_command_t()
                command.target = UInt32(index)
                command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
                command.flags = generation
                command.scalar.0 = value ? 1 : 0
                // A full queue refuses the command; the value stays unsent and is tried again
                // on the next pass.
                if ztd_command_queue_push(commands, &command) != 0 {
                    sent[index] = value
                    commandsSent += 1
                    changed = true
                }
            }
            index += 1
        }
        if changed { board.setValues(sent, generation: generation) }
    }

    // MARK: Results

    /// Copies every result that changed into its binding (OUT-2, OUT-3).
    func deliver() {
        beats += 1
        // The slots belong to one plan; until that plan runs, they hold nothing to deliver.
        guard runner.installedGeneration == generation else { return }
        var index = 0
        while index < slots.count {
            let slot = slots[index]
            let writes = slot.writes
            if writes != seen[index], writes > 0 {
                switch results[index].kind {
                case .value, .frame:
                    let value = slot.readScalar()
                    let changed = results[index].kind == .value ? value.value != lastScalars[index]?.value : value != lastScalars[index]
                    if changed {
                        lastScalars[index] = value
                        results[index].write(value)
                    }
                    seen[index] = writes
                case .vector:
                    if let values = slot.readVector() {
                        if values != lastVectors[index] {
                            lastVectors[index] = values
                            results[index].write(values)
                        }
                        seen[index] = writes
                    }
                }
            }
            index += 1
        }
    }

    // MARK: The run loop

    /// Installs or removes the observer and the timer so that each exists exactly while it
    /// has something to do.
    private func reschedule() {
        let wantsObserver = isRunning && (!switches.isEmpty || !results.isEmpty)
        if wantsObserver, observer == nil {
            let created = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
            observer = created
        } else if !wantsObserver, let existing = observer {
            CFRunLoopObserverInvalidate(existing)
            observer = nil
        }

        if let existing = timer {
            CFRunLoopTimerInvalidate(existing)
            timer = nil
        }
        if isRunning, !results.isEmpty {
            let interval = 1 / min(max(resultRate, 1), 1_000)
            let created = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0) { [weak self] _ in
                MainActor.assumeIsolated { self?.deliver() }
            }
            CFRunLoopAddTimer(CFRunLoopGetMain(), created, .commonModes)
            timer = created
        }
    }
}

/// The pump's observer and timer, held apart so that they are taken off the run loop whenever
/// the pump goes away, on whatever thread that happens.
private final class RunLoopHooks: @unchecked Sendable {
    var observer: CFRunLoopObserver?
    var timer: CFRunLoopTimer?

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        if let timer { CFRunLoopTimerInvalidate(timer) }
    }
}
