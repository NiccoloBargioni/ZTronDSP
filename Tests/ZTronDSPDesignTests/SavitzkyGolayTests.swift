import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-426. Savitzky–Golay coefficients and derivatives: QR on a scaled abscissa. Acceptance:
/// golden (`savgol_coeffs`; windows 5, 11, 31; orders 2, 3, 4; derivatives 0, 1, 2;
/// coefficients within 1e-10).
@Suite("Savitzky–Golay coefficients (WP-426)")
struct SavitzkyGolayCoefficientTests {
    @Test func theCoefficientsMatchTheOracle() throws {
        let file = try Golden.savitzkyGolay.get()
        var checked = 0
        for golden in file.cases where golden.name.hasPrefix("coefficients-") {
            let coefficients = try DSP.savitzkyGolayCoefficients(
                window: try golden.integer("window"), polynomialOrder: try golden.integer("order"), derivative: try golden.integer("derivative"))
            let expected = try golden.real("coefficients")
            expectClose(coefficients, expected, .absolute(1e-10), golden.name)
            Measurements.shared.record("WP-426 Savitzky–Golay coefficients against savgol_coeffs, absolute", zip(coefficients, expected).map { abs($0 - $1) }.max() ?? 1, bound: 1e-10)
            checked += 1
        }
        #expect(checked == 3 * 3 * 3 + 1)
    }

    @Test func theCoefficientsReproduceAPolynomialAndItsDerivativesExactly() throws {
        // p(t) = 2 − t + 0.5·t² − 0.25·t³ on the samples t = −5 … 5: a filter of order 3 or more
        // returns p and its derivatives at t = 0.
        let samples = (-5 ... 5).map { t -> Double in let t = Double(t); return 2 - t + 0.5 * t * t - 0.25 * t * t * t }
        let expected = [2.0, -1, 1, -1.5, 0]
        for order in [3, 4, 6] {
            for derivative in 0 ... 4 where derivative <= order {
                let coefficients = try DSP.savitzkyGolayCoefficients(window: 11, polynomialOrder: order, derivative: derivative)
                // Convolution order: the coefficient of the newest sample comes first.
                let value = zip(coefficients, samples.reversed()).map { $0 * $1 }.reduce(0, +)
                expectClose(value, expected[derivative], .absolute(1e-11), "order \(order), derivative \(derivative)")
            }
        }
        // A smoothing filter passes a constant unchanged; a differentiating one removes it.
        for window in [1, 3, 31, 255] {
            for order in [0, 2, 5] where order < window {
                let smooth = try DSP.savitzkyGolayCoefficients(window: window, polynomialOrder: order)
                expectClose(smooth.reduce(0, +), 1.0, .absolute(1e-12), "window \(window), order \(order)")
                #expect(zip(smooth, smooth.reversed()).allSatisfy { abs($0 - $1) < 1e-13 }, "a smoothing filter is symmetric")
                if order >= 1 {
                    let slope = try DSP.savitzkyGolayCoefficients(window: window, polynomialOrder: order, derivative: 1)
                    expectClose(slope.reduce(0, +), 0.0, .absolute(1e-12))
                    #expect(zip(slope, slope.reversed()).allSatisfy { abs($0 + $1) < 1e-12 }, "a first derivative is antisymmetric")
                }
            }
        }
        // Order 0 is the moving average; a window of one sample is the identity.
        expectClose(try DSP.savitzkyGolayCoefficients(window: 5, polynomialOrder: 0), [Double](repeating: 0.2, count: 5), .absolute(1e-15))
        expectClose(try DSP.savitzkyGolayCoefficients(window: 1, polynomialOrder: 0), [1.0], .absolute(1e-15))
        // A derivative above the polynomial order is identically zero.
        #expect(try DSP.savitzkyGolayCoefficients(window: 7, polynomialOrder: 2, derivative: 3) == [Double](repeating: 0, count: 7))
    }

    @Test func valuesThatMakeNoFitAreTypedErrors() throws {
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: 6, polynomialOrder: 2) }?.invalidParameterName == "window")
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: 0, polynomialOrder: 0) }?.invalidParameterName == "window")
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: DSP.savitzkyGolayMaximumWindow + 2, polynomialOrder: 2) }?.invalidParameterName == "window")
        // An order at or above the window is rejected (§7.5, row 6).
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: 5, polynomialOrder: 5) }?.invalidParameterName == "polynomialOrder")
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: 5, polynomialOrder: -1) }?.invalidParameterName == "polynomialOrder")
        #expect(thrownError { _ = try DSP.savitzkyGolayCoefficients(window: 5, polynomialOrder: 2, derivative: -1) }?.invalidParameterName == "derivative")
        // The largest order a window admits interpolates its samples: the centre is returned.
        let interpolating = try DSP.savitzkyGolayCoefficients(window: 5, polynomialOrder: 4)
        expectClose(interpolating, [0.0, 0, 1, 0, 0], .absolute(1e-12))
    }

    /// The stress test of the stability note (NUMS-2). The polynomials are the well-conditioned
    /// ones of the stress-fixture library (WP-016), sampled across a wide window. A fit of order
    /// 24 holds every one of them, so it must return them, and their derivative, at the middle of
    /// the window.
    @Test func stressAWideWindowAndAHighOrderNeedTheOrthogonalFactorisation() throws {
        let window = 401, order = 24
        let half = (window - 1) / 2
        /// The worst error of a fit over the fixtures, relative to the size of what it returns;
        /// infinite when LAPACK refuses the system.
        func worst(scaled: Bool, normalEquations: Bool) -> Double {
            var worst = 0.0
            for fixture in StressFixture.wellConditionedPolynomials where fixture.degree >= 5 {
                // p(u) on u = −1 … 1, as a signal across the window: x[i] = p((i − half) / half).
                let polynomial = Polynomial(fixture.coefficients)
                let samples = (0 ..< window).map { polynomial.evaluate(at: Double($0 - half) / Double(half)) }
                let scale = samples.map { abs($0) }.max() ?? 1
                // dp/di = p′(0) / half.
                let wanted = [(0, polynomial.evaluate(at: 0), scale), (1, polynomial.derivative.evaluate(at: 0) / Double(half), scale / Double(half))]
                for (derivative, expected, unit) in wanted {
                    guard let weights = try? SavitzkyGolayFit.weights(
                        window: window, polynomialOrder: order, derivative: derivative, position: half, scaled: scaled,
                        normalEquations: normalEquations)
                    else { return .infinity }
                    worst = max(worst, abs(zip(weights, samples).map { $0 * $1 }.reduce(0, +) - expected) / unit)
                }
            }
            return worst
        }
        let production = worst(scaled: true, normalEquations: false)
        let rawFactorised = worst(scaled: false, normalEquations: false)
        let scaledNormal = worst(scaled: true, normalEquations: true)
        let rawNormal = worst(scaled: false, normalEquations: true)
        Measurements.shared.record("WP-426 stress: order 24 across 401 samples, factorisation on the scaled abscissa, relative", production, bound: 1e-12)
        Measurements.shared.record("WP-426 stress: the same, factorisation on the raw abscissa", rawFactorised, bound: .infinity)
        Measurements.shared.record("WP-426 stress: the same, normal equations on the scaled abscissa", scaledNormal, bound: .infinity)
        Measurements.shared.record("WP-426 stress: the same, normal equations on the raw abscissa", rawNormal, bound: .infinity)
        #expect(production < 1e-12, "the fit as it is made: \(production)")
        // The route the method avoids squares the condition number: at this order the normal
        // equations have lost half their digits on the scaled abscissa, and on the raw one
        // there is no Cholesky factor left.
        #expect(scaledNormal > 1e4 * production, "normal equations on the scaled abscissa: \(scaledNormal) against \(production)")
        #expect(rawNormal > 1e4 * production, "normal equations on the raw abscissa: \(rawNormal) against \(production)")
        // The scaling keeps the powers of the abscissa inside a double: 200ᵏ leaves it at k = 134,
        // where the raw fit is a system of infinities and is refused.
        #expect((try? SavitzkyGolayFit.weights(window: window, polynomialOrder: 150, derivative: 0, position: half, scaled: false)) == nil)
        let highOrder = thrownError { _ = try SavitzkyGolayFit.weights(window: window, polynomialOrder: 150, derivative: 0, position: half) }
        #expect(highOrder == nil || highOrder?.numericalFailure?.routine == "dgels", "a fit beyond the precision of a double is a typed error, never a NaN")
    }

    /// What the scaled abscissa is for (register audit, WP-905a): a fit that is well posed but
    /// whose powers leave a double on the raw abscissa. Order 84 across 10 001 samples is well
    /// inside what a least-squares fit on equispaced samples resolves (about 2·√window, 200
    /// here), but 5 000⁸⁴ is 10³¹⁰·⁷: on the raw abscissa the system is one of infinities and is
    /// refused. On the scaled one the weights reproduce the polynomial fixtures of WP-016, as
    /// values and as slopes at the centre.
    @Test func stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa() throws {
        let window = 10_001, order = 84
        let half = (window - 1) / 2
        #expect((try? SavitzkyGolayFit.weights(window: window, polynomialOrder: order, derivative: 0, position: half, scaled: false)) == nil,
                "on the raw abscissa the powers overflow")
        var worst = 0.0
        for fixture in StressFixture.wellConditionedPolynomials where fixture.degree >= 5 {
            let polynomial = Polynomial(fixture.coefficients)
            let samples = (0 ..< window).map { polynomial.evaluate(at: Double($0 - half) / Double(half)) }
            let scale = samples.map { abs($0) }.max() ?? 1
            let wanted = [(0, polynomial.evaluate(at: 0), scale), (1, polynomial.derivative.evaluate(at: 0) / Double(half), scale / Double(half))]
            for (derivative, expected, unit) in wanted {
                let weights = try SavitzkyGolayFit.weights(window: window, polynomialOrder: order, derivative: derivative, position: half)
                #expect(weights.allSatisfy { $0.isFinite })
                worst = max(worst, abs(zip(weights, samples).map { $0 * $1 }.reduce(0, +) - expected) / unit)
            }
        }
        Measurements.shared.record("WP-426 stress: order 84 across 10 001 samples, whose raw powers overflow, factorisation on the scaled abscissa, relative", worst, bound: 1e-12)
        #expect(worst < 1e-12, "the fit as it is made: \(worst)")
    }
}

/// WP-427. Savitzky–Golay application, five edge modes. Acceptance: golden per mode
/// (`savgol_filter`; filtered Float32 output within 1e-5).
@Suite("Savitzky–Golay application (WP-427)")
struct SavitzkyGolayApplicationTests {
    private func edge(named name: String, constant: Float) -> SavitzkyGolayEdge {
        switch name {
        case "interp": .interpolate
        case "mirror": .mirror
        case "nearest": .nearest
        case "constant": .constant(constant)
        default: .wrap
        }
    }

    @Test func theFilteredSignalMatchesTheOracleInEveryMode() throws {
        let file = try Golden.savitzkyGolay.get()
        let signal = try file.require("signal")
        let input = try signal.floats("input")
        let rows = try signal.floats("filtered")
        let count = try signal.integer("count")
        #expect(input.count == count && rows.count == 3 * 3 * 3 * 5 * count)
        var perMode: [String: Int] = [:]
        for golden in file.cases where golden.name.hasPrefix("filter-") {
            let mode = try golden.string("mode")
            let row = try golden.integer("row")
            let output = try DSP.savitzkyGolay(
                input, window: try golden.integer("window"), polynomialOrder: try golden.integer("order"),
                derivative: try golden.integer("derivative"), edge: edge(named: mode, constant: Float(try golden.number("constant"))))
            let expected = Array(rows[row * count ..< (row + 1) * count])
            expectClose(output, expected, .absolute(1e-5), golden.name)
            Measurements.shared.record("WP-427 Savitzky–Golay output against savgol_filter, mode \(mode), absolute",
                                       Double(zip(output, expected).map { abs($0 - $1) }.max() ?? 1), bound: 1e-5)
            perMode[mode, default: 0] += 1
        }
        #expect(perMode == ["interp": 27, "mirror": 27, "nearest": 27, "constant": 27, "wrap": 27])
    }

    @Test func eachModeContinuesTheSignalAsItSays() throws {
        let input: [Float] = [1, 2, 4, 8, 16, 32, 64]
        // A moving sum of three samples makes the continuation visible at both ends.
        func ends(_ edge: SavitzkyGolayEdge) throws -> (Float, Float) {
            let output = try DSP.savitzkyGolay(input, window: 3, polynomialOrder: 0, edge: edge)
            return (output[0] * 3, output[6] * 3)
        }
        let mirror = try ends(.mirror), nearest = try ends(.nearest), constant = try ends(.constant(10)), wrap = try ends(.wrap)
        expectClose([mirror.0, mirror.1], [2 + 1 + 2, 32 + 64 + 32] as [Float], .absolute(1e-4))
        expectClose([nearest.0, nearest.1], [1 + 1 + 2, 32 + 64 + 64] as [Float], .absolute(1e-4))
        expectClose([constant.0, constant.1], [10 + 1 + 2, 32 + 64 + 10] as [Float], .absolute(1e-4))
        expectClose([wrap.0, wrap.1], [64 + 1 + 2, 32 + 64 + 1] as [Float], .absolute(1e-4))
        // Away from the ends every mode gives the same values.
        let reference = try DSP.savitzkyGolay(input, window: 3, polynomialOrder: 1, edge: .interpolate)
        for edge in [SavitzkyGolayEdge.mirror, .nearest, .constant(-3), .wrap] {
            let output = try DSP.savitzkyGolay(input, window: 3, polynomialOrder: 1, edge: edge)
            #expect(Array(output[1 ..< 6]) == Array(reference[1 ..< 6]))
        }
        // The window may be longer than the signal in every mode but one.
        #expect(try DSP.savitzkyGolay([1, 2], window: 5, polynomialOrder: 2, edge: .mirror).count == 2)
        #expect(try DSP.savitzkyGolay([3], window: 5, polynomialOrder: 2, edge: .mirror) == [3])
        #expect(try DSP.savitzkyGolay([3], window: 5, polynomialOrder: 2, edge: .wrap) == [3])
        #expect(thrownError { _ = try DSP.savitzkyGolay([1, 2], window: 5, polynomialOrder: 2, edge: .interpolate) }?.invalidParameterName == "window")
        #expect(thrownError { _ = try DSP.savitzkyGolay([1, 2], window: 3, polynomialOrder: 1, edge: .constant(.nan)) }?.invalidParameterName == "edge")
        #expect(thrownError { _ = try DSP.savitzkyGolay([1, 2], window: 4, polynomialOrder: 1) }?.invalidParameterName == "window")
        #expect(try DSP.savitzkyGolay([], window: 5, polynomialOrder: 2).isEmpty)
    }

    @Test func interpolationAtTheEndsReturnsAPolynomialExactly() throws {
        // A cubic: the fit of order 3 to the first and to the last window is the cubic itself,
        // so the filter returns it, and its slope, at every sample, the ends included.
        let count = 40
        let input = (0 ..< count).map { n -> Float in
            let t = Double(n) / 10
            return Float(0.25 * t * t * t - t * t + 0.5 * t - 0.125)
        }
        let smoothed = try DSP.savitzkyGolay(input, window: 9, polynomialOrder: 3, edge: .interpolate)
        expectClose(smoothed, input, .absolute(2e-6))
        let slope = try DSP.savitzkyGolay(input, window: 9, polynomialOrder: 3, derivative: 1, edge: .interpolate)
        let expected = (0 ..< count).map { n -> Float in
            let t = Double(n) / 10
            return Float((0.75 * t * t - 2 * t + 0.5) / 10)
        }
        expectClose(slope, expected, .absolute(5e-6))
        // The other modes cannot do that at the ends.
        let mirrored = try DSP.savitzkyGolay(input, window: 9, polynomialOrder: 3, edge: .mirror)
        #expect(abs(mirrored[0] - input[0]) > 1e-3 && abs(mirrored[20] - input[20]) < 2e-6)
    }
}
