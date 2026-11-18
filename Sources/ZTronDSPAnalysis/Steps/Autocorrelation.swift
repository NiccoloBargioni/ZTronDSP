import Foundation
import ZTronDSPCore

/// The autocorrelation of a sampled sequence, frame by frame (§6.7): one vector of lags per
/// hop, `r[ℓ] = Σₙ x[n]·x[n + ℓ]` over the last `window` values, for the lags `0 … maxLag`.
///
/// ```swift
/// Pipeline {
///     Autocorrelation(window: 2_048, hop: 512, maxLag: 1_024, normalization: .coefficient)
///     Emit(to: lagFeed)                        // a heat map of lags over time
/// }
/// ```
///
/// - It follows any sampled sequence: samples, a novelty curve, a scalar track. `window` and
///   `hop` count values of that sequence: samples after samples, one value per feature frame
///   after a novelty curve. Like a block of sequence stages, a block that begins with it, or
///   with sequence stages and then it, is taken to start from samples; on another sequence it
///   is written after the step that produces the sequence, or fluently.
/// - Each frame is followed by zeros up to a fast length at or above `window + maxLag` before
///   it is transformed (the Wiener–Khinchin relation), so the result is the linear
///   autocorrelation and not the circular one (§6.12). The frame is not tapered and its mean
///   is not removed. A lag at or past the window has no product and reads 0.
/// - `normalization` is that of `DSP.autocorrelate`; `.coefficient` divides by the value at
///   lag 0, and a frame whose value at lag 0 does not exceed `floor` is zeros (NUM-1).
/// - Every lag is right to the floor of a single-precision transform under the value at lag
///   0, about 10⁻⁷ of it, not of itself: a lag that should read 0 reads that much, with
///   either sign, and a coefficient can exceed 1 by as much (§7.5, row 11).
/// - Downstream the frames are `Lags`, the axis is lags in seconds, and `frameSize`,
///   `hopSize` and `featureRate` are those of this step (ENV-1). A frame's time is the time of
///   the newest value of its window; no latency is added.
/// - On a signal of several channels, `channels` says what is correlated (MIC-6).
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on any
/// thread; `lower(_:)` runs on the control context.
public struct Autocorrelation: ContextDependentStep {
    /// Values per frame.
    public let window: Int
    /// Values between the starts of two frames.
    public let hop: Int
    /// The last lag of a frame; `nil` for `window − 1`, the last lag that has a product.
    public let maxLag: Int?
    public let normalization: CorrelationNormalization
    /// The least value at lag 0 that `.coefficient` divides by.
    public let floor: Double
    public let channels: ChannelPolicy
    let backendBox: AnyStrategy
    public let activation: StageActivation

    public init(
        window: Int = 2_048, hop: Int = 512, maxLag: Int? = nil, normalization: CorrelationNormalization = .none,
        floor: Double = DSP.correlationFloor, channels: ChannelPolicy = .mixdown, backend: some FFTBackend = .vDSP,
        isActive: some ActivationSource = .active
    ) {
        self.window = window
        self.hop = hop
        self.maxLag = maxLag
        self.normalization = normalization
        self.floor = floor
        self.channels = channels
        self.backendBox = AnyStrategy(backend)
        self.activation = isActive.stageActivation
    }

    /// The transform backend the step was declared with.
    public var backend: any FFTBackend { backendBox.value(as: (any FFTBackend).self) ?? VDSPFFTBackend() }

    /// From any sampled sequence to lags.
    public static let rule = DomainRule("Autocorrelation: a sampled sequence to lags") { $0.isSampledSequence ? .lags : nil }

    public var stageDescription: StageDescription { StageDescription(self, rule: Autocorrelation.rule) }

    /// The longest window and the last lag the step takes.
    static let longest = 1 << 24

    /// Everything that determines the node, and nothing else (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let window: Int
        let hop: Int
        let lagCount: Int
        let normalization: CorrelationNormalization
        let floor: Float
        let channel: Int?
        let backend: AnyStrategy
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "an autocorrelation needs the rate of the sequence it frames, and there is none here") }
        let window = try StageValidation.value(window, named: "window", in: 1 ... Autocorrelation.longest, context: context)
        let hop = try StageValidation.hop(hop, frame: window, named: "hop", in: context)
        let last = try StageValidation.value(maxLag ?? window - 1, named: "maxLag", in: 0 ... Autocorrelation.longest, context: context)
        guard floor >= 0, floor.isFinite else { throw context.invalid("floor", "the floor of a denominator is finite and not negative, not \(floor)") }
        let backend = backend
        let length = WienerKhinchin.transformLength(frame: window, lagCount: last + 1)
        guard backend.supports(length: length) else {
            throw context.invalid("backend", "\(type(of: backend)) does not transform frames of \(length) points")
        }
        let channel = try ChannelSelection.resolve(channels, in: context)
        let key = Key(window: window, hop: hop, lagCount: last + 1, normalization: normalization, floor: Float(floor), channel: channel, backend: backendBox)
        let normalization = normalization
        let channelCount = max(context.environment.channelCount, 1), blockFrames = context.maximumBlockFrames
        context.emit(.analysis(AnalysisStep(
            name: "Autocorrelation", key: key, output: .real(count: last + 1),
            scope: .spectral(frameSize: window, hopSize: hop, axis: .lags(count: last + 1, sampleRate: rate))
        ) { () throws(DSPError) -> any AnalysisNode in
            try AutocorrelationNode(
                window: window, hop: hop, lagCount: last + 1, normalization: normalization, floor: key.floor,
                transform: WienerKhinchin(frame: window, lagCount: last + 1, backend: backend),
                mixer: ChannelMixer(channel: channel, channelCount: channelCount, maximumFrames: blockFrames), sampleRate: rate)
        }))
    }
}

// MARK: The typing rules (tier 1)

extension PipelineBuilder {
    public static func buildPartialBlock<I, M: SampledSequence>(accumulated: Pipeline<I, M>, next: Autocorrelation) -> Pipeline<I, Lags> {
        accumulated.appending(next.stageDescription)
    }

    /// Sequence stages and then an autocorrelation: like a block of sequence stages alone, the
    /// block is taken to start from samples.
    public static func buildPartialBlock(accumulated: SequenceChain, next: Autocorrelation) -> Pipeline<Samples, Lags> {
        Pipeline(unchecked: accumulated.stages + [next.stageDescription])
    }

    /// A block that begins with an autocorrelation is taken to start from samples.
    public static func buildPartialBlock(first: Autocorrelation) -> Pipeline<Samples, Lags> {
        Pipeline(unchecked: [first.stageDescription])
    }
}

extension Pipeline where Output: SampledSequence {
    /// The autocorrelation of the sequence, frame by frame: see ``Autocorrelation``.
    public func autocorrelation(
        window: Int = 2_048, hop: Int = 512, maxLag: Int? = nil, normalization: CorrelationNormalization = .none,
        floor: Double = DSP.correlationFloor, channels: ChannelPolicy = .mixdown, backend: some FFTBackend = .vDSP,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Lags> {
        appending(Autocorrelation(window: window, hop: hop, maxLag: maxLag, normalization: normalization, floor: floor, channels: channels,
                                  backend: backend, isActive: isActive).stageDescription)
    }
}
