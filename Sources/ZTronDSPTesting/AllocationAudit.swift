import CZTronDSPTesting
import Foundation
import Testing
import ZTronDSPCore

/// What one thread asked of the heap during an audited region.
///
/// An immutable value, usable on any thread; it does not allocate, but for ``description``.
public struct AllocationCounts: Sendable, Equatable, CustomStringConvertible {
    /// Calls that allocate: `malloc`, `calloc`, the allocating half of `realloc`.
    public let allocations: Int
    /// Calls that free: `free`, the freeing half of `realloc`.
    public let deallocations: Int
    /// Bytes requested by the allocations.
    public let bytes: Int

    /// Counts given figure by figure, as an audit reports them.
    public init(allocations: Int, deallocations: Int, bytes: Int) {
        self.allocations = allocations
        self.deallocations = deallocations
        self.bytes = bytes
    }

    /// The counts in words: the allocations with their bytes, then the deallocations.
    public var description: String {
        "\(allocations) allocation(s) of \(bytes) byte(s), \(deallocations) deallocation(s)"
    }
}

/// Why an allocation audit could not run. An audit that cannot run is a failure, never a pass.
///
/// A value, usable on any thread; it does not allocate.
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
///
/// Callable on any thread: the thread it audits is the caller's. Outside `body` it does not
/// allocate.
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
/// Callable on any thread: the thread it audits is the caller's. Outside `body` it
/// allocates only to record an issue.
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
///
/// ``isUnderThreadSanitizer`` may be read on any thread: its first read looks the symbol up,
/// once, and may allocate; later reads do not allocate.
public enum AllocationAudit {
    /// True when the process runs under the Thread Sanitizer, whose allocator hides the heap
    /// from the probe: `expectNoAllocations` then runs its body and audits nothing.
    public static let isUnderThreadSanitizer: Bool = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
}

/// Performs exactly one allocation and one deallocation of `byteCount` bytes that no optimiser
/// can remove. Use it as the control case of an audit: a test that expects this to be counted
/// fails loudly if the probe ever stops working.
///
/// Callable on any thread; it allocates, by design.
public func forceAllocation(byteCount: Int = 64) {
    ztdt_force_allocation(byteCount)
}

/// `calloc`, `realloc`, `free`: two allocations (of `first` and of `second` bytes) and two
/// deallocations that no optimiser can remove.
///
/// Callable on any thread; it allocates, by design.
public func forceReallocation(from first: Int, to second: Int) {
    ztdt_force_reallocation(first, second)
}

/// A digest of the calling thread's floating-point environment: rounding mode, exception flags
/// and masks, flush-to-zero. Equal digests mean an unchanged environment (RT-6: a kernel
/// never touches it).
///
/// Callable on any thread, the analysis thread included; it does not allocate.
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

    /// An audit not yet opened, ready for `begin()` on the thread it audits. Creating one
    /// allocates its four atomic cells.
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

/// The real-time audit of a pipeline (RT-7, layer 3; EXT-3): compiles `pipeline`, runs it on
/// the calling thread, block by block, inside `expectNoAllocations`, and records an issue as
/// that does when a stage allocates or frees heap memory while it runs.
///
/// The pipeline is compiled as an attachment compiles it, for a signal of `format` in blocks
/// of `blockSize` frames of seeded noise. Eight blocks run before the audit opens: a stage
/// that waits for its history takes its other path afterwards, and what a first call makes
/// the Swift runtime instantiate is not what this audit is about. Then `blocks` blocks run
/// inside it. Sinks at the end of the pipeline are written as in a session; a result bound
/// to a `Binding` is delivered when the run is over, if the caller is on the main thread.
///
/// Everything runs on the caller's thread: a node or a processor written outside the package
/// is held to RT-2 here as the stock stages are, with no engine and no thread of its own.
///
/// Threading: a test's own thread, never an engine's analysis thread (the plan it drives is
/// its own). It allocates outside the audit: the plan, the noise, the eight blocks before it.
/// The eight blocks mean that it shows no first use (RT-2): a stage whose first block makes
/// the Swift runtime instantiate something is held to that by an audit that opens before the
/// first block, in an optimised build and a process of its own.
///
/// - Parameters:
///   - pipeline: the pipeline under audit, from samples to whatever it ends in.
///   - format: the signal the pipeline is compiled for; mono at 48 kHz by default.
///   - blockSize: frames per block.
///   - blocks: blocks that run inside the audit.
///   - crossovers: the table the plan binds its implementations by.
///   - comment: put in front of an issue; evaluated only when one is recorded.
///   - sourceLocation: where an issue is recorded; the caller's line by default.
/// - Returns: what the calling thread asked of the heap inside the audit.
/// - Throws: what compiling the pipeline throws; an audit that cannot run is recorded as an
///   issue, as by `expectNoAllocations`.
@discardableResult
public func expectNoAllocationsRunning<Output: SignalDomain>(
    _ pipeline: Pipeline<Samples, Output>, format: SignalFormat = SignalFormat(sampleRate: 48_000), blockSize: Int = 512, blocks: Int = 1_000,
    crossovers: CrossoverTable = .shipped, _ comment: @autoclosure () -> String = "", sourceLocation: SourceLocation = #_sourceLocation
) throws(DSPError) -> AllocationCounts {
    let driven = try DrivenPipeline(pipeline, format: format, blockSize: blockSize, crossovers: crossovers)
    defer { driven.finish() }
    let buffer = try AudioBuffer(channelCount: format.channelCount, capacity: max(blockSize, 1))
    for channel in 0 ..< format.channelCount {
        let noise = TestSignal.whiteNoise(count: max(blockSize, 1), seed: UInt64(17 + channel), amplitude: 0.5)
        let target = buffer.channel(channel)
        for index in noise.indices { target[index] = noise[index] }
    }
    let block = buffer.block(frameCount: max(blockSize, 1))
    var warm = 0
    while warm < 8 {
        driven.run(block)
        warm += 1
    }
    return expectNoAllocations(comment(), sourceLocation: sourceLocation) {
        var count = 0
        while count < blocks {
            driven.run(block)
            count += 1
        }
    }
}
