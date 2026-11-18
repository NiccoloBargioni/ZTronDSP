import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// The weighted least-squares fit of a type I linear-phase FIR filter (odd length, symmetric
/// taps) to a piecewise-linear target (§6.3.3, §7.2 row 5; Parks & Burrus).
///
/// The amplitude response of such a filter is a cosine series, `A(ω) = Σ aₖ·cos(kω)`. The
/// integral of the weighted squared error over the bands is quadratic in the `aₖ`, with a
/// minimum at the solution of the normal equations `Q·a = b`, where
///
///     Q[k][l] = ∫ W(ω)·cos(kω)·cos(lω) dω        b[k] = ∫ W(ω)·D(ω)·cos(kω) dω
///
/// both in closed form for a weight that is constant and a target that is linear on each
/// band. `Q` is a Toeplitz plus a Hankel matrix of one sequence.
///
/// **Conditioning** (`Docs/Numerics/fir-design.md`). Where the bands cover the whole axis `Q`
/// is close to diagonal. Where they leave part of it unspecified, the cosines are no longer
/// independent over what is left and `Q` loses its rank in double precision: a Cholesky
/// factor then either does not exist, or it returns one of many solutions that fit the bands
/// equally well, with taps several times larger than they need be. So the solve is tested:
/// `dposv`, then `dpocon`; below a reciprocal condition number of 10⁻¹⁰ the system is solved
/// again by `dgelsd`, whose minimum-norm solution is well defined whatever the rank.
///
/// Oracle: `scipy.signal.firls`.
enum LeastSquaresFIR {
    /// One band of the target: its edges in units of the Nyquist frequency, the gains wanted
    /// at them (linear in between), and the weight of the error over the band.
    struct Band: Hashable, Sendable {
        let lower: Double
        let upper: Double
        let lowerGain: Double
        let upperGain: Double
        let weight: Double
    }

    /// The reciprocal condition number below which the Cholesky solution is not trusted.
    static let reciprocalConditionFloor = 1e-10
    /// The longest filter that is fitted: the system has (length + 1) / 2 unknowns and is
    /// dense.
    static let maximumLength = 4_095

    struct Fit {
        let taps: [Double]
        /// True when the normal equations were solved by `dgelsd`.
        let usedFallback: Bool
        /// `dpocon`'s estimate; `nil` when the matrix was not positive definite.
        let reciprocalCondition: Double?
    }

    /// The taps of the fit.
    ///
    /// - Parameter solver: `.tested` is the production path. The other two are hooks for the
    ///   tests that show what the condition test is for; production code never passes them.
    static func design(length: Int, bands: [Band], solver: Solver = .tested) throws(DSPError) -> Fit {
        guard length >= 1, length % 2 == 1, length <= maximumLength else {
            throw .invalidParameter(stage: .none, parameter: "length", reason: "a least-squares design has an odd number of taps between 1 and \(maximumLength) (a type I linear-phase filter), not \(length)")
        }
        guard !bands.isEmpty else {
            throw .invalidParameter(stage: .none, parameter: "bands", reason: "a least-squares design needs at least one band")
        }
        var previous = 0.0
        for band in bands {
            guard band.lower.isFinite, band.upper.isFinite, band.lower >= previous, band.upper > band.lower, band.upper <= 1 else {
                throw .invalidParameter(stage: .none, parameter: "bands", reason: "the bands must be ascending, each wider than 0 Hz, without overlap, between 0 Hz and the Nyquist frequency")
            }
            guard band.lowerGain.isFinite, band.upperGain.isFinite else {
                throw .invalidParameter(stage: .none, parameter: "desired", reason: "every wanted gain must be finite")
            }
            guard band.weight.isFinite, band.weight >= 0 else {
                throw .invalidParameter(stage: .none, parameter: "weights", reason: "a weight must be finite and not negative, not \(band.weight)")
            }
            previous = band.upper
        }
        guard bands.contains(where: { $0.weight > 0 }) else {
            throw .invalidParameter(stage: .none, parameter: "weights", reason: "at least one band needs a positive weight")
        }

        let half = (length - 1) / 2
        let order = half + 1

        // q(n) = Σ_bands W·[f·sinc(n·f)] between the band's edges.
        var q = [Double](repeating: 0, count: length)
        for n in 0 ..< length {
            var value = 0.0
            for band in bands where band.weight > 0 {
                value += band.weight * (band.upper * WindowedSincMethod.sinc(band.upper * Double(n))
                    - band.lower * WindowedSincMethod.sinc(band.lower * Double(n)))
            }
            q[n] = value
        }
        // Q = toeplitz(q[0…half]) + hankel(q[0…half], q[half…]), column by column.
        var matrix = [Double](repeating: 0, count: order * order)
        for column in 0 ..< order {
            for row in 0 ..< order {
                matrix[column * order + row] = q[abs(row - column)] + q[row + column]
            }
        }
        // b(n) = Σ_bands W·[f·(m·f + c)·sinc(n·f) + m·cos(nπf)/(πn)²], with the n = 0 limit −m·f²/2.
        var right = [Double](repeating: 0, count: order)
        for n in 0 ..< order {
            var value = 0.0
            for band in bands where band.weight > 0 {
                let slope = (band.upperGain - band.lowerGain) / (band.upper - band.lower)
                let offset = band.lowerGain - band.lower * slope
                func term(_ f: Double) -> Double {
                    var result = f * (slope * f + offset) * WindowedSincMethod.sinc(f * Double(n))
                    if n == 0 {
                        result -= slope * f * f / 2
                    } else {
                        let scale = Double.pi * Double(n)
                        result += slope * cos(Double(n) * Double.pi * f) / (scale * scale)
                    }
                    return result
                }
                value += band.weight * (term(band.upper) - term(band.lower))
            }
            right[n] = value
        }

        var coefficients: [Double]
        var usedFallback = false
        var reciprocal: Double?
        let cholesky = solver == .singularValuesOnly ? nil : try LAPACK.solvePositiveDefinite(matrix, order: order, rightHandSide: right)
        reciprocal = cholesky?.reciprocalCondition
        if let cholesky, solver == .choleskyOnly || cholesky.reciprocalCondition >= reciprocalConditionFloor {
            coefficients = cholesky.solution
        } else {
            guard solver != .choleskyOnly else {
                throw .numericalFailure(routine: "dposv", info: 1)
            }
            coefficients = try LAPACK.leastSquaresBySVD(matrix, rows: order, columns: order, rightHandSide: right).solution
            usedFallback = true
        }
        guard coefficients.allSatisfy(\.isFinite) else {
            throw .numericalFailure(routine: usedFallback ? "dgelsd" : "dposv", info: 0)
        }

        // The cosine series as symmetric taps: a[half] … a[1], 2·a[0], a[1] … a[half].
        var taps = [Double](repeating: 0, count: length)
        taps[half] = 2 * coefficients[0]
        for k in 1 ..< order {
            taps[half - k] = coefficients[k]
            taps[half + k] = coefficients[k]
        }
        return Fit(taps: taps, usedFallback: usedFallback, reciprocalCondition: reciprocal)
    }

    enum Solver: Hashable, Sendable {
        /// `dposv`, the condition test, then `dgelsd` where the test fails.
        case tested
        /// `dposv` alone, whatever its condition: the fit without its mitigation.
        case choleskyOnly
        /// `dgelsd` alone.
        case singularValuesOnly
    }

    /// The weighted squared error of `taps` against the target, integrated over the bands by
    /// the midpoint rule: what the fit minimises, for tests and for the stability note.
    static func weightedError(of taps: [Double], bands: [Band], pointsPerBand: Int = 2_000) -> Double {
        var total = 0.0
        for band in bands where band.weight > 0 {
            let step = (band.upper - band.lower) / Double(pointsPerBand)
            for index in 0 ..< pointsPerBand {
                let f = band.lower + (Double(index) + 0.5) * step
                let wanted = band.lowerGain + (band.upperGain - band.lowerGain) * (f - band.lower) / (band.upper - band.lower)
                let deviation = FIRMath.zeroPhaseAmplitude(of: taps, at: Double.pi * f) - wanted
                total += band.weight * deviation * deviation * step
            }
        }
        return total
    }
}
