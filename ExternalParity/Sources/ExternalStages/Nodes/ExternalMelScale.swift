import Accelerate
import Foundation
import ZTronDSP

/// The mel-scale conversion as a processing step: the stock `MelScale` re-implemented outside
/// ZTronDSP, as a step family with a node of its own (specification §5.11.1, §6.11, EXT-4).
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Power()
/// ExternalMelScale(bands: 128)
/// Decibels()
/// ```
///
/// Magnitudes or powers on a linear-frequency axis in, the same kind of value on a mel axis of
/// `bands` bands out. The weights are those of the public `MelFilterBank`: `bands + 2` edges
/// equally spaced on the mel scale across `range` (0 Hz … the Nyquist frequency at the step's
/// position unless stated), one triangle per band, evaluated at the bin centres. The node
/// applies them with one dot product per band from the toolkit, each bound to the
/// implementation its length calls for, or with one dense product above the crossover (§7.4).
///
/// The step is a family (ORD-1): its typing rule is written once as a builder overload, once
/// as a fluent method and once as a `DomainRule`, and a wrong order fails to compile with a
/// sentence that names the step (ORD-4). When the pipeline is attached, a range that leaves
/// 0 Hz … Nyquist and a band that covers no bin are errors (O-18). Downstream, the environment
/// and the feeds describe a mel axis by the band centres in hertz. Switched off, the step
/// suspends the rest of its branch (ACT-3). It adds no latency and has nothing to settle.
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct ExternalMelScale: ContextDependentStep {
    /// How many mel bands. Usable on any thread.
    public let bands: Int
    /// The band the mel bands span; `nil` for 0 Hz to the Nyquist frequency. Usable on any
    /// thread.
    public let range: FrequencyRange?
    let formulaBox: AnyStrategy
    let normalizationBox: AnyStrategy
    /// The step's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// - Parameters:
    ///   - bands: how many mel bands, at least 1.
    ///   - range: the band they span; `nil` for 0 Hz to the Nyquist frequency.
    ///   - formula: `.slaney` (the default), `.htk`, or a formula of your own.
    ///   - normalization: `.slaney` (unit area per band, the default), `.none` (unit peak), or
    ///     one of your own.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    ///
    /// Usable on any thread.
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

    /// The mel formula the step was declared with. Usable on any thread.
    public var formula: any MelFormula { formulaBox.value(as: (any MelFormula).self) ?? SlaneyMelFormula() }

    /// The band normalisation the step was declared with. Usable on any thread.
    public var normalization: any MelNormalization { normalizationBox.value(as: (any MelNormalization).self) ?? SlaneyMelNormalization() }

    /// The family's rule for the plan compiler (§5.8.2, tier 2): from magnitudes or powers on a
    /// linear-frequency axis to the same values on a mel axis. Usable on any thread.
    public static let rule = DomainRule.spectral("ExternalMelScale: linear-frequency magnitudes or powers to a mel axis") { axis, values in
        axis == .linear && (values == .magnitude || values == .power) ? .spectrum(axis: .mel, values: values) : nil
    }

    /// The step as a pipeline holds it, with its rule. Usable on any thread.
    public var stageDescription: StageDescription { StageDescription(self, rule: ExternalMelScale.rule) }

    /// What tells one projection node from another: the weights it applies and how.
    struct Key: Hashable, Sendable {
        let bank: MelFilterBank
        let isDense: Bool
        let kinds: [Int32]
    }

    /// The filter bank for a spectrum of `binCount` bins up to `nyquist`, checked (O-18).
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a range that leaves 0 Hz … `nyquist` or is
    ///   empty, for a band count that holds nothing, and for a band that covers no bin; the
    ///   last names the band and the transform length that would fill it.
    public func bank(binCount: Int, nyquist: Double, sampleRate: Double) throws(DSPError) -> MelFilterBank {
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
        func make(_ formula: some MelFormula, _ normalization: some MelNormalization) throws(DSPError) -> MelFilterBank {
            try MelFilterBank(bands: bands, binCount: binCount, nyquist: nyquist, range: hertz, formula: formula, normalization: normalization)
        }
        let bank = try make(formula, normalization)
        if let empty = bank.firstEmptyBand {
            let length = 2 * (binCount - 1)
            let filling = ExternalMelScale.smallestFillingLength(edges: bank.edges, sampleRate: 2 * nyquist, above: length)
            let advice = filling.map { "a transform of \($0) points is the smallest that fills every band" } ?? "no transform length up to 2²⁴ fills every band"
            throw .invalidParameter(
                stage: .none, parameter: "bands",
                reason: "band \(empty) of \(bands), from \(bank.edges[empty]) Hz to \(bank.edges[empty + 2]) Hz, covers no bin of a transform of \(length) points, whose bins are \(bank.binWidth) Hz apart; \(advice)")
        }
        return bank
    }

    /// The smallest transform length above `length` whose bins reach every band of a bank with
    /// these edges at `sampleRate`, or `nil` when none does below 2²⁴ points.
    static func smallestFillingLength(edges: [Double], sampleRate: Double, above length: Int) -> Int? {
        var candidate = DSP.nextFastLength(length + 1)
        while candidate <= 1 << 24 {
            let width = sampleRate / Double(candidate)
            var filled = true
            var band = 0
            while band < edges.count - 2 {
                // The first bin above the band's lower edge has to lie below its upper edge.
                let next = (edges[band] / width).rounded(.down) + 1
                if next * width >= edges[band + 2] {
                    filled = false
                    break
                }
                band += 1
            }
            if filled { return candidate }
            candidate = DSP.nextFastLength(candidate + 1)
        }
        return nil
    }

    /// Builds the filter bank for the spectral scope at the step's position and emits the node
    /// that applies it. Control context; allocates.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` where there is no linear-frequency
    ///   spectrum; what ``bank(binCount:nyquist:sampleRate:)`` throws.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        guard case .linearFrequency(let bins, let nyquist)? = environment.frequencyAxis, bins >= 2, nyquist > 0 else {
            throw DSPError.unsupportedConfiguration(
                reason: "ExternalMelScale needs the frames of a spectral scope on a linear-frequency axis, and there is none at this position",
                stage: context.path)
        }
        let bank = try bank(binCount: bins, nyquist: nyquist, sampleRate: environment.sampleRate)
        // Banded dot products, or one dense product above the crossover (§7.4, SEL-3).
        let isDense = context.implementation(for: .melProjection, size: bank.bandCount * bins) == .accelerate
        // Each band's dot product is bound here, once, to the implementation its length calls
        // for: 0 a scalar loop, 1 the 8-lane loop, 2 vDSP.
        let crossovers = context.crossovers, requested = environment.implementation
        let kinds: [Int32] = bank.bands.map { band in
            let length = band.weights.count
            if crossovers.implementation(for: .reduction, size: length, requested: requested) == .accelerate { return 2 }
            return crossovers.reductionUsesSIMD(count: length) ? 1 : 0
        }
        context.emit(.analysis(AnalysisStep(
            name: "ExternalMelScale", key: Key(bank: bank, isDense: isDense, kinds: kinds), output: .real(count: bank.bandCount),
            scope: .axis(.mel(centers: bank.centers))
        ) { () throws(DSPError) -> any AnalysisNode in
            try ExternalMelNode(bank: bank, isDense: isDense, kinds: kinds)
        }))
    }
}

/// What runs an `ExternalMelScale`: one frame of linear-frequency bins in, one frame of mel
/// bands out.
///
/// Each bin belongs to at most two bands, so a band is a short run of weights and one dot
/// product. The bands are taken in their own order; neighbours bound to the same dot product
/// form a stretch, so the loop over a stretch holds no test of a length (SEL-3).
///
/// Threading: created on the control context, where it allocates its tables once. `process`
/// and `reset` belong to the analysis thread and allocate nothing, take no lock and log
/// nothing (RT-2); the loops are `while` loops. One thread at a time.
final class ExternalMelNode: AnalysisNode {
    private let binCount: Int
    private let bandCount: Int
    /// The weights of every band, one run after another, in the order of the bands.
    private let weights: AlignedBuffer<Float>
    /// Per band: its first bin, and how many bins it covers.
    private let firstBins: AlignedBuffer<Int>
    private let counts: AlignedBuffer<Int>
    /// Per stretch of bands bound to one dot product: the band after its last, and which dot
    /// product it is (0 a scalar loop, 1 the 8-lane loop, 2 vDSP).
    private let stretchEnds: AlignedBuffer<Int>
    private let stretchKinds: AlignedBuffer<Int>
    private let stretchCount: Int
    /// The whole bank as one matrix, for the dense product; `nil` for banded products.
    private let matrix: AlignedBuffer<Float>?

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(bank: MelFilterBank, isDense: Bool, kinds: [Int32]) throws(DSPError) {
        binCount = bank.binCount
        bandCount = bank.bandCount
        var total = 0
        var stretches = 0
        var band = 0
        while band < bank.bandCount {
            total += bank.bands[band].weights.count
            if band == 0 || ExternalMelNode.kind(of: band, in: kinds) != ExternalMelNode.kind(of: band - 1, in: kinds) { stretches += 1 }
            band += 1
        }
        weights = try AlignedBuffer<Float>(count: max(total, 1))
        firstBins = try AlignedBuffer<Int>(count: max(bank.bandCount, 1))
        counts = try AlignedBuffer<Int>(count: max(bank.bandCount, 1))
        stretchEnds = try AlignedBuffer<Int>(count: max(stretches, 1))
        stretchKinds = try AlignedBuffer<Int>(count: max(stretches, 1))
        stretchCount = stretches

        var offset = 0
        var stretch = -1
        band = 0
        while band < bank.bandCount {
            let run = bank.bands[band]
            firstBins.baseAddress[band] = run.firstBin
            counts.baseAddress[band] = run.weights.count
            var index = 0
            while index < run.weights.count {
                weights.baseAddress[offset + index] = run.weights[index]
                index += 1
            }
            offset += run.weights.count
            let kind = ExternalMelNode.kind(of: band, in: kinds)
            if band == 0 || kind != ExternalMelNode.kind(of: band - 1, in: kinds) {
                stretch += 1
                stretchKinds.baseAddress[stretch] = kind
            }
            stretchEnds.baseAddress[stretch] = band + 1
            band += 1
        }
        if isDense {
            matrix = try AlignedBuffer<Float>(copying: bank.denseWeights())
        } else {
            matrix = nil
        }
    }

    private static func kind(of band: Int, in kinds: [Int32]) -> Int {
        band < kinds.count ? Int(kinds[band]) : 0
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= binCount, let spectrum = frame.values.baseAddress,
              let result = output.real.baseAddress
        else { return }
        if let matrix {
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(bandCount), Int32(binCount), 1, matrix.baseAddress, Int32(binCount), spectrum, 1, 0, result, 1)
            output.emit(count: bandCount)
            return
        }
        let first = UnsafePointer(firstBins.baseAddress), lengths = UnsafePointer(counts.baseAddress)
        let ends = UnsafePointer(stretchEnds.baseAddress), kinds = UnsafePointer(stretchKinds.baseAddress)
        var run = UnsafePointer(weights.baseAddress)
        var band = 0
        var stretch = 0
        while stretch < stretchCount {
            let end = ends[stretch]
            switch kinds[stretch] {
            case 0:
                while band < end {
                    let count = lengths[band]
                    result[band] = Vector.Native.dot(run, spectrum + first[band], count: count)
                    run += count
                    band &+= 1
                }
            case 1:
                while band < end {
                    let count = lengths[band]
                    result[band] = Vector.Native.dotSIMD(run, spectrum + first[band], count: count)
                    run += count
                    band &+= 1
                }
            default:
                while band < end {
                    let count = lengths[band]
                    result[band] = Vector.Accelerated.dot(run, spectrum + first[band], count: count)
                    run += count
                    band &+= 1
                }
            }
            stretch &+= 1
        }
        output.emit(count: bandCount)
    }

    func reset() {}
}

// MARK: The family's typing rule (ORD-1) and its sentences (ORD-4)

extension PipelineBuilder {
    /// The family's compile-time rule: the step follows magnitudes or powers on a
    /// linear-frequency axis and yields the same values on a mel axis.
    public static func buildPartialBlock<I, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, Values>>, next: ExternalMelScale
    ) -> Pipeline<I, Spectrum<MelFrequency, Values>> {
        accumulated.appending(next.stageDescription)
    }

    /// Catches the step after a domain it does not take, with a sentence that names it and says what it needs.
    @available(*, unavailable, message: "ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ExternalMelScale) -> Pipeline<I, O> { accumulated }

    /// Catches the step after sequence stages alone: there are no bins yet.
    @available(*, unavailable, message: "ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: ExternalMelScale) -> SequenceChain { accumulated }

    /// Catches the step at the head of a block: its domains depend on the stage before it (ORD-3).
    @available(*, unavailable, message: "A block cannot begin with ExternalMelScale: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.externalMelScale(bands: 40) }.")
    public static func buildPartialBlock(first: ExternalMelScale) -> Pipeline<Spectrum<LinearFrequency, PowerValues>, Spectrum<MelFrequency, PowerValues>> {
        Pipeline(unchecked: [])
    }
}

extension Pipeline {
    /// The magnitudes or powers on a mel axis: see ``ExternalMelScale``. Usable on any thread.
    public func externalMelScale<Values: LinearValued>(
        bands: Int, range: FrequencyRange? = nil, formula: some MelFormula = .slaney, normalization: some MelNormalization = .slaney,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<MelFrequency, Values>> where Output == Spectrum<LinearFrequency, Values> {
        appending(ExternalMelScale(bands: bands, range: range, formula: formula, normalization: normalization, isActive: isActive).stageDescription)
    }
}
