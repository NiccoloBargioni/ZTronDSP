import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

@Suite("Polynomial (WP-401)")
struct PolynomialTests {
    private let p = Polynomial([2, -3, 0.5, 4])          // 2x³ − 3x² + 0.5x + 4
    private let q = Polynomial([1, 0.25, -1.5])           // x² + 0.25x − 1.5
    private let points: [Double] = [-3.5, -1, -0.125, 0, 0.75, 1, 2.5, 17]
    private let complexPoints: [Complex] = [Complex(0, 1), Complex(0.3, -0.4), Complex(-2, 0.5), Complex(1.5, 2.5), Complex(0, 0)]

    @Test func coefficientsAreStoredHighestPowerFirstWithoutLeadingZeros() {
        #expect(p.coefficients == [2, -3, 0.5, 4])
        #expect(p.degree == 3)
        #expect(p.leadingCoefficient == 2)
        #expect(Polynomial([0, 0, 1, 2]).coefficients == [1, 2])
        #expect(Polynomial([0, 0, 1, 2]).degree == 1)
        #expect(Polynomial([0, 0, 1, 2]) == Polynomial([1, 2]))
        #expect(Polynomial([1, 2, 0]).coefficients == [1, 2, 0], "trailing zeros are roots at the origin, not padding")
    }

    @Test func theZeroPolynomialAndConstants() {
        #expect(Polynomial([]).isZero)
        #expect(Polynomial([0, 0]).isZero)
        #expect(Polynomial([]) == .zero)
        #expect(Polynomial.zero.coefficients == [0])
        #expect(Polynomial.zero.degree == 0)
        #expect(Polynomial.zero.evaluate(at: 3) == 0)
        #expect(Polynomial.zero.derivative.isZero)
        #expect(!Polynomial.one.isZero)
        #expect(Polynomial.one.evaluate(at: -7) == 1)
        #expect(Polynomial([5]).degree == 0)
        #expect(Polynomial([5]).derivative.isZero)
        #expect((Polynomial.zero * p).isZero)
        #expect(Polynomial.one * p == p)
    }

    @Test func evaluationAtARealPointIsHornersRule() {
        #expect(p.evaluate(at: 0) == 4)
        #expect(p.evaluate(at: 1) == 3.5)
        #expect(p.evaluate(at: 2) == 9.0)
        #expect(p.evaluate(at: -1) == -1.5)
        for x in points {
            let cubic: Double = 2 * x * x * x
            let square: Double = 3 * x * x
            let direct: Double = cubic - square + 0.5 * x + 4
            expectClose(p.evaluate(at: x), direct, .relative(1e-14))
        }
    }

    @Test func evaluationAtAComplexPointAgreesWithTheRealOneOnTheRealAxis() {
        for x in points {
            let value = p.evaluate(at: Complex(x))
            #expect(value.real == p.evaluate(at: x))
            #expect(value.imaginary == 0)
        }
        // p(j) = 2j³ − 3j² + 0.5j + 4 = −2j + 3 + 0.5j + 4 = 7 − 1.5j
        #expect(p.evaluate(at: .i) == Complex(7, -1.5))
        for z in complexPoints {
            let cubic: Complex = 2 * (z * z * z)
            let square: Complex = 3 * (z * z)
            let direct: Complex = cubic - square + 0.5 * z + 4
            let value = p.evaluate(at: z)
            expectClose(value.real, direct.real, .absolute(1e-12))
            expectClose(value.imaginary, direct.imaginary, .absolute(1e-12))
        }
    }

    @Test func aRealPolynomialMapsConjugatesToConjugates() {
        for z in complexPoints {
            #expect(p.evaluate(at: z.conjugate) == p.evaluate(at: z).conjugate)
        }
    }

    @Test func theProductEvaluatesToTheProductOfTheValues() {
        let product = p * q
        #expect(product.degree == p.degree + q.degree)
        #expect(product.coefficients == [2, -2.5, -3.25, 8.625, 0.25, -6])
        #expect(product == q * p, "multiplication commutes")
        for x in points {
            expectClose(product.evaluate(at: x), p.evaluate(at: x) * q.evaluate(at: x), .relative(1e-13))
        }
        for z in complexPoints {
            let expected = p.evaluate(at: z) * q.evaluate(at: z)
            let value = product.evaluate(at: z)
            expectClose(value.real, expected.real, .absolute(1e-11))
            expectClose(value.imaginary, expected.imaginary, .absolute(1e-11))
        }
        let r = Polynomial([-1, 4])
        #expect((p * q) * r == p * (q * r), "multiplication associates on exactly representable coefficients")
    }

    @Test func theDerivativeFollowsThePowerRuleAndTheProductRule() {
        #expect(p.derivative.coefficients == [6, -6, 0.5])
        #expect(Polynomial([1, 0, 0, 0, 0]).derivative.coefficients == [4, 0, 0, 0])
        #expect(p.derivative.derivative.derivative.coefficients == [12])
        #expect(p.derivative.derivative.derivative.derivative.isZero)
        // (p·q)′ = p′·q + p·q′, checked through values because the type has no sum.
        let left = (p * q).derivative
        for x in points {
            let first: Double = p.derivative.evaluate(at: x) * q.evaluate(at: x)
            let second: Double = p.evaluate(at: x) * q.derivative.evaluate(at: x)
            let right = first + second
            expectClose(left.evaluate(at: x), right, .relative(1e-12))
        }
        // Against a central difference.
        for x in [-1.5, 0.25, 2.0] {
            let h = 1e-5
            let numeric = (p.evaluate(at: x + h) - p.evaluate(at: x - h)) / (2 * h)
            expectClose(p.derivative.evaluate(at: x), numeric, .relative(1e-8))
        }
    }

    @Test func aPolynomialFromRealRootsVanishesAtThem() {
        let roots: [Double] = [-2, 0.5, 0.5, 3]
        let polynomial = Polynomial(realRoots: roots, leadingCoefficient: -2)
        #expect(polynomial.degree == 4)
        #expect(polynomial.leadingCoefficient == -2)
        #expect(polynomial.coefficients == [-2, 4, 9.5, -11.5, 3])
        for root in roots { #expect(polynomial.evaluate(at: root) == 0) }
        #expect(polynomial.derivative.evaluate(at: 0.5) == 0, "a double root is a root of the derivative")
        #expect(Polynomial(realRoots: []) == .one)
        #expect(Polynomial(realRoots: [], leadingCoefficient: 0).isZero)
    }

    @Test func aPolynomialFromConjugateRootsHasRealCoefficientsAndVanishesAtThem() throws {
        let roots = [Complex(0.3, 0.4), Complex(-0.9), Complex(0.3, -0.4), Complex(2, -1), Complex(2, 1)]
        let polynomial = try Polynomial(roots: roots, leadingCoefficient: 3)
        #expect(polynomial.degree == 5)
        #expect(polynomial.leadingCoefficient == 3)
        for root in roots {
            #expect(polynomial.evaluate(at: root).magnitude <= 1e-13, "p(\(root)) = \(polynomial.evaluate(at: root))")
        }
        // (x² − 0.6x + 0.25)(x + 0.9)(x² − 4x + 5), multiplied out by hand.
        let expected = Polynomial([1, -0.6, 0.25]) * Polynomial([1, 0.9]) * Polynomial([1, -4, 5])
        expectClose(polynomial.coefficients, expected.coefficients.map { 3 * $0 }, .relative(1e-14))
        // Vieta: the coefficient after the leading one is minus the sum of the roots.
        expectClose(polynomial.coefficients[1] / 3, -3.7, .relative(1e-14))
        // The constant term is (−1)ⁿ times the product of the roots.
        expectClose(polynomial.coefficients[5] / 3, 1.125, .relative(1e-14))
        #expect(try Polynomial(roots: []) == .one)
        #expect(try Polynomial(roots: [Complex(1.5)]).coefficients == [1, -1.5])
    }

    @Test func rootsThatAreNotClosedUnderConjugationAreATypedError() {
        #expect(thrownError { _ = try Polynomial(roots: [Complex(0.3, 0.4)]) }?.invalidParameterName == "roots")
        #expect(thrownError { _ = try Polynomial(roots: [Complex(0.3, 0.4), Complex(0.3, -0.5)]) }?.invalidParameterName == "roots")
        #expect(thrownError { _ = try Polynomial(roots: [Complex(0.3, 0.4), Complex(0.31, -0.4)]) }?.invalidParameterName == "roots")
        #expect(thrownError { _ = try Polynomial(roots: [Complex(.nan, 0)]) }?.invalidParameterName == "roots")
        #expect(thrownError { _ = try Polynomial(roots: [Complex(1, .infinity), Complex(1, -.infinity)]) }?.invalidParameterName == "roots")
        // A pair that agrees to rounding is a pair.
        #expect(throws: Never.self) { _ = try Polynomial(roots: [Complex(0.3, 0.4), Complex(0.3 + 1e-16, -0.4)]) }
    }

    @Test func itIsAValueWithADescription() {
        #expect(p == Polynomial([2, -3, 0.5, 4]))
        #expect(p != q)
        #expect(Set([p, q, Polynomial([2, -3, 0.5, 4])]).count == 2)
        #expect(Polynomial([1, 0, -2]).description == "1.0·x^2 + -2.0")
        #expect(Polynomial([3, 1]).description == "3.0·x + 1.0")
        #expect(Polynomial.zero.description == "0.0")
    }
}
