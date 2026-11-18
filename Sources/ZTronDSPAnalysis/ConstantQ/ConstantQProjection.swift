import Foundation
import ZTronDSPCore

/// The weights of the pseudo constant-Q transform over the bins of a linear-frequency
/// spectrum (§6.8): what `ConstantQScale` applies, as a table.
///
/// Band `k` weighs linear bin `b` by the magnitude of the response of the `k`-th constant-Q
/// atom at the bin's frequency, `|W(f_b − fₖ)| / W(0)` with `W` the transform of the atom's
/// window: 1 at the band's centre. For a spectrum of powers the weights are the squares of
/// those.
///
/// A band is kept as its first bin and a run of weights, as a mel band is. The run reaches
/// from the lowest to the highest bin that the thinning of a kernel row would keep
/// (`ConstantQAtom.threshold`), with every weight in between as it is.
///
/// The weights are computed in double precision and kept in single. An immutable value,
/// usable on any thread; creating it allocates and transforms, and is not for the analysis
/// thread.
struct ConstantQProjection: Hashable, Sendable {
    /// The weights of one band: bins `firstBin ..< firstBin + weights.count`.
    struct Band: Hashable, Sendable {
        let firstBin: Int
        let weights: [Float]
    }

    /// Bins of the spectrum the projection applies to.
    let binCount: Int
    let bands: [Band]

    /// - Parameters:
    ///   - geometry: the bins of the constant-Q axis, at the sample rate of the spectrum.
    ///   - binCount: bins of the spectrum, from 0 Hz to the Nyquist frequency: those of a
    ///     transform of `2 · (binCount − 1)` points, which must be a transform length.
    ///   - squared: true for the weights of a spectrum of powers.
    /// - Throws: `DSPError.invalidParameter` for an atom longer than the transform, a
    ///   transform that is no transform length, a window that cannot be sampled, and a band
    ///   that keeps less than `ConstantQKernel.keptEnergyFloor` of its response on the bins of
    ///   a one-sided spectrum.
    init(geometry: ConstantQGeometry, binCount: Int, window: Window, sparsity: Double, squared: Bool) throws(DSPError) {
        guard binCount >= 2 else {
            throw .invalidParameter(stage: .none, parameter: "binCount", reason: "a spectrum of \(binCount) bins has no bins to weigh")
        }
        guard sparsity >= 0, sparsity < 1 else {
            throw .invalidParameter(stage: .none, parameter: "sparsity", reason: "the sparsity is the share of a kernel row that may be dropped, from 0 up to but not 1, not \(sparsity)")
        }
        let length = 2 * (binCount - 1)
        var atoms = try ConstantQAtomTransform(length: length)
        var magnitudes = [Double](repeating: 0, count: atoms.binCount)
        var built: [Band] = []
        built.reserveCapacity(geometry.binCount)
        for bin in 0 ..< geometry.binCount {
            let atomLength = geometry.atomLength(ofBin: bin)
            let frequency = geometry.frequency(ofBin: bin) / geometry.sampleRate
            // Scaled by 1 / Σw: the response is 1 at the band's centre. A response does not
            // depend on where in the frame the atom lies.
            let energy = try atoms.transform(window: window, atomLength: atomLength, frequency: frequency, center: atomLength / 2, gain: 1)
            let real = atoms.real, imaginary = atoms.imaginary
            for index in 0 ..< magnitudes.count {
                magnitudes[index] = (real[index] * real[index] + imaginary[index] * imaginary[index]).squareRoot()
            }
            let thinning = ConstantQAtom.threshold(magnitudes: magnitudes, total: energy * Double(length), sparsity: sparsity)
            guard let threshold = thinning.threshold,
                  let first = magnitudes.firstIndex(where: { $0 >= threshold }), let last = magnitudes.lastIndex(where: { $0 >= threshold })
            else {
                throw .invalidParameter(
                    stage: .none, parameter: "binsPerOctave",
                    reason: "bin \(bin), at \(geometry.frequency(ofBin: bin)) Hz, keeps \(thinning.kept) of its response on the bins of a one-sided spectrum, less than \(ConstantQKernel.keptEnergyFloor): its atom of \(atomLength) samples holds \(frequency * Double(atomLength)) periods, too few to tell the bin from its mirror image; raise binsPerOctave or filterScale, lower gamma, or keep the bins away from 0 Hz and the Nyquist frequency")
            }
            built.append(Band(firstBin: first, weights: magnitudes[first ... last].map { Float(squared ? $0 * $0 : $0) }))
        }
        self.binCount = binCount
        bands = built
    }

    /// How many bands.
    var bandCount: Int { bands.count }

    /// The weights as a dense matrix, band after band: `bandCount · binCount` values.
    func denseWeights() -> [Float] {
        var result = [Float](repeating: 0, count: bands.count * binCount)
        for (index, band) in bands.enumerated() {
            for (offset, weight) in band.weights.enumerated() { result[index * binCount + band.firstBin + offset] = weight }
        }
        return result
    }

    /// The bands of one spectrum of `binCount` magnitudes or powers. A one-shot computation
    /// in double precision: it allocates, and is not for the analysis thread.
    func applied(to spectrum: [Float]) -> [Float] {
        bands.map { band in
            var sum = 0.0
            for (offset, weight) in band.weights.enumerated() where band.firstBin + offset < spectrum.count {
                sum += Double(weight) * Double(spectrum[band.firstBin + offset])
            }
            return Float(sum)
        }
    }
}
