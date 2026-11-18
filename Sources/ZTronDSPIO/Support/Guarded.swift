import os

/// A value behind a lock: the shape of every piece of mutable state in this target (IMM-3,
/// PLAT-1). Sources are immutable descriptions plus one `Guarded` state; what is not
/// `Sendable` by itself (an `AVAudioEngine`, an `AVAudioFile`, observer tokens) lives inside
/// one and is touched only while the lock is held.
///
/// Threading: `withLock` may be called on any thread that is allowed to block: the control
/// context, a notification queue, a reader or pacing thread. It is never called on the audio
/// I/O thread, which runs no Swift at all (RT-1), nor on the analysis thread (RT-2). The lock
/// is not recursive: a body must not call back into the same `Guarded`.
final class Guarded<Value>: @unchecked Sendable {
    // Threading contract: `value` is read and written only between os_unfair_lock_lock and
    // os_unfair_lock_unlock on `lock`, which lives on stable heap storage.
    private let lock: os_unfair_lock_t
    private var value: Value

    init(_ value: Value) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        self.value = value
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Runs `body` with the value, alone.
    func withLock<Result, Failure: Error>(_ body: (inout Value) throws(Failure) -> Result) throws(Failure) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&value)
    }

    /// A copy of the value.
    func get() -> Value {
        withLock { $0 }
    }

    /// Replaces the value.
    func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}
