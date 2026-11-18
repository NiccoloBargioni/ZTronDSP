import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign

// The one operation of `DoubleDouble` that no suite ran (COV-3): the sum of a double-double and
// a plain double. Nothing in the package calls it today (the Horner evaluation adds
// double-doubles to double-doubles); it is tested here as the arithmetic it claims to be.

@Suite("Double-double arithmetic: adding a double (COV-3)")
struct CoverageDoubleDoubleTests {
    /// §7.5, rows 4 and 12 (NUMS-1): double-double arithmetic exists because a polynomial
    /// evaluated beside one of its roots cancels the digits a double holds. The sum with a
    /// double is an error-free transformation: what the rounded sum loses is in the low word,
    /// so a later cancellation gives it back exactly.
    @Test func addingADoubleKeepsWhatARoundedSumLoses() {
        let small = 1e-20
        let lostInDouble = (1.0 + small) - 1.0
        #expect(lostInDouble == 0, "a double loses the small term: the test has something to show")

        let sum = DoubleDouble(1) + small
        #expect(sum.hi == 1 && sum.lo == small, "the rounded sum, and beside it exactly what the rounding dropped")
        let back = sum + (-1.0)
        #expect(back.hi == small && back.lo == 0 && back.value == small, "cancelling the large term gives the small one back, to the last bit")
    }

    /// The same rule as the sum of two double-doubles (Dekker 1971): adding the double `b` is
    /// adding the double-double `(b, 0)`, and the result is normalised, `|lo| ≤ ulp(hi) / 2`.
    @Test func addingADoubleIsAddingTheDoubleDoubleWithNoLowWord() {
        let lefts: [DoubleDouble] = [
            DoubleDouble(1), DoubleDouble(hi: 1, lo: 3e-17), DoubleDouble(hi: -0.1, lo: 2.5e-18), DoubleDouble(hi: 1e16, lo: 0.25),
            DoubleDouble(hi: 3.0e-9, lo: -1.0e-26), DoubleDouble.zero,
        ]
        let rights: [Double] = [0, 0.1, -1, 1e-30, 123_456.789, -1e16, 0x1p-52]
        for left in lefts {
            for right in rights {
                let sum = left + right
                let reference = left + DoubleDouble(right)
                #expect(sum.hi == reference.hi && sum.lo == reference.lo, "(\(left.hi), \(left.lo)) + \(right)")
                let half = sum.hi.ulp / 2
                #expect(abs(sum.lo) <= half, "normalised: the low word is below half a unit of the high one")
                // To the precision of a double-double the sum is the exact one: taking the
                // operands away again leaves nothing a double can see beside them.
                let residue = ((sum - left) + (-right)).value
                let scale = max(abs(left.hi), abs(right), Double.leastNormalMagnitude)
                #expect(abs(residue) <= scale * 1e-30, "(\(left.hi), \(left.lo)) + \(right): \(residue) left over")
            }
        }
    }
}
