import Foundation
import ZTronDSPCore

/// How the triangles of a mel filter bank are scaled (§6.11). A strategy (§5.3): pass
/// `.slaney` or `.none`, or a conformer of your own. Conformers are immutable values, usable
/// on any thread; the stock ones do not allocate. `gain` is called where a bank is built,
/// once per band.
public protocol MelNormalization: Hashable, Sendable {
    /// The factor the triangle of one band is multiplied by, given the band's edges and its
    /// centre in hertz.
    func gain(lowerEdge: Double, center: Double, upperEdge: Double) -> Double
}

/// Slaney's normalisation: each triangle is scaled by `2 / (upper edge − lower edge)`, which
/// gives the continuous triangle unit area, so wide bands do not outweigh narrow ones.
///
/// An immutable value, usable on any thread; it does not allocate.
public struct SlaneyMelNormalization: MelNormalization {
    /// Slaney's normalisation; there is nothing to set.
    public init() {}

    /// `2 / (upperEdge − lowerEdge)`.
    @inlinable
    public func gain(lowerEdge: Double, center: Double, upperEdge: Double) -> Double {
        2 / (upperEdge - lowerEdge)
    }
}

/// No normalisation: the peak of every triangle is 1.
///
/// An immutable value, usable on any thread; it does not allocate.
public struct UnitPeakMelNormalization: MelNormalization {
    /// The normalisation that leaves every peak at 1.
    public init() {}

    /// 1, whatever the band.
    @inlinable
    public func gain(lowerEdge: Double, center: Double, upperEdge: Double) -> Double { 1 }
}

extension MelNormalization where Self == SlaneyMelNormalization {
    /// Unit area per band, the default. Usable on any thread; it does not allocate.
    public static var slaney: SlaneyMelNormalization { SlaneyMelNormalization() }
}

extension MelNormalization where Self == UnitPeakMelNormalization {
    /// Unit peak per band. Usable on any thread; it does not allocate.
    public static var none: UnitPeakMelNormalization { UnitPeakMelNormalization() }
}

/// The weights of a mel filter bank over the bins of a linear-frequency spectrum (§6.11): what
/// `MelScale` applies, as a table (§7.2 row 18).
///
/// `bands + 2` edges are spaced equally on the mel scale across the range. Band `m` is a
/// triangle that rises linearly in hertz from edge `m` to edge `m + 1` and falls to edge
/// `m + 2`, evaluated at the bin centres. Each bin belongs to at most two bands, so a band is
/// kept as its first bin and the run of weights that are not zero.
///
/// The weights are computed in double precision and kept in single. An immutable value,
/// usable on any thread; creating it allocates.
public struct MelFilterBank: Hashable, Sendable {
    /// The weights of one band: bins `firstBin ..< firstBin + weights.count`.
    ///
    /// An immutable value, usable on any thread; it does not allocate.
    public struct Band: Hashable, Sendable {
        /// The first bin with a weight.
        public let firstBin: Int
        /// The weights that are not zero, from `firstBin` on.
        public let weights: [Float]
    }

    /// Bins of the spectrum the bank applies to.
    public let binCount: Int
    /// Hertz between two bins.
    public let binWidth: Double
    /// The `bands + 2` edges, in hertz.
    public let edges: [Double]
    /// The bands, lowest first.
    public let bands: [Band]

    /// - Parameters:
    ///   - bands: how many bands, at least 1.
    ///   - binCount: bins of the spectrum, from 0 Hz to `nyquist`: at least 2.
    ///   - nyquist: the frequency of the last bin, in hertz.
    ///   - range: the band the edges span, in hertz; `nil` for 0 Hz to `nyquist`.
    ///   - formula: the mel scale the edges are spaced on; `.slaney` by default.
    ///   - normalization: how each triangle is scaled; `.slaney`, unit area, by default.
    /// - Throws: `DSPError.invalidParameter` for counts that hold nothing and for a range that
    ///   is empty or leaves 0 Hz … `nyquist`. A band that covers no bin is not an error here:
    ///   see ``firstEmptyBand``.
    public init(
        bands: Int, binCount: Int, nyquist: Double, range: ClosedRange<Double>? = nil, formula: some MelFormula = .slaney,
        normalization: some MelNormalization = .slaney
    ) throws(DSPError) {
        guard bands >= 1, bands <= 1 << 16 else {
            throw .invalidParameter(stage: .none, parameter: "bands", reason: "a filter bank has between 1 and 65 536 bands, not \(bands)")
        }
        guard binCount >= 2, nyquist > 0, nyquist.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "binCount", reason: "a spectrum of \(binCount) bins up to \(nyquist) Hz has no bins to weigh")
        }
        let low = range?.lowerBound ?? 0, high = range?.upperBound ?? nyquist
        guard low >= 0, high > low, high <= nyquist, low.isFinite, high.isFinite else {
            throw .invalidParameter(
                stage: .none, parameter: "range",
                reason: "the mel range runs from \(low) Hz to \(high) Hz: it must not be empty and must lie within 0 Hz … the Nyquist frequency, \(nyquist) Hz")
        }
        let width = nyquist / Double(binCount - 1)
        let edges = MelFilterBank.edges(bands: bands, low: low, high: high, formula: formula)
        var built: [Band] = []
        built.reserveCapacity(bands)
        for band in 0 ..< bands {
            let lower = edges[band], center = edges[band + 1], upper = edges[band + 2]
            let gain = normalization.gain(lowerEdge: lower, center: center, upperEdge: upper)
            // The bins strictly inside the triangle's foot are the ones with a weight.
            var bin = max(Int((lower / width).rounded(.down)), 0)
            var first = -1
            var weights: [Float] = []
            while bin < binCount {
                let frequency = Double(bin) * width
                if frequency >= upper { break }
                let rising = (frequency - lower) / (center - lower), falling = (upper - frequency) / (upper - center)
                let weight = Float(max(0, min(rising, falling)) * gain)
                if weight > 0 {
                    if first < 0 { first = bin }
                    weights.append(weight)
                }
                bin += 1
            }
            built.append(Band(firstBin: max(first, 0), weights: weights))
        }
        self.binCount = binCount
        self.binWidth = width
        self.edges = edges
        self.bands = built
    }

    /// `bands + 2` points equally spaced on the mel scale from `low` to `high`, in hertz.
    static func edges(bands: Int, low: Double, high: Double, formula: some MelFormula) -> [Double] {
        let first = formula.mel(fromHertz: low), last = formula.mel(fromHertz: high)
        var result = (0 ..< bands + 2).map { formula.hertz(fromMel: first + (last - first) * Double($0) / Double(bands + 1)) }
        // The ends are the range itself, whatever the round trip through the formula gives.
        result[0] = low
        result[bands + 1] = high
        return result
    }

    /// How many bands.
    public var bandCount: Int { bands.count }

    /// The centre of each band, in hertz: what the rows of a mel spectrum are (VC-5). It allocates
    /// the array it returns.
    public var centers: [Double] { Array(edges.dropFirst().dropLast()) }

    /// The first band that has no bin with a weight, when there is one (O-18). Such a band
    /// would always read zero: the frame is too short for it.
    public var firstEmptyBand: Int? { bands.firstIndex { $0.weights.isEmpty } }

    /// The weights as a dense matrix, band after band: `bandCount · binCount` values. It allocates
    /// the array it returns.
    public func denseWeights() -> [Float] {
        var result = [Float](repeating: 0, count: bands.count * binCount)
        for (index, band) in bands.enumerated() {
            for (offset, weight) in band.weights.enumerated() { result[index * binCount + band.firstBin + offset] = weight }
        }
        return result
    }

    /// The mel bands of one spectrum of `binCount` magnitudes or powers. A one-shot
    /// computation in double precision: it allocates, and is not for the analysis thread.
    public func applied(to spectrum: [Float]) -> [Float] {
        bands.map { band in
            var sum = 0.0
            for (offset, weight) in band.weights.enumerated() where band.firstBin + offset < spectrum.count {
                sum += Double(weight) * Double(spectrum[band.firstBin + offset])
            }
            return Float(sum)
        }
    }

    /// The smallest transform length above `length` whose bins reach every band of a bank
    /// with these edges at `sampleRate`, or `nil` when none does below 2²⁴ points.
    static func smallestFillingLength(edges: [Double], sampleRate: Double, above length: Int) -> Int? {
        var candidate = DSP.nextFastLength(length + 1)
        while candidate <= 1 << 24 {
            let width = sampleRate / Double(candidate)
            var filled = true
            for band in 0 ..< max(edges.count - 2, 0) {
                // A bin strictly between the band's lower and upper edge.
                let next = (edges[band] / width).rounded(.down) + 1
                if next * width >= edges[band + 2] {
                    filled = false
                    break
                }
            }
            if filled { return candidate }
            candidate = DSP.nextFastLength(candidate + 1)
        }
        return nil
    }
}
