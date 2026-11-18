/// The continuous values of a pipeline, in order: what an animation interpolates (ANI-2).
///
/// Frequencies are carried as log₂ of their stated value, so an animated cutoff glides evenly
/// in pitch, and gains in decibels. Orders, sizes, windows and strategies are not in the
/// vector: they are structure.
///
/// Vectors of one length form a vector space. Vectors of different lengths belong to
/// pipelines of different topology, which are not interpolated (ANI-4): the difference of two
/// such vectors is a **replacement** that stands for its left operand, scaling a replacement
/// leaves it unchanged, and adding one to any vector gives the replacement's values. An
/// interpolation `from + (to − from) · t` therefore yields `to` at once, for every `t`.
///
/// An immutable value, usable on any thread.
public struct ParameterVector: Hashable, Sendable {
    public let values: [Double]
    /// True for the difference of two vectors of unequal length; see the type's description.
    public let isReplacement: Bool

    public init(_ values: [Double] = []) {
        self.values = values
        self.isReplacement = false
    }

    package init(replacement values: [Double]) {
        self.values = values
        self.isReplacement = true
    }

    /// The vector with no values.
    public static let zero = ParameterVector()

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    public static func + (lhs: ParameterVector, rhs: ParameterVector) -> ParameterVector {
        if rhs.isReplacement { return ParameterVector(rhs.values) }
        if lhs.isReplacement { return ParameterVector(lhs.values) }
        guard lhs.values.count == rhs.values.count else { return rhs }
        return ParameterVector(zip(lhs.values, rhs.values).map { $0 + $1 })
    }

    public static func - (lhs: ParameterVector, rhs: ParameterVector) -> ParameterVector {
        if lhs.isReplacement { return lhs }
        guard lhs.values.count == rhs.values.count, !rhs.isReplacement else {
            return ParameterVector(replacement: lhs.values)
        }
        return ParameterVector(zip(lhs.values, rhs.values).map { $0 - $1 })
    }

    /// Every value multiplied by `factor`. A replacement is returned unchanged.
    public func scaled(by factor: Double) -> ParameterVector {
        isReplacement ? self : ParameterVector(values.map { $0 * factor })
    }

    /// The sum of the squares of the values.
    public var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    /// The vector with `other`'s values after its own: how the values of consecutive stages
    /// are gathered.
    public func appending(_ other: ParameterVector) -> ParameterVector {
        ParameterVector(values + other.values)
    }
}
