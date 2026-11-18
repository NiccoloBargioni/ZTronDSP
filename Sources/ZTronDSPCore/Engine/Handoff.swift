import Darwin

/// How the control context hands an object to the one thread that runs it, and gets back the
/// object that thread has stopped using, without either waiting for the other (RT-3, RT-4).
///
/// The control context publishes a value as pending. The consumer takes it at a boundary of
/// its own choosing, with one atomic exchange, makes it the installed value, and retires the
/// one it replaces. A retired value is released by the control context, so nothing is ever
/// freed on the consumer's thread. A value published while another is still pending replaces
/// it: the latest wins.
///
/// Threading: `publish`, `withdraw`, `drainRetired` and `hasPending` belong to the control
/// context. `take`, `install`, `refresh` and `installed` belong to the consumer: one thread at
/// a time, which is the analysis thread, or the control context while it is certain that no
/// thread consumes (a hub that is not scheduled).
final class Handoff<Value: AnyObject>: @unchecked Sendable {
    private let slot: OpaquePointer
    /// Consumer only: what it runs. The slot holds the reference that keeps it alive.
    private(set) var installed: Value?
    /// Consumer only: a replaced value the retire list had no room for yet.
    private var limbo: UnsafeMutableRawPointer?

    init(retireCapacity: Int = 16) throws(DSPError) {
        guard let slot = ztd_plan_slot_create(UInt32(max(retireCapacity, 2))) else {
            throw .resourceAllocationFailed(what: "a hand-over slot")
        }
        self.slot = slot
    }

    deinit {
        installed = nil
        if let pending = ztd_plan_slot_withdraw(slot) { Unmanaged<Value>.fromOpaque(pending).release() }
        if let limbo { Unmanaged<Value>.fromOpaque(limbo).release() }
        if let current = ztd_plan_slot_current(slot) { Unmanaged<Value>.fromOpaque(current).release() }
        while let retired = ztd_plan_slot_next_retired(slot) { Unmanaged<Value>.fromOpaque(retired).release() }
        ztd_plan_slot_destroy(slot)
    }

    // MARK: Control context

    /// Makes `value` pending. A pending value it replaces never ran and is released here.
    func publish(_ value: Value) {
        let replaced = ztd_plan_slot_publish(slot, Unmanaged.passRetained(value).toOpaque())
        if let replaced { Unmanaged<Value>.fromOpaque(replaced).release() }
    }

    /// Takes the pending value back, when the consumer has not taken it yet.
    func withdraw() -> Value? {
        guard let pending = ztd_plan_slot_withdraw(slot) else { return nil }
        return Unmanaged<Value>.fromOpaque(pending).takeRetainedValue()
    }

    /// True while a published value has not been taken.
    var hasPending: Bool { ztd_plan_slot_has_pending(slot) }

    /// Releases every value the consumer has finished with.
    func drainRetired() {
        while let retired = ztd_plan_slot_next_retired(slot) { Unmanaged<Value>.fromOpaque(retired).release() }
    }

    // MARK: Consumer

    /// Takes the pending value without installing it: for a consumer that runs it beside the
    /// installed one first. The caller either installs it or hands it to `discard`.
    @inline(__always)
    func take() -> Value? {
        guard limbo == nil || flushLimbo() else { return nil }
        guard let pending = ztd_plan_slot_take(slot) else { return nil }
        return Unmanaged<Value>.fromOpaque(pending).takeUnretainedValue()
    }

    /// Makes a taken value the installed one and retires the one it replaces.
    func install(_ value: Value) {
        installed = value
        let previous = ztd_plan_slot_install(slot, Unmanaged.passUnretained(value).toOpaque())
        if let previous { retire(previous) }
    }

    /// Retires a taken value that will not be installed.
    func discard(_ value: Value) {
        retire(Unmanaged.passUnretained(value).toOpaque())
    }

    /// Installs the pending value, when there is one, and returns the installed value.
    @inline(__always)
    @discardableResult
    func refresh() -> Value? {
        if let pending = take() { install(pending) }
        return installed
    }

    private func retire(_ pointer: UnsafeMutableRawPointer) {
        if !ztd_plan_slot_retire(slot, pointer) { limbo = pointer }
    }

    private func flushLimbo() -> Bool {
        guard let pointer = limbo else { return true }
        guard ztd_plan_slot_retire(slot, pointer) else { return false }
        limbo = nil
        return true
    }
}

/// Waiting on the control context for something the analysis side does within a block or a
/// poll interval. Control may sleep; the analysis side never waits for it.
enum ControlWait {
    /// Sleeps in short steps until `condition` holds or `timeout` seconds have passed, and
    /// returns whether it held.
    @discardableResult
    static func until(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = ztd_thread_now() + timeout
        var pause: UInt32 = 50
        while ztd_thread_now() < deadline {
            usleep(pause)
            if condition() { return true }
            if pause < 1_000 { pause *= 2 }
        }
        return condition()
    }
}
