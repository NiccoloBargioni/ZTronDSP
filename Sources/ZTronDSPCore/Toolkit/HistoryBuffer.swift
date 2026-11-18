import Darwin

/// The last `count` samples of a stream as one contiguous window, oldest first (§5.11.4).
///
/// Every sample is stored twice, `count` positions apart, so the window never wraps and
/// reading it copies nothing. Samples may be appended in batches of any size.
///
/// Threading: create and release on the control context. `append`, `window` and `reset` are
/// allocation-free and belong to one thread at a time (the analysis thread).
public final class HistoryBuffer {
    /// The window length.
    public let count: Int
    @usableFromInline let storage: AlignedBuffer<Float>
    @usableFromInline var position: Int
    @usableFromInline var appended: Int

    /// Creates a history of `count` samples, all zero.
    ///
    /// - Throws: `DSPError.resourceAllocationFailed` for a count below 1 or when memory cannot
    ///   be had.
    public init(count: Int) throws(DSPError) {
        guard count >= 1 else { throw .resourceAllocationFailed(what: "a history of \(count) samples") }
        self.count = count
        self.storage = try AlignedBuffer<Float>(count: 2 * count)
        self.position = 0
        self.appended = 0
    }

    /// The number of samples appended since creation or the last reset.
    @inlinable public var totalAppended: Int { appended }

    /// True once at least `count` samples were appended: the window holds no initial zeros.
    @inlinable public var isFull: Bool { appended >= count }

    /// The last `count` samples, oldest first. Valid until the next `append` or `reset`.
    @inlinable public var window: UnsafePointer<Float> {
        UnsafePointer(storage.baseAddress + position)
    }

    /// The most recent `length` samples (at most `count`), oldest first.
    @inlinable
    public func latest(_ length: Int) -> UnsafePointer<Float> {
        let length = min(max(length, 0), count)
        return UnsafePointer(storage.baseAddress + position + (count - length))
    }

    /// Appends `sampleCount` samples.
    @inlinable
    public func append(_ samples: UnsafePointer<Float>, count sampleCount: Int) {
        guard sampleCount > 0 else { return }
        appended &+= sampleCount
        var source = samples
        var remaining = sampleCount
        // Only the last `count` samples of a long batch can be in the window.
        if remaining > count {
            source += remaining - count
            remaining = count
        }
        let base = storage.baseAddress
        let stride = MemoryLayout<Float>.stride
        while remaining > 0 {
            let run = min(remaining, count - position)
            memcpy(base + position, source, run * stride)
            memcpy(base + position + count, source, run * stride)
            position += run
            if position == count { position = 0 }
            source += run
            remaining -= run
        }
    }

    /// Appends one sample.
    @inlinable
    public func append(_ sample: Float) {
        let base = storage.baseAddress
        base[position] = sample
        base[position + count] = sample
        position += 1
        if position == count { position = 0 }
        appended &+= 1
    }

    /// Back to zeros, as at creation (ACT-10).
    @inlinable
    public func reset() {
        storage.clear()
        position = 0
        appended = 0
    }
}
