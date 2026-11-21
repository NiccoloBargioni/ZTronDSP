import Darwin

/// A block of audio: one buffer of Float32 samples per channel, non-interleaved (§6.1).
///
/// A block is a borrowed view. It owns nothing and is valid for the call that hands it over:
/// a stage that needs samples later copies them. Blocks are not `Sendable`.
///
/// Threading: reading and writing through a block allocates nothing; it is what
/// `SampleProcessor.process(_:)` and `PullSampleSource.render(into:)` receive on the analysis
/// thread.
public struct AudioBlock {
    /// Channels in the block.
    public let channelCount: Int
    /// Frames each channel can hold.
    public let capacity: Int
    @usableFromInline var frames: Int
    @usableFromInline let table: UnsafePointer<UnsafeMutablePointer<Float>?>

    /// Wraps `channelCount` channel pointers, each with room for `capacity` frames, of which
    /// the first `frameCount` hold samples. The table and the channels must outlive the block.
    @inlinable
    public init(channels: UnsafePointer<UnsafeMutablePointer<Float>?>, channelCount: Int, capacity: Int, frameCount: Int) {
        self.table = channels
        self.channelCount = max(channelCount, 0)
        self.capacity = max(capacity, 0)
        self.frames = min(max(frameCount, 0), max(capacity, 0))
    }

    /// Frames that hold samples.
    @inlinable public var frameCount: Int { frames }

    /// Declares how many frames hold samples, clamped to `0 … capacity`.
    @inlinable
    public mutating func setFrameCount(_ count: Int) {
        frames = min(max(count, 0), capacity)
    }

    /// The samples of one channel. `index` must be in `0 ..< channelCount`; an index outside
    /// it returns channel 0 rather than reading out of bounds.
    @inlinable
    public func channel(_ index: Int) -> UnsafeMutablePointer<Float> {
        table[index >= 0 && index < channelCount ? index : 0].unsafelyUnwrapped
    }

    /// The valid samples of one channel as a buffer.
    @inlinable
    public func samples(ofChannel index: Int) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: channel(index), count: frames)
    }

    /// The channel table as the C kernels take their output: `float *const *`.
    @inlinable public var channelTable: UnsafePointer<UnsafeMutablePointer<Float>?> { table }

    /// The channel table as the C kernels take their input: `const float *const *`.
    @inlinable public var constantChannelTable: UnsafePointer<UnsafePointer<Float>?> {
        UnsafeRawPointer(table).assumingMemoryBound(to: UnsafePointer<Float>?.self)
    }

    /// Sets every valid sample to zero.
    @inlinable
    public func clear() {
        var channel = 0
        while channel < channelCount {
            memset(table[channel].unsafelyUnwrapped, 0, frames * MemoryLayout<Float>.stride)
            channel += 1
        }
    }

    /// Copies the valid samples of `source` into this block, channel by channel, up to this
    /// block's capacity and channel count, and returns the number of frames copied.
    @inlinable
    @discardableResult
    public mutating func copy(from source: AudioBlock) -> Int {
        let count = min(source.frames, capacity)
        let channels = min(source.channelCount, channelCount)
        var channel = 0
        while channel < channels {
            memcpy(table[channel].unsafelyUnwrapped, source.table[channel].unsafelyUnwrapped, count * MemoryLayout<Float>.stride)
            channel += 1
        }
        frames = count
        return count
    }
}

/// Owned storage for a block: `channelCount` aligned channels of `capacity` frames.
///
/// Threading: create and release it on the control context; creating one allocates its
/// storage. `block(frameCount:)` and the pointers do not allocate. One thread at a time.
public final class AudioBuffer {
    /// The number of channels.
    public let channelCount: Int
    /// Frames each channel can hold.
    public let capacity: Int
    @usableFromInline let storage: AlignedBuffer<Float>
    @usableFromInline let table: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    /// Creates zero-filled storage.
    ///
    /// - Throws: `DSPError.resourceAllocationFailed` for a channel count below 1, a negative
    ///   capacity, or when memory cannot be had.
    public init(channelCount: Int, capacity: Int) throws(DSPError) {
        guard channelCount >= 1, capacity >= 0 else {
            throw .resourceAllocationFailed(what: "a block of \(channelCount) channels of \(capacity) frames")
        }
        // Each channel starts on a 64-byte boundary. A size the machine cannot hold is an
        // allocation that failed, not a trap (§9.3).
        let (padded, tooLong) = max(capacity, 1).addingReportingOverflow(15)
        let stride = padded & ~15
        let (cells, tooMany) = stride.multipliedReportingOverflow(by: channelCount)
        guard !tooLong, !tooMany, cells <= 1 << 30, channelCount <= 1 << 16 else {
            throw .resourceAllocationFailed(what: "a block of \(channelCount) channels of \(capacity) frames")
        }
        // Buffers that are read and written in one loop must not sit a whole number of pages
        // apart, or every load waits on a store it only seems to depend on. Each buffer
        // therefore starts at its own offset within a page (measured: about 260 ns per block
        // of 512 frames between a lucky and an unlucky launch, WP-324).
        let color = Int(ztd_buffer_color()) / MemoryLayout<Float>.stride
        self.storage = try AlignedBuffer<Float>(count: cells + 4_096 / MemoryLayout<Float>.stride)
        self.table = .allocate(capacity: channelCount)
        var channel = 0
        while channel < channelCount {
            table[channel] = storage.baseAddress + color + channel * stride
            channel += 1
        }
        self.channelCount = channelCount
        self.capacity = capacity
    }

    /// Creates storage holding a copy of `channels`, which must be of equal length.
    public convenience init(channels: [[Float]]) throws(DSPError) {
        let capacity = channels.first?.count ?? 0
        guard channels.allSatisfy({ $0.count == capacity }) else {
            throw .resourceAllocationFailed(what: "a block from channels of unequal length")
        }
        try self.init(channelCount: channels.count, capacity: capacity)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                if let from = source.baseAddress, capacity > 0 {
                    memcpy(table[index].unsafelyUnwrapped, from, capacity * MemoryLayout<Float>.stride)
                }
            }
        }
    }

    deinit {
        table.deallocate()
    }

    /// A view of the storage with `frameCount` valid frames (the whole capacity by default).
    @inlinable
    public func block(frameCount: Int? = nil) -> AudioBlock {
        AudioBlock(channels: UnsafePointer(table), channelCount: channelCount, capacity: capacity, frameCount: frameCount ?? capacity)
    }

    /// The samples of one channel.
    @inlinable
    public func channel(_ index: Int) -> UnsafeMutablePointer<Float> {
        table[index >= 0 && index < channelCount ? index : 0].unsafelyUnwrapped
    }

    /// Sets every sample to zero.
    public func clear() {
        storage.clear()
    }

    /// The first `frameCount` samples of a channel as a new array (allocates).
    public func array(ofChannel index: Int, frameCount: Int? = nil) -> [Float] {
        Array(UnsafeBufferPointer(start: channel(index), count: min(frameCount ?? capacity, capacity)))
    }
}
