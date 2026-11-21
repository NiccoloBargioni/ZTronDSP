import Foundation
import ZTronDSPCore

/// The window of a constant-Q atom, laid around the sample the atom is centred on.
enum ConstantQAtom {
    /// The window of an atom of `length` samples, at the offsets `−⌊length/2⌋ ..< ⌈length/2⌉`
    /// from its centre: sample `m` is the window at `t = ½ + m / length`. Its peak therefore
    /// sits on the centre sample for an even and for an odd length alike, which is what lets
    /// atoms of every length, in every octave, be centred on one instant.
    ///
    /// - Throws: `invalidParameter` for a half window, a window without a sum to normalise by,
    ///   and whatever sampling throws (WIN-3).
    static func window(_ window: Window, length: Int) throws(DSPError) -> (samples: [Double], sum: Double) {
        guard !window.isHalf else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "\(window) covers the first half of a frame only: an atom needs a window over its whole length")
        }
        // `t = ½ + m / length` is sample `length + 2m` of the window sampled at twice the length.
        let fine = try window.doubleSamples(count: 2 * length)
        // coverage:ignore(a Window returns as many samples as it is asked for; the guard keeps the indices below inside what it returned)
        guard fine.count == 2 * length else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "\(window) gives \(fine.count) samples where \(2 * length) were asked for")
        }
        var samples = [Double](repeating: 0, count: length)
        var sum = 0.0, peak = 0.0
        let first = length - 2 * (length / 2)
        for index in 0 ..< length {
            let value = fine[first + 2 * index]
            samples[index] = value
            sum += value
            peak = max(peak, abs(value))
        }
        // A sum that is the round-off of its terms is nothing to normalise by (§7.5 row 21).
        guard abs(sum) > WindowAnalysis.Limit.sameValue * Double(length) * peak, sum.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "\(window) sums to \(sum) over an atom of \(length) samples: it has no gain to normalise the atom by")
        }
        return (samples, sum)
    }

    /// The share of its energy a kernel row keeps on the bins it may read when it is kept in
    /// full, and the magnitude from which its entries stay when it is thinned out.
    ///
    /// The entries are dropped from the smallest up while the magnitudes dropped stay below
    /// `sparsity` of their sum, and while what remains holds at least
    /// `ConstantQKernel.keptEnergyFloor` of `total`, the energy of the row over both halves
    /// of the spectrum. What `total` exceeds the energy of `magnitudes` by lies where the row
    /// may not read, at negative frequencies or above the band it is given, and counts as
    /// dropped from the start.
    ///
    /// - Returns: `threshold`, the magnitude of the smallest entry that stays, or `nil` when
    ///   the row does not hold that share even in full; `kept`, the share it holds in full.
    static func threshold(magnitudes: [Double], total: Double, sparsity: Double) -> (threshold: Double?, kept: Double) {
        var oneSided = 0.0, summed = 0.0
        for magnitude in magnitudes {
            oneSided += magnitude * magnitude
            summed += magnitude
        }
        let budget = (1 - ConstantQKernel.keptEnergyFloor) * total
        let mirrored = max(total - oneSided, 0)
        guard total > 0, total.isFinite, mirrored <= budget else { return (nil, total > 0 && total.isFinite ? min(oneSided / total, 1) : 0) }
        var dropped = mirrored, passed = 0.0
        for magnitude in magnitudes.sorted() {
            passed += magnitude
            if passed >= sparsity * summed || dropped + magnitude * magnitude > budget { return (magnitude, min(oneSided / total, 1)) }
            dropped += magnitude * magnitude
        }
        return (0, min(oneSided / total, 1))
    }
}

/// Lays constant-Q atoms in a frame and transforms them, in double precision: what a kernel
/// and a projection are computed from. Control context; it allocates when it is made.
struct ConstantQAtomTransform {
    /// The transform length: samples of a frame.
    let length: Int
    /// Bins of a one-sided spectrum: `length / 2 + 1`.
    let binCount: Int
    private let transform: DoubleDFT
    private var atomReal: [Double]
    private var atomImaginary: [Double]
    private var sineReal: [Double]
    private var sineImaginary: [Double]
    /// The real parts of the transform of the last atom, bins `0 … length / 2`.
    private(set) var real: [Double]
    /// The imaginary parts of the transform of the last atom.
    private(set) var imaginary: [Double]
    /// Samples of the frame the last atom wrote: what has to be cleared for the next.
    private var written = 0 ..< 0

    /// - Throws: `invalidParameter` for a length that is no transform length.
    init(length: Int) throws(DSPError) {
        try TransformLength.admit(length, parameter: "transformLength")
        self.length = length
        binCount = length / 2 + 1
        transform = try DoubleDFT(length: length)
        atomReal = [Double](repeating: 0, count: length)
        atomImaginary = atomReal
        real = [Double](repeating: 0, count: binCount)
        imaginary = real
        sineReal = real
        sineImaginary = real
    }

    /// Transforms the atom `gain · w[m] / Σw · e^(j2π · frequency · m)` of `atomLength`
    /// samples, with `frequency` in cycles per sample and `m` counted from sample `center` of
    /// the frame, which the atom is centred on. The spectrum is left in `real` and
    /// `imaginary`.
    ///
    /// - Returns: the energy of the atom, `Σ|a[m]|²`; by Parseval's theorem the energy of its
    ///   whole transform is `length` times that.
    mutating func transform(window: Window, atomLength: Int, frequency: Double, center: Int, gain: Double) throws(DSPError) -> Double {
        let shape = try ConstantQAtom.window(window, length: atomLength)
        let first = center - atomLength / 2
        guard first >= 0, first + atomLength <= length else {
            throw .invalidParameter(stage: .none, parameter: "transformLength", reason: "an atom of \(atomLength) samples centred on sample \(center) does not lie inside a frame of \(length)")
        }
        for index in written {
            atomReal[index] = 0
            atomImaginary[index] = 0
        }
        written = first ..< first + atomLength
        let scale = gain / shape.sum
        var energy = 0.0
        for index in 0 ..< atomLength {
            let phase = 2 * Double.pi * frequency * Double(index - atomLength / 2)
            let value = scale * shape.samples[index]
            atomReal[first + index] = value * cos(phase)
            atomImaginary[first + index] = value * sin(phase)
            energy += value * value
        }
        // The transform of the complex atom from those of its two real parts:
        // A = DFT(real part) + j · DFT(imaginary part).
        atomReal.withUnsafeBufferPointer { source in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    guard let from = source.baseAddress, let toReal = re.baseAddress, let toImaginary = im.baseAddress else { return }
                    transform.forward(from, real: toReal, imaginary: toImaginary)
                }
            }
        }
        atomImaginary.withUnsafeBufferPointer { source in
            sineReal.withUnsafeMutableBufferPointer { re in
                sineImaginary.withUnsafeMutableBufferPointer { im in
                    guard let from = source.baseAddress, let toReal = re.baseAddress, let toImaginary = im.baseAddress else { return }
                    transform.forward(from, real: toReal, imaginary: toImaginary)
                }
            }
        }
        for bin in 0 ..< binCount {
            real[bin] -= sineImaginary[bin]
            imaginary[bin] += sineReal[bin]
        }
        return energy
    }
}

/// The spectral kernel of one octave of a constant-Q transform (§6.8, §7.2 row 13): what turns
/// the spectrum of a frame into the constant-Q coefficients of that octave, stored sparsely.
///
/// A coefficient is the inner product of the signal with an atom: a windowed complex
/// exponential at the bin's centre frequency, scaled by `2 / Σw` so that a sine at the centre
/// reads its own amplitude. By Parseval's theorem that inner product is also one over the
/// spectrum of the frame, against the conjugate transform of the atom, and the transform of
/// an atom is concentrated around its frequency: a row of the kernel has a few entries worth
/// keeping (Brown & Puckette 1992).
///
/// ```swift
/// let kernel = try ConstantQKernel(geometry: geometry, octave: geometry.octaves - 1)
/// kernel.nonZeroCount        // about ten per row for the defaults of §6.8
/// kernel.keptEnergy.min()    // at least 0.999
/// ```
///
/// **The frame.** A frame is `span` samples, the length of the octave's longest atom, followed
/// by zeros up to `transformLength`; every atom is centred on sample `center` of it. Row `r`
/// holds `conj(DFT(atom r)) / transformLength` at the bins `0 … transformLength / 2` of a
/// one-sided spectrum, so that the coefficient is `Σ_b kernel[r, b] · X[b]`.
///
/// **What a row reads.** The bins of a one-sided spectrum; and where the transform has more
/// than one octave, those up to 0.8 of the Nyquist frequency only, because every octave but
/// the highest is read from a signal that half-band decimators have halved, and that is the
/// band they pass unchanged and keep free of aliases. (With a `gamma` above 0 the highest
/// octave has a kernel of its own, which reads its whole band.)
///
/// **Sparsity.** The entries of a row are dropped from the smallest up while the magnitudes
/// dropped stay below `sparsity` of the row's summed magnitude, and while the row keeps at
/// least ``keptEnergyFloor`` of its energy, whatever `sparsity` asks for. The energy is that
/// of the whole transform of the atom: what lies where the row does not read, at negative
/// frequencies or above its band, counts as dropped. A row that cannot keep that much even
/// in full is refused: its atom is too short to tell its frequency from its mirror image, or
/// its bin lies too close to the top of the band.
///
/// **Storage.** Compressed sparse rows with the real and the imaginary parts apart: Accelerate
/// has no complex sparse product at the deployment target (E-11).
///
/// The kernel is computed in double precision and kept in single. An immutable value, usable
/// on any thread; creating it allocates and transforms, and is not for the analysis thread.
public struct ConstantQKernel: Hashable, Sendable {
    /// The least share of its energy a row keeps (§7.5 row 13).
    public static let keptEnergyFloor = 0.999

    /// Bins of the octave: the rows.
    public let rowCount: Int
    /// The length of the transform the kernel is applied to the spectrum of.
    public let transformLength: Int
    /// Samples at the start of a frame that the atoms reach; the rest of the frame is zeros.
    public let span: Int
    /// The sample of the frame every atom is centred on: `span / 2`.
    public let center: Int
    /// The atom length of each row, in samples of the rate the octave is read at.
    public let atomLengths: [Int]
    /// Where each row starts in ``columns``, ``real`` and ``imaginary``: `rowCount + 1`
    /// offsets, the last one the number of entries.
    public let rowStarts: [Int]
    /// The bin of each entry, ascending within a row.
    public let columns: [Int]
    /// The real part of each entry.
    public let real: [Float]
    /// The imaginary part of each entry.
    public let imaginary: [Float]
    /// The share of its energy each row keeps: at least ``keptEnergyFloor``.
    public let keptEnergy: [Double]

    /// - Parameters:
    ///   - geometry: the bins of the transform.
    ///   - octave: which octave's bins, counted from the lowest: bins
    ///     `octave · B ..< (octave + 1) · B`, read at `sampleRate / 2^(octaves − 1 − octave)`.
    ///     With a `gamma` of 0 every octave has the same kernel.
    ///   - window: the window of the atoms.
    ///   - sparsity: the largest share of a row's summed magnitude that is dropped, `0 ..< 1`;
    ///     0 keeps every bin.
    ///   - transformLength: the transform the kernel is for; `nil` for the smallest transform
    ///     length that holds the longest atom of the highest octave.
    /// - Throws: `DSPError.invalidParameter` for an octave or a sparsity out of range, a
    ///   length that is no transform length or is shorter than the longest atom, a window
    ///   that cannot be sampled or sums to nothing, and a row that keeps less than
    ///   ``keptEnergyFloor`` of its energy in full: the reason says whether the atom is too
    ///   short or the bin too high.
    public init(
        geometry: ConstantQGeometry, octave: Int, window: Window = .hann, sparsity: Double = 0.01, transformLength: Int? = nil
    ) throws(DSPError) {
        guard octave >= 0, octave < geometry.octaves else {
            throw .invalidParameter(stage: .none, parameter: "octave", reason: "octave \(octave) is not one of the \(geometry.octaves) octaves of the transform, numbered from 0")
        }
        guard sparsity >= 0, sparsity < 1 else {
            throw .invalidParameter(stage: .none, parameter: "sparsity", reason: "the sparsity is the share of a kernel row that may be dropped, from 0 up to but not 1, not \(sparsity)")
        }
        let depth = geometry.octaves - 1 - octave
        let lengths = geometry.atomLengths(atDepth: depth)
        let span = lengths.max() ?? 1
        guard span <= ConstantQKernel.longestAtom else {
            throw .invalidParameter(
                stage: .none, parameter: "fmin",
                reason: "the longest atom of octave \(octave) is \(span) samples at its own rate, above the \(ConstantQKernel.longestAtom) a kernel is built for: raise fmin, or lower binsPerOctave or filterScale")
        }
        let length = transformLength ?? DSP.nextFastLength(max(span, geometry.span(atDepth: 0)))
        guard length >= span else {
            throw .invalidParameter(stage: .none, parameter: "transformLength", reason: "a transform of \(length) points does not hold the longest atom of octave \(octave), \(span) samples")
        }

        let center = span / 2
        var atoms = try ConstantQAtomTransform(length: length)
        let scale = 1 / Double(length)
        // The bins a row may read: all of them, or those the decimators above its octave keep clean.
        let isHalved = geometry.octaves > 1 && (geometry.gamma == 0 || depth > 0)
        let readable = isHalved ? Int((HalfBand.cleanShare * Double(length / 2)).rounded(.down)) + 1 : atoms.binCount
        var magnitudes = [Double](repeating: 0, count: readable)

        var starts = [0]
        var columns: [Int] = []
        var real: [Float] = [], imaginary: [Float] = []
        var kept: [Double] = []
        starts.reserveCapacity(lengths.count + 1)

        for (row, atomLength) in lengths.enumerated() {
            let frequency = geometry.normalizedFrequency(atPosition: row)
            // Scaled by 2 / Σw: a sine of amplitude 1 at the bin's centre reads 1.
            let energy = try atoms.transform(window: window, atomLength: atomLength, frequency: frequency, center: center, gain: 2)
            // kernel = conj(A) / N.
            let atomReal = atoms.real, atomImaginary = atoms.imaginary
            var beyond = 0.0
            for bin in 0 ..< atomReal.count {
                let magnitude = (atomReal[bin] * atomReal[bin] + atomImaginary[bin] * atomImaginary[bin]).squareRoot() * scale
                if bin < readable { magnitudes[bin] = magnitude } else { beyond += magnitude * magnitude }
            }
            // Parseval: the energy of the whole row, both halves of the spectrum, is that of the atom over N.
            let total = energy * scale
            let thinning = ConstantQAtom.threshold(magnitudes: magnitudes, total: total, sparsity: sparsity)
            guard let threshold = thinning.threshold else {
                let bin = octave * geometry.binsPerOctave + row
                let found = "bin \(bin), at \(geometry.frequency(ofBin: bin)) Hz, keeps \(thinning.kept) of its kernel energy on the bins its row reads, less than \(ConstantQKernel.keptEnergyFloor)"
                let nyquist = geometry.sampleRate / 2
                // What is lost lies above the band the row reads, or folds over one of its ends.
                if beyond > 0.5 * (1 - thinning.kept) * total {
                    throw .invalidParameter(
                        stage: .none, parameter: "octaves",
                        reason: "\(found): it lies too close to \(HalfBand.cleanShare) of the Nyquist frequency of its octave (\(HalfBand.cleanShare * nyquist) Hz for the highest octave), above which the half-band decimators between the octaves neither pass the signal unchanged nor keep it free of aliases; lower fmin or octaves, or run the transform on a signal sampled faster")
                }
                if frequency > 0.25 {
                    throw .invalidParameter(
                        stage: .none, parameter: "octaves",
                        reason: "\(found): it lies too close to the Nyquist frequency, \(nyquist) Hz at this position, for the transform of its atom to fit below it; lower fmin or octaves, or run the transform on a signal sampled faster")
                }
                throw .invalidParameter(
                    stage: .none, parameter: "binsPerOctave",
                    reason: "\(found): its atom of \(atomLength) samples holds \(frequency * Double(atomLength)) periods, too few to tell the bin from its mirror image at negative frequencies; raise binsPerOctave or filterScale, or lower gamma")
            }
            var keptEnergy = 0.0
            for bin in 0 ..< readable where magnitudes[bin] >= threshold {
                columns.append(bin)
                real.append(Float(atomReal[bin] * scale))
                imaginary.append(Float(-atomImaginary[bin] * scale))
                keptEnergy += magnitudes[bin] * magnitudes[bin]
            }
            starts.append(columns.count)
            kept.append(min(keptEnergy / total, 1))
        }

        self.rowCount = lengths.count
        self.transformLength = length
        self.span = span
        self.center = center
        self.atomLengths = lengths
        self.rowStarts = starts
        self.columns = columns
        self.real = real
        self.imaginary = imaginary
        self.keptEnergy = kept
    }

    /// The longest atom a kernel is built for, in samples of the octave's own rate.
    static let longestAtom = 1 << 20

    /// Bins of the spectrum the kernel is applied to: `transformLength / 2 + 1`.
    public var columnCount: Int { transformLength / 2 + 1 }

    /// Entries kept, over all rows.
    public var nonZeroCount: Int { columns.count }

    /// The lowest and the highest bin any row reads.
    public var columnRange: ClosedRange<Int> {
        (columns.min() ?? 0) ... (columns.max() ?? 0)
    }

    /// The kernel as a dense matrix, row after row: `rowCount · columnCount` real parts and as many
    /// imaginary parts, zero where an entry was dropped. It allocates the two arrays it returns.
    public func dense() -> (real: [Float], imaginary: [Float]) {
        let bins = columnCount
        var denseReal = [Float](repeating: 0, count: rowCount * bins), denseImaginary = denseReal
        for row in 0 ..< rowCount {
            for index in rowStarts[row] ..< rowStarts[row + 1] {
                denseReal[row * bins + columns[index]] = real[index]
                denseImaginary[row * bins + columns[index]] = imaginary[index]
            }
        }
        return (denseReal, denseImaginary)
    }

    /// The constant-Q coefficients of one spectrum of `columnCount` bins: a one-shot product
    /// in double precision. It allocates, and is not for the analysis thread. Bins the
    /// spectrum does not have count as zero.
    public func applied(toReal spectrumReal: [Float], imaginary spectrumImaginary: [Float]) -> (real: [Float], imaginary: [Float]) {
        var resultReal = [Float](repeating: 0, count: rowCount), resultImaginary = resultReal
        let available = min(spectrumReal.count, spectrumImaginary.count)
        for row in 0 ..< rowCount {
            var sumReal = 0.0, sumImaginary = 0.0
            for index in rowStarts[row] ..< rowStarts[row + 1] where columns[index] < available {
                let a = Double(real[index]), b = Double(imaginary[index])
                let x = Double(spectrumReal[columns[index]]), y = Double(spectrumImaginary[columns[index]])
                sumReal += a * x - b * y
                sumImaginary += a * y + b * x
            }
            resultReal[row] = Float(sumReal)
            resultImaginary[row] = Float(sumImaginary)
        }
        return (resultReal, resultImaginary)
    }
}
