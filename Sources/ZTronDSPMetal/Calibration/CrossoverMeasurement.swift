import Foundation
import ZTronDSPCore

/// An entry of a `CrossoverTable` that a measurement can decide (§7.4): the size from which
/// the heavier of two implementations of a primitive is the faster one.
public enum CrossoverEntry: String, Hashable, Sendable, Codable, CaseIterable {
    /// Element-wise vector operations: a Swift loop against vDSP, by the vector's length.
    case elementwise
    /// Reductions: a scalar Swift loop against the 8-lane loop, by the vector's length.
    case reductionSIMD
    /// Reductions: the 8-lane Swift loop against vDSP, by the vector's length.
    case reductionAccelerate
    /// The minimum / maximum exchange of two lanes: a C loop against vDSP, by the lane's length.
    case laneExchange
    /// The gain kernel: a C loop against vDSP, by the block size.
    case gainKernel
    /// A single-precision biquad cascade: a C loop against `vDSP_biquad`, by the block size.
    case biquadKernel
    /// An FIR: the direct kernel against the partitioned one, by the number of taps.
    case firPartitioned
    /// A mel projection: banded dot products against a dense product, by bands × bins.
    case melDense
    /// An offline median: CPU lanes against the GPU, by kernel × bins × frames.
    case medianGPU

    /// What the entry is called on a plot.
    public var title: String {
        switch self {
        case .elementwise: "Element-wise (scale)"
        case .reductionSIMD: "Reduction (dot product), scalar to 8 lanes"
        case .reductionAccelerate: "Reduction (dot product), 8 lanes to vDSP"
        case .laneExchange: "Lane exchange"
        case .gainKernel: "Gain kernel"
        case .biquadKernel: "Biquad cascade, four sections"
        case .firPartitioned: "FIR, blocks of 512 frames"
        case .melDense: "Mel projection"
        case .medianGPU: "Median of a spectrogram"
        }
    }

    /// What the size that decides the entry counts, with its unit.
    public var sizeLabel: String {
        switch self {
        case .elementwise, .reductionSIMD, .reductionAccelerate, .laneExchange: "Length (elements)"
        case .gainKernel, .biquadKernel: "Block size (frames)"
        case .firPartitioned: "Taps"
        case .melDense: "Bands x bins"
        case .medianGPU: "Kernel x bins x frames"
        }
    }
}

/// The time one implementation of a primitive takes at each size of a grid.
///
/// An immutable value, usable on any thread.
public struct CalibrationCurve: Hashable, Sendable, Codable {
    /// The kind of implementation: `.native`, `.accelerate` or `.metal`.
    public let implementation: Implementation
    /// What the implementation is, in a few words: "C loop", "vDSP_biquad".
    public let label: String
    /// Nanoseconds per call at each size of the measurement's grid.
    public let nanoseconds: [Double]

    public init(implementation: Implementation, label: String, nanoseconds: [Double]) {
        self.implementation = implementation
        self.label = label
        self.nanoseconds = nanoseconds
    }
}

/// What was measured for one entry of the table: the grid of sizes, a curve per
/// implementation, and the crossover read off them.
///
/// An immutable value, usable on any thread.
public struct CrossoverMeasurement: Hashable, Sendable, Codable {
    /// The entry of the table the measurement decides.
    public let entry: CrossoverEntry
    /// The sizes measured, increasing.
    public let sizes: [Int]
    /// One curve per implementation, the lighter one first: the one that leads at small sizes.
    public let curves: [CalibrationCurve]
    /// The smallest size of the grid from which the second implementation is faster than the
    /// first at that size and at every larger one. `nil` when it is not faster at the largest
    /// size, and when only one implementation was measured.
    public let crossover: Int?

    /// A measurement from its curves; the crossover is read off the first two.
    public init(entry: CrossoverEntry, sizes: [Int], curves: [CalibrationCurve]) {
        self.entry = entry
        self.sizes = sizes
        self.curves = curves
        crossover = curves.count >= 2 ? Calibration.crossover(sizes: sizes, lighter: curves[0].nanoseconds, heavier: curves[1].nanoseconds) : nil
    }
}

/// A measured `CrossoverTable` together with the measurements it was read from (SEL-5): what
/// `Calibration.report()` returns, and what exports as a MATLAB script (§6.14, WP-614).
///
/// An immutable value, usable on any thread, and `Codable`, so an app can keep it.
public struct CalibrationReport: Hashable, Sendable, Codable {
    /// The table: the one the measurements started from, with every entry that was measured
    /// against a second implementation replaced by its crossover. An entry whose heavier
    /// implementation never led is `Int.max`: never use it.
    public let table: CrossoverTable
    /// What was measured, in the order it was measured.
    public let measurements: [CrossoverMeasurement]

    /// - Parameter base: the table the entries that were not measured are taken from.
    public init(measurements: [CrossoverMeasurement], startingFrom base: CrossoverTable = .shipped) {
        self.measurements = measurements
        var table = base
        for measurement in measurements where measurement.curves.count >= 2 {
            table = table.replacing(measurement.entry, with: measurement.crossover ?? Int.max)
        }
        self.table = table
    }
}

extension CrossoverTable {
    /// The table with one entry replaced. A table is an immutable value: this returns another.
    public func replacing(_ entry: CrossoverEntry, with size: Int) -> CrossoverTable {
        CrossoverTable(
            elementwise: entry == .elementwise ? size : elementwise,
            reductionSIMD: entry == .reductionSIMD ? size : reductionSIMD,
            reductionAccelerate: entry == .reductionAccelerate ? size : reductionAccelerate,
            laneExchange: entry == .laneExchange ? size : laneExchange,
            gainKernel: entry == .gainKernel ? size : gainKernel,
            biquadKernel: entry == .biquadKernel ? size : biquadKernel,
            firPartitioned: entry == .firPartitioned ? size : firPartitioned,
            convolutionFFTFactor: convolutionFFTFactor,
            melDense: entry == .melDense ? size : melDense,
            medianGPU: entry == .medianGPU ? size : medianGPU,
            polynomialClosedForm: polynomialClosedForm)
    }

    /// The value of one entry.
    public func size(of entry: CrossoverEntry) -> Int {
        switch entry {
        case .elementwise: elementwise
        case .reductionSIMD: reductionSIMD
        case .reductionAccelerate: reductionAccelerate
        case .laneExchange: laneExchange
        case .gainKernel: gainKernel
        case .biquadKernel: biquadKernel
        case .firPartitioned: firPartitioned
        case .melDense: melDense
        case .medianGPU: medianGPU
        }
    }
}

// MARK: MATLAB export (WP-614)

extension CalibrationReport: MATLABExportable {
    /// The measurements as a MATLAB script: for every entry measured, the sizes and the time
    /// per call of each implementation as variables, and a plot of time against size on
    /// logarithmic axes, one curve per implementation (§6.14). Core MATLAB only, so the script
    /// also runs in GNU Octave (MAT-2); equal reports give equal text (MAT-4).
    ///
    /// Runs on the background executor (MAT-6); the caller may be on any thread but the
    /// analysis thread.
    public func matlabScript() async throws(DSPError) -> String {
        let report = self
        return try await BackgroundWork.run { _ throws(DSPError) -> String in try report.script().text }
    }

    /// The line styles of the curves of one plot, in order.
    static let styles = ["o-", "x--", "s:", "d-."]

    func script() throws(DSPError) -> MATLABScript {
        var script = MATLABScript()
            .comment("ZTronDSP calibration: time per call against size, one curve per implementation.")
        for measurement in measurements {
            script = script.comment("\(measurement.entry.rawValue): \(Self.summary(of: measurement))")
            script = try script.vector("sizes_\(measurement.entry.rawValue)", measurement.sizes.map(Double.init))
            for (index, curve) in measurement.curves.enumerated() {
                script = try script.vector("ns_\(measurement.entry.rawValue)_\(index + 1)", curve.nanoseconds)
            }
        }
        let columns = measurements.count > 1 ? 2 : 1
        let rows = (measurements.count + columns - 1) / columns
        for (position, measurement) in measurements.enumerated() {
            script = script.subplot(rows, columns, position + 1)
            var legend: [String] = []
            for (index, curve) in measurement.curves.enumerated() {
                let style = Self.styles[index % Self.styles.count]
                script = script.loglog("sizes_\(measurement.entry.rawValue)", "ns_\(measurement.entry.rawValue)_\(index + 1)", style: style)
                if index == 0, measurement.curves.count > 1 { script = script.hold() }
                legend.append("\(curve.label) (\(style))")
            }
            if measurement.curves.count > 1 { script = script.hold(false) }
            script = script.grid()
                .xlabel(measurement.entry.sizeLabel)
                .ylabel("Time per call (ns)")
                .title("\(measurement.entry.title): \(legend.joined(separator: ", "))")
        }
        return script
    }

    private static func summary(of measurement: CrossoverMeasurement) -> String {
        let names = measurement.curves.map(\.label).joined(separator: " against ")
        guard measurement.curves.count >= 2 else { return "\(names), one implementation measured" }
        return measurement.crossover.map { "\(names), crossover at \($0)" } ?? "\(names), no crossover on the grid"
    }
}
