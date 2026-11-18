import ZTronDSPCore

/// Closed forms for polynomials of degree two and below. A second-order section's zeros and
/// poles are read through these, never through a general root finder (§6.3.8).
enum QuadraticRoots {
    /// The roots of `a·x² + b·x + c`: two for a quadratic, one when `a` is zero, none for a
    /// constant.
    ///
    /// The discriminant is formed with fused multiply-adds (Kahan), so it carries no rounding
    /// error of its own, and the real roots are taken in the order that avoids cancellation.
    /// A complex pair is returned with the positive imaginary part first.
    static func roots(_ a: Double, _ b: Double, _ c: Double) -> [Complex] {
        if a == 0 {
            return b == 0 ? [] : [Complex(-c / b)]
        }
        // Scale by a power of two, which is exact, so that squaring cannot overflow.
        let largest = max(abs(a), abs(b), abs(c))
        guard largest.isFinite else { return [Complex(.nan, .nan), Complex(.nan, .nan)] }
        let scale = Double(sign: .plus, exponent: -Int(largest.exponent), significand: 1)
        let a = a * scale
        let b = b * scale
        let c = c * scale

        let discriminant = accurateDiscriminant(a, b, c)
        if discriminant < 0 {
            let real = -b / (2 * a)
            let imaginary = (-discriminant).squareRoot() / (2 * abs(a))
            return [Complex(real, imaginary), Complex(real, -imaginary)]
        }
        let root = discriminant.squareRoot()
        let q = -(b + (b.sign == .minus ? -root : root)) / 2
        if q == 0 { return [Complex(0), Complex(0)] }   // b = 0 and c = 0: a double root at the origin
        return [Complex(q / a), Complex(c / q)]
    }

    /// `b² − 4ac` with the rounding errors of both products recovered.
    private static func accurateDiscriminant(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let square = b * b
        let squareError = (-square).addingProduct(b, b)
        let fourA = 4 * a
        let product = fourA * c
        let productError = (-product).addingProduct(fourA, c)
        return (square - product) + (squareError - productError)
    }
}
