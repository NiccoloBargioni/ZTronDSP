import Foundation
import ZTronDSP

// The extension guide, row 4 of §5.11.1: a context-dependent family (Docs/ExtensionGuide.md).

// snippet:begin normalize-step
/// Scales every frame of magnitudes or powers so that its largest value is 1, on whatever
/// axis the frame has. A frame whose largest value is at or below `floor` becomes zeros.
///
/// The step is a family (ORD-1): what it produces depends on what it follows, so it names no
/// `Input` and no `Output`. Its typing rule is written once below as a builder overload, once
/// as a fluent method, and once as the `DomainRule` its description carries. An immutable
/// value, usable on any thread. `lower(_:)` runs on the control context.
public struct PeakNormalize: ContextDependentStep {
    /// A frame that peaks at or below this is silence. Usable on any thread.
    public let floor: Float
    /// The step's switch (§5.9). The step keeps the domain, so switched off the frames pass
    /// as they are (ACT-3).
    public let activation: StageActivation

    public init(floor: Float = 1e-12, isActive: some ActivationSource = .active) {
        self.floor = floor
        self.activation = isActive.stageActivation
    }

    /// The rule the plan compiler checks when a pipeline is attached (§5.8.2, tier 2):
    /// magnitudes or powers on any axis, kept. A rule of one's own has a name of its own.
    public static let rule = DomainRule.spectral("PeakNormalize: magnitudes or powers, kept") { axis, values in
        values == .magnitude || values == .power ? .spectrum(axis: axis, values: values) : nil
    }

    /// The step as a pipeline holds it, with its rule. Usable on any thread.
    public var stageDescription: StageDescription { StageDescription(self, rule: PeakNormalize.rule) }

    /// Emits the node. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(reason: "PeakNormalize needs the frames of a spectral scope, and there is none at this position", stage: context.path)
        }
        let floor = try StageValidation.finite(self.floor, named: "floor", in: context)
        context.emit(.analysis(AnalysisStep(name: "PeakNormalize", key: self.floor, output: .real(count: bins)) {
            () throws(DSPError) -> any AnalysisNode in
            PeakNormalizeNode(floor: floor)
        }))
    }
}
// snippet:end normalize-step

// snippet:begin normalize-family
extension PipelineBuilder {
    /// The family's compile-time rule (§5.8.2, tier 1): the step follows magnitudes or powers
    /// on any axis and keeps the domain.
    public static func buildPartialBlock<I, Axis, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<Axis, Values>>, next: PeakNormalize
    ) -> Pipeline<I, Spectrum<Axis, Values>> {
        accumulated.appending(next.stageDescription)
    }

    /// Catches the step after a domain it does not take, with a sentence that names it and says what it needs (ORD-4).
    @available(*, unavailable, message: "PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: PeakNormalize) -> Pipeline<I, O> { accumulated }

    /// Catches the step after sequence stages alone: there are no bins yet.
    @available(*, unavailable, message: "PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: PeakNormalize) -> SequenceChain { accumulated }
}

extension Pipeline {
    /// The family's fluent spelling, constrained on the output domain. Usable on any thread.
    public func peakNormalized<Axis, Values: LinearValued>(
        floor: Float = 1e-12, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<Axis, Values>> where Output == Spectrum<Axis, Values> {
        appending(PeakNormalize(floor: floor, isActive: isActive).stageDescription)
    }
}
// snippet:end normalize-family

/// What runs a `PeakNormalize`: one frame in, the same frame scaled out.
///
/// Threading: created on the control context. `process` and `reset` belong to the analysis
/// thread and allocate nothing, take no lock and log nothing (RT-2). One thread at a time.
final class PeakNormalizeNode: AnalysisNode {
    private let floor: Float

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(floor: Float) {
        self.floor = floor
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        let target = output.real
        guard let frame = input.real, let values = frame.values.baseAddress, let result = target.baseAddress else { return }
        let count = min(frame.count, target.count)
        // The toolkit's reductions and element-wise operations, each bound to the fastest
        // implementation for its length (§5.11.4).
        let peak = Vector.maximum(values, count: count)
        if peak > floor {
            Vector.scale(values, by: 1 / peak, into: result, count: count)
        } else {
            // Silence stays silence: no division by a floor, no NaN (NUM-1).
            var index = 0
            while index < count {
                result[index] = 0
                index &+= 1
            }
        }
        output.emit(count: count)
    }

    func reset() {}
}
