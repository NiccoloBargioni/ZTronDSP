import Foundation
import ZTronDSPCore

/// Harmonic–percussive separation by median filtering (§6.10; Fitzgerald 2010, Driedger et
/// al. 2014): one component of a spectrum is kept, the domain stays what it was.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512)
/// HarmonicPercussive(select: .harmonic)        // on the complex spectrum: masked, the phase kept
/// InverseSTFT()                                // … and back to samples: what `HPSS` is
///
/// STFT(frame: 2_048, hop: 512); Magnitude()
/// HarmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 17)   // on magnitudes
/// ```
///
/// - `H` is the median of the magnitudes along time, over `timeKernel` frames; `P` is the
///   median along frequency, over `frequencyKernel` bins. Kernels are odd; 31 and 31 is the
///   default, 17 and 17 the low-latency setting. Edges are reflected, the edge value repeated.
/// - The masks are those of `mask`: `.soft(power: p)`, `M_H = Hᵖ / (Hᵖ + (m_H·P)ᵖ)` and
///   `M_P = Pᵖ / (Pᵖ + (m_P·H)ᵖ)`, or `.hard`, their limit. The margins `m_H`, `m_P` are at
///   least 1; above 1 they leave a residual, `1 − M_H − M_P`. A bin where neither median
///   reaches `floor` goes to neither side (NUM-1) and so to the residual; with a floor of 0
///   and a soft mask, a bin whose medians are both zero is shared equally instead.
/// - On a **complex spectrum** of an `STFT` the step multiplies each bin by the mask of the
///   component and keeps its phase; on **magnitudes**, on any axis, it gives the component's
///   magnitudes. Powers and decibels are neither (O-2).
/// - `alignment` says which frames the time median is taken over. `.causal`, the default: the
///   frames `t − timeKernel + 1 … t`. No latency; the harmonic part is biased towards the
///   past. `.centered`: `(timeKernel − 1) / 2` frames on either side of `t`, which is what an
///   offline separation computes; the frame is then known that many frames late, and that
///   look-ahead is the latency the step declares (REAL-5). A frame keeps the time of the
///   spectrum it describes.
/// - After a start the first frames are filtered over the frames there are, reflected
///   (ACT-10). Causal, a frame comes out for every frame that goes in. Centred, the first
///   frame is known once its look-ahead has arrived: on magnitudes nothing is written until
///   then; on a complex spectrum the step is a delay line of that many frames and begins as
///   one, with as many frames of silence, so that a resynthesis by `InverseSTFT` keeps its
///   place in the stream and its output begins with the whole latency as zeros, as the
///   output of a filter does. Frame the signal causally, the default of `STFT`, when a
///   centred separation is resynthesised: a centred framing has reflected the start of the
///   signal into its first frames, and behind the silence that reflection is resynthesised
///   too, ahead of the signal. A causal separation is best framed centred instead: its first
///   frame is then divided by whole window sums, not by the edge of one window. `HPSS` makes
///   both choices.
/// - `median` is `.selectionNetwork`, the CPU lanes. A live frame is never filtered on the GPU
///   (GPU-1): `.automatic` means the CPU here, and `.metal` is refused when the pipeline is
///   attached.
///
/// The step keeps the domain, so switched off it is bypassed (ACT-3): the spectrum passes
/// unchanged, as it arrives; a constant `false` leaves no trace of the step, its latency
/// included (ACT-4). Inside `HPSS` the recipe is bypassed as a whole, with its latency kept.
/// An immutable value, usable on any thread; `lower(_:)` runs on the control context.
public struct HarmonicPercussive: ContextDependentStep {
    /// The component that is kept.
    public let component: HarmonicPercussiveComponent
    /// Frames the median along time is taken over: odd.
    public let timeKernel: Int
    /// Bins the median along frequency is taken over: odd.
    public let frequencyKernel: Int
    /// How much the harmonic median has to exceed the percussive one by: at least 1.
    public let harmonicMargin: Double
    /// How much the percussive median has to exceed the harmonic one by: at least 1.
    public let percussiveMargin: Double
    /// The least median that counts as a value.
    public let floor: Double
    public let alignment: FrameAlignment
    let maskBox: AnyStrategy
    let medianBox: AnyStrategy
    public let activation: StageActivation

    public init(
        select component: HarmonicPercussiveComponent, timeKernel: Int = 31, frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2),
        harmonicMargin: Double = 1, percussiveMargin: Double = 1, alignment: FrameAlignment = .causal,
        median: some MedianStrategy = .selectionNetwork, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) {
        self.component = component
        self.timeKernel = timeKernel
        self.frequencyKernel = frequencyKernel
        self.harmonicMargin = harmonicMargin
        self.percussiveMargin = percussiveMargin
        self.floor = floor
        self.alignment = alignment
        self.maskBox = AnyStrategy(mask)
        self.medianBox = AnyStrategy(median)
        self.activation = isActive.stageActivation
    }

    /// The mask strategy the step was declared with.
    public var mask: any MaskStrategy { maskBox.value(as: (any MaskStrategy).self) ?? SoftMask() }

    /// The median strategy the step was declared with.
    public var median: any MedianStrategy { medianBox.value(as: (any MedianStrategy).self) ?? SelectionNetworkMedian() }

    /// From the complex linear-frequency spectrum, or from magnitudes on any axis, to the same.
    public static let rule = DomainRule.spectral("HarmonicPercussive: a complex linear-frequency spectrum, or magnitudes, kept") { axis, values in
        (values == .complex && axis == .linear) || values == .magnitude ? .spectrum(axis: axis, values: values) : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: HarmonicPercussive.rule) }

    /// Frames a centred median waits for after the one it describes.
    static func lookAhead(timeKernel: Int, alignment: FrameAlignment) -> Int {
        alignment == .centered ? (timeKernel - 1) / 2 : 0
    }

    /// The checks the step and the offline separation share: the kernels, the margins, the
    /// floor, the mask.
    static func check(timeKernel: Int, frequencyKernel: Int, harmonicMargin: Double, percussiveMargin: Double, floor: Double, mask: any MaskStrategy) throws(DSPError) {
        for (name, kernel) in [("timeKernel", timeKernel), ("frequencyKernel", frequencyKernel)] {
            guard kernel >= 1, kernel % 2 == 1, kernel <= MedianNetwork.maximumCount else {
                throw .invalidParameter(stage: .none, parameter: name, reason: "a median is taken over an odd number of values from 1 to \(MedianNetwork.maximumCount), not \(kernel)")
            }
        }
        for (name, margin) in [("harmonicMargin", harmonicMargin), ("percussiveMargin", percussiveMargin)] {
            guard margin >= 1, margin.isFinite else {
                throw .invalidParameter(stage: .none, parameter: name, reason: "a margin is a finite factor of at least 1, not \(margin): below 1 the two masks would claim more than the spectrum holds")
            }
        }
        guard floor >= 0, floor.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "floor", reason: "the floor of the medians is finite and not negative, not \(floor)")
        }
        try mask.validate()
    }

    /// Everything that determines the node, and nothing else (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let component: HarmonicPercussiveComponent
        let binCount: Int
        let isComplex: Bool
        let timeKernel: Int
        let frequencyKernel: Int
        let harmonicMargin: Float
        let percussiveMargin: Float
        let floor: Float
        let lookAhead: Int
        let mask: AnyStrategy
        let median: AnyStrategy
        let implementation: Implementation
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        guard let bins = environment.frequencyAxis?.rowCount, bins >= 1, let featureRate = environment.featureRate, featureRate > 0 else {
            throw DSPError.unsupportedConfiguration(
                reason: "HarmonicPercussive needs the frames of a spectral scope: there is no frequency axis and no feature rate at this position", stage: context.path)
        }
        let mask = mask, median = median
        try HarmonicPercussive.check(
            timeKernel: timeKernel, frequencyKernel: frequencyKernel, harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: floor,
            mask: mask)
        let isComplex: Bool
        if case .spectrum(_, .complex) = context.domain { isComplex = true } else { isComplex = false }
        let ahead = HarmonicPercussive.lookAhead(timeKernel: timeKernel, alignment: alignment)
        let requested = environment.implementation, crossovers = context.crossovers
        // Made once here, so that a strategy that cannot filter a live frame is refused when
        // the pipeline is attached and names this stage.
        _ = try median.makeFilter(kernel: timeKernel, binCount: bins, along: .time, implementation: requested, crossovers: crossovers)
        _ = try median.makeFilter(kernel: frequencyKernel, binCount: bins, along: .frequency, implementation: requested, crossovers: crossovers)

        let key = Key(
            component: component, binCount: bins, isComplex: isComplex, timeKernel: timeKernel, frequencyKernel: frequencyKernel,
            harmonicMargin: Float(harmonicMargin), percussiveMargin: Float(percussiveMargin), floor: Float(floor), lookAhead: ahead, mask: maskBox,
            median: medianBox, implementation: crossovers.implementation(for: .laneExchange, size: bins, requested: requested))
        let timeKernel = timeKernel, frequencyKernel = frequencyKernel
        context.emit(.analysis(AnalysisStep(
            name: "HarmonicPercussive", key: key, output: isComplex ? .complex(count: bins) : .real(count: bins),
            latency: Double(ahead) / featureRate
        ) { () throws(DSPError) -> any AnalysisNode in
            try HarmonicPercussiveNode(
                component: key.component, binCount: bins, isComplex: isComplex, lookAhead: ahead, settling: timeKernel - 1 - ahead,
                timeMedian: median.makeFilter(kernel: timeKernel, binCount: bins, along: .time, implementation: requested, crossovers: crossovers),
                frequencyMedian: median.makeFilter(kernel: frequencyKernel, binCount: bins, along: .frequency, implementation: requested, crossovers: crossovers),
                mask: mask, harmonicMargin: key.harmonicMargin, percussiveMargin: key.percussiveMargin, floor: key.floor, featureRate: featureRate)
        }))
    }
}

// MARK: The typing rules (tier 1)

extension PipelineBuilder {
    /// On the complex spectrum of an STFT: the mask applied, the phase kept.
    public static func buildPartialBlock<I>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, ComplexValues>>, next: HarmonicPercussive
    ) -> Pipeline<I, Spectrum<LinearFrequency, ComplexValues>> {
        accumulated.appending(next.stageDescription)
    }

    /// On magnitudes, on any axis: the component's magnitudes.
    public static func buildPartialBlock<I, Axis>(
        accumulated: Pipeline<I, Spectrum<Axis, MagnitudeValues>>, next: HarmonicPercussive
    ) -> Pipeline<I, Spectrum<Axis, MagnitudeValues>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// One component of the complex spectrum, its phase kept: see ``HarmonicPercussive``.
    public func harmonicPercussive(
        select component: HarmonicPercussiveComponent, timeKernel: Int = 31, frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2),
        harmonicMargin: Double = 1, percussiveMargin: Double = 1, alignment: FrameAlignment = .causal,
        median: some MedianStrategy = .selectionNetwork, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> where Output == Spectrum<LinearFrequency, ComplexValues> {
        appending(HarmonicPercussive(
            select: component, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask, harmonicMargin: harmonicMargin,
            percussiveMargin: percussiveMargin, alignment: alignment, median: median, floor: floor, isActive: isActive).stageDescription)
    }

    /// One component of the magnitudes: see ``HarmonicPercussive``.
    public func harmonicPercussive<Axis>(
        select component: HarmonicPercussiveComponent, timeKernel: Int = 31, frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2),
        harmonicMargin: Double = 1, percussiveMargin: Double = 1, alignment: FrameAlignment = .causal,
        median: some MedianStrategy = .selectionNetwork, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> where Output == Spectrum<Axis, MagnitudeValues> {
        appending(HarmonicPercussive(
            select: component, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask, harmonicMargin: harmonicMargin,
            percussiveMargin: percussiveMargin, alignment: alignment, median: median, floor: floor, isActive: isActive).stageDescription)
    }
}
