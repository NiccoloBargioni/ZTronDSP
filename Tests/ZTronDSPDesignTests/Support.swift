import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

// Shared by the tests of the LTI design packages (M4).

/// The golden files of this target, each parsed once.
enum Golden {
    static let prototypes = Result { try GoldenFile(named: "analog_prototypes", in: .module) }
    static let ellipticFunctions = Result { try GoldenFile(named: "elliptic_functions", in: .module) }
    static let transformations = Result { try GoldenFile(named: "frequency_transformations", in: .module) }
    static let sectionPairing = Result { try GoldenFile(named: "section_pairing", in: .module) }
    static let order = Result { try GoldenFile(named: "iir_order", in: .module) }
    static let design = Result { try GoldenFile(named: "iir_design", in: .module) }
    static let cookbook = Result { try GoldenFile(named: "cookbook_equalizers", in: .module) }
}

extension GoldenCase {
    /// A complex golden vector as `Complex` values.
    func complexes(_ key: String) throws -> [Complex] {
        let (real, imaginary) = try complex(key)
        return zip(real, imaginary).map { Complex($0, $1) }
    }

    /// The single number of a one-element vector.
    func scalar(_ key: String) throws -> Double {
        let values = try real(key)
        try #require(values.count == 1, "\(name).\(key) holds \(values.count) values")
        return values[0]
    }
}

/// The worst deviation seen per quantity, printed when the test process exits, so that the
/// figures a report quotes are the ones the tests measured. One line per quantity:
/// `MEASURED|<label>|<worst>|<bound>`.
final class Measurements: @unchecked Sendable {
    static let shared = Measurements()
    private let lock = NSLock()
    private var worst: [String: (value: Double, bound: Double)] = [:]

    private init() {
        atexit { Measurements.shared.dump() }
    }

    func record(_ label: String, _ value: Double, bound: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let current = worst[label], current.value >= value { return }
        worst[label] = (value, bound)
    }

    private func dump() {
        lock.lock()
        defer { lock.unlock() }
        for label in worst.keys.sorted() {
            guard let entry = worst[label] else { continue }
            print("MEASURED|\(label)|\(entry.value)|\(entry.bound)")
        }
    }
}

/// How two sets of roots are compared. SciPy's order is not ours, so the two sets are
/// *matched*: every expected root is assigned one computed root, each computed root used
/// once, in the assignment whose worst pair is as good as possible (a bottleneck matching).
/// The pairs are held to a relative tolerance, `|actual − expected| ≤ tolerance·|expected|`;
/// an expected root that is exactly zero must be matched by one that is exactly zero.
///
/// The set passes exactly when *some* assignment puts every pair within tolerance, so the
/// verdict does not depend on the order either side lists its roots in.
///
/// - Returns: The worst relative deviation of the best assignment, or `nil` when the sets
///   cannot be compared.
@discardableResult
func expectRootsClose(
    _ actual: [Complex], _ expected: [Complex], relative tolerance: Double, _ comment: @autoclosure () -> String,
    measure label: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) -> Double? {
    guard actual.count == expected.count else {
        Issue.record("\(comment()): \(actual.count) roots, \(expected.count) expected", sourceLocation: sourceLocation)
        return nil
    }
    guard actual.allSatisfy(\.isFinite) else {
        Issue.record("\(comment()): a computed root is not finite", sourceLocation: sourceLocation)
        return nil
    }
    let worst = RootMatching.bottleneck(actual, expected)
    if !(worst <= tolerance) {
        Issue.record("\(comment()): the best assignment of the \(actual.count) computed roots to the expected ones leaves a relative deviation of \(worst), which exceeds \(tolerance)", sourceLocation: sourceLocation)
    }
    if let label { Measurements.shared.record(label, worst, bound: tolerance) }
    return worst
}

enum RootMatching {
    /// The relative deviation of one pair.
    static func deviation(_ actual: Complex, _ expected: Complex) -> Double {
        let distance = (actual - expected).magnitude
        let scale = expected.magnitude
        return scale > 0 ? distance / scale : (distance == 0 ? 0 : .infinity)
    }

    /// The smallest `d` for which a perfect matching exists that uses only pairs deviating by
    /// at most `d`: binary search over the pair deviations, with an augmenting-path matching
    /// (Kuhn) at each step.
    static func bottleneck(_ actual: [Complex], _ expected: [Complex]) -> Double {
        let count = expected.count
        guard count > 0 else { return 0 }
        let deviations = expected.map { e in actual.map { deviation($0, e) } }
        let candidates = Array(Set(deviations.joined())).sorted()

        func isFeasible(_ limit: Double) -> Bool {
            var owner = [Int](repeating: -1, count: count)        // owner[actual] = expected
            func augment(_ row: Int, _ visited: inout [Bool]) -> Bool {
                for column in 0 ..< count where deviations[row][column] <= limit && !visited[column] {
                    visited[column] = true
                    if owner[column] < 0 || augment(owner[column], &visited) {
                        owner[column] = row
                        return true
                    }
                }
                return false
            }
            for row in 0 ..< count {
                var visited = [Bool](repeating: false, count: count)
                if !augment(row, &visited) { return false }
            }
            return true
        }

        var low = 0
        var high = candidates.count - 1
        guard isFeasible(candidates[high]) else { return .infinity }
        while low < high {
            let middle = (low + high) / 2
            if isFeasible(candidates[middle]) { high = middle } else { low = middle + 1 }
        }
        return candidates[low]
    }
}

/// Compares the coefficients of a polynomial that was multiplied out from roots.
///
/// A coefficient is a sum of products of roots, and is known to a relative accuracy of that
/// sum's *terms*, not of the sum, which may cancel to zero (the odd coefficients of an
/// elliptic numerator do). So coefficient `k` is held to `tolerance` times its natural
/// scale: the same coefficient of the polynomial whose roots are the magnitudes `|rᵢ|`,
/// times the leading coefficient.
@discardableResult
func expectCoefficientsClose(
    _ actual: [Double], _ expected: [Double], roots: [Complex], leading: Double, relative tolerance: Double,
    _ comment: @autoclosure () -> String, measure label: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) -> Double? {
    // Left-pad the shorter list: a leading coefficient of zero is dropped by `Polynomial`.
    let count = max(actual.count, expected.count)
    let a = [Double](repeating: 0, count: count - actual.count) + actual
    let e = [Double](repeating: 0, count: count - expected.count) + expected
    let scale = Polynomial(realRoots: roots.map { -$0.magnitude }, leadingCoefficient: abs(leading)).coefficients
    guard scale.count <= count else {
        Issue.record("\(comment()): \(count) coefficients for \(roots.count) roots", sourceLocation: sourceLocation)
        return nil
    }
    let scales = [Double](repeating: 0, count: count - scale.count) + scale
    var worst = 0.0
    for index in 0 ..< count {
        let deviation = abs(a[index] - e[index])
        let bound = tolerance * scales[index]
        if scales[index] > 0 { worst = max(worst, deviation / scales[index]) }
        if !(deviation <= bound) {
            Issue.record("\(comment()): coefficient \(index) is \(a[index]) where \(e[index]) was expected: deviation \(deviation) exceeds \(bound)", sourceLocation: sourceLocation)
        }
    }
    if let label { Measurements.shared.record(label, worst, bound: tolerance) }
    return worst
}

/// `|actual − expected| ≤ tolerance · max|expected|` for every point of a complex response.
@discardableResult
func expectResponseClose(
    _ actual: [Complex], _ expected: [Complex], relativeToPeak tolerance: Double, _ comment: @autoclosure () -> String,
    measure label: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) -> Double? {
    guard actual.count == expected.count else {
        Issue.record("\(comment()): \(actual.count) points, \(expected.count) expected", sourceLocation: sourceLocation)
        return nil
    }
    let peak = expected.map(\.magnitude).max() ?? 0
    var worst = 0.0
    var failures = 0
    for index in actual.indices {
        let deviation = (actual[index] - expected[index]).magnitude
        worst = max(worst, peak > 0 ? deviation / peak : deviation)
        if !(deviation <= tolerance * peak) { failures += 1 }
    }
    if failures > 0 {
        Issue.record("\(comment()): \(failures) of \(actual.count) points deviate by more than \(tolerance) of the peak; the worst by \(worst)", sourceLocation: sourceLocation)
    }
    if let label { Measurements.shared.record(label, worst, bound: tolerance) }
    return worst
}

/// The amplifications a golden case names, for the stock families.
func family(named name: String, _ golden: GoldenCase) throws -> any FilterFamily {
    switch name {
    case "butterworth": return ButterworthFamily()
    case "chebyshev1": return Chebyshev1Family(ripple: .decibels(try golden.number("ripple")))
    case "chebyshev2": return Chebyshev2Family(stopband: .decibels(try golden.number("stopband")))
    case "elliptic": return EllipticFamily(ripple: .decibels(try golden.number("ripple")), stopband: .decibels(try golden.number("stopband")))
    case "bessel": return BesselFamily(normalization: .phase)
    default:
        Issue.record("unknown family \(name)")
        return ButterworthFamily()
    }
}

/// The response a golden case names, with the given edges.
func response(named name: String, edges: [Double]) throws -> FilterResponse {
    switch name {
    case "lowpass": return .lowPass(cutoff: edges[0])
    case "highpass": return .highPass(cutoff: edges[0])
    case "bandpass": return .bandPass(from: edges[0], to: edges[1])
    case "bandstop": return .bandStop(from: edges[0], to: edges[1])
    default:
        Issue.record("unknown response \(name)")
        return .lowPass(cutoff: edges[0])
    }
}

/// Opens the family existential for the generic initialiser.
func design(_ family: any FilterFamily, _ response: FilterResponse, order: Int, domain: IIRDesign.Domain) throws -> IIRDesign {
    func open(_ family: some FilterFamily) throws -> IIRDesign {
        try IIRDesign(family, response, order: order, domain: domain)
    }
    return try open(family)
}

/// The error a throwing expression raises, for tests that inspect it.
func thrownError(_ body: () throws -> Void) -> DSPError? {
    do {
        try body()
        return nil
    } catch let error as DSPError {
        return error
    } catch {
        return nil
    }
}

extension DSPError {
    /// The parameter an `invalidParameter` error names.
    var invalidParameterName: String? {
        if case .invalidParameter(_, let parameter, _) = self { return parameter }
        return nil
    }

    var isUnsupportedConfiguration: Bool {
        if case .unsupportedConfiguration = self { return true }
        return false
    }

    var numericalFailure: (routine: String, info: Int)? {
        if case .numericalFailure(let routine, let info, _) = self { return (routine, info) }
        return nil
    }
}

/// One design of the matrix of `iir_design.json`: family × response × orders 1, 2, 5, 8.
struct DesignCase {
    let golden: GoldenCase
    let familyName: String
    let responseName: String
    let order: Int
    let isAnalog: Bool
    let domain: IIRDesign.Domain
    let design: IIRDesign

    /// Every design of one domain, built through the public initialiser.
    static func all(analog: Bool) throws -> [DesignCase] {
        let file = try Golden.design.get()
        var result: [DesignCase] = []
        for golden in file.cases where golden.parameters["family"] != nil {
            let isAnalog = try golden.string("domain") == "analog"
            guard isAnalog == analog else { continue }
            let familyName = try golden.string("family")
            let responseName = try golden.string("response")
            let order = try golden.integer("order")
            let domain: IIRDesign.Domain = isAnalog ? .analog : .digital(sampleRate: try golden.number("sample_rate"))
            let built = try ZTronDSPDesignTests.design(
                try family(named: familyName, golden), try response(named: responseName, edges: try golden.numbers("edges")),
                order: order, domain: domain)
            result.append(DesignCase(golden: golden, familyName: familyName, responseName: responseName, order: order,
                                     isAnalog: isAnalog, domain: domain, design: built))
        }
        try #require(result.count == 5 * 4 * 4, "family × response × orders 1, 2, 5, 8")
        return result
    }
}

/// The sampled curves of `iir_design.json`: raw matrices, one block of rows per design.
struct DesignCurves {
    let values: [Double]
    let shape: [Int]

    init(domain: String, key: String) throws {
        let golden = try Golden.design.get().require("\(domain)-curves")
        values = try golden.real(key)
        shape = try golden.shape(key)
        try #require(shape.count == 3 && shape[2] == 512)
    }

    /// One curve of one design.
    func curve(row: Int, channel: Int) -> [Double] {
        let start = (row * shape[1] + channel) * shape[2]
        return Array(values[start ..< start + shape[2]])
    }

    func complexCurve(row: Int) -> [Complex] {
        zip(curve(row: row, channel: 0), curve(row: row, channel: 1)).map { Complex($0, $1) }
    }

    /// The frequency grid of a domain.
    static func grid(_ domain: String) throws -> [Double] {
        try Golden.design.get().require("grid").real(domain)
    }
}
