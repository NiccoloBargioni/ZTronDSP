import Foundation
import ZTronDSP

// The extension guide, row 9 of §5.11.1: an inverse with its report (Docs/ExtensionGuide.md).

// snippet:begin emphasis-stages
/// Pre-emphasis, y[n] = x[n] − a·x[n − 1]: lifts the high end before an analysis.
///
/// The stage lowers to a stock kernel spec, one section of the stock cascade, so it is fused
/// and switched like a stock filter and takes a changed coefficient in place (EXT-2). An
/// immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct PreEmphasis: SequenceStage {
    /// The `a` of the difference equation. Usable on any thread.
    public let coefficient: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(coefficient: Double = 0.97, isActive: some ActivationSource = .active) {
        self.coefficient = coefficient
        self.activation = isActive.stageActivation
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let a = try StageValidation.finite(coefficient, named: "coefficient", in: context)
        let precision: BiquadPrecision = context.environment.biquadPrecision == .double ? .double : .single
        context.emit(.biquad(sections: [BiquadSection(b0: 1, b1: -a, b2: 0, a1: 0, a2: 0)], precision: precision))
    }
}

/// De-emphasis, y[n] = x[n] + a·y[n − 1]: what undoes `PreEmphasis` with the same coefficient.
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct DeEmphasis: SequenceStage {
    /// The `a` of the difference equation. Usable on any thread.
    public let coefficient: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(coefficient: Double = 0.97, isActive: some ActivationSource = .active) {
        self.coefficient = coefficient
        self.activation = isActive.stageActivation
    }

    /// - Throws: `DSPError.unstableDesign` for a coefficient whose magnitude is not below 1:
    ///   the pole would sit on or outside the unit circle (REAL-2).
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let a = try StageValidation.finite(coefficient, named: "coefficient", in: context)
        guard abs(a) < 1 else { throw DSPError.unstableDesign(maxPoleRadius: abs(a)) }
        let precision: BiquadPrecision = context.environment.biquadPrecision == .double ? .double : .single
        context.emit(.biquad(sections: [BiquadSection(b0: 1, b1: 0, b2: 0, a1: -a, a2: 0)], precision: precision))
    }
}
// snippet:end emphasis-stages

// snippet:begin emphasis-inverse
extension PreEmphasis: InvertibleStage {
    /// The stage that undoes this one, with the value it needs to match it.
    public var inverse: DeEmphasis { DeEmphasis(coefficient: coefficient) }

    /// The one condition: the inverse has its pole at `a`, and is stable while that lies inside
    /// the unit circle. A failed condition is reported, not thrown (INV-3). Background work.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        let radius = abs(coefficient)
        let holds = radius < 1
        return [InversionCondition(
            name: "a stable inverse",
            theorem: "1 − a·z⁻¹ is undone by 1 / (1 − a·z⁻¹), which is stable when its pole lies inside the unit circle: |a| < 1",
            quantity: "|a|", observed: radius, holds: holds, margin: 1 - radius,
            // What the inverse does to the round-off of single-precision samples: it amplifies
            // it by up to 1 / (1 − |a|). Without a stable inverse everything is lost.
            predictedError: holds ? Double(Float.ulpOfOne) / (1 - radius) : 1)]
    }

    /// The stage and then its inverse on the signal of the report; `nil` without a signal, and
    /// where there is no stable inverse to run. Background work.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil, abs(coefficient) < 1 else { return nil }
        let original = try context.samples()
        try context.check()
        let reconstruction = try context.samples(after: stageDescriptions + inverse.stageDescriptions)
        return InversionRoundTrip(original: original, reconstruction: reconstruction)
    }
}
// snippet:end emphasis-inverse

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a pre-emphasis: see ``PreEmphasis``. Usable on any thread.
    public func preEmphasis(coefficient: Double = 0.97, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(PreEmphasis(coefficient: coefficient, isActive: isActive))
    }

    /// The pipeline followed by a de-emphasis: see ``DeEmphasis``. Usable on any thread.
    public func deEmphasis(coefficient: Double = 0.97, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(DeEmphasis(coefficient: coefficient, isActive: isActive))
    }
}
