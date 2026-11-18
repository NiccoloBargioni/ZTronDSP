import Foundation
import ZTronDSPCore

/// The pseudo constant-Q transform as a processing step (§6.8): magnitudes or powers on a
/// linear-frequency axis in, the same kind of value on a constant-Q axis out. An axis
/// conversion, as `MelScale` is.
///
/// ```swift
/// STFT(frame: 8_192, hop: 512); Magnitude()
/// ConstantQScale(fmin: .midiNote(48), octaves: 5, binsPerOctave: 12)     // C3 up, a bin per semitone
/// ChromaFold()
/// ```
///
/// - The bins are those of ``ConstantQ`` with the same arguments (``ConstantQGeometry``).
///   Band `k` weighs each linear bin by the magnitude of the response of the `k`-th
///   constant-Q atom at that bin, 1 at the band's centre; a spectrum of powers is weighed by
///   the square of it. One transform per hop and no phase: what there is of resolution is
///   that of the frame the spectra come from.
/// - That is why it is meant for bins a single frame resolves: when the pipeline is
///   attached, a bin whose atom is longer than the frame is refused, and the error names the
///   frame that would hold it and the lowest `fmin` this frame holds. So are bins that reach
///   the Nyquist frequency.
/// - It follows magnitudes or powers on a linear-frequency axis: a band sums energy, and
///   decibels do not add; a complex spectrum has to become real first; an axis that is no
///   longer linear cannot be converted. Decibels come after it.
/// - `sparsity` thins the weights of a band out as it thins a kernel row: no band loses more
///   than 0.1 % of the energy of its response.
/// - Downstream, the environment and the feeds describe a constant-Q axis, so a view labels
///   the rows and `ChromaFold` folds them without knowing how they were produced.
///
/// Going back to linear bins is lossy and is not offered (D-10). Switched off, the step
/// suspends the rest of its branch (ACT-3). An immutable value, usable on any thread.
public struct ConstantQScale: ContextDependentStep {
    /// The centre of the lowest bin, before tuning.
    public let fmin: Frequency
    /// How many octaves the bins span.
    public let octaves: Int
    /// Bins per octave.
    public let binsPerOctave: Int
    /// The offset of every bin centre, in fractions of a bin.
    public let tuning: Double
    /// The factor on `Q`: above 1 the atoms are longer and the bands narrower.
    public let filterScale: Double
    /// The bandwidth every band is widened by, in hertz: 0 for constant Q.
    public let gamma: Double
    /// The window of the atoms whose responses the bands are.
    public let window: Window
    /// The share of a band's summed weights that may be dropped.
    public let sparsity: Double
    public let activation: StageActivation

    public init(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, filterScale: Double = 1,
        gamma: Double = 0, window: Window = .hann, sparsity: Double = 0.01, isActive: some ActivationSource = .active
    ) {
        self.fmin = fmin
        self.octaves = octaves
        self.binsPerOctave = binsPerOctave
        self.tuning = tuning
        self.filterScale = filterScale
        self.gamma = gamma
        self.window = window
        self.sparsity = sparsity
        self.activation = isActive.stageActivation
    }

    /// From magnitudes or powers on a linear-frequency axis to the same values on a
    /// constant-Q axis.
    public static let rule = DomainRule.spectral("ConstantQScale: linear-frequency magnitudes or powers to a constant-Q axis") { axis, values in
        axis == .linear && (values == .magnitude || values == .power) ? .spectrum(axis: .constantQ, values: values) : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: ConstantQScale.rule) }

    struct Key: Hashable, Sendable {
        let geometry: ConstantQGeometry
        let binCount: Int
        let window: Window
        let sparsity: Double
        let isSquared: Bool
        let isDense: Bool
    }

    /// The bins for a spectrum of `binCount` bins up to `nyquist`, cut from frames of
    /// `frameSize` samples, checked.
    func geometry(binCount: Int, nyquist: Double, frameSize: Int, in context: LoweringContext) throws(DSPError) -> ConstantQGeometry {
        let rate = 2 * nyquist
        let lowest: Double
        do throws(DSPError) {
            lowest = try fmin.hertz(sampleRate: rate)
        } catch {
            if case .invalidParameter(_, _, let reason) = error { throw context.invalid("fmin", reason) }
            throw error
        }
        let geometry = try ConstantQGeometry(
            minimumFrequency: lowest, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, filterScale: filterScale, gamma: gamma,
            sampleRate: rate)
        // The lowest bin has the longest atom: a frame that holds it holds them all.
        let longest = geometry.atomLength(ofBin: 0)
        guard longest <= frameSize else {
            // A frame holds the atom of a bin, Q · rate / (f + γ/α) samples, from this frequency up.
            let resolved = max(geometry.q * rate / Double(frameSize) - gamma / geometry.alpha, 0)
            throw context.invalid(
                "fmin",
                "the lowest bin, at \(geometry.frequency(ofBin: 0)) Hz, has an atom of \(longest) samples, longer than the frame of \(frameSize) samples the spectra come from: a single frame does not resolve it. A frame of \(DSP.nextFastLength(longest)) samples holds it; this frame holds the bins from \(resolved) Hz up")
        }
        return geometry
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        guard case .linearFrequency(let bins, let nyquist)? = environment.frequencyAxis, bins >= 2, nyquist > 0 else {
            throw DSPError.unsupportedConfiguration(
                reason: "ConstantQScale needs the frames of a spectral scope on a linear-frequency axis, and there is none at this position", stage: context.path)
        }
        let length = 2 * (bins - 1)
        guard DSP.isFastLength(length) else {
            throw DSPError.unsupportedConfiguration(
                reason: "ConstantQScale needs the spectra of a transform length: \(bins) bins are those of a transform of \(length) points, which is none", stage: context.path)
        }
        guard sparsity >= 0, sparsity < 1 else {
            throw context.invalid("sparsity", "the sparsity is the share of a band that may be dropped, from 0 up to but not 1, not \(sparsity)")
        }
        guard !window.isHalf else {
            throw context.invalid("window", "\(window) covers the first half of a frame only: an atom needs a window over its whole length")
        }
        let geometry = try geometry(binCount: bins, nyquist: nyquist, frameSize: min(environment.frameSize ?? length, length), in: context)
        let isSquared: Bool
        if case .spectrum(_, .power) = context.domain { isSquared = true } else { isSquared = false }
        // Banded dot products, or one dense product above the crossover: the choice of a band
        // projection, which is what the mel projection is too (§7.4).
        let isDense = context.implementation(for: .melProjection, size: geometry.binCount * bins) == .accelerate
        let crossovers = context.crossovers, requested = environment.implementation
        let window = window, sparsity = sparsity
        context.emit(.analysis(AnalysisStep(
            name: "ConstantQScale", key: Key(geometry: geometry, binCount: bins, window: window, sparsity: sparsity, isSquared: isSquared, isDense: isDense),
            output: .real(count: geometry.binCount), scope: .axis(geometry.axis)
        ) { () throws(DSPError) -> any AnalysisNode in
            let projection = try ConstantQProjection(geometry: geometry, binCount: bins, window: window, sparsity: sparsity, squared: isSquared)
            if isDense { return try DenseConstantQNode(projection) }
            return try BandedConstantQNode(projection, crossovers: crossovers, requested: requested)
        }))
    }
}

extension PipelineBuilder {
    public static func buildPartialBlock<I, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<LinearFrequency, Values>>, next: ConstantQScale
    ) -> Pipeline<I, Spectrum<ConstantQFrequency, Values>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The magnitudes or powers on a constant-Q axis: see ``ConstantQScale``.
    public func constantQScale<Values: LinearValued>(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, filterScale: Double = 1,
        gamma: Double = 0, window: Window = .hann, sparsity: Double = 0.01, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<ConstantQFrequency, Values>> where Output == Spectrum<LinearFrequency, Values> {
        appending(ConstantQScale(
            fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, filterScale: filterScale, gamma: gamma, window: window,
            sparsity: sparsity, isActive: isActive).stageDescription)
    }
}
