/// Where samples come from (§4.4). A source knows nothing about pipelines: the same pipeline
/// attaches to a microphone, a file, a generator or a processed signal, and a component that
/// displays or analyses takes `any SampleSource` and nothing more specific (SRC-3).
///
/// A source is one of two kinds. A ``PushSampleSource`` is clocked by something else, hardware
/// or a reader thread, and writes into a ring the engine hands it. A ``PullSampleSource`` is
/// clocked by the engine, which asks it for samples. These three protocols are the whole
/// contract: a source written outside the package is served exactly like a stock one (SRC-1).
///
/// Threading: `prepare`, `start` and `stop` are called on the control context, one at a time,
/// and may allocate and block. `format` is read there too. `events` has one consumer; while
/// the source is attached that consumer is the engine, so an app follows the session's events
/// instead.
public protocol SampleSource: AnyObject, Sendable {
    /// The sample rate and the channel count the source delivers. Valid after `prepare()`.
    var format: SignalFormat { get }

    /// What happens to the source while it runs.
    var events: AsyncStream<SourceEvent> { get }

    /// Brings the source to the point where it can start: permission, session, format
    /// discovery. Called once per engine before the first attachment, and again before a
    /// session that finished or failed is started anew; a source that has an end starts over.
    func prepare() async throws(DSPError)

    /// Starts delivering. Called with the first attachment that starts (ATT-6).
    func start() throws(DSPError)

    /// Stops delivering. Called with the last attachment that stops.
    func stop()
}

/// A source clocked by something else: hardware, a reader thread. It writes into the ring the
/// engine hands it and never waits for the engine (RT-8).
///
/// Threading as for every source: `connect` too runs on the control context, where it may
/// allocate. The source then writes into the ring from its own thread (the I/O thread, for
/// hardware), and `RingWriter.write` does not allocate.
public protocol PushSampleSource: SampleSource {
    /// Gives the source the ring it writes into. Called on the control context after
    /// `prepare()` and again after every format change, with a ring of the new format; from
    /// then on the source writes only to the newest ring.
    func connect(to ring: RingWriter)
}

/// A source clocked by the engine.
///
/// Threading as for every source, and `pacing` is read on the control context. `render` runs
/// on the analysis thread, or on the offline thread of an `.asFastAsPossible` source, and does
/// not allocate (RT-2).
public protocol PullSampleSource: SampleSource {
    /// Whether the engine asks for a block once per block duration or as fast as it can
    /// process them.
    var pacing: Pacing { get }

    /// Fills `block` with up to `block.capacity` frames, declares how many with
    /// `block.setFrameCount(_:)`, and returns that number. Returning 0 ends the stream.
    ///
    /// Runs on the analysis thread, or on the session's own thread for an
    /// `.asFastAsPossible` source, and is bound by RT-2: memory only, no allocation, no lock,
    /// no logging.
    ///
    /// A source whose format changes says so on `events`, ends the stream of the old format by
    /// returning 0, and is asked again with blocks of the new format once the engine has
    /// re-planned (ATT-4).
    func render(into block: inout AudioBlock) -> Int
}

/// How the engine paces a pull source.
///
/// A value, usable on any thread; it does not allocate.
public enum Pacing: Hashable, Sendable {
    /// One block per block duration, on the analysis thread.
    case realTime
    /// As fast as the blocks are processed, on a thread of its own, so that it cannot starve
    /// a live session (§4.3).
    case asFastAsPossible
}

/// What happened to a source (§4.4, CAP-8).
///
/// A value, usable on any thread; it does not allocate.
public enum SourceEvent: Sendable, Hashable {
    /// The source delivers another format from now on. The engine re-plans (ATT-4).
    case formatChanged(SignalFormat)
    /// The source stopped delivering and may resume by itself.
    case interrupted
    /// The source delivers again after an interruption. Stages start cold (ACT-10).
    case resumed
    /// The input route changed.
    case routeChanged(RouteChange)
    /// The system's media services were reset; the source rebuilt itself.
    case mediaServicesReset
    /// The source had to drop frames because its consumer fell behind (RT-8).
    case overrun(droppedFrames: Int)
    /// The source has nothing more to deliver.
    case ended
    /// The source cannot go on.
    case failed(DSPError)
}

/// What changed about the input route (MIC-4).
///
/// A value, usable on any thread; it does not allocate.
public enum RouteChange: Hashable, Sendable {
    /// The selected input disappeared; the source fell back to the system's choice.
    case inputLost
    /// The selected input came back and is used again.
    case inputRestored
    /// The system chose another input.
    case inputChanged
    /// Something else about the route changed; the input is the same.
    case other
}

/// Carries a source's events to its consumer. A source keeps one, yields into it, and hands
/// out its stream as `events`.
///
/// Threading: `send` may be called from any thread that is allowed to allocate and lock; it is
/// not for the audio I/O thread or the analysis thread. Creating a channel allocates its
/// stream, and `send` may allocate.
public final class SourceEventChannel: Sendable {
    /// The stream a source returns from `events`.
    public let stream: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    /// A channel that keeps the newest `capacity` events while nobody is listening.
    public init(capacity: Int = 64) {
        (stream, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .bufferingNewest(max(capacity, 1)))
        _ = SourceEventChannel.firstUse
    }

    /// Sends one event into a stream nobody listens to, once in a process, where the first
    /// channel is made (RT-2). Code that sends keeps what `yield` returns for a moment, and
    /// the first use of that type in a process makes the Swift runtime instantiate it, which
    /// allocates. A source that sends from its `render`, as `ScriptedSource` does, reaches
    /// such code on the thread that renders, at the entry of `render`, whether it sends or
    /// not. Here it is reached first, on a thread that may allocate.
    private static let firstUse: Void = {
        let (_, scratch) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .bufferingNewest(1))
        scratch.yield(.interrupted)
        scratch.finish()
    }()

    /// Delivers an event.
    public func send(_ event: SourceEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}
