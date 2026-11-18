import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// The elliptic integrals and functions behind the elliptic prototype and its order
/// estimate (WP-408), all by Landen transformations (Orfanidis, *Lecture Notes on Elliptic
/// Filter Design*, 2006).
///
/// A Landen step replaces the modulus `k` by `k₁ = (k / (1 + k′))²`, which falls to zero
/// quadratically: seven steps reach the last bit from any modulus a double can hold. Every
/// function below is a short recursion over that sequence, with no iteration to a
/// tolerance, no minimiser and no subtraction of nearly equal numbers.
///
/// **Arguments.** The functions take the *parameter* `m = k²`, as SciPy does, together with
/// its complement `mc = 1 − m`. Passing both is what keeps them accurate at either end:
/// near `m = 1` the complement carries the digits that `1 − m` would lose.
///
/// A hook for the package's own tests and for the design code; allocation is limited to the
/// short modulus sequence. Usable on any thread.
enum EllipticFunctions {
    /// The descending Landen sequence `k₁, k₂, …` of the modulus with `k² = m`,
    /// `k′² = mc`, up to the first term that no longer changes `1 + k`.
    ///
    /// The modulus and its complement are carried side by side, `kₙ₊₁ = (kₙ / (1 + k′ₙ))²`
    /// and `k′ₙ₊₁ = 2·√k′ₙ / (1 + k′ₙ)`: each is a product of positive numbers, so neither
    /// loses digits, however close to 0 or to 1 the modulus starts. (Forming `k′` as
    /// `√(1 − k²)` at every step would cancel as long as `k` stays near 1.)
    /// Usable on any thread.
    static func landenSequence(m: Double, complement mc: Double) -> [Double] {
        var sequence: [Double] = []
        var k = m.squareRoot()
        var kComplement = mc.squareRoot()
        // Quadratic convergence: from the smallest complement a double holds, some twenty
        // steps; the bound is never reached.
        for _ in 0 ..< 64 {
            guard k > 1e-20, kComplement > 0 else { break }
            let denominator = 1 + kComplement
            let ratio = k / denominator
            k = ratio * ratio
            kComplement = 2 * kComplement.squareRoot() / denominator
            sequence.append(k)
        }
        return sequence
    }

    /// The complete elliptic integral of the first kind, `K(m)`, from the parameter and its
    /// complement: `K = (π/2)·Π(1 + kₙ)`.
    ///
    /// `m = 0` gives π/2. At `m = 1` (`mc = 0`) the integral diverges; the largest finite
    /// double is returned in place of infinity (NUM-1).
    /// Usable on any thread.
    static func completeIntegral(m: Double, complement mc: Double) -> Double {
        guard mc > 0 else { return .greatestFiniteMagnitude }
        var result = Double.pi / 2
        for k in landenSequence(m: m, complement: mc) { result *= 1 + k }
        return result
    }

    /// `K(m)` for a parameter known directly (accurate for `m` not close to 1).
    /// Usable on any thread.
    static func completeIntegral(m: Double) -> Double {
        completeIntegral(m: m, complement: 1 - m)
    }

    /// `K′(m) = K(1 − m)` for a parameter known directly (accurate for small `m`, where
    /// `K′` grows like `ln(4/√m)`).
    /// Usable on any thread.
    static func complementaryIntegral(m: Double) -> Double {
        completeIntegral(m: 1 - m, complement: m)
    }

    /// The solution `m` of the degree equation `n·K′(m)/K(m) = K′(m₁)/K(m₁)`, with its
    /// complement, through the nome: `q = q₁^(1/n)`, then the theta-function series
    ///
    ///     m = 16·q·( Σ_{j≥0} q^{j(j+1)} / (1 + 2·Σ_{j≥1} q^{j²}) )⁴.
    ///
    /// The complement is computed the same way from the complementary nome
    /// `q′ = exp(π² / ln q)`, never as `1 − m`, so it stays accurate when the solution is
    /// close to 1 (a high order). Both series are summed to convergence.
    /// Usable on any thread.
    static func degreeEquation(order: Int, m1: Double) -> (m: Double, complement: Double) {
        let ratio = complementaryIntegral(m: m1) / completeIntegral(m: m1)   // K′(m₁) / K(m₁)
        let logNome = -Double.pi * ratio / Double(order)
        let m = parameter(fromLogNome: logNome)
        let complement = logNome < 0 ? parameter(fromLogNome: Double.pi * Double.pi / logNome) : 0
        return (m, complement)
    }

    /// `k²` from the logarithm of its nome.
    private static func parameter(fromLogNome logNome: Double) -> Double {
        let q = exp(logNome)
        guard q > 0 else { return 0 }
        guard q < 1 else { return 1 }
        var numerator = 1.0
        var denominator = 1.0
        for j in 1 ... 2_000 {
            let upper = exp(logNome * Double(j * (j + 1)))
            let lower = exp(logNome * Double(j * j))
            numerator += upper
            denominator += 2 * lower
            if lower < 1e-18 { break }
        }
        let ratio = numerator / denominator
        return min(1, 16 * q * ratio * ratio * ratio * ratio)
    }

    /// The Jacobi elliptic functions `sn`, `cn`, `dn` of a real argument `u` for the
    /// parameter `m` (complement `mc`), by ascending the Landen sequence from the circular
    /// functions: `w ← (1 + kₙ)·w / (1 + kₙ·w²)`, started at `sin(πu/2K)` for `sn` and at
    /// `cos(πu/2K)` for `cd`. `dn` and `cn` follow from the two.
    /// Usable on any thread.
    static func jacobi(_ u: Double, m: Double, complement mc: Double) -> (sn: Double, cn: Double, dn: Double) {
        guard mc > 0 else {
            // m = 1: the functions degenerate to hyperbolic ones.
            let sech = 1 / cosh(u)
            return (tanh(u), sech, sech)
        }
        let sequence = landenSequence(m: m, complement: mc)
        var quarterPeriod = Double.pi / 2
        for k in sequence { quarterPeriod *= 1 + k }
        let angle = u / quarterPeriod * (Double.pi / 2)
        var sn = sin(angle)
        var cd = cos(angle)
        for k in sequence.reversed() {
            sn = (1 + k) * sn / (1 + k * sn * sn)
            cd = (1 + k) * cd / (1 + k * cd * cd)
        }
        // dn² = 1 − m·sn² = mc / (1 − m·cd²). The two differences multiply to mc, so the larger
        // one is at least √mc: take the form that subtracts the least.
        let fromSn = 1 - m * sn * sn
        let fromCd = 1 - m * cd * cd
        let dn = fromSn >= fromCd ? fromSn.squareRoot() : (mc / fromCd).squareRoot()
        return (sn, cd * dn, dn)
    }

    /// The inverse of `sn`: the `u` with `sn(u, m) = w`, for a complex `w`, by descending the
    /// Landen sequence: `w ← 2w / ((1 + kₙ₊₁)(1 + √(1 − kₙ²w²)))`, then
    /// `u = (2K/π)·asin(w)`.
    /// Usable on any thread.
    static func inverseSn(_ w: Complex, m: Double, complement mc: Double) -> Complex {
        guard mc > 0 else {
            // m = 1: sn is tanh, and its inverse ½·ln((1 + w)/(1 − w)).
            let logarithm = Complex.log((Complex.one + w) / (Complex.one - w))
            return Complex(logarithm.real / 2, logarithm.imaginary / 2)
        }
        var sequence = [m.squareRoot()]
        sequence += landenSequence(m: m, complement: mc)
        var quarterPeriod = Double.pi / 2
        for k in sequence.dropFirst() { quarterPeriod *= 1 + k }
        var value = w
        for index in 0 ..< sequence.count - 1 {
            let scaled = sequence[index] * value
            let complement = Complex.sqrt((Complex.one - scaled) * (Complex.one + scaled))
            value = 2 * value / ((1 + sequence[index + 1]) * (Complex.one + complement))
        }
        return (2 / Double.pi * quarterPeriod) * arcsine(value)
    }

    /// The inverse of `sc` for the complementary parameter: the real `u` with
    /// `sc(u, 1 − m) = w`. Since `sc(u, 1 − m) = −j·sn(ju, m)`, it is the imaginary part of
    /// `inverseSn(jw, m)`, and the recursion stays real:
    /// `y ← 2y / ((1 + kₙ₊₁)(1 + √(1 + kₙ²y²)))`, then `u = (2K/π)·asinh(y)`.
    /// Usable on any thread.
    static func inverseSc(_ w: Double, m: Double, complement mc: Double) -> Double {
        guard mc > 0 else { return atan(w) }   // m = 1: sc(u, 0) = tan u
        var sequence = [m.squareRoot()]
        sequence += landenSequence(m: m, complement: mc)
        var quarterPeriod = Double.pi / 2
        for k in sequence.dropFirst() { quarterPeriod *= 1 + k }
        var value = w
        for index in 0 ..< sequence.count - 1 {
            let scaled = sequence[index] * value
            value = 2 * value / ((1 + sequence[index + 1]) * (1 + (1 + scaled * scaled).squareRoot()))
        }
        return 2 / Double.pi * quarterPeriod * asinh(value)
    }

    /// The principal inverse sine of a complex number, by Kahan's formulas, which are
    /// accurate for small arguments and on both axes:
    /// `Re = atan2(Re z, Re(√(1 − z)·√(1 + z)))`, `Im = asinh(Im(conj(√(1 − z))·√(1 + z)))`.
    static func arcsine(_ z: Complex) -> Complex {
        let lower = Complex.sqrt(Complex.one - z)
        let upper = Complex.sqrt(Complex.one + z)
        return Complex(atan2(z.real, (lower * upper).real), asinh((lower.conjugate * upper).imaginary))
    }
}
