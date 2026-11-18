import ZTronDSPCore

/// Splits a set of roots into its real members and its conjugate pairs.
///
/// A system with real coefficients has roots that are real or come in conjugate pairs; every
/// conversion out of zero-pole-gain form starts here. The rule and the order of the result
/// follow the reference pairing (`scipy.signal`'s `_cplxreal`), because the section pairing
/// of WP-404 is defined on that order.
enum ConjugatePairs {
    /// The relative tolerance for "real" and for "conjugate of": 100 ε.
    static let tolerance = 100 * Double.ulpOfOne

    /// - Returns: `pairs`, one member of each conjugate pair, the one with the positive
    ///   imaginary part, averaged with the conjugate of its partner, ordered by real part and
    ///   then, among equal real parts, by imaginary part; and `reals`, in ascending order.
    /// - Throws: `DSPError.invalidParameter` naming `parameter` when a value is not finite or
    ///   a complex value has no conjugate among the others.
    static func split(_ values: [Complex], parameter: String) throws(DSPError) -> (pairs: [Complex], reals: [Double]) {
        guard values.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "every value must be finite")
        }
        // Sorted by real part, then by the magnitude of the imaginary part. The original
        // position breaks ties, so the order is the same on every run.
        let order = values.indices.sorted { lhs, rhs in
            let a = values[lhs]
            let b = values[rhs]
            if a.real != b.real { return a.real < b.real }
            if abs(a.imaginary) != abs(b.imaginary) { return abs(a.imaginary) < abs(b.imaginary) }
            return lhs < rhs
        }
        var reals: [Double] = []
        var upper: [Complex] = []
        var lower: [Complex] = []
        for index in order {
            let value = values[index]
            if abs(value.imaginary) <= tolerance * value.magnitude {
                reals.append(value.real)
            } else if value.imaginary > 0 {
                upper.append(value)
            } else {
                lower.append(value)
            }
        }
        guard upper.count == lower.count else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "a complex value has no conjugate: \(upper.count) lie above the real axis and \(lower.count) below")
        }
        // Within a run of (nearly) equal real parts, order both halves by imaginary part so
        // that partners face each other.
        var start = 0
        while start < upper.count {
            var end = start
            while end + 1 < upper.count, upper[end + 1].real - upper[end].real <= tolerance * upper[end].magnitude {
                end += 1
            }
            if end > start {
                sortByImaginaryMagnitude(&upper, start ... end)
                sortByImaginaryMagnitude(&lower, start ... end)
            }
            start = end + 1
        }
        var pairs: [Complex] = []
        pairs.reserveCapacity(upper.count)
        for index in upper.indices {
            let partner = lower[index].conjugate
            guard (upper[index] - partner).magnitude <= tolerance * partner.magnitude else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "\(upper[index]) has no conjugate among the values")
            }
            pairs.append(Complex((upper[index].real + partner.real) / 2, (upper[index].imaginary + partner.imaginary) / 2))
        }
        return (pairs, reals)
    }

    /// A stable insertion sort of one run by the magnitude of the imaginary part. Runs are a
    /// handful of values long.
    private static func sortByImaginaryMagnitude(_ values: inout [Complex], _ range: ClosedRange<Int>) {
        guard range.count > 1 else { return }
        for index in (range.lowerBound + 1) ... range.upperBound {
            let value = values[index]
            var position = index
            while position > range.lowerBound, abs(values[position - 1].imaginary) > abs(value.imaginary) {
                values[position] = values[position - 1]
                position -= 1
            }
            values[position] = value
        }
    }
}
