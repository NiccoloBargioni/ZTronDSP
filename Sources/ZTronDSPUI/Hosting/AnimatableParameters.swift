import SwiftUI
import ZTronDSPCore

/// The continuous values of a hosted pipeline, as the vector SwiftUI interpolates (ANI-2,
/// ANI-3): every gain, in decibels, and every frequency, as log₂ of hertz, of every stage,
/// in order.
///
/// The length of the vector is the pipeline's and is known only at run time. Vectors of
/// pipelines of one topology form a vector space, and SwiftUI interpolates in it. A change
/// of topology is not interpolated (ANI-4): the difference of two vectors that belong to
/// different topologies is a **replacement**, which stands for its left operand; scaling a
/// replacement leaves it as it is, and adding one to anything gives its values. So
/// `from + (to − from) · t` is `to`, at once, for every `t`. Two vectors belong to different
/// topologies when their lengths differ, as `ParameterVector` has it, and also when the
/// pipelines they were taken from differ in more than their continuous values, which the
/// lengths alone cannot tell.
///
/// The vector with no values and no pipeline is the zero of every length.
///
/// An immutable value, usable on any thread.
struct AnimatableParameters: VectorArithmetic, Sendable {
    var values: [Double]
    /// The pipeline the values were taken from, with every continuous value set to nought:
    /// what the pipeline is apart from them. `nil` for a quantity that arithmetic made.
    var structure: AnyStrategy?
    var isReplacement = false

    init(values: [Double] = [], structure: AnyStrategy? = nil, isReplacement: Bool = false) {
        self.values = values
        self.structure = structure
        self.isReplacement = isReplacement
    }

    /// The vector of `pipeline`.
    init<Output: SignalDomain>(_ pipeline: Pipeline<Samples, Output>) {
        let vector = pipeline.parameters
        values = vector.values
        structure = AnyStrategy(pipeline.replacingParameters(ParameterVector([Double](repeating: 0, count: vector.count))))
    }

    /// The values as the core's vector.
    var vector: ParameterVector { ParameterVector(values) }

    static var zero: AnimatableParameters { AnimatableParameters() }

    private var isZero: Bool { values.isEmpty && structure == nil && !isReplacement }

    private func hasTopology(of other: AnimatableParameters) -> Bool {
        guard values.count == other.values.count else { return false }
        guard let structure, let others = other.structure else { return true }
        return structure == others
    }

    static func + (lhs: AnimatableParameters, rhs: AnimatableParameters) -> AnimatableParameters {
        if rhs.isReplacement { return AnimatableParameters(values: rhs.values, structure: rhs.structure) }
        if lhs.isReplacement { return AnimatableParameters(values: lhs.values, structure: lhs.structure) }
        if lhs.isZero { return rhs }
        if rhs.isZero { return lhs }
        guard lhs.values.count == rhs.values.count else { return rhs }
        return AnimatableParameters(values: zip(lhs.values, rhs.values).map { $0 + $1 }, structure: lhs.structure ?? rhs.structure)
    }

    static func - (lhs: AnimatableParameters, rhs: AnimatableParameters) -> AnimatableParameters {
        if lhs.isReplacement || rhs.isZero { return lhs }
        if lhs.isZero { return AnimatableParameters(values: rhs.values.map { -$0 }, structure: rhs.structure) }
        guard !rhs.isReplacement, lhs.hasTopology(of: rhs) else {
            return AnimatableParameters(values: lhs.values, structure: lhs.structure, isReplacement: true)
        }
        return AnimatableParameters(values: zip(lhs.values, rhs.values).map { $0 - $1 }, structure: lhs.structure ?? rhs.structure)
    }

    mutating func scale(by factor: Double) {
        guard !isReplacement else { return }
        values = values.map { $0 * factor }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}
