import Foundation

/// Where a reader of a feed stands: which columns it has already taken. A reader keeps one
/// and passes it to every `read`; a fresh cursor starts at the oldest column the feed holds.
///
/// A plain value. Each reader has its own.
public struct FeedCursor: Sendable, Hashable {
    // Moved only by the column store of this file, as a `read` takes columns (IMM-1).
    fileprivate(set) var layout: UInt64 = 0
    fileprivate(set) var epoch: UInt64 = 0
    fileprivate(set) var column: UInt64 = 0

    public init() {}
}

/// What one `read` of a feed brought.
public struct FeedRead: Sendable, Hashable {
    /// True when what the reader took before no longer belongs to the feed's history: the
    /// feed was attached anew, cleared for a changed branch, or trimmed. A renderer clears its
    /// texture, and allocates a new one when `rowCount` or `history` changed (V-6).
    public let isReset: Bool
    /// Values per column.
    public let rowCount: Int
    /// Columns the feed keeps.
    public let history: Int
    /// The position, counted from the feed's first column, of the first column copied.
    public let firstColumn: Int
    /// Columns copied into the reader's buffer, oldest first.
    public let columnCount: Int
    /// Columns the reader never saw because the writer overwrote them first. A slow reader
    /// skips; it never blocks the writer.
    public let skipped: Int
}

/// A handle on a liveness observation. The observation ends when the handle is cancelled or
/// released.
public final class FeedObservation: Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Ends the observation.
    public func cancel() {
        onCancel()
    }

    deinit {
        onCancel()
    }
}

/// One shape of a feed's history: rows per column, columns kept, and the storage for them.
/// A feed that is attached to frames of another shape, or trimmed, gets a new one; readers
/// tell layouts apart by their identifier.
final class ColumnLayout {
    let identifier: UInt64
    let rowCount: Int
    let capacity: Int
    let axis: FeedAxis?
    let environment: DSPEnvironment?
    /// Seconds between two columns that arrive in one frame (a waveform's buckets).
    let columnDuration: Double
    /// True for a layout that continues the one before it: it was filled with that layout's
    /// newest columns when it was made, and the writer adds what was written since.
    let inherits: Bool
    /// For a layout that continues another: the columns of that layout it already holds are
    /// those below this number.
    var inheritedThrough: UInt64 = 0
    let values: UnsafeMutablePointer<Float>
    let times: UnsafeMutablePointer<Double>
    /// Columns begun and columns finished: the pair that tells a reader whether what it copied
    /// was overwritten meanwhile.
    let started: OpaquePointer
    let completed: OpaquePointer
    /// The first column that belongs to the present history; it moves when the feed is cleared.
    let floor: OpaquePointer
    let epoch: OpaquePointer

    init(identifier: UInt64, rowCount: Int, capacity: Int, axis: FeedAxis?, environment: DSPEnvironment?, columnDuration: Double,
         inherits: Bool) throws(DSPError) {
        // A history the machine cannot hold is an allocation that failed, not a trap (§9.3).
        let (cells, overflow) = max(rowCount, 1).multipliedReportingOverflow(by: max(capacity, 1))
        guard !overflow, cells <= ColumnLayout.maximumCells else {
            throw .resourceAllocationFailed(what: "a feed of \(capacity) columns of \(rowCount) values")
        }
        // Started, completed, floor, epoch: all four, or none.
        guard let counters = AtomicCells.make([0, 0, 0, 1]) else {
            throw .resourceAllocationFailed(what: "the counters of a feed")
        }
        self.identifier = identifier
        self.rowCount = max(rowCount, 1)
        self.capacity = max(capacity, 1)
        self.axis = axis
        self.environment = environment
        self.columnDuration = columnDuration
        self.inherits = inherits
        started = counters[0]
        completed = counters[1]
        floor = counters[2]
        epoch = counters[3]
        values = .allocate(capacity: self.rowCount * self.capacity)
        values.initialize(repeating: 0, count: self.rowCount * self.capacity)
        times = .allocate(capacity: self.capacity)
        times.initialize(repeating: 0, count: self.capacity)
    }

    /// The most values one layout holds: a gigabyte of floats.
    static let maximumCells = 1 << 28

    deinit {
        values.deallocate()
        times.deallocate()
        ztd_atomic_destroy(started)
        ztd_atomic_destroy(completed)
        ztd_atomic_destroy(floor)
        ztd_atomic_destroy(epoch)
    }

    /// Copies the columns `first ..< end` into `target`, oldest first, and their times into
    /// `times` when it is given.
    func copy(_ first: UInt64, _ end: UInt64, into target: UnsafeMutablePointer<Float>, times target2: UnsafeMutablePointer<Double>?) {
        var column = first
        var written = 0
        while column < end {
            // Up to the end of the ring in one piece.
            let slot = Int(column % UInt64(capacity))
            let run = min(Int(end - column), capacity - slot)
            memcpy(target + written * rowCount, values + slot * rowCount, run * rowCount * MemoryLayout<Float>.stride)
            if let target2 { memcpy(target2 + written, times + slot, run * MemoryLayout<Double>.stride) }
            written += run
            column += UInt64(run)
        }
    }
}

/// The store behind a feed: a ring of columns with one writer and any number of readers
/// (RT-4: "a feed's sequence-locked column store").
///
/// The writer, the analysis thread, overwrites the oldest column with one `memcpy` and two
/// atomic stores; it never waits and never allocates. A reader copies the columns it has not
/// seen and then checks, with the writer's two counters, that none of them was overwritten
/// while it copied; those that were are dropped from what it returns. Readers lock only
/// against one another and against the control context, never against the writer.
///
/// Threading: `append` and `clear` belong to the writer. `configure`, `trim` and `drain`
/// belong to the control context. Everything else is for any thread but the analysis thread.
final class ColumnStore: @unchecked Sendable {
    /// Columns asked for when the feed was created.
    let declaredHistory: Int
    let minimumHistory: Int

    private let layouts: Handoff<ColumnLayout>?
    private let reading = Locked<ColumnLayout?>(nil)
    private let generationWord: OpaquePointer?
    private let liveWord: OpaquePointer?
    private let identifiers = Locked<UInt64>(0)
    private let observers = Locked<[UUID: @MainActor @Sendable (Bool) -> Void]>([:])

    init(history: Int, minimumHistory: Int?) {
        declaredHistory = max(history, 1)
        self.minimumHistory = min(max(minimumHistory ?? history, 1), max(history, 1))
        layouts = try? Handoff<ColumnLayout>()
        generationWord = ztd_atomic_create(0)
        liveWord = ztd_atomic_create(0)
    }

    deinit {
        if let generationWord { ztd_atomic_destroy(generationWord) }
        if let liveWord { ztd_atomic_destroy(liveWord) }
    }

    // MARK: Any thread but the analysis thread

    /// One atomic load: moves with every new column and with every clear, trim or new layout.
    var generation: UInt64 { generationWord.map { ztd_atomic_load($0) } ?? 0 }

    var isLive: Bool { liveWord.map { ztd_atomic_load($0) != 0 } ?? false }

    var layout: ColumnLayout? { reading.get() }

    /// Columns the feed holds now.
    var columnCount: Int {
        guard let layout = reading.get() else { return 0 }
        let completed = ztd_atomic_load(layout.completed), floor = ztd_atomic_load(layout.floor)
        return Int(min(completed - min(floor, completed), UInt64(layout.capacity)))
    }

    func setLive(_ live: Bool) {
        guard let liveWord, ztd_atomic_exchange(liveWord, live ? 1 : 0) != (live ? 1 : 0) else { return }
        let handlers = Array(observers.get().values)
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(live) }
        }
    }

    func observeLiveness(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> FeedObservation {
        let key = UUID()
        observers.withLock { $0[key] = handler }
        return FeedObservation { [weak self] in
            self?.observers.withLock { $0[key] = nil }
        }
    }

    func read(_ cursor: inout FeedCursor, into buffer: UnsafeMutableBufferPointer<Float>, times: UnsafeMutableBufferPointer<Double>?) -> FeedRead {
        guard let layout = reading.get() else {
            return FeedRead(isReset: false, rowCount: 0, history: declaredHistory, firstColumn: 0, columnCount: 0, skipped: 0)
        }
        let epoch = ztd_atomic_load(layout.epoch)
        var isReset = false
        if cursor.layout != layout.identifier || cursor.epoch != epoch {
            isReset = true
            cursor = FeedCursor()
            cursor.layout = layout.identifier
            cursor.epoch = epoch
        }
        let capacity = UInt64(layout.capacity)
        let completed = ztd_atomic_load(layout.completed)
        let wanted = max(cursor.column, ztd_atomic_load(layout.floor))
        var first = max(wanted, completed > capacity ? completed - capacity : 0)
        var skipped = Int(first - wanted)
        let room = min(buffer.count / layout.rowCount, times?.count ?? Int.max)
        let end = min(completed, first + UInt64(room))
        if end > first, let target = buffer.baseAddress {
            layout.copy(first, end, into: target, times: times?.baseAddress)
            // Columns the writer came round to while they were being copied are not whole. The
            // barrier makes the copy complete before the counter that judges it is read.
            ztd_atomic_barrier()
            let begun = ztd_atomic_load(layout.started)
            let valid = min(max(first, begun > capacity ? begun - capacity : 0), end)
            if valid > first {
                let lost = Int(valid - first), kept = Int(end - valid)
                memmove(target, target + lost * layout.rowCount, kept * layout.rowCount * MemoryLayout<Float>.stride)
                if let stamps = times?.baseAddress { memmove(stamps, stamps + lost, kept * MemoryLayout<Double>.stride) }
                skipped += lost
                first = valid
            }
        }
        if ztd_atomic_load(layout.epoch) != epoch {
            // Cleared while it was read: nothing of this is part of the history any more. The
            // cursor still names the old epoch, so the next read starts over.
            return FeedRead(isReset: true, rowCount: layout.rowCount, history: layout.capacity, firstColumn: Int(first), columnCount: 0, skipped: 0)
        }
        cursor.column = max(end, first)
        return FeedRead(isReset: isReset, rowCount: layout.rowCount, history: layout.capacity, firstColumn: Int(first),
                        columnCount: Int(max(end, first) - first), skipped: skipped)
    }

    /// A consistent copy of everything the feed holds: the layout it belongs to, the values
    /// column by column, oldest first, and the time of each column.
    func snapshot() -> (layout: ColumnLayout, values: [Float], times: [Double])? {
        guard let layout = reading.get() else { return nil }
        var attempt = 0
        while attempt < 16 {
            attempt += 1
            let epoch = ztd_atomic_load(layout.epoch)
            let capacity = UInt64(layout.capacity)
            let completed = ztd_atomic_load(layout.completed)
            let first = max(ztd_atomic_load(layout.floor), completed > capacity ? completed - capacity : 0)
            let count = Int(completed - min(first, completed))
            var values = [Float](repeating: 0, count: count * layout.rowCount)
            var times = [Double](repeating: 0, count: count)
            var lost = 0
            values.withUnsafeMutableBufferPointer { target in
                times.withUnsafeMutableBufferPointer { stamps in
                    guard count > 0, let base = target.baseAddress else { return }
                    layout.copy(first, completed, into: base, times: stamps.baseAddress)
                    ztd_atomic_barrier()
                    let begun = ztd_atomic_load(layout.started)
                    lost = Int(min(max(first, begun > capacity ? begun - capacity : 0), completed) - first)
                }
            }
            guard ztd_atomic_load(layout.epoch) == epoch else { continue }
            if lost > 0 {
                values.removeFirst(lost * layout.rowCount)
                times.removeFirst(lost)
            }
            return (layout, values, times)
        }
        return (layout, [], [])
    }

    // MARK: Control context

    /// Prepares the store for columns of `rowCount` values. What it holds is kept when the
    /// shape is the one it has; otherwise a new, empty layout takes its place.
    func configure(rowCount: Int, axis: FeedAxis?, environment: DSPEnvironment?, columnDuration: Double) throws(DSPError) {
        guard let layouts, generationWord != nil, liveWord != nil else { throw .resourceAllocationFailed(what: "the counters of a feed") }
        if let current = reading.get(), current.rowCount == max(rowCount, 1), current.axis == axis, current.environment == environment,
           current.columnDuration == columnDuration {
            return
        }
        let capacity = reading.get()?.capacity ?? declaredHistory
        let layout = try ColumnLayout(identifier: nextIdentifier(), rowCount: rowCount, capacity: capacity, axis: axis, environment: environment,
                                      columnDuration: columnDuration, inherits: false)
        layouts.publish(layout)
        reading.set(layout)
        bump()
    }

    /// Drops the oldest columns down to the minimum the feed was created with (MEM-1). The
    /// smaller layout is filled here with a consistent copy of the newest columns, so readers
    /// have them at once, whether or not a writer runs; a writer that does run adds the
    /// columns it wrote meanwhile when it next writes. Returns whether there was anything to
    /// give.
    func trim() -> Bool {
        guard let layouts, let current = reading.get(), current.capacity > minimumHistory else { return false }
        guard let layout = try? ColumnLayout(identifier: nextIdentifier(), rowCount: current.rowCount, capacity: minimumHistory, axis: current.axis,
                                             environment: current.environment, columnDuration: current.columnDuration, inherits: true) else {
            return false
        }
        let capacity = UInt64(current.capacity), kept = UInt64(layout.capacity)
        var attempt = 0
        while attempt < 64 {
            attempt += 1
            let completed = ztd_atomic_load(current.completed)
            let oldest = max(ztd_atomic_load(current.floor), completed > capacity ? completed - capacity : 0)
            let first = max(oldest, completed > kept ? completed - kept : 0)
            current.copy(first, completed, into: layout.values, times: layout.times)
            ztd_atomic_barrier()
            let begun = ztd_atomic_load(current.started)
            // A column the writer came round to while it was copied is not whole: again.
            if begun > first + capacity { continue }
            ztd_atomic_store(layout.started, completed - first)
            ztd_atomic_store(layout.completed, completed - first)
            layout.inheritedThrough = completed
            break
        }
        layouts.publish(layout)
        reading.set(layout)
        bump()
        return true
    }

    /// Frees the layouts the writer has finished with.
    func drain() {
        layouts?.drainRetired()
    }

    private func nextIdentifier() -> UInt64 {
        identifiers.withLock { value in
            value += 1
            return value
        }
    }

    private func bump() {
        if let generationWord { _ = ztd_atomic_add(generationWord, 1) }
    }

    // MARK: The writer

    /// The layout the writer writes into, taking a new one when the control context handed
    /// one over. Nothing of the old layout is held once the new one is installed: the control
    /// context frees it (RT-3).
    @inline(__always)
    private func writing() -> ColumnLayout? {
        guard let layouts else { return nil }
        if let pending = layouts.take() {
            if pending.inherits { catchUp(pending, from: layouts.installed) }
            layouts.install(pending)
        }
        return layouts.installed
    }

    /// Adds to a layout that continues `old` the columns the writer wrote to `old` after the
    /// control context copied it.
    private func catchUp(_ layout: ColumnLayout, from old: ColumnLayout?) {
        guard let old, old.rowCount == layout.rowCount, let generationWord else { return }
        let written = ztd_atomic_load(old.completed), capacity = UInt64(old.capacity)
        var column = max(layout.inheritedThrough, written > capacity ? written - capacity : 0)
        while column < written {
            let slot = Int(column % capacity)
            write(old.values + slot * old.rowCount, count: old.rowCount, time: old.times[slot], into: layout, generationWord)
            column += 1
        }
    }

    /// Appends one column of `count` values; a column of another length is cut or padded with
    /// zeros. Allocation-free.
    @inline(__always)
    func append(_ column: UnsafePointer<Float>, count: Int, time: Double) {
        guard let layout = writing(), let generationWord else { return }
        write(column, count: count, time: time, into: layout, generationWord)
    }

    @inline(__always)
    private func write(_ column: UnsafePointer<Float>, count: Int, time: Double, into layout: ColumnLayout, _ generationWord: OpaquePointer) {
        let number = ztd_atomic_load(layout.completed)
        ztd_atomic_store(layout.started, number + 1)
        // The announcement is visible to every reader before the column is touched.
        ztd_atomic_barrier()
        let slot = Int(number % UInt64(layout.capacity))
        let target = layout.values + slot * layout.rowCount
        let copied = min(count, layout.rowCount)
        memcpy(target, column, copied * MemoryLayout<Float>.stride)
        if copied < layout.rowCount { memset(target + copied, 0, (layout.rowCount - copied) * MemoryLayout<Float>.stride) }
        layout.times[slot] = time
        ztd_atomic_store(layout.completed, number + 1)
        _ = ztd_atomic_add(generationWord, 1)
    }

    /// Seconds between two columns of one frame, for the writer. It takes the layout the control
    /// context prepared, as a write does: the first frame is spaced like every other.
    var columnDuration: Double { writing()?.columnDuration ?? 0 }

    /// What the store holds is not part of what follows (SWAP-3). Allocation-free.
    func clear() {
        guard let layout = writing(), let generationWord else { return }
        ztd_atomic_store(layout.floor, ztd_atomic_load(layout.completed))
        _ = ztd_atomic_add(layout.epoch, 1)
        _ = ztd_atomic_add(generationWord, 1)
    }
}
