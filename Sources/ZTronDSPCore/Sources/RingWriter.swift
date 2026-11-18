/// The storage behind a ``RingWriter``: a single-producer, single-consumer ring of planar
/// Float32 frames, created by the engine for one push source (RT-4).
///
/// Threading: created and released on the control context. One thread writes, through a
/// `RingWriter`; one thread reads, the analysis thread.
final class SampleRing: @unchecked Sendable {
    let pointer: OpaquePointer
    let channelCount: Int

    init(channelCount: Int, capacity: Int) throws(DSPError) {
        // A count the ring's 32 bits do not hold is a ring that cannot be had (§9.3).
        guard channelCount >= 1, capacity >= 1, let channels = UInt32(exactly: channelCount), let frames = UInt32(exactly: capacity),
              let ring = ztd_ring_create(channels, frames, ZTD_RING_STORAGE_AUTOMATIC) else {
            throw .resourceAllocationFailed(what: "a ring of \(channelCount) channels of \(capacity) frames")
        }
        pointer = ring
        self.channelCount = channelCount
    }

    deinit {
        ztd_ring_destroy(pointer)
    }
}

/// The writing end of the ring the engine hands a ``PushSampleSource``.
///
/// One thread writes at a time: the audio I/O thread of a hardware source, or the reader
/// thread of a file source. `write` never blocks and never allocates: when the ring is full
/// the newest frames are dropped and counted, and the engine reports `.overrun` (RT-8).
/// `writeWaiting` is for a reader thread that must not lose frames; it sleeps until there is
/// room, so it is not for a real-time thread.
///
/// The writer keeps its ring alive. A source drops the writer it holds when it is given a new
/// one.
public struct RingWriter: Sendable {
    let storage: SampleRing

    init(_ storage: SampleRing) {
        self.storage = storage
    }

    /// The ring as the C layer knows it, a `ztd_ring_t *`, for a source whose I/O callback is
    /// written in C (RT-1).
    public var ring: OpaquePointer { storage.pointer }

    /// Channels of the ring: the source's channel count when the ring was made.
    public var channelCount: Int { storage.channelCount }

    /// Frames the ring holds when full.
    public var capacity: Int { Int(ztd_ring_capacity(storage.pointer)) }

    /// Frames that can be written now.
    public var availableSpace: Int { Int(ztd_ring_space(storage.pointer)) }

    /// Writes the valid frames of `block` and returns how many were written. Frames that do not
    /// fit are dropped and counted.
    ///
    /// A count of frames is taken as the ring counts, in 32 bits, here and in the functions
    /// below: a negative one is none, and one beyond 2³² − 1 is that many (no ring holds them,
    /// and these functions run where nothing can be thrown).
    @discardableResult
    public func write(_ block: AudioBlock) -> Int {
        Int(ztd_ring_write(storage.pointer, block.constantChannelTable, UInt32(clamping: block.frameCount)))
    }

    /// Writes `frameCount` frames from one pointer per channel.
    @discardableResult
    public func write(channels: UnsafePointer<UnsafePointer<Float>?>, frameCount: Int) -> Int {
        Int(ztd_ring_write(storage.pointer, channels, UInt32(clamping: frameCount)))
    }

    /// Writes `frameCount` frames from one interleaved buffer of `frameCount × channelCount`
    /// samples.
    @discardableResult
    public func write(interleaved samples: UnsafePointer<Float>, frameCount: Int) -> Int {
        Int(ztd_ring_write_interleaved(storage.pointer, samples, UInt32(clamping: frameCount)))
    }

    /// Writes every valid frame of `block`, waiting for room when the ring is full, and
    /// returns how many were written: all of them, unless the engine closed the ring because
    /// the source was stopped or re-planned. For reader threads only.
    @discardableResult
    public func writeWaiting(_ block: AudioBlock) -> Int {
        Int(ztd_ring_write_waiting(storage.pointer, block.constantChannelTable, UInt32(clamping: block.frameCount)))
    }

    /// Frames the writer has dropped since the ring was made.
    public var droppedFrames: Int { Int(truncatingIfNeeded: ztd_ring_overrun_frames(storage.pointer)) }
}
