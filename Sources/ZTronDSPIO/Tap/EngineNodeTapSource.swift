import AVFAudio
import Foundation
import ZTronDSPCore

/// A tap on a node of the app's own `AVAudioEngine` as a source (§4.4): what the app itself
/// is playing, sample for sample.
///
/// ```swift
/// let playback = EngineNodeTapSource(node: player)
/// let session = try await engine.attach(analysis(into: feed), to: playback)
/// try session.start()
/// ```
///
/// A tap delivers bursts of 100 ms and more (E-15). Handed on as they come, they would reach
/// the pipeline, and every view behind it, in jumps. The source therefore keeps a pacing
/// buffer: it releases the samples block by block at the block rate, one burst late, which is
/// when the tap has them. Should more than two bursts ever be waiting, because the tap's
/// clock runs a little faster than the pacer's or the pacer was held up, the excess is
/// released at once.
///
/// The format is the node's output format on the tapped bus, read when the source is
/// prepared. If the node delivers another format later, the source reports `.formatChanged`
/// and the session re-plans.
///
/// The source takes the bus's tap: a tap that was installed there before is replaced, and the
/// tap is removed when the source stops. The node must be attached to an engine before a
/// pipeline is attached to the source. The session, the microphone and the user's permission
/// are not involved.
///
/// Threading: as every source, `prepare`, `start`, `stop` and `connect(to:)` are called by the
/// engine on its control context. The tap's bursts arrive on a thread of AVFAudio's and the
/// blocks leave on a pacing thread of the source's own; neither is a real-time thread, and
/// both may allocate. When the engine's ring is full the newest frames are dropped and
/// counted, and the engine reports `.overrun` (RT-8).
public final class EngineNodeTapSource: PushSampleSource {
    /// The shortest burst a tap delivers, in seconds (E-15): what the source asks for.
    static let shortestBurst = 0.1

    private struct State {
        var isPrepared = false
        var hasFailed = false
        /// Counts the starts: a burst belongs to the tap of one start, and to no other.
        var run = 0
        var outlet: RingWriter?
        var burst: BurstBuffer?
        var pacer: SourceThread?
    }

    private let tap: any NodeTapping
    private let blockSize: Int
    private let clock: any PacingClock
    /// How long `stop()` waits for the pacing thread, in seconds.
    private let stopTimeout: Double
    private let channel = SourceEventChannel()
    private let current = Guarded(SignalFormat(sampleRate: 0, channelCount: 0))
    private let state = Guarded(State())

    /// A source that taps output bus `bus` of `node`.
    ///
    /// - Parameters:
    ///   - node: a node of the app's engine: a player, a mixer, an effect. Not the engine's
    ///     output node, whose format follows the hardware.
    ///   - bus: the output bus to tap.
    ///   - blockSize: frames released per step of the pacer; the engine's block size is the
    ///     natural choice. At least 1.
    public convenience init(node: AVAudioNode, bus: Int = 0, blockSize: Int = 512) {
        self.init(tap: AudioNodeTap(node: node, bus: bus), blockSize: blockSize, clock: MonotonicClock())
    }

    /// A source with the parts a test replaces: the tap and the clock (COV-5), and the time
    /// `stop()` waits for the pacing thread.
    init(tap: any NodeTapping, blockSize: Int, clock: any PacingClock, stopTimeout: Double = 5) {
        self.tap = tap
        self.blockSize = blockSize
        self.clock = clock
        self.stopTimeout = stopTimeout
    }

    deinit {
        stop()
    }

    /// The format of the tapped bus: valid after `prepare()`, and the new one after the
    /// source reported `.formatChanged`. May be read on any thread.
    public var format: SignalFormat { current.get() }

    /// What happens to the source: `.formatChanged`, `.overrun` when the pacing buffer was
    /// full, `.failed`. One consumer, which is the engine while the source is attached.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    /// Reads the format of the tapped bus.
    ///
    /// - Throws: `invalidParameter` for a block size below 1 or a bus the node does not have;
    ///   `sourceUnavailable` when the node is not attached to an engine or its bus has no
    ///   format yet; `unsupportedConfiguration` when the bus does not deliver Float32 or has
    ///   more channels than the pacing buffer takes.
    public func prepare() async throws(DSPError) {
        try state.withLock { state throws(DSPError) in
            guard blockSize >= 1 else {
                throw DSPError.invalidParameter(stage: .none, parameter: "blockSize", reason: "the pacer releases at least one frame per step, not \(blockSize)")
            }
            current.set(try usableOutput().format)
            state.isPrepared = true
            state.hasFailed = false
        }
    }

    /// Installs the tap and starts the pacing thread.
    ///
    /// - Throws: `sourceUnavailable` when the source was not prepared, the node was detached
    ///   since, or the tap cannot be installed; `resourceAllocationFailed` when the pacing
    ///   buffer cannot be had.
    public func start() throws(DSPError) {
        // The two threads hold the state, not the source: a source that is let go ends them.
        let shared = state, current = current, channel = channel, clock = clock, blockSize = blockSize
        try state.withLock { state throws(DSPError) in
            guard state.isPrepared else {
                throw DSPError.sourceUnavailable(reason: "the node tap was not prepared; attach a pipeline to it first")
            }
            guard state.burst == nil else { return }
            let format = try usableOutput().format
            state.burst = try BurstBuffer(channelCount: format.channelCount, capacity: EngineNodeTapSource.capacity(for: format))
            state.hasFailed = false
            state.run += 1
            let run = state.run
            do throws(DSPError) {
                let burstSize = Int((format.sampleRate * EngineNodeTapSource.shortestBurst).rounded(.up))
                try tap.install(bufferSize: burstSize) { format, isFloat, buffers, frameCount in
                    EngineNodeTapSource.receive(format, isFloat, buffers, frameCount, run: run, state: shared, current: current, channel: channel)
                }
            } catch {
                state.burst = nil
                throw error
            }
            state.pacer = SourceThread.start(name: "com.zombietron.ztrondsp.tap", qualityOfService: .userInitiated) { thread in
                EngineNodeTapSource.pace(thread, state: shared, current: current, channel: channel, clock: clock, blockSize: blockSize)
            }
        }
    }

    /// Removes the tap and ends the pacing thread. What the tap had delivered and the pacer
    /// had not released is not part of what follows.
    public func stop() {
        let pacer = state.withLock { state -> SourceThread? in
            guard state.burst != nil || state.pacer != nil else { return nil }
            tap.remove()
            let pacer = state.pacer
            state.pacer = nil
            state.burst = nil
            return pacer
        }
        guard let pacer else { return }
        pacer.cancel()
        // Not under the lock: the pacer takes it at every step.
        if !pacer.join(timeout: stopTimeout) {
            // It ends at its next look at the clock, and writes nothing: the buffer is gone.
            Log.sources.fault("The pacing thread of a node tap did not end in time")
        }
    }

    /// Takes the ring the pacer writes from now on. Called by the engine on its control
    /// context, after `prepare()` and after every format change.
    public func connect(to ring: RingWriter) {
        state.withLock { $0.outlet = ring }
    }

    /// The bus as it is now, when it can be tapped.
    private func usableOutput() throws(DSPError) -> NodeOutput {
        let output = tap.output
        guard output.hasBus else {
            throw .invalidParameter(stage: .none, parameter: "bus", reason: "the node has no such output bus")
        }
        guard output.isAttached else {
            throw .sourceUnavailable(reason: "the node is not attached to an engine")
        }
        guard output.format.isValid else {
            throw .sourceUnavailable(reason: "the node's output has no format yet (\(output.format))")
        }
        guard output.isFloat else {
            throw .unsupportedConfiguration(reason: "the node's output is not Float32; a tap takes the format of an engine's nodes")
        }
        guard output.format.channelCount <= EngineInputCapture.maximumChannelCount else {
            throw .unsupportedConfiguration(
                reason: "the node's output has \(output.format.channelCount) channels; the pacing buffer takes at most \(EngineInputCapture.maximumChannelCount)")
        }
        return output
    }

    /// Frames the pacing buffer holds: a second and a half, which is more than three of the
    /// longest bursts a tap delivers.
    static func capacity(for format: SignalFormat) -> Int {
        Int((format.sampleRate * 1.5).rounded(.up))
    }
}

// MARK: The two threads

extension EngineNodeTapSource {
    /// A burst from the tap, on AVFAudio's thread: into the pacing buffer.
    private static func receive(
        _ format: SignalFormat, _ isFloat: Bool, _ buffers: UnsafePointer<AudioBufferList>, _ frameCount: Int, run: Int,
        state: Guarded<State>, current: Guarded<SignalFormat>, channel: SourceEventChannel
    ) {
        state.withLock { state in
            // A burst that was on its way when the source stopped belongs to nobody, also when
            // the source has been started again since.
            guard state.burst != nil, state.run == run, !state.hasFailed else { return }
            guard isFloat, format.isValid, format.channelCount <= EngineInputCapture.maximumChannelCount else {
                state.hasFailed = true
                channel.send(.failed(.unsupportedConfiguration(reason: "the tapped node now delivers \(format), which is not a Float32 format the tap can take")))
                return
            }
            if format != current.get() {
                // The node delivers another format from here on: a buffer of the new shape,
                // and nothing is released until the engine has handed over a ring of it.
                guard let burst = try? BurstBuffer(channelCount: format.channelCount, capacity: capacity(for: format)) else {
                    state.hasFailed = true
                    channel.send(.failed(.resourceAllocationFailed(what: "the pacing buffer of a node tap")))
                    return
                }
                state.burst = burst
                state.outlet = nil
                current.set(format)
                channel.send(.formatChanged(format))
            }
            state.burst?.append(buffers, frameCount: frameCount)
        }
    }

    /// The pacing thread: one block per block duration from the moment a burst is there, and
    /// without a wait while more than two bursts are waiting.
    private static func pace(
        _ thread: SourceThread, state: Guarded<State>, current: Guarded<SignalFormat>, channel: SourceEventChannel,
        clock: any PacingClock, blockSize: Int
    ) {
        var buffer: ZTronDSPCore.AudioBuffer?
        var deadline = clock.now
        var isReleasing = false
        var reportedLoss = 0
        while !thread.isCancelled {
            let format = current.get()
            let blockDuration = Double(blockSize) / max(format.sampleRate, 1)
            if buffer?.channelCount != format.channelCount {
                buffer = try? ZTronDSPCore.AudioBuffer(channelCount: format.channelCount, capacity: blockSize)
            }
            var released = 0, waiting = 0, mayWait = 0, lost = 0
            if let buffer {
                state.withLock { state in
                    guard let burst = state.burst, burst.channelCount == buffer.channelCount else { return }
                    lost = burst.lostFrames
                    guard burst.available >= blockSize, let outlet = state.outlet, outlet.channelCount == burst.channelCount else { return }
                    var block = buffer.block(frameCount: 0)
                    released = burst.release(into: &block)
                    outlet.write(block)
                    waiting = burst.available
                    mayWait = 2 * max(burst.largestBurst, blockSize)
                }
            }
            if lost != reportedLoss {
                if lost > reportedLoss { channel.send(.overrun(droppedFrames: lost - reportedLoss)) }
                reportedLoss = lost
            }
            let now = clock.now
            if released > 0 {
                // The schedule starts with the first block of what has arrived; a thread that
                // was held up does not owe more than a second of the past.
                if !isReleasing || deadline < now - 1 {
                    isReleasing = true
                    deadline = now
                }
                deadline = waiting > mayWait ? now : deadline + blockDuration
            } else {
                // Nothing to release: the schedule starts again when a burst is there.
                isReleasing = false
                deadline = now + blockDuration
            }
            while !thread.isCancelled, clock.now < deadline { clock.sleep(until: deadline) }
        }
    }
}
