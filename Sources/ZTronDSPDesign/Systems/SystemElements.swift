import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

// The elements of the two system builders of §6.3.7.

/// What the elements of both system builders have in common (§6.3.7): whether they depend on
/// the sample rate, and their continuous values.
///
/// Conformers are immutable values, usable on any thread; `parameters` may allocate the list
/// it returns, and resolving an element allocates (``IIRSystemElement``, ``FIRSystemElement``).
public protocol SystemElement: Hashable, Sendable {
    /// True when the element depends on the sample rate it is resolved at: it states a
    /// frequency in hertz, as a MIDI note or in mels. An element that is fixed in the `z`
    /// plane (coefficients, roots, frequencies in cycles or radians per sample) is the same
    /// system at every rate, and a system made of such elements can be analysed without one.
    /// The default is `true`. Usable on any thread.
    var dependsOnSampleRate: Bool { get }

    /// The element's continuous values, for animation (ANI-2): frequencies as their
    /// `animatableValue`, gains in decibels. The default is no values. Usable on any thread.
    var parameters: [Double] { get }

    /// The element with its continuous values replaced; `values` holds as many as `parameters`.
    /// Usable on any thread; it may allocate.
    func replacingParameters(_ values: ArraySlice<Double>) -> Self
}

extension SystemElement {
    /// The default: the element is taken to depend on the sample rate. Usable on any thread.
    public var dependsOnSampleRate: Bool { true }
    /// The default: no continuous values. Usable on any thread. It does not allocate.
    public var parameters: [Double] { [] }
    /// The default: nothing to replace. Usable on any thread. It does not allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> Self { self }
}

/// An element of an `IIRSystem { }` block: anything that is a digital system of zeros, poles
/// and a gain once the sample rate is known (§6.3.7).
///
/// The stock elements are ``Pole``, ``Zero``, ``Section``, ``DifferenceEquation``, the IIR
/// forms of the response and equaliser stages (`LowPass` … `HighShelf`), and the two
/// representations `ZeroPoleGain` and `SecondOrderSections`. A conformer of your own is
/// written into a block the same way.
///
/// Conformers are immutable values, usable on any thread. Resolving allocates: control or
/// background context.
public protocol IIRSystemElement: SystemElement {
    /// The element as a digital system at `sampleRate`, as a rational function of `z⁻¹`:
    /// `gain · Π(1 − zᵢ·z⁻¹) / Π(1 − pᵢ·z⁻¹)`. Zeros and poles are real or come in conjugate
    /// pairs. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for values that make no system at this rate.
    func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain
}

/// An element of an `FIRSystem { }` block: anything that is a list of taps once the sample
/// rate is known (§6.3.7).
///
/// The stock elements are ``Taps``, ``LeastSquares``, ``Zero`` and the FIR forms of the
/// response stages (`LowPass(.windowedSinc(), …)` and the like). ``Pole``, ``Section``,
/// ``DifferenceEquation`` and the IIR forms of the response stages may be written into the
/// block as well; each is rejected when the system is resolved if it would place a pole away
/// from the origin.
///
/// Conformers are immutable values, usable on any thread. Resolving allocates: control or
/// background context.
public protocol FIRSystemElement: SystemElement {
    /// The element's taps at `sampleRate`, lowest delay first: `y[n] = Σ taps[k]·x[n − k]`.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for values that make no FIR filter at this rate,
    ///   an element with a pole away from the origin among them.
    func taps(sampleRate: Double) throws(DSPError) -> [Double]
}

/// An element whose roots were found from coefficients, and are therefore known only to
/// their condition (§6.3.8).
protocol ConditionedSystemElement {
    /// The condition number of each zero and of each pole, in the order of the element's
    /// `zeroPoleGain(sampleRate:)`.
    func rootConditions(sampleRate: Double) throws(DSPError) -> (zeros: [Double], poles: [Double])
}

// MARK: Where a root lies

/// A point of the `z` plane as a pole or a zero states it.
enum RootLocation: Hashable, Sendable {
    /// `radius · e^{±j·2π·f/fs}`.
    case polar(radius: Double, frequency: Frequency)
    /// A point of the plane itself.
    case cartesian(Complex)

    /// The root, with its conjugate when it is not real.
    func roots(sampleRate: Double, parameter: String) throws(DSPError) -> [Complex] {
        switch self {
        case .cartesian(let point):
            guard point.isFinite else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "the location \(point) is not finite")
            }
            return point.imaginary == 0 ? [point] : [point, point.conjugate]
        case .polar(let radius, let frequency):
            guard radius.isFinite, radius >= 0 else {
                throw .invalidParameter(stage: .none, parameter: "radius", reason: "a radius is not negative and finite, not \(radius)")
            }
            let hertz = try frequency.hertz(sampleRate: sampleRate)
            let nyquist = sampleRate / 2
            guard hertz <= nyquist else {
                throw .invalidParameter(stage: .none, parameter: "frequency", reason: "\(frequency) is \(hertz) Hz, above the Nyquist frequency of \(nyquist) Hz")
            }
            // At 0 Hz and at the Nyquist frequency the root is real and has no conjugate.
            if hertz == 0 || radius == 0 { return [Complex(radius)] }
            if hertz == nyquist { return [Complex(-radius)] }
            let root = Complex(magnitude: radius, phase: 2 * Double.pi * hertz / sampleRate)
            return [root, root.conjugate]
        }
    }

    var dependsOnSampleRate: Bool {
        switch self {
        case .cartesian: false
        // A frequency in cycles or radians per sample is an angle of the plane; one in hertz
        // is an angle only once the rate is known.
        case .polar(_, let frequency): !frequency.dependsOnSampleRate
        }
    }

    var parameters: [Double] {
        switch self {
        case .cartesian: []
        case .polar(_, let frequency): [frequency.animatableValue]
        }
    }

    func replacingParameters(_ values: ArraySlice<Double>) -> RootLocation {
        guard case .polar(let radius, let frequency) = self, let value = values.first else { return self }
        return .polar(radius: radius, frequency: frequency.replacing(animatableValue: value))
    }
}

// MARK: Pole

/// A pole of a system (§6.3.7): the factor `1 / (1 − p·z⁻¹)`, together with the factor of
/// its conjugate when the pole is not real, so that the system has real coefficients.
///
/// ```swift
/// IIRSystem {
///     Zero(onUnitCircleAt: .hertz(50))
///     Pole(radius: 0.985, frequency: .hertz(50))      // the pair 0.985·e^{±j·2π·50/fs}
/// }
/// ```
///
/// A pole at 0 Hz or at the Nyquist frequency is real and stands alone. A pole on or outside
/// the unit circle makes a system that is not stable; it can be analysed, and it is rejected
/// when a pipeline that runs it is compiled (REAL-2). In an `FIRSystem` only a pole at the
/// origin is accepted: it is a delay of one sample.
///
/// An immutable value, usable on any thread; resolving it at a sample rate allocates.
public struct Pole: IIRSystemElement, FIRSystemElement {
    let location: RootLocation

    /// The pole pair `radius · e^{±jω}` at the angle of `frequency`. Usable on any thread.
    public init(radius: Double, frequency: Frequency) {
        location = .polar(radius: radius, frequency: frequency)
    }

    /// The pole at a point of the `z` plane, with its conjugate when the point is not real.
    /// Usable on any thread.
    public init(at location: Complex) {
        self.location = .cartesian(location)
    }

    /// The pole, or the pole pair, over as many zeros at the origin. Control or background
    /// context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        let poles = try location.roots(sampleRate: sampleRate, parameter: "pole")
        return ZeroPoleGain(zeros: [Complex](repeating: .zero, count: poles.count), poles: poles, gain: 1, domain: .digital)
    }

    /// A pole at the origin is a delay of one sample; any other pole has no taps. Control or
    /// background context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        let poles = try location.roots(sampleRate: sampleRate, parameter: "pole")
        guard poles.allSatisfy({ $0 == .zero }) else {
            throw .invalidParameter(stage: .none, parameter: "pole", reason: "an FIR system has no pole away from the origin, and this one lies at \(poles[0]): put it in an IIRSystem")
        }
        return [0, 1]
    }

    /// True for a pole whose frequency is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { location.dependsOnSampleRate }
    /// The frequency of a pole given by radius and frequency. Usable on any thread; it may
    /// allocate.
    public var parameters: [Double] { location.parameters }
    /// The pole at another frequency. Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> Pole { Pole(location: location.replacingParameters(values)) }

    private init(location: RootLocation) {
        self.location = location
    }
}

// MARK: Zero

/// A zero of a system (§6.3.7): the factor `1 − z₀·z⁻¹`, together with the factor of its
/// conjugate when the zero is not real, so that the system has real coefficients.
///
/// `Zero(onUnitCircleAt: .hertz(50))` removes 50 Hz entirely: the pair `e^{±j·2π·50/fs}`.
/// A zero at 0 Hz or at the Nyquist frequency is real and stands alone.
///
/// An immutable value, usable on any thread; resolving it at a sample rate allocates.
public struct Zero: IIRSystemElement, FIRSystemElement {
    let location: RootLocation

    /// The zero pair on the unit circle at the angle of `frequency`: the conjugate is added
    /// automatically. Usable on any thread.
    public init(onUnitCircleAt frequency: Frequency) {
        location = .polar(radius: 1, frequency: frequency)
    }

    /// The zero pair `radius · e^{±jω}` at the angle of `frequency`. Usable on any thread.
    public init(radius: Double, frequency: Frequency) {
        location = .polar(radius: radius, frequency: frequency)
    }

    /// The zero at a point of the `z` plane, with its conjugate when the point is not real.
    /// Usable on any thread.
    public init(at location: Complex) {
        self.location = .cartesian(location)
    }

    /// The zero, or the zero pair, over as many poles at the origin. Control or background
    /// context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        let zeros = try location.roots(sampleRate: sampleRate, parameter: "zero")
        return ZeroPoleGain(zeros: zeros, poles: [Complex](repeating: .zero, count: zeros.count), gain: 1, domain: .digital)
    }

    /// `[1, −z₀]` for a real zero, `[1, −2·Re z₀, |z₀|²]` for a pair. Control or background
    /// context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        let zeros = try location.roots(sampleRate: sampleRate, parameter: "zero")
        if zeros.count == 1 { return [1, -zeros[0].real] }
        return [1, -2 * zeros[0].real, zeros[0].squaredMagnitude]
    }

    /// True for a zero whose frequency is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { location.dependsOnSampleRate }
    /// The frequency of a zero given by its frequency. Usable on any thread; it may allocate.
    public var parameters: [Double] { location.parameters }
    /// The zero at another frequency. Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> Zero { Zero(location: location.replacingParameters(values)) }

    private init(location: RootLocation) {
        self.location = location
    }
}

// MARK: Section

/// One second-order section given by its coefficients (§6.3.7):
///
///     H(z) = (b[0] + b[1]·z⁻¹ + b[2]·z⁻²) / (a[0] + a[1]·z⁻¹ + a[2]·z⁻²)
///
/// Each list holds one to three numbers; `a[0]` is not zero and is normalised to 1. The
/// zeros and the poles are read in closed form: no root finder runs (§6.3.8).
///
/// An immutable value, usable on any thread; resolving it at a sample rate allocates.
public struct Section: IIRSystemElement, FIRSystemElement {
    /// The numerator coefficients, lowest delay first. Usable on any thread.
    public let b: [Double]
    /// The denominator coefficients, lowest delay first. Usable on any thread.
    public let a: [Double]

    /// Usable on any thread.
    public init(b: [Double], a: [Double] = [1]) {
        self.b = b
        self.a = a
    }

    /// The five numbers of the section, normalised.
    func normalized() throws(DSPError) -> SecondOrderSections.Section {
        guard (1 ... 3).contains(b.count), (1 ... 3).contains(a.count) else {
            throw .invalidParameter(stage: .none, parameter: b.count > 3 || b.isEmpty ? "b" : "a", reason: "a section has one to three coefficients in its numerator and in its denominator, not \(b.count) and \(a.count): a longer recurrence is a DifferenceEquation")
        }
        guard b.allSatisfy(\.isFinite), a.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "b", reason: "every coefficient of a section must be finite")
        }
        guard a[0] != 0 else {
            throw .invalidParameter(stage: .none, parameter: "a", reason: "the first denominator coefficient of a section must not be zero: it is what the output is divided by")
        }
        let numerator = b + [Double](repeating: 0, count: 3 - b.count)
        let denominator = a + [Double](repeating: 0, count: 3 - a.count)
        return .init(b0: numerator[0] / a[0], b1: numerator[1] / a[0], b2: numerator[2] / a[0], a1: denominator[1] / a[0], a2: denominator[2] / a[0])
    }

    /// The section's zeros, poles and gain, read in closed form. Control or background
    /// context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        SecondOrderSections(sections: [try normalized()]).zeroPoleGain()
    }

    /// The numerator, when the denominator is a constant; a section with a pole away from the
    /// origin has no taps. Control or background context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        let section = try normalized()
        guard section.a1 == 0, section.a2 == 0 else {
            throw .invalidParameter(stage: .none, parameter: "a", reason: "an FIR system has no pole away from the origin, and this section has the denominator 1, \(section.a1), \(section.a2): put it in an IIRSystem")
        }
        return [section.b0, section.b1, section.b2]
    }

    /// A section is fixed in the `z` plane. Usable on any thread.
    public var dependsOnSampleRate: Bool { false }
}

// MARK: DifferenceEquation

/// A system given as a difference equation (§6.3.7):
///
///     a[0]·y[n] = Σ b[k]·x[n − k] − Σ_{k ≥ 1} a[k]·y[n − k]
///
/// with `a[0]` normalised to 1. The lists may be of any length up to the degree the root
/// finder supports.
///
/// Its zeros and poles have to be *found* from the coefficients, by the root finder, and are
/// known only to their condition (§6.3.8): the analysis of a system that holds a difference
/// equation reports that condition for every root that came from one. Prefer zeros, poles
/// and sections where the system is known that way.
///
/// An immutable value, usable on any thread; resolving it at a sample rate allocates.
public struct DifferenceEquation: IIRSystemElement, FIRSystemElement, ConditionedSystemElement {
    /// The coefficients of the input, lowest delay first. Usable on any thread.
    public let b: [Double]
    /// The coefficients of the output, lowest delay first. Usable on any thread.
    public let a: [Double]
    /// The strategy that finds the zeros and the poles, boxed for comparison. Usable on any
    /// thread.
    public let rootFinder: AnyStrategy

    /// Usable on any thread; it allocates only to box a root finder larger than three words, which
    /// the stock one is not.
    public init(b: [Double], a: [Double] = [1], rootFinder: some PolynomialRootFinder = .companionQR) {
        self.b = b
        self.a = a
        self.rootFinder = AnyStrategy(rootFinder)
    }

    private func transferFunction() throws(DSPError) -> TransferFunction {
        guard !b.isEmpty, !a.isEmpty, b.allSatisfy(\.isFinite), a.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "b", reason: "a difference equation needs finite coefficients, at least one on each side")
        }
        guard a[0] != 0 else {
            throw .invalidParameter(stage: .none, parameter: "a", reason: "the first output coefficient of a difference equation must not be zero: it is what the output is divided by")
        }
        guard let finder = rootFinder.value(as: (any PolynomialRootFinder).self) else {
            throw .invalidParameter(stage: .none, parameter: "rootFinder", reason: "the difference equation has no root finder")
        }
        func make(_ finder: some PolynomialRootFinder) -> TransferFunction {
            TransferFunction.differenceEquation(b: b.map { $0 / a[0] }, a: a.map { $0 / a[0] }, rootFinder: finder)
        }
        return make(finder)
    }

    /// The zeros and the poles, found by the root finder. Control or background context;
    /// allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        let function = try transferFunction()
        guard !function.numerator.isZero else {
            // A numerator of zeros is a system that passes nothing.
            return ZeroPoleGain(zeros: [], poles: try function.poles, gain: 0, domain: .digital)
        }
        return try function.zeroPoleGain()
    }

    func rootConditions(sampleRate: Double) throws(DSPError) -> (zeros: [Double], poles: [Double]) {
        let function = try transferFunction()
        return (function.numerator.isZero ? [] : try function.zeroConditions, try function.poleConditions)
    }

    /// The input coefficients, when the output side is `a[0]` alone; a recurrence on the
    /// output has no taps. Control or background context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        _ = try transferFunction()
        guard a.dropFirst().allSatisfy({ $0 == 0 }) else {
            throw .invalidParameter(stage: .none, parameter: "a", reason: "an FIR system has no pole away from the origin, and this difference equation feeds its output back: put it in an IIRSystem")
        }
        return b.map { $0 / a[0] }
    }

    /// A difference equation is fixed in the `z` plane. Usable on any thread.
    public var dependsOnSampleRate: Bool { false }
}

// MARK: Taps

/// Caller-supplied FIR coefficients (§6.3.3): `y[n] = Σ taps[k]·x[n − k]`.
///
/// An immutable value, usable on any thread; resolving it at a sample rate allocates.
public struct Taps: FIRSystemElement {
    /// The coefficients, lowest delay first. Usable on any thread.
    public let values: [Double]

    /// Usable on any thread.
    public init(_ values: [Double]) {
        self.values = values
    }

    /// The taps as they were given. Control or background context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "taps", reason: "an FIR filter has at least one tap, and every tap is finite")
        }
        return values
    }

    /// Taps are fixed in the `z` plane. Usable on any thread.
    public var dependsOnSampleRate: Bool { false }
}

// MARK: LeastSquares

/// A least-squares fit to any piecewise-linear target (§6.3.3): the fit of `.leastSquares`
/// with the bands, the gains wanted at their edges and their weights stated by the caller.
///
/// ```swift
/// FIRSystem {
///     LeastSquares(length: 101,
///                  bands: [.hertz(0), .hertz(3_000), .hertz(4_000), .hertz(24_000)],
///                  desired: [1, 1, 0, 0])
/// }
/// ```
///
/// `bands` holds the two edges of each band, ascending and without overlap, from 0 Hz to the
/// Nyquist frequency at most; `desired` the gain wanted at each edge, linear in between;
/// `weights` one weight per band, or none for equal weights. What lies between two bands is
/// not fitted. A fit that leaves much of the axis out is ill-conditioned and is solved by the
/// fall-back of the method (§6.3.3); its taps then follow the minimum-norm solution.
///
/// Oracle: `scipy.signal.firls`. An immutable value, usable on any thread; resolving it at a
/// sample rate allocates.
public struct LeastSquares: FIRSystemElement {
    /// The number of taps: odd. Usable on any thread.
    public let length: Int
    /// The edges of the bands, two per band. Usable on any thread.
    public let bands: [Frequency]
    /// The gain wanted at each edge. Usable on any thread.
    public let desired: [Double]
    /// One weight per band; empty for equal weights. Usable on any thread.
    public let weights: [Double]

    /// Usable on any thread.
    public init(length: Int, bands: [Frequency], desired: [Double], weights: [Double] = []) {
        self.length = length
        self.bands = bands
        self.desired = desired
        self.weights = weights
    }

    /// The taps of the fit. Control or background context; allocates.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try IIRDesign.validate(sampleRate: sampleRate)
        guard !bands.isEmpty, bands.count % 2 == 0 else {
            throw .invalidParameter(stage: .none, parameter: "bands", reason: "the bands are given by their edges, two per band, not \(bands.count) edges")
        }
        guard desired.count == bands.count else {
            throw .invalidParameter(stage: .none, parameter: "desired", reason: "one wanted gain per band edge: \(bands.count) edges and \(desired.count) gains")
        }
        guard weights.isEmpty || weights.count == bands.count / 2 else {
            throw .invalidParameter(stage: .none, parameter: "weights", reason: "one weight per band: \(bands.count / 2) bands and \(weights.count) weights")
        }
        let nyquist = sampleRate / 2
        var fitted: [LeastSquaresFIR.Band] = []
        for index in 0 ..< bands.count / 2 {
            let lower = try bands[2 * index].hertz(sampleRate: sampleRate) / nyquist
            let upper = try bands[2 * index + 1].hertz(sampleRate: sampleRate) / nyquist
            fitted.append(.init(lower: lower, upper: upper, lowerGain: desired[2 * index], upperGain: desired[2 * index + 1],
                                weight: weights.isEmpty ? 1 : weights[index]))
        }
        return try LeastSquaresFIR.design(length: length, bands: fitted).taps
    }

    /// True when a band edge is stated in hertz, as a note or in mels. Usable on any thread.
    public var dependsOnSampleRate: Bool { bands.contains { !$0.dependsOnSampleRate } }
    /// The band edges. Usable on any thread; it may allocate.
    public var parameters: [Double] { bands.map(\.animatableValue) }
    /// The fit with other band edges. Usable on any thread; it may allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> LeastSquares {
        guard values.count == bands.count else { return self }
        return LeastSquares(length: length, bands: zip(bands, values).map { $0.replacing(animatableValue: $1) }, desired: desired, weights: weights)
    }
}

// MARK: The representations as elements

extension ZeroPoleGain: IIRSystemElement {
    /// The system itself, when it is digital. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an analog system: transform it first
    ///   (`bilinear(sampleRate:)`).
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        guard domain == .digital else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "an analog system is not an element of a digital one: transform it first, with bilinear(sampleRate:)")
        }
        return self
    }

    /// Zeros and poles are fixed in the `z` plane. Usable on any thread.
    public var dependsOnSampleRate: Bool { false }
}

extension SecondOrderSections: IIRSystemElement {
    /// The cascade as zeros, poles and gain, read section by section, when it is digital.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an analog cascade.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        guard domain == .digital else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "an analog cascade is not an element of a digital system")
        }
        return zeroPoleGain()
    }

    /// Sections are fixed in the `z` plane. Usable on any thread.
    public var dependsOnSampleRate: Bool { false }
}
