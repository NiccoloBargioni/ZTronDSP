import Foundation
import ZTronDSPCore

/// The envelope of the signal: one (minimum, maximum) pair per stretch of `resolution`
/// seconds, for a `WaveformFeed` and the view that draws it (§5.2, §8.2).
///
/// ```swift
/// Tap { Waveform(resolution: 0.005); Emit(to: waveformFeed) }
/// ```
///
/// The stretches follow one another without overlap, whatever the engine's block size: a
/// pair is the least and the greatest sample of its stretch, and equals what a reduction of
/// the whole signal would give. Pairs leave in frames of as many as a block completes; a
/// pair's time is the time of the first sample of its stretch. Downstream, `featureRate` is
/// the number of pairs per second.
///
/// A multichannel signal is reduced by `channels`. Switched off, it suspends the rest of its
/// branch (ACT-3). An immutable value, usable on any thread.
public struct Waveform: PipelineStage {
    public typealias Input = Samples
    public typealias Output = Envelope

    /// The time one pair covers, in seconds.
    public let resolution: TimeInterval
    public let channels: ChannelPolicy
    public let activation: StageActivation

    public init(resolution: TimeInterval = 0.005, channels: ChannelPolicy = .mixdown, isActive: some ActivationSource = .active) {
        self.resolution = resolution
        self.channels = channels
        self.activation = isActive.stageActivation
    }

    struct Key: Hashable, Sendable {
        let bucket: Int
        let channel: Int?
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "a waveform needs a sample rate, and there is none here") }
        guard resolution > 0, resolution.isFinite else {
            throw context.invalid("resolution", "a pair covers a positive, finite time, not \(resolution) s")
        }
        let bucket = max(Int((resolution * rate).rounded()), 1)
        guard bucket <= 1 << 28 else { throw context.invalid("resolution", "\(resolution) s is \(bucket) samples here: too long for one pair") }
        let channel = try ChannelSelection.resolve(channels, in: context)
        let channelCount = max(context.environment.channelCount, 1), blockFrames = context.maximumBlockFrames
        // The most pairs one block completes, and one for the stretch the block before left open.
        let capacity = blockFrames / bucket + 2
        context.emit(.analysis(AnalysisStep(
            name: "Waveform", key: Key(bucket: bucket, channel: channel), output: .envelope(maximumCount: capacity),
            scope: .spectral(frameSize: bucket, hopSize: bucket, axis: .indices(count: 2))
        ) { () throws(DSPError) -> any AnalysisNode in
            try WaveformNode(bucket: bucket, mixer: ChannelMixer(channel: channel, channelCount: channelCount, maximumFrames: blockFrames), sampleRate: rate)
        }))
    }
}

extension Pipeline where Output == Samples {
    /// The envelope of the signal: see ``Waveform``.
    public func waveform(
        resolution: TimeInterval = 0.005, channels: ChannelPolicy = .mixdown, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Envelope> {
        appending(Waveform(resolution: resolution, channels: channels, isActive: isActive))
    }
}
