internal import CExternalKernels
import Foundation
import ZTronDSP

/// An IIR low-pass filter: the stock `LowPass(_:cutoff:order:)` re-implemented outside
/// ZTronDSP, on a C kernel of its own (specification §5.11.1, EXT-4).
///
/// ```swift
/// ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
/// ```
///
/// The filter is designed with the public design API, for the sample rate at the stage's
/// position: the family's prototype, the low-pass transformation, the bilinear transform,
/// the section pairing, and the gain spread over the sections. It runs as second-order
/// sections on `extk_biquad_create`, in the precision the environment's `biquadPrecision` asks
/// for; `.automatic` takes what `SecondOrderSections.recommendedPrecision()` measures. In
/// single precision the kernel is bound, when the plan is compiled, to vDSP or to a C loop by
/// the size of the blocks at the stage's position (SEL-3).
///
/// The stage runs on any sampled sequence and keeps its domain. A cutoff at or beyond the
/// Nyquist frequency at its position is rejected when the plan is compiled, with the stage's
/// path (ENV-2, O-16). It adds no latency; its settling time is the time its slowest pole
/// takes to decay by 100 dB, which is how long a plan pre-rolls it before it is heard
/// (ACT-7, SWAP-2). The cutoff is the stage's continuous value (ANI-2).
///
/// What it does not have that the stock stage has: the engine sends no value to a kernel of
/// the caller's own, so a changed cutoff is a new kernel, pre-rolled and faded in (SWAP-2),
/// where the stock filter takes new coefficients in place and keeps its memory; and a kernel
/// of the caller's own is a fusion barrier (EXT-2).
///
/// An immutable value, usable on any thread. Designing happens in `design(sampleRate:)` and in
/// `lower(_:)`: control or background context.
public struct ExternalLowPass: SequenceStage {
    /// What tells one cascade from another: its coefficients, its precision, and whether it runs
    /// on vDSP or in a C loop.
    struct Key: Hashable, Sendable {
        let coefficients: [Double]
        let isDouble: Bool
        let isAccelerated: Bool
    }

    /// The `FilterFamily`, boxed for comparison.
    let familyBox: AnyStrategy
    /// The edge of the family's prototype: the −3 dB point of a Butterworth filter. Usable on
    /// any thread.
    public let cutoff: Frequency
    /// The order of the filter: it has that many poles. Usable on any thread.
    public let order: Int
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(familyBox: AnyStrategy, cutoff: Frequency, order: Int, activation: StageActivation) {
        self.familyBox = familyBox
        self.cutoff = cutoff
        self.order = order
        self.activation = activation
    }

    /// An IIR low-pass of the given family and order. Usable on any thread.
    ///
    /// - Parameters:
    ///   - family: `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`,
    ///     `.elliptic(ripple:stopband:)`, `.bessel(normalization:)`, or a family of your own.
    ///   - cutoff: The edge of the family's prototype.
    ///   - order: The order of the filter.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active) {
        self.init(familyBox: AnyStrategy(family), cutoff: cutoff, order: order, activation: isActive.stageActivation)
    }

    /// The cutoff as its `animatableValue` (ANI-2). Usable on any thread.
    public var parameters: [Double] { [cutoff.animatableValue] }

    /// The stage with its cutoff replaced. Passing its own value returns it unchanged. Usable
    /// on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> ExternalLowPass {
        guard values.count == 1, let value = values.first else { return self }
        return ExternalLowPass(familyBox: familyBox, cutoff: cutoff.replacing(animatableValue: value), order: order, activation: activation)
    }

    /// The design the stage's arguments name, at `sampleRate`. Control or background context;
    /// allocates.
    ///
    /// - Throws: what the design throws for values that make no filter at this rate.
    public func design(sampleRate: Double) throws(DSPError) -> IIRDesign {
        try ExternalLowPass.design(try family(), cutoff: try cutoff.hertz(sampleRate: sampleRate), order: order, sampleRate: sampleRate)
    }

    private func family() throws(DSPError) -> any FilterFamily {
        guard let family = familyBox.value(as: (any FilterFamily).self) else {
            throw .invalidParameter(stage: .none, parameter: "family", reason: "the stage has no filter family")
        }
        return family
    }

    private static func design(_ family: some FilterFamily, cutoff: Double, order: Int, sampleRate: Double) throws(DSPError) -> IIRDesign {
        try IIRDesign(family, .lowPass(cutoff: cutoff), order: order, domain: .digital(sampleRate: sampleRate))
    }

    /// Designs the filter for the environment at the stage's position and emits its kernel.
    /// Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a cutoff that is not between 0 Hz and the
    ///   Nyquist frequency here, an order the family does not design, or a coefficient that
    ///   single precision cannot hold; `DSPError.unstableDesign` for a pole on or outside the
    ///   unit circle (REAL-2).
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let hertz = try StageValidation.frequency(cutoff, named: "cutoff", in: context)
        let design = try ExternalLowPass.design(try family(), cutoff: hertz, order: order, sampleRate: context.environment.sampleRate)
        let sections = try design.secondOrderSections
        guard !sections.sections.isEmpty else { return }
        let margin = sections.stabilityMargin
        guard margin > 0 else { throw DSPError.unstableDesign(maxPoleRadius: 1 - margin) }
        // The gain is spread over the sections, so that each works at the level of the signal
        // and RT-6 clears nothing that carries it.
        let realised = sections.spreadingGain()
        let coefficients = realised.coefficients
        guard coefficients.allSatisfy(\.isFinite) else {
            throw context.invalid("sections", "a coefficient of the cascade is not a finite number")
        }
        let isDouble: Bool
        switch context.environment.biquadPrecision {
        case .single: isDouble = false
        case .double: isDouble = true
        case .automatic: isDouble = try sections.recommendedPrecision() == .double
        }
        if !isDouble {
            guard coefficients.allSatisfy({ Float($0).isFinite }) else {
                throw context.invalid("sections", "a coefficient of the cascade exceeds single precision; run it in double precision: .environment(\\.biquadPrecision, .double), or leave the choice to .automatic")
            }
        }
        let count = realised.sections.count
        // vDSP, or the C loop where a block holds only a few frames: bound here, once (SEL-3).
        let isAccelerated = context.implementation(for: .biquadKernel, size: context.maximumBlockFrames) == .accelerate
        let key = Key(coefficients: coefficients, isDouble: isDouble, isAccelerated: isAccelerated)
        context.emit(.custom(CustomKernel(name: "ExternalLowPass", key: key, latencyFrames: 0) { channels, _, _ in
            extk_biquad_create(UInt32(max(channels, 0)), UInt32(count), coefficients, isDouble,
                               isAccelerated ? ZTD_IMPLEMENTATION_ACCELERATE : ZTD_IMPLEMENTATION_NATIVE)
        }))
    }
}

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by an IIR low-pass on the suite's own C kernel. See
    /// ``ExternalLowPass``. Usable on any thread.
    public func externalLowPass(
        _ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(ExternalLowPass(family, cutoff: cutoff, order: order, isActive: isActive))
    }
}

extension PipelineBuilder {
    /// Catches the filter after a domain it does not run on, with a sentence that names it
    /// (ORD-4). Without this overload the stage gets the sentence the core has for every
    /// sequence stage, which names the kind and not the stage.
    @available(*, unavailable, message: "ExternalLowPass runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins: put it before the transform.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ExternalLowPass) -> Pipeline<I, O> { accumulated }
}
