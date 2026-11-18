import Foundation
import ZTronDSPCore

/// Marks the measuring spelling of `SpectralCentroid`: the spectrum it measures passes on
/// (OUT-1).
public enum MeasuredSpectrum {}

/// The spectral centroid, `C = Σ fₖ·mₖ / Σ mₖ` over the bins of a linear-frequency axis inside
/// an optional range, with `m` the magnitudes or the powers it follows (§6.5).
///
/// ```swift
/// STFT(frame: 1_024, hop: 256); Magnitude()
/// SpectralCentroid()                           // transforming: the chain goes on with the centroid
/// SpectralCentroid(to: $centroid)              // measuring: the spectrum passes on (OUT-1)
/// ```
///
/// It follows magnitudes or powers on a linear-frequency axis only: the weights must be
/// non-negative energies on evenly spaced bins, so decibels will not do, and over mel or
/// constant-Q bands the same formula is not the centroid (O-8).
///
/// The transforming spelling starts a scalar track at the feature rate. A frame whose weights
/// sum to less than `floor` has no centroid: it repeats the last value, or 0 before the first,
/// with confidence 0; no NaN is ever written (NUM-1). The measuring spelling equals
/// `Tap { SpectralCentroid(…); Emit(to: binding) }`, written fluently where it begins a branch.
///
/// Switched off, the transforming spelling suspends the rest of its branch; the measuring one
/// stops measuring and the spectrum passes (ACT-3). An immutable value, usable on any thread.
public struct SpectralCentroid<Continuation>: ContextDependentStep {
    /// The band the centroid is taken over; `nil` for 0 Hz to the Nyquist frequency.
    public let range: FrequencyRange?
    /// The least sum of weights that is divided by.
    public let floor: Double
    public let activation: StageActivation
    let measuring: StageDescription?

    public var stageDescription: StageDescription {
        measuring ?? StageDescription(self, rule: SpectralCentroidRule.rule)
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard measuring == nil else { throw context.structuralStage() }
        let environment = context.environment
        guard case .linearFrequency(let bins, let nyquist)? = environment.frequencyAxis, bins >= 2, nyquist > 0, let featureRate = environment.featureRate
        else {
            throw DSPError.unsupportedConfiguration(
                reason: "SpectralCentroid needs the frames of a spectral scope on a linear-frequency axis, and there is none at this position", stage: context.path)
        }
        guard floor >= 0, floor.isFinite else { throw context.invalid("floor", "the floor of the weights is finite and not negative, not \(floor)") }
        let width = nyquist / Double(bins - 1)
        var low = 0.0, high = nyquist
        if let range {
            let hertz = try range.hertz(sampleRate: environment.sampleRate)
            guard hertz.upperBound <= nyquist else {
                throw context.invalid("range", "\(range) ends at \(hertz.upperBound) Hz, above the Nyquist frequency of \(nyquist) Hz at this position")
            }
            (low, high) = (hertz.lowerBound, hertz.upperBound)
        }
        let first = Int((low / width).rounded(.up)), last = min(Int((high / width).rounded(.down)), bins - 1)
        guard last >= first else {
            throw context.invalid("range", "no bin lies between \(low) Hz and \(high) Hz: the bins of this frame are \(width) Hz apart")
        }
        let count = last - first + 1
        let key = SpectralCentroidKey(firstBin: first, count: count, binWidth: width, floor: Float(floor))
        let bound = Vector.Bound(count: count, implementation: environment.implementation, crossovers: context.crossovers)
        context.emit(.analysis(AnalysisStep(
            name: "SpectralCentroid", key: key, output: .scalar, scope: .featureSequence(rate: featureRate)
        ) { () throws(DSPError) -> any AnalysisNode in
            try SpectralCentroidNode(firstBin: first, count: count, binWidth: width, floor: Float(key.floor), bound: bound)
        }))
    }
}

struct SpectralCentroidKey: Hashable, Sendable {
    let firstBin: Int
    let count: Int
    let binWidth: Double
    let floor: Float
}

/// The typing rule of the centroid, tier 2 (O-8).
enum SpectralCentroidRule {
    static let rule = DomainRule.spectral("SpectralCentroid: magnitudes or powers on a linear-frequency axis to a scalar") { axis, values in
        axis == .linear && (values == .magnitude || values == .power) ? .scalar : nil
    }
}

extension SpectralCentroid where Continuation == Scalar {
    /// The transforming spelling: the chain goes on with the centroid in hertz, one value per
    /// frame.
    public init(range: FrequencyRange? = nil, floor: Double = 1e-10, isActive: some ActivationSource = .active) {
        self.range = range
        self.floor = floor
        self.activation = isActive.stageActivation
        self.measuring = nil
    }

    /// From magnitudes or powers on a linear-frequency axis to a scalar.
    public static var rule: DomainRule { SpectralCentroidRule.rule }
}

extension SpectralCentroid where Continuation == MeasuredSpectrum {
    /// The measuring spelling (OUT-1): the centroid goes to `binding`, a `Binding<Float>` or a
    /// `Binding<ScalarFrame>`, on the main thread and at the result rate; the spectrum passes
    /// on unchanged.
    public init(range: FrequencyRange? = nil, floor: Double = 1e-10, to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) {
        self.range = range
        self.floor = floor
        self.activation = isActive.stageActivation
        self.measuring = .measuring([SpectralCentroid<Scalar>(range: range, floor: floor).stageDescription], to: binding, isActive: isActive)
    }
}

extension PipelineBuilder {
    public static func buildPartialBlock<I, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, Values>>, next: SpectralCentroid<Scalar>
    ) -> Pipeline<I, Scalar> {
        accumulated.appending(next.stageDescription)
    }

    public static func buildPartialBlock<I, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, Values>>, next: SpectralCentroid<MeasuredSpectrum>
    ) -> Pipeline<I, Spectrum<LinearFrequency, Values>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The spectral centroid, as a scalar track: see ``SpectralCentroid``.
    public func spectralCentroid<Values: LinearValued>(
        range: FrequencyRange? = nil, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Scalar> where Output == Spectrum<LinearFrequency, Values> {
        appending(SpectralCentroid<Scalar>(range: range, floor: floor, isActive: isActive).stageDescription)
    }

    /// The spectral centroid, delivered to a binding; the spectrum passes on: see
    /// ``SpectralCentroid``.
    public func spectralCentroid<Values: LinearValued>(
        range: FrequencyRange? = nil, floor: Double = 1e-10, to binding: some ScalarResultTarget, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> where Output == Spectrum<LinearFrequency, Values> {
        appending(SpectralCentroid<MeasuredSpectrum>(range: range, floor: floor, to: binding, isActive: isActive).stageDescription)
    }
}
