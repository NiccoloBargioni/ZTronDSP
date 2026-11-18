import ZTronDSPCore

/// The reverse Bessel polynomial `θₙ(s) = Σ aₖ·sᵏ`, `aₖ = (2n − k)! / (2^(n−k)·k!·(n − k)!)`,
/// and its roots: the poles of the delay-normalised Bessel filter of order `n` (WP-410).
///
/// The roots are found as SciPy finds them: the closed-form approximation of Campos and
/// Calderón (arXiv:1105.0957) as starting values, refined simultaneously by the
/// Aberth–Ehrlich iteration. What differs is the evaluation. Beside its roots the polynomial
/// cancels almost every digit a double holds (the roots have condition numbers of 10¹⁰ at
/// order 20 and 8·10¹² at order 25), and the three-term recurrence is no better, because the
/// polynomial is its recessive solution near the negative real axis. So the polynomial and
/// its derivative are evaluated by Horner's rule in double-double arithmetic, on
/// coefficients that are themselves carried to 32 digits. That leaves a relative error of
/// about κ·10⁻³² in each root, well below one unit of the last place up to the largest
/// supported order (`Docs/Numerics/bessel-roots.md`).
///
/// A hook for the package's own tests and for the design code. Control or background
/// context; allocates.
enum BesselPolynomial {
    /// The largest order the roots are computed and verified for (§12, the grid of
    /// WP-405…411).
    /// Usable on any thread.
    static let maximumOrder = 25

    /// The coefficients of `θₙ`, highest power first, as integers rounded to double
    /// precision. They are exact up to order 15 (the largest is then below 2⁵³).
    /// Usable on any thread.
    static func coefficients(order: Int) -> [Double] {
        extendedCoefficients(order: order).map(\.value)
    }

    /// The coefficients in double-double precision, by the exact integer recurrence
    /// `aₖ₋₁ = aₖ·(2n − k + 1)·k / (2·(n − k + 1))` from `aₙ = 1`.
    static func extendedCoefficients(order: Int) -> [DoubleDouble] {
        var coefficients = [DoubleDouble](repeating: DoubleDouble(1), count: order + 1)
        guard order >= 1 else { return coefficients }
        for k in stride(from: order, through: 1, by: -1) {
            // Index 0 holds aₙ; the coefficient of sᵏ sits at index n − k.
            let factor = Double(2 * order - k + 1) * Double(k)
            let divisor = Double(2 * (order - k + 1))
            coefficients[order - k + 1] = coefficients[order - k] * factor / divisor
        }
        return coefficients
    }

    /// The starting values of Campos and Calderón for the zeros of the ordinary Bessel
    /// polynomial `yₙ(x) = xⁿ·θₙ(1/x)`: a fitted curve through the zeros, symmetric about the
    /// real axis.
    static func startingZeros(order n: Int) -> [Complex] {
        if n == 1 { return [Complex(-1)] }
        let x = Double(n)
        let fourth = x * x * x * x
        let s = 2 * x * x - 3 * fourth + fourth * x
        let b3 = (16 - 8 * x) / s
        let b2 = (-24 - 12 * x + 12 * x * x) / s
        let b1 = (8 + 24 * x - 12 * x * x - 2 * x * x * x) / s
        let b0 = (-6 * x + 5 * x * x * x - fourth) / s
        let r = 2 * x * x + x * x * x
        let a1 = (-6 - 6 * x) / r
        let a2 = 6 / r
        return (1 ... n).map { index in
            let k = Double(index)
            return Complex(a1 * k + a2 * k * k, b0 + b1 * k + b2 * k * k + b3 * k * k * k)
        }
    }

    /// The roots of `θₙ`, in conjugate-symmetric order: root `i` and root `n − 1 − i` are
    /// conjugates, and for an odd order the middle one is real.
    /// Usable on any thread.
    ///
    /// - Parameter maximumIterations: The bound on Aberth iterations. Convergence takes five
    ///   or six; the parameter exists so that a test can show the failure path.
    /// - Throws: `DSPError.invalidParameter` for an order below 1;
    ///   `DSPError.unsupportedConfiguration` above ``maximumOrder``;
    ///   `DSPError.numericalFailure(routine: "besselRoots", …)` when the iteration does not
    ///   settle.
    static func roots(order: Int, maximumIterations: Int = 50) throws(DSPError) -> [Complex] {
        guard order >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a filter order must be at least 1, not \(order)")
        }
        guard order <= maximumOrder else {
            throw .unsupportedConfiguration(reason: "Bessel prototypes are computed up to order \(maximumOrder); order \(order) was asked for")
        }
        let coefficients = extendedCoefficients(order: order)
        var roots = startingZeros(order: order).map(\.reciprocal)

        var settled = false
        for _ in 0 ..< max(0, maximumIterations) {
            var largestStep = 0.0
            var next = roots
            for index in roots.indices {
                let evaluated = ExtendedHorner.evaluate(coefficients, at: roots[index])
                // Newton's correction, damped by the repulsion of the other roots (Aberth).
                let newton = evaluated.value / evaluated.derivative
                var repulsion = Complex.zero
                for other in roots.indices where other != index {
                    repulsion = repulsion + (roots[index] - roots[other]).reciprocal
                }
                let step = newton / (Complex.one - newton * repulsion)
                next[index] = roots[index] - step
                largestStep = max(largestStep, step.magnitude / next[index].magnitude)
            }
            roots = next
            guard largestStep.isFinite else { break }
            if largestStep <= 4 * Double.ulpOfOne {
                settled = true
                break
            }
        }
        guard settled else {
            throw .numericalFailure(routine: "besselRoots", info: order)
        }

        // Conjugates are averaged, which makes the set exactly symmetric.
        for index in 0 ..< (order + 1) / 2 {
            let mirror = order - 1 - index
            let real = (roots[index].real + roots[mirror].real) / 2
            let imaginary = (roots[index].imaginary - roots[mirror].imaginary) / 2
            roots[index] = Complex(real, imaginary)
            roots[mirror] = Complex(real, index == mirror ? 0 : -imaginary)
        }
        return roots
    }

    /// The residual of `θₙ` at `root`, relative to the size of its terms:
    /// `|θₙ(r)| / Σ aₖ·|r|ᵏ`. The acceptance figure of WP-410.
    /// Usable on any thread.
    static func relativeResidual(order: Int, at root: Complex) -> Double {
        let coefficients = extendedCoefficients(order: order)
        let value = ExtendedHorner.evaluate(coefficients, at: root).value.magnitude
        var scale = 0.0
        let radius = root.magnitude
        for coefficient in coefficients { scale = scale * radius + coefficient.value }
        return value / scale
    }
}
