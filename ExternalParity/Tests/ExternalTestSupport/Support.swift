import Darwin
import Foundation
import SwiftUI
import Testing
import ZTronDSP
import ZTronDSPTesting

// What the tests of the external parity suite and of the extension guide share. Everything here is written on the public
// API of ZTronDSP, as an app's own code is: the suite imports no internal symbol of it.

public let mono48 = SignalFormat(sampleRate: 48_000)

/// Waits, on the test's task, until `condition` holds; false when it does not within `timeout`.
public func eventually(timeout: Double = 60, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

extension PipelineSession {
    /// Waits until the session is in `state`.
    public func reaches(_ state: SessionState, timeout: Double = 60) async -> Bool {
        await eventually(timeout: timeout) { self.state == state }
    }
}

/// A value two threads share, behind a lock: a test's instrument.
public final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ new: Value) {
        lock.lock()
        value = new
        lock.unlock()
    }

    public func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// A sink that keeps what it is given: a `FeatureSink` written outside the package. One writer
/// at a time (ATT-5).
///
/// Threading: `write` runs on the thread that runs the plan and the test reads from its own
/// task, so the store sits behind a lock and grows as frames arrive. That makes it a test's
/// instrument, not a pattern for a sink: a sink of an app is bound by RT-2.
public final class CollectingSink<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    public typealias Domain = D

    struct Store {
        var channels: [[Float]] = []
        var frames: [[Float]] = []
        var scalars: [ScalarFrame] = []
        var times: [Double] = []
        var indices: [Int] = []
        var blockLengths: [Int] = []
        var axis: FeedAxis?
        var environment: DSPEnvironment?
        var claims = 0
        var releases = 0
    }

    private let store = Guarded(Store())

    public init() {}

    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        store.withLock { store in
            store.claims += 1
            store.axis = axis
            store.environment = environment
        }
    }

    public func write(_ frame: FrameView) {
        store.withLock { store in
            store.times.append(frame.time)
            store.indices.append(frame.index)
            if let real = frame.real { store.frames.append(Array(real.values)) }
            if let scalar = frame.scalar { store.scalars.append(scalar) }
            if let block = frame.samples {
                store.blockLengths.append(block.frameCount)
                while store.channels.count < block.channelCount { store.channels.append([]) }
                var channel = 0
                while channel < block.channelCount {
                    store.channels[channel].append(contentsOf: block.samples(ofChannel: channel))
                    channel += 1
                }
            }
        }
    }

    public func release() {
        store.withLock { $0.releases += 1 }
    }

    /// The samples of the first channel.
    public var samples: [Float] { store.withLock { $0.channels.first ?? [] } }
    public var channels: [[Float]] { store.withLock { $0.channels } }
    public var sampleCount: Int { store.withLock { $0.channels.first?.count ?? 0 } }
    public var frames: [[Float]] { store.withLock { $0.frames } }
    public var frameCount: Int { store.withLock { $0.times.count } }
    public var scalars: [ScalarFrame] { store.withLock { $0.scalars } }
    public var times: [Double] { store.withLock { $0.times } }
    public var indices: [Int] { store.withLock { $0.indices } }
    public var axis: FeedAxis? { store.withLock { $0.axis } }
    public var environment: DSPEnvironment? { store.withLock { $0.environment } }
    public var claims: Int { store.withLock { $0.claims } }
    public var releases: Int { store.withLock { $0.releases } }

    /// The samples of the first channel laid out by the time each block carries: element `n` is
    /// the sample the sink was given for the `n`-th frame of the stream, or `nil` where it was
    /// given none. Frame times are content times, so a stretch the sink did not hear is a gap.
    public func timeline(sampleRate: Double, count: Int) -> [Float?] {
        store.withLock { store in
            var result = [Float?](repeating: nil, count: count)
            let samples = store.channels.first ?? []
            var offset = 0
            for (time, length) in zip(store.times, store.blockLengths) {
                let start = Int((time * sampleRate).rounded())
                for index in 0 ..< length where start + index >= 0 && start + index < count {
                    result[start + index] = samples[offset + index]
                }
                offset += length
            }
            return result
        }
    }
}

/// A sink that counts the frames of the blocks it is given and keeps nothing: how a test knows
/// how far an engine has come. Its count is one atomic word, written by the thread that runs
/// the plan.
public final class FrameCounter: FeatureSink, @unchecked Sendable {
    public typealias Domain = Samples
    private let cell = ztd_atomic_create(0)

    public init() {}

    deinit {
        if let cell { ztd_atomic_destroy(cell) }
    }

    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    public func write(_ frame: FrameView) {
        if let cell { _ = ztd_atomic_add(cell, UInt64(frame.count)) }
    }

    public func release() {}

    public var frames: Int { cell.map { Int(ztd_atomic_load($0)) } ?? 0 }
}

/// State behind a SwiftUI binding: what `@State` is to a view.
public final class StateBox<Value: Sendable>: @unchecked Sendable {
    private let stored: Guarded<Value>
    private let written = Guarded(0)

    public init(_ value: Value) {
        stored = Guarded(value)
    }

    public var value: Value {
        get { stored.get() }
        set { stored.set(newValue) }
    }

    /// How often the binding was written through.
    public var writes: Int { written.get() }

    public var binding: Binding<Value> {
        Binding(get: { self.stored.get() }, set: { self.stored.set($0); self.written.withLock { $0 += 1 } })
    }
}

/// A push source the test feeds by hand: a `PushSampleSource` written outside the package. The
/// engine's analysis thread takes what the test writes, block by block, so a test decides at
/// which block boundary a switch moves or a pipeline changes.
public final class HandFedSource: PushSampleSource, @unchecked Sendable {
    public let format: SignalFormat
    private let channel = SourceEventChannel()
    private let writer = Guarded<RingWriter?>(nil)

    public init(format: SignalFormat = mono48) {
        self.format = format
    }

    public var events: AsyncStream<SourceEvent> { channel.stream }

    public func prepare() async throws(DSPError) {}
    public func start() throws(DSPError) {}
    public func stop() {}

    public func connect(to ring: RingWriter) {
        writer.set(ring)
    }

    /// Frames the ring takes without dropping any.
    public var availableSpace: Int { writer.get()?.availableSpace ?? 0 }

    /// Writes one channel of samples to every channel of the ring; returns the frames written.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        guard let ring = writer.get() else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
            return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
        }
    }

    /// The stream is over: the engine delivers what the ring still holds and finishes.
    public func end() {
        channel.send(.ended)
    }
}

/// An engine, a hand-fed source and a session on a pipeline of samples, with a counter in front
/// of the pipeline and a sink behind it.
///
/// The counter tells the test how far the engine has come: when it has seen every frame the
/// test wrote, the ring is empty, and whatever the test does next (a switch, an update) lands
/// at the first block it writes after that. The sink behind the pipeline hears what leaves
/// the main line; an update that changes the main line in front of it leaves it without
/// frames until the new plan has taken over (CR-015, item 4), so after such an update a test
/// waits for the counter, not for the sink.
public struct HandFedRun {
    public let engine: DSPEngine
    public let source: HandFedSource
    public let session: PipelineSession
    /// The frames that entered the pipeline.
    public let entered: FrameCounter
    /// What left the main line.
    public let output: CollectingSink<Samples>

    /// Attaches `pipeline`, between the counter and the sink, and starts the session.
    public init(_ pipeline: Pipeline<Samples, Samples>, blockSize: Int = 64, format: SignalFormat = mono48) async throws {
        engine = DSPEngine(blockSize: blockSize)
        source = HandFedSource(format: format)
        entered = FrameCounter()
        output = CollectingSink<Samples>()
        session = try await engine.attach(HandFedRun.framed(pipeline, entered, output), to: source)
        try session.start()
    }

    /// `pipeline` as the run attaches it: what a test hands to `session.update(_:)`.
    public func framed(_ pipeline: Pipeline<Samples, Samples>) -> Pipeline<Samples, Samples> {
        HandFedRun.framed(pipeline, entered, output)
    }

    private static func framed(_ pipeline: Pipeline<Samples, Samples>, _ entered: FrameCounter, _ output: CollectingSink<Samples>) -> Pipeline<Samples, Samples> {
        Pipeline().emit(to: entered).appending(pipeline).emit(to: output)
    }

    /// Writes `samples`, a whole number of blocks, and waits until the engine has taken them
    /// all and, unless `awaitingOutput` is false, until the main line has delivered as many
    /// frames as went in.
    @discardableResult
    public func feed(_ samples: [Float], awaitingOutput: Bool = true) async -> Bool {
        var position = 0
        let entered = self.entered, output = self.output
        while position < samples.count {
            let end = min(position + 4_096, samples.count)
            let goal = entered.frames + (end - position), delivered = output.sampleCount + (end - position)
            source.write(Array(samples[position ..< end]))
            guard await eventually(timeout: 60, { entered.frames >= goal && (!awaitingOutput || output.sampleCount >= delivered) }) else { return false }
            position = end
        }
        return true
    }

    /// Moves a bound switch as a control on the main thread would, and has the session read it
    /// at once (BIND-3).
    public func set(_ box: StateBox<Bool>, to value: Bool) async {
        let session = self.session
        await MainActor.run {
            box.value = value
            session.syncBindings()
        }
    }

    /// Ends the stream, waits for the session to finish, and detaches it.
    @discardableResult
    public func finish() async -> Bool {
        source.end()
        let finished = await session.reaches(.finished)
        session.detach()
        return finished
    }
}

/// Runs a pipeline of samples through an engine on `source` and returns what its main line
/// delivered, one array per channel.
public func throughEngine(
    _ pipeline: Pipeline<Samples, Samples>, on source: any SampleSource, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
) async throws -> [[Float]] {
    let engine = DSPEngine(blockSize: blockSize, crossovers: crossovers)
    let sink = CollectingSink<Samples>()
    let session = try await engine.attach(pipeline.emit(to: sink), to: source)
    try session.start()
    let finished = await session.reaches(.finished)
    session.detach()
    try #require(finished, "the session did not finish")
    return sink.channels
}

/// Runs a pipeline that ends in real frames through an engine on `source` and returns the
/// frames, with the axis and the environment its sink was claimed with.
public func framesThroughEngine<D: RealVectorDomain>(
    _ pipeline: Pipeline<Samples, D>, on source: any SampleSource, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
) async throws -> CollectingSink<D> {
    let engine = DSPEngine(blockSize: blockSize, crossovers: crossovers)
    let sink = CollectingSink<D>()
    let session = try await engine.attach(pipeline.emit(to: sink), to: source)
    try session.start()
    let finished = await session.reaches(.finished)
    session.detach()
    try #require(finished, "the session did not finish")
    return sink
}

/// The events of a session as they arrive.
public final class EventLog: @unchecked Sendable {
    private let events = Guarded<[SessionEvent]>([])
    private let task: Task<Void, Never>

    public init(_ session: PipelineSession) {
        let stream = session.events
        let events = self.events
        task = Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    deinit {
        task.cancel()
    }

    public var all: [SessionEvent] { events.get() }

    public func contains(_ event: SessionEvent) -> Bool { events.get().contains(event) }
}

/// The largest distance between two signals, relative to the largest magnitude of the second.
public func deviation(_ actual: [Float], from expected: [Float]) -> Double {
    guard actual.count == expected.count else { return .infinity }
    var peak = 0.0, worst = 0.0
    var index = 0
    while index < expected.count {
        peak = max(peak, Double(abs(expected[index])))
        worst = max(worst, abs(Double(actual[index]) - Double(expected[index])))
        index += 1
    }
    return peak > 0 ? worst / peak : worst
}

// MARK: The real-time audit on a thread the test does not own (RT-7, layer 3)

/// Counts the blocks a callback has seen. The engine's thread only.
public final class BlockCounter: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<Int>

    public init() {
        cell = .allocate(capacity: 1)
        cell.initialize(to: 0)
    }

    deinit {
        cell.deallocate()
    }

    /// The number of the block being processed, from 0; counts it.
    public func next() -> Int {
        let value = cell.pointee
        cell.pointee = value &+ 1
        return value
    }
}

// snippet:begin audit-on-the-engine-thread
/// Runs `pipeline` on an engine and audits what the thread that runs its plan asks of the heap
/// while it processes `blocks` blocks, after `warmUp` blocks outside the audit: the source,
/// the plan with its kernels and nodes, and the sinks, as they run in an app. That thread is
/// the engine's analysis thread for a source paced in real time (`pacing: .realTime`), and a
/// thread of the session's own for one that is read as fast as it is processed.
///
/// Nothing public runs a plan block by block on the caller's thread, so `expectNoAllocations`
/// cannot hold a pipeline; `ThreadAllocationAudit` is opened and closed from a callback on the
/// engine's thread instead.
public func expectNoAllocationsOnTheEngineThread<Output: SignalDomain>(
    _ pipeline: Pipeline<Samples, Output>, on source: (any SampleSource)? = nil, format: SignalFormat = mono48, blockSize: Int = 512,
    blocks: Int = 1_000, warmUp: Int = 16, pacing: Pacing = .asFastAsPossible, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let audit = ThreadAllocationAudit()
    let counter = BlockCounter()
    let gate = FeatureCallback<Samples> { _ in
        let block = counter.next()
        if block == warmUp { audit.begin() } else if block == warmUp + blocks { audit.end() }
    }
    // Noise of the format, unless the test brings a source of its own: it then delivers at
    // least `warmUp + blocks + 1` blocks.
    let audited: any SampleSource
    if let source {
        audited = source
    } else {
        var channels: [[Float]] = []
        for channel in 0 ..< format.channelCount {
            channels.append(TestSignal.whiteNoise(count: (warmUp + blocks + 4) * blockSize, seed: UInt64(41 + channel), amplitude: 0.5))
        }
        audited = BufferSource(channels: channels, sampleRate: format.sampleRate, pacing: pacing)
    }
    let engine = DSPEngine(blockSize: blockSize)
    let session = try await engine.attach(Pipeline().emit(to: gate).appending(pipeline), to: audited)
    try session.start()
    let closed = await eventually { audit.isClosed || audit.failedToOpen }
    let finished = await session.reaches(.finished)
    session.detach()
    #expect(closed && finished, "\(comment): the audited stretch did not run to its end", sourceLocation: sourceLocation)
    #expect(!audit.failedToOpen, "\(comment): the allocation audit could not be opened: an audit that cannot run is a failure", sourceLocation: sourceLocation)
    let counts = try #require(audit.counts, "\(comment): the audit was not closed", sourceLocation: sourceLocation)
    #expect(counts.allocations == 0 && counts.deallocations == 0, "\(comment): \(blocks) blocks on the engine's thread: \(counts)", sourceLocation: sourceLocation)
}
// snippet:end audit-on-the-engine-thread

/// A sink that only counts, for the audit: it keeps nothing and allocates nothing.
///
/// Threading: `write` belongs to the thread that runs the plan; the count is one atomic word.
public final class CollectingCount<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    public typealias Domain = D
    private let cell = ztd_atomic_create(0)

    public init() {}

    deinit {
        if let cell { ztd_atomic_destroy(cell) }
    }

    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    public func write(_ frame: FrameView) {
        if let cell { _ = ztd_atomic_add(cell, 1) }
    }

    public func release() {}

    public var frames: Int { cell.map { Int(ztd_atomic_load($0)) } ?? 0 }
}
