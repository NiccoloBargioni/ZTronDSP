import ZTronDSPCore

/// A polynomial with real coefficients, highest power first: `[1, -3, 2]` is `x² − 3x + 2`.
///
/// The coefficient form is the interchange form of an LTI system (§6.3.1); designs never pass
/// through it (REAL-1). Leading zeros are dropped when the polynomial is created, so `degree`
/// is the highest power that is present; the zero polynomial is `[0]`.
///
/// An immutable value, usable on any thread. Design maths: allocates, so not for the analysis
/// thread.
public struct Polynomial: Hashable, Sendable, CustomStringConvertible {
    /// The coefficients, highest power first. Never empty; the first one is non-zero unless
    /// the polynomial is zero. Usable on any thread.
    public let coefficients: [Double]

    /// The polynomial with the given coefficients, highest power first. Leading zeros are
    /// dropped; an empty list is the zero polynomial. Usable on any thread; allocates.
    public init(_ coefficients: [Double]) {
        if let first = coefficients.firstIndex(where: { $0 != 0 }) {
            self.coefficients = first == 0 ? coefficients : Array(coefficients[first...])
        } else {
            self.coefficients = [0]
        }
    }

    /// `leadingCoefficient · Π (x − rₖ)` for real roots. Usable on any thread; allocates.
    public init(realRoots: [Double], leadingCoefficient: Double = 1) {
        var product = [leadingCoefficient]
        for root in realRoots { product = Self.multiply(product, [1, -root]) }
        self.init(product)
    }

    /// `leadingCoefficient · Π (x − rₖ)` for roots that are real or come in conjugate pairs.
    ///
    /// Each pair is multiplied out as one real quadratic, `x² − 2·Re r·x + |r|²`, so no
    /// imaginary residue is ever formed and dropped. A root counts as real when its imaginary
    /// part is within 100 ε of its magnitude; two roots are a pair when they agree to the same
    /// tolerance. Usable on any thread; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when a root is not finite or a complex root has
    ///   no conjugate among the others.
    public init(roots: [Complex], leadingCoefficient: Double = 1) throws(DSPError) {
        let split = try ConjugatePairs.split(roots, parameter: "roots")
        var product = [leadingCoefficient]
        for pair in split.pairs {
            product = Self.multiply(product, [1, -2 * pair.real, pair.squaredMagnitude])
        }
        for root in split.reals { product = Self.multiply(product, [1, -root]) }
        self.init(product)
    }

    /// The zero polynomial. Usable on any thread.
    public static let zero = Polynomial([0])
    /// The constant 1. Usable on any thread.
    public static let one = Polynomial([1])

    /// The highest power present; 0 for a constant, the zero polynomial included. Usable on
    /// any thread.
    public var degree: Int { coefficients.count - 1 }

    /// The coefficient of the highest power; 0 only for the zero polynomial. Usable on any
    /// thread.
    public var leadingCoefficient: Double { coefficients[0] }

    /// True for the zero polynomial. Usable on any thread.
    public var isZero: Bool { coefficients.count == 1 && coefficients[0] == 0 }

    /// The value at a real point, by Horner's rule. Usable on any thread; allocation-free.
    public func evaluate(at x: Double) -> Double {
        var value = 0.0
        for coefficient in coefficients { value = value * x + coefficient }
        return value
    }

    /// The value at a complex point, by Horner's rule. Usable on any thread; allocation-free.
    public func evaluate(at z: Complex) -> Complex {
        var real = 0.0
        var imaginary = 0.0
        for coefficient in coefficients {
            let nextReal = real * z.real - imaginary * z.imaginary + coefficient
            imaginary = real * z.imaginary + imaginary * z.real
            real = nextReal
        }
        return Complex(real, imaginary)
    }

    /// The first derivative. The derivative of a constant is the zero polynomial. Usable on
    /// any thread; allocates.
    public var derivative: Polynomial {
        let degree = self.degree
        guard degree > 0 else { return .zero }
        var result = [Double](repeating: 0, count: degree)
        for index in 0 ..< degree { result[index] = coefficients[index] * Double(degree - index) }
        return Polynomial(result)
    }

    /// The product of two polynomials: the convolution of their coefficients. Usable on any
    /// thread; allocates.
    public static func * (lhs: Polynomial, rhs: Polynomial) -> Polynomial {
        Polynomial(multiply(lhs.coefficients, rhs.coefficients))
    }

    /// A readable form. Usable on any thread.
    public var description: String {
        let degree = self.degree
        var terms: [String] = []
        for (index, coefficient) in coefficients.enumerated() where coefficient != 0 || degree == 0 {
            let power = degree - index
            switch power {
            case 0: terms.append("\(coefficient)")
            case 1: terms.append("\(coefficient)·x")
            default: terms.append("\(coefficient)·x^\(power)")
            }
        }
        return terms.joined(separator: " + ")
    }

    // MARK: Internals

    /// The convolution of two coefficient lists.
    static func multiply(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: lhs.count + rhs.count - 1)
        for (i, a) in lhs.enumerated() where a != 0 {
            for (j, b) in rhs.enumerated() { result[i + j] += a * b }
        }
        return result
    }

    /// True when every coefficient is finite.
    var isFinite: Bool { coefficients.allSatisfy(\.isFinite) }
}
