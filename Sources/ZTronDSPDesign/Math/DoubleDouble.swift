import ZTronDSPCore

/// An unevaluated sum of two doubles, `hi + lo` with `|lo| ≤ ulp(hi) / 2`: about 32 significant
/// digits. Design maths uses it in two places where a polynomial has to be evaluated beside
/// one of its roots, which cancels almost every digit a double holds: the Newton polish of
/// the root finder (§7.5, row 12) and the roots of the reverse Bessel polynomial (row 4).
///
/// The operations are the classical error-free transformations (Dekker 1971; Knuth's two-sum;
/// a fused multiply-add for the two-product). A value; usable on any thread.
struct DoubleDouble: Sendable {
    var hi: Double
    var lo: Double

    @inline(__always)
    init(_ value: Double) {
        hi = value
        lo = 0
    }

    @inline(__always)
    init(hi: Double, lo: Double) {
        self.hi = hi
        self.lo = lo
    }

    static let zero = DoubleDouble(0)

    /// The nearest double.
    @inline(__always) var value: Double { hi + lo }

    /// `a + b` exactly, as a rounded sum and its error.
    @inline(__always)
    static func twoSum(_ a: Double, _ b: Double) -> (sum: Double, error: Double) {
        let sum = a + b
        let virtual = sum - a
        return (sum, (a - (sum - virtual)) + (b - virtual))
    }

    /// `a + b` exactly, for `|a| ≥ |b|`.
    @inline(__always)
    static func quickTwoSum(_ a: Double, _ b: Double) -> (sum: Double, error: Double) {
        let sum = a + b
        return (sum, b - (sum - a))
    }

    /// `a · b` exactly, as a rounded product and its error.
    @inline(__always)
    static func twoProduct(_ a: Double, _ b: Double) -> (product: Double, error: Double) {
        let product = a * b
        return (product, (-product).addingProduct(a, b))
    }

    @inline(__always)
    static func + (lhs: DoubleDouble, rhs: DoubleDouble) -> DoubleDouble {
        var (sum, error) = twoSum(lhs.hi, rhs.hi)
        let (low, lowError) = twoSum(lhs.lo, rhs.lo)
        error += low
        (sum, error) = quickTwoSum(sum, error)
        error += lowError
        (sum, error) = quickTwoSum(sum, error)
        return DoubleDouble(hi: sum, lo: error)
    }

    @inline(__always)
    static func + (lhs: DoubleDouble, rhs: Double) -> DoubleDouble {
        var (sum, error) = twoSum(lhs.hi, rhs)
        error += lhs.lo
        (sum, error) = quickTwoSum(sum, error)
        return DoubleDouble(hi: sum, lo: error)
    }

    @inline(__always)
    static prefix func - (value: DoubleDouble) -> DoubleDouble {
        DoubleDouble(hi: -value.hi, lo: -value.lo)
    }

    @inline(__always)
    static func - (lhs: DoubleDouble, rhs: DoubleDouble) -> DoubleDouble {
        lhs + (-rhs)
    }

    @inline(__always)
    static func * (lhs: DoubleDouble, rhs: Double) -> DoubleDouble {
        var (product, error) = twoProduct(lhs.hi, rhs)
        error = error.addingProduct(lhs.lo, rhs)
        (product, error) = quickTwoSum(product, error)
        return DoubleDouble(hi: product, lo: error)
    }

    /// `lhs / rhs` for a non-zero double divisor, to within a few units of the last place of
    /// the pair.
    @inline(__always)
    static func / (lhs: DoubleDouble, rhs: Double) -> DoubleDouble {
        let first = lhs.hi / rhs
        let (product, productError) = twoProduct(first, rhs)
        let remainder = ((lhs.hi - product) - productError) + lhs.lo
        let (quotient, error) = quickTwoSum(first, remainder / rhs)
        return DoubleDouble(hi: quotient, lo: error)
    }
}

/// Horner's rule carried in double-double arithmetic.
enum ExtendedHorner {
    /// The value and the first derivative of the polynomial with the real `coefficients`
    /// (highest power first) at the complex point `point`, each rounded to double precision
    /// from a double-double evaluation.
    ///
    /// The relative error of the value is about `ε² · Σ|aₖ||z|ᵏ / |p(z)|` instead of the
    /// `ε · …` of a plain evaluation, so the Newton correction `p / p′` stays meaningful right
    /// beside a root. Allocation-free.
    static func evaluate(_ coefficients: [DoubleDouble], at point: Complex) -> (value: Complex, derivative: Complex) {
        let x = point.real
        let y = point.imaginary
        var valueReal = DoubleDouble.zero
        var valueImaginary = DoubleDouble.zero
        var slopeReal = DoubleDouble.zero
        var slopeImaginary = DoubleDouble.zero
        for coefficient in coefficients {
            // p′ ← p′·z + p, then p ← p·z + a.
            let nextSlopeReal = slopeReal * x - slopeImaginary * y + valueReal
            let nextSlopeImaginary = slopeReal * y + slopeImaginary * x + valueImaginary
            slopeReal = nextSlopeReal
            slopeImaginary = nextSlopeImaginary
            let nextValueReal = valueReal * x - valueImaginary * y + coefficient
            let nextValueImaginary = valueReal * y + valueImaginary * x
            valueReal = nextValueReal
            valueImaginary = nextValueImaginary
        }
        return (Complex(valueReal.value, valueImaginary.value), Complex(slopeReal.value, slopeImaginary.value))
    }
}
