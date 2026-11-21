import Foundation

/// Runs a plan on samples the caller holds, on the caller's thread (WP-323): the engine
/// without a source, a thread or a clock. It is what `pipeline.process(_:format:)` uses, and
/// because it drives the same plan with the same blocks, offline output equals engine output.
final class OfflineRunner: PlanOutput {
    let plan: ExecutionPlan
    let format: SignalFormat
    let blockSize: Int
    private let input: AudioBuffer
    private var claimed: [ObjectIdentifier] = []
    private var claimedSinks: [any PlanSink] = []

    // What the main line produced.
    private(set) var samples: [[Float]] = []
    private(set) var frames: [[Float]] = []
    private(set) var scalars: [ScalarFrame] = []
    private(set) var nonFiniteCount = 0

    init(stages: [StageDescription], format: SignalFormat, blockSize: Int, crossovers: CrossoverTable) throws(DSPError) {
        guard format.isValid else {
            throw .invalidParameter(stage: .none, parameter: "format", reason: "\(format) is not a signal format")
        }
        guard blockSize >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "blockSize", reason: "a block holds at least one frame, not \(blockSize)")
        }
        self.format = format
        self.blockSize = blockSize
        let environment = DSPEnvironment(sampleRate: format.sampleRate, channelCount: format.channelCount, blockSize: blockSize, isRealTime: false)
        let lowered = try PlanCompiler(crossovers: crossovers).lower(stages, environment: environment, blockSize: blockSize)
        // A binding is read on the main actor only (BIND-1). Off it, a bound switch counts as on.
        let values: [Bool] = OfflineRunner.onMainThread
            ? MainActor.assumeIsolated { lowered.switches.map { $0.read() } }
            : [Bool](repeating: true, count: lowered.switches.count)
        plan = try ExecutionPlan(lowered: lowered, switchValues: values, crossovers: crossovers, generation: 1, previous: nil)
        input = try AudioBuffer(channelCount: format.channelCount, capacity: blockSize)
        try claimSinks()
        plan.output = self
    }

    deinit {
        releaseSinks()
    }

    private static var onMainThread: Bool { pthread_main_np() != 0 }

    private func claimSinks() throws(DSPError) {
        var identities: [(identity: ObjectIdentifier, name: String)] = []
        for entry in plan.sinks {
            if let identity = entry.description.sink.identity { identities.append((identity, entry.description.sink.name)) }
        }
        try SinkRegistry.claim(identities)
        claimed = identities.map(\.identity)
        do throws(DSPError) {
            for entry in plan.sinks {
                let position = entry.description.position
                try entry.sink.claim(axis: position.environment.frequencyAxis, environment: position.environment, domain: position.domain, format: position.format)
                claimedSinks.append(entry.sink)
                entry.sink.setLive(true)
            }
        } catch {
            releaseSinks()
            throw error.inStage(.none)
        }
    }

    private func releaseSinks() {
        for sink in claimedSinks {
            sink.setLive(false)
            sink.release()
        }
        claimedSinks = []
        SinkRegistry.release(claimed)
        claimed = []
    }

    /// Runs the channels through the plan in blocks of `blockSize` frames. May be called more
    /// than once: the plan keeps its state, as it does between the blocks of a live session.
    func run(_ channels: [[Float]]) {
        let count = channels.map(\.count).min() ?? 0
        var position = 0
        var consumed = 0
        while position < count {
            let frames = min(blockSize, count - position)
            var block = input.block(frameCount: frames)
            for (channel, source) in channels.enumerated() where channel < format.channelCount {
                let target = block.channel(channel)
                source.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var index = 0
                    while index < frames {
                        // A non-finite sample is replaced by 0 where the signal enters (NUM-1).
                        let value = base[position + index]
                        if value.isFinite { target[index] = value } else { target[index] = 0; nonFiniteCount += 1 }
                        index += 1
                    }
                }
            }
            block.setFrameCount(frames)
            plan.process(FrameView(samples: block, index: consumed, time: Double(consumed) / format.sampleRate))
            consumed += frames
            position += frames
        }
    }

    /// Delivers the bound results, as the session's heartbeat would. Main actor.
    @MainActor
    static func deliver(_ slots: [ResultSlot], to results: [BoundResult]) {
        for (slot, result) in zip(slots, results) where slot.writes > 0 {
            switch result.kind {
            case .value, .frame: result.write(slot.readScalar())
            case .vector: if let values = slot.readVector() { result.write(values) }
            }
        }
    }

    func finish() {
        if OfflineRunner.onMainThread {
            let slots = plan.resultSlots, results = plan.lowered.results
            MainActor.assumeIsolated { OfflineRunner.deliver(slots, to: results) }
        }
        releaseSinks()
    }

    // MARK: PlanOutput

    func take(_ frame: FrameView) {
        if let block = frame.samples {
            while samples.count < block.channelCount { samples.append([]) }
            for channel in 0 ..< block.channelCount { samples[channel].append(contentsOf: block.samples(ofChannel: channel)) }
        } else if let real = frame.real {
            frames.append(Array(real.values))
        } else if let scalar = frame.scalar {
            scalars.append(scalar)
        }
    }

    func takeShadow(_ frame: FrameView) {}
}

extension Pipeline where Input == Samples {
    private func runOffline(_ channels: [[Float]], _ format: SignalFormat, _ blockSize: Int, _ crossovers: CrossoverTable) throws(DSPError) -> OfflineRunner {
        guard channels.count == format.channelCount else {
            throw .invalidParameter(stage: .none, parameter: "samples", reason: "\(channels.count) channels of samples for a format of \(format.channelCount)")
        }
        let runner = try OfflineRunner(stages: stages, format: format, blockSize: blockSize, crossovers: crossovers)
        runner.run(channels)
        runner.finish()
        return runner
    }
}

extension Pipeline where Input == Samples, Output == Samples {
    /// Runs the pipeline on `samples`, synchronously on the caller's thread, and returns the
    /// main line's output (§4.5). Sinks fill as they do live.
    ///
    /// The same plan the engine would run is compiled and driven in blocks of `blockSize`
    /// frames, so the result equals what a session attached to a source of these samples
    /// produces. Bound switches are read once, at the start, when the call is made on the main
    /// thread, and count as on otherwise; bound results are delivered at the end under the
    /// same condition (BIND-1).
    ///
    /// Compiles a plan, so it allocates: not for the analysis thread, and for a long input not
    /// for the main thread either (§9.2).
    public func process(
        _ samples: [Float], format: SignalFormat, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [Float] {
        try runOffline([samples], format, blockSize, crossovers).samples.first ?? []
    }

    /// Runs the pipeline on a signal of several channels, one array per channel. As the
    /// single-channel `process`, it runs synchronously on the caller's thread and compiles a plan,
    /// so it allocates: not for the analysis thread.
    public func process(
        channels: [[Float]], format: SignalFormat, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [[Float]] {
        try runOffline(channels, format, blockSize, crossovers).samples
    }
}

extension Pipeline where Input == Samples, Output: RealVectorDomain {
    /// Runs the pipeline on `samples` and returns the frames at the end of its main line, one array
    /// per frame. As the `process` of samples, it runs synchronously on the caller's thread and
    /// compiles a plan, so it allocates: not for the analysis thread.
    public func process(
        _ samples: [Float], format: SignalFormat, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [[Float]] {
        try runOffline([samples], format, blockSize, crossovers).frames
    }
}

extension Pipeline where Input == Samples, Output: ScalarValuedDomain {
    /// Runs the pipeline on `samples` and returns the values at the end of its main line. As the
    /// `process` of samples, it runs synchronously on the caller's thread and compiles a plan, so
    /// it allocates: not for the analysis thread.
    public func process(
        _ samples: [Float], format: SignalFormat, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [ScalarFrame] {
        try runOffline([samples], format, blockSize, crossovers).scalars
    }
}

extension Pipeline where Input == Samples {
    /// Runs the pipeline on `samples` for the sake of its sinks, whatever its output domain. As
    /// `process`, it runs synchronously on the caller's thread and compiles a plan, so it
    /// allocates: not for the analysis thread.
    public func run(
        on samples: [Float], format: SignalFormat, blockSize: Int = 512, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) {
        _ = try runOffline([samples], format, blockSize, crossovers)
    }
}

/// A pipeline compiled for one format and run block by block on the caller's thread, with
/// nothing between the caller and its plan: what the package's test product runs inside the
/// allocation audit (EXT-3).
///
/// `package`: a hook for `ZTronDSPTesting`, which is part of this package (VIS-1), not API.
/// One thread makes it, runs it and finishes it.
package final class DrivenPipeline {
    private let runner: OfflineRunner
    /// Frames run so far: where the next block begins.
    private var position = 0

    /// Compiles `pipeline` as an attachment does, for a signal of `format` in blocks of at
    /// most `blockSize` frames, and claims its sinks. Allocates.
    package init<Output: SignalDomain>(
        _ pipeline: Pipeline<Samples, Output>, format: SignalFormat, blockSize: Int, crossovers: CrossoverTable
    ) throws(DSPError) {
        runner = try OfflineRunner(stages: pipeline.stages, format: format, blockSize: blockSize, crossovers: crossovers)
        // The runner's own collection of the main line allocates; the plan does not.
        runner.plan.output = nil
    }

    /// Runs the valid frames of `block` through the plan, as the block that follows the ones
    /// run before. `block` has the format's channels and at most `blockSize` frames. It
    /// allocates nothing when no stage of the pipeline does (RT-2).
    package func run(_ block: AudioBlock) {
        runner.plan.process(FrameView(samples: block, index: position, time: Double(position) / runner.format.sampleRate))
        position &+= block.frameCount
    }

    /// Releases the pipeline's sinks.
    package func finish() {
        runner.finish()
    }
}
