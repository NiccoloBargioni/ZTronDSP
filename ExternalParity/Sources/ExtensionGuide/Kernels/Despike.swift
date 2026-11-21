import Foundation
import ZTronDSP

// The extension guide, row 2 of §5.11.1: a sample-domain stage in Swift (Docs/ExtensionGuide.md).

// snippet:begin despike-stage
/// Removes single-sample spikes: every sample becomes the median of itself and its two
/// neighbours. A median is not a linear filter, so no stock kernel computes it.
///
/// The stage runs on any sampled sequence and keeps its domain. It delays the signal by one
/// frame. An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct Despike: SequenceStage {
    /// The stage's switch (§5.9). Switched off, the signal passes, one frame late like the
    /// processed one (ACT-8).
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// Emits the processor. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let channels = context.channelCount
        // The latency is stated here, for the environment downstream, and by the processor that
        // runs: a plan in which the two differ is refused.
        context.emit(.processor(CustomProcessor(name: "Despike", key: channels, latencyFrames: 1) {
            _ throws(DSPError) -> any SampleProcessor in
            let processor = try DespikeProcessor(channelCount: channels)
            // `make` runs on the control context. One block of silence here makes whatever the
            // first `process` asks of the Swift runtime happen now, and not on the analysis
            // thread (RT-2); the reset forgets the block.
            let scratch = try AudioBuffer(channelCount: max(channels, 1), capacity: 1)
            var block = scratch.block()
            processor.process(&block)
            processor.reset()
            return processor
        }))
    }
}
// snippet:end despike-stage

// snippet:begin despike-processor
/// What runs a `Despike`: a block in place, each channel with the two samples before it.
///
/// Threading: created on the control context, where it allocates its memory once. `process`
/// and `reset` belong to the analysis thread: no allocation, no lock, no logging (RT-2), and
/// the loops are `while` loops. One thread at a time.
public final class DespikeProcessor: SampleProcessor {
    private let channelCount: Int
    /// Per channel: the two samples before the block, the older one first.
    private let history: AlignedBuffer<Float>

    /// A processor for `channelCount` channels. Control context; allocates.
    public init(channelCount: Int) throws(DSPError) {
        self.channelCount = max(channelCount, 1)
        history = try AlignedBuffer<Float>(count: 2 * max(channelCount, 1))
    }

    /// The median of x[n − 2], x[n − 1] and x[n] stands for x[n − 1]: one frame of delay.
    public var latencyFrames: Int { 1 }
    /// Two frames after a cold start the memory holds signal, not the zeros it starts with.
    public var settlingFrames: Int { 2 }

    /// Analysis thread; allocation-free.
    public func process(_ block: inout AudioBlock) {
        var channel = 0
        while channel < block.channelCount, channel < channelCount {
            let samples = block.channel(channel)
            let memory = history.baseAddress + 2 * channel
            var older = memory[0], newer = memory[1]
            var frame = 0
            while frame < block.frameCount {
                let current = samples[frame]
                samples[frame] = max(min(older, newer), min(max(older, newer), current))
                older = newer
                newer = current
                frame &+= 1
            }
            memory[0] = older
            memory[1] = newer
            channel &+= 1
        }
    }

    /// A cold start (ACT-10). Analysis thread; allocation-free.
    public func reset() {
        history.clear()
    }
}
// snippet:end despike-processor

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a median of three: see ``Despike``. Usable on any thread.
    public func despiked(isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Despike(isActive: isActive))
    }
}

// snippet:begin despike-sentence
extension PipelineBuilder {
    /// Catches the stage after a domain it does not run on, with a sentence that names it (ORD-4).
    @available(*, unavailable, message: "Despike runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Despike) -> Pipeline<I, O> { accumulated }
}
// snippet:end despike-sentence
