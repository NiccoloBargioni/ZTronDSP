import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Waits, on the test's task, until `condition` holds; false when it does not within `timeout`.
func eventually(timeout: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

extension PipelineSession {
    /// Waits until the session is in `state`.
    func reaches(_ state: SessionState, timeout: Double = 5) async -> Bool {
        await eventually(timeout: timeout) { self.state == state }
    }
}

/// Listens to the main-line output of a session: what a processed source would be handed.
final class OutputProbe: MainLineConsumer, @unchecked Sendable {
    // Threading: written by the thread that runs the session, read by the test once it has stopped.
    private(set) var samples: [Float] = []
    private(set) var blocks = 0
    private(set) var boundaries = 0

    func boundary() { boundaries += 1 }

    func consume(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        samples.append(contentsOf: block.samples(ofChannel: 0))
        blocks += 1
    }
}

/// Collects the events of a session as they arrive.
final class EventLog: @unchecked Sendable {
    private let events = Locked<[SessionEvent]>([])
    private var task: Task<Void, Never>?

    init(_ session: PipelineSession) {
        let stream = session.events
        let events = self.events
        task = Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [SessionEvent] { events.get() }

    func contains(_ event: SessionEvent) -> Bool { events.get().contains(event) }

    var states: [SessionState] {
        events.get().compactMap { if case .stateChanged(let state) = $0 { state } else { nil } }
    }
}

/// A push source for tests: the test writes blocks into the ring by hand and sends events.
final class ManualPushSource: PushSampleSource, @unchecked Sendable {
    private let stored: Locked<SignalFormat>
    private let channel = SourceEventChannel()
    private let writer = Locked<RingWriter?>(nil)
    private let counts = Locked<(prepares: Int, starts: Int, stops: Int, connects: Int)>((0, 0, 0, 0))
    let startError: DSPError?

    init(format: SignalFormat, startError: DSPError? = nil) {
        stored = Locked(format)
        self.startError = startError
    }

    var format: SignalFormat { stored.get() }
    var events: AsyncStream<SourceEvent> { channel.stream }
    var prepares: Int { counts.get().prepares }
    var starts: Int { counts.get().starts }
    var stops: Int { counts.get().stops }
    var connects: Int { counts.get().connects }

    func prepare() async throws(DSPError) { counts.withLock { $0.prepares += 1 } }

    func start() throws(DSPError) {
        if let startError { throw startError }
        counts.withLock { $0.starts += 1 }
    }

    func stop() { counts.withLock { $0.stops += 1 } }

    func connect(to ring: RingWriter) {
        writer.set(ring)
        counts.withLock { $0.connects += 1 }
    }

    /// Writes one channel of samples to every channel of the ring; returns the frames written.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        guard let ring = writer.get() else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
            return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
        }
    }

    /// Writes a block without allocating: what an audited loop feeds the ring with.
    @discardableResult
    func write(_ block: AudioBlock) -> Int {
        writer.withLock { $0?.write(block) ?? 0 }
    }

    func send(_ event: SourceEvent) { channel.send(event) }

    /// Changes the format the source reports and says so.
    func changeFormat(to format: SignalFormat) {
        stored.set(format)
        channel.send(.formatChanged(format))
    }
}

/// A clock a test holds: `sleep` moves it forward and is recorded.
final class TestClock: AnalysisClock, @unchecked Sendable {
    private let state = Locked<(now: Double, sleeps: [Double])>((0, []))

    var now: Double { state.get().now }
    var sleeps: [Double] { state.get().sleeps }

    func sleep(until deadline: Double) {
        state.withLock { state in
            state.sleeps.append(deadline - state.now)
            state.now = max(state.now, deadline)
        }
    }

    func advance(by seconds: Double) {
        state.withLock { $0.now += seconds }
    }
}

/// An engine a test drives turn by turn, with a source the test feeds by hand.
struct Rig {
    let engine: DSPEngine
    let source: ManualPushSource
    let blockSize: Int

    init(blockSize: Int = 64, sampleRate: Double = 48_000, channelCount: Int = 1) {
        engine = DSPEngine(blockSize: blockSize, drivenByHand: true)
        source = ManualPushSource(format: SignalFormat(sampleRate: sampleRate, channelCount: channelCount))
        self.blockSize = blockSize
    }

    /// Writes `samples` and runs the engine until they are processed.
    func feed(_ samples: [Float]) {
        var position = 0
        while position < samples.count {
            let end = min(position + blockSize * 32, samples.count)
            source.write(Array(samples[position ..< end]))
            engine.core.runTurn()
            position = end
        }
        engine.core.flush()
    }

    /// Lets everything the test asked of the main thread and of the control context happen.
    func drain() async {
        await MainActor.run {}
        engine.core.flush()
        await MainActor.run {}
    }
}
