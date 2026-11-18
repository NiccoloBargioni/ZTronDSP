import ZTronDSPCore

/// The plane a linear time-invariant system is described in (§6.3.1).
///
/// A tag on every representation: it decides where the frequency axis lies (the imaginary
/// axis or the unit circle) and which region is stable (the left half plane or the unit
/// disc). An immutable value, usable on any thread.
public enum SystemDomain: Hashable, Sendable, CustomStringConvertible {
    /// Continuous time: a function of `s`. Frequencies are in radians per second.
    case analog
    /// Discrete time: a function of `z`. Frequencies are in radians per sample.
    case digital

    /// A readable form. Usable on any thread.
    public var description: String {
        switch self {
        case .analog: "analog"
        case .digital: "digital"
        }
    }
}

/// The unit a magnitude response is reported in.
///
/// An immutable value, usable on any thread.
public struct MagnitudeScale: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case linear
        case decibels
    }

    let kind: Kind
    /// The floor of a decibel scale; unused by the linear one. Usable on any thread.
    public let floor: Double

    /// The magnitude itself, `|H|`. Usable on any thread.
    public static let linear = MagnitudeScale(kind: .linear, floor: 0)

    /// Amplitude decibels, `20·log₁₀|H|`, clamped at the package's floor of −160 dB so that a
    /// zero of the response is a number and not −∞ (NUM-1). Usable on any thread.
    public static let decibels = MagnitudeScale(kind: .decibels, floor: DSP.decibelFloor)

    /// Amplitude decibels clamped at `floor`, for a stop band that lies below −160 dB. Usable
    /// on any thread.
    public static func decibels(floor: Double) -> MagnitudeScale {
        MagnitudeScale(kind: .decibels, floor: floor)
    }
}

/// A linear time-invariant system and the analysis every representation of one provides
/// (§6.3.8).
///
/// `ZeroPoleGain`, `TransferFunction` and `SecondOrderSections` adopt it. A conformer supplies
/// its domain, zeros, poles and gain; everything else has a default that is computed from
/// those, and a conformer with a better-conditioned route overrides it (a cascade of sections
/// multiplies section responses; a coefficient form evaluates its polynomials).
///
/// **Frequencies** are angular: radians per second for an analog system, radians per sample
/// for a digital one (π is the Nyquist frequency).
///
/// **Values that do not exist** are stated, never NaN (NUM-1): at a frequency that coincides
/// with a pole the response is reported as `Complex(.greatestFiniteMagnitude, 0)`; the phase
/// of a zero response is 0; the group delay is `nil` where it is undefined.
///
/// Conformers are immutable values, usable on any thread. The analysis allocates its
/// results: design maths, for a control or background context, not for the analysis thread.
public protocol LTISystem: Sendable {
    /// The plane the system is described in.
    /// Usable on any thread.
    var domain: SystemDomain { get }

    /// The zeros, with their multiplicity. Read from the zero-pole-gain form, or in closed
    /// form from each section; found from coefficients through the root finder only for a
    /// system that was given as coefficients.
    /// Control or background context; allocates.
    var zeros: [Complex] { get throws(DSPError) }

    /// The poles, with their multiplicity. See ``zeros``.
    /// Control or background context; allocates.
    var poles: [Complex] { get throws(DSPError) }

    /// The gain `k` of `H = k·Π(x − zᵢ) / Π(x − pᵢ)`.
    /// Control or background context; allocates.
    var gain: Double { get throws(DSPError) }

    /// Digital: every pole lies strictly inside the unit circle. Analog: every pole lies
    /// strictly in the left half plane.
    /// Control or background context; allocates.
    var isStable: Bool { get throws(DSPError) }

    /// Digital: `1 − max|p|`. Analog: `−max Re p`. Positive exactly when the system is
    /// stable. A system without poles has the margin 1 (digital) or the largest finite
    /// double (analog).
    /// Control or background context; allocates.
    var stabilityMargin: Double { get throws(DSPError) }

    /// Digital: every zero lies inside or on the unit circle. Analog: every zero lies in the
    /// closed left half plane. "On" allows for one part in 10¹² of rounding.
    /// Control or background context; allocates.
    var isMinimumPhase: Bool { get throws(DSPError) }

    /// The complex response `H(jω)` (analog) or `H(e^{jω})` (digital) at each frequency.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a frequency that is not finite.
    func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex]

    /// `|H|` at each frequency, in the given scale.
    /// Control or background context; allocates.
    func magnitudeResponse(at frequencies: [Double], in scale: MagnitudeScale) throws(DSPError) -> [Double]

    /// `arg H` at each frequency, in radians: in −π … π, or, unwrapped, continued along the
    /// order of `frequencies` so that no step between neighbours exceeds π.
    /// Control or background context; allocates.
    func phaseResponse(at frequencies: [Double], unwrapped: Bool) throws(DSPError) -> [Double]

    /// The group delay `−dφ/dω` at each frequency: in samples for a digital system, in
    /// seconds for an analog one.
    ///
    /// `nil` where the delay is undefined: where `|H|` is zero or below 10⁻¹² of the largest
    /// `|H|` among `frequencies` (a zero on the frequency axis), and at a pole on the axis.
    /// Control or background context; allocates.
    func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?]
}

extension LTISystem {
    /// The default: the stability margin is positive. Control or background context; allocates.
    public var isStable: Bool {
        get throws(DSPError) { try stabilityMargin > 0 }
    }

    /// The default, from the poles. Control or background context; allocates.
    public var stabilityMargin: Double {
        get throws(DSPError) { LTIAnalysis.stabilityMargin(of: try poles, domain: domain) }
    }

    /// The default, from the zeros. Control or background context; allocates.
    public var isMinimumPhase: Bool {
        get throws(DSPError) { LTIAnalysis.isMinimumPhase(zeros: try zeros, domain: domain) }
    }

    /// The default: the product over the zeros and poles. Control or background context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        return LTIAnalysis.response(zeros: try zeros, poles: try poles, gain: try gain, domain: domain, at: frequencies)
    }

    /// The magnitude of the frequency response, in `scale` (linear unless stated). Control or
    /// background context; allocates.
    public func magnitudeResponse(at frequencies: [Double], in scale: MagnitudeScale = .linear) throws(DSPError) -> [Double] {
        let response = try frequencyResponse(at: frequencies)
        switch scale.kind {
        case .linear:
            return response.map(\.magnitude)
        case .decibels:
            return response.map { DSP.decibels(fromAmplitude: $0.magnitude, floor: scale.floor) }
        }
    }

    /// The phase of the frequency response, wrapped unless `unwrapped` is true. Control or
    /// background context; allocates.
    public func phaseResponse(at frequencies: [Double], unwrapped: Bool = false) throws(DSPError) -> [Double] {
        let phases = try frequencyResponse(at: frequencies).map { $0.magnitude < .greatestFiniteMagnitude ? $0.phase : 0 }
        return unwrapped ? LTIAnalysis.unwrapped(phases) : phases
    }

    /// The default: a sum over the zeros and poles, with the undefined points removed. Control or
    /// background context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        let response = try frequencyResponse(at: frequencies)
        let delays = LTIAnalysis.groupDelay(zeros: try zeros, poles: try poles, domain: domain, at: frequencies)
        return LTIAnalysis.masked(delays, by: response)
    }
}

/// The arithmetic shared by the representations.
enum LTIAnalysis {
    /// How far outside the stable region a zero may sit, relative to the boundary, and still
    /// count as on it.
    static let boundaryTolerance = 1e-12
    /// The fraction of the largest magnitude below which the group delay is undefined.
    static let undefinedDelayThreshold = 1e-12

    static func validate(_ frequencies: [Double]) throws(DSPError) {
        guard frequencies.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "frequencies", reason: "every frequency must be finite")
        }
    }

    /// The point of the frequency axis: `jω` or `e^{jω}`.
    @inline(__always)
    static func point(_ frequency: Double, _ domain: SystemDomain) -> Complex {
        switch domain {
        case .analog: Complex(0, frequency)
        case .digital: Complex(magnitude: 1, phase: frequency)
        }
    }

    /// A response value as it is reported: a non-finite one, at a pole, becomes the largest
    /// finite magnitude with phase 0.
    @inline(__always)
    static func reported(_ value: Complex) -> Complex {
        value.isFinite ? value : Complex(.greatestFiniteMagnitude, 0)
    }

    static func stabilityMargin(of poles: [Complex], domain: SystemDomain) -> Double {
        switch domain {
        case .digital:
            return 1 - (poles.map(\.magnitude).max() ?? 0)
        case .analog:
            guard let rightmost = poles.map(\.real).max() else { return .greatestFiniteMagnitude }
            return -rightmost
        }
    }

    static func isMinimumPhase(zeros: [Complex], domain: SystemDomain) -> Bool {
        switch domain {
        case .digital:
            return zeros.allSatisfy { $0.magnitude <= 1 + boundaryTolerance }
        case .analog:
            return zeros.allSatisfy { $0.real <= boundaryTolerance * $0.magnitude }
        }
    }

    /// `k·Π(x − zᵢ) / Π(x − pᵢ)` on the frequency axis. Factors of the numerator and of the
    /// denominator alternate, so the running product stays near the size of the response.
    static func response(zeros: [Complex], poles: [Complex], gain: Double, domain: SystemDomain, at frequencies: [Double]) -> [Complex] {
        frequencies.map { frequency in
            let x = point(frequency, domain)
            var value = Complex(gain)
            for index in 0 ..< max(zeros.count, poles.count) {
                if index < zeros.count { value = value * (x - zeros[index]) }
                if index < poles.count { value = value / (x - poles[index]) }
            }
            return reported(value)
        }
    }

    /// The group delay as a sum over the roots: each pole contributes `Re[w / (x − p)]` and
    /// each zero the negative of the same, where `w` is `x` on the unit circle and 1 on the
    /// imaginary axis. Not finite where a root lies on the axis at that frequency.
    static func groupDelay(zeros: [Complex], poles: [Complex], domain: SystemDomain, at frequencies: [Double]) -> [Double] {
        frequencies.map { frequency in
            let x = point(frequency, domain)
            let weight = domain == .digital ? x : Complex.one
            var delay = 0.0
            for pole in poles { delay += (weight / (x - pole)).real }
            for zero in zeros { delay -= (weight / (x - zero)).real }
            return delay
        }
    }

    /// Applies the rule for undefined delays (§6.3.8).
    static func masked(_ delays: [Double], by response: [Complex]) -> [Double?] {
        let magnitudes = response.map(\.magnitude)
        let largest = magnitudes.filter { $0 < .greatestFiniteMagnitude }.max() ?? 0
        var result: [Double?] = []
        result.reserveCapacity(delays.count)
        for (delay, magnitude) in zip(delays, magnitudes) {
            let defined = delay.isFinite && magnitude > 0 && magnitude < .greatestFiniteMagnitude
                && magnitude >= undefinedDelayThreshold * largest
            result.append(defined ? delay : nil)
        }
        return result
    }

    /// Removes the jumps of 2π: each step between neighbours is brought into −π … π.
    static func unwrapped(_ phases: [Double]) -> [Double] {
        guard phases.count > 1 else { return phases }
        var result = phases
        var correction = 0.0
        for index in 1 ..< phases.count {
            let step = phases[index] - phases[index - 1]
            if abs(step) >= .pi {
                var wrapped = (step + .pi).truncatingRemainder(dividingBy: 2 * .pi)
                if wrapped < 0 { wrapped += 2 * .pi }
                wrapped -= .pi
                if wrapped == -.pi, step > 0 { wrapped = .pi }
                correction += wrapped - step
            }
            result[index] = phases[index] + correction
        }
        return result
    }
}
