import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

extension DSP {
    /// The analog angular frequency, in radians per second, that the bilinear transform at
    /// `sampleRate` maps onto `hertz`: `2·fs·tan(π·f/fs)`.
    ///
    /// The bilinear transform compresses the whole analog axis into `0 … fs/2`; designing
    /// the analog filter at the pre-warped frequency puts the digital filter's edge exactly
    /// where it was asked for (§6.3.2). Usable on any thread; allocation-free.
    ///
    /// - Throws: `DSPError.invalidParameter` unless `0 ≤ hertz < sampleRate / 2` and the
    ///   sample rate is positive and finite.
    public static func prewarpedAngularFrequency(hertz: Double, sampleRate: Double) throws(DSPError) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        guard hertz.isFinite, hertz >= 0, hertz < sampleRate / 2 else {
            throw .invalidParameter(stage: .none, parameter: "hertz", reason: "\(hertz) Hz does not lie in 0 … \(sampleRate / 2) Hz, below the Nyquist frequency")
        }
        return 2 * sampleRate * tan(Double.pi * hertz / sampleRate)
    }
}

extension ZeroPoleGain {
    /// The digital system obtained by the bilinear transform `s → 2·fs·(z − 1)/(z + 1)`
    /// (Tustin's method), on the roots: `z = (2·fs + s)/(2·fs − s)`. Zeros at infinity move
    /// to the Nyquist frequency, `z = −1`, and the gain is adjusted so that the response at
    /// 0 Hz is unchanged.
    ///
    /// No frequency is pre-warped here: design the analog filter at
    /// `DSP.prewarpedAngularFrequency(hertz:sampleRate:)`. Oracle: `scipy.signal.bilinear_zpk`.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the system is not analog, has more zeros
    ///   than poles, the sample rate is not positive and finite, or a root lies at
    ///   `s = 2·fs`, which the transform sends to infinity.
    public func bilinear(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        guard domain == .analog else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the bilinear transform takes an analog system; this one is already digital")
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        let degree = relativeDegree
        guard degree >= 0 else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the system has \(zeros.count) zeros and only \(poles.count) poles: it is improper")
        }
        let twice = 2 * sampleRate
        let mappedZeros = zeros.map { (twice + $0) / (twice - $0) } + [Complex](repeating: Complex(-1), count: degree)
        let mappedPoles = poles.map { (twice + $0) / (twice - $0) }
        // Re[Π(2fs − z) / Π(2fs − p)], factors alternating.
        var ratio = Complex.one
        for index in 0 ..< max(zeros.count, poles.count) {
            if index < zeros.count { ratio = ratio * (twice - zeros[index]) }
            if index < poles.count { ratio = ratio / (twice - poles[index]) }
        }
        let result = ZeroPoleGain(zeros: mappedZeros, poles: mappedPoles, gain: gain * ratio.real, domain: .digital)
        guard result.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "a root at s = 2·fs has no image under the bilinear transform")
        }
        return result
    }
}

extension TransferFunction {
    /// The digital system obtained by the bilinear transform, on the coefficients: every
    /// power `sⁱ` becomes `(2·fs)ⁱ·(z − 1)ⁱ·(z + 1)^(M − i)`, with `M` the degree of the
    /// denominator, and the result is scaled so that its denominator is monic. Both lists of
    /// the result have `M + 1` coefficients, so it reads as powers of `z` or of `z⁻¹` alike.
    ///
    /// Provided for parity with etk4j's `BilinearTransform` and `scipy.signal.bilinear`. The
    /// expansion is ill-conditioned for all but small orders; transform the `ZeroPoleGain`
    /// when there is one. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the system is not analog, the denominator
    ///   is zero, the numerator's degree exceeds the denominator's, or the sample rate is
    ///   not positive and finite; `DSPError.unsupportedConfiguration` above degree 512 or
    ///   when the coefficients leave the range of a double.
    public func bilinear(sampleRate: Double) throws(DSPError) -> TransferFunction {
        guard domain == .analog else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the bilinear transform takes an analog system; this one is already digital")
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        guard !denominator.isZero else {
            throw .invalidParameter(stage: .none, parameter: "denominator", reason: "the denominator is zero")
        }
        let degree = denominator.degree
        guard numerator.degree <= degree else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the numerator has degree \(numerator.degree) and the denominator only \(degree): the system is improper")
        }
        guard degree <= CompanionQRRootFinder.maximumDegree else {
            throw .unsupportedConfiguration(reason: "the coefficient form of the bilinear transform is computed up to degree \(CompanionQRRootFinder.maximumDegree); this system has degree \(degree)")
        }

        // (z − 1)ⁱ·(z + 1)^(M − i) for i = 0 … M, each the product of two binomial expansions.
        var plusPowers: [[Double]] = [[1]]
        for power in 0 ..< degree { plusPowers.append(Polynomial.multiply(plusPowers[power], [1, 1])) }
        var basis: [[Double]] = []
        basis.reserveCapacity(degree + 1)
        var minusPower = [1.0]
        for power in 0 ... degree {
            basis.append(Polynomial.multiply(minusPower, plusPowers[degree - power]))
            minusPower = Polynomial.multiply(minusPower, [1, -1])
        }

        func substitute(_ polynomial: Polynomial) -> [Double] {
            var result = [Double](repeating: 0, count: degree + 1)
            let coefficients = polynomial.coefficients
            var scale = 1.0
            // Ascending powers of s: the coefficient of sⁱ is the i-th from the end.
            for power in 0 ... polynomial.degree {
                let coefficient = coefficients[coefficients.count - 1 - power] * scale
                if coefficient != 0 {
                    for position in 0 ... degree { result[position] += coefficient * basis[power][position] }
                }
                scale *= 2 * sampleRate
            }
            return result
        }
        let mappedNumerator = substitute(numerator)
        let mappedDenominator = substitute(denominator)
        let leading = mappedDenominator[0]
        guard leading != 0, leading.isFinite, mappedNumerator.allSatisfy(\.isFinite), mappedDenominator.allSatisfy(\.isFinite) else {
            throw .unsupportedConfiguration(reason: "the bilinear transform of these coefficients leaves the range of a double, or has a pole at infinity; transform the zero-pole-gain form instead")
        }
        guard let finder = rootFinder.value(as: (any PolynomialRootFinder).self) else {
            throw .invalidParameter(stage: .none, parameter: "rootFinder", reason: "the transfer function has no root finder")
        }
        return TransferFunction.digital(numerator: mappedNumerator.map { $0 / leading },
                                        denominator: mappedDenominator.map { $0 / leading }, finder: finder)
    }

    /// Opens the existential so that the generic initialiser can box the same finder again.
    private static func digital(numerator: [Double], denominator: [Double], finder: some PolynomialRootFinder) -> TransferFunction {
        TransferFunction(numerator: numerator, denominator: denominator, domain: .digital, rootFinder: finder)
    }
}
