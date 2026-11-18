import Foundation

/// One source as one engine runs it: the place where every attachment of the engine to that
/// source meets (ATT-6). The source is prepared once, started with the first attachment that
/// starts and stopped with the last that stops, and every attachment sees the same blocks.
///
/// A hub is either fed by its source through an adapter, or, for a processed source, by the
/// main-line output of a session the hub owns on the upstream source (SRC-2).
///
/// Threading: the control context only. `runner` is the hub's half on the analysis side.
final class SourceHub: @unchecked Sendable {
    let source: any SampleSource
    let runner: HubRunner
    /// The engine's attention word (not owned): what the hub's runner and the runners of its
    /// sessions tell the control context with.
    let attention: OpaquePointer
    /// The source as a processed source, when it is one.
    let processed: ProcessedSource?

    /// Preparing the source, shared by every attachment that arrives meanwhile.
    var preparation: Task<Result<Bool, DSPError>, Never>?
    var isPrepared = false

    var adapter: SourceAdapter?
    var input: AudioBuffer?
    /// For a processed source: the session that produces its samples.
    var inner: SessionCore?

    /// What the hub's sessions are compiled for.
    var format = SignalFormat(sampleRate: 48_000, channelCount: 1)
    var maximumFrames = 512
    var environment = DSPEnvironment()

    /// The attachments, in the order they were made.
    var sessions: [SessionCore] = []
    /// Attachments on their way in: a hub with one is not discarded.
    var pendingAttaches = 0
    /// The source is delivering: started, and not stopped since.
    var isStarted = false
    var isInterrupted = false
    /// The stream ended or failed: the next start prepares the source again (§4.5).
    var streamOver = false
    /// Above zero while the control context works on what the hub runs.
    var pauseDepth = 0
    /// Moves when the stream starts over.
    var epoch: UInt64 = 0
    /// Counts the stages handed to the runner.
    var stageSerial: UInt64 = 0
    /// The thread of its own that runs the hub, for an `.asFastAsPossible` source.
    var thread: RunnerThread?
    var lastDropped = 0
    var lastNonFinite = 0

    init(source: any SampleSource, attention: OpaquePointer) throws(DSPError) {
        self.source = source
        self.processed = SourceAdapter.processed(source)
        self.attention = attention
        runner = try HubRunner(attention: attention)
    }

    var isDerived: Bool { processed != nil }

    /// True for a source the engine asks for blocks as fast as they are processed.
    var isFreeRunning: Bool { adapter?.pacing == .asFastAsPossible }

    /// Seconds between two looks at the source: half a block, and never under a millisecond
    /// (§4.3).
    var pollInterval: Double {
        max(0.001, Double(maximumFrames) / max(format.sampleRate, 1) / 2)
    }

    /// The sessions that run, in the order they were attached.
    var scheduled: [SessionCore] { sessions.filter(\.isScheduled) }
}
