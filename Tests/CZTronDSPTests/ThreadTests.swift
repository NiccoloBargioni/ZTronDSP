import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// What the kernel says about the calling thread's scheduling, read straight from Mach: the
/// tests check the helper against it, not against itself.
private struct Scheduling: Sendable, Equatable {
    /// True when a time-constraint policy is in force.
    var realTime = false
    var period = 0.0, computation = 0.0, constraint = 0.0
    var preemptible = false
    /// The thread's base priority (a time-constraint thread runs at 97 on Darwin).
    var priority: Int32 = 0

    static func current() -> Scheduling {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) * 1e-9
        let thread = pthread_mach_thread_np(pthread_self())
        var result = Scheduling()

        var policy = thread_time_constraint_policy_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var isDefault: boolean_t = 0
        let got = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_get(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count, &isDefault)
            }
        }
        if got == KERN_SUCCESS && isDefault == 0 {
            result.realTime = true
            result.period = Double(policy.period) * secondsPerTick
            result.computation = Double(policy.computation) * secondsPerTick
            result.constraint = Double(policy.constraint) * secondsPerTick
            result.preemptible = policy.preemptible != 0
        }

        var info = thread_extended_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
            }
        }
        if read == KERN_SUCCESS { result.priority = info.pth_priority }
        return result
    }
}

/// Runs `body` on a thread of its own and returns what it returns. The policy under test belongs
/// to a thread: it must not be set on one of the test runner's.
private func onItsOwnThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result? {
    let result = Shared<Result?>(nil)
    let thread = JoinableThread { result.set(body()) }
    thread.join()
    return result.get()
}

@Suite("Scheduling helper (WP-226)")
struct ThreadTests {
    private struct Readback: Sendable {
        var granted = false
        var reported = false
        var period = -1.0
        var kernel = Scheduling()
    }

    @Test func thePolicyReadsBackAsSet() throws {
        // A poll interval of 5 ms, 3 ms of work per turn, due within the interval; then other figures.
        // The kernel keeps period and constraint as given, and the computation as given when it is
        // at least half the constraint. A smaller computation it may raise, to half the constraint
        // at most (the host of §3 does): the last two cases are of that kind.
        for (period, computation, constraint) in [(0.005, 0.003, 0.005), (0.0029, 0.0015, 0.002), (0.02, 0.006, 0.01), (0.005, 0.001, 0.005), (0.02, 0.0005, 0.01)] {
            let outcome = try #require(onItsOwnThread { () -> (before: Scheduling, set: Readback, cleared: Readback) in
                let before = Scheduling.current()
                var set = Readback()
                set.granted = ztd_thread_set_time_constraint(period, computation, constraint)
                set.reported = ztd_thread_get_time_constraint(&set.period)
                set.kernel = Scheduling.current()
                ztd_thread_clear_time_constraint()
                var cleared = Readback()
                cleared.reported = ztd_thread_get_time_constraint(&cleared.period)
                cleared.kernel = Scheduling.current()
                return (before, set, cleared)
            })
            #expect(!outcome.before.realTime, "a new thread has no such policy")
            #expect(outcome.set.granted, "the simulator's host grants the policy")
            #expect(outcome.set.reported, "and the helper reads it back as in force")
            // One tick of the clock is 125 / 3 ns on Apple silicon: the figures come back to within one.
            expectClose(outcome.set.period, period, .absolute(1e-7))
            #expect(outcome.set.kernel.realTime && outcome.set.kernel.preemptible)
            expectClose(outcome.set.kernel.period, period, .absolute(1e-7))
            #expect(outcome.set.kernel.computation >= computation - 1e-7 && outcome.set.kernel.computation <= max(computation, constraint / 2) + 1e-7,
                    "the computation is the one asked for, or raised to no more than half the constraint: \(outcome.set.kernel.computation)")
            if computation < constraint / 2 { note("WP-226 computation of \(computation) s under a constraint of \(constraint) s reads back as", outcome.set.kernel.computation, "s") }
            expectClose(outcome.set.kernel.constraint, constraint, .absolute(1e-7))
            #expect(outcome.set.kernel.priority > outcome.before.priority, "the thread now runs in the real-time band")
            // Cleared: back to time-sharing, and the helper says so.
            #expect(!outcome.cleared.reported && outcome.cleared.period == -1, "nothing is in force; the period is left alone")
            #expect(!outcome.cleared.kernel.realTime && outcome.cleared.kernel.priority < outcome.set.kernel.priority)
        }
    }

    @Test func aRefusedRequestLeavesTheQualityOfServiceInPlaceAndIsReported() throws {
        // Requests the scheduler cannot honour: more work than fits before it is due, or none at all.
        // And requests that are not durations.
        let refused: [(Double, Double, Double)] = [
            (0.005, 0.004, 0.001), (0.005, 0, 0.005), (0.005, 10, 20),
            (0.005, .nan, 0.005), (-1, 0.001, 0.005), (0.005, 0.001, .infinity), (1e9, 0.001, 0.005),
        ]
        for (period, computation, constraint) in refused {
            let outcome = try #require(onItsOwnThread { () -> (before: Scheduling, after: Scheduling, granted: Bool, reported: Bool, classBefore: UInt32, classAfter: UInt32) in
                // The analysis thread is created at user-interactive quality of service (RT-9).
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
                let classBefore = qos_class_self().rawValue
                let before = Scheduling.current()
                let granted = ztd_thread_set_time_constraint(period, computation, constraint)
                var ignored = 0.0
                let reported = ztd_thread_get_time_constraint(&ignored)
                return (before, Scheduling.current(), granted, reported, classBefore, qos_class_self().rawValue)
            })
            #expect(!outcome.granted, "the refusal is reported: (\(period), \(computation), \(constraint))")
            #expect(!outcome.reported && !outcome.after.realTime, "no policy is in force")
            #expect(outcome.classBefore == QOS_CLASS_USER_INTERACTIVE.rawValue && outcome.classAfter == outcome.classBefore, "the quality of service is the one the thread had")
            #expect(outcome.after.priority == outcome.before.priority, "and the kernel still schedules it there: \(outcome.before.priority) before, \(outcome.after.priority) after")
        }
        // On such a thread a request that can be honoured still is: the refusal was the request's.
        let outcome = onItsOwnThread { () -> [Bool] in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            let first = ztd_thread_set_time_constraint(0.005, 0.004, 0.001)
            let second = ztd_thread_set_time_constraint(0.005, 0.003, 0.005)
            ztd_thread_clear_time_constraint()
            return [first, second]
        }
        #expect(outcome == [false, true])
    }

    /// RT-9: the fall-back of a thread that is refused is its quality of service, so nothing the
    /// helper does may take that away from a thread that has no policy.
    @Test func aClearWithoutAPolicyLeavesTheThreadExactlyAsItIs() throws {
        let outcome = try #require(onItsOwnThread { () -> (before: Scheduling, after: Scheduling, classBefore: UInt32, classAfter: UInt32, refused: Bool) in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            let before = Scheduling.current(), classBefore = qos_class_self().rawValue
            ztd_thread_clear_time_constraint()                                   // nothing to clear
            let refused = !ztd_thread_set_time_constraint(0.2, 0.1, 0.2)         // more work than the scheduler grants
            ztd_thread_clear_time_constraint()                                   // still nothing to clear
            ztd_thread_clear_time_constraint()
            return (before, Scheduling.current(), classBefore, qos_class_self().rawValue, refused)
        })
        #expect(outcome.refused)
        #expect(outcome.classBefore == QOS_CLASS_USER_INTERACTIVE.rawValue && outcome.classAfter == outcome.classBefore, "the class is the one the thread had: \(String(outcome.classAfter, radix: 16))")
        #expect(outcome.after.priority == outcome.before.priority && !outcome.after.realTime, "and so is its priority: \(outcome.before.priority) before, \(outcome.after.priority) after")
        // A thread that never had a class is left alone too.
        let plain = try #require(onItsOwnThread { () -> (Int32, Int32) in
            let before = Scheduling.current().priority
            ztd_thread_clear_time_constraint()
            return (before, Scheduling.current().priority)
        })
        #expect(plain.0 == plain.1)
    }

    /// A granted policy takes the thread out of its class for good. What a clear can give back
    /// is the priority the class gave, and it does, however often the policy comes and goes.
    @Test func aClearAfterAGrantGivesTheThreadItsPriorityBack() throws {
        let outcome = try #require(onItsOwnThread { () -> (before: Int32, during: Int32, cleared: [Int32], stillRealTime: Bool, refusedAfter: Int32) in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            let before = Scheduling.current().priority
            var cleared: [Int32] = [], during: Int32 = 0
            for _ in 0 ..< 3 {
                _ = ztd_thread_set_time_constraint(0.005, 0.0025, 0.005)
                during = Scheduling.current().priority
                ztd_thread_clear_time_constraint()
                cleared.append(Scheduling.current().priority)
            }
            let stillRealTime = Scheduling.current().realTime
            _ = ztd_thread_set_time_constraint(0.2, 0.1, 0.2)                    // refused: the thread stays where the clear left it
            return (before, during, cleared, stillRealTime, Scheduling.current().priority)
        })
        #expect(outcome.during > outcome.before, "a time-constraint thread runs above every class")
        #expect(outcome.cleared == [outcome.before, outcome.before, outcome.before], "cleared, the thread is back at \(outcome.before): \(outcome.cleared)")
        #expect(!outcome.stillRealTime && outcome.refusedAfter == outcome.before)
    }

    @Test func theClockRunsForwardInSeconds() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // One multiplication of the tick count by the seconds in a tick, as the helper does it: two
        // readings in the same tick then give the same number, not numbers one rounding apart.
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) * 1e-9
        let first = ztd_thread_now()
        let mach = Double(mach_absolute_time()) * secondsPerTick
        let second = ztd_thread_now()
        #expect(first > 0 && first <= mach && mach <= second, "the same clock as mach_absolute_time, in seconds")
        #expect(second - first < 5, "two readings in a row are a moment apart")
    }

    @Test func sleepingUntilADeadlineReturnsOnceItHasPassed() {
        let start = ztd_thread_now()
        ztd_thread_sleep_until(start + 0.003)
        let woke = ztd_thread_now()
        #expect(woke >= start + 0.003 - 1e-7, "not before the deadline (to within one tick of the clock, 42 ns)")
        // A deadline that has passed, or is no time at all, does not wait.
        let before = ztd_thread_now()
        ztd_thread_sleep_until(before - 1)
        ztd_thread_sleep_until(0)
        ztd_thread_sleep_until(-.infinity)
        ztd_thread_sleep_until(.nan)
        ztd_thread_sleep_until(.infinity)
        #expect(ztd_thread_now() - before < 2, "five calls that have nothing to wait for return at once, however busy the machine")
    }

    @Test func readingTheClockIsAllocationFree() {
        var total = 0.0
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                total += ztd_thread_now()
                round += 1
            }
        }
        #expect(total > 0)
        let result = Benchmark.measure("thread.now", iterations: 5_000) { Benchmark.blackHole(ztd_thread_now()) }
        Benchmark.record([result])
        note(result.name, result.minimum, "ns")
        #expect(result.minimum > 0)
    }
}
