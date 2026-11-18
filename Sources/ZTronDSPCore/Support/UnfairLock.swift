import os

/// The lock behind control state (PLAT-1): `os_unfair_lock` on stable heap storage. It is
/// taken on the control context and in background work only, never on the analysis or I/O
/// thread (RT-2).
final class UnfairLock: @unchecked Sendable {
    // Threading contract: the lock word is only touched through os_unfair_lock_lock / unlock.
    private let storage: os_unfair_lock_t

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return try body()
    }
}

/// A value guarded by an ``UnfairLock``: the shape of every piece of control state.
final class Locked<Value>: @unchecked Sendable {
    // Threading contract: `value` is read and written only inside `lock.withLock`.
    private let lock = UnfairLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&value) }
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
