import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

@Suite("Atomic cell")
struct AtomicTests {
    @Test func loadStoreAddExchange() {
        let cell = ztd_atomic_create(5)!
        defer { ztd_atomic_destroy(cell) }
        #expect(ztd_atomic_load(cell) == 5)
        ztd_atomic_store(cell, 9)
        #expect(ztd_atomic_load(cell) == 9)
        #expect(ztd_atomic_add(cell, 3) == 12, "add returns the new value")
        #expect(ztd_atomic_exchange(cell, 100) == 12, "exchange returns the previous value")
        #expect(ztd_atomic_compare_exchange(cell, 100, 7))
        #expect(!ztd_atomic_compare_exchange(cell, 100, 8), "the cell no longer holds 100")
        #expect(ztd_atomic_load(cell) == 7)
        #expect(UInt(bitPattern: UnsafeRawPointer(cell)) % 64 == 0, "a cache line of its own")
    }

    @Test func concurrentAddsAreNotLost() async {
        let cell = ztd_atomic_create(0)!
        defer { ztd_atomic_destroy(cell) }
        nonisolated(unsafe) let shared = cell
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var round = 0
                    while round < 50_000 { _ = ztd_atomic_add(shared, 1); round += 1 }
                }
            }
        }
        #expect(ztd_atomic_load(cell) == 400_000)
    }

    @Test func operationsAreAllocationFree() {
        let cell = ztd_atomic_create(0)!
        defer { ztd_atomic_destroy(cell) }
        expectNoAllocations {
            var round: UInt64 = 0
            while round < 1_000 {
                ztd_atomic_store(cell, round)
                _ = ztd_atomic_load(cell)
                _ = ztd_atomic_add(cell, 1)
                _ = ztd_atomic_exchange(cell, 2)
                _ = ztd_atomic_compare_exchange(cell, 2, 3)
                round += 1
            }
        }
    }
}

@Suite("Command queue (WP-206)")
struct CommandQueueTests {
    private func command(_ target: UInt32, value: Double) -> ztd_command_t {
        var command = ztd_command_t()
        command.target = target
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        command.scalar.0 = value
        return command
    }

    @Test func orderIsKept() {
        let queue = ztd_command_queue_create(16)!
        defer { ztd_command_queue_destroy(queue) }
        for index in 0 ..< 10 {
            var message = command(UInt32(index), value: Double(index) * 0.5)
            #expect(ztd_command_queue_push(queue, &message) == UInt64(index + 1), "sequences count from 1")
        }
        var received = ztd_command_t()
        for index in 0 ..< 10 {
            #expect(ztd_command_queue_pop(queue, &received))
            #expect(received.target == UInt32(index) && received.scalar.0 == Double(index) * 0.5)
            #expect(received.sequence == UInt64(index + 1))
            #expect(received.kind == UInt32(ZTD_COMMAND_SET_VALUES))
        }
        #expect(!ztd_command_queue_pop(queue, &received), "an empty queue gives nothing")
    }

    @Test func overflowIsReportedAndNothingBlocks() {
        let queue = ztd_command_queue_create(4)!
        defer { ztd_command_queue_destroy(queue) }
        var message = command(0, value: 1)
        var accepted = 0
        for _ in 0 ..< 10 where ztd_command_queue_push(queue, &message) != 0 { accepted += 1 }
        #expect(accepted == 4, "a queue of four holds four")
        #expect(ztd_command_queue_overflows(queue) == 6, "each refused command is counted")
        var received = ztd_command_t()
        #expect(ztd_command_queue_pop(queue, &received) && received.sequence == 1)
        #expect(ztd_command_queue_push(queue, &message) == 5, "a slot freed by the consumer is usable again")
        #expect(ztd_command_queue_overflows(queue) == 6)
    }

    @Test func capacityIsRoundedUpToAPowerOfTwo() {
        for (requested, capacity) in [(0, 2), (1, 2), (3, 4), (5, 8), (8, 8)] {
            let queue = ztd_command_queue_create(UInt32(requested))!
            defer { ztd_command_queue_destroy(queue) }
            var message = command(0, value: 0)
            var accepted = 0
            while ztd_command_queue_push(queue, &message) != 0 { accepted += 1 }
            #expect(accepted == capacity, "requested \(requested)")
        }
    }

    @Test func acknowledgementTellsTheProducerWhatWasApplied() {
        let queue = ztd_command_queue_create(8)!
        defer { ztd_command_queue_destroy(queue) }
        #expect(ztd_command_queue_applied(queue) == 0)
        var message = command(1, value: 2)
        let payload = UnsafeMutablePointer<Double>.allocate(capacity: 5)
        defer { payload.deallocate() }
        message.values = UnsafeRawPointer(payload)
        message.count = 5
        let sequence = ztd_command_queue_push(queue, &message)
        #expect(ztd_command_queue_applied(queue) < sequence, "the payload must stay alive")
        var received = ztd_command_t()
        #expect(ztd_command_queue_pop(queue, &received))
        #expect(received.values == UnsafeRawPointer(payload) && received.count == 5, "the payload pointer travels with the message")
        #expect(ztd_command_queue_applied(queue) < sequence, "popped is not applied")
        ztd_command_queue_acknowledge(queue, received.sequence)
        #expect(ztd_command_queue_applied(queue) == sequence, "now the producer may free the payload")
    }

    @Test func twoThreadsExchangeEveryCommandInOrder() async {
        let queue = ztd_command_queue_create(64)!
        defer { ztd_command_queue_destroy(queue) }
        nonisolated(unsafe) let shared = queue
        let total = 200_000
        async let produced: Int = Task.detached {
            var sent = 0
            var message = ztd_command_t()
            while sent < total {
                message.target = UInt32(sent)
                if ztd_command_queue_push(shared, &message) != 0 { sent += 1 } else { sched_yield() }
            }
            return sent
        }.value
        async let consumed: Bool = Task.detached {
            var expected = 0
            var message = ztd_command_t()
            var ordered = true
            while expected < total {
                if ztd_command_queue_pop(shared, &message) {
                    if message.target != UInt32(expected) || message.sequence != UInt64(expected + 1) { ordered = false }
                    ztd_command_queue_acknowledge(shared, message.sequence)
                    expected += 1
                } else {
                    sched_yield()
                }
            }
            return ordered
        }.value
        let sent = await produced
        let ordered = await consumed
        #expect(sent == total)
        #expect(ordered, "no command lost, duplicated or out of order")
        #expect(ztd_command_queue_applied(queue) == UInt64(total))
    }

    @Test func pushAndPopAreAllocationFree() {
        let queue = ztd_command_queue_create(8)!
        defer { ztd_command_queue_destroy(queue) }
        expectNoAllocations {
            var message = ztd_command_t()
            var round = 0
            while round < 1_000 {
                _ = ztd_command_queue_push(queue, &message)
                _ = ztd_command_queue_pop(queue, &message)
                ztd_command_queue_acknowledge(queue, message.sequence)
                round += 1
            }
        }
    }
}

@Suite("Pointer queue and plan slot (WP-205)")
struct PlanSlotTests {
    @Test func aPointerQueueIsFirstInFirstOut() {
        let queue = ztd_pointer_queue_create(4)!
        defer { ztd_pointer_queue_destroy(queue) }
        let values = (1 ... 4).map { UnsafeMutableRawPointer(bitPattern: $0 * 16)! }
        for value in values { #expect(ztd_pointer_queue_push(queue, value)) }
        #expect(!ztd_pointer_queue_push(queue, values[0]), "full")
        #expect(!ztd_pointer_queue_push(queue, nil), "NULL cannot be queued: it means empty")
        for value in values { #expect(ztd_pointer_queue_pop(queue) == value) }
        #expect(ztd_pointer_queue_pop(queue) == nil)
    }

    private func plan(_ number: Int) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: number * 64)! }

    @Test func publishTakeInstallRetire() {
        let slot = ztd_plan_slot_create(4)!
        defer { ztd_plan_slot_destroy(slot) }
        #expect(ztd_plan_slot_current(slot) == nil && ztd_plan_slot_take(slot) == nil)
        #expect(ztd_plan_slot_publish(slot, plan(1)) == nil)
        #expect(ztd_plan_slot_current(slot) == nil, "published is not yet current")
        #expect(ztd_plan_slot_take(slot) == plan(1))
        #expect(ztd_plan_slot_take(slot) == nil, "a plan is taken once")
        #expect(ztd_plan_slot_install(slot, plan(1)) == nil)
        #expect(ztd_plan_slot_current(slot) == plan(1) && ztd_plan_slot_exchanges(slot) == 1)

        #expect(ztd_plan_slot_publish(slot, plan(2)) == nil)
        let taken = ztd_plan_slot_take(slot)
        let previous = ztd_plan_slot_install(slot, taken)
        #expect(previous == plan(1) && ztd_plan_slot_current(slot) == plan(2))
        #expect(ztd_plan_slot_next_retired(slot) == nil)
        #expect(ztd_plan_slot_retire(slot, previous))
        #expect(ztd_plan_slot_next_retired(slot) == plan(1))
        #expect(ztd_plan_slot_next_retired(slot) == nil, "a retired plan is handed back once")
    }

    @Test func theLatestUpdateWins() {
        let slot = ztd_plan_slot_create(4)!
        defer { ztd_plan_slot_destroy(slot) }
        #expect(ztd_plan_slot_publish(slot, plan(1)) == nil)
        #expect(ztd_plan_slot_publish(slot, plan(2)) == plan(1), "the replaced plan, which never ran, goes back to the publisher")
        #expect(ztd_plan_slot_take(slot) == plan(2))
        #expect(ztd_plan_slot_publish(slot, plan(3)) == nil)
        #expect(ztd_plan_slot_withdraw(slot) == plan(3))
        #expect(ztd_plan_slot_withdraw(slot) == nil && ztd_plan_slot_take(slot) == nil)
    }

    @Test func aFullRetireListRefusesAndKeepsNothing() {
        let slot = ztd_plan_slot_create(2)!
        defer { ztd_plan_slot_destroy(slot) }
        #expect(ztd_plan_slot_retire(slot, plan(1)) && ztd_plan_slot_retire(slot, plan(2)))
        #expect(!ztd_plan_slot_retire(slot, plan(3)), "the analysis thread keeps the plan and tries again")
        #expect(ztd_plan_slot_next_retired(slot) == plan(1))
        #expect(ztd_plan_slot_retire(slot, plan(3)))
        #expect(ztd_plan_slot_next_retired(slot) == plan(2) && ztd_plan_slot_next_retired(slot) == plan(3))
    }

    /// Exchange while running: a control thread publishes plans as fast as it can while an
    /// analysis thread takes, installs and retires them. Every plan must come back exactly once.
    @Test func everyPlanIsDestroyedExactlyOnceUnderExchangeWhileRunning() async {
        let slot = ztd_plan_slot_create(8)!
        defer { ztd_plan_slot_destroy(slot) }
        nonisolated(unsafe) let shared = slot
        let total = 100_000
        let stop = ztd_atomic_create(0)!
        defer { ztd_atomic_destroy(stop) }
        nonisolated(unsafe) let stopFlag = stop

        // Each "plan" is a counter cell: destroying it is counting it.
        let destroyed = UnsafeMutablePointer<UInt8>.allocate(capacity: total + 1)
        destroyed.initialize(repeating: 0, count: total + 1)
        defer { destroyed.deallocate() }
        nonisolated(unsafe) let ledger = destroyed

        async let analysis: Void = Task.detached {
            var backlog: UnsafeMutableRawPointer?
            while true {
                if let waiting = backlog, ztd_plan_slot_retire(shared, waiting) { backlog = nil }
                if backlog == nil, let incoming = ztd_plan_slot_take(shared) {
                    if let previous = ztd_plan_slot_install(shared, incoming), !ztd_plan_slot_retire(shared, previous) {
                        backlog = previous
                    }
                } else if ztd_atomic_load(stopFlag) != 0, backlog == nil {
                    // Nothing pending and nothing waiting: retire the last plan and finish.
                    if ztd_plan_slot_take(shared) == nil {
                        if let last = ztd_plan_slot_install(shared, nil) {
                            while !ztd_plan_slot_retire(shared, last) { sched_yield() }
                        }
                        return
                    }
                } else {
                    sched_yield()
                }
            }
        }.value

        func destroy(_ plan: UnsafeMutableRawPointer) { ledger[Int(bitPattern: plan) / 64] += 1 }
        for number in 1 ... total {
            if let replaced = ztd_plan_slot_publish(slot, plan(number)) { destroy(replaced) }
            while let retired = ztd_plan_slot_next_retired(slot) { destroy(retired) }
        }
        ztd_atomic_store(stop, 1)
        await analysis
        while let retired = ztd_plan_slot_next_retired(slot) { destroy(retired) }

        var once = 0, never = 0, twice = 0
        for number in 1 ... total {
            switch destroyed[number] { case 0: never += 1; case 1: once += 1; default: twice += 1 }
        }
        #expect(once == total && never == 0 && twice == 0, "\(once) once, \(never) never, \(twice) more than once")
        #expect(ztd_plan_slot_current(slot) == nil)
    }

    @Test func theAnalysisSideIsAllocationFree() {
        let slot = ztd_plan_slot_create(4)!
        defer { ztd_plan_slot_destroy(slot) }
        let first = plan(1), second = plan(2)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                _ = ztd_plan_slot_publish(slot, round % 2 == 0 ? first : second)
                if let taken = ztd_plan_slot_take(slot), let previous = ztd_plan_slot_install(slot, taken) {
                    _ = ztd_plan_slot_retire(slot, previous)
                }
                _ = ztd_plan_slot_next_retired(slot)
                _ = ztd_plan_slot_current(slot)
                round += 1
            }
        }
    }
}
