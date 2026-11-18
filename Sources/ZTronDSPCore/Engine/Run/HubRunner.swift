// The analysis-thread side of a source hub: it turns what the source delivers into blocks and
// runs every session attached to the source on each of them (ATT-6). Nothing here allocates,
// locks or logs (RT-2); loops are `while` loops (CR-002).

/// What a hub works with between two changes made on the control context: handed over whole,
/// so the thread never sees half a change (RT-4).
final class HubStage {
    /// How the hub is driven.
    enum Mode {
        /// Nothing to do: the hub is paused, stopped, or fed by another session's output.
        case idle
        /// A ring is polled every `interval` seconds and drained.
        case polled
        /// The engine asks a pull source for one block per block duration.
        case paced
        /// The engine asks a pull source for blocks as fast as they are processed.
        case free
    }

    let mode: Mode
    let adapter: SourceAdapter?
    let input: AudioBuffer?
    /// The sessions that run, in the order they were attached.
    let sessions: [SessionRunner]
    let sampleRate: Double
    /// Seconds between two looks at a ring.
    let interval: Double
    /// Moves when the stream starts over: the hub counts frames from 0 again.
    let epoch: UInt64
    /// Seconds by which the hub's samples lag the signal they describe: the latency of the
    /// pipeline in front of a processed source, 0 for a source of its own.
    let latency: Double
    /// A number no other stage of the hub has: how the runner tells a new stage from the one
    /// it ran last, whoever installed it and wherever it was allocated.
    let serial: UInt64

    init(mode: Mode, adapter: SourceAdapter?, input: AudioBuffer?, sessions: [SessionRunner], sampleRate: Double,
         interval: Double, epoch: UInt64, latency: Double = 0, serial: UInt64 = 0) {
        self.latency = latency
        self.serial = serial
        self.mode = mode
        self.adapter = adapter
        self.input = input
        self.sessions = sessions
        self.sampleRate = sampleRate
        self.interval = interval
        self.epoch = epoch
    }
}

/// Something that takes the main-line output of a session, block by block, on the analysis
/// thread: the hub of a processed source (SRC-2), or a probe.
protocol MainLineConsumer: AnyObject {
    /// Called at every block boundary of the session, whether or not a block follows.
    func boundary()
    /// Called with each block of output. Allocation-free.
    func consume(_ frame: FrameView)
}

final class HubRunner: MainLineConsumer, @unchecked Sendable {
    let stage: Handoff<HubStage>
    /// The engine's attention word (not owned).
    private let attention: OpaquePointer
    /// The epoch of the stream that ended, or 0; cleared by the control context when it has
    /// seen it. Naming the epoch keeps the end of an old stream from ending the one that
    /// follows a re-plan (ATT-4).
    private let ended: OpaquePointer

    // The thread that runs the hub only.
    private var position = 0
    private var epoch: UInt64 = 0
    private var isOver = false
    private var nextRender = 0.0
    private var seenDropped = 0
    private var seenNonFinite = 0
    /// The serial of the stage the runner last began to run; none before the first.
    private var seenSerial: UInt64?

    /// The most blocks one turn processes before the thread looks at its other hubs again.
    static let blocksPerTurn = 64

    init(attention: OpaquePointer) throws(DSPError) {
        // The hand-over first: it frees itself when the cell that follows cannot be had.
        stage = try Handoff<HubStage>()
        guard let ended = ztd_atomic_create(0) else { throw .resourceAllocationFailed(what: "a source hub") }
        self.ended = ended
        self.attention = attention
    }

    deinit {
        ztd_atomic_destroy(ended)
    }

    // MARK: Control context

    /// Once after a stream has ended: the epoch of that stream. 0 otherwise.
    func takeEnded() -> UInt64 {
        ztd_atomic_exchange(ended, 0)
    }

    // MARK: The thread that runs the hub

    /// Takes a new stage when there is one. Returns the stage to run.
    @inline(__always)
    private func current(_ now: Double) -> HubStage? {
        // No reference to the stage that ran before is held across the hand-over: it could be
        // the last one once the control context has released its own, and the stage would then
        // be freed on this thread (RT-3). A new stage is known by its serial, which also holds
        // when the control context installed it on the runner's behalf.
        guard let current = stage.refresh() else { return nil }
        if current.serial != seenSerial {
            seenSerial = current.serial
            if current.epoch != epoch {
                epoch = current.epoch
                position = 0
                isOver = false
            }
            nextRender = now
        }
        return current
    }

    /// Runs the hub: every block the source has ready, through every session. Returns the time
    /// at which the hub wants to run again; infinity when it has nothing to wait for.
    func turn(now: Double) -> Double {
        guard let stage = current(now), let adapter = stage.adapter, let input = stage.input, !isOver else { return .infinity }
        var blocks = 0
        switch stage.mode {
        case .idle:
            return .infinity

        case .polled:
            while blocks < HubRunner.blocksPerTurn {
                switch adapter.next(into: input) {
                case .block(let frames):
                    run(stage, input, frames)
                    blocks += 1
                case .waiting:
                    watch(adapter)
                    return now + stage.interval
                case .ended:
                    finish()
                    return .infinity
                }
            }
            watch(adapter)
            return now

        case .paced:
            // One block per block duration, on the engine's own clock; a thread that was held
            // up catches up a few blocks at a time and gives up on what is older than a second.
            if nextRender < now - 1 { nextRender = now }
            while nextRender <= now, blocks < 8 {
                // A source that is asked for its blocks has one, or its stream is over: only a
                // ring keeps a hub waiting, and a ring is polled.
                guard case .block(let frames) = adapter.next(into: input) else {
                    finish()
                    return .infinity
                }
                run(stage, input, frames)
                nextRender += Double(frames) / stage.sampleRate
                blocks += 1
            }
            watch(adapter)
            return nextRender

        case .free:
            while blocks < HubRunner.blocksPerTurn {
                guard case .block(let frames) = adapter.next(into: input) else {
                    finish()
                    return .infinity
                }
                run(stage, input, frames)
                blocks += 1
            }
            watch(adapter)
            return now
        }
    }

    @inline(__always)
    private func run(_ stage: HubStage, _ input: AudioBuffer, _ frames: Int) {
        let frame = FrameView(samples: input.block(frameCount: frames), index: position, time: Double(position) / stage.sampleRate)
        var index = 0
        while index < stage.sessions.count {
            stage.sessions[index].run(frame)
            index += 1
        }
        position += frames
    }

    private func finish() {
        isOver = true
        ztd_atomic_store(ended, epoch)
        ztd_atomic_store(attention, 1)
    }

    /// Tells the control context when frames were dropped or replaced since it last looked.
    @inline(__always)
    private func watch(_ adapter: SourceAdapter) {
        let dropped = adapter.droppedFrames, nonFinite = adapter.nonFiniteCount
        if dropped != seenDropped || nonFinite != seenNonFinite {
            seenDropped = dropped
            seenNonFinite = nonFinite
            ztd_atomic_store(attention, 1)
        }
    }

    // MARK: A hub fed by another session's output (SRC-2)

    func boundary() {
        _ = current(0)
    }

    func consume(_ frame: FrameView) {
        guard let stage = stage.installed, let block = frame.samples, !isOver else { return }
        let view = FrameView(samples: block, index: position, time: Double(position) / stage.sampleRate - stage.latency)
        var index = 0
        while index < stage.sessions.count {
            stage.sessions[index].run(view)
            index += 1
        }
        position += block.frameCount
    }
}
