import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-408: the complete integral, the degree equation and the inverse `sn` and `sc`, by
/// Landen transformations, against tabulated values to 1e-12 (relative).
@Suite("Elliptic helpers (WP-408)")
struct EllipticFunctionTests {
    private static let tolerance = 1e-12

    @Test func theCompleteIntegralMatchesTheTable() throws {
        let golden = try Golden.ellipticFunctions.get().require("complete-integral")
        let parameters = try golden.real("m")
        let expected = try golden.real("K")
        for (m, value) in zip(parameters, expected) {
            let computed = EllipticFunctions.completeIntegral(m: m)
            expectClose(computed, value, .relative(Self.tolerance), "K(\(m))")
            Measurements.shared.record("WP-408 complete integral K(m), relative", abs(computed - value) / value, bound: Self.tolerance)
            // With the complement stated the answer is the same.
            expectClose(EllipticFunctions.completeIntegral(m: m, complement: 1 - m), value, .relative(Self.tolerance))
        }
        // Close to m = 1, where K diverges like ln(4/√(1 − m)): the complement carries the digits.
        for (complement, value) in zip(try golden.real("complement"), try golden.real("K_near_one")) {
            let computed = EllipticFunctions.complementaryIntegral(m: complement)
            expectClose(computed, value, .relative(Self.tolerance), "K(1 − \(complement))")
            Measurements.shared.record("WP-408 complete integral near m = 1, relative", abs(computed - value) / value, bound: Self.tolerance)
        }
    }

    @Test func theCompleteIntegralAtTheEndsOfItsRange() {
        #expect(EllipticFunctions.completeIntegral(m: 0) == .pi / 2)
        // K′(m) is K of the complement: at m = ½ the two agree.
        #expect(EllipticFunctions.complementaryIntegral(m: 0.5) == EllipticFunctions.completeIntegral(m: 0.5))
        // Legendre's relation at the lemniscatic point: K(½) = Γ(¼)² / (4√π).
        expectClose(EllipticFunctions.completeIntegral(m: 0.5), 1.8540746773013719, .relative(1e-15))
        // m = 1: the integral diverges; the largest finite double stands in for infinity (NUM-1).
        #expect(EllipticFunctions.completeIntegral(m: 1, complement: 0) == .greatestFiniteMagnitude)
        #expect(EllipticFunctions.completeIntegral(m: 1).isFinite)
        // The Landen sequence falls quadratically: a handful of terms from any modulus.
        #expect(EllipticFunctions.landenSequence(m: 0, complement: 1).isEmpty)
        let sequence = EllipticFunctions.landenSequence(m: 0.999999, complement: 1e-6)
        #expect(sequence.count <= 9)
        #expect(zip(sequence, sequence.dropFirst()).allSatisfy { $1 < $0 })
    }

    @Test func theDegreeEquationMatchesTheTable() throws {
        let file = try Golden.ellipticFunctions.get()
        let cases = file.cases.filter { $0.name.hasPrefix("degree-") }
        #expect(cases.count == 4)
        for golden in cases {
            let m1 = try golden.number("m1")
            let orders = try golden.real("order")
            let parameters = try golden.real("m")
            let complements = try golden.real("complement")
            for index in orders.indices {
                let solution = EllipticFunctions.degreeEquation(order: Int(orders[index]), m1: m1)
                expectClose(solution.m, parameters[index], .relative(Self.tolerance), "\(golden.name) order \(orders[index]): m")
                expectClose(solution.complement, complements[index], .relative(Self.tolerance), "\(golden.name) order \(orders[index]): 1 − m")
                Measurements.shared.record("WP-408 degree equation m, relative", abs(solution.m - parameters[index]) / parameters[index], bound: Self.tolerance)
                Measurements.shared.record("WP-408 degree equation 1 − m, relative", abs(solution.complement - complements[index]) / complements[index], bound: Self.tolerance)
            }
        }
    }

    @Test func theDegreeEquationIsSatisfiedByItsSolution() {
        // n·K′(m)/K(m) = K′(m₁)/K(m₁), checked with the integrals themselves.
        for m1 in [1e-10, 1e-4, 0.01] {
            let target = EllipticFunctions.complementaryIntegral(m: m1) / EllipticFunctions.completeIntegral(m: m1)
            for order in [1, 4, 9, 30] {
                let solution = EllipticFunctions.degreeEquation(order: order, m1: m1)
                let ratio = EllipticFunctions.completeIntegral(m: solution.complement, complement: solution.m)
                    / EllipticFunctions.completeIntegral(m: solution.m, complement: solution.complement)
                expectClose(Double(order) * ratio, target, .relative(1e-12), "order \(order), m₁ = \(m1)")
                // Order 1 returns the parameter it was given.
                if order == 1 { expectClose(solution.m, m1, .relative(1e-12)) }
                expectClose(solution.m + solution.complement, 1, .relative(1e-14))
            }
        }
    }

    @Test func theJacobiFunctionsMatchTheTable() throws {
        let file = try Golden.ellipticFunctions.get()
        let cases = file.cases.filter { $0.name.hasPrefix("jacobi-") }
        #expect(cases.count == 10)
        for golden in cases {
            let m = try golden.number("m")
            let arguments = try golden.real("u")
            let sn = try golden.real("sn")
            let cn = try golden.real("cn")
            let dn = try golden.real("dn")
            for index in arguments.indices {
                let computed = EllipticFunctions.jacobi(arguments[index], m: m, complement: 1 - m)
                // cn vanishes at the odd multiples of K, where only an absolute comparison means anything.
                expectClose(computed.sn, sn[index], .absolute(Self.tolerance), "\(golden.name) sn(\(arguments[index]))")
                expectClose(computed.cn, cn[index], .absolute(Self.tolerance), "\(golden.name) cn(\(arguments[index]))")
                expectClose(computed.dn, dn[index], .relative(Self.tolerance), "\(golden.name) dn(\(arguments[index]))")
                Measurements.shared.record("WP-408 sn/cn (absolute) and dn (relative)", max(abs(computed.sn - sn[index]), abs(computed.cn - cn[index]), abs(computed.dn - dn[index]) / dn[index]), bound: Self.tolerance)
            }
        }
    }

    @Test func theJacobiFunctionsSatisfyTheirIdentitiesAndDegenerateCorrectly() {
        for m in [1e-9, 0.3, 0.9, 1 - 1e-9] {
            let complement = m < 0.5 ? 1 - m : (m == 0.9 ? 0.1 : 1e-9)
            let quarter = EllipticFunctions.completeIntegral(m: m, complement: complement)
            for fraction in [0.0, 0.2, 0.5, 0.8, 1.0] {
                let (sn, cn, dn) = EllipticFunctions.jacobi(fraction * quarter, m: m, complement: complement)
                expectClose(sn * sn + cn * cn, 1, .absolute(1e-13), "m = \(m)")
                expectClose(dn * dn + m * sn * sn, 1, .absolute(1e-13), "m = \(m)")
            }
            // At the quarter period sn = 1, cn = 0 and dn = k′.
            let end = EllipticFunctions.jacobi(quarter, m: m, complement: complement)
            expectClose(end.sn, 1, .absolute(1e-14))
            expectClose(end.cn, 0, .absolute(1e-14))
            expectClose(end.dn, complement.squareRoot(), .relative(1e-12))
        }
        // m = 0 is circular, m = 1 hyperbolic.
        let circular = EllipticFunctions.jacobi(0.7, m: 0, complement: 1)
        expectClose(circular.sn, sin(0.7), .relative(1e-15))
        expectClose(circular.cn, cos(0.7), .relative(1e-15))
        #expect(circular.dn == 1)
        let hyperbolic = EllipticFunctions.jacobi(0.7, m: 1, complement: 0)
        #expect(hyperbolic.sn == tanh(0.7))
        #expect(hyperbolic.cn == 1 / cosh(0.7) && hyperbolic.dn == 1 / cosh(0.7))
    }

    // MARK: Stability (NUMS-2, §7.5 row 4)

    /// The Landen sequence carries the modulus and its complement side by side. Recomputing
    /// the complement as √(1 − k²) at each step, the textbook form, cancels while k stays near
    /// 1: for K(1 − 10⁻³⁰) it returns a number that is wrong in the third digit, and for a
    /// complement below ε it never leaves k = 1 at all.
    @Test func stressTheLandenSequenceCarriesTheComplement() throws {
        /// The textbook recursion: the hazard.
        func naive(complement: Double) -> Double {
            var k = (1 - complement).squareRoot()
            var result = Double.pi / 2
            for _ in 0 ..< 64 {
                guard k > 1e-20 else { break }
                let kComplement = ((1 - k) * (1 + k)).squareRoot()
                k = (1 - kComplement) / (1 + kComplement)
                result *= 1 + k
            }
            return result
        }
        let golden = try Golden.ellipticFunctions.get().require("complete-integral")
        for (complement, expected) in zip(try golden.real("complement"), try golden.real("K_near_one")) {
            let carried = EllipticFunctions.complementaryIntegral(m: complement)
            expectClose(carried, expected, .relative(1e-12), "K(1 − \(complement))")
            let hazard = abs(naive(complement: complement) - expected) / expected
            Measurements.shared.record("WP-408 stress: K near m = 1 with the complement recomputed, relative (hazard)", hazard, bound: 1e-12)
            if complement <= 1e-12 { #expect(hazard > 1e-6, "K(1 − \(complement)) by the textbook recursion is off by \(hazard)") }
        }
        // The expected values are ln(4/√p) to first order: an independent check on the table.
        expectClose(EllipticFunctions.complementaryIntegral(m: 1e-300), 2 * M_LN2 + 150 * M_LN10, .relative(1e-14))
    }

    /// The degree equation returns 1 − m from the complementary nome. Taken as a subtraction
    /// it would hold as many digits as m is short of 1.
    @Test func stressTheDegreeEquationKeepsTheComplement() {
        for (order, lost) in [(12, 1e-10), (30, 1e-6), (50, 1e-2)] {
            let solution = EllipticFunctions.degreeEquation(order: order, m1: 2.589e-7)   // 1 dB against 60 dB
            let subtracted = 1 - solution.m
            let disagreement = abs(subtracted - solution.complement) / solution.complement
            Measurements.shared.record("WP-408 stress: 1 − m by subtraction against the complementary nome, order \(order), relative (hazard)", disagreement, bound: 1e-12)
            // The identity that defines the solution, with the complement that was returned…
            let ratio = EllipticFunctions.completeIntegral(m: solution.complement, complement: solution.m)
                / EllipticFunctions.completeIntegral(m: solution.m, complement: solution.complement)
            let target = EllipticFunctions.complementaryIntegral(m: 2.589e-7) / EllipticFunctions.completeIntegral(m: 2.589e-7)
            expectClose(Double(order) * ratio, target, .relative(1e-12), "order \(order)")
            // …and with the subtracted one, which has lost its digits.
            let naiveRatio = EllipticFunctions.completeIntegral(m: subtracted, complement: solution.m)
                / EllipticFunctions.completeIntegral(m: solution.m, complement: subtracted)
            if order >= 30 {
                #expect(abs(Double(order) * naiveRatio - target) / target > 1e-12, "order \(order)")
                #expect(disagreement > lost * 1e-3)
            }
        }
    }

    /// Kahan's formulas for the inverse sine. The logarithmic form, −j·ln(jz + √(1 − z²)),
    /// subtracts nearly equal numbers for a small argument and loses half its digits.
    @Test func stressTheInverseSineOfASmallArgumentKeepsItsDigits() {
        for y in [1e-12, 1e-8, 1e-4] {
            // asin(jy) = j·asinh(y), and the inverse sc is built on it.
            let value = EllipticFunctions.inverseSn(Complex(0, y), m: 0, complement: 1)
            expectClose(value.imaginary, asinh(y), .relative(1e-15), "asin(j·\(y))")
            #expect(value.real == 0)
            let logarithmic = -log(-y + (1 + y * y).squareRoot())   // the hazard
            Measurements.shared.record("WP-408 stress: asinh by the logarithmic form, relative (hazard)", abs(logarithmic - asinh(y)) / asinh(y), bound: 1e-15)
        }
        let real = EllipticFunctions.inverseSn(Complex(1e-9, 0), m: 0, complement: 1)
        expectClose(real.real, 1e-9, .relative(1e-15))
    }

    @Test func theInverseSnAndScMatchTheTable() throws {
        let file = try Golden.ellipticFunctions.get()
        let cases = file.cases.filter { $0.name.hasPrefix("inverse-") }
        #expect(cases.count == 10)
        for golden in cases {
            let m = try golden.number("m")
            for (w, expected) in zip(try golden.real("w_sn"), try golden.real("inverse_sn")) {
                let computed = EllipticFunctions.inverseSn(Complex(w), m: m, complement: 1 - m)
                expectClose(computed.real, expected, .relative(Self.tolerance), "\(golden.name) asn(\(w))")
                // w = 1 is the branch point of the inverse: there the imaginary part is the
                // square root of a rounding error, and only the real part means anything.
                if w < 1 { #expect(abs(computed.imaginary) <= 1e-12 * max(1, expected)) }
                if expected > 0 { Measurements.shared.record("WP-408 inverse sn, relative", abs(computed.real - expected) / expected, bound: Self.tolerance) }
            }
            for (w, expected) in zip(try golden.real("w_sc"), try golden.real("inverse_sc")) {
                let computed = EllipticFunctions.inverseSc(w, m: m, complement: 1 - m)
                expectClose(computed, expected, .relative(Self.tolerance), "\(golden.name) asc(\(w))")
                if expected > 0 { Measurements.shared.record("WP-408 inverse sc, relative", abs(computed - expected) / expected, bound: Self.tolerance) }
                // The real recursion is the complex one on the imaginary axis.
                let viaSn = EllipticFunctions.inverseSn(Complex(0, w), m: m, complement: 1 - m)
                expectClose(viaSn.imaginary, expected, .relative(Self.tolerance), "\(golden.name) asc through asn")
                #expect(abs(viaSn.real) <= 1e-12 * max(1, expected))
            }
        }
    }

    @Test func theInversesUndoTheFunctions() {
        for m in [0.01, 0.5, 0.97] {
            let quarter = EllipticFunctions.completeIntegral(m: m)
            for fraction in [0.05, 0.3, 0.6, 0.95] {
                let u = fraction * quarter
                let (sn, cn, _) = EllipticFunctions.jacobi(u, m: m, complement: 1 - m)
                let back = EllipticFunctions.inverseSn(Complex(sn), m: m, complement: 1 - m)
                expectClose(back.real, u, .relative(1e-11), "asn(sn(u)), m = \(m)")
                // sc with the complementary parameter, as the elliptic prototype uses it. Its
                // quarter period is K′(m), and sc grows without bound towards it.
                let v = fraction * EllipticFunctions.completeIntegral(m: 1 - m, complement: m)
                let (snC, cnC, _) = EllipticFunctions.jacobi(v, m: 1 - m, complement: m)
                #expect(cn > 0)
                expectClose(EllipticFunctions.inverseSc(snC / cnC, m: m, complement: 1 - m), v, .relative(1e-11), "asc(sc(v)), m = \(m)")
            }
        }
        // m = 1 degenerates to the hyperbolic and circular inverses.
        expectClose(EllipticFunctions.inverseSn(Complex(0.5), m: 1, complement: 0).real, atanh(0.5), .relative(1e-15))
        #expect(EllipticFunctions.inverseSc(2, m: 1, complement: 0) == atan(2))
        // A complex argument off both axes: sn(asn(w)) = w, by the addition theorem
        // sn(x + jy) = (s·d₁ + j·c·d·s₁·c₁) / (c₁² + m·s²·s₁²).
        let m = 0.6
        let w = Complex(0.4, 0.7)
        let u = EllipticFunctions.inverseSn(w, m: m, complement: 1 - m)
        let (s, c, d) = EllipticFunctions.jacobi(u.real, m: m, complement: 1 - m)
        let (s1, c1, d1) = EllipticFunctions.jacobi(u.imaginary, m: 1 - m, complement: m)
        let denominator = c1 * c1 + m * s * s * s1 * s1
        expectClose(s * d1 / denominator, w.real, .absolute(1e-13))
        expectClose(c * d * s1 * c1 / denominator, w.imaginary, .absolute(1e-13))
    }
}
