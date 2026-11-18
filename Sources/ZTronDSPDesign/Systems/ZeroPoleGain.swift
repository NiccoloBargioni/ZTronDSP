import ZTronDSPCore

/// A linear time-invariant system as its zeros, its poles and a gain:
///
///     H(x) = gain · Π (x − zerosᵢ) / Π (x − polesᵢ)
///
/// with `x = s` for an analog system and `x = z` for a digital one. This is the working form
/// of filter design (§6.3.1): prototypes, frequency transformations and the bilinear
/// transform all act on the roots, so a design never passes through polynomial coefficients
/// (REAL-1).
///
/// Construction never fails. A system with real coefficients has zeros and poles that are
/// real or come in conjugate pairs; the conversions that need this (to coefficients, to
/// sections) check it and throw. An immutable value, usable on any thread.
public struct ZeroPoleGain: LTISystem, Hashable, Sendable {
    /// The zeros, with their multiplicity. Usable on any thread.
    public let zeros: [Complex]
    /// The poles, with their multiplicity. Usable on any thread.
    public let poles: [Complex]
    /// The gain `k`. Usable on any thread.
    public let gain: Double
    /// The plane the roots lie in. Usable on any thread.
    public let domain: SystemDomain

    /// Usable on any thread.
    public init(zeros: [Complex], poles: [Complex], gain: Double, domain: SystemDomain) {
        self.zeros = zeros
        self.poles = poles
        self.gain = gain
        self.domain = domain
    }

    /// The number of poles in excess of the zeros: the number of zeros at infinity. Negative
    /// for an improper system. Usable on any thread.
    public var relativeDegree: Int { poles.count - zeros.count }

    /// True when the gain and every root are finite. Usable on any thread.
    public var isFinite: Bool {
        gain.isFinite && zeros.allSatisfy(\.isFinite) && poles.allSatisfy(\.isFinite)
    }

    // MARK: Conversions

    /// The coefficient form: the numerator `gain·Π(x − zᵢ)` over the monic denominator
    /// `Π(x − pᵢ)`, each conjugate pair multiplied out as one real quadratic.
    ///
    /// The expansion is ill-conditioned for clustered roots (§7.5, row 4): the coefficient
    /// form is for interchange, not for design and not for running. Control or background
    /// context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when a value is not finite or the zeros or poles
    ///   are not closed under conjugation.
    public func transferFunction() throws(DSPError) -> TransferFunction {
        guard gain.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "the gain must be finite, not \(gain)")
        }
        let zeroSplit = try ConjugatePairs.split(zeros, parameter: "zeros")
        let poleSplit = try ConjugatePairs.split(poles, parameter: "poles")
        let numerator = Self.expand(zeroSplit, leading: gain)
        let denominator = Self.expand(poleSplit, leading: 1)
        guard numerator.allSatisfy(\.isFinite), denominator.allSatisfy(\.isFinite) else {
            throw .unsupportedConfiguration(reason: "the coefficients of this system exceed the range of a double; keep it in zero-pole-gain form")
        }
        return TransferFunction(numerator: Polynomial(numerator), denominator: Polynomial(denominator), domain: domain)
    }

    /// `leading · Π(x − r)` over a split set of roots: one real quadratic per conjugate pair,
    /// one linear factor per real root.
    private static func expand(_ roots: (pairs: [Complex], reals: [Double]), leading: Double) -> [Double] {
        var product = [leading]
        for pair in roots.pairs {
            product = Polynomial.multiply(product, [1, -2 * pair.real, pair.squaredMagnitude])
        }
        for root in roots.reals {
            product = Polynomial.multiply(product, [1, -root])
        }
        return product
    }

    // MARK: Analysis

    /// The product over the zeros and poles, numerator and denominator factors alternating.
    /// Control or background context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        return LTIAnalysis.response(zeros: zeros, poles: poles, gain: gain, domain: domain, at: frequencies)
    }

    /// A sum over the zeros and poles; `nil` where the delay is undefined. Control or background
    /// context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        let response = try frequencyResponse(at: frequencies)
        let delays = LTIAnalysis.groupDelay(zeros: zeros, poles: poles, domain: domain, at: frequencies)
        return LTIAnalysis.masked(delays, by: response)
    }
}
