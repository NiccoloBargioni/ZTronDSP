import Accelerate
import ZTronDSPCore
import ZTronDSPDesign

/// What a correlation is divided by (§6.7). With `r[ℓ] = Σₙ x[n + ℓ]·y[n]` the sum of the
/// products at lag `ℓ`:
///
/// | Case | Value | A reading |
/// |---|---|---|
/// | `.none` | `r[ℓ]` | The sum as it is. |
/// | `.biased` | `r[ℓ] / N` | `N` is the length of the longer input. The estimate of the correlation function whose variance is least; it falls off towards the ends, where fewer products are summed. |
/// | `.unbiased` | `r[ℓ] / (products at lag ℓ)` | Each lag divided by the number of products it sums: `N − |ℓ|` for inputs of one length. A lag without products is 0. |
/// | `.coefficient` | `r[ℓ] / √(Σx²·Σy²)` | Between −1 and 1; an autocorrelation reads 1 at lag 0. Where the denominator does not exceed the floor, every value is 0 (NUM-1). |
///
/// An immutable value, usable on any thread.
public enum CorrelationNormalization: Hashable, Sendable, CaseIterable {
    case none
    case biased
    case unbiased
    case coefficient
}

extension DSP {
    /// The least denominator a `.coefficient` normalisation divides by: the root of the
    /// product of the two energies, far below anything a signal that is not silence gives
    /// (two inputs of a hundred samples at an RMS level 220 dB under full scale just reach it).
    public static let correlationFloor: Double = 1e-20

    /// The cross-correlation of `x` and `y`: `r[ℓ] = Σₙ x[n + ℓ]·y[n]` for every lag at which
    /// the two overlap (§6.7).
    ///
    /// ```swift
    /// let r = try DSP.correlate(received, sent)                 // lags −(M − 1) … N − 1
    /// let delay = r.indices.max { r[$0] < r[$1] }! - (sent.count - 1)
    /// ```
    ///
    /// The full result has `N + M − 1` values; value `j` is lag `j − (M − 1)`, so lag 0 sits at
    /// index `M − 1`. It is the convolution of `x` with `y` back to front, and `mode` cuts it as
    /// it cuts a convolution.
    ///
    /// A one-shot computation: synchronous, it runs where it is called and allocates (§9.2).
    ///
    /// - Parameters:
    ///   - mode: which part of the result is returned; `.full` by default.
    ///   - normalization: `.none` by default.
    ///   - strategy: as for ``convolve(_:_:mode:strategy:crossovers:)``; the FFT method
    ///     conjugates the spectrum of `y`. Its floor is that of the sums: `.unbiased` divides
    ///     the sums of the outermost lags by one or two products and leaves the floor as it
    ///     is, so there the quotients are right to that floor and not to 10⁻⁶ of the largest
    ///     of them, unless the method is `.direct` (§7.5, row 10).
    ///   - floor: the least denominator `.coefficient` divides by.
    /// - Throws: `DSPError.invalidParameter` for an empty input, a floor that is negative or
    ///   not a number, or a result of more than 2²⁸ values;
    ///   `DSPError.resourceAllocationFailed` when a transform cannot be set up.
    public static func correlate(
        _ x: [Float], _ y: [Float], mode: ConvolutionMode = .full, normalization: CorrelationNormalization = .none,
        strategy: ConvolutionStrategy = .automatic, floor: Double = DSP.correlationFloor, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [Float] {
        try OneShotCorrelation.checkFloor(floor)
        var result = try OneShotConvolution.run(x, y, isCorrelation: true, mode: mode, strategy: strategy, crossovers: crossovers, names: ("x", "y"))
        let n = x.count, m = y.count
        let first = OneShotConvolution.span(mode, n, m).lowerBound
        switch normalization {
        case .none:
            break
        case .biased:
            OneShotCorrelation.scale(&result, by: 1 / Double(Swift.max(n, m)))
        case .unbiased:
            for index in result.indices {
                let lag = first + index - (m - 1)
                // The products at this lag: y[k]·x[k + lag] for every k both inputs hold.
                let products = Swift.min(m - 1, n - 1 - lag) - Swift.max(0, -lag) + 1
                result[index] = products > 0 ? Float(Double(result[index]) / Double(products)) : 0
            }
        case .coefficient:
            let denominator = (OneShotCorrelation.energy(x) * OneShotCorrelation.energy(y)).squareRoot()
            // 0/0 on silence: zeros, not a number that is none (NUM-1).
            OneShotCorrelation.scale(&result, by: denominator > floor && denominator.isFinite ? 1 / denominator : 0)
        }
        return result
    }

    /// The autocorrelation of `x`: `r[ℓ] = Σₙ x[n]·x[n + ℓ]` for the lags `0 … maxLag` (§6.7).
    /// An autocorrelation is even in the lag, so the negative lags are not returned.
    ///
    /// ```swift
    /// let r = try DSP.autocorrelate(frame, maxLag: 2_048, normalization: .coefficient)
    /// ```
    ///
    /// A one-shot computation: synchronous, it runs where it is called and allocates (§9.2).
    /// For a stream, the step is `Autocorrelation`.
    ///
    /// - Parameters:
    ///   - maxLag: the last lag returned; `nil`, the default, is `x.count − 1`, the last lag
    ///     that has a product. A lag past it is 0.
    ///   - normalization: `.none` by default. `.coefficient` divides by the value at lag 0.
    ///   - strategy: `.direct` sums the products; `.fft` and `.partitioned` use the
    ///     Wiener–Khinchin relation on the signal zero-padded to a fast length at or above
    ///     `N + maxLag`, so that the result is the linear autocorrelation and not the circular
    ///     one; `.automatic` chooses by the crossover of `crossovers`.
    ///   - floor: the least value at lag 0 that `.coefficient` divides by.
    /// - Returns: `maxLag + 1` values. With the Wiener–Khinchin relation each is right to the
    ///   floor of a single-precision transform under the value at lag 0, about 10⁻⁷ of it
    ///   (§7.5, row 11): a lag that should read 0 reads that much, with either sign.
    /// - Throws: `DSPError.invalidParameter` for an empty input, a negative `maxLag` or one
    ///   above 2²⁸, or a floor that is negative or not a number;
    ///   `DSPError.resourceAllocationFailed` when a transform cannot be set up.
    public static func autocorrelate(
        _ x: [Float], maxLag: Int? = nil, normalization: CorrelationNormalization = .none, strategy: ConvolutionStrategy = .automatic,
        floor: Double = DSP.correlationFloor, crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [Float] {
        try OneShotCorrelation.checkFloor(floor)
        guard !x.isEmpty else { throw .invalidParameter(stage: .none, parameter: "x", reason: "there is nothing to correlate: x is empty") }
        let n = x.count
        let last = maxLag ?? n - 1
        guard last >= 0, last <= OneShotConvolution.longestResult, n <= OneShotConvolution.longestResult else {
            throw .invalidParameter(stage: .none, parameter: "maxLag", reason: "the lags run from 0 to a last lag between 0 and \(OneShotConvolution.longestResult), not to \(last)")
        }
        // Lags that have a product; the rest are 0.
        let known = Swift.min(last, n - 1) + 1
        var result = [Float](repeating: 0, count: last + 1)
        if OneShotConvolution.method(strategy, n, known, crossovers: crossovers) == .direct {
            // C[ℓ] = Σₚ padded[ℓ + p]·x[p], the signal followed by zeros.
            var padded = [Float](repeating: 0, count: n + known - 1)
            padded.replaceSubrange(0 ..< n, with: x)
            padded.withUnsafeBufferPointer { source in
                x.withUnsafeBufferPointer { weights in
                    result.withUnsafeMutableBufferPointer { target in
                        guard let from = source.baseAddress, let taps = weights.baseAddress, let to = target.baseAddress else { return }
                        vDSP_conv(from, 1, taps, 1, to, 1, vDSP_Length(known), vDSP_Length(n))
                    }
                }
            }
        } else {
            let transform = try WienerKhinchin(frame: n, lagCount: known)
            x.withUnsafeBufferPointer { source in
                result.withUnsafeMutableBufferPointer { target in
                    guard let from = source.baseAddress, let to = target.baseAddress else { return }
                    transform.autocorrelate(from, into: to)
                }
            }
        }
        switch normalization {
        case .none:
            break
        case .biased:
            OneShotCorrelation.scale(&result, by: 1 / Double(n))
        case .unbiased:
            for lag in 0 ..< known { result[lag] = Float(Double(result[lag]) / Double(n - lag)) }
        case .coefficient:
            let energy = Double(result[0])
            OneShotCorrelation.scale(&result, by: energy > floor && energy.isFinite ? 1 / energy : 0)
        }
        return result
    }
}

/// What the correlations share.
enum OneShotCorrelation {
    static func checkFloor(_ floor: Double) throws(DSPError) {
        guard floor >= 0, floor.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "floor", reason: "the floor of a denominator is finite and not negative, not \(floor)")
        }
    }

    /// `Σ x²`, in double precision.
    static func energy(_ x: [Float]) -> Double {
        var sum = 0.0
        for value in x { sum += Double(value) * Double(value) }
        return sum
    }

    /// Every value times `factor`, the product taken in double precision. A factor of 0 gives
    /// zeros whatever the values are, values that are not numbers included.
    static func scale(_ values: inout [Float], by factor: Double) {
        guard factor != 0 else {
            for index in values.indices { values[index] = 0 }
            return
        }
        for index in values.indices { values[index] = Float(Double(values[index]) * factor) }
    }
}
