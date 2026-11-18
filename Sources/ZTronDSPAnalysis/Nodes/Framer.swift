import Darwin
import ZTronDSPCore

/// Cuts a stream of samples, arriving in batches of any size, into frames of `frameSize`
/// samples that start `hopSize` samples apart (§6.4.1, §7.2 row 2): what a framing step is
/// built on.
///
/// The samples are kept in a mirrored ring (`vm_remap`, E-18): every frame is a contiguous
/// view of the ring, and nothing is copied per hop. Where the system refuses the mirror the
/// framer keeps a doubled history instead, which copies each sample twice as it arrives and
/// gives the same frames (§13.1).
///
/// ```swift
/// var offset = 0
/// while offset < count {
///     offset += framer.append(samples + offset, count: count - offset)
///     while let frame = framer.frame {
///         use(frame, alignedTo: framer.framePosition)       // frameSize samples
///         framer.advance()
///     }
/// }
/// ```
///
/// Threading: create and release on the control context (it allocates). `append`, `frame`,
/// `advance` and `reset` allocate nothing and take no lock; they belong to one thread at a
/// time (the analysis thread). A framer is not `Sendable`.
public final class Framer {
    /// Samples per frame.
    public let frameSize: Int
    /// Samples between the starts of two frames.
    public let hopSize: Int
    /// Where a frame sits on the signal.
    public let alignment: FrameAlignment
    /// True when frames are views of a mirrored ring: nothing is copied per hop.
    public let isMirrored: Bool
    /// The most samples the framer holds at once.
    public let capacity: Int

    private let ring: OpaquePointer?
    private let history: HistoryBuffer?
    /// One channel pointer, as the ring takes what it is given.
    private let table: UnsafeMutablePointer<UnsafePointer<Float>?>
    /// Samples the signal is extended by at its start, by reflection: half a frame when
    /// centred, none when causal.
    private let lead: Int
    /// The first `lead + 1` samples, kept until the reflection can be written.
    private let head: AlignedBuffer<Float>
    private let reflection: AlignedBuffer<Float>
    private var headCount = 0
    private var isPrimed: Bool
    /// Samples held that no hop has passed yet.
    private var buffered = 0
    private var index = 0

    /// - Parameters:
    ///   - frameSize: samples per frame, at least 1.
    ///   - hopSize: samples between frame starts, `1 … frameSize`.
    /// - Throws: `DSPError.invalidParameter` for sizes that do not fit together,
    ///   `DSPError.resourceAllocationFailed` when memory cannot be had.
    public convenience init(frameSize: Int, hopSize: Int, alignment: FrameAlignment = .causal) throws(DSPError) {
        try self.init(frameSize: frameSize, hopSize: hopSize, alignment: alignment, mirrored: true)
    }

    /// `mirrored: false` forces the fall-back storage, for tests.
    init(frameSize: Int, hopSize: Int, alignment: FrameAlignment, mirrored: Bool) throws(DSPError) {
        guard frameSize >= 1, frameSize <= 1 << 28 else {
            throw .invalidParameter(stage: .none, parameter: "frameSize", reason: "a frame holds between 1 and 2²⁸ samples, not \(frameSize)")
        }
        guard hopSize >= 1, hopSize <= frameSize else {
            throw .invalidParameter(stage: .none, parameter: "hopSize", reason: "a hop of \(hopSize) samples does not fit a frame of \(frameSize): it lies between 1 and the frame size")
        }
        self.frameSize = frameSize
        self.hopSize = hopSize
        self.alignment = alignment
        lead = alignment == .centered ? frameSize / 2 : 0
        head = try AlignedBuffer<Float>(count: lead + 1)
        reflection = try AlignedBuffer<Float>(count: max(lead, 1))
        isPrimed = lead == 0

        // Room for a frame and as much again, so a batch seldom has to wait for a hop.
        let wanted = 2 * frameSize
        let mirror: OpaquePointer? = mirrored ? ztd_ring_create(1, UInt32(wanted), ZTD_RING_STORAGE_MIRRORED) : nil
        if let mirror {
            ring = mirror
            history = nil
            capacity = Int(ztd_ring_capacity(mirror))
        } else {
            ring = nil
            history = try HistoryBuffer(count: wanted)
            capacity = wanted
        }
        isMirrored = mirror != nil
        table = .allocate(capacity: 1)
        table.initialize(to: nil)
    }

    deinit {
        ztd_ring_destroy(ring)
        table.deinitialize(count: 1)
        table.deallocate()
    }

    /// Takes up to `count` samples and returns how many it took. It takes fewer than it is
    /// given when it is full: read the frames that are ready, then append the rest.
    public func append(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var taken = 0
        if !isPrimed {
            // Centred framing reflects the signal at its start: x[−n] = x[n]. The reflection of
            // the first half frame needs the samples 1 … lead, so those are collected first.
            let wanted = min(lead + 1 - headCount, count)
            memcpy(head.baseAddress + headCount, samples, wanted * MemoryLayout<Float>.stride)
            headCount += wanted
            taken = wanted
            guard headCount == lead + 1 else { return taken }
            var position = 0
            while position < lead {
                reflection.baseAddress[position] = head.baseAddress[lead - position]
                position &+= 1
            }
            store(UnsafePointer(reflection.baseAddress), count: lead)
            store(UnsafePointer(head.baseAddress), count: lead + 1)
            isPrimed = true
        }
        let room = min(capacity - buffered, count - taken)
        if room > 0 {
            store(samples + taken, count: room)
            taken += room
        }
        return taken
    }

    private func store(_ samples: UnsafePointer<Float>, count: Int) {
        if let ring {
            table.pointee = samples
            _ = ztd_ring_write(ring, table, UInt32(count))
        } else if let history {
            history.append(samples, count: count)
        }
        buffered += count
    }

    /// The frame that is ready: `frameSize` samples, oldest first, valid until the next
    /// `advance`, `append` or `reset`. `nil` while fewer samples than a frame are held.
    public var frame: UnsafePointer<Float>? {
        guard buffered >= frameSize else { return nil }
        if let ring { return ztd_ring_peek(ring, 0, UInt32(frameSize)) }
        return history?.latest(buffered)
    }

    /// Frames passed since creation or the last reset: the index of the frame that is ready,
    /// or of the next one.
    public var frameIndex: Int { index }

    /// The sample the ready frame is aligned to, counted from the first sample appended since
    /// creation or the last reset: the frame's last sample when causal, its centre when
    /// centred. A 64-bit count: it does not wrap in any session (§7.5 row 2).
    public var framePosition: Int {
        alignment == .centered ? index &* hopSize : index &* hopSize &+ frameSize &- 1
    }

    /// Moves on by one hop. Does nothing while no frame is ready.
    public func advance() {
        guard buffered >= frameSize else { return }
        if let ring { _ = ztd_ring_consume(ring, UInt32(hopSize)) }
        buffered -= hopSize
        index &+= 1
    }

    /// Back to the state at creation: a cold start (ACT-10).
    public func reset() {
        if let ring { ztd_ring_reset(ring) }
        history?.reset()
        headCount = 0
        isPrimed = lead == 0
        buffered = 0
        index = 0
    }
}
