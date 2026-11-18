/// Turns a source of any kind into the one thing the engine runs: a stream of blocks of a
/// fixed size (§4.4). This is the one place that tells a push source from a pull source
/// (ATT-2), and where arbitrary batches become blocks (WP-318) and non-finite samples become
/// zeros (NUM-1).
///
/// Threading: created and released on the control context. `next(into:)` belongs to the one
/// thread that runs the hub; the counters are single atomic words (RT-4).
final class SourceAdapter: @unchecked Sendable {
    /// What a call to `next(into:)` found.
    enum Next {
        /// A block of this many frames: `blockSize`, or fewer for the last block of a stream.
        case block(Int)
        /// Nothing yet: the ring holds less than a block.
        case waiting
        /// The stream is over.
        case ended
    }

    private enum Feed {
        case ring(SampleRing)
        case render(any PullSampleSource)
    }

    let format: SignalFormat
    let blockSize: Int
    let kind: SourceKind
    let pacing: Pacing
    private let feed: Feed

    /// Set by the control context when a push source says it has ended: what the ring still
    /// holds is delivered, then the stream is over.
    private let ending: OpaquePointer
    /// Non-finite samples replaced so far.
    private let nonFinite: OpaquePointer

    // Analysis thread only: the block being assembled from a pull source.
    private var fill = 0
    private var finished = false
    private let unfilled: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    /// `source` as a processed source, when it is one: fed by a session, not by an adapter.
    static func processed(_ source: any SampleSource) -> ProcessedSource? {
        source as? ProcessedSource
    }

    /// The adapter of a prepared source that is not a processed one.
    static func make(for source: any SampleSource, blockSize: Int) throws(DSPError) -> SourceAdapter {
        try SourceAdapter(source: source, blockSize: blockSize)
    }

    /// Adapts a prepared source. A push source is given its ring here.
    private init(source: any SampleSource, blockSize: Int) throws(DSPError) {
        let format = source.format
        guard format.isValid, format.sampleRate <= 1e9, format.channelCount <= 1 << 16 else {
            throw .sourceUnavailable(reason: "the source reports the format \(format) after it was prepared")
        }
        guard blockSize >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "blockSize", reason: "a block holds at least one frame, not \(blockSize)")
        }
        // The ring of a push source has room for half a second, and never less than eight
        // blocks: a tap delivers bursts of 100 ms and more (E-15), and a file reader fills
        // whatever it is given. Its frames are counted here, before anything is made for the
        // source: eight blocks that no `Int` counts are more than any ring holds, and a count
        // beyond the ring's 32 bits is a ring that cannot be had (§9.3).
        let (eightBlocks, uncountable) = blockSize.multipliedReportingOverflow(by: 8)
        let ringCapacity = uncountable ? Int.max : max(eightBlocks, Int((format.sampleRate * 0.5).rounded(.up)))
        let isPush = !(source is any PullSampleSource) && source is any PushSampleSource
        guard !isPush || UInt32(exactly: ringCapacity) != nil else {
            throw .resourceAllocationFailed(what: "a ring of \(format.channelCount) channels of \(ringCapacity) frames")
        }
        guard let cells = AtomicCells.make([0, 0]) else {
            throw .resourceAllocationFailed(what: "the counters of a source")
        }
        let ending = cells[0], nonFinite = cells[1]
        self.ending = ending
        self.nonFinite = nonFinite
        self.format = format
        self.blockSize = blockSize
        unfilled = .allocate(capacity: format.channelCount)
        unfilled.initialize(repeating: nil, count: format.channelCount)

        if let pull = source as? any PullSampleSource {
            kind = .pull
            pacing = pull.pacing
            feed = .render(pull)
        } else if let push = source as? any PushSampleSource {
            kind = .push
            pacing = .realTime
            let ring: SampleRing
            do {
                ring = try SampleRing(channelCount: format.channelCount, capacity: ringCapacity)
            } catch {
                ztd_atomic_destroy(ending)
                ztd_atomic_destroy(nonFinite)
                unfilled.deallocate()
                throw error
            }
            feed = .ring(ring)
            push.connect(to: RingWriter(ring))
        } else {
            ztd_atomic_destroy(ending)
            ztd_atomic_destroy(nonFinite)
            unfilled.deallocate()
            throw .unsupportedConfiguration(
                reason: "\(type(of: source)) is neither a PushSampleSource nor a PullSampleSource; a source adopts one of the two")
        }
    }

    deinit {
        ztd_atomic_destroy(ending)
        ztd_atomic_destroy(nonFinite)
        unfilled.deallocate()
    }

    // MARK: Control context

    /// The source has said it ended: deliver what a ring still holds, then end the stream.
    func endAfterDraining() {
        ztd_atomic_store(ending, 1)
    }

    /// Empties the ring and reopens it. Only while neither end is in use: before the source is
    /// started, with the hub off its thread.
    func rewind() {
        if case .ring(let ring) = feed { ztd_ring_reset(ring.pointer) }
        ztd_atomic_store(ending, 0)
        fill = 0
        finished = false
    }

    /// Lets a writer that waits for room return: the source is being stopped or re-planned.
    func close() {
        if case .ring(let ring) = feed { ztd_ring_close(ring.pointer) }
    }

    /// Throws away what the ring holds, from the reading end: the samples of before an
    /// interruption. Only with the hub off its thread.
    func discardPending() {
        if case .ring(let ring) = feed { _ = ztd_ring_consume(ring.pointer, ztd_ring_available(ring.pointer)) }
        fill = 0
    }

    /// Frames the writer of a push source has dropped since the ring was made or rewound.
    var droppedFrames: Int {
        if case .ring(let ring) = feed { return Int(truncatingIfNeeded: ztd_ring_overrun_frames(ring.pointer)) }
        return 0
    }

    /// Non-finite samples replaced by zeros so far.
    var nonFiniteCount: Int { Int(truncatingIfNeeded: ztd_atomic_load(nonFinite)) }

    // MARK: Analysis thread

    /// Puts the next block into `buffer`, which holds `format.channelCount` channels of at
    /// least `blockSize` frames. Allocation-free.
    func next(into buffer: AudioBuffer) -> Next {
        let frames: Int
        switch feed {
        case .ring(let ring):
            let available = Int(ztd_ring_available(ring.pointer))
            if available >= blockSize {
                frames = blockSize
            } else if ztd_atomic_load(ending) != 0 {
                // Look again: the source may have written between the two reads.
                let rest = Int(ztd_ring_available(ring.pointer))
                guard rest > 0 else { return .ended }
                frames = min(rest, blockSize)
            } else {
                return .waiting
            }
            let table = UnsafePointer(buffer.block().channelTable)
            guard Int(ztd_ring_read(ring.pointer, table, UInt32(frames))) == frames else { return .waiting }

        case .render(let source):
            // Over when the source returned 0, or when it said so in an event.
            guard !finished, ztd_atomic_load(ending) == 0 else { return .ended }
            let channels = format.channelCount
            while fill < blockSize {
                var channel = 0
                while channel < channels {
                    unfilled[channel] = buffer.channel(channel) + fill
                    channel += 1
                }
                var block = AudioBlock(channels: UnsafePointer(unfilled), channelCount: channels, capacity: blockSize - fill, frameCount: 0)
                let produced = min(max(source.render(into: &block), 0), blockSize - fill)
                if produced == 0 {
                    finished = true
                    break
                }
                fill += produced
            }
            guard fill > 0 else { return .ended }
            frames = fill
            fill = 0
        }

        // Where the signal enters: nothing downstream sees a NaN or an infinity (NUM-1).
        var replaced: UInt32 = 0
        var channel = 0
        while channel < format.channelCount {
            let samples = buffer.channel(channel)
            replaced += ztd_copy_finite(samples, samples, UInt32(frames))
            channel += 1
        }
        if replaced > 0 { _ = ztd_atomic_add(nonFinite, UInt64(replaced)) }
        return .block(frames)
    }
}
