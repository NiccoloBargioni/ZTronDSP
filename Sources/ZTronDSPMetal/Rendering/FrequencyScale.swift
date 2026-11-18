import Foundation
import ZTronDSPCore

/// How the frequency axis of a view is laid out (§5.3): the strategy behind
/// `.frequencyScale(_:)`.
///
/// A scale places a frequency on an axis: `position(of:)` says where, in whatever unit the
/// scale counts in (hertz, octaves, mels), and `frequency(at:)` is its inverse. A view shows
/// the frequencies between two positions evenly spaced in that unit. The scale only warps the
/// display of rows that are evenly spaced in hertz; rows that are already mel bands or
/// constant-Q bins are drawn bin for bin (VC-5, IN-11).
///
/// Pass `.linear`, `.logarithmic`, `.mel`, or a conformer of your own. A conformer's position
/// grows with the frequency, and its two functions invert each other.
///
/// Conformers are immutable values, usable on any thread. The functions are called on the
/// main thread or on the background executor when a scale is set, a few thousand times, never
/// on the analysis thread.
public protocol FrequencyScale: Hashable, Sendable {
    /// Where `hertz` sits on the axis, in the scale's own unit. Grows with the frequency.
    func position(of hertz: Double) -> Double
    /// The frequency, in hertz, that sits at `position`.
    func frequency(at position: Double) -> Double
}

/// Frequencies evenly spaced in hertz.
public struct LinearFrequencyScale: FrequencyScale {
    public init() {}

    public func position(of hertz: Double) -> Double { hertz }
    public func frequency(at position: Double) -> Double { position }
}

/// Frequencies evenly spaced in octaves. An axis cannot reach 0 Hz that way, so it starts at
/// `lowestFrequency`: frequencies below it sit at its position.
public struct LogarithmicFrequencyScale: FrequencyScale {
    /// Where the axis starts, in hertz.
    public let lowestFrequency: Double

    /// - Parameter lowestFrequency: where the axis starts; a value that is not positive is
    ///   taken as 20 Hz, the lower edge of hearing.
    public init(lowestFrequency: Double = 20) {
        self.lowestFrequency = lowestFrequency > 0 && lowestFrequency.isFinite ? lowestFrequency : 20
    }

    /// The position in octaves above 1 Hz.
    public func position(of hertz: Double) -> Double { log2(max(hertz, lowestFrequency)) }
    public func frequency(at position: Double) -> Double { exp2(position) }
}

/// Frequencies evenly spaced in mels, by a mel formula of the core (§6.11).
public struct MelFrequencyScale<Formula: MelFormula>: FrequencyScale {
    /// The formula that turns hertz into mels and back.
    public let formula: Formula

    public init(formula: Formula) {
        self.formula = formula
    }

    public func position(of hertz: Double) -> Double { formula.mel(fromHertz: max(hertz, 0)) }
    public func frequency(at position: Double) -> Double { formula.hertz(fromMel: position) }
}

extension FrequencyScale where Self == LinearFrequencyScale {
    /// Evenly spaced in hertz. The default.
    public static var linear: LinearFrequencyScale { LinearFrequencyScale() }
}

extension FrequencyScale where Self == LogarithmicFrequencyScale {
    /// Evenly spaced in octaves, from 20 Hz.
    public static var logarithmic: LogarithmicFrequencyScale { LogarithmicFrequencyScale() }

    /// Evenly spaced in octaves, from `lowestFrequency`.
    public static func logarithmic(from lowestFrequency: Double) -> LogarithmicFrequencyScale {
        LogarithmicFrequencyScale(lowestFrequency: lowestFrequency)
    }
}

extension FrequencyScale where Self == MelFrequencyScale<SlaneyMelFormula> {
    /// Evenly spaced in mels, by Slaney's formula.
    public static var mel: MelFrequencyScale<SlaneyMelFormula> { MelFrequencyScale(formula: SlaneyMelFormula()) }
}

extension FrequencyScale {
    /// Evenly spaced in mels, by `formula`.
    public static func mel<Formula: MelFormula>(_ formula: Formula) -> MelFrequencyScale<Formula> where Self == MelFrequencyScale<Formula> {
        MelFrequencyScale(formula: formula)
    }
}

/// How a heat map fills the space between two rows (§8.1): the pitch classes of a chromagram
/// are cells with hard edges, the bins of a spectrogram blend into one another.
public enum RowInterpolation: Hashable, Sendable {
    /// Linear between neighbouring rows. The default.
    case linear
    /// Each row is a cell of one colour.
    case nearest
}

/// The warp table of a heat map: for evenly spaced positions on the display axis, the row
/// coordinate shown there (row `k` is the number `k`). The fragment shader interpolates
/// between its entries, so any scale, stock or not, is drawn by the same code.
///
/// The table spans the whole axis of the feed; which part of it a view shows is two uniforms,
/// so moving or animating the visible range builds no table.
struct WarpTable: Hashable, Sendable {
    /// Entries in a table. A logarithmic axis over ten octaves is then exact to a thousandth
    /// of a row for two thousand rows.
    static let size = 4_096

    /// What the table's axis counts in.
    enum Axis: Hashable, Sendable {
        /// Rows drawn bin for bin: positions are rows, from 0 to the row count.
        case rows
        /// Rows evenly spaced in hertz, laid out by a scale: positions are the scale's, from
        /// the first to the second.
        case scaled(Double, Double)
        /// Rows evenly spaced in hertz on an axis that is linear in hertz, up to the Nyquist
        /// frequency given: what a scale that cannot order the axis falls back to.
        case hertz(Double)
    }

    /// The row coordinate at each entry.
    let rows: [Float]
    let rowCount: Int
    let axis: Axis

    /// The table for rows drawn bin for bin: every row is a cell of the same height, and row
    /// `k` has its centre at `k`.
    init(rowCount: Int) {
        let count = max(rowCount, 1)
        self.rowCount = count
        axis = .rows
        rows = (0 ..< Self.size).map { Float(Double($0) / Double(Self.size - 1) * Double(count) - 0.5) }
    }

    /// The table for `rowCount` rows evenly spaced in hertz from 0 to `nyquist`, laid out by
    /// `scale`. A scale that does not put the top of the axis above its bottom is replaced by
    /// the linear one.
    init(rowCount: Int, nyquist: Double, scale: some FrequencyScale) {
        let count = max(rowCount, 1)
        self.rowCount = count
        let low = scale.position(of: 0), high = scale.position(of: nyquist)
        guard count > 1, nyquist > 0, low.isFinite, high.isFinite, high > low else {
            axis = .hertz(max(nyquist, 0))
            rows = (0 ..< Self.size).map { Float(Double($0) / Double(Self.size - 1) * Double(count - 1)) }
            return
        }
        axis = .scaled(low, high)
        let spacing = nyquist / Double(count - 1)
        rows = (0 ..< Self.size).map { entry in
            let row = scale.frequency(at: low + Double(entry) / Double(Self.size - 1) * (high - low)) / spacing
            return Float(row.isNaN ? 0 : min(max(row, 0), Double(count - 1)))
        }
    }

    /// Where a visible stretch of the axis begins and ends on the table, each from 0 to 1.
    ///
    /// - Parameters:
    ///   - frequencies: for rows evenly spaced in hertz, the frequencies at the bottom and at
    ///     the top edge of the view.
    ///   - rows: for rows drawn bin for bin, the row positions at the two edges, from 0 (the
    ///     lower edge of row 0) to the row count.
    ///   - scale: the scale the table was built with.
    ///
    /// No stretch, or one that is empty or not a number, gives the whole axis.
    func span(frequencies: ClosedRange<Double>?, rows: ClosedRange<Double>?, scale: some FrequencyScale) -> ClosedRange<Float> {
        var low = 0.0, high = 1.0
        switch axis {
        case .rows:
            if let rows {
                low = rows.lowerBound / Double(rowCount)
                high = rows.upperBound / Double(rowCount)
            }
        case .scaled(let first, let last):
            if let frequencies {
                low = (scale.position(of: frequencies.lowerBound) - first) / (last - first)
                high = (scale.position(of: frequencies.upperBound) - first) / (last - first)
            }
        case .hertz(let nyquist):
            if let frequencies, nyquist > 0 {
                low = frequencies.lowerBound / nyquist
                high = frequencies.upperBound / nyquist
            }
        }
        guard low.isFinite, high.isFinite else { return 0 ... 1 }
        low = min(max(low, 0), 1)
        high = min(max(high, 0), 1)
        return high > low ? Float(low) ... Float(high) : 0 ... 1
    }
}
