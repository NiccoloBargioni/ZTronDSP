import Foundation

/// A complex number in double precision: the currency of design maths (poles, zeros,
/// responses; §6.1). The signal path does not use it; samples and spectra are `Float`.
///
/// An immutable value, usable on any thread. Its arithmetic does not allocate; only
/// ``description`` allocates, for the string it returns.
public struct Complex: Hashable, Sendable, CustomStringConvertible {
    /// The real part.
    public let real: Double
    /// The imaginary part.
    public let imaginary: Double

    /// The number `real + j·imaginary`; without an imaginary part it is a real number.
    @inlinable
    public init(_ real: Double, _ imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }

    /// The number with the given magnitude and phase (in radians).
    @inlinable
    public init(magnitude: Double, phase: Double) {
        self.init(magnitude * cos(phase), magnitude * sin(phase))
    }

    /// The number zero.
    public static let zero = Complex(0, 0)
    /// The number one.
    public static let one = Complex(1, 0)
    /// The imaginary unit.
    public static let i = Complex(0, 1)

    /// `|z|`, computed without intermediate overflow.
    @inlinable public var magnitude: Double { hypot(real, imaginary) }
    /// `|z|²`.
    @inlinable public var squaredMagnitude: Double { real * real + imaginary * imaginary }
    /// The argument, in `−π … π`.
    @inlinable public var phase: Double { atan2(imaginary, real) }
    /// The complex conjugate: the same real part, the imaginary part negated.
    @inlinable public var conjugate: Complex { Complex(real, -imaginary) }
    /// True when both parts are finite, neither infinite nor NaN.
    @inlinable public var isFinite: Bool { real.isFinite && imaginary.isFinite }
    /// True when the imaginary part is exactly zero.
    @inlinable public var isReal: Bool { imaginary == 0 }

    /// `1 / z`.
    @inlinable public var reciprocal: Complex { Complex.one / self }

    /// The sum, part by part.
    @inlinable
    public static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    /// The difference, part by part.
    @inlinable
    public static func - (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real - rhs.real, lhs.imaginary - rhs.imaginary)
    }

    /// The product.
    @inlinable
    public static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
                lhs.real * rhs.imaginary + lhs.imaginary * rhs.real)
    }

    /// Division by Smith's method, which does not overflow where the plain formula would.
    @inlinable
    public static func / (lhs: Complex, rhs: Complex) -> Complex {
        if abs(rhs.real) >= abs(rhs.imaginary) {
            if rhs.real == 0 { return Complex(lhs.real / rhs.real, lhs.imaginary / rhs.real) }
            let ratio = rhs.imaginary / rhs.real
            let denominator = rhs.real + rhs.imaginary * ratio
            return Complex((lhs.real + lhs.imaginary * ratio) / denominator,
                           (lhs.imaginary - lhs.real * ratio) / denominator)
        }
        let ratio = rhs.real / rhs.imaginary
        let denominator = rhs.real * ratio + rhs.imaginary
        return Complex((lhs.real * ratio + lhs.imaginary) / denominator,
                       (lhs.imaginary * ratio - lhs.real) / denominator)
    }

    /// Both parts negated.
    @inlinable public static prefix func - (value: Complex) -> Complex { Complex(-value.real, -value.imaginary) }

    /// The sum with a real number, which changes only the real part.
    @inlinable public static func + (lhs: Complex, rhs: Double) -> Complex { Complex(lhs.real + rhs, lhs.imaginary) }
    /// The sum with a real number, which changes only the real part.
    @inlinable public static func + (lhs: Double, rhs: Complex) -> Complex { Complex(lhs + rhs.real, rhs.imaginary) }
    /// The difference with a real number, which changes only the real part.
    @inlinable public static func - (lhs: Complex, rhs: Double) -> Complex { Complex(lhs.real - rhs, lhs.imaginary) }
    /// A real number minus a complex one.
    @inlinable public static func - (lhs: Double, rhs: Complex) -> Complex { Complex(lhs - rhs.real, -rhs.imaginary) }
    /// The product with a real number, which scales both parts.
    @inlinable public static func * (lhs: Complex, rhs: Double) -> Complex { Complex(lhs.real * rhs, lhs.imaginary * rhs) }
    /// The product with a real number, which scales both parts.
    @inlinable public static func * (lhs: Double, rhs: Complex) -> Complex { Complex(lhs * rhs.real, lhs * rhs.imaginary) }
    /// The quotient by a real number, which divides both parts.
    @inlinable public static func / (lhs: Complex, rhs: Double) -> Complex { Complex(lhs.real / rhs, lhs.imaginary / rhs) }
    /// A real number divided by a complex one, by Smith's method as in the complex division.
    @inlinable public static func / (lhs: Double, rhs: Complex) -> Complex { Complex(lhs) / rhs }

    /// `e^z`.
    @inlinable
    public static func exp(_ z: Complex) -> Complex {
        Complex(magnitude: Foundation.exp(z.real), phase: z.imaginary)
    }

    /// The principal logarithm: `ln|z| + j·arg z`.
    @inlinable
    public static func log(_ z: Complex) -> Complex {
        Complex(Foundation.log(z.magnitude), z.phase)
    }

    /// The principal square root, by the formula that avoids cancellation.
    @inlinable
    public static func sqrt(_ z: Complex) -> Complex {
        if z.real == 0 && z.imaginary == 0 { return .zero }
        let magnitude = z.magnitude
        if z.real >= 0 {
            let t = ((magnitude + z.real) / 2).squareRoot()
            return Complex(t, z.imaginary / (2 * t))
        }
        let t = ((magnitude - z.real) / 2).squareRoot()
        // The sign of a zero imaginary part chooses the side of the branch cut.
        return Complex(abs(z.imaginary) / (2 * t), z.imaginary.sign == .minus ? -t : t)
    }

    /// `z` raised to a whole power, by repeated squaring.
    public static func pow(_ z: Complex, _ exponent: Int) -> Complex {
        if exponent < 0 { return pow(z, -exponent).reciprocal }
        var result = Complex.one
        var base = z
        var remaining = exponent
        while remaining > 0 {
            if remaining & 1 == 1 { result = result * base }
            base = base * base
            remaining >>= 1
        }
        return result
    }

    /// The number written as `a + bj` or `a - bj`.
    public var description: String {
        imaginary.sign == .minus ? "\(real) - \(-imaginary)j" : "\(real) + \(imaginary)j"
    }
}
