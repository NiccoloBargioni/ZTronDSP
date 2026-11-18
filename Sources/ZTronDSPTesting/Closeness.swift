import Foundation
import Testing

/// How near two numbers, or two sequences of numbers, have to be.
///
/// One value answers one question, so a test states its tolerance where it compares:
/// `expectClose(output, reference, .deviationBelow(decibels: -100))`.
public enum Tolerance: Sendable, Equatable, CustomStringConvertible {
    /// `|actual − expected| ≤ bound` for every element.
    case absolute(Double)
    /// `|actual − expected| ≤ bound · max(|actual|, |expected|)` for every element.
    case relative(Double)
    /// The levels differ by at most `bound` decibels, element by element:
    /// `|20·log₁₀(|actual| / |expected|)| ≤ bound`. Two zeros agree; a zero and a non-zero
    /// value do not.
    case decibels(Double)
    /// `|actual − expected| ≤ bound · max|expected|`, the maximum taken over the whole
    /// sequence. This is how tolerances on spectra are stated (specification §6.1): relative
    /// to the largest value of the frame, not to each bin.
    case relativeToMaximum(Double)
    /// The largest deviation lies at or below `decibels` relative to the peak of the expected
    /// sequence: `20·log₁₀(max|actual − expected| / max|expected|) ≤ decibels`. Reads as
    /// "within −100 dB".
    case deviationBelow(decibels: Double)

    public var description: String {
        switch self {
        case .absolute(let bound): "absolute tolerance \(bound)"
        case .relative(let bound): "relative tolerance \(bound)"
        case .decibels(let bound): "level tolerance \(bound) dB"
        case .relativeToMaximum(let bound): "tolerance \(bound) of the largest expected value"
        case .deviationBelow(let decibels): "deviation bound \(decibels) dB below the expected peak"
        }
    }
}

/// Why two sequences are not close. `nil` from ``Closeness/compare(_:_:_:)`` means they are.
public struct ClosenessFailure: Sendable, Equatable, CustomStringConvertible {
    /// What went wrong.
    public enum Reason: Sendable, Equatable {
        /// The sequences have different lengths.
        case countMismatch(actual: Int, expected: Int)
        /// At least one element is out of tolerance; the fields describe the worst one.
        case outOfTolerance
        /// An element is NaN or infinite and does not equal its counterpart.
        case nonFinite
    }

    public let reason: Reason
    /// Index of the worst element.
    public let index: Int
    public let actual: Double
    public let expected: Double
    /// The deviation of the worst element, in the measure of the tolerance.
    public let deviation: Double
    /// The bound the deviation was held against, in the same measure.
    public let bound: Double
    /// How many elements are out of tolerance.
    public let failingCount: Int
    public let count: Int
    public let tolerance: Tolerance

    public var description: String {
        switch reason {
        case .countMismatch(let actualCount, let expectedCount):
            return "count mismatch: \(actualCount) values, \(expectedCount) expected"
        case .nonFinite:
            return "element \(index) is \(actual) where \(expected) was expected (non-finite values must match exactly)"
        case .outOfTolerance:
            let position = count == 1 ? "value" : "element \(index)"
            let scope = count == 1 ? "" : "; \(failingCount) of \(count) elements out of tolerance"
            return "\(position) is \(actual) where \(expected) was expected: deviation \(deviation) exceeds \(bound) (\(tolerance))\(scope)"
        }
    }
}

/// The comparison behind ``expectClose(_:_:_:_:sourceLocation:)-swift.func``, usable on its own.
public enum Closeness {
    /// Compares two sequences element by element. Returns `nil` when `actual` is within
    /// `tolerance` of `expected`, otherwise a description of the worst deviation.
    ///
    /// Non-finite values are never "close": a NaN fails, and an infinity passes only against
    /// the same infinity.
    public static func compare<A: Collection, E: Collection>(
        _ actual: A, _ expected: E, _ tolerance: Tolerance
    ) -> ClosenessFailure? where A.Element: BinaryFloatingPoint, E.Element: BinaryFloatingPoint {
        let count = expected.count
        guard actual.count == count else {
            return ClosenessFailure(
                reason: .countMismatch(actual: actual.count, expected: count), index: 0, actual: .nan,
                expected: .nan, deviation: .infinity, bound: 0, failingCount: 0, count: count, tolerance: tolerance)
        }

        var expectedPeak = 0.0
        for value in expected { expectedPeak = max(expectedPeak, abs(Double(value))) }

        var worstIndex = -1
        var worstExcess = -Double.infinity
        var worst = (actual: 0.0, expected: 0.0, deviation: 0.0, bound: 0.0)
        var failing = 0

        var index = 0
        var expectedIterator = expected.makeIterator()
        for element in actual {
            defer { index += 1 }
            let a = Double(element)
            let e = Double(expectedIterator.next()!)

            guard a.isFinite, e.isFinite else {
                if a == e { continue }
                return ClosenessFailure(
                    reason: .nonFinite, index: index, actual: a, expected: e, deviation: .infinity, bound: 0,
                    failingCount: 1, count: count, tolerance: tolerance)
            }

            let deviation: Double
            let bound: Double
            switch tolerance {
            case .absolute(let limit):
                deviation = abs(a - e); bound = limit
            case .relative(let limit):
                deviation = abs(a - e); bound = limit * max(abs(a), abs(e))
            case .decibels(let limit):
                if a == 0 && e == 0 {
                    deviation = 0
                } else if a == 0 || e == 0 {
                    deviation = .infinity
                } else {
                    deviation = abs(20 * log10(abs(a) / abs(e)))
                }
                bound = limit
            case .relativeToMaximum(let limit):
                deviation = abs(a - e); bound = limit * expectedPeak
            case .deviationBelow(let decibels):
                deviation = abs(a - e); bound = expectedPeak * pow(10, decibels / 20)
            }

            if deviation > bound {
                failing += 1
                let excess = bound > 0 ? deviation / bound : (deviation > 0 ? .infinity : 0)
                if excess > worstExcess || worstIndex < 0 {
                    worstExcess = excess
                    worstIndex = index
                    worst = (a, e, deviation, bound)
                }
            }
        }

        guard failing > 0 else { return nil }
        return ClosenessFailure(
            reason: .outOfTolerance, index: worstIndex, actual: worst.actual, expected: worst.expected,
            deviation: worst.deviation, bound: worst.bound, failingCount: failing, count: count, tolerance: tolerance)
    }

    /// The scalar form of ``compare(_:_:_:)``.
    public static func compare<T: BinaryFloatingPoint, U: BinaryFloatingPoint>(
        _ actual: T, _ expected: U, _ tolerance: Tolerance
    ) -> ClosenessFailure? {
        compare(CollectionOfOne(actual), CollectionOfOne(expected), tolerance)
    }
}

/// Records an issue unless `actual` is within `tolerance` of `expected`.
///
/// - Returns: `true` when the values are close, so a test can stop early on a failure.
@discardableResult
public func expectClose<T: BinaryFloatingPoint, U: BinaryFloatingPoint>(
    _ actual: T, _ expected: U, _ tolerance: Tolerance,
    _ comment: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    report(Closeness.compare(actual, expected, tolerance), comment(), sourceLocation)
}

/// Records an issue unless every element of `actual` is within `tolerance` of its counterpart
/// in `expected`. The issue names the worst element and counts the others.
///
/// - Returns: `true` when the sequences are close.
@discardableResult
public func expectClose<A: Collection, E: Collection>(
    _ actual: A, _ expected: E, _ tolerance: Tolerance,
    _ comment: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool where A.Element: BinaryFloatingPoint, E.Element: BinaryFloatingPoint {
    report(Closeness.compare(actual, expected, tolerance), comment(), sourceLocation)
}

private func report(_ failure: ClosenessFailure?, _ comment: String, _ sourceLocation: SourceLocation) -> Bool {
    guard let failure else { return true }
    let prefix = comment.isEmpty ? "" : "\(comment): "
    Issue.record("\(prefix)\(failure)", sourceLocation: sourceLocation)
    return false
}
