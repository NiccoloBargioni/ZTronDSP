import Accelerate
import ZTronDSPCore

/// The arithmetic on taps that FIR design, FIR systems and their analysis share. Design
/// maths in double precision: control or background context.
enum FIRMath {
    /// `H(e^{jω}) = Σ h[n]·e^{−jωn}`, by Horner's rule in `z⁻¹`: the discrete-time Fourier
    /// transform of the taps, which at the frequencies of a zero-padded DFT is that DFT.
    static func response(of taps: [Double], at omega: Double) -> Complex {
        let delay = Complex(magnitude: 1, phase: -omega)
        var real = 0.0
        var imaginary = 0.0
        var index = taps.count - 1
        while index >= 0 {
            let nextReal = real * delay.real - imaginary * delay.imaginary + taps[index]
            imaginary = real * delay.imaginary + imaginary * delay.real
            real = nextReal
            index -= 1
        }
        return Complex(real, imaginary)
    }

    /// `Σ n·h[n]·e^{−jωn}`: the transform of the taps weighted by their delay, the numerator of
    /// the group delay `Re{DFT(n·h) / DFT(h)}`.
    static func rampedResponse(of taps: [Double], at omega: Double) -> Complex {
        let delay = Complex(magnitude: 1, phase: -omega)
        var real = 0.0
        var imaginary = 0.0
        var index = taps.count - 1
        while index >= 0 {
            let nextReal = real * delay.real - imaginary * delay.imaginary + Double(index) * taps[index]
            imaginary = real * delay.imaginary + imaginary * delay.real
            real = nextReal
            index -= 1
        }
        return Complex(real, imaginary)
    }

    /// The real amplitude of a symmetric filter with its linear phase removed:
    /// `A(ω) = Σ h[n]·cos((n − (K − 1)/2)·ω)`.
    static func zeroPhaseAmplitude(of taps: [Double], at omega: Double) -> Double {
        let centre = Double(taps.count - 1) / 2
        var sum = 0.0
        for (index, tap) in taps.enumerated() {
            sum += tap * cos((Double(index) - centre) * omega)
        }
        return sum
    }

    /// The taps of two filters in series: their convolution.
    static func convolve(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        Polynomial.multiply(lhs, rhs)
    }

    /// How far the taps are from the symmetry of a linear-phase filter, relative to their
    /// largest: `symmetric` for `h[n] = h[K − 1 − n]`, `antisymmetric` for
    /// `h[n] = −h[K − 1 − n]`.
    static func asymmetry(of taps: [Double]) -> (symmetric: Double, antisymmetric: Double) {
        let largest = taps.map { abs($0) }.max() ?? 0
        guard largest > 0 else { return (0, 0) }
        var symmetric = 0.0
        var antisymmetric = 0.0
        for index in 0 ..< taps.count {
            let mirrored = taps[taps.count - 1 - index]
            symmetric = max(symmetric, abs(taps[index] - mirrored))
            antisymmetric = max(antisymmetric, abs(taps[index] + mirrored))
        }
        return (symmetric / largest, antisymmetric / largest)
    }

    /// The relative tolerance within which taps count as symmetric or antisymmetric: design
    /// rounding, far below what Float32 taps resolve.
    static let symmetryTolerance = 1e-9

    /// True for taps that are symmetric or antisymmetric about their middle: a linear-phase
    /// filter (§6.3.8).
    static func isLinearPhase(_ taps: [Double]) -> Bool {
        let measure = asymmetry(of: taps)
        return measure.symmetric <= symmetryTolerance || measure.antisymmetric <= symmetryTolerance
    }

    /// The taps without the zeros at their ends: what the filter is once its pure delay and
    /// its unused tail are set aside. `leading` is the number of zeros removed at the front.
    static func trimmed(_ taps: [Double]) -> (taps: [Double], leading: Int) {
        guard let first = taps.firstIndex(where: { $0 != 0 }), let last = taps.lastIndex(where: { $0 != 0 }) else {
            return ([], 0)
        }
        return (Array(taps[first ... last]), first)
    }

    /// `|H|` on a grid of `points / 2 + 1` frequencies from 0 Hz to the Nyquist frequency,
    /// evenly spaced, by one transform of the zero-padded taps. `points` is a power of two of
    /// at least sixteen times the number of taps (and at least 4 096), capped at 2²².
    ///
    /// - Throws: `DSPError.resourceAllocationFailed` when the transform cannot be set up.
    static func magnitudeGrid(of taps: [Double]) throws(DSPError) -> [Double] {
        var points = 4_096
        while points < 16 * taps.count, points < 1 << 22 { points *= 2 }
        while points < taps.count { points *= 2 }
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(points), .FORWARD) else {
            throw .resourceAllocationFailed(what: "a transform of \(points) points")
        }
        defer { vDSP_DFT_DestroySetupD(setup) }
        var inputReal = taps + [Double](repeating: 0, count: points - taps.count)
        var inputImaginary = [Double](repeating: 0, count: points)
        var outputReal = [Double](repeating: 0, count: points)
        var outputImaginary = [Double](repeating: 0, count: points)
        vDSP_DFT_ExecuteD(setup, &inputReal, &inputImaginary, &outputReal, &outputImaginary)
        var magnitudes = [Double](repeating: 0, count: points / 2 + 1)
        for bin in 0 ... points / 2 {
            magnitudes[bin] = (outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin]).squareRoot()
        }
        return magnitudes
    }

    /// The least and the greatest `|H|` over a band given in units of the Nyquist frequency:
    /// the grid points inside it, and the band's two edges evaluated exactly.
    static func extremes(of taps: [Double], grid: [Double], from lower: Double, to upper: Double) -> (least: Double, greatest: Double) {
        var least = Double.infinity
        var greatest = 0.0
        for edge in [lower, upper] {
            let value = response(of: taps, at: Double.pi * edge).magnitude
            least = min(least, value)
            greatest = max(greatest, value)
        }
        let bins = grid.count - 1
        let first = Int((lower * Double(bins)).rounded(.up))
        let last = Int((upper * Double(bins)).rounded(.down))
        if first <= last {
            for bin in max(first, 0) ... min(last, bins) {
                least = min(least, grid[bin])
                greatest = max(greatest, grid[bin])
            }
        }
        return (least, greatest)
    }
}
