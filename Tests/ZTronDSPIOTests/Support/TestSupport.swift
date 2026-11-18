import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// Waits, on the test's task, until `condition` holds; false when it does not within `timeout`.
func eventually(timeout: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

/// A moment of real time, for the things that must not happen within it.
func pause(milliseconds: Int = 20) async {
    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
}

/// A value several threads of a test share.
final class Shared<Value>: @unchecked Sendable {
    // Threading: `value` is read and written only with the lock held.
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result, Failure: Error>(_ body: (inout Value) throws(Failure) -> Result) throws(Failure) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    func get() -> Value { withLock { $0 } }
    func set(_ newValue: Value) { withLock { $0 = newValue } }
}

/// A sink that keeps every sample it is written, channel by channel, and the time of every
/// block: what a test compares with what a source was given.
///
/// It locks and allocates in `write`, which a sink of a product must not; a test may.
final class Collector: FeatureSink, @unchecked Sendable {
    typealias Domain = Samples

    private struct Contents {
        var channels: [[Float]] = []
        var times: [Double] = []
        var blockSizes: [Int] = []
        var claims = 0
        var environment: DSPEnvironment?
    }

    private let contents = Shared(Contents())

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        contents.withLock {
            $0.claims += 1
            $0.environment = environment
        }
    }

    func write(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        contents.withLock { contents in
            if contents.channels.count != block.channelCount {
                // Another channel count: the plan was compiled anew for another format.
                contents.channels = [[Float]](repeating: [], count: block.channelCount)
            }
            for channel in 0 ..< block.channelCount {
                contents.channels[channel].append(contentsOf: block.samples(ofChannel: channel))
            }
            contents.times.append(frame.time)
            contents.blockSizes.append(block.frameCount)
        }
    }

    func release() {}

    /// The samples of one channel, since the format last changed.
    func samples(ofChannel channel: Int = 0) -> [Float] {
        contents.withLock { channel < $0.channels.count ? $0.channels[channel] : [] }
    }

    var channelCount: Int { contents.withLock { $0.channels.count } }
    var frameCount: Int { contents.withLock { $0.channels.first?.count ?? 0 } }
    var times: [Double] { contents.withLock { $0.times } }
    var blockSizes: [Int] { contents.withLock { $0.blockSizes } }
    var blockCount: Int { contents.withLock { $0.times.count } }
    var claims: Int { contents.withLock { $0.claims } }
    var environment: DSPEnvironment? { contents.withLock { $0.environment } }
}

/// The events of a session, as they arrive.
final class SessionLog: Sendable {
    private let events = Shared<[SessionEvent]>([])

    init(_ session: PipelineSession) {
        let stream = session.events, events = events
        Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [SessionEvent] { events.get() }
    func contains(_ event: SessionEvent) -> Bool { events.get().contains(event) }
    func count(of event: SessionEvent) -> Int { events.get().filter { $0 == event }.count }

    var states: [SessionState] {
        events.get().compactMap { if case .stateChanged(let state) = $0 { state } else { nil } }
    }
}

/// The events of a source that no engine listens to. A source's stream has one consumer and
/// ends for good when that consumer is cancelled, so the listener is never cancelled: it ends
/// when the source is released.
final class SourceLog: Sendable {
    private let events = Shared<[SourceEvent]>([])

    convenience init(_ source: any SampleSource) {
        self.init(stream: source.events)
    }

    /// Listens to a channel's stream: what a source's own thread sends.
    init(stream: AsyncStream<SourceEvent>) {
        let events = events
        Task.detached {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }

    var all: [SourceEvent] { events.get() }

    /// Waits until the source has said exactly `expected`, in that order.
    func shows(_ expected: [SourceEvent], timeout: Double = 5) async -> Bool {
        await eventually(timeout: timeout) { self.events.get() == expected }
    }
}

extension PipelineSession {
    /// Waits until the session is in `state`.
    func reaches(_ state: SessionState, timeout: Double = 5) async -> Bool {
        await eventually(timeout: timeout) { self.state == state }
    }
}

/// A pipeline with memory, written against the public API as a stage outside the package
/// would be (the core holds no processing stage, EXT-1): two biquad sections and a gain. What
/// it puts out depends on every sample before, so a sample that was lost, repeated or moved
/// across a block boundary shows in everything that follows.
struct Smoothing: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.biquad(
            sections: [
                BiquadSection(b0: 0.2, b1: 0.4, b2: 0.2, a1: -0.3, a2: 0.1),
                BiquadSection(b0: 0.5, b1: -0.2, b2: 0.1, a1: 0.25, a2: -0.05),
            ],
            precision: .single))
        context.emit(.gain(factor: 0.75, ramp: 0))
    }
}

/// One attachment of a pipeline that ends in a ``Collector``, on an engine of its own.
struct Attachment {
    let engine: DSPEngine
    let session: PipelineSession
    let sink: Collector
    let log: SessionLog

    /// Attaches a pipeline to `source`: the samples as they are, or smoothed.
    init(_ source: any SampleSource, blockSize: Int = 64, smoothing: Bool = false) async throws {
        engine = DSPEngine(blockSize: blockSize)
        sink = Collector()
        let plain = Pipeline<Samples, Samples>()
        let pipeline = smoothing ? plain.appending(Smoothing()).emit(to: sink) : plain.emit(to: sink)
        session = try await engine.attach(pipeline, to: source)
        log = SessionLog(session)
    }
}

/// A clock a test holds. A thread that sleeps on it waits for the test to move the time, and
/// meanwhile gives way for a moment of real time at each look.
final class ManualClock: PacingClock, @unchecked Sendable {
    private let time = Shared(0.0)
    private let looks = Shared(0)

    var now: Double { time.get() }

    func sleep(until deadline: Double) {
        looks.withLock { $0 += 1 }
        if now < deadline { usleep(100) }
    }

    func advance(by seconds: Double) {
        time.withLock { $0 += seconds }
    }

    /// How often a thread has asked to sleep: it moves while a thread paces on this clock.
    var sleepCount: Int { looks.get() }
}

/// A clock that never makes a thread wait: a sleep moves the time to the deadline at once.
/// What is paced on it happens in the order and at the times of the real thing, as fast as the
/// machine allows.
final class LeapingClock: PacingClock, @unchecked Sendable {
    private let time = Shared(0.0)

    var now: Double { time.get() }

    func sleep(until deadline: Double) {
        time.withLock { $0 = max($0, deadline) }
        usleep(50)                                  // a thread with nothing to do gives way
    }
}

/// A clock on which every sleep lasts 300 ms of real time and no time ever passes: a thread
/// that paces on it does not notice for that long that it was asked to end.
final class StubbornClock: PacingClock, Sendable {
    private let asleep = Shared(false)
    var now: Double { 0 }

    /// True while a thread is inside `sleep(until:)`: what tells "gave up waiting for the
    /// thread" from "waited until the thread came back" without reading the wall clock.
    var isAsleep: Bool { asleep.get() }

    func sleep(until deadline: Double) {
        asleep.set(true)
        usleep(2_000_000)
        asleep.set(false)
    }
}

/// The seam of `ztd_internal.h` for the tests of failed creation: request number `index` for
/// memory made by the calling thread, counted from this call, is refused once; a negative
/// index refuses none. The function is in no public header, on purpose; it is looked up by
/// name.
func refuseAllocation(_ index: Int) {
    let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let symbol = dlsym(anyImage, "ztd_fail_allocation") else {
        Issue.record("the seam of ztd_internal.h is not in the image")
        return
    }
    unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(Int32(index))
}

/// A push source that does nothing but keep the ring the engine hands it: how a test comes by
/// a ring of a given shape.
final class RingProbe: PushSampleSource, Sendable {
    let format: SignalFormat
    private let channel = SourceEventChannel()
    private let ring = Shared<RingWriter?>(nil)

    init(format: SignalFormat) {
        self.format = format
    }

    var events: AsyncStream<SourceEvent> { channel.stream }
    var writer: RingWriter? { ring.get() }

    func prepare() async throws(DSPError) {}
    func start() throws(DSPError) {}
    func stop() {}
    func connect(to ring: RingWriter) { self.ring.set(ring) }
}

/// Audio files written for one test, in a directory of their own that goes with the value.
final class AudioFixtures: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ztrondsp-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `channels` (one array per channel, of one length) as a file and returns where.
    ///
    /// - Parameter bitDepth: 32 writes Float32 samples, which come back bit for bit; 16 writes
    ///   integers, which come back exactly when every sample is a multiple of 1/32 768.
    func write(_ channels: [[Float]], sampleRate: Double, name: String, bitDepth: Int = 32) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: bitDepth == 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels.count), interleaved: false))
        let frames = channels.first?.count ?? 0
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { data[index].update(from: base, count: frames) }
            }
        }
        // The file is closed when the writer goes out of scope.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if frames > 0 { try file.write(from: buffer) }
        }
        return url
    }
}

/// A deterministic signal: every sample is a multiple of 1/32 768, so it survives a 16-bit
/// file exactly, and no two stretches of it are alike.
func steppedSignal(count: Int, seed: UInt64) -> [Float] {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return (0 ..< count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let step = Int(truncatingIfNeeded: state >> 40) % 30_000 - 15_000
        return Float(step) / 32_768
    }
}
