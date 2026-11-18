import AVFAudio
import CZTronDSP
import ZTronDSPCore

/// The pacing buffer of a node tap (§4.4, E-15): what the tap has delivered, in bursts of
/// 100 ms and more, and the pacer has not yet released block by block.
///
/// It is a ring of the package's own kind, filled by the same function that fills a ring from
/// a sink node, so a burst is taken in whichever of the two Float32 layouts it comes. When the
/// pacer falls so far behind that the buffer is full, the newest frames are dropped and
/// counted, as for a hardware source (RT-8).
///
/// Threading: not `Sendable`. It lives inside the state of its source and is touched only
/// while that state's lock is held: by the tap's thread to append, by the pacing thread to
/// release. Neither is a real-time thread.
final class BurstBuffer {
    let channelCount: Int
    private let ring: OpaquePointer
    private let intake: OpaquePointer
    /// Frames of the largest burst taken so far: the measure of how much may wait.
    private(set) var largestBurst = 0

    /// A buffer for `capacity` frames of `channelCount` channels.
    init(channelCount: Int, capacity: Int) throws(DSPError) {
        guard channelCount >= 1, channelCount <= Int(ZTD_SINK_TAP_MAX_CHANNELS), capacity >= 1, capacity <= 1 << 30,
              let ring = ztd_ring_create(UInt32(channelCount), UInt32(capacity), ZTD_RING_STORAGE_AUTOMATIC) else {
            throw .resourceAllocationFailed(what: "the pacing buffer of a node tap (\(channelCount) channels of \(capacity) frames)")
        }
        guard let intake = ztd_sink_tap_create() else {
            ztd_ring_destroy(ring)
            throw .resourceAllocationFailed(what: "the pacing buffer of a node tap")
        }
        ztd_sink_tap_set_ring(intake, ring)
        self.channelCount = channelCount
        self.ring = ring
        self.intake = intake
    }

    deinit {
        ztd_sink_tap_release(intake)
        ztd_ring_destroy(ring)
    }

    /// Takes one burst of `frameCount` frames.
    func append(_ buffers: UnsafePointer<AudioBufferList>, frameCount: Int) {
        largestBurst = max(largestBurst, frameCount)
        ztd_sink_tap_receive(intake, buffers, UInt32(clamping: frameCount))
    }

    /// Frames waiting to be released.
    var available: Int { Int(ztd_ring_available(ring)) }

    /// Frames that were delivered and not kept: the buffer was full, or the burst was not in
    /// the buffer's layout.
    var lostFrames: Int {
        Int(truncatingIfNeeded: ztd_ring_overrun_frames(ring)) + Int(truncatingIfNeeded: ztd_sink_tap_discarded_frames(intake))
    }

    /// Moves up to `block.capacity` frames, the oldest, into `block`, and returns how many.
    func release(into block: inout AudioBlock) -> Int {
        let frames = Int(ztd_ring_read(ring, block.channelTable, UInt32(clamping: block.capacity)))
        block.setFrameCount(frames)
        return frames
    }
}
