/// What a source delivers: a sample rate and a channel count (§4.4). Samples are always
/// Float32, non-interleaved (§6.1).
///
/// An immutable value, usable on any thread.
public struct SignalFormat: Hashable, Sendable, CustomStringConvertible {
    /// Samples per second.
    public let sampleRate: Double
    /// Channels in the signal.
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// True for a positive, finite sample rate and at least one channel.
    public var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount >= 1
    }

    /// The format with another channel count.
    public func withChannelCount(_ count: Int) -> SignalFormat {
        SignalFormat(sampleRate: sampleRate, channelCount: count)
    }

    /// The format with another sample rate.
    public func withSampleRate(_ rate: Double) -> SignalFormat {
        SignalFormat(sampleRate: rate, channelCount: channelCount)
    }

    public var description: String {
        "\(sampleRate) Hz, \(channelCount) channel\(channelCount == 1 ? "" : "s")"
    }
}

/// How the channels of a signal enter a framing step (§5.3, MIC-6).
public enum ChannelPolicy: Hashable, Sendable {
    /// The mean of all channels. The default.
    case mixdown
    /// One channel, by zero-based index.
    case channel(Int)
    /// Every channel on its own: one frame per channel per hop, in channel order.
    case perChannel
}

/// The kind of source a pipeline is attached to. Informational only: a stage MUST NOT change
/// its behaviour on it (§5.4).
public enum SourceKind: Hashable, Sendable {
    /// Clocked by something else: hardware, a reader thread.
    case push
    /// Clocked by the engine.
    case pull
    /// The main-line output of another pipeline (SRC-2).
    case derived
    /// No source: `pipeline.process(_:format:)` on the caller's thread.
    case offline
}
