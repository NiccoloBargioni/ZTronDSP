import Foundation
import ZTronDSPCore

/// What a `Level` measures.
///
/// A value, usable on any thread; it does not allocate.
public enum LevelKind: Hashable, Sendable {
    /// The largest magnitude in the window, in dBFS.
    case peak
    /// The root mean square of the window, in dBFS: a full-scale sine reads −3.01 dB.
    case rms
}

/// The level of the signal in dBFS, peak or RMS, over its own window and hop (§6.2). Both are
/// given in seconds, so the values do not depend on the engine's block size: one value per
/// hop, each over the window that ends at it.
///
/// ```swift
/// Level(.rms)                              // transforming: the chain goes on with the level
/// Level(.rms, to: $level)                  // measuring: the samples pass on (OUT-1)
/// ```
///
/// The transforming spelling, `Level<Scalar>`, starts a scalar track at `1 / hop` values per
/// second; a value's time is the time of the newest sample of its window. Silence reads the
/// floor of the decibel conversions, −160 dB, with confidence 1: silence has a level. The
/// measuring spelling, `Level<Samples>`, equals `Tap { Level(…); Emit(to: binding) }`.
///
/// A multichannel signal is reduced by `channels`. Switched off, the transforming spelling
/// suspends the rest of its branch; the measuring one stops measuring and the samples pass
/// (ACT-3). An immutable value, usable on any thread; `lower(_:)` runs on the control context and
/// may allocate.
public struct Level<Output: SignalDomain>: PipelineStage {
    /// Audio samples.
    public typealias Input = Samples

    /// What is measured: the peak or the RMS.
    public let kind: LevelKind
    /// The window, in seconds.
    public let window: TimeInterval
    /// The time between two values, in seconds.
    public let hop: TimeInterval
    /// How a signal of several channels is reduced (MIC-6): the mixdown unless told otherwise.
    public let channels: ChannelPolicy
    /// The step's switch: off, the transforming spelling suspends the rest of its branch and the
    /// measuring one stops measuring (ACT-3).
    public let activation: StageActivation
    let measuring: StageDescription?

    /// The step itself, from samples to a scalar track; for the measuring spelling, the tap that
    /// measures (OUT-1).
    public var stageDescriptions: [StageDescription] {
        [measuring ?? StageDescription(self, rule: .fixed(.samples, .scalar))]
    }

    /// Checks the window and the hop against the sample rate at the step's position (positive,
    /// finite, a hop no longer than the window) and emits the node. The measuring spelling is
    /// lowered as its tap: called on it, this throws. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard measuring == nil else { throw context.structuralStage() }
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "a level needs a sample rate, and there is none here") }
        guard window > 0, window.isFinite else { throw context.invalid("window", "a window lasts a positive, finite time, not \(window) s") }
        guard hop > 0, hop.isFinite else { throw context.invalid("hop", "a hop lasts a positive, finite time, not \(hop) s") }
        let windowFrames = max(Int((window * rate).rounded()), 1), hopFrames = max(Int((hop * rate).rounded()), 1)
        guard windowFrames <= 1 << 28 else { throw context.invalid("window", "a window of \(window) s is \(windowFrames) samples here: too long to hold") }
        guard hopFrames <= windowFrames else {
            throw context.invalid("hop", "a hop of \(hop) s is longer than the window of \(window) s: samples between two windows would not be measured")
        }
        let channel = try ChannelSelection.resolve(channels, in: context)
        let key = LevelKey(kind: kind, window: windowFrames, hop: hopFrames, channel: channel)
        let kind = kind
        let bound = Vector.Bound(count: windowFrames, implementation: context.environment.implementation, crossovers: context.crossovers)
        let channelCount = max(context.environment.channelCount, 1), blockFrames = context.maximumBlockFrames
        context.emit(.analysis(AnalysisStep(
            name: "Level", key: key, output: .scalar, scope: .featureSequence(rate: rate / Double(hopFrames))
        ) { () throws(DSPError) -> any AnalysisNode in
            try LevelNode(kind: kind, window: windowFrames, hop: hopFrames, bound: bound,
                          mixer: ChannelMixer(channel: channel, channelCount: channelCount, maximumFrames: blockFrames), sampleRate: rate)
        }))
    }
}

struct LevelKey: Hashable, Sendable {
    let kind: LevelKind
    let window: Int
    let hop: Int
    let channel: Int?
}

extension Level where Output == Scalar {
    /// The transforming spelling: the chain goes on with the level, one value per hop. Usable on
    /// any thread; it does not allocate.
    public init(
        _ kind: LevelKind, window: TimeInterval = 0.050, hop: TimeInterval = 0.010, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) {
        self.kind = kind
        self.window = window
        self.hop = hop
        self.channels = channels
        self.activation = isActive.stageActivation
        self.measuring = nil
    }
}

extension Level where Output == Samples {
    /// The measuring spelling (OUT-1): the level goes to `binding`, a `Binding<Float>` or a
    /// `Binding<ScalarFrame>`, on the main thread and at the result rate; the samples pass on
    /// unchanged. Usable on any thread; it allocates the description of its measuring branch.
    public init(
        _ kind: LevelKind, window: TimeInterval = 0.050, hop: TimeInterval = 0.010, channels: ChannelPolicy = .mixdown,
        to binding: some ScalarResultTarget, isActive: some ActivationSource = .active
    ) {
        self.kind = kind
        self.window = window
        self.hop = hop
        self.channels = channels
        self.activation = isActive.stageActivation
        self.measuring = .measuring(Level<Scalar>(kind, window: window, hop: hop, channels: channels).stageDescriptions, to: binding, isActive: isActive)
    }
}

extension Pipeline where Output == Samples {
    /// The level of the signal, as a scalar track: see ``Level``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func level(
        _ kind: LevelKind, window: TimeInterval = 0.050, hop: TimeInterval = 0.010, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Scalar> {
        appending(Level<Scalar>(kind, window: window, hop: hop, channels: channels, isActive: isActive))
    }

    /// The level of the signal, delivered to a binding; the samples pass on: see ``Level``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func level(
        _ kind: LevelKind, window: TimeInterval = 0.050, hop: TimeInterval = 0.010, channels: ChannelPolicy = .mixdown,
        to binding: some ScalarResultTarget, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(Level<Samples>(kind, window: window, hop: hop, channels: channels, to: binding, isActive: isActive))
    }
}
