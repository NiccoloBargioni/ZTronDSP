import Accelerate
import ZTronDSPCore
import ZTronDSPDesign

/// Which part of a convolution or a correlation is returned (§6.7). With `N` and `K` the
/// lengths of the two inputs:
///
/// | Mode | Values | Which |
/// |---|---|---|
/// | `.full` | `N + K − 1` | Every value in which the two overlap by at least one sample. |
/// | `.same` | `N` | The middle of the full result, as long as the first input: its values from index `(K − 1) / 2` on (rounded down). |
/// | `.valid` | `max(N, K) − min(N, K) + 1` | The values in which the shorter input lies wholly inside the longer one: no value rests on a sample that is not there. |
///
/// An immutable value, usable on any thread; it does not allocate.
public enum ConvolutionMode: Hashable, Sendable, CaseIterable {
    /// Every value in which the two inputs overlap: `N + K − 1` values.
    case full
    /// The middle of the full result, as long as the first input.
    case same
    /// The values in which the shorter input lies wholly inside the longer one.
    case valid
}

extension DSP {
    /// The convolution of `x` and `h`: `(x ∗ h)[n] = Σₖ h[k]·x[n − k]` (§6.7).
    ///
    /// ```swift
    /// let wet = try DSP.convolve(dry, impulseResponse)                       // N + K − 1 values
    /// let smoothed = try DSP.convolve(track, [0.25, 0.5, 0.25], mode: .same) // as long as track
    /// ```
    ///
    /// A one-shot computation: synchronous, it runs where it is called, on any thread, and
    /// allocates (§9.2); with a long input, call it off the main thread. For a stream, the
    /// stage is `Convolve`.
    ///
    /// - Parameters:
    ///   - x: the signal, `N` values.
    ///   - h: the kernel, `K` values.
    ///   - mode: which part of the result is returned; `.full` by default.
    ///   - strategy: `.direct` is `vDSP_conv`; `.fft` multiplies the spectra of the two inputs,
    ///     zero-padded to a fast length at or above `N + K − 1`; `.partitioned` runs the
    ///     partitioned kernel of the streaming stage over the signal, which keeps every
    ///     transform as short as twice the kernel; `.automatic`, the default, takes the direct
    ///     method below the crossover of `crossovers` and the FFT method above it, and the
    ///     partitioned one where a single transform would exceed 2²² points.
    ///   - crossovers: the measured crossovers `.automatic` follows (§7.4).
    /// - Returns: the values `mode` names. The methods agree within the floor of a
    ///   single-precision transform: under 10⁻⁶ of the largest value the two inputs can give,
    ///   the largest sample of `x` times the sum of the magnitudes of `h`. That is about the
    ///   largest value of the result, unless the values of `h` cancel, as those of a difference
    ///   do. A value far below it is known only to that floor unless the method is `.direct`,
    ///   which has every value to a few units in the last place of the sum of its own products
    ///   (§7.5, row 10). A sample that is not a number spreads to every value it reaches.
    /// - Throws: `DSPError.invalidParameter` for an empty input or a result of more than 2²⁸
    ///   values; `DSPError.resourceAllocationFailed` when a transform cannot be set up.
    public static func convolve(
        _ x: [Float], _ h: [Float], mode: ConvolutionMode = .full, strategy: ConvolutionStrategy = .automatic,
        crossovers: CrossoverTable = .shipped
    ) throws(DSPError) -> [Float] {
        try OneShotConvolution.run(x, h, isCorrelation: false, mode: mode, strategy: strategy, crossovers: crossovers, names: ("x", "h"))
    }
}

/// The one-shot convolution and correlation behind `DSP.convolve` and `DSP.correlate`
/// (WP-513, WP-514; §7.2 row 10). With `x` of `N` and `y` of `M` values, the full result has
/// `N + M − 1` values, numbered from 0:
///
///     convolution   full[j] = Σₘ y[m]·x[j − m]
///     correlation   full[j] = Σₘ y[m]·x[j − (M − 1) + m]        (lag j − (M − 1))
///
/// Control or background context: everything here allocates.
enum OneShotConvolution {
    /// The longest result that is computed.
    static let longestResult = 1 << 28
    /// The longest single transform `.automatic` asks for; past it, the partitioned method.
    static let longestTransform = 1 << 22

    /// The values of the full result a mode keeps.
    static func span(_ mode: ConvolutionMode, _ n: Int, _ m: Int) -> Range<Int> {
        switch mode {
        case .full: return 0 ..< n + m - 1
        case .same: return (m - 1) / 2 ..< (m - 1) / 2 + n
        case .valid: return Swift.min(n, m) - 1 ..< Swift.max(n, m)
        }
    }

    /// The method a strategy comes to for inputs of `n` and `m` values.
    static func method(_ strategy: ConvolutionStrategy, _ n: Int, _ m: Int, crossovers: CrossoverTable) -> ConvolutionStrategy {
        guard strategy == .automatic else { return strategy }
        guard crossovers.convolutionUsesFFT(n, m) else { return .direct }
        return DSP.nextFastLength(n + m - 1) <= longestTransform ? .fft : .partitioned
    }

    static func run(
        _ x: [Float], _ y: [Float], isCorrelation: Bool, mode: ConvolutionMode, strategy: ConvolutionStrategy, crossovers: CrossoverTable,
        names: (String, String)
    ) throws(DSPError) -> [Float] {
        let what = isCorrelation ? "correlate" : "convolve"
        guard !x.isEmpty else { throw .invalidParameter(stage: .none, parameter: names.0, reason: "there is nothing to \(what): \(names.0) is empty") }
        guard !y.isEmpty else { throw .invalidParameter(stage: .none, parameter: names.1, reason: "there is nothing to \(what): \(names.1) is empty") }
        let n = x.count, m = y.count
        guard n <= longestResult, m <= longestResult, n + m - 1 <= longestResult else {
            throw .invalidParameter(stage: .none, parameter: names.0, reason: "a result of \(n) + \(m) − 1 values is longer than the \(longestResult) that are computed in one piece")
        }
        let kept = span(mode, n, m)
        switch method(strategy, n, m, crossovers: crossovers) {
        case .direct, .automatic:
            return direct(x, y, isCorrelation: isCorrelation, keeping: kept)
        case .fft:
            return Array(try transformed(x, y, isCorrelation: isCorrelation)[kept])
        case .partitioned:
            // A correlation is the convolution with the second input reversed.
            return Array(try partitioned(x, isCorrelation ? Array(y.reversed()) : y)[kept])
        }
    }

    // MARK: The direct method

    /// `vDSP_conv` over the longer input, padded with zeros so that every value of `kept`
    /// has all its products; only those values of the full result are computed.
    static func direct(_ x: [Float], _ y: [Float], isCorrelation: Bool, keeping kept: Range<Int>) -> [Float] {
        let n = x.count, m = y.count
        var result = [Float](repeating: 0, count: kept.count)
        guard !kept.isEmpty else { return result }
        // The filter is the shorter input: one output costs as many products as it has taps.
        let xIsSignal = n >= m
        let signal = xIsSignal ? x : y, filter = xIsSignal ? y : x
        let taps = filter.count
        var padded = [Float](repeating: 0, count: signal.count + 2 * (taps - 1))
        padded.replaceSubrange(taps - 1 ..< taps - 1 + signal.count, with: signal)

        // What vDSP_conv computes is C[i] = Σₚ padded[i + p]·F[p], with F the filter as it is
        // or, for a negative stride, back to front.
        //   convolution                   full[j] = C[j], F back to front
        //   correlation, x the signal     full[j] = C[j], F = y as it is
        //   correlation, y the signal     full[j] = C[n + m − 2 − j], F = x as it is
        let mirrored = isCorrelation && !xIsSignal
        let first = mirrored ? n + m - 2 - (kept.upperBound - 1) : kept.lowerBound
        padded.withUnsafeBufferPointer { source in
            filter.withUnsafeBufferPointer { kernel in
                result.withUnsafeMutableBufferPointer { target in
                    guard let from = source.baseAddress, let weights = kernel.baseAddress, let to = target.baseAddress else { return }
                    if isCorrelation {
                        vDSP_conv(from + first, 1, weights, 1, to, 1, vDSP_Length(kept.count), vDSP_Length(taps))
                    } else {
                        vDSP_conv(from + first, 1, weights + (taps - 1), -1, to, 1, vDSP_Length(kept.count), vDSP_Length(taps))
                    }
                }
            }
        }
        if mirrored { result.reverse() }
        return result
    }

    // MARK: The FFT method

    /// The full result by one transform of a fast length at or above `N + M − 1`: the product
    /// of the two spectra, the second one conjugated for a correlation.
    static func transformed(_ x: [Float], _ y: [Float], isCorrelation: Bool) throws(DSPError) -> [Float] {
        let n = x.count, m = y.count, count = n + m - 1
        let length = DSP.nextFastLength(count)
        let plan = try VDSPFFTPlan(length: length)
        let bins = length / 2 + 1
        let first = try AlignedBuffer<Float>(count: length), second = try AlignedBuffer<Float>(count: length)
        let firstReal = try AlignedBuffer<Float>(count: bins), firstImaginary = try AlignedBuffer<Float>(count: bins)
        let secondReal = try AlignedBuffer<Float>(count: bins), secondImaginary = try AlignedBuffer<Float>(count: bins)
        let productReal = try AlignedBuffer<Float>(count: bins), productImaginary = try AlignedBuffer<Float>(count: bins)
        x.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { first.copy(from: base, count: n) }
        }
        y.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { second.copy(from: base, count: m) }
        }
        plan.forward(first.baseAddress, real: firstReal.baseAddress, imaginary: firstImaginary.baseAddress)
        plan.forward(second.baseAddress, real: secondReal.baseAddress, imaginary: secondImaginary.baseAddress)

        var signal = DSPSplitComplex(realp: firstReal.baseAddress, imagp: firstImaginary.baseAddress)
        var other = DSPSplitComplex(realp: secondReal.baseAddress, imagp: secondImaginary.baseAddress)
        var product = DSPSplitComplex(realp: productReal.baseAddress, imagp: productImaginary.baseAddress)
        // vDSP_zvmul conjugates its first operand when asked: conj(Y)·X is the spectrum of the
        // correlation, Y·X that of the convolution.
        vDSP_zvmul(&other, 1, &signal, 1, &product, 1, vDSP_Length(bins), isCorrelation ? -1 : 1)
        plan.inverse(real: productReal.baseAddress, imaginary: productImaginary.baseAddress, into: first.baseAddress)

        var result = [Float](repeating: 0, count: count)
        let circular = first.baseAddress
        if isCorrelation {
            // Lag ℓ sits at ℓ modulo the transform length; the full result starts at lag −(M − 1).
            for index in 0 ..< count {
                let lag = index - (m - 1)
                result[index] = circular[lag >= 0 ? lag : lag + length]
            }
        } else {
            for index in 0 ..< count { result[index] = circular[index] }
        }
        return result
    }

    // MARK: The partitioned method

    /// The shortest and the longest partition the one-shot method gives the kernel.
    static let partitionRange = 64 ... 1 << 16

    /// The full convolution by the partitioned kernel of the streaming stage (WP-215), run
    /// over the longer input followed by as many zeros as the result is longer than it.
    static func partitioned(_ x: [Float], _ y: [Float]) throws(DSPError) -> [Float] {
        let xIsSignal = x.count >= y.count
        let signal = xIsSignal ? x : y, taps = xIsSignal ? y : x
        var partition = partitionRange.lowerBound
        while partition < taps.count, partition < partitionRange.upperBound { partition *= 2 }
        var kernel = ztd_partitioned_create(1, taps, UInt32(taps.count), UInt32(partition), 0)
        defer { ztd_kernel_destroy(&kernel) }
        guard !ztd_kernel_is_null(&kernel), let process = kernel.process else {
            throw .resourceAllocationFailed(what: "a partitioned kernel of \(taps.count) taps")
        }
        let count = signal.count + taps.count - 1
        var input = [Float](repeating: 0, count: count)
        input.replaceSubrange(0 ..< signal.count, with: signal)
        var result = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let to = target.baseAddress else { return }
                var position = 0
                while position < count {
                    let frames = Swift.min(partition, count - position)
                    var inputChannel: UnsafePointer<Float>? = from + position
                    var outputChannel: UnsafeMutablePointer<Float>? = to + position
                    withUnsafePointer(to: &inputChannel) { inputs in
                        withUnsafePointer(to: &outputChannel) { outputs in
                            _ = process(kernel.state, inputs, outputs, 1, UInt32(frames))
                        }
                    }
                    position += frames
                }
            }
        }
        return result
    }
}
