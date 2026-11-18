/// The latest-value slot behind a result binding (OUT-2). The analysis thread writes each
/// result into it, wait-free; on the main run loop the session copies the slots whose value
/// changed into their bindings.
///
/// Threading: `write` belongs to the analysis thread (one writer). The reads belong to the
/// main thread. A scalar is one atomic word; a vector is guarded by a sequence counter, so a
/// reader that overlaps a write sees it and reads again.
final class ResultSlot: PlanSink, @unchecked Sendable {
    let kind: BoundResult.Kind
    /// For a scalar: value bits in the high half, confidence bits in the low half.
    private let word: OpaquePointer
    /// Writes so far. For a vector it is odd while a write is in progress.
    private let version: OpaquePointer
    private var values: AlignedBuffer<Float>?
    private var capacity = 0
    private let count: OpaquePointer

    init(kind: BoundResult.Kind) throws(DSPError) {
        self.kind = kind
        guard let cells = AtomicCells.make([0, 0, 0]) else {
            throw .resourceAllocationFailed(what: "a result slot")
        }
        word = cells[0]
        version = cells[1]
        count = cells[2]
    }

    deinit {
        ztd_atomic_destroy(word)
        ztd_atomic_destroy(version)
        ztd_atomic_destroy(count)
    }

    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError) {
        guard kind == .vector else { return }
        if case .real(let size) = format { capacity = size } else { capacity = axis?.rowCount ?? 0 }
        values = try AlignedBuffer<Float>(count: max(capacity, 1))
    }

    func release() {}

    func write(_ frame: FrameView) {
        switch kind {
        case .value, .frame:
            guard let scalar = frame.scalar else { return }
            ztd_atomic_store(word, UInt64(scalar.value.bitPattern) << 32 | UInt64(scalar.confidence.bitPattern))
            _ = ztd_atomic_add(version, 1)
        case .vector:
            guard let real = frame.real, let source = real.values.baseAddress, let values else { return }
            let length = min(real.count, capacity)
            _ = ztd_atomic_add(version, 1)                    // odd: a write is in progress
            ztd_atomic_barrier()                              // … and seen as such before the values move
            values.copy(from: source, count: length)
            ztd_atomic_store(count, UInt64(length))
            _ = ztd_atomic_add(version, 1)                    // even again: the write is complete
        }
    }

    /// The number of completed writes, as the reader compares it with the last one it saw.
    var writes: UInt64 { ztd_atomic_load(version) }

    /// The latest scalar result. Main thread.
    func readScalar() -> ScalarFrame {
        let bits = ztd_atomic_load(word)
        return ScalarFrame(value: Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)),
                           confidence: Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
    }

    /// The latest vector result, or `nil` when none was written yet or a write kept overlapping
    /// the read. Main thread; allocates the array it returns (OUT-5).
    func readVector() -> [Float]? {
        guard let values else { return nil }
        var attempt = 0
        while attempt < 8 {
            let before = ztd_atomic_load(version)
            if before > 0, before & 1 == 0 {
                let length = Int(ztd_atomic_load(count))
                let copy = Array(UnsafeBufferPointer(start: values.baseAddress, count: min(length, capacity)))
                ztd_atomic_barrier()                          // the copy is complete before it is judged
                if ztd_atomic_load(version) == before { return copy }
            } else if before == 0 {
                return nil
            }
            attempt += 1
        }
        return nil
    }
}
