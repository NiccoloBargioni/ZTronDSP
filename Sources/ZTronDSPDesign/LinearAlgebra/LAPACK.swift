import Accelerate
import ZTronDSPCore

/// The one file group that calls LAPACK (LA-1).
///
/// The calls go through the legacy CLAPACK interface: its replacement exists only from
/// iOS 16.4 and the deployment floor is 15.0 (E-10). When the floor moves, this is the only
/// place that changes. Every routine with a work array is asked for its size first, and a
/// non-zero `info` becomes `DSPError.numericalFailure(routine:info:)`.
///
/// Control or background context only: every call allocates its work space.
enum LAPACK {
    /// Throws `DSPError.numericalFailure` for a non-zero `info`.
    /// Control or background context.
    static func check(_ info: Int, routine: String) throws(DSPError) {
        guard info == 0 else { throw .numericalFailure(routine: routine, info: info) }
    }

    /// The eigenvalues of an upper Hessenberg matrix.
    ///
    /// The matrix is first balanced by scaling only (`dgebal`, `JOB = 'S'`), which is a
    /// diagonal similarity and therefore keeps the Hessenberg form; the eigenvalues are then
    /// found by the implicit double-shift QR algorithm (`dhseqr`, eigenvalues only).
    /// Control or background context.
    ///
    /// - Parameters:
    ///   - matrix: `order × order` values, column by column. Entries below the first
    ///     subdiagonal must be zero.
    ///   - order: The number of rows; at least 1.
    ///   - balancing: `false` skips the balance. A hook for the stress test that shows what
    ///     the balance is for; production code never passes it.
    /// - Returns: The real and imaginary parts. Conjugate pairs are adjacent, the member
    ///   with the positive imaginary part first.
    /// - Throws: `DSPError.invalidParameter` when the storage does not hold `order²` values;
    ///   `DSPError.numericalFailure` when a routine reports a non-zero `info` (for `dhseqr`,
    ///   the QR iteration did not converge).
    static func hessenbergEigenvalues(
        of matrix: [Double], order: Int, balancing: Bool = true
    ) throws(DSPError) -> (real: [Double], imaginary: [Double]) {
        guard order >= 1, order <= Int(Int32.max / 2), matrix.count == order * order else {
            throw .invalidParameter(stage: .none, parameter: "matrix", reason: "\(matrix.count) values do not form a square matrix of order \(order)")
        }
        var a = matrix
        var n = __CLPK_integer(order)
        var leadingDimension = n
        var low = __CLPK_integer(1)
        var high = n
        var info = __CLPK_integer(0)

        if balancing {
            var job = CChar(UInt8(ascii: "S"))
            var scale = [Double](repeating: 1, count: order)
            dgebal_(&job, &n, &a, &leadingDimension, &low, &high, &scale, &info)
            try check(Int(info), routine: "dgebal")
        }

        var job = CChar(UInt8(ascii: "E"))
        var vectors = CChar(UInt8(ascii: "N"))
        var real = [Double](repeating: 0, count: order)
        var imaginary = [Double](repeating: 0, count: order)
        var unusedVectors = [Double](repeating: 0, count: 1)
        var vectorsDimension = __CLPK_integer(1)

        // Workspace query (LA-1): the routine writes the size it wants into the first slot.
        var workSize = __CLPK_integer(-1)
        var query = [Double](repeating: 0, count: 1)
        dhseqr_(&job, &vectors, &n, &low, &high, &a, &leadingDimension, &real, &imaginary,
                &unusedVectors, &vectorsDimension, &query, &workSize, &info)
        try check(Int(info), routine: "dhseqr")

        workSize = __CLPK_integer(max(Double(order), min(query[0], Double(Int32.max / 2))))
        var work = [Double](repeating: 0, count: Int(workSize))
        dhseqr_(&job, &vectors, &n, &low, &high, &a, &leadingDimension, &real, &imaginary,
                &unusedVectors, &vectorsDimension, &work, &workSize, &info)
        try check(Int(info), routine: "dhseqr")
        return (real, imaginary)
    }
}
