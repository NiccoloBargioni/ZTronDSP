import CZTronDSPTesting
import Foundation
import Testing
import ZTronDSPCore

/// What one thread asked of the heap during an audited region.
public struct AllocationCounts: Sendable, Equatable, CustomStringConvertible {
    /// Calls that allocate: `malloc`, `calloc`, the allocating half of `realloc`.
    public let allocations: Int
    /// Calls that free: `free`, the freeing half of `realloc`.
    public let deallocations: Int
    /// Bytes requested by the allocations.
    public let bytes: Int

    public init(allocations: Int, deallocations: Int, bytes: Int) {
        self.allocations = allocations
        self.deallocations = deallocations
        self.bytes = bytes
    }

    public var description: String {
        "\(allocations) allocation(s) of \(bytes) byte(s), \(deallocations) deallocation(s)"
    }
}

/// Why an allocation audit could not run. An audit that cannot run is a failure, never a pass.
public enum AllocationAuditError: Error, Sendable, Equatable {
    /// The `malloc_logger` hook is not firing, so a count of zero would mean nothing.
    case hookNotLive
    /// More audits are open at once than the probe has slots for.
    case noFreeSlot
    /// This thread is already under audit; audits do not nest.
    case nested
}

/// Runs `body` on the calling thread and returns what that thread allocated and freed while
/// it ran. Allocations made by other threads in the meantime are not counted, so tests that
/// run in parallel do not disturb one another.
///
/// The closure is synchronous and cannot throw on purpose: an audit belongs to one thread,
/// a suspension point could resume on another, and an error path allocates.
public func countAllocations(_ body: () -> Void) throws(AllocationAuditError) -> AllocationCounts {
    guard ztdt_alloc_hook_is_live() else { throw .hookNotLive }
    let token = ztdt_alloc_audit_begin()
    guard token >= 0 else { throw token == -2 ? .nested : .noFreeSlot }
    body()
    let counts = ztdt_alloc_audit_end(token)
    return AllocationCounts(
        allocations: Int(counts.allocations), deallocations: Int(counts.deallocations), bytes: Int(counts.bytes))
}

/// Records an issue when `body` allocates or frees heap memory on the calling thread, or when
/// the audit cannot run. This is the run-time layer of the real-time verification (RT-7):
/// set everything up outside the closure, then run the steady-state loop inside it.
///
/// Write that loop with `while`, not `for … in`. In an unoptimised build a `for … in` loop
/// over a range allocates on every iteration (measured on Swift 6.4, change request CR-002),
/// so the loop of the test itself would fail the audit. The audit is meant to pass in Debug
/// and in Release.
///
/// - Returns: the counts, so a test can assert further on them.
@discardableResult
public func expectNoAllocations(
    _ comment: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () -> Void
) -> AllocationCounts {
    // The Thread Sanitizer puts its own allocator in front of the one the probe hooks, so the
    // hook never fires there. That run looks for races; the audit belongs to the plain runs,
    // in Debug and in Release. The body still runs, so the test does what it does.
    if AllocationAudit.isUnderThreadSanitizer {
        body()
        return AllocationCounts(allocations: 0, deallocations: 0, bytes: 0)
    }
    let counts: AllocationCounts
    do {
        counts = try countAllocations(body)
    } catch {
        let text = comment()
        Issue.record(
            "\(text.isEmpty ? "" : "\(text): ")the allocation audit could not run: \(error)",
            sourceLocation: sourceLocation)
        return AllocationCounts(allocations: 0, deallocations: 0, bytes: 0)
    }
    if counts.allocations != 0 || counts.deallocations != 0 {
        let text = comment()
        Issue.record(
            "\(text.isEmpty ? "" : "\(text): ")expected no heap traffic, found \(counts)",
            sourceLocation: sourceLocation)
    }
    return counts
}

/// Where an allocation audit can run.
public enum AllocationAudit {
    /// True when the process runs under the Thread Sanitizer, whose allocator hides the heap
    /// from the probe: `expectNoAllocations` then runs its body and audits nothing.
    public static let isUnderThreadSanitizer: Bool = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
}

/// Performs exactly one allocation and one deallocation of `byteCount` bytes that no optimiser
/// can remove. Use it as the control case of an audit: a test that expects this to be counted
/// fails loudly if the probe ever stops working.
public func forceAllocation(byteCount: Int = 64) {
    ztdt_force_allocation(byteCount)
}

/// `calloc`, `realloc`, `free`: two allocations (of `first` and of `second` bytes) and two
/// deallocations that no optimiser can remove.
public func forceReallocation(from first: Int, to second: Int) {
    ztdt_force_reallocation(first, second)
}

/// A digest of the calling thread's floating-point environment: rounding mode, exception flags
/// and masks, flush-to-zero. Equal digests mean an unchanged environment (RT-6: a kernel
/// never touches it).
public func floatingPointEnvironmentDigest() -> UInt64 {
    ztdt_floating_point_environment()
}

/// An allocation audit that is opened and closed from inside code running on the audited
/// thread, for a thread the test does not own: the engine's analysis thread, reached through
/// a sink's callback.
///
/// Call `begin()` and `end()` on the audited thread; neither allocates. Read `counts` from
/// the test once `isClosed` is true.
///
/// Threading: `begin` and `end` belong to the audited thread. The results are single atomic
/// words and may be read anywhere.
public final class ThreadAllocationAudit: @unchecked Sendable {
    private var token: Int32 = -1
    private let state: OpaquePointer?
    private let allocations: OpaquePointer?
    private let deallocations: OpaquePointer?
    private let bytes: OpaquePointer?

    public init() {
        state = ztd_atomic_create(0)
        allocations = ztd_atomic_create(0)
        deallocations = ztd_atomic_create(0)
        bytes = ztd_atomic_create(0)
    }

    deinit {
        for cell in [state, allocations, deallocations, bytes] {
            if let cell { ztd_atomic_destroy(cell) }
        }
    }

    /// Opens the audit on the calling thread. Does nothing when it is open already.
    public func begin() {
        guard token < 0, let state, ztd_atomic_load(state) == 0 else { return }
        token = ztdt_alloc_audit_begin()
        ztd_atomic_store(state, token >= 0 ? 1 : 3)
    }

    /// Closes the audit on the calling thread and keeps what it counted.
    public func end() {
        guard token >= 0, let state, let allocations, let deallocations, let bytes else { return }
        let counted = ztdt_alloc_audit_end(token)
        token = -1
        ztd_atomic_store(allocations, counted.allocations)
        ztd_atomic_store(deallocations, counted.deallocations)
        ztd_atomic_store(bytes, counted.bytes)
        ztd_atomic_store(state, 2)
    }

    /// True while the audit is open.
    public var isOpen: Bool { state.map { ztd_atomic_load($0) == 1 } ?? false }

    /// True once the audit has been closed.
    public var isClosed: Bool { state.map { ztd_atomic_load($0) == 2 } ?? false }

    /// True when the audit could not be opened: an audit that cannot run is a failure.
    public var failedToOpen: Bool { state.map { ztd_atomic_load($0) == 3 } ?? true }

    /// What the audited thread allocated and freed between `begin()` and `end()`; `nil` until
    /// the audit has been closed.
    public var counts: AllocationCounts? {
        guard isClosed, let allocations, let deallocations, let bytes else { return nil }
        return AllocationCounts(allocations: Int(ztd_atomic_load(allocations)), deallocations: Int(ztd_atomic_load(deallocations)),
                                bytes: Int(ztd_atomic_load(bytes)))
    }
}
