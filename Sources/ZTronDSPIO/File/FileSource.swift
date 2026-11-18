import AVFAudio
import CZTronDSP
import Foundation
import ZTronDSPCore

/// An audio file as a source (§4.4): anything `AVAudioFile` reads, delivered as Float32.
///
/// ```swift
/// let recording = FileSource(url: url)                                   // at the speed it was recorded
/// let batch = FileSource(url: url, pacing: .asFastAsPossible)            // as fast as it is processed
/// let resampled = FileSource(url: url, sampleRate: 16_000)               // converted when it is opened
/// ```
///
/// The file is read on a thread of the source's own, because file reads block and message
/// Objective-C, which the analysis thread must not do. That thread writes into the engine's
/// ring and waits for room when the ring is full, so no sample is ever lost, whatever the
/// pacing: with `.realTime` a block is released when the clock reaches the time of its first
/// frame; with `.asFastAsPossible` the reader is held back only by how fast the pipeline
/// drains the ring. After its last write the source reports `.ended`, and the session
/// finishes once the ring is drained.
///
/// The format is the file's channel count at the file's sample rate, or at `sampleRate` when
/// one is given: the file is then rate-converted as it is read. Arbitrary-ratio resampling
/// inside a pipeline is not offered; this is the place for it (§1.4).
///
/// Stopping and starting the session continues the file where the pipeline left it: what
/// had been read ahead into the ring is read again. Preparing the source, which the engine
/// does before the first attachment and when a finished session is started again, starts
/// the file over.
///
/// The source reads the file and nothing else: it does not touch the audio session, and the
/// package writes nothing to disk (§9.4).
///
/// Threading: as every source, `prepare`, `start`, `stop` and `connect(to:)` are called by the
/// engine on its control context. `prepare` opens the file on the background executor.
/// `stop` waits until the reader thread has ended, which takes as long as one read, and for
/// five seconds at most: a reader that is stuck in a read longer than that is left to end by
/// itself, and the source has to be prepared again before it starts.
public final class FileSource: PushSampleSource {
    /// One run of the reader thread, and what passes between it and the control side: the
    /// reader, while no thread reads it, and the frames the thread wrote.
    private struct Run {
        let thread: SourceThread
        let handover: Guarded<(reader: FileReader?, written: Int)>
    }

    private struct State {
        /// The open file, while no thread reads it.
        var reader: FileReader?
        var outlet: RingWriter?
        var run: Run?
        /// Frames the pipeline has been given since the file was prepared: where the next
        /// start continues.
        var position = 0
    }

    private let url: URL
    private let pacing: Pacing
    private let sampleRate: Double?
    private let blockSize: Int
    private let clock: any PacingClock
    /// How long `stop()` waits for the reader thread, in seconds.
    private let stopTimeout: Double
    private let channel = SourceEventChannel()
    private let current = Guarded(SignalFormat(sampleRate: 0, channelCount: 0))
    private let state = Guarded(State())

    /// A source that reads the file at `url`.
    ///
    /// - Parameters:
    ///   - pacing: `.realTime`, the default, delivers the file at the speed it plays at;
    ///     `.asFastAsPossible` as fast as the pipeline takes it.
    ///   - sampleRate: the rate to deliver. `nil`, the default, is the file's own.
    ///   - blockSize: frames read and released at a time; the engine's block size is the
    ///     natural choice. At least 1.
    public convenience init(url: URL, pacing: Pacing = .realTime, sampleRate: Double? = nil, blockSize: Int = 512) {
        self.init(url: url, pacing: pacing, sampleRate: sampleRate, blockSize: blockSize, clock: MonotonicClock())
    }

    /// A source with the clock a test holds (COV-5), and the time `stop()` waits for a
    /// reader that is stuck in a read.
    init(url: URL, pacing: Pacing, sampleRate: Double?, blockSize: Int, clock: any PacingClock, stopTimeout: Double = 5) {
        self.url = url
        self.pacing = pacing
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        self.clock = clock
        self.stopTimeout = stopTimeout
    }

    deinit {
        stop()
    }

    /// The file's channel count, at its own rate or at the one asked for: valid after
    /// `prepare()`. May be read on any thread.
    public var format: SignalFormat { current.get() }

    /// What happens to the source: `.ended` after its last write, `.failed` when a read
    /// fails. One consumer, which is the engine while the source is attached.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    /// Opens the file, at its first frame, and reads its format.
    ///
    /// - Throws: `sourceUnavailable` when the file is missing or cannot be read;
    ///   `invalidParameter` for a block size or a sample rate that is not one;
    ///   `unsupportedConfiguration` when the file cannot be converted to the rate asked for;
    ///   `cancelled` when the calling task was cancelled.
    public func prepare() async throws(DSPError) {
        stop()
        let url = url, sampleRate = sampleRate, blockSize = blockSize
        let opened = try await BackgroundWork.run { _ throws(DSPError) in
            Guarded<FileReader?>(try FileReader(url: url, sampleRate: sampleRate, blockSize: blockSize))
        }
        state.withLock { state in
            let reader = opened.get()
            state.reader = reader
            state.position = 0
            if let reader { current.set(reader.format) }
        }
    }

    /// Starts the reader thread, at the frame the pipeline was last given.
    ///
    /// - Throws: `sourceUnavailable` when the source was not prepared.
    public func start() throws(DSPError) {
        let channel = channel, clock = clock, pacing = pacing
        try state.withLock { state throws(DSPError) in
            guard state.run == nil else { return }
            guard let reader = state.reader, let outlet = state.outlet else {
                throw DSPError.sourceUnavailable(reason: "the file source was not prepared; attach a pipeline to it first")
            }
            reader.seek(toFrame: state.position)
            state.reader = nil
            let handover = Guarded<(reader: FileReader?, written: Int)>((reader, 0))
            let thread = SourceThread.start(
                name: "com.zombietron.ztrondsp.file", qualityOfService: pacing == .realTime ? .userInitiated : .utility
            ) { thread in
                let taken = handover.withLock { handover -> FileReader? in
                    defer { handover.reader = nil }
                    return handover.reader
                }
                guard let taken else { return }
                let written = FileSource.read(taken, pacing: pacing, clock: clock, channel: channel, thread: thread) { block in
                    // Waits for room; returns short only when the engine has closed the ring.
                    outlet.writeWaiting(block)
                }
                handover.set((taken, written))
            }
            state.run = Run(thread: thread, handover: handover)
        }
    }

    /// Ends the reader thread and waits for it. The engine has closed the ring before, so a
    /// reader that waits for room returns.
    public func stop() {
        let run = state.withLock { state -> Run? in
            defer { state.run = nil }
            return state.run
        }
        guard let run else { return }
        run.thread.cancel()
        let ended = run.thread.join(timeout: stopTimeout)
        state.withLock { state in
            let handed = run.handover.get()
            guard ended, let reader = handed.reader else {
                // The thread is stuck in a read. It keeps its reader and ends when the read
                // returns; the source is without a file until it is prepared again.
                Log.sources.fault("The reader thread of a file source did not end in time; the file is opened anew when the source is prepared again")
                return
            }
            // What the ring still holds was written but never reached the pipeline: the next
            // start reads it again.
            let unread = state.outlet.map { Int(ztd_ring_available($0.ring)) } ?? 0
            state.position = max(state.position + handed.written - unread, 0)
            state.reader = reader
        }
    }

    /// Takes the ring the reader thread writes from its next start on. Called by the engine
    /// on its control context, after `prepare()`.
    public func connect(to ring: RingWriter) {
        state.withLock { $0.outlet = ring }
    }

    /// The reader thread's loop: read a block, wait until it is due, write it; `.ended` after
    /// the last write. Returns the frames written.
    ///
    /// - Parameter write: takes a block and returns how many of its frames it took; fewer
    ///   than all means the reader is being stopped.
    static func read(
        _ reader: FileReader, pacing: Pacing, clock: any PacingClock, channel: SourceEventChannel, thread: SourceThread,
        write: (AudioBlock) -> Int
    ) -> Int {
        var written = 0
        let start = clock.now
        let rate = reader.format.sampleRate
        do throws(DSPError) {
            while !thread.isCancelled {
                guard let block = try reader.next() else {
                    channel.send(.ended)
                    break
                }
                if pacing == .realTime {
                    // A block is released when the clock reads the time of its first frame.
                    let due = start + Double(written) / rate
                    while !thread.isCancelled, clock.now < due { clock.sleep(until: due) }
                    if thread.isCancelled { break }
                }
                let count = write(block)
                written += count
                if count < block.frameCount { break }
            }
        } catch {
            channel.send(.failed(error))
        }
        return written
    }
}
