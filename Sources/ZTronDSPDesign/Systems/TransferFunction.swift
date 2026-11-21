import ZTronDSPCore

/// A linear time-invariant system as the coefficients of its numerator and denominator:
///
///     H(x) = numerator(x) / denominator(x)
///
/// both polynomials in `x`, highest power first, with `x = s` for an analog system and
/// `x = z` for a digital one. For a digital system whose two coefficient lists have the same
/// length this is also the difference-equation form in `z⁻¹`;
/// ``differenceEquation(b:a:rootFinder:)``
/// builds one from lists of different lengths.
///
/// The coefficient form exists for interchange and for parity with etk4j (§6.3.1). Its zeros
/// and poles have to be *found*, by the root finder named when the value is created, and
/// that step is ill-conditioned for clustered roots (§6.3.8): designs are kept in
/// `ZeroPoleGain` form and are never routed through this type.
///
/// One consequence: a pole that lies exactly on the unit circle (or the imaginary axis) is
/// found only to rounding, so `isStable` then turns on the last bit of the root. Judge
/// stability in zero-pole or section form, where such a pole is where it was put.
///
/// Construction never fails; a denominator that is zero is reported when the system is
/// analysed. An immutable value, usable on any thread; its analysis allocates (see
/// `LTISystem`).
public struct TransferFunction: LTISystem, Hashable, Sendable {
    /// The numerator. Usable on any thread.
    public let numerator: Polynomial
    /// The denominator. Usable on any thread.
    public let denominator: Polynomial
    /// The plane the polynomials are written in. Usable on any thread.
    public let domain: SystemDomain
    /// The strategy that finds the zeros and the poles, boxed for comparison. Usable on any
    /// thread.
    public let rootFinder: AnyStrategy

    /// Usable on any thread; it allocates only to box a root finder larger than three words, which
    /// the stock one is not.
    public init(
        numerator: Polynomial, denominator: Polynomial, domain: SystemDomain,
        rootFinder: some PolynomialRootFinder = .companionQR
    ) {
        self.numerator = numerator
        self.denominator = denominator
        self.domain = domain
        self.rootFinder = AnyStrategy(rootFinder)
    }

    /// From coefficient lists, highest power first. Leading zeros are dropped. Usable on any
    /// thread; it may allocate.
    public init(
        numerator: [Double], denominator: [Double], domain: SystemDomain,
        rootFinder: some PolynomialRootFinder = .companionQR
    ) {
        self.init(numerator: Polynomial(numerator), denominator: Polynomial(denominator), domain: domain, rootFinder: rootFinder)
    }

    /// The digital system of the difference equation
    /// `a₀·y[n] = Σ bₖ·x[n − k] − Σ_{k ≥ 1} aₖ·y[n − k]`: coefficients of `z⁻¹`, lowest delay
    /// first. The shorter list is padded with zeros at its end, which turns the two into
    /// polynomials in `z` of equal degree. Usable on any thread; it allocates the padded lists.
    public static func differenceEquation(
        b: [Double], a: [Double], rootFinder: some PolynomialRootFinder = .companionQR
    ) -> TransferFunction {
        let count = max(b.count, a.count)
        let numerator = b + [Double](repeating: 0, count: count - b.count)
        let denominator = a + [Double](repeating: 0, count: count - a.count)
        return TransferFunction(numerator: numerator, denominator: denominator, domain: .digital, rootFinder: rootFinder)
    }

    // MARK: Roots

    private func finder() throws(DSPError) -> any PolynomialRootFinder {
        guard let finder = rootFinder.value(as: (any PolynomialRootFinder).self) else {
            throw .invalidParameter(stage: .none, parameter: "rootFinder", reason: "the transfer function has no root finder")
        }
        return finder
    }

    private func requireDenominator() throws(DSPError) {
        guard !denominator.isZero else {
            throw .invalidParameter(stage: .none, parameter: "denominator", reason: "the denominator is zero")
        }
    }

    /// The roots of the numerator, found by the root finder. None for a numerator that is
    /// zero. Control or background context; allocates.
    public var zeros: [Complex] {
        get throws(DSPError) {
            try requireDenominator()
            if numerator.isZero { return [] }
            return try finder().roots(of: numerator)
        }
    }

    /// The roots of the denominator, found by the root finder. Control or background context;
    /// allocates.
    public var poles: [Complex] {
        get throws(DSPError) {
            try requireDenominator()
            return try finder().roots(of: denominator)
        }
    }

    /// The ratio of the two leading coefficients. Usable on any thread.
    public var gain: Double {
        get throws(DSPError) {
            try requireDenominator()
            return numerator.leadingCoefficient / denominator.leadingCoefficient
        }
    }

    /// The condition number of each zero with respect to the numerator's coefficients, in
    /// the order of ``zeros`` (§6.3.8). Control or background context; allocates.
    public var zeroConditions: [Double] {
        get throws(DSPError) {
            try requireDenominator()
            if numerator.isZero { return [] }
            return try finder().rootConditions(of: numerator)
        }
    }

    /// The condition number of each pole with respect to the denominator's coefficients, in
    /// the order of ``poles`` (§6.3.8). Control or background context; allocates.
    public var poleConditions: [Double] {
        get throws(DSPError) {
            try requireDenominator()
            return try finder().rootConditions(of: denominator)
        }
    }

    /// The zero-pole-gain form, through the root finder. Control or background context;
    /// allocates.
    public func zeroPoleGain() throws(DSPError) -> ZeroPoleGain {
        ZeroPoleGain(zeros: try zeros, poles: try poles, gain: try gain, domain: domain)
    }

    // MARK: Analysis

    /// The ratio of the two polynomials on the frequency axis, each by Horner's rule: no
    /// root is found.
    /// Control or background context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        try requireDenominator()
        return frequencies.map { frequency in
            let x = LTIAnalysis.point(frequency, domain)
            return LTIAnalysis.reported(numerator.evaluate(at: x) / denominator.evaluate(at: x))
        }
    }

    /// From the polynomials and their derivatives: `Re[w·D′/D] − Re[w·N′/N]`, with `w = z` on
    /// the unit circle and 1 on the imaginary axis. No root is found.
    /// Control or background context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        let response = try frequencyResponse(at: frequencies)
        let numeratorSlope = numerator.derivative
        let denominatorSlope = denominator.derivative
        let delays = frequencies.map { frequency -> Double in
            let x = LTIAnalysis.point(frequency, domain)
            let weight = domain == .digital ? x : Complex.one
            let poles = (weight * denominatorSlope.evaluate(at: x) / denominator.evaluate(at: x)).real
            let zeros = numerator.degree == 0 ? 0 : (weight * numeratorSlope.evaluate(at: x) / numerator.evaluate(at: x)).real
            return poles - zeros
        }
        return LTIAnalysis.masked(delays, by: response)
    }
}
