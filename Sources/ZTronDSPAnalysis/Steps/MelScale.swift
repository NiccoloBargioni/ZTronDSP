import Foundation
import ZTronDSPCore

/// The mel-scale conversion as a processing step (§6.11, IN-11): magnitudes or powers on a
/// linear-frequency axis in, the same kind of value on a mel axis of `bands` bands out.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Power()
/// MelScale(bands: 128)
/// Decibels()
/// ```
///
/// - `bands + 2` edges are spaced equally on the mel scale across `range`, which defaults to
///   0 Hz … the Nyquist frequency at the step's position. Band `m` is a triangle from edge `m`
///   over edge `m + 1` to edge `m + 2`, evaluated at the bin centres.
/// - `formula` is `.slaney` (the default) or `.htk`; `normalization` is `.slaney` (unit area
///   per band, the default) or `.none` (unit peak).
/// - It follows magnitudes or powers on a linear-frequency axis: a mel band sums energy, and
///   decibels do not add; a complex spectrum has to become real first; an axis that is
///   already mel cannot be converted again (O-5). Decibels come after it.
/// - When the pipeline is attached, a range that leaves 0 Hz … Nyquist, and a band that
///   covers no bin, are errors (O-18); the latter names the band and the transform length
///   that would fill it.
/// - Downstream, the environment and the feeds describe a mel axis by the band centres in
///   hertz, so a view labels the rows without knowing how they were produced.
///
/// Converting to the mel scale is not the same as displaying a linear spectrogram on a mel axis,
/// which moves pixels and changes no data. Going back from mel bands to linear bins is lossy and is
/// not offered (D-10). Switched off, the step suspends the rest of its branch (ACT-3). An immutable
/// value, usable on any thread. Its formula and its normalisation are kept boxed (`AnyStrategy`):
/// creating one, and reading `formula` or `normalization`, allocate only for one larger than three
/// words, which no stock one is. `lower(_:)` runs on the control context and may allocate.
public struct MelScale: ContextDependentStep {
    /// Bands of the mel axis produced.
    public let bands: Int
    /// The band the mel bands span; `nil` for 0 Hz to the Nyquist frequency.
    public let range: FrequencyRange?
    let formulaBox: AnyStrategy
    let normalizationBox: AnyStrategy
    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// `bands` mel bands across `range` under `formula` and `normalization`. Nothing is checked
    /// here: `lower(_:)` checks the range and the bands against the spectra at the step's
    /// position when the plan is compiled (O-18).
    public init(
        bands: Int, range: FrequencyRange? = nil, formula: some MelFormula = .slaney, normalization: some MelNormalization = .slaney,
        isActive: some ActivationSource = .active
    ) {
        self.bands = bands
        self.range = range
        self.formulaBox = AnyStrategy(formula)
        self.normalizationBox = AnyStrategy(normalization)
        self.activation = isActive.stageActivation
    }

    /// The mel formula the step was declared with.
    public var formula: any MelFormula { formulaBox.value(as: (any MelFormula).self) ?? SlaneyMelFormula() }

    /// The band normalisation the step was declared with.
    public var normalization: any MelNormalization { normalizationBox.value(as: (any MelNormalization).self) ?? SlaneyMelNormalization() }

    /// From magnitudes or powers on a linear-frequency axis to the same values on a mel axis.
    public static let rule = DomainRule.spectral("MelScale: linear-frequency magnitudes or powers to a mel axis") { axis, values in
        axis == .linear && (values == .magnitude || values == .power) ? .spectrum(axis: .mel, values: values) : nil
    }

    /// The step with its typing rule, ``rule``.
    public var stageDescription: StageDescription { StageDescription(self, rule: MelScale.rule) }

    struct Key: Hashable, Sendable {
        let bank: MelFilterBank
        let isDense: Bool
    }

    /// The filter bank for a spectrum of `binCount` bins up to `nyquist`, checked (O-18).
    func bank(binCount: Int, nyquist: Double, sampleRate: Double) throws(DSPError) -> MelFilterBank {
        var hertz: ClosedRange<Double>?
        if let range {
            let resolved = try range.hertz(sampleRate: sampleRate)
            guard resolved.upperBound <= nyquist else {
                throw .invalidParameter(
                    stage: .none, parameter: "range",
                    reason: "\(range) ends at \(resolved.upperBound) Hz, above the Nyquist frequency of \(nyquist) Hz at this position")
            }
            hertz = resolved
        }
        func make<F: MelFormula, N: MelNormalization>(_ formula: F, _ normalization: N) throws(DSPError) -> MelFilterBank {
            try MelFilterBank(bands: bands, binCount: binCount, nyquist: nyquist, range: hertz, formula: formula, normalization: normalization)
        }
        let bank = try make(formula, normalization)
        if let empty = bank.firstEmptyBand {
            let length = 2 * (binCount - 1)
            let filling = MelFilterBank.smallestFillingLength(edges: bank.edges, sampleRate: 2 * nyquist, above: length)
            let advice = filling.map { "a transform of \($0) points is the smallest that fills every band" } ?? "no transform length up to 2²⁴ fills every band"
            throw .invalidParameter(
                stage: .none, parameter: "bands",
                reason: "band \(empty) of \(bands), from \(bank.edges[empty]) Hz to \(bank.edges[empty + 2]) Hz, covers no bin of a transform of \(length) points, whose bins are \(bank.binWidth) Hz apart; \(advice)")
        }
        return bank
    }

    /// Builds the filter bank for the spectra at the step's position, which checks the range and
    /// that every band covers a bin (O-18), and emits the banded or the dense projection,
    /// whichever the crossover chooses. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        guard case .linearFrequency(let bins, let nyquist)? = environment.frequencyAxis, bins >= 2, nyquist > 0 else {
            throw DSPError.unsupportedConfiguration(
                reason: "MelScale needs the frames of a spectral scope on a linear-frequency axis, and there is none at this position", stage: context.path)
        }
        let bank = try bank(binCount: bins, nyquist: nyquist, sampleRate: environment.sampleRate)
        // Banded dot products, or one dense product above the crossover (§7.4).
        let isDense = context.implementation(for: .melProjection, size: bank.bandCount * bins) == .accelerate
        let crossovers = context.crossovers, requested = environment.implementation
        context.emit(.analysis(AnalysisStep(
            name: "MelScale", key: Key(bank: bank, isDense: isDense), output: .real(count: bank.bandCount), scope: .axis(.mel(centers: bank.centers))
        ) { () throws(DSPError) -> any AnalysisNode in
            if isDense { return try DenseMelNode(bank) }
            return try BandedMelNode(bank, crossovers: crossovers, requested: requested)
        }))
    }
}

extension PipelineBuilder {
    /// `MelScale` follows magnitudes or powers on a linear-frequency axis and keeps the kind of
    /// value (O-5). Runs where the pipeline is described, on any thread, and allocates.
    public static func buildPartialBlock<I, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, Values>>, next: MelScale
    ) -> Pipeline<I, Spectrum<MelFrequency, Values>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The magnitudes or powers on a mel axis: see ``MelScale``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func melScale<Values: LinearValued>(
        bands: Int, range: FrequencyRange? = nil, formula: some MelFormula = .slaney, normalization: some MelNormalization = .slaney,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<MelFrequency, Values>> where Output == Spectrum<LinearFrequency, Values> {
        appending(MelScale(bands: bands, range: range, formula: formula, normalization: normalization, isActive: isActive).stageDescription)
    }
}
