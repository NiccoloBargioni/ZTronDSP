import ZTronDSPCore

/// Minimises a function of one variable on an interval: Brent's method, golden-section
/// steps with parabolic interpolation where the parabola can be trusted.
///
/// The order estimate of a band-stop filter moves each pass-band edge to where the order is
/// smallest, and its oracle (`scipy.signal.buttord` and its siblings) does that with
/// `scipy.optimize.fminbound`. The natural frequencies that come out depend on where that
/// search stops, so this is the same procedure, step for step, with the same tolerance: the
/// two agree far inside the 10⁻⁹ the parity tests allow.
/// Control or background context.
enum BoundedMinimizer {
    /// The absolute tolerance on the position of the minimum: SciPy's default.
    /// Control or background context.
    static let defaultTolerance = 1e-5

    /// The point of `lower … upper` at which `function` is smallest, to within `tolerance`.
    ///
    /// Control or background context; allocation-free apart from what `function` does.
    static func minimize(
        from lower: Double, to upper: Double, tolerance: Double = defaultTolerance, maximumEvaluations: Int = 500,
        _ function: (Double) throws(DSPError) -> Double
    ) throws(DSPError) -> Double {
        let squareRootOfEpsilon = (2.2e-16).squareRoot()
        let goldenMean = 0.5 * (3 - (5.0).squareRoot())
        var a = lower
        var b = upper
        var fulc = a + goldenMean * (b - a)
        var nfc = fulc
        var xf = fulc
        var rat = 0.0
        var e = 0.0
        var x = xf
        var fx = try function(x)
        var evaluations = 1
        var ffulc = fx
        var fnfc = fx
        var xm = 0.5 * (a + b)
        var tol1 = squareRootOfEpsilon * abs(xf) + tolerance / 3
        var tol2 = 2 * tol1

        while abs(xf - xm) > tol2 - 0.5 * (b - a) {
            var golden = true
            if abs(e) > tol1 {
                // Try a parabola through the three best points.
                golden = false
                var r = (xf - nfc) * (fx - ffulc)
                var q = (xf - fulc) * (fx - fnfc)
                var p = (xf - fulc) * q - (xf - nfc) * r
                q = 2 * (q - r)
                if q > 0 { p = -p }
                q = abs(q)
                r = e
                e = rat
                if abs(p) < abs(0.5 * q * r), p > q * (a - xf), p < q * (b - xf) {
                    rat = p / q
                    x = xf + rat
                    if x - a < tol2 || b - x < tol2 {
                        rat = xm - xf >= 0 ? tol1 : -tol1
                    }
                } else {
                    golden = true
                }
            }
            if golden {
                e = xf >= xm ? a - xf : b - xf
                rat = goldenMean * e
            }
            x = xf + (rat >= 0 ? 1 : -1) * max(abs(rat), tol1)
            let fu = try function(x)
            evaluations += 1

            if fu <= fx {
                if x >= xf { a = xf } else { b = xf }
                fulc = nfc
                ffulc = fnfc
                nfc = xf
                fnfc = fx
                xf = x
                fx = fu
            } else {
                if x < xf { a = x } else { b = x }
                if fu <= fnfc || nfc == xf {
                    fulc = nfc
                    ffulc = fnfc
                    nfc = x
                    fnfc = fu
                } else if fu <= ffulc || fulc == xf || fulc == nfc {
                    fulc = x
                    ffulc = fu
                }
            }
            xm = 0.5 * (a + b)
            tol1 = squareRootOfEpsilon * abs(xf) + tolerance / 3
            tol2 = 2 * tol1
            if evaluations >= maximumEvaluations { break }
        }
        return xf
    }
}
