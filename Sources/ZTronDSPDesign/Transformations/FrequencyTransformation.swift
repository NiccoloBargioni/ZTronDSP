import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// A transformation of an analog low-pass prototype, whose edge sits at 1 rad/s, into the
/// response that is wanted (§6.3.2). It acts on the zeros and the poles, never on
/// coefficients. Frequencies are angular, in radians per second.
///
/// An immutable value, usable on any thread; it does not allocate.
public enum FrequencyTransformation: Hashable, Sendable {
    /// Low-pass with its edge at `cutoff`: `s → s / cutoff`. Oracle: `lp2lp_zpk`.
    case lowPass(cutoff: Double)
    /// High-pass with its edge at `cutoff`: `s → cutoff / s`. Zeros at infinity move to the
    /// origin. Oracle: `lp2hp_zpk`.
    case highPass(cutoff: Double)
    /// Band-pass centred on `center` (the geometric mean of the two edges) and `bandwidth`
    /// wide (their difference): `s → (s² + center²) / (bandwidth·s)`. The order doubles.
    /// Oracle: `lp2bp_zpk`.
    case bandPass(center: Double, bandwidth: Double)
    /// Band-stop centred on `center` and `bandwidth` wide:
    /// `s → bandwidth·s / (s² + center²)`. The order doubles; zeros at infinity move to
    /// `±j·center`. Oracle: `lp2bs_zpk`.
    case bandStop(center: Double, bandwidth: Double)
}

extension ZeroPoleGain {
    /// The system that results from substituting the transformation for `s`.
    ///
    /// The receiver is an analog low-pass prototype: at least as many poles as zeros. The
    /// gain is adjusted so that the transformed response takes the prototype's values at the
    /// corresponding frequencies. For the band transformations each root `r` becomes the two
    /// roots of a quadratic; the larger is formed directly and the smaller from their
    /// product, `center²`, so a wide band costs no accuracy. Control or background context;
    /// allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the system is not analog, has more zeros
    ///   than poles, an edge or a width is not positive and finite, or a root would be sent
    ///   to infinity (a root at the origin under an inverting transformation).
    public func transformed(by transformation: FrequencyTransformation) throws(DSPError) -> ZeroPoleGain {
        guard domain == .analog else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "a frequency transformation acts on an analog prototype, not on a digital system")
        }
        let degree = relativeDegree
        guard degree >= 0 else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the prototype has \(zeros.count) zeros and only \(poles.count) poles: it is improper")
        }
        let result: ZeroPoleGain
        switch transformation {
        case .lowPass(let cutoff):
            try Self.requirePositive(cutoff, "cutoff")
            result = ZeroPoleGain(
                zeros: zeros.map { $0 * cutoff }, poles: poles.map { $0 * cutoff },
                gain: gain * pow(cutoff, Double(degree)), domain: .analog)

        case .highPass(let cutoff):
            try Self.requirePositive(cutoff, "cutoff")
            result = ZeroPoleGain(
                zeros: zeros.map { cutoff / $0 } + [Complex](repeating: .zero, count: degree),
                poles: poles.map { cutoff / $0 },
                gain: gain * AnalogPrototype.realRatio(negatedNumerator: zeros, negatedDenominator: poles),
                domain: .analog)

        case .bandPass(let center, let bandwidth):
            try Self.requirePositive(center, "center")
            try Self.requirePositive(bandwidth, "bandwidth")
            let half = bandwidth / 2
            result = ZeroPoleGain(
                zeros: Self.split(zeros.map { $0 * half }, around: center) + [Complex](repeating: .zero, count: degree),
                poles: Self.split(poles.map { $0 * half }, around: center),
                gain: gain * pow(bandwidth, Double(degree)), domain: .analog)

        case .bandStop(let center, let bandwidth):
            try Self.requirePositive(center, "center")
            try Self.requirePositive(bandwidth, "bandwidth")
            let half = bandwidth / 2
            result = ZeroPoleGain(
                zeros: Self.split(zeros.map { half / $0 }, around: center)
                    + [Complex](repeating: Complex(0, center), count: degree)
                    + [Complex](repeating: Complex(0, -center), count: degree),
                poles: Self.split(poles.map { half / $0 }, around: center),
                gain: gain * AnalogPrototype.realRatio(negatedNumerator: zeros, negatedDenominator: poles),
                domain: .analog)
        }
        guard result.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "transformation", reason: "the transformation sends a zero or a pole of this system to infinity, or its gain out of range")
        }
        return result
    }

    private static func requirePositive(_ value: Double, _ parameter: String) throws(DSPError) {
        guard value.isFinite, value > 0 else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "an angular frequency must be positive and finite, not \(value)")
        }
    }

    /// Each root `r` becomes `r ± √(r² − center²)`: first all the larger members, then all
    /// the smaller ones. The two multiply to `center²`, so the smaller is the quotient,
    /// which avoids the cancellation of the direct form.
    private static func split(_ roots: [Complex], around center: Double) -> [Complex] {
        let centerSquared = center * center
        var larger: [Complex] = []
        var smaller: [Complex] = []
        larger.reserveCapacity(roots.count)
        smaller.reserveCapacity(roots.count)
        for root in roots {
            let radical = Complex.sqrt(root * root - centerSquared)
            let plus = root + radical
            let minus = root - radical
            let first = plus.squaredMagnitude >= minus.squaredMagnitude ? plus : minus
            larger.append(first)
            smaller.append(centerSquared / first)
        }
        return larger + smaller
    }
}

extension TransferFunction {
    /// The transformation applied to the coefficient form *by conversion*: the roots are
    /// found, transformed in zero-pole-gain form and multiplied out again (Appendix A). The
    /// result is as accurate as its root finding; transform the `ZeroPoleGain` when there is
    /// one. Control or background context; allocates.
    public func transformed(by transformation: FrequencyTransformation) throws(DSPError) -> TransferFunction {
        try zeroPoleGain().transformed(by: transformation).transferFunction()
    }
}
