import Foundation

/// The time an analysis loop paces itself with: the monotonic clock, or a clock a test holds.
protocol AnalysisClock: Sendable {
    /// Seconds on a monotonic clock.
    var now: Double { get }
    /// Returns once the clock reads `deadline`.
    func sleep(until deadline: Double)
}

/// The monotonic clock of the machine.
struct MachClock: AnalysisClock {
    var now: Double { ztd_thread_now() }

    func sleep(until deadline: Double) {
        ztd_thread_sleep_until(deadline)
    }
}

/// The hubs one thread runs, as one immutable list handed over whole (RT-4).
final class HubList {
    let hubs: [HubRunner]
    /// Seconds between two looks at a ring: the period asked of the scheduler (RT-9).
    let interval: Double

    init(hubs: [HubRunner], interval: Double) {
        self.hubs = hubs
        self.interval = interval
    }
}

/// How an analysis thread is scheduled (RT-9).
public enum AnalysisScheduling: Sendable, Hashable {
    /// No session has run yet: the thread does not exist.
    case notStarted
    /// The thread runs under a Mach time-constraint policy whose period is its poll interval.
    case timeConstrained
    /// The system refused the time-constraint policy. The thread keeps its user-interactive
    /// quality of service.
    case qualityOfServiceOnly
}

/// A thread that runs hubs (§4.3): the engine's one analysis thread, or the thread of its own
/// that an `.asFastAsPossible` source gets so that it cannot starve a live session.
///
/// The analysis thread wakes by polling: it runs every hub, then sleeps until the earliest
/// deadline a hub named, and never for less than a millisecond. While no hub has anything to
/// do it is parked and causes no wake-up at all.
///
/// Threading: `start`, `stop`, `wake` and `schedule.publish` belong to the control context.
/// `turn` is the body of the loop; it runs on the thread, or on a test's thread when the
/// engine is driven by hand.
final class RunnerThread: @unchecked Sendable {
    enum Role {
        /// User-interactive, time-constrained, polling.
        case analysis
        /// Utility, free-running.
        case offline
    }

    let role: Role
    let schedule: Handoff<HubList>
    private let clock: any AnalysisClock
    /// The engine's attention word: non-zero when the control context has something to do.
    private let attention: OpaquePointer
    private let notify: @Sendable () -> Void
    private let parker: OpaquePointer
    private let quit: OpaquePointer
    private let turns: OpaquePointer
    private let policy: OpaquePointer
    private let exited: OpaquePointer
    private let guardLock = UnfairLock()
    private var thread: Thread?
    /// True on the thread of its own: a test that drives `turn` by hand keeps its scheduling.
    private var ownsThread = false
    /// The poll interval the scheduling policy was last asked for; -1 before the first.
    private var appliedInterval = -1.0

    init(role: Role, clock: any AnalysisClock, attention: OpaquePointer, notify: @escaping @Sendable () -> Void) throws(DSPError) {
        // The hand-over frees itself; the parker and the cells are made all or none, so a
        // thread that cannot be made leaves nothing behind.
        schedule = try Handoff<HubList>()
        guard let parker = ztd_parker_create() else { throw .resourceAllocationFailed(what: "an analysis thread") }
        guard let cells = AtomicCells.make([0, 0, 0, 1]) else {
            ztd_parker_destroy(parker)
            throw .resourceAllocationFailed(what: "an analysis thread")
        }
        self.role = role
        self.clock = clock
        self.attention = attention
        self.notify = notify
        self.parker = parker
        quit = cells[0]
        turns = cells[1]
        policy = cells[2]
        exited = cells[3]
    }

    deinit {
        ztd_parker_destroy(parker)
        ztd_atomic_destroy(quit)
        ztd_atomic_destroy(turns)
        ztd_atomic_destroy(policy)
        ztd_atomic_destroy(exited)
    }

    // MARK: Control context

    /// Creates the thread. Does nothing when it already runs.
    func start() {
        guardLock.withLock {
            guard thread == nil else { return }
            ztd_atomic_store(quit, 0)
            ztd_atomic_store(exited, 0)
            let created = Thread { [self] in
                run()
                ztd_atomic_store(exited, 1)
            }
            created.name = role == .analysis ? "com.zombietron.ztrondsp.analysis" : "com.zombietron.ztrondsp.offline"
            created.qualityOfService = role == .analysis ? .userInteractive : .utility
            thread = created
            created.start()
        }
    }

    /// Ends the thread and waits until it is gone. Does nothing when it does not run.
    func stop() {
        guardLock.withLock {
            guard thread != nil else { return }
            ztd_atomic_store(quit, 1)
            ztd_parker_unpark(parker)
            ControlWait.until { ztd_atomic_load(exited) != 0 }
            thread = nil
        }
    }

    /// True while the thread exists.
    var isRunning: Bool {
        guardLock.withLock { thread != nil }
    }

    /// Lets a parked thread look at what was published for it.
    func wake() {
        ztd_parker_unpark(parker)
    }

    /// Passes of the loop so far.
    var turnCount: UInt64 { ztd_atomic_load(turns) }

    /// Times the thread has parked.
    var parkCount: UInt64 { ztd_parker_park_count(parker) }

    var scheduling: AnalysisScheduling {
        switch ztd_atomic_load(policy) {
        case 1: .timeConstrained
        case 2: .qualityOfServiceOnly
        default: .notStarted
        }
    }

    // MARK: The loop

    private func run() {
        ownsThread = true
        while ztd_atomic_load(quit) == 0 {
            if let deadline = turn() {
                if deadline > clock.now { clock.sleep(until: deadline) }
            } else {
                ztd_parker_park(parker)
            }
        }
        if role == .analysis { ztd_thread_clear_time_constraint() }
    }

    /// One pass: takes a new list of hubs when there is one, runs every hub, and returns the
    /// time to sleep until, or `nil` when no hub has anything to do and the thread parks.
    func turn() -> Double? {
        _ = ztd_atomic_add(turns, 1)
        // No reference to the old list is held across the hand-over (RT-3); a new list is
        // known by what it asks of the scheduler.
        let list = schedule.refresh()
        let wanted = (list?.hubs.isEmpty ?? true) ? 0 : (list?.interval ?? 0)
        if wanted != appliedInterval {
            appliedInterval = wanted
            applyPolicy(list)
        }
        guard let list, !list.hubs.isEmpty else { return nil }

        let now = clock.now
        var deadline = Double.infinity
        var index = 0
        while index < list.hubs.count {
            let next = list.hubs[index].turn(now: now)
            if next < deadline { deadline = next }
            index += 1
        }
        // The control context is woken between turns, never inside one, and only when a hub or
        // a session left it something to do.
        if ztd_atomic_exchange(attention, 0) != 0 { notify() }
        guard deadline < .infinity else { return nil }
        // Polling never comes round in less than a millisecond (§4.3).
        return role == .analysis ? max(deadline, now + 0.001) : deadline
    }

    /// Asks for the time-constraint policy that fits the list's poll interval (RT-9).
    private func applyPolicy(_ list: HubList?) {
        guard role == .analysis, ownsThread else { return }
        guard let list, !list.hubs.isEmpty, list.interval > 0 else {
            ztd_thread_clear_time_constraint()
            return
        }
        // Half the interval for the work of a turn, within what the scheduler grants at all
        // (between 50 µs and 50 ms, WP-226): a long block does not need more, and a request
        // for more would be refused whole.
        let computation = min(max(list.interval * 0.5, 0.000_05), 0.05)
        let granted = ztd_thread_set_time_constraint(list.interval, computation, max(list.interval, computation))
        // A refusal leaves whatever was in force before. A policy made for another interval is
        // not what the report "quality of service only" describes: it is ended, and the thread
        // runs at the priority it had before any policy (RT-9).
        if !granted { ztd_thread_clear_time_constraint() }
        ztd_atomic_store(policy, granted ? 1 : 2)
    }
}
