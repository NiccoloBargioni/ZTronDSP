/// The main-line output of a pipeline attached to another source, as a source of its own
/// (SRC-2). Anything that takes a source takes it: a view, or `attach` for a further
/// pipeline.
///
/// ```swift
/// let cleaned = microphone.processed(by: Pipeline { HighPass(.butterworth, cutoff: .hertz(90), order: 4) })
/// let session = try await engine.attach(analysis, to: cleaned)
/// ```
///
/// The engine runs the pipeline on the upstream source and hands each block of its output to
/// the pipelines attached to this source inside the same turn of the analysis thread: there
/// is no ring between them and no added latency. The upstream source is prepared, started and
/// stopped by the engine as the attachments to this source come and go.
///
/// Threading: an immutable description plus the format the engine resolves for it; usable on
/// any thread. Creating one allocates.
public final class ProcessedSource: SampleSource, @unchecked Sendable {
    /// The source whose samples the pipeline processes.
    public let upstream: any SampleSource
    let stages: [StageDescription]
    private let channel = SourceEventChannel()
    private let resolved = Locked<SignalFormat?>(nil)

    init(upstream: any SampleSource, stages: [StageDescription]) {
        self.upstream = upstream
        self.stages = stages
    }

    /// The format of the pipeline's output: the upstream format, changed by whatever stages
    /// change the rate. Valid after `prepare()`, or once the source is attached.
    public var format: SignalFormat {
        resolved.get() ?? upstream.format
    }

    /// The events of the processed signal: those of the upstream source, with a format change
    /// reported in the format of the output.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    /// Prepares the upstream source and works out the format of the output. An engine that the
    /// source is attached to does this itself.
    public func prepare() async throws(DSPError) {
        try await upstream.prepare()
        let format = upstream.format
        guard format.isValid else {
            throw .sourceUnavailable(reason: "the upstream source reports the format \(format) after it was prepared")
        }
        let environment = DSPEnvironment(sampleRate: format.sampleRate, channelCount: format.channelCount)
        let lowered = try PlanCompiler(crossovers: .shipped).lower(stages, environment: environment, blockSize: environment.blockSize)
        resolved.set(lowered.output.environment.format)
    }

    /// Does nothing: the engine starts the upstream source with the first attachment that
    /// starts.
    public func start() throws(DSPError) {}

    /// Does nothing: the engine stops the upstream source with the last attachment that stops.
    public func stop() {}

    // MARK: Engine

    /// Records the format of the output, as the engine resolved it for an attachment.
    func setFormat(_ format: SignalFormat) {
        resolved.set(format)
    }

    /// Passes an event of the processed signal on to whoever listens to `events`.
    func send(_ event: SourceEvent) {
        channel.send(event)
    }
}

extension SampleSource {
    /// A source whose samples are this source's samples after `pipeline` (SRC-2). Usable on any
    /// thread; it allocates the source it returns.
    public func processed(by pipeline: Pipeline<Samples, Samples>) -> ProcessedSource {
        ProcessedSource(upstream: self, stages: pipeline.stages)
    }
}
