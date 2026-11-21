import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// What a Savitzky–Golay filter does where its window reaches past the ends of the signal
/// (§6.3.6). Every mode of etk4j's `SavitzkyGolayFilter.Mode` is here (Appendix A).
///
/// An immutable value, usable on any thread; it does not allocate.
public enum SavitzkyGolayEdge: Hashable, Sendable {
    /// No padding: the values within half a window of an end are read off the polynomial
    /// fitted to the first, or the last, whole window.
    case interpolate
    /// The signal is reflected about its end samples, which are not repeated:
    /// `x[−k] = x[k]`.
    case mirror
    /// The end samples are repeated: `x[−k] = x[0]`.
    case nearest
    /// The signal is continued with one value.
    case constant(Float)
    /// The signal is continued with itself, as one period of a periodic signal:
    /// `x[−k] = x[N − k]`.
    case wrap
}

extension DSP {
    /// The coefficients of a Savitzky–Golay filter (Savitzky & Golay 1964): the FIR filter
    /// whose output is the value, or the `derivative`-th derivative, at the middle of the
    /// window, of the polynomial of degree `polynomialOrder` that fits the `window` samples
    /// under it best in the least-squares sense (§6.3.6).
    ///
    /// The coefficients are in convolution order, `y[n] = Σ c[k]·x[n + (window − 1)/2 − k]`,
    /// and are those of `scipy.signal.savgol_coeffs` with a sample spacing of 1: a derivative
    /// is taken with respect to the sample index. A derivative above the polynomial order is
    /// identically zero.
    ///
    /// The fit is solved by an orthogonal factorisation (LAPACK `dgels`) on an abscissa
    /// scaled to −1 … 1, never through the normal equations
    /// (`Docs/Numerics/savitzky-golay.md`). Control or background context; allocates.
    ///
    /// - Parameters:
    ///   - window: The number of samples under the fit: odd, so that the window has a middle
    ///     sample and the filter a whole delay.
    ///   - polynomialOrder: The degree of the polynomial: below `window`.
    ///   - derivative: 0 smooths; `d` gives the `d`-th derivative.
    /// - Throws: `DSPError.invalidParameter` for a window that is even, below 1 or above
    ///   ``savitzkyGolayMaximumWindow``, a polynomial order that is negative or not below the
    ///   window, and a negative derivative; `DSPError.numericalFailure` when LAPACK reports
    ///   a fit without full rank.
    public static func savitzkyGolayCoefficients(window: Int, polynomialOrder: Int, derivative: Int = 0) throws(DSPError) -> [Double] {
        try SavitzkyGolayFit.validate(window: window, polynomialOrder: polynomialOrder, derivative: derivative)
        // In convolution order the newest sample comes first: the fit's coefficients reversed.
        return try SavitzkyGolayFit.weights(window: window, polynomialOrder: polynomialOrder, derivative: derivative, position: (window - 1) / 2).reversed()
    }

    /// The widest Savitzky–Golay window that is designed. A constant, usable on any thread; it
    /// does not allocate.
    public static let savitzkyGolayMaximumWindow = 65_535

    /// A signal smoothed, or differentiated, by a Savitzky–Golay filter: the offline twin of
    /// the `SavitzkyGolay` stage (§6.3.6).
    ///
    /// Output sample `n` is the value at `n` of the polynomial fitted to the window centred
    /// on `n`; nothing is delayed. `edge` says what the window holds where it reaches past
    /// the ends. The arithmetic is in double precision and the result is rounded to Float32.
    /// Oracle: `scipy.signal.savgol_filter`. Runs where it is called and allocates: not for
    /// the analysis thread.
    ///
    /// - Throws: what ``savitzkyGolayCoefficients(window:polynomialOrder:derivative:)``
    ///   throws; `DSPError.invalidParameter` for `.interpolate` on a signal shorter than the
    ///   window, and for a constant that is not finite.
    public static func savitzkyGolay(
        _ samples: [Float], window: Int, polynomialOrder: Int, derivative: Int = 0, edge: SavitzkyGolayEdge = .interpolate
    ) throws(DSPError) -> [Float] {
        let coefficients = try savitzkyGolayCoefficients(window: window, polynomialOrder: polynomialOrder, derivative: derivative)
        let count = samples.count
        let half = (window - 1) / 2
        guard count > 0 else { return [] }
        if case .constant(let value) = edge, !value.isFinite {
            throw .invalidParameter(stage: .none, parameter: "edge", reason: "the constant a signal is continued with must be finite, not \(value)")
        }
        if edge == .interpolate, window > count {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "with `.interpolate` the window (\(window)) must not be longer than the signal (\(count) samples)")
        }

        /// The sample at `index`, which may lie outside the signal.
        func sample(_ index: Int) -> Double {
            if index >= 0, index < count { return Double(samples[index]) }
            switch edge {
            case .interpolate:
                return 0
            case .constant(let value):
                return Double(value)
            case .nearest:
                return Double(samples[index < 0 ? 0 : count - 1])
            case .mirror:
                guard count > 1 else { return Double(samples[0]) }
                // Reflection without repeating the end samples has the period 2·(count − 1).
                let period = 2 * (count - 1)
                var folded = index % period
                if folded < 0 { folded += period }
                return Double(samples[folded < count ? folded : period - folded])
            case .wrap:
                var folded = index % count
                if folded < 0 { folded += count }
                return Double(samples[folded])
            }
        }

        var output = [Float](repeating: 0, count: count)
        for n in 0 ..< count {
            var sum = 0.0
            for k in 0 ..< window {
                sum += coefficients[k] * sample(n + half - k)
            }
            output[n] = Float(sum)
        }

        if edge == .interpolate, half > 0 {
            // The first and the last half window: the polynomial of the first, or the last,
            // whole window, read off at each of those positions.
            for position in 0 ..< half {
                let leading = try SavitzkyGolayFit.weights(window: window, polynomialOrder: polynomialOrder, derivative: derivative, position: position)
                var head = 0.0
                var tail = 0.0
                for index in 0 ..< window {
                    head += leading[index] * Double(samples[index])
                    // The fit at `window − 1 − position` is the mirror image of the fit at
                    // `position`, with the sign of an odd derivative reversed.
                    tail += leading[index] * Double(samples[count - 1 - index])
                }
                output[position] = Float(head)
                output[count - 1 - position] = Float(derivative % 2 == 0 ? tail : -tail)
            }
        }
        return output
    }
}

/// The least-squares polynomial fit behind the Savitzky–Golay filter (WP-426).
enum SavitzkyGolayFit {
    static func validate(window: Int, polynomialOrder: Int, derivative: Int) throws(DSPError) {
        guard window >= 1, window % 2 == 1, window <= DSP.savitzkyGolayMaximumWindow else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "a Savitzky–Golay window is odd and lies in 1 … \(DSP.savitzkyGolayMaximumWindow), not \(window)")
        }
        guard polynomialOrder >= 0, polynomialOrder < window else {
            throw .invalidParameter(stage: .none, parameter: "polynomialOrder", reason: "the polynomial order (\(polynomialOrder)) must be at least 0 and below the window (\(window)): a polynomial of that degree or more passes through every sample and smooths nothing")
        }
        guard derivative >= 0 else {
            throw .invalidParameter(stage: .none, parameter: "derivative", reason: "the order of a derivative is not negative, not \(derivative)")
        }
    }

    /// The weights `w` with which the samples of one window give the `derivative`-th
    /// derivative, at the sample `position` of the window, of the polynomial fitted to them:
    /// `value = Σ w[i]·x[i]`, with `i` counted from the window's first sample.
    ///
    /// The weights are the minimum-norm solution of the `(order + 1) × window` system
    /// `Σᵢ w[i]·tᵢᵏ = d!·δ(k, d) / sᵈ`, with the abscissa `tᵢ = (i − position) / s` scaled by
    /// the largest distance `s` in the window, so that every `tᵢ` lies in −1 … 1 and no power
    /// of it leaves the range of a double.
    ///
    /// - Parameters:
    ///   - scaled: `false` leaves the abscissa as it is (`s = 1`).
    ///   - normalEquations: `true` solves `(A·Aᵀ)·z = y`, `w = Aᵀ·z` by Cholesky factorisation
    ///     instead of factorising `A` itself: the route that squares the condition number.
    ///     Both are hooks for the stress test that shows what the method is for; production
    ///     code never passes them.
    static func weights(
        window: Int, polynomialOrder: Int, derivative: Int, position: Int, scaled: Bool = true, normalEquations: Bool = false
    ) throws(DSPError) -> [Double] {
        guard derivative <= polynomialOrder else { return [Double](repeating: 0, count: window) }
        let rows = polynomialOrder + 1
        let scale = scaled ? Double(max(position, window - 1 - position, 1)) : 1
        // Column i holds the powers 0 … order of tᵢ.
        var matrix = [Double](repeating: 0, count: rows * window)
        for index in 0 ..< window {
            let t = Double(index - position) / scale
            var power = 1.0
            for row in 0 ..< rows {
                matrix[index * rows + row] = power
                power *= t
            }
        }
        var right = [Double](repeating: 0, count: rows)
        var factorial = 1.0
        if derivative > 1 {
            for factor in 2 ... derivative { factorial *= Double(factor) }
        }
        right[derivative] = factorial / pow(scale, Double(derivative))
        guard matrix.allSatisfy(\.isFinite), right[derivative].isFinite else {
            throw .numericalFailure(routine: "dgels", info: 0)
        }
        let weights: [Double]
        if normalEquations {
            var gram = [Double](repeating: 0, count: rows * rows)
            for column in 0 ..< rows {
                for row in 0 ..< rows {
                    var sum = 0.0
                    for index in 0 ..< window { sum += matrix[index * rows + row] * matrix[index * rows + column] }
                    gram[column * rows + row] = sum
                }
            }
            guard let solved = try LAPACK.solvePositiveDefinite(gram, order: rows, rightHandSide: right) else {
                throw .numericalFailure(routine: "dposv", info: 1)
            }
            weights = (0 ..< window).map { index in
                var sum = 0.0
                for row in 0 ..< rows { sum += matrix[index * rows + row] * solved.solution[row] }
                return sum
            }
        } else {
            weights = try LAPACK.solveByOrthogonalFactorization(matrix, rows: rows, columns: window, rightHandSide: right)
        }
        guard weights.allSatisfy(\.isFinite) else {
            throw .numericalFailure(routine: "dgels", info: 0)
        }
        return weights
    }
}
