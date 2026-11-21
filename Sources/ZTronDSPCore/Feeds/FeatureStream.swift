import Foundation

/// A sink that hands frames to app logic as an `AsyncSequence` (§5.2):
///
/// ```swift
/// let onsets = FeatureStream<Novelty>()
/// // … Emit(to: onsets) in a pipeline …
/// for await frame in onsets { react(to: frame.scalar.value) }
/// ```
///
/// The stream is bounded. It keeps the newest `capacity` frames; when the consumer lags, the
/// oldest are dropped and counted (`droppedFrames`), and nothing ever grows. The analysis
/// thread copies each frame into storage that was allocated when the stream was attached,
/// without allocating, locking or waking anyone; the consumer is woken from the engine's
/// control context.
///
/// One task iterates a stream at a time. The sequence does not end when the session stops or
/// is detached, because the stream may be attached again; it ends when the consuming task is
/// cancelled, or when `finish()` is called.
///
/// Threading: `write` belongs to the analysis thread and does not allocate. Everything else is
/// for any other thread: creating and claiming the stream allocate, and each frame the consumer
/// takes is a copy that allocates.
public final class FeatureStream<Domain: SignalDomain>: FeatureSink, AsyncSequence, @unchecked Sendable {
    /// The frames the sequence delivers: owned copies.
    public typealias Element = FeatureFrame

    /// Frames the stream holds for a consumer that lags.
    public let capacity: Int

    /// Everything the writer needs, allocated when the stream is claimed.
    private final class Storage {
        let capacity: Int
        let format: FrameFormat
        let primaryCount: Int
        let secondaryCount: Int
        let primary: UnsafeMutablePointer<Float>
        let secondary: UnsafeMutablePointer<Float>
        let headers: UnsafeMutablePointer<Header>

        struct Header {
            var index = 0
            var time = 0.0
            var count = 0
            var channelCount = 1
            var scalar = ScalarFrame.none
        }

        init(capacity: Int, format: FrameFormat) throws(DSPError) {
            self.capacity = capacity
            self.format = format
            switch format {
            case .samples(let channels, let frames): (primaryCount, secondaryCount) = (Swift.max(channels, 1) * Swift.max(frames, 1), 0)
            case .real(let count): (primaryCount, secondaryCount) = (Swift.max(count, 1), 0)
            case .complex(let count), .envelope(let count): (primaryCount, secondaryCount) = (Swift.max(count, 1), Swift.max(count, 1))
            case .scalar: (primaryCount, secondaryCount) = (0, 0)
            }
            // Frames the machine cannot hold are an allocation that failed, not a trap (§9.3).
            let (cells, overflow) = Swift.max(primaryCount, secondaryCount, 1).multipliedReportingOverflow(by: capacity)
            guard !overflow, cells <= 1 << 28, capacity <= 1 << 24 else {
                throw .resourceAllocationFailed(what: "a stream of \(capacity) frames")
            }
            primary = .allocate(capacity: Swift.max(primaryCount * capacity, 1))
            secondary = .allocate(capacity: Swift.max(secondaryCount * capacity, 1))
            headers = .allocate(capacity: capacity)
            headers.initialize(repeating: Header(), count: capacity)
        }

        deinit {
            primary.deallocate()
            secondary.deallocate()
            headers.deallocate()
        }
    }

    private struct Reader {
        var storage: Storage?
        /// The next frame the consumer takes, counted from the first frame ever written.
        var cursor: UInt64 = 0
        var dropped = 0
        var isFinished = false
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let reader = Locked(Reader())
    /// Frames begun and frames completed: the pair that tells a reader whether the slot it
    /// copied was overwritten meanwhile.
    private let started: OpaquePointer?
    private let completed: OpaquePointer?
    // The writer's own: set on the control context while no writer runs.
    private var writing: Storage?
    private var attention: OpaquePointer?

    /// A stream that holds the newest `capacity` frames for its consumer.
    public init(capacity: Int = 64) {
        self.capacity = Swift.max(capacity, 1)
        started = ztd_atomic_create(0)
        completed = ztd_atomic_create(0)
    }

    deinit {
        if let started { ztd_atomic_destroy(started) }
        if let completed { ztd_atomic_destroy(completed) }
    }

    /// Frames the consumer never saw because it lagged by more than `capacity`.
    public var droppedFrames: Int {
        let written = completed.map { ztd_atomic_load($0) } ?? 0
        return reader.withLock { reader in
            reader.dropped + Int(written > reader.cursor + UInt64(capacity) ? written - reader.cursor - UInt64(capacity) : 0)
        }
    }

    /// Ends the sequence: the consumer's loop finishes once it has taken what is left.
    public func finish() {
        let waiter = reader.withLock { reader -> CheckedContinuation<Bool, Never>? in
            reader.isFinished = true
            defer { reader.waiter = nil }
            return reader.waiter
        }
        waiter?.resume(returning: true)
    }

    // MARK: FeatureSink

    /// Allocates the storage for `capacity` frames of the domain's shape at the stream's
    /// position. Control context.
    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        try claim(axis: axis, environment: environment, domain: Domain.tag,
                  format: Domain.tag.frameKind == .scalar ? .scalar : .real(count: axis?.rowCount ?? 0))
    }

    /// Copies `frame` into the next slot, over the oldest when the consumer lags. Analysis
    /// thread; does not allocate, lock or wake anyone.
    public func write(_ frame: FrameView) {
        guard let storage = writing, let started, let completed else { return }
        let number = ztd_atomic_load(completed)
        ztd_atomic_store(started, number + 1)
        ztd_atomic_barrier()                                  // announced before the slot is touched
        let slot = Int(number % UInt64(storage.capacity))
        var header = Storage.Header()
        header.index = frame.index
        header.time = frame.time
        if let scalar = frame.scalar {
            header.scalar = scalar
            header.count = 1
        } else if let real = frame.real, let source = real.values.baseAddress {
            header.count = Swift.min(real.count, storage.primaryCount)
            memcpy(storage.primary + slot * storage.primaryCount, source, header.count * MemoryLayout<Float>.stride)
        } else if let complex = frame.complex, let real = complex.real.baseAddress, let imaginary = complex.imaginary.baseAddress {
            header.count = Swift.min(complex.count, storage.primaryCount)
            memcpy(storage.primary + slot * storage.primaryCount, real, header.count * MemoryLayout<Float>.stride)
            memcpy(storage.secondary + slot * storage.secondaryCount, imaginary, header.count * MemoryLayout<Float>.stride)
        } else if let envelope = frame.envelope, let minima = envelope.minima.baseAddress, let maxima = envelope.maxima.baseAddress {
            header.count = Swift.min(envelope.count, storage.primaryCount)
            memcpy(storage.primary + slot * storage.primaryCount, minima, header.count * MemoryLayout<Float>.stride)
            memcpy(storage.secondary + slot * storage.secondaryCount, maxima, header.count * MemoryLayout<Float>.stride)
        } else if let block = frame.samples {
            header.channelCount = block.channelCount
            header.count = Swift.min(block.frameCount, block.channelCount > 0 ? storage.primaryCount / block.channelCount : 0)
            var channel = 0
            while channel < block.channelCount {
                memcpy(storage.primary + slot * storage.primaryCount + channel * header.count, block.channel(channel),
                       header.count * MemoryLayout<Float>.stride)
                channel += 1
            }
        }
        storage.headers[slot] = header
        ztd_atomic_store(completed, number + 1)
        // The consumer is woken by the control context, which the thread signals between turns.
        if let attention { ztd_atomic_store(attention, 1) }
    }

    /// Stops taking frames and wakes a waiting consumer. Control context.
    public func release() {
        writing = nil
        wake()
    }

    // MARK: Consumer

    /// Takes the frames of the stream one after another. For one consuming task.
    ///
    /// Use it on the consuming task, on any thread; each frame it returns is a copy and allocates.
    public struct Iterator: AsyncIteratorProtocol {
        let stream: FeatureStream<Domain>

        /// The next frame, waiting for one when there is none; `nil` once the stream is
        /// finished or the task cancelled.
        public mutating func next() async -> FeatureFrame? {
            await stream.next()
        }
    }

    /// The iterator a `for await` loop runs on. Any thread. The stream has one consumer at a
    /// time: a second task that iterates it while the first waits for a frame gets `nil`.
    public func makeAsyncIterator() -> Iterator {
        Iterator(stream: self)
    }

    private func next() async -> FeatureFrame? {
        while !Task.isCancelled {
            switch take() {
            case .frame(let frame): return frame
            case .finished: return nil
            case .empty: break
            }
            let goesOn = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let answer = reader.withLock { reader -> Bool? in
                        // The stream has one consumer at a time: a second task that iterates
                        // it while the first waits is told that there is nothing for it, and
                        // does not spin beside the first.
                        if reader.waiter != nil { return false }
                        let written = completed.map { ztd_atomic_load($0) } ?? 0
                        // Cancelled between the check above and here: there is no waiter for
                        // the cancellation handler to find, so the wait must not begin.
                        if reader.isFinished || written > reader.cursor || Task.isCancelled { return true }
                        reader.waiter = continuation
                        return nil
                    }
                    if let answer { continuation.resume(returning: answer) }
                }
            } onCancel: {
                wake()
            }
            if !goesOn { return nil }
        }
        return nil
    }

    private enum Taken {
        case frame(FeatureFrame)
        case empty
        case finished
    }

    /// Copies the oldest frame the consumer has not seen out of the ring.
    private func take() -> Taken {
        guard let started, let completed else { return .finished }
        return reader.withLock { reader -> Taken in
            guard let storage = reader.storage else { return reader.isFinished ? .finished : .empty }
            let capacity = UInt64(storage.capacity)
            while true {
                let written = ztd_atomic_load(completed)
                guard reader.cursor < written else { return reader.isFinished ? .finished : .empty }
                if written - reader.cursor > capacity {
                    reader.dropped += Int(written - reader.cursor - capacity)
                    reader.cursor = written - capacity
                }
                let slot = Int(reader.cursor % capacity)
                let header = storage.headers[slot]
                let frame = FeatureStream.copy(storage, slot, header, kind: Domain.tag.frameKind)
                // The copy is whole only if the writer has not come round to this slot meanwhile.
                ztd_atomic_barrier()
                if ztd_atomic_load(started) > reader.cursor + capacity {
                    reader.dropped += 1
                    reader.cursor += 1
                    continue
                }
                reader.cursor += 1
                return .frame(frame)
            }
        }
    }

    private static func copy(_ storage: Storage, _ slot: Int, _ header: Storage.Header, kind: DomainTag.FrameKind) -> FeatureFrame {
        let primary = UnsafeBufferPointer(start: storage.primary + slot * storage.primaryCount,
                                          count: Swift.min(header.count * Swift.max(header.channelCount, 1), storage.primaryCount))
        let secondary = UnsafeBufferPointer(start: storage.secondary + slot * storage.secondaryCount, count: Swift.min(header.count, storage.secondaryCount))
        switch storage.format {
        case .scalar:
            return FeatureFrame(kind: kind, index: header.index, time: header.time, scalar: header.scalar)
        case .real:
            return FeatureFrame(kind: kind, index: header.index, time: header.time, values: Array(primary))
        case .complex, .envelope:
            return FeatureFrame(kind: kind, index: header.index, time: header.time, values: Array(primary), secondary: Array(secondary))
        case .samples:
            return FeatureFrame(kind: kind, index: header.index, time: header.time, values: Array(primary), channelCount: header.channelCount)
        }
    }

    /// Lets a waiting consumer look again.
    private func wake() {
        let waiter = reader.withLock { reader -> CheckedContinuation<Bool, Never>? in
            defer { reader.waiter = nil }
            return reader.waiter
        }
        waiter?.resume(returning: true)
    }
}

extension FeatureStream: NamedSink {
    var sinkName: String { "FeatureStream<\(Domain.self)>" }

    /// Allocates the ring for frames of `format`. What an earlier attachment left is kept for
    /// the consumer when the frames are of the same shape.
    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError) {
        guard started != nil, completed != nil else { throw .resourceAllocationFailed(what: "the counters of a feature stream") }
        if let existing = reader.withLock({ $0.storage }), existing.format == format {
            writing = existing
            return
        }
        let storage = try Storage(capacity: capacity, format: format)
        reader.withLock { reader in
            // Frames of the old shape are gone with their storage.
            reader.storage = storage
            reader.cursor = completed.map { ztd_atomic_load($0) } ?? 0
        }
        writing = storage
    }

    func connect(attention: OpaquePointer?) {
        self.attention = attention
    }

    func service() {
        let waiter = reader.withLock { reader -> CheckedContinuation<Bool, Never>? in
            let written = completed.map { ztd_atomic_load($0) } ?? 0
            guard written > reader.cursor, let waiter = reader.waiter else { return nil }
            reader.waiter = nil
            return waiter
        }
        waiter?.resume(returning: true)
    }
}
