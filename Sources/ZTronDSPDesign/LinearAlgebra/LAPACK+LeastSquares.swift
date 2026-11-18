import Accelerate
import ZTronDSPCore

// The linear solves of FIR design and of the Savitzky–Golay fit (WP-425, WP-426), in the one
// file group that calls LAPACK (LA-1). Legacy CLAPACK interface, as the file beside this one.
//
// Control or background context only: every call allocates its work space.
extension LAPACK {
    /// What `dposv` and `dpocon` say about a symmetric system.
    struct PositiveDefiniteSolution {
        /// The solution of `A·x = b`.
        let solution: [Double]
        /// `dpocon`'s estimate of `1 / (‖A‖₁·‖A⁻¹‖₁)`: near 1 for a well-conditioned matrix,
        /// near the rounding unit for a singular one.
        let reciprocalCondition: Double
    }

    /// Solves `A·x = b` for a symmetric matrix by Cholesky factorisation (`dposv`) and
    /// estimates the reciprocal condition number of `A` from the factor (`dpocon`).
    ///
    /// - Parameters:
    ///   - matrix: `order × order` values, column by column. Only the upper triangle is read.
    ///   - rightHandSide: `order` values.
    /// - Returns: `nil` when the matrix is not positive definite (`dposv` reports a leading
    ///   minor that is not): there is no Cholesky factor, and the caller takes its fall-back.
    /// - Throws: `DSPError.invalidParameter` for storage of the wrong size;
    ///   `DSPError.numericalFailure` for an illegal argument (`info < 0`).
    static func solvePositiveDefinite(
        _ matrix: [Double], order: Int, rightHandSide: [Double]
    ) throws(DSPError) -> PositiveDefiniteSolution? {
        guard order >= 1, order <= Int(Int32.max / 2), matrix.count == order * order, rightHandSide.count == order else {
            throw .invalidParameter(stage: .none, parameter: "matrix", reason: "\(matrix.count) values and a right-hand side of \(rightHandSide.count) do not form a system of order \(order)")
        }
        // ‖A‖₁ of the full symmetric matrix, from its upper triangle, before it is overwritten.
        var columnSums = [Double](repeating: 0, count: order)
        for column in 0 ..< order {
            for row in 0 ... column {
                let value = abs(matrix[column * order + row])
                columnSums[column] += value
                if row != column { columnSums[row] += value }
            }
        }
        var norm = columnSums.max() ?? 0

        var a = matrix
        var b = rightHandSide
        var uplo = CChar(UInt8(ascii: "U"))
        var n = __CLPK_integer(order)
        var one = __CLPK_integer(1)
        var leadingDimension = n
        var rightDimension = n
        var info = __CLPK_integer(0)
        dposv_(&uplo, &n, &one, &a, &leadingDimension, &b, &rightDimension, &info)
        if info > 0 { return nil }
        try check(Int(info), routine: "dposv")

        var reciprocal = 0.0
        var work = [Double](repeating: 0, count: 3 * order)
        var integerWork = [__CLPK_integer](repeating: 0, count: order)
        dpocon_(&uplo, &n, &a, &leadingDimension, &norm, &reciprocal, &work, &integerWork, &info)
        try check(Int(info), routine: "dpocon")
        return PositiveDefiniteSolution(solution: b, reciprocalCondition: reciprocal)
    }

    /// The minimum-norm least-squares solution of `A·x ≈ b` by the singular value
    /// decomposition (`dgelsd`): what remains well defined when `A` has no full rank.
    ///
    /// - Parameters:
    ///   - matrix: `rows × columns` values, column by column.
    ///   - rightHandSide: `rows` values.
    ///   - reciprocalCondition: singular values at or below this fraction of the largest are
    ///     taken as zero; a negative value means the rounding unit.
    /// - Returns: The `columns` values of the solution and the effective rank.
    /// - Throws: `DSPError.invalidParameter` for storage of the wrong size;
    ///   `DSPError.numericalFailure` when the decomposition does not converge.
    static func leastSquaresBySVD(
        _ matrix: [Double], rows: Int, columns: Int, rightHandSide: [Double], reciprocalCondition: Double = -1
    ) throws(DSPError) -> (solution: [Double], rank: Int) {
        guard rows >= 1, columns >= 1, rows <= Int(Int32.max / 2), columns <= Int(Int32.max / 2),
              matrix.count == rows * columns, rightHandSide.count == rows
        else {
            throw .invalidParameter(stage: .none, parameter: "matrix", reason: "\(matrix.count) values and a right-hand side of \(rightHandSide.count) do not form a \(rows) × \(columns) system")
        }
        var a = matrix
        let longest = max(rows, columns)
        var b = rightHandSide + [Double](repeating: 0, count: longest - rows)
        var m = __CLPK_integer(rows)
        var n = __CLPK_integer(columns)
        var one = __CLPK_integer(1)
        var leadingDimension = m
        var rightDimension = __CLPK_integer(longest)
        var singularValues = [Double](repeating: 0, count: min(rows, columns))
        var threshold = reciprocalCondition
        var rank = __CLPK_integer(0)
        var info = __CLPK_integer(0)

        // Workspace query (LA-1): the sizes of both work arrays come back in their first slots.
        var workSize = __CLPK_integer(-1)
        var query = [Double](repeating: 0, count: 1)
        var integerQuery = [__CLPK_integer](repeating: 0, count: 1)
        dgelsd_(&m, &n, &one, &a, &leadingDimension, &b, &rightDimension, &singularValues, &threshold, &rank,
                &query, &workSize, &integerQuery, &info)
        try check(Int(info), routine: "dgelsd")

        workSize = __CLPK_integer(max(1, min(query[0], Double(Int32.max / 2))))
        var work = [Double](repeating: 0, count: Int(workSize))
        var integerWork = [__CLPK_integer](repeating: 0, count: max(1, Int(integerQuery[0])))
        dgelsd_(&m, &n, &one, &a, &leadingDimension, &b, &rightDimension, &singularValues, &threshold, &rank,
                &work, &workSize, &integerWork, &info)
        try check(Int(info), routine: "dgelsd")
        return (Array(b.prefix(columns)), Int(rank))
    }

    /// Solves a full-rank system by an orthogonal factorisation (`dgels`): the least-squares
    /// solution of an overdetermined system (QR), the minimum-norm solution of an
    /// underdetermined one (LQ). The condition number of the matrix enters once, where the
    /// normal equations would square it.
    ///
    /// - Parameters:
    ///   - matrix: `rows × columns` values, column by column, of full rank.
    ///   - rightHandSide: `rows` values.
    /// - Returns: The `columns` values of the solution.
    /// - Throws: `DSPError.invalidParameter` for storage of the wrong size;
    ///   `DSPError.numericalFailure` when the triangular factor has a zero on its diagonal
    ///   (`info > 0`: the matrix has no full rank).
    static func solveByOrthogonalFactorization(
        _ matrix: [Double], rows: Int, columns: Int, rightHandSide: [Double]
    ) throws(DSPError) -> [Double] {
        guard rows >= 1, columns >= 1, rows <= Int(Int32.max / 2), columns <= Int(Int32.max / 2),
              matrix.count == rows * columns, rightHandSide.count == rows
        else {
            throw .invalidParameter(stage: .none, parameter: "matrix", reason: "\(matrix.count) values and a right-hand side of \(rightHandSide.count) do not form a \(rows) × \(columns) system")
        }
        var a = matrix
        let longest = max(rows, columns)
        var b = rightHandSide + [Double](repeating: 0, count: longest - rows)
        var transpose = CChar(UInt8(ascii: "N"))
        var m = __CLPK_integer(rows)
        var n = __CLPK_integer(columns)
        var one = __CLPK_integer(1)
        var leadingDimension = m
        var rightDimension = __CLPK_integer(longest)
        var info = __CLPK_integer(0)

        var workSize = __CLPK_integer(-1)
        var query = [Double](repeating: 0, count: 1)
        dgels_(&transpose, &m, &n, &one, &a, &leadingDimension, &b, &rightDimension, &query, &workSize, &info)
        try check(Int(info), routine: "dgels")

        workSize = __CLPK_integer(max(1, min(query[0], Double(Int32.max / 2))))
        var work = [Double](repeating: 0, count: Int(workSize))
        dgels_(&transpose, &m, &n, &one, &a, &leadingDimension, &b, &rightDimension, &work, &workSize, &info)
        try check(Int(info), routine: "dgels")
        return Array(b.prefix(columns))
    }
}
