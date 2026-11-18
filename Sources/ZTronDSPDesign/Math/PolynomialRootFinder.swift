import ZTronDSPCore

/// How the roots of a polynomial are found (§5.3). A strategy: pass `.companionQR`, or a
/// conformer of your own, wherever a root finder is asked for.
///
/// Root finding is the ill-conditioned step of LTI analysis, which is why designs stay in
/// zero-pole-gain form and only a system that was *given* as coefficients comes here
/// (§6.3.8). Conformers are immutable values, usable on any thread; finding roots allocates
/// and is design maths, not for the analysis thread.
public protocol PolynomialRootFinder: Hashable, Sendable {
    /// The roots of `polynomial`, with their multiplicity: as many as its degree. Complex
    /// roots come in conjugate pairs, since the coefficients are real.
    ///
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for the zero polynomial or a coefficient that is
    ///   not finite; `DSPError.unsupportedConfiguration` above the degree the finder
    ///   supports; `DSPError.numericalFailure` when the underlying routine fails.
    func roots(of polynomial: Polynomial) throws(DSPError) -> [Complex]
}

extension PolynomialRootFinder {
    /// The condition number of each root of `polynomial` with respect to its coefficients,
    /// in the order of ``roots(of:)``:
    ///
    ///     κ(r) = Σ |aₖ|·|r|ᵏ / (|r|·|p′(r)|)
    ///
    /// A simple root found from coefficients is wrong by about κ(r)·ε (§6.3.8). A multiple
    /// root, where `p′(r)` vanishes, has the condition `.infinity`; a root at the origin is
    /// read from the trailing zero coefficients, is exact, and has the condition 0.
    ///
    /// Control or background context; allocates.
    public func rootConditions(of polynomial: Polynomial) throws(DSPError) -> [Double] {
        let roots = try self.roots(of: polynomial)
        return roots.map { polynomial.rootCondition(at: $0) }
    }
}

extension Polynomial {
    /// The condition number of `root` with respect to the coefficients of this polynomial,
    /// `κ(r) = Σ |aₖ|·|r|ᵏ / (|r|·|p′(r)|)` (§6.3.8): `.infinity` where the derivative
    /// vanishes (a multiple root) and 0 at the origin. Usable on any thread; allocation-free.
    public func rootCondition(at root: Complex) -> Double {
        let radius = root.magnitude
        guard radius > 0 else { return 0 }
        var weighted = 0.0
        var slopeReal = 0.0
        var slopeImaginary = 0.0
        let degree = self.degree
        for (index, coefficient) in coefficients.enumerated() {
            weighted = weighted * radius + abs(coefficient)
            guard index < degree else { continue }
            let factor = coefficient * Double(degree - index)
            let nextReal = slopeReal * root.real - slopeImaginary * root.imaginary + factor
            slopeImaginary = slopeReal * root.imaginary + slopeImaginary * root.real
            slopeReal = nextReal
        }
        let slope = Complex(slopeReal, slopeImaginary).magnitude
        guard slope > 0, slope.isFinite, weighted.isFinite else { return .infinity }
        return weighted / (radius * slope)
    }
}

/// The stock root finder (§7.2, row 12): closed form up to degree 2; above it, the
/// eigenvalues of the companion matrix, balanced by scaling only, found by the Hessenberg QR
/// algorithm, then at most two Newton steps on the original polynomial.
///
/// - Roots at the origin are read from the trailing zero coefficients and are exact.
/// - The companion matrix is upper Hessenberg as it stands. Balancing by scaling only
///   (LAPACK `dgebal`, `JOB = 'S'`) is a diagonal similarity, so it stays Hessenberg, and
///   `dhseqr` runs on it directly.
/// - The Newton steps evaluate the polynomial in double-double arithmetic, because next to a
///   root a plain evaluation has no correct digit left; a step is kept only when it lowers
///   the residual, so a multiple root, where Newton's method is erratic, is left alone.
///
/// The cost is O(n³) and the degree is capped at 512. The accuracy is the conditioning of
/// the roots: about κ(r)·ε, and ε^(1/m) for a root of multiplicity m
/// (`Docs/Numerics/polynomial-roots.md`).
///
/// An immutable value, usable on any thread. Finding roots allocates: design maths, not for
/// the analysis thread.
public struct CompanionQRRootFinder: PolynomialRootFinder {
    /// The highest degree the finder accepts (§6.3.8). Usable on any thread.
    public static let maximumDegree = 512

    let balancing: Bool
    let polishSteps: Int

    /// The stock finder. Usable on any thread.
    public init() {
        balancing = true
        polishSteps = 2
    }

    /// A finder with one of its two mitigations weakened. A hook for the stress tests that
    /// show what each mitigation is for (NUMS-2); production code uses ``init()``.
    /// Usable on any thread.
    init(balancing: Bool, polishSteps: Int) {
        self.balancing = balancing
        self.polishSteps = max(0, polishSteps)
    }

    /// The roots of `polynomial`, with their multiplicity. Control or background context;
    /// allocates.
    public func roots(of polynomial: Polynomial) throws(DSPError) -> [Complex] {
        guard polynomial.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "polynomial", reason: "every coefficient must be finite")
        }
        guard !polynomial.isZero else {
            throw .invalidParameter(stage: .none, parameter: "polynomial", reason: "the zero polynomial has no finite set of roots")
        }
        guard polynomial.degree <= Self.maximumDegree else {
            throw .unsupportedConfiguration(reason: "roots are found for polynomials up to degree \(Self.maximumDegree); this one has degree \(polynomial.degree)")
        }

        // Roots at the origin: one for every trailing zero coefficient, exactly.
        var coefficients = polynomial.coefficients
        var atOrigin = 0
        while coefficients.count > 1, coefficients[coefficients.count - 1] == 0 {
            coefficients.removeLast()
            atOrigin += 1
        }
        let origin = [Complex](repeating: .zero, count: atOrigin)

        let degree = coefficients.count - 1
        switch degree {
        case 0:
            return origin
        case 1:
            return [Complex(-coefficients[1] / coefficients[0])] + origin
        case 2:
            return QuadraticRoots.roots(coefficients[0], coefficients[1], coefficients[2]) + origin
        default:
            return try companionRoots(coefficients) + origin
        }
    }

    private func companionRoots(_ coefficients: [Double]) throws(DSPError) -> [Complex] {
        let degree = coefficients.count - 1
        // The companion matrix of the monic polynomial, column by column: the first row holds
        // −aₖ/a₀ and the subdiagonal holds ones.
        var companion = [Double](repeating: 0, count: degree * degree)
        let leading = coefficients[0]
        for column in 0 ..< degree {
            companion[column * degree] = -coefficients[column + 1] / leading
            if column + 1 < degree { companion[column * degree + column + 1] = 1 }
        }
        guard companion.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "polynomial", reason: "the coefficients are too far apart in size to be divided by the leading one")
        }
        let eigenvalues = try LAPACK.hessenbergEigenvalues(of: companion, order: degree, balancing: balancing)

        let extended = coefficients.map { DoubleDouble($0) }
        var roots: [Complex] = []
        roots.reserveCapacity(degree)
        var index = 0
        while index < degree {
            let estimate = Complex(eigenvalues.real[index], eigenvalues.imaginary[index])
            let isPair = estimate.imaginary != 0 && index + 1 < degree
            let polished = polish(estimate, extended)
            roots.append(polished)
            if isPair {
                // The partner of a complex eigenvalue is its conjugate: polish one, mirror it.
                roots.append(polished.conjugate)
                index += 2
            } else {
                index += 1
            }
        }
        return roots
    }

    /// At most `polishSteps` Newton steps on the original polynomial. A step is kept only
    /// when it lowers the residual.
    private func polish(_ estimate: Complex, _ coefficients: [DoubleDouble]) -> Complex {
        var root = estimate
        guard polishSteps > 0, root.isFinite else { return root }
        var current = ExtendedHorner.evaluate(coefficients, at: root)
        for _ in 0 ..< polishSteps {
            let residual = current.value.magnitude
            guard residual > 0, current.derivative.magnitude > 0 else { break }
            let candidate = root - current.value / current.derivative
            guard candidate.isFinite else { break }
            let next = ExtendedHorner.evaluate(coefficients, at: candidate)
            guard next.value.magnitude < residual else { break }
            root = candidate
            current = next
        }
        return root
    }
}

extension PolynomialRootFinder where Self == CompanionQRRootFinder {
    /// Closed form up to degree 2; the balanced companion matrix, Hessenberg QR and a Newton
    /// polish above it. The default. Usable on any thread.
    public static var companionQR: CompanionQRRootFinder { CompanionQRRootFinder() }
}
