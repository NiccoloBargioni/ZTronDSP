import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// Test doubles for the coverage suites (COV-3). Each is written against the public API, as a
// client of the core would write it, and fails or waits only when a test tells it to.

/// Listens to the main-line output of a session and keeps every channel of it.
final class CoverageChannelProbe: MainLineConsumer, @unchecked Sendable {
    // Threading: written by the thread that runs the session, read by the test once that thread
    // is at rest (the tests that use it drive the engine by hand).
    private(set) var channels: [[Float]] = []

    func boundary() {}

    func consume(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        while channels.count < block.channelCount { channels.append([]) }
        for channel in 0 ..< block.channelCount { channels[channel].append(contentsOf: block.samples(ofChannel: channel)) }
    }
}

/// A sink of samples that refuses the claims it is told to refuse, counted from 1.
final class CoverageFussySink: FeatureSink, @unchecked Sendable {
    typealias Domain = Samples
    // Threading: `claim` and `release` run on the engine's control context, `write` on the thread
    // that runs the plan; the test reads and sets the rest while neither is at work (the engine
    // is driven by hand, and every call into it has returned).
    private(set) var samples: [Float] = []
    private(set) var claims = 0
    private(set) var releases = 0
    private(set) var rates: [Double] = []
    var refused: Set<Int> = []

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        claims += 1
        if refused.contains(claims) { throw .resourceAllocationFailed(what: "the storage of a fussy sink") }
        rates.append(environment.sampleRate)
    }

    func write(_ frame: FrameView) {
        if let block = frame.samples { samples.append(contentsOf: block.samples(ofChannel: 0)) }
    }

    func release() { releases += 1 }
}

/// A sink of samples that notes the name of the thread that writes it, and how many frames.
final class CoverageThreadSink: FeatureSink, @unchecked Sendable {
    typealias Domain = Samples
    // Threading: everything is behind the lock; the writer is whatever thread the engine runs
    // the session on, which is what the sink is there to tell.
    private let state = Locked<(threads: [String], frames: Int)>(([], 0))

    /// The names of the threads that wrote, in order, each named once per run of writes.
    var threads: [String] { state.get().threads }
    var frameCount: Int { state.get().frames }

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    func write(_ frame: FrameView) {
        let name = Thread.current.name ?? ""
        state.withLock { state in
            if state.threads.last != name { state.threads.append(name) }
            state.frames += frame.count
        }
    }

    func release() {}
}

/// A pull source of a fixed number of ones per preparation, whose pacing the test sets between
/// two runs: what a source looks like that is real-time at one moment and not at the next.
final class CoveragePacedSource: PullSampleSource, @unchecked Sendable {
    // Threading: `render` runs on the thread the engine gives the source and touches `remaining`
    // only; `prepare` refills it on another thread while nothing renders. The pacing and the
    // counter are behind the lock.
    private let channel = SourceEventChannel()
    private let settings: Locked<(pacing: Pacing, prepares: Int)>
    private let framesPerRun: Int
    private var remaining = 0

    init(pacing: Pacing, framesPerRun: Int) {
        settings = Locked((pacing, 0))
        self.framesPerRun = framesPerRun
    }

    var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
    var events: AsyncStream<SourceEvent> { channel.stream }
    var pacing: Pacing { settings.get().pacing }
    var prepares: Int { settings.get().prepares }

    func setPacing(_ pacing: Pacing) { settings.withLock { $0.pacing = pacing } }

    func prepare() async throws(DSPError) {
        settings.withLock { $0.prepares += 1 }
        remaining = framesPerRun
    }

    func start() throws(DSPError) {}
    func stop() {}

    func render(into block: inout AudioBlock) -> Int {
        let frames = min(block.capacity, remaining)
        guard frames > 0 else { return 0 }
        let samples = block.channel(0)
        var frame = 0
        while frame < frames {
            samples[frame] = 1
            frame += 1
        }
        remaining -= frames
        block.setFrameCount(frames)
        return frames
    }
}

/// A push source whose preparation takes as long as the test says: while the gate is closed,
/// `prepare()` waits.
final class CoverageGatedSource: PushSampleSource, @unchecked Sendable {
    // Threading: everything is behind the lock.
    private struct State {
        var isOpen = true
        var waiting: [CheckedContinuation<Void, Never>] = []
        var prepares = 0
        var starts = 0
        var writer: RingWriter?
    }

    private let state = Locked(State())
    private let channel = SourceEventChannel()

    var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
    var events: AsyncStream<SourceEvent> { channel.stream }
    var prepares: Int { state.get().prepares }
    var starts: Int { state.get().starts }

    func prepare() async throws(DSPError) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goesOn = state.withLock { state -> Bool in
                state.prepares += 1
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if goesOn { continuation.resume() }
        }
    }

    func start() throws(DSPError) { state.withLock { $0.starts += 1 } }
    func stop() {}
    func connect(to ring: RingWriter) { state.withLock { $0.writer = ring } }

    func closeGate() { state.withLock { $0.isOpen = false } }

    func openGate() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func send(_ event: SourceEvent) { channel.send(event) }

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        guard let ring = state.get().writer else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
            return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
        }
    }
}

/// Collects the events of a source as they arrive.
final class CoverageSourceEventLog: @unchecked Sendable {
    // Threading: the events are behind the lock; the task is set once, in `init`.
    private let events = Locked<[SourceEvent]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SourceEvent>) {
        let events = self.events
        task = Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [SourceEvent] { events.get() }
    func contains(_ event: SourceEvent) -> Bool { events.get().contains(event) }
}

/// Collects the events of a session's control side as they arrive: for a session the app does
/// not hold, such as the one in front of a processed source.
final class CoverageSessionEventLog: @unchecked Sendable {
    // Threading: the events are behind the lock; the task is set once, in `init`.
    private let events = Locked<[SessionEvent]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SessionEvent>) {
        let events = self.events
        task = Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [SessionEvent] { events.get() }
    func contains(_ event: SessionEvent) -> Bool { events.get().contains(event) }
}

/// A running sum on the caller's own C kernel, `y[n] = y[n − 1] + x[n]`, one channel: a kernel
/// whose state shows whether an update kept it (SWAP-1). `key` tells one from another.
struct CoverageAccumulate: SequenceStage {
    let key: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "CoverageAccumulate", key: key) { _, _, _ in
            let sum = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            sum.initialize(to: 0)
            return ztd_kernel_t(
                process: { state, input, output, _, frames in
                    let sum = state!.assumingMemoryBound(to: Float.self)
                    let source = input![0]!, target = output![0]!
                    var total = sum.pointee
                    var frame = 0
                    while frame < Int(frames) {
                        total += source[frame]
                        target[frame] = total
                        frame += 1
                    }
                    sum.pointee = total
                    return frames
                },
                command: nil,
                reset: { state in state!.assumingMemoryBound(to: Float.self).pointee = 0 },
                destroy: { state in state!.assumingMemoryBound(to: Float.self).deallocate() },
                state: UnsafeMutableRawPointer(sum), latency_frames: 0, settling_frames: 0)
        }))
    }
}

/// A copy on the caller's own C kernel that declares a delay of 2³¹ frames: a stage whose
/// unprocessed path, were it switched, no machine could hold.
struct CoverageEndlessDelay: SequenceStage {
    var activation: StageActivation = .active

    init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "CoverageEndlessDelay", key: 0, latencyFrames: 1 << 31) { _, _, _ in
            var kernel = ztd_kernel_identity()
            kernel.latency_frames = 1 << 31
            return kernel
        }))
    }
}

/// The seam of `ztd_internal.h` for a refused allocation: the C layer's constructors that ask
/// `ztd_may_allocate()` take "no" for the system's answer once, for request number `index` of
/// the calling thread. The two functions are in no header; they are looked up by name, as the
/// C target's own tests do.
enum CoverageAllocationSeam {
    private static let functions: (fail: @convention(c) (Int32) -> Void, isPending: @convention(c) () -> Bool)? = {
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let fail = dlsym(anyImage, "ztd_fail_allocation"), let pending = dlsym(anyImage, "ztd_allocation_failure_is_pending") else { return nil }
        return (unsafeBitCast(fail, to: (@convention(c) (Int32) -> Void).self), unsafeBitCast(pending, to: (@convention(c) () -> Bool).self))
    }()

    /// Runs `body` with request number `index` of this thread refused, and returns whether the
    /// request was made at all.
    static func refusing(_ index: Int, _ body: () -> Void) throws -> Bool {
        let seam = try #require(functions, "the seam of ztd_internal.h is not in the image")
        seam.fail(Int32(index))
        defer { seam.fail(-1) }
        body()
        return !seam.isPending()
    }
}

extension Rig {
    /// Attaches `pipeline`, listens to its main line, and starts it.
    func probed(_ pipeline: Pipeline<Samples, Samples>) async throws -> (session: PipelineSession, probe: OutputProbe) {
        let session = try await engine.attach(pipeline, to: source)
        let probe = OutputProbe()
        engine.core.addProbe(probe, to: session.core)
        try session.start()
        return (session, probe)
    }

    /// Moves `box` to `value` on the main actor and has the session read its switches at once (BIND-3).
    func set(_ box: StateBox<Bool>, to value: Bool, of session: PipelineSession) async {
        await MainActor.run {
            box.value = value
            session.syncBindings()
        }
    }

    /// What the control context says a session still holds of value commands that were not applied.
    func pendingPayloads(of session: PipelineSession) -> Int {
        (try? engine.core.control.sync { session.core.payloads.count }) ?? -1
    }
}
