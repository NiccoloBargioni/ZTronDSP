import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// `FrequencyScale` and the warp table a heat map draws it with (WP-605).
@Suite("Frequency scales")
struct FrequencyScaleTests {
    /// A scale written outside the package: evenly spaced in the square root of the frequency.
    struct SquareRootScale: FrequencyScale {
        func position(of hertz: Double) -> Double { max(hertz, 0).squareRoot() }
        func frequency(at position: Double) -> Double { position * position }
    }

    /// Scales that cannot lay out an axis.
    struct FlatScale: FrequencyScale {
        func position(of hertz: Double) -> Double { 1 }
        func frequency(at position: Double) -> Double { 1 }
    }

    struct FallingScale: FrequencyScale {
        func position(of hertz: Double) -> Double { -hertz }
        func frequency(at position: Double) -> Double { -position }
    }

    struct BrokenScale: FrequencyScale {
        func position(of hertz: Double) -> Double { hertz == 0 ? .nan : hertz }
        func frequency(at position: Double) -> Double { .nan }
    }

    /// The row the shader reads at `unit` of the visible stretch: the table, linear between
    /// its entries.
    private func row(_ table: WarpTable, at unit: Double, span: ClosedRange<Float> = 0 ... 1) -> Double {
        let position = Double(span.lowerBound) + unit * Double(span.upperBound - span.lowerBound)
        let scaled = min(max(position, 0), 1) * Double(WarpTable.size - 1)
        let index = min(Int(scaled), WarpTable.size - 2)
        return Double(table.rows[index]) + Double(table.rows[index + 1] - table.rows[index]) * (scaled - Double(index))
    }

    @Test func theStockScalesPlaceFrequenciesAndInvertThemselves() {
        let frequencies: [Double] = [20, 55, 440, 999.9, 1_000, 1_000.1, 4_186, 12_000, 24_000]
        func roundTrips(_ scale: some FrequencyScale) -> Bool {
            frequencies.allSatisfy { abs(scale.frequency(at: scale.position(of: $0)) - $0) <= 1e-9 * $0 }
        }
        func rises(_ scale: some FrequencyScale) -> Bool {
            zip(frequencies, frequencies.dropFirst()).allSatisfy { scale.position(of: $0) < scale.position(of: $1) }
        }
        #expect(roundTrips(LinearFrequencyScale()) && roundTrips(LogarithmicFrequencyScale()) && roundTrips(MelFrequencyScale(formula: SlaneyMelFormula())))
        #expect(roundTrips(MelFrequencyScale(formula: HTKMelFormula())) && roundTrips(SquareRootScale()))
        #expect(rises(LinearFrequencyScale()) && rises(LogarithmicFrequencyScale()) && rises(MelFrequencyScale(formula: SlaneyMelFormula())) && rises(MelFrequencyScale(formula: HTKMelFormula())))

        #expect(LinearFrequencyScale().position(of: 440) == 440 && LinearFrequencyScale().frequency(at: 440) == 440)
        // Octaves above 1 Hz, from 20 Hz: an axis in octaves cannot reach 0 Hz.
        let octaves = LogarithmicFrequencyScale()
        #expect(octaves.lowestFrequency == 20 && octaves.position(of: 1_024) == 10 && octaves.frequency(at: 10) == 1_024)
        #expect(octaves.position(of: 0) == log2(20) && octaves.position(of: 5) == octaves.position(of: 20) && octaves.position(of: -3) == log2(20))
        #expect(LogarithmicFrequencyScale(lowestFrequency: 100).position(of: 50) == log2(100))
        for none in [0, -5, Double.nan, .infinity] { #expect(LogarithmicFrequencyScale(lowestFrequency: none).lowestFrequency == 20, "\(none) is no start of an axis") }
        // Mels: 1 000 Hz is 15 mel by Slaney's formula; the HTK formula is another scale.
        #expect(abs(MelFrequencyScale(formula: SlaneyMelFormula()).position(of: 1_000) - 15) < 1e-12)
        #expect(MelFrequencyScale(formula: SlaneyMelFormula()).position(of: -10) == 0, "nothing below 0 Hz")
        #expect(abs(MelFrequencyScale(formula: HTKMelFormula()).position(of: 700) - 2_595 * log10(2)) < 1e-9)
    }

    @Test func theStockValuesAreStrategiesOfTheirOwnTypes() {
        func key(_ scale: some FrequencyScale) -> AnyStrategy { AnyStrategy(scale) }
        #expect(key(.linear) == key(LinearFrequencyScale()) && key(.logarithmic) == key(LogarithmicFrequencyScale(lowestFrequency: 20)))
        #expect(key(.logarithmic(from: 50)) == key(LogarithmicFrequencyScale(lowestFrequency: 50)) && key(.logarithmic(from: 50)) != key(.logarithmic))
        #expect(key(.mel) == key(MelFrequencyScale(formula: SlaneyMelFormula())) && key(.mel(.htk)) == key(MelFrequencyScale(formula: HTKMelFormula())))
        #expect(key(.mel) != key(.mel(.htk)) && key(.mel(.slaney)) == key(.mel) && key(.linear) != key(.logarithmic))
        #expect(Set([RowInterpolation.linear, .nearest]).count == 2)
    }

    /// The table against the scale it stands for: what the shader reads between two entries is
    /// within a thousandth of a row of the exact position.
    @Test func theWarpTableFollowsTheScaleToAThousandthOfARow() {
        let nyquist = 24_000.0
        func worst(_ scale: some FrequencyScale, rows: Int) -> Double {
            let table = WarpTable(rowCount: rows, nyquist: nyquist, scale: scale)
            let low = scale.position(of: 0), high = scale.position(of: nyquist)
            var worst = 0.0
            for step in 0 ... 20_000 {
                let unit = Double(step) / 20_000
                let exact = min(max(scale.frequency(at: low + unit * (high - low)) / (nyquist / Double(rows - 1)), 0), Double(rows - 1))
                worst = max(worst, abs(row(table, at: unit) - exact))
            }
            return worst
        }
        var report: [String] = []
        for rows in [257, 1_025, 2_049] {
            let figures = [("linear", worst(LinearFrequencyScale(), rows: rows)), ("logarithmic", worst(LogarithmicFrequencyScale(), rows: rows)),
                           ("mel", worst(MelFrequencyScale(formula: SlaneyMelFormula()), rows: rows)), ("mel (HTK)", worst(MelFrequencyScale(formula: HTKMelFormula()), rows: rows)),
                           ("square root", worst(SquareRootScale(), rows: rows))]
            for (name, error) in figures {
                #expect(error < 1e-3, "\(name), \(rows) rows: off by \(error) rows")
                report.append("\(name) \(rows): \(String(format: "%.2e", error))")
            }
        }
        print("warp table, largest deviation in rows: \(report.joined(separator: "; "))")
    }

    @Test func aTableSpansTheWholeAxisOfTheFeed() {
        let linear = WarpTable(rowCount: 1_025, nyquist: 24_000, scale: LinearFrequencyScale())
        #expect(linear.rows.count == WarpTable.size && linear.rows.first == 0 && linear.rows.last == 1_024 && linear.rowCount == 1_025)
        #expect(linear.axis == .scaled(0, 24_000))
        let octaves = WarpTable(rowCount: 1_025, nyquist: 24_000, scale: LogarithmicFrequencyScale())
        #expect(octaves.axis == .scaled(log2(20), log2(24_000)))
        expectClose(octaves.rows[0], Float(20 / (24_000.0 / 1_024)), .relative(1e-6), "the axis starts at 20 Hz, between rows 0 and 1")
        #expect(octaves.rows.last == 1_024 && zip(octaves.rows, octaves.rows.dropFirst()).allSatisfy { $0 <= $1 }, "rising to the last row")
        // Halfway up a logarithmic axis lies the geometric mean of its ends.
        expectClose(row(octaves, at: 0.5), (20.0 * 24_000).squareRoot() / (24_000.0 / 1_024), .relative(1e-5))
        // A scale of one's own is a table like any other.
        let root = WarpTable(rowCount: 101, nyquist: 10_000, scale: SquareRootScale())
        expectClose(row(root, at: 0.5), 25.0, .absolute(1e-3), "half the square root is a quarter of the frequency")
    }

    @Test func rowsThatAreNotFrequenciesAreCellsOfEqualHeight() {
        let cells = WarpTable(rowCount: 12)
        #expect(cells.axis == .rows && cells.rowCount == 12 && cells.rows.first == -0.5 && cells.rows.last == 11.5)
        // The middle of cell k is the row coordinate k.
        for cell in 0 ..< 12 { expectClose(row(cells, at: (Double(cell) + 0.5) / 12), Double(cell), .absolute(1e-3)) }
        // Whatever the scale: only rows evenly spaced in hertz are warped (VC-5).
        #expect(WarpTable(axis: .pitchClasses, rowCount: 12, scale: LogarithmicFrequencyScale()) == cells)
        #expect(WarpTable(axis: nil, rowCount: 12, scale: MelFrequencyScale(formula: SlaneyMelFormula())) == cells)
        #expect(WarpTable(axis: .mel(centers: [100, 200, 300]), rowCount: 3, scale: LogarithmicFrequencyScale()).axis == .rows)
        #expect(WarpTable(axis: .linearFrequency(binCount: 12, nyquist: 8_000), rowCount: 12, scale: LogarithmicFrequencyScale())
            == WarpTable(rowCount: 12, nyquist: 8_000, scale: LogarithmicFrequencyScale()))
        #expect(WarpTable(rowCount: 0).rowCount == 1, "no row at all is laid out as one")
    }

    @Test func aScaleThatCannotOrderTheAxisIsReplacedByTheLinearOne() {
        let linear = WarpTable(rowCount: 65, nyquist: 8_000, scale: LinearFrequencyScale())
        for (name, table) in [("flat", WarpTable(rowCount: 65, nyquist: 8_000, scale: FlatScale())), ("falling", WarpTable(rowCount: 65, nyquist: 8_000, scale: FallingScale())),
                              ("not a number", WarpTable(rowCount: 65, nyquist: 8_000, scale: BrokenScale()))] {
            #expect(table.axis == .hertz(8_000), "\(name)")
            #expect(table.rows == linear.rows, "\(name): the rows of the linear axis")
            // A visible band is then read in hertz.
            #expect(table.span(frequencies: 2_000 ... 6_000, rows: nil, scale: FlatScale()) == 0.25 ... 0.75, "\(name)")
            #expect(table.span(frequencies: nil, rows: 1 ... 2, scale: FlatScale()) == 0 ... 1, "\(name): a row range means nothing to frequencies")
        }
        // One row, or no Nyquist frequency: nothing to lay out.
        let single = WarpTable(rowCount: 1, nyquist: 8_000, scale: LogarithmicFrequencyScale())
        #expect(single.axis == .hertz(8_000) && single.rows.allSatisfy { $0 == 0 })
        let nowhere = WarpTable(rowCount: 9, nyquist: 0, scale: LinearFrequencyScale())
        #expect(nowhere.axis == .hertz(0) && nowhere.span(frequencies: 1 ... 2, rows: nil, scale: LinearFrequencyScale()) == 0 ... 1)
        #expect(WarpTable(rowCount: 9, nyquist: -5, scale: LinearFrequencyScale()).axis == .hertz(0))
    }

    @Test func aVisibleStretchIsTwoPositionsOnTheTable() {
        let linearScale = LinearFrequencyScale(), octaveScale = LogarithmicFrequencyScale()
        let linear = WarpTable(rowCount: 1_025, nyquist: 24_000, scale: linearScale)
        #expect(linear.span(frequencies: nil, rows: nil, scale: linearScale) == 0 ... 1, "nothing asked: the whole axis")
        #expect(linear.span(frequencies: 6_000 ... 18_000, rows: nil, scale: linearScale) == 0.25 ... 0.75)
        #expect(linear.span(frequencies: -100 ... 48_000, rows: nil, scale: linearScale) == 0 ... 1, "clamped to the axis")
        #expect(linear.span(frequencies: 5_000 ... 5_000, rows: nil, scale: linearScale) == 0 ... 1, "a band of no width shows everything")
        #expect(linear.span(frequencies: 30_000 ... 40_000, rows: nil, scale: linearScale) == 0 ... 1, "a band above the axis shows everything")
        #expect(linear.span(frequencies: nil, rows: 3 ... 9, scale: linearScale) == 0 ... 1, "rows are not what a frequency axis is cut by")

        let octaves = WarpTable(rowCount: 1_025, nyquist: 24_000, scale: octaveScale)
        let whole = log2(24_000.0 / 20)
        let band = octaves.span(frequencies: 200 ... 2_000, rows: nil, scale: octaveScale)
        expectClose(band.lowerBound, Float(log2(10.0) / whole), .relative(1e-6))
        expectClose(band.upperBound, Float(log2(100.0) / whole), .relative(1e-6))
        #expect(octaves.span(frequencies: 0 ... 24_000, rows: nil, scale: octaveScale) == 0 ... 1, "below 20 Hz is where the axis starts")
        // The band's ends are where the table says they are.
        expectClose(row(octaves, at: 0, span: band), 200 / (24_000.0 / 1_024), .relative(1e-4))
        expectClose(row(octaves, at: 1, span: band), 2_000 / (24_000.0 / 1_024), .relative(1e-4))

        let cells = WarpTable(rowCount: 12)
        #expect(cells.span(frequencies: nil, rows: 3 ... 6, scale: linearScale) == 0.25 ... 0.5)
        #expect(cells.span(frequencies: 100 ... 200, rows: nil, scale: linearScale) == 0 ... 1, "hertz are not what cells are cut by")
        #expect(cells.span(frequencies: nil, rows: -4 ... 40, scale: linearScale) == 0 ... 1 && cells.span(frequencies: nil, rows: 5 ... 5, scale: linearScale) == 0 ... 1)
        #expect(cells.span(frequencies: nil, rows: 0 ... .infinity, scale: linearScale) == 0 ... 1, "not a finite stretch: everything")
    }
}
