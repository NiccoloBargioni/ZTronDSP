import Foundation
import ZTronDSPCore

/// The bins of a constant-Q transform at one sample rate (§6.8): where each bin sits and how
/// long its atom is.
///
/// ```swift
/// let geometry = try ConstantQGeometry(minimumFrequency: 32.70, octaves: 7, binsPerOctave: 36, sampleRate: 48_000)
/// geometry.frequencies       // 252 centres, 32.70 Hz … 4 106 Hz
/// geometry.atomLengths       // 75 507 … 602 samples
/// ```
///
/// With `B` bins per octave:
///
/// - bin `k` is centred on `fₖ = minimumFrequency · 2^((k + tuning) / B)`;
/// - `α = 2^(1/B) − 1` and `Q = filterScale / α`;
/// - its atom is `Nₖ = ⌈Q · sampleRate / (fₖ + γ/α)⌉` samples long.
///
/// `tuning` is in fractions of a bin and moves every centre, so it belongs to the transform
/// and not to what is made of it later. With `gamma` above 0 the transform is variable-Q: the
/// atoms of the low bins are shorter than constant-Q asks, which is what shortens the delay
/// of a transform that runs in real time.
///
/// A geometry is what the steps of §6.8 compute from their arguments and the sample rate at their
/// position; it is a table, not something a step is given. An immutable value, usable on any
/// thread; creating one allocates only the error it throws.
public struct ConstantQGeometry: Hashable, Sendable {
    /// Samples per second of the signal the atoms are laid on.
    public let sampleRate: Double
    /// The centre of bin 0 when `tuning` is 0, in hertz.
    public let minimumFrequency: Double
    /// How many octaves the bins span.
    public let octaves: Int
    /// Bins per octave, `B`.
    public let binsPerOctave: Int
    /// The offset of every centre, in fractions of a bin.
    public let tuning: Double
    /// The factor on `Q`: above 1 the atoms are longer and the bins narrower.
    public let filterScale: Double
    /// The bandwidth every bin is widened by, in hertz: 0 for constant Q.
    public let gamma: Double

    /// - Parameters:
    ///   - minimumFrequency: above 0 Hz.
    ///   - octaves: 1 … 32. The highest bin must lie below half the sample rate.
    ///   - binsPerOctave: 1 … 1 200; a multiple of 12 where chroma follow.
    ///   - tuning: −1 … 1 bins.
    ///   - filterScale: above 0.
    ///   - gamma: 0 Hz or more.
    ///   - sampleRate: the rate the bins are laid out at: positive and finite.
    /// - Throws: `DSPError.invalidParameter` for a value outside these ranges, and for bins
    ///   that reach the Nyquist frequency: the reason names how many octaves fit.
    public init(
        minimumFrequency: Double, octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, filterScale: Double = 1,
        gamma: Double = 0, sampleRate: Double
    ) throws(DSPError) {
        guard sampleRate > 0, sampleRate.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        guard minimumFrequency > 0, minimumFrequency.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "fmin", reason: "the lowest bin sits above 0 Hz, not at \(minimumFrequency) Hz")
        }
        guard octaves >= 1, octaves <= 32 else {
            throw .invalidParameter(stage: .none, parameter: "octaves", reason: "a constant-Q transform spans between 1 and 32 octaves, not \(octaves)")
        }
        guard binsPerOctave >= 1, binsPerOctave <= 1_200 else {
            throw .invalidParameter(stage: .none, parameter: "binsPerOctave", reason: "an octave holds between 1 and 1 200 bins, not \(binsPerOctave)")
        }
        guard tuning.isFinite, abs(tuning) <= 1 else {
            throw .invalidParameter(stage: .none, parameter: "tuning", reason: "tuning is a fraction of a bin between −1 and 1, not \(tuning)")
        }
        guard filterScale > 0, filterScale.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "filterScale", reason: "the filter scale is positive and finite, not \(filterScale)")
        }
        guard gamma >= 0, gamma.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "gamma", reason: "gamma is a bandwidth of 0 Hz or more, not \(gamma)")
        }
        self.sampleRate = sampleRate
        self.minimumFrequency = minimumFrequency
        self.octaves = octaves
        self.binsPerOctave = binsPerOctave
        self.tuning = tuning
        self.filterScale = filterScale
        self.gamma = gamma

        let nyquist = sampleRate / 2
        let highest = frequency(ofBin: octaves * binsPerOctave - 1)
        guard highest < nyquist else {
            // The highest bin of n octaves is 2^n · lowestTop, with lowestTop = fmin · 2^((tuning − 1) / B).
            let lowestTop = minimumFrequency * pow(2, (tuning - 1) / Double(binsPerOctave))
            // n octaves fit while 2^n · lowestTop stays below the Nyquist frequency.
            let fitting = lowestTop < nyquist ? max(Int(log2(nyquist / lowestTop).rounded(.up)) - 1, 0) : 0
            let advice = fitting >= 1 ? "\(fitting) octave\(fitting == 1 ? "" : "s") above \(minimumFrequency) Hz fit below it" : "not one octave above \(minimumFrequency) Hz fits below it"
            throw .invalidParameter(
                stage: .none, parameter: "octaves",
                reason: "the highest of \(octaves * binsPerOctave) bins sits at \(highest) Hz, which is not below the Nyquist frequency of \(nyquist) Hz at this position; \(advice)")
        }
        // The longest atom is counted in an `Int`: a lowest bin a fraction of a hertz above 0 has none.
        guard q * sampleRate / (frequency(ofBin: 0) + gamma / alpha) < 1e12 else {
            throw .invalidParameter(
                stage: .none, parameter: "fmin",
                reason: "the atom of the lowest bin, at \(frequency(ofBin: 0)) Hz, would be longer than 10¹² samples")
        }
    }

    /// Bins in all: `octaves · binsPerOctave`.
    public var binCount: Int { octaves * binsPerOctave }

    /// `α = 2^(1/B) − 1`: the distance from a bin to the next, as a share of its frequency.
    public var alpha: Double { pow(2, 1 / Double(binsPerOctave)) - 1 }

    /// `Q = filterScale / α`: the periods of its centre frequency an atom holds when `gamma`
    /// is 0.
    public var q: Double { filterScale / alpha }

    /// The centre of bin `bin` in hertz, `minimumFrequency · 2^((bin + tuning) / B)`. Bins an
    /// octave apart are a factor of exactly two apart. The formula holds for any index, also
    /// outside `0 ..< binCount`.
    public func frequency(ofBin bin: Int) -> Double {
        let octave = Int((Double(bin) / Double(binsPerOctave)).rounded(.down))
        let position = bin - octave * binsPerOctave
        return minimumFrequency * pow(2, Double(octave)) * pow(2, (Double(position) + tuning) / Double(binsPerOctave))
    }

    /// The centre of every bin, lowest first. It allocates the array it returns.
    public var frequencies: [Double] { (0 ..< binCount).map { frequency(ofBin: $0) } }

    /// The length of the atom of bin `bin` in samples at `sampleRate`:
    /// `⌈Q · sampleRate / (fₖ + γ/α)⌉`.
    public func atomLength(ofBin bin: Int) -> Int {
        ConstantQGeometry.length(q * sampleRate / (frequency(ofBin: bin) + gamma / alpha))
    }

    /// The atom length of every bin, lowest bin, and so longest atom, first. It allocates the array
    /// it returns.
    public var atomLengths: [Int] { (0 ..< binCount).map { atomLength(ofBin: $0) } }

    /// The axis of a spectrum with these bins: what a feed and the environment carry
    /// downstream of the transform (VC-5). Row 0 is the centre of bin 0, tuning included.
    public var axis: FeedAxis {
        .constantQ(minimumFrequency: frequency(ofBin: 0), binsPerOctave: binsPerOctave, binCount: binCount)
    }

    // MARK: The bins as an octave-recursive transform reads them

    /// The centre of the bin at `position` of an octave in cycles per sample of the rate that
    /// octave is read at. It is the same for every octave: an octave down, the frequencies
    /// and the rate both halve.
    func normalizedFrequency(atPosition position: Int) -> Double {
        frequency(ofBin: (octaves - 1) * binsPerOctave + position) / sampleRate
    }

    /// The atom lengths of one octave, in samples of the rate that octave is read at:
    /// `sampleRate / 2^depth`, with `depth` 0 for the highest octave. The definition of the
    /// lengths applied at that rate: `⌈Q / (ν + γ · 2^depth / (α · sampleRate))⌉`.
    ///
    /// With `gamma` 0 every octave has the same lengths, which is what lets one kernel serve
    /// them all.
    func atomLengths(atDepth depth: Int) -> [Int] {
        let widening = gamma * pow(2, Double(depth)) / (alpha * sampleRate)
        return (0 ..< binsPerOctave).map { ConstantQGeometry.length(q / (normalizedFrequency(atPosition: $0) + widening)) }
    }

    /// The longest atom of the octave at `depth`, in samples of its own rate: what one frame
    /// of that octave has to hold.
    func span(atDepth depth: Int) -> Int {
        atomLengths(atDepth: depth).max() ?? 1
    }

    /// A length in whole samples: the value rounded up, and never less than one sample.
    private static func length(_ exact: Double) -> Int {
        Int(max(exact.rounded(.up), 1))
    }
}
