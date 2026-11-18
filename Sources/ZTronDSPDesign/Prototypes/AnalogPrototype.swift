import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// How a Bessel prototype is scaled in frequency (§6.3.2).
///
/// An immutable value, usable on any thread.
public enum BesselNormalization: Hashable, Sendable {
    /// The phase reaches the middle of its range at 1 rad/s, and the asymptotes of the
    /// magnitude are those of a Butterworth filter of the same order. The default, and
    /// MATLAB's convention.
    case phase
    /// The group delay in the pass band is 1 s: the natural form of the Bessel polynomial.
    case delay
    /// The magnitude is −3 dB at 1 rad/s.
    case magnitude
}

/// The analog low-pass prototypes of the classical filter families (§6.3.2): each is a
/// `ZeroPoleGain` in the `s` plane whose edge sits at 1 rad/s. A filter is made from one by a
/// frequency transformation and, for a digital filter, the bilinear transform.
///
/// The prototypes are those of etk4j and `scipy.signal` (Appendix A), to within 10⁻⁹.
///
/// A ripple or an attenuation is an `Amplification`, read as a number of decibels whatever
/// its sign: `.decibels(1)` and `.decibels(-1)` both mean a ripple of 1 dB, and `.linear(0.01)`
/// an attenuation of 40 dB.
///
/// Pure functions returning immutable values. Design maths: they allocate, so they belong on
/// a control or background context, not on the analysis thread.
public enum AnalogPrototype {
    /// The highest order a prototype is computed for. Usable on any thread.
    public static let maximumOrder = 512

    /// The smallest `1 − k²` an elliptic prototype is designed for: 64 ε, a transition band
    /// 32 units of the last place wide.
    static let smallestEllipticComplement = 64 * Double.ulpOfOne

    /// The Butterworth prototype: `order` poles equally spaced on the left half of the unit
    /// circle, no zeros, gain 1. The magnitude is maximally flat and −3 dB at 1 rad/s.
    /// Oracle: `scipy.signal.buttap`. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order outside 1 … 512.
    public static func butterworth(order: Int) throws(DSPError) -> ZeroPoleGain {
        try validate(order: order)
        var poles: [Complex] = []
        poles.reserveCapacity(order)
        for m in stride(from: -order + 1, to: order, by: 2) {
            // m = 0 gives the exactly real pole of an odd order.
            let angle = Double.pi * Double(m) / Double(2 * order)
            poles.append(m == 0 ? Complex(-1, 0) : Complex(-cos(angle), -sin(angle)))
        }
        return ZeroPoleGain(zeros: [], poles: poles, gain: 1, domain: .analog)
    }

    /// The Chebyshev type I prototype: poles on an ellipse, an equiripple pass band of
    /// `ripple` decibels, no zeros. The edge at 1 rad/s is where the gain first falls below
    /// the ripple. Oracle: `scipy.signal.cheb1ap`. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order outside 1 … 512 or a ripple that
    ///   is not a positive, finite number of decibels.
    public static func chebyshev1(order: Int, ripple: Amplification) throws(DSPError) -> ZeroPoleGain {
        try validate(order: order)
        let rippleDecibels = try decibels(ripple, parameter: "ripple")
        // ε² = 10^(rp/10) − 1, through expm1: for a small ripple the power and the 1 agree
        // in most of their digits.
        let epsilon = powerRatioMinusOne(rippleDecibels).squareRoot()
        let mu = asinh(1 / epsilon) / Double(order)
        var poles: [Complex] = []
        poles.reserveCapacity(order)
        for m in stride(from: -order + 1, to: order, by: 2) {
            let theta = Double.pi * Double(m) / Double(2 * order)
            // −sinh(μ + jθ)
            poles.append(Complex(-sinh(mu) * cos(theta), m == 0 ? 0 : -cosh(mu) * sin(theta)))
        }
        var gain = realProduct(negated: poles)
        if order % 2 == 0 { gain /= (1 + epsilon * epsilon).squareRoot() }
        return try finite(ZeroPoleGain(zeros: [], poles: poles, gain: gain, domain: .analog), "ripple")
    }

    /// The Chebyshev type II (inverse Chebyshev) prototype: an equiripple stop band at least
    /// `stopband` decibels down, finite zeros on the imaginary axis, a monotonic pass band.
    /// The edge at 1 rad/s is where the attenuation first reaches `stopband`. Oracle:
    /// `scipy.signal.cheb2ap`. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order outside 1 … 512 or an attenuation
    ///   that is not a positive, finite number of decibels.
    public static func chebyshev2(order: Int, stopband: Amplification) throws(DSPError) -> ZeroPoleGain {
        try validate(order: order)
        let attenuation = try decibels(stopband, parameter: "stopband")
        let delta = 1 / powerRatioMinusOne(attenuation).squareRoot()
        let mu = asinh(1 / delta) / Double(order)

        var zeros: [Complex] = []
        var poles: [Complex] = []
        for m in stride(from: -order + 1, to: order, by: 2) {
            let angle = Double.pi * Double(m) / Double(2 * order)
            if m != 0 {
                // An odd order has no zero for m = 0: that one lies at infinity.
                zeros.append(Complex(0, 1 / sin(angle)))
            }
            // A Butterworth pole, warped onto the Chebyshev ellipse and inverted.
            let warped = Complex(-sinh(mu) * cos(angle), m == 0 ? 0 : -cosh(mu) * sin(angle))
            poles.append(warped.reciprocal)
        }
        let gain = realRatio(negatedNumerator: poles, negatedDenominator: zeros)
        return try finite(ZeroPoleGain(zeros: zeros, poles: poles, gain: gain, domain: .analog), "stopband")
    }

    /// The elliptic (Cauer) prototype: equiripple in both bands, `ripple` decibels in the
    /// pass band and at least `stopband` decibels down in the stop band; the steepest
    /// transition of any family for a given order. The edge at 1 rad/s is where the gain
    /// first falls below the ripple.
    ///
    /// The Jacobi elliptic functions are evaluated by Landen transformations and the degree
    /// equation through the nome; nothing is minimised or iterated to a tolerance
    /// (§6.3.2). Oracle: `scipy.signal.ellipap`. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order outside 1 … 512, a ripple or an
    ///   attenuation that is not a positive, finite number of decibels, or an attenuation
    ///   that does not exceed the ripple.
    public static func elliptic(order: Int, ripple: Amplification, stopband: Amplification) throws(DSPError) -> ZeroPoleGain {
        try validate(order: order)
        let rippleDecibels = try decibels(ripple, parameter: "ripple")
        let attenuation = try decibels(stopband, parameter: "stopband")
        guard attenuation > rippleDecibels else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "the stop-band attenuation (\(attenuation) dB) must exceed the pass-band ripple (\(rippleDecibels) dB)")
        }
        let epsilonSquared = powerRatioMinusOne(rippleDecibels)
        if order == 1 {
            let pole = -(1 / epsilonSquared).squareRoot()
            return try finite(ZeroPoleGain(zeros: [], poles: [Complex(pole)], gain: -pole, domain: .analog), "ripple")
        }
        let epsilon = epsilonSquared.squareRoot()
        // The discrimination parameter k₁² and the selectivity parameter m = k² it implies.
        let m1 = epsilonSquared / powerRatioMinusOne(attenuation)
        guard m1 > 0, m1 < 1 else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "a ripple of \(rippleDecibels) dB and an attenuation of \(attenuation) dB cannot be told apart in double precision")
        }
        let k1Integral = EllipticFunctions.completeIntegral(m: m1)
        let (m, mComplement) = EllipticFunctions.degreeEquation(order: order, m1: m1)
        // The stop band begins at 1/k ≈ 1 + (1 − m)/2. Once that is within a few units of the
        // last place of 1, the transition band has no representable frequency in it.
        guard m > 0, mComplement >= Self.smallestEllipticComplement else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "order \(order) with a ripple of \(rippleDecibels) dB and an attenuation of \(attenuation) dB puts the stop band closer to the pass band than double precision resolves")
        }
        let quarterPeriod = EllipticFunctions.completeIntegral(m: m, complement: mComplement)
        let k = m.squareRoot()

        // The pole displacement v₀, from sc(v₀·N·K₁/K, 1 − k₁²) = 1/ε.
        let r = EllipticFunctions.inverseSc(1 / epsilon, m: m1, complement: 1 - m1)
        let v0 = quarterPeriod * r / (Double(order) * k1Integral)
        let (sv, cv, dv) = EllipticFunctions.jacobi(v0, m: mComplement, complement: m)

        var upperZeros: [Complex] = []
        var upperPoles: [Complex] = []
        var realPole: Complex?
        for j in stride(from: 1 - order % 2, to: order, by: 2) {
            let (s, c, d) = EllipticFunctions.jacobi(Double(j) * quarterPeriod / Double(order), m: m, complement: mComplement)
            let denominator = 1 - (d * sv) * (d * sv)
            let pole = Complex(-(c * d * sv * cv) / denominator, -(s * dv) / denominator)
            if j == 0 {
                // The real pole of an odd order; its zero lies at infinity.
                realPole = Complex(pole.real, 0)
            } else {
                upperZeros.append(Complex(0, 1 / (k * s)))
                upperPoles.append(pole)
            }
        }
        let zeros = upperZeros + upperZeros.map(\.conjugate)
        var poles = upperPoles
        if let realPole { poles.insert(realPole, at: 0) }
        poles += upperPoles.map(\.conjugate)

        var gain = realRatio(negatedNumerator: poles, negatedDenominator: zeros)
        if order % 2 == 0 { gain /= (1 + epsilonSquared).squareRoot() }
        return try finite(ZeroPoleGain(zeros: zeros, poles: poles, gain: gain, domain: .analog), "order")
    }

    /// The Bessel (Thomson) prototype: the all-pole filter with maximally flat group delay.
    /// Its poles are the roots of the reverse Bessel polynomial (Campos starting values,
    /// Aberth refinement, evaluated in double-double arithmetic), scaled according to
    /// `normalization`. Oracle: `scipy.signal.besselap`. Control or background context;
    /// allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order below 1;
    ///   `DSPError.unsupportedConfiguration` above order 25, the highest the roots are
    ///   verified for.
    public static func bessel(order: Int, normalization: BesselNormalization = .phase) throws(DSPError) -> ZeroPoleGain {
        let delayPoles = try BesselPolynomial.roots(order: order)
        // θₙ(0) = (2n)! / (2ⁿ·n!): the gain of the delay-normalised filter.
        var constant = 1.0
        for factor in stride(from: 1, to: 2 * order, by: 2) { constant *= Double(factor) }

        switch normalization {
        case .delay:
            return ZeroPoleGain(zeros: [], poles: delayPoles, gain: constant, domain: .analog)
        case .phase:
            // The poles are moved so that their product is 1: Butterworth asymptotes.
            let scale = pow(10, -log10(constant) / Double(order))
            return ZeroPoleGain(zeros: [], poles: delayPoles.map { $0 * scale }, gain: 1, domain: .analog)
        case .magnitude:
            let cutoff = halfPowerFrequency(poles: delayPoles, gain: constant)
            return ZeroPoleGain(zeros: [], poles: delayPoles.map { $0 / cutoff },
                                gain: pow(cutoff, -Double(order)) * constant, domain: .analog)
        }
    }

    // MARK: Internals

    static func validate(order: Int) throws(DSPError) {
        guard order >= 1, order <= maximumOrder else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a filter order must lie in 1 … \(maximumOrder), not \(order)")
        }
    }

    /// The size of a ripple or an attenuation in decibels: positive whatever the sign it was
    /// stated with.
    static func decibels(_ amplification: Amplification, parameter: String) throws(DSPError) -> Double {
        let value = abs(amplification.decibels(floor: -10_000))
        guard value.isFinite, value > 0, value <= 1_000 else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "\(amplification) is not a positive, finite number of decibels (at most 1 000)")
        }
        return value
    }

    private static func finite(_ prototype: ZeroPoleGain, _ parameter: String) throws(DSPError) -> ZeroPoleGain {
        guard prototype.isFinite, prototype.gain != 0 else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "the prototype cannot be represented in double precision for these values")
        }
        return prototype
    }

    /// `10^(dB/10) − 1`, without the cancellation of the direct form for a small number of
    /// decibels.
    static func powerRatioMinusOne(_ decibels: Double) -> Double {
        expm1(M_LN10 * 0.1 * decibels)
    }

    /// `Re Π(−pᵢ)`.
    static func realProduct(negated values: [Complex]) -> Double {
        var product = Complex.one
        for value in values { product = product * (-value) }
        return product.real
    }

    /// `Re[Π(−nᵢ) / Π(−dᵢ)]`, with the factors alternating so that the running value stays
    /// near the size of the result.
    static func realRatio(negatedNumerator: [Complex], negatedDenominator: [Complex]) -> Double {
        var value = Complex.one
        for index in 0 ..< max(negatedNumerator.count, negatedDenominator.count) {
            if index < negatedNumerator.count { value = value * (-negatedNumerator[index]) }
            if index < negatedDenominator.count { value = value / (-negatedDenominator[index]) }
        }
        return value.real
    }

    /// The angular frequency at which the all-pole filter `gain / Π(s − pᵢ)` is 3 dB down:
    /// Newton's method on the logarithm of the gain, inside a bracket that bisection keeps
    /// valid. The magnitude of a Bessel filter falls monotonically, so the root is unique.
    static func halfPowerFrequency(poles: [Complex], gain: Double) -> Double {
        // f(ω) = Σ ln|jω − pᵢ| − ln(gain) − ½·ln 2, increasing in ω.
        func value(_ omega: Double) -> (f: Double, slope: Double) {
            var f = -log(gain) - 0.5 * M_LN2
            var slope = 0.0
            for pole in poles {
                let distanceSquared = pole.real * pole.real + (omega - pole.imaginary) * (omega - pole.imaginary)
                f += 0.5 * log(distanceSquared)
                slope += (omega - pole.imaginary) / distanceSquared
            }
            return (f, slope)
        }
        var low = 0.0
        var high = 1.5
        while value(high).f < 0, high < 1e6 { high *= 2 }
        var omega = high
        for _ in 0 ..< 200 {
            let (f, slope) = value(omega)
            if f > 0 { high = omega } else { low = omega }
            var next = slope > 0 ? omega - f / slope : (low + high) / 2
            if !(next > low && next < high) { next = (low + high) / 2 }
            if abs(next - omega) <= 2 * Double.ulpOfOne * omega {
                omega = next
                break
            }
            omega = next
        }
        return omega
    }
}
