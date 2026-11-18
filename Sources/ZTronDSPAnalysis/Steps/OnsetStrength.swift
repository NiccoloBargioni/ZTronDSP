import Foundation
import ZTronDSPCore

/// The onset strength of a spectrum in decibels, one value per frame (§6.9): how much the
/// spectrum rose since `lag` frames ago, averaged over its bands,
///
///     o[t] = mean over bands f of max(0, S[f, t] − R[f, t − lag])
///
/// where `R` is `S` itself or, with `maxSize` above 1, `S` under a maximum filter of that
/// many bands along frequency, which keeps a partial that moves by less than the filter (a
/// vibrato) from counting as an onset. It is the spectral flux of a log spectrum (Böck &
/// Widmer 2013), by custom of a mel spectrum:
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels()
/// OnsetStrength()
/// Tempogram(.autocorrelation)
/// ```
///
/// - Values of `S` below `floor` are raised to it first. Without that, the fluctuation of the
///   noise floor from frame to frame counts as onsets: a difference of logarithms has no
///   lower limit of its own (§7.5, row 14). The default, −80 dB, is that far under a spectrum
///   whose full scale reads 0 dB.
/// - It follows a spectrum in decibels, on any axis (O-9). Downstream the signal is a novelty
///   curve: a sampled sequence at the feature rate, outside the spectral scope (§5.2), so a
///   filter after it means hertz of the curve.
/// - The first `lag` frames after a start have nothing to be compared with: they read 0 with
///   confidence 0. Every other value has confidence 1. A value's time is its frame's time; no
///   latency is added.
/// - The maximum filter is centred, `maxSize / 2` bands below a band to `(maxSize − 1) / 2`
///   above it (rounded down), with the edges reflected.
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on any
/// thread; `lower(_:)` runs on the control context.
public struct OnsetStrength: ContextDependentStep {
    /// Frames between a spectrum and the one it is compared with.
    public let lag: Int
    /// Bands of the maximum filter along frequency; 1 for none.
    public let maxSize: Int
    /// What the values of the spectrum are raised to, in decibels.
    public let floor: Double
    public let activation: StageActivation

    public init(lag: Int = 1, maxSize: Int = 1, floor: Double = -80, isActive: some ActivationSource = .active) {
        self.lag = lag
        self.maxSize = maxSize
        self.floor = floor
        self.activation = isActive.stageActivation
    }

    /// From a spectrum in decibels, on any axis, to a novelty curve.
    public static let rule = DomainRule.spectral("OnsetStrength: a spectrum in decibels to a novelty curve") { _, values in
        values == .decibel ? .novelty : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: OnsetStrength.rule) }

    /// The longest lag the step keeps frames for.
    static let longestLag = 1 << 12

    /// Everything that determines the node, and nothing else (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let bands: Int
        let lag: Int
        let maxSize: Int
        let floor: Float
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        guard let bands = environment.frequencyAxis?.rowCount, bands >= 1, let featureRate = environment.featureRate, featureRate > 0 else {
            throw DSPError.unsupportedConfiguration(
                reason: "OnsetStrength needs the frames of a spectral scope: there is no frequency axis and no feature rate at this position", stage: context.path)
        }
        let lag = try StageValidation.value(lag, named: "lag", in: 1 ... OnsetStrength.longestLag, context: context)
        guard maxSize >= 1, maxSize <= bands else {
            throw context.invalid("maxSize", "a maximum over \(maxSize) bands does not fit a spectrum of \(bands): it spans between 1 band, which is no filter, and all of them")
        }
        let floor = Float(try StageValidation.finite(floor, named: "floor", in: context))
        let maxSize = maxSize
        context.emit(.analysis(AnalysisStep(
            name: "OnsetStrength", key: Key(bands: bands, lag: lag, maxSize: maxSize, floor: floor), output: .scalar,
            scope: .featureSequence(rate: featureRate)
        ) { () throws(DSPError) -> any AnalysisNode in
            try OnsetStrengthNode(bands: bands, lag: lag, maxSize: maxSize, floor: floor)
        }))
    }
}

// MARK: The typing rule (tier 1)

extension PipelineBuilder {
    public static func buildPartialBlock<I, Axis>(
        accumulated: Pipeline<I, Spectrum<Axis, DecibelValues>>, next: OnsetStrength
    ) -> Pipeline<I, Novelty> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The onset strength of the spectrum in decibels, as a novelty curve: see ``OnsetStrength``.
    public func onsetStrength<Axis>(
        lag: Int = 1, maxSize: Int = 1, floor: Double = -80, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Novelty> where Output == Spectrum<Axis, DecibelValues> {
        appending(OnsetStrength(lag: lag, maxSize: maxSize, floor: floor, isActive: isActive).stageDescription)
    }
}
