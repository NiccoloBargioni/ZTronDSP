import Foundation

/// A test double (§4.4): a source that follows a script of batches of any size, format
/// changes, events and failures, so that the engine's handling of each can be tested without
/// hardware.
///
/// Each call to `render` delivers at most one batch, or the part of it that fits, so the
/// engine sees the irregular sizes the script states. A format change reports
/// `.formatChanged` and ends the stream of the old format; once the engine has re-planned,
/// the script goes on in the new one. A failure reports `.failed` and then delivers silence
/// until the engine stops asking.
///
/// Threading: as a pull source. `prepare`, `start` and `stop` run on the control context;
/// `render` runs on the analysis thread, or on the offline thread with the default
/// `.asFastAsPossible` pacing; `format` may be read on any thread. With two deliberate
/// exceptions to RT-2: `render` sends events and failures, which allocates, and at a format
/// change it takes the lock that guards `format`. That is what makes them arrive at an exact
/// place in the stream, and it is why this type is a test double and not a pattern for a
/// source.
public final class ScriptedSource: PullSampleSource, @unchecked Sendable {
    /// One step of a script.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum Step: Sendable {
        /// A batch of samples, one array per channel, all of one length.
        case samples([[Float]])
        /// The source delivers another format from here on.
        case formatChange(SignalFormat)
        /// An event, sent as it is: `.interrupted`, `.resumed`, `.overrun`, …
        case event(SourceEvent)
        /// The source fails.
        case failure(DSPError)
    }

    /// How the engine paces the script: `.asFastAsPossible` unless told otherwise.
    public let pacing: Pacing
    /// The format the script is in now: the initial one, then that of the last format change
    /// `render` reached. It takes a lock; any thread.
    public var format: SignalFormat { current.get() }
    /// The events and the format changes of the script, as `render` reaches them.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    private let initialFormat: SignalFormat
    private let steps: [Step]
    /// The frames of each step that delivers samples, 0 for the others: known before the
    /// stream starts, so that rendering computes nothing it has to allocate for.
    private let lengths: [Int]
    private let channel = SourceEventChannel()
    private let current: Locked<SignalFormat>

    // The thread that renders only.
    private var step = 0
    private var offset = 0
    private var failed = false
    private let renders: OpaquePointer?

    /// A source that follows `steps` and then ends. Any thread but the analysis thread; it
    /// allocates.
    public init(format: SignalFormat, pacing: Pacing = .asFastAsPossible, _ steps: [Step]) {
        self.initialFormat = format
        self.pacing = pacing
        self.steps = steps
        self.lengths = steps.map { step in
            if case .samples(let batch) = step { return batch.map(\.count).min() ?? 0 }
            return 0
        }
        self.current = Locked(format)
        self.renders = ztd_atomic_create(0)
    }

    /// A source that delivers `samples` on one channel in batches of the given sizes, the last size
    /// repeating until the samples run out. Any thread but the analysis thread; it allocates.
    public convenience init(_ samples: [Float], sampleRate: Double, batchSizes: [Int], pacing: Pacing = .asFastAsPossible) {
        var steps: [Step] = []
        var position = 0
        var index = 0
        while position < samples.count {
            let size = max(batchSizes.isEmpty ? samples.count : batchSizes[min(index, batchSizes.count - 1)], 1)
            let end = min(position + size, samples.count)
            steps.append(.samples([Array(samples[position ..< end])]))
            position = end
            index += 1
        }
        self.init(format: SignalFormat(sampleRate: sampleRate), pacing: pacing, steps)
    }

    deinit {
        if let renders { ztd_atomic_destroy(renders) }
    }

    /// How often `render` has been called: what a test of pacing counts.
    public var renderCount: Int {
        renders.map { Int(truncatingIfNeeded: ztd_atomic_load($0)) } ?? 0
    }

    /// Checks the initial format and rewinds the script to its first step. Control context.
    public func prepare() async throws(DSPError) {
        guard initialFormat.isValid else {
            throw .invalidParameter(stage: .none, parameter: "format", reason: "\(initialFormat) is not a signal format")
        }
        current.set(initialFormat)
        step = 0
        offset = 0
        failed = false
    }

    /// Does nothing: the engine's requests drive the script.
    public func start() throws(DSPError) {}

    /// Does nothing.
    public func stop() {}

    /// Delivers the next batch, or the part of it that fits; sends the events it passes, ends the
    /// stream at a format change, and delivers silence after a failure. See the threading note
    /// of the type for what it allocates and locks.
    public func render(into block: inout AudioBlock) -> Int {
        if let renders { _ = ztd_atomic_add(renders, 1) }
        if failed {
            // The engine has been told; until it stops asking it gets silence.
            block.setFrameCount(block.capacity)
            block.clear()
            return block.capacity
        }
        while step < steps.count {
            switch steps[step] {
            case .samples(let batch):
                let length = lengths[step]
                let frames = min(block.capacity, length - offset)
                guard frames > 0 else {
                    step += 1
                    offset = 0
                    continue
                }
                var index = 0
                while index < block.channelCount {
                    let target = block.channel(index)
                    if index < batch.count {
                        batch[index].withUnsafeBufferPointer { source in
                            guard let base = source.baseAddress else { return }
                            memcpy(target, base + offset, frames * MemoryLayout<Float>.stride)
                        }
                    } else {
                        memset(target, 0, frames * MemoryLayout<Float>.stride)
                    }
                    index += 1
                }
                offset += frames
                if offset >= length {
                    step += 1
                    offset = 0
                }
                block.setFrameCount(frames)
                return frames

            case .formatChange(let format):
                step += 1
                current.set(format)
                channel.send(.formatChanged(format))
                // The stream of the old format ends here; the engine re-plans and asks again.
                block.setFrameCount(0)
                return 0

            case .event(let event):
                step += 1
                channel.send(event)

            case .failure(let error):
                step += 1
                failed = true
                channel.send(.failed(error))
                block.setFrameCount(block.capacity)
                block.clear()
                return block.capacity
            }
        }
        block.setFrameCount(0)
        return 0
    }
}
