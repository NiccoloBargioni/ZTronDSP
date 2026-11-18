import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-410: the roots of the reverse Bessel polynomial, from Campos starting values refined by
/// Aberth iteration, to a residual of 1e-12 for orders up to 25.
@Suite("Bessel polynomial roots (WP-410)")
struct BesselPolynomialTests {
    @Test func theCoefficientsAreThoseOfTheReverseBesselPolynomial() {
        #expect(BesselPolynomial.coefficients(order: 0) == [1])
        #expect(BesselPolynomial.coefficients(order: 1) == [1, 1])
        #expect(BesselPolynomial.coefficients(order: 2) == [1, 3, 3])
        #expect(BesselPolynomial.coefficients(order: 3) == [1, 6, 15, 15])
        #expect(BesselPolynomial.coefficients(order: 4) == [1, 10, 45, 105, 105])
        #expect(BesselPolynomial.coefficients(order: 5) == [1, 15, 105, 420, 945, 945])
        // The recurrence θₙ = (2n − 1)·θₙ₋₁ + s²·θₙ₋₂, coefficient by coefficient: exactly while
        // the integers fit a double (the largest stays below 2⁵³ up to order 15), to rounding
        // beyond.
        for order in 2 ... 25 {
            let current = BesselPolynomial.coefficients(order: order)
            let previous = BesselPolynomial.coefficients(order: order - 1)
            let beforeThat = BesselPolynomial.coefficients(order: order - 2)
            for index in 0 ... order {
                let fromPrevious = index >= 1 ? Double(2 * order - 1) * previous[index - 1] : 0
                let fromBefore = index <= order - 2 ? beforeThat[index] : 0
                if order <= 15 {
                    #expect(current[index] == fromPrevious + fromBefore, "order \(order), coefficient \(index)")
                } else {
                    expectClose(current[index], fromPrevious + fromBefore, .relative(4e-16), "order \(order), coefficient \(index)")
                }
            }
        }
        // The constant term is (2n − 1)!!, and equals the coefficient next to it.
        let largest = BesselPolynomial.coefficients(order: 25)
        var doubleFactorial = 1.0
        for factor in stride(from: 1.0, through: 49, by: 2) { doubleFactorial *= factor }
        expectClose(largest[25], doubleFactorial, .relative(1e-15))
        #expect(largest[24] == largest[25])
    }

    @Test func theResidualIsBelowTenToTheMinusTwelveUpToOrderTwentyFive() throws {
        #expect(BesselPolynomial.maximumOrder == 25)
        var worst = 0.0
        for order in 1 ... 25 {
            let roots = try BesselPolynomial.roots(order: order)
            #expect(roots.count == order)
            let polynomial = Polynomial(BesselPolynomial.coefficients(order: order))
            for root in roots {
                // The acceptance figure: |θ(r)| against the size of its terms, evaluated in
                // extended precision so that the figure is the root's and not the evaluation's.
                let residual = BesselPolynomial.relativeResidual(order: order, at: root)
                worst = max(worst, residual)
                #expect(residual <= 1e-12, "order \(order): residual \(residual) at \(root)")
                // A plain double-precision evaluation agrees that the root is a root.
                var scale = 0.0
                for coefficient in polynomial.coefficients { scale = scale * root.magnitude + coefficient }
                #expect(polynomial.evaluate(at: root).magnitude <= 1e-12 * scale, "order \(order)")
                #expect(root.real < 0, "order \(order): the poles of a Bessel filter lie in the left half plane")
            }
        }
        Measurements.shared.record("WP-410 Bessel roots, residual relative to the terms (orders 1…25)", worst, bound: 1e-12)
    }

    @Test func theRootsAreTheRootsAndNotJustSmallResiduals() throws {
        // Vieta, which a residual cannot fake: the roots sum to −a₍ₙ₋₁₎ = −n(n + 1)/2 and
        // multiply to (−1)ⁿ·(2n − 1)!!.
        for order in [1, 2, 3, 8, 15, 25] {
            let roots = try BesselPolynomial.roots(order: order)
            var sum = Complex.zero
            var product = Complex.one
            for root in roots {
                sum = sum + root
                product = product * (-root)
            }
            expectClose(sum.real, -Double(order * (order + 1)) / 2, .relative(1e-13), "order \(order): sum")
            #expect(abs(sum.imaginary) <= 1e-12)
            var doubleFactorial = 1.0
            for factor in stride(from: 1, to: 2 * order, by: 2) { doubleFactorial *= Double(factor) }
            expectClose(product.real, doubleFactorial, .relative(1e-12), "order \(order): product")
        }
        #expect(try BesselPolynomial.roots(order: 1) == [Complex(-1)])
        expectRootsClose(try BesselPolynomial.roots(order: 2), [Complex(-1.5, 0.75.squareRoot()), Complex(-1.5, -0.75.squareRoot())], relative: 1e-15, "order 2")
    }

    @Test func theRootsAreExactlyConjugateSymmetric() throws {
        for order in 1 ... 25 {
            let roots = try BesselPolynomial.roots(order: order)
            for index in 0 ..< order {
                #expect(roots[index] == roots[order - 1 - index].conjugate, "order \(order), root \(index)")
            }
            if order % 2 == 1 { #expect(roots[order / 2].imaginary == 0) }
        }
    }

    /// The mitigation of §7.5 row 4 for the Bessel roots: evaluation in double-double
    /// arithmetic. The condition number of a root reaches 8·10¹² at order 25, so a plain
    /// double evaluation cannot place it better than about 10⁻³; the prototype's golden
    /// tolerance of 10⁻⁹ is met only because the refinement does not see that error.
    @Test func stressTheRootsAreFarMoreAccurateThanTheirConditioningAllowsInDoublePrecision() throws {
        let order = 25
        let polynomial = Polynomial(BesselPolynomial.coefficients(order: order))
        let roots = try BesselPolynomial.roots(order: order)
        let worstCondition = try #require(roots.map { polynomial.rootCondition(at: $0) }.max())
        Measurements.shared.record("WP-410 Bessel order 25, largest root condition number (hazard)", worstCondition, bound: 1e16)
        #expect(worstCondition > 1e12, "the roots are ill-conditioned: κ = \(worstCondition)")
        // One Newton step in extended precision from the returned root does not move it by
        // more than a few units in the last place: the root is converged to working precision.
        for root in roots {
            #expect(BesselPolynomial.relativeResidual(order: order, at: root) * worstCondition < 1e-12 * worstCondition)
            #expect(BesselPolynomial.relativeResidual(order: order, at: root) <= 4 * Double.ulpOfOne,
                    "a residual of \(BesselPolynomial.relativeResidual(order: order, at: root)) leaves κ·residual above the golden tolerance")
        }
    }

    @Test func invalidOrdersAndAStalledIterationAreTypedErrors() {
        #expect(thrownError { _ = try BesselPolynomial.roots(order: 0) }?.invalidParameterName == "order")
        #expect(thrownError { _ = try BesselPolynomial.roots(order: -2) }?.invalidParameterName == "order")
        #expect(thrownError { _ = try BesselPolynomial.roots(order: 26) }?.isUnsupportedConfiguration == true)
        // Too few iterations to settle: reported, not returned half-converged.
        let failure = thrownError { _ = try BesselPolynomial.roots(order: 12, maximumIterations: 1) }?.numericalFailure
        #expect(failure?.routine == "besselRoots" && failure?.info == 12)
        #expect(thrownError { _ = try BesselPolynomial.roots(order: 12, maximumIterations: 0) }?.numericalFailure != nil)
        // Convergence needs only a handful.
        #expect(throws: Never.self) { _ = try BesselPolynomial.roots(order: 25, maximumIterations: 8) }
    }
}
