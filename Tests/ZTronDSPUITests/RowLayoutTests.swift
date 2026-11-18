import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// Where the values of a feed's axis sit among its rows and on the height of a view: what
/// labels, pinches and `.frequencyRange` all go through (VC-5).
@Suite("Row layout")
struct RowLayoutTests {
    static let mel = FeedAxis.mel(centers: [100, 200, 400, 800, 1_600])
    static let constantQ = FeedAxis.constantQ(minimumFrequency: 55, binsPerOctave: 12, binCount: 36)
    static let tempo = FeedAxis.tempo(beatsPerMinute: [60, 80, 100, 120, 140, 160, 180, 200])
    static let linear = FeedAxis.linearFrequency(binCount: 513, nyquist: 24_000)

    // MARK: Values and row positions

    @Test(arguments: [mel, constantQ, tempo, FeedAxis.pitchClasses, .lags(count: 64, sampleRate: 100), .quefrency(count: 32, sampleRate: 48_000),
                      .indices(count: 20), linear, .tempo(beatsPerMinute: [240, 180, 120, 90, 60])])
    func everyRowHasItsCentreHalfARowAboveItsLowerEdge(axis: FeedAxis) {
        let mapping = RowAxisMapping(axis: axis)
        for row in 0 ..< axis.rowCount {
            let value = axis.value(ofRow: row)
            expectClose(mapping.position(of: value), Double(row) + 0.5, .absolute(1e-9), "row \(row) of \(axis)")
            expectClose(mapping.value(at: Double(row) + 0.5), value, .relative(1e-12), "row \(row) of \(axis)")
        }
    }

    @Test(arguments: [mel, constantQ, tempo, FeedAxis.lags(count: 64, sampleRate: 100), .indices(count: 20), linear,
                      .tempo(beatsPerMinute: [240, 180, 120, 90, 60])])
    func positionAndValueInvertEachOtherBetweenAndBeyondTheRows(axis: FeedAxis) {
        let mapping = RowAxisMapping(axis: axis)
        for step in -4 ... 4 * axis.rowCount + 4 {
            let position = Double(step) / 4
            expectClose(mapping.position(of: mapping.value(at: position)), position, .absolute(1e-9), "position \(position) of \(axis)")
        }
    }

    @Test func aMelAxisIsInterpolatedBetweenItsCentresAndContinuedBeyondThem() {
        let mapping = RowAxisMapping(axis: Self.mel)
        #expect(mapping.position(of: 150) == 1.0, "half way between the first two centres")
        #expect(mapping.position(of: 600) == 3.0)
        #expect(mapping.position(of: 50) == 0.0, "the lower edge of the first row continues the first spacing")
        #expect(mapping.value(at: 0) == 50 && mapping.value(at: 5) == 2_000)
        #expect(mapping.fullRange == 50 ... 2_000)
        #expect(mapping.rows(for: 150 ... 600) == 1.0 ... 3.0)
        #expect(mapping.rows(for: 0 ... 100_000) == 0.0 ... 5.0, "kept inside the axis")
        #expect(mapping.rows(for: 5_000 ... 9_000) == nil, "a range that covers no row")
    }

    @Test func aConstantQAxisIsEvenInOctaves() {
        let mapping = RowAxisMapping(axis: Self.constantQ)
        expectClose(mapping.position(of: 110), 12.5, .absolute(1e-9), "an octave is twelve rows")
        expectClose(mapping.value(at: 24.5), 220, .relative(1e-12))
        #expect(mapping.position(of: 0) == 0 && mapping.position(of: -5) == 0, "no row below the axis")
        expectClose(mapping.fullRange.lowerBound, 55 * exp2(-0.5 / 12), .relative(1e-12))
        expectClose(mapping.fullRange.upperBound, 55 * exp2(35.5 / 12), .relative(1e-12))
    }

    @Test func aFallingAxisGivesRangesInRisingOrder() {
        // The rows of an autocorrelation tempogram: longer lags are slower tempi.
        let mapping = RowAxisMapping(axis: .tempo(beatsPerMinute: [240, 180, 120, 90, 60]))
        #expect(mapping.position(of: 240) == 0.5 && mapping.position(of: 60) == 4.5 && mapping.position(of: 150) == 2.0)
        #expect(mapping.fullRange.lowerBound < mapping.fullRange.upperBound)
        #expect(mapping.rows(for: 90 ... 180) == 1.5 ... 3.5)
    }

    @Test func degenerateAxesDoNotTrap() {
        #expect(RowAxisMapping(axis: .mel(centers: [])).position(of: 5) == 0)
        #expect(RowAxisMapping(axis: .mel(centers: [])).value(at: 3) == 0)
        #expect(RowAxisMapping(axis: .mel(centers: [])).rows(for: 0 ... 1) == nil)
        #expect(RowAxisMapping(axis: .mel(centers: [440])).position(of: 440) == 0.5)
        #expect(RowAxisMapping(axis: .mel(centers: [440])).value(at: 0.5) == 440)
        #expect(RowAxisMapping(axis: .tempo(beatsPerMinute: [120, 120])).position(of: 130) == 10.5)
        #expect(RowAxisMapping(axis: .tempo(beatsPerMinute: [100, 100, 120])).position(of: 100) == 1.5, "rows of one value")
        #expect(RowAxisMapping(axis: .lags(count: 8, sampleRate: 0)).position(of: 2) == 0.5)
        #expect(RowAxisMapping(axis: .lags(count: 8, sampleRate: 0)).value(at: 2) == 0)
        #expect(RowAxisMapping(axis: .linearFrequency(binCount: 1, nyquist: 24_000)).position(of: 100) == 0.5)
        #expect(RowAxisMapping(axis: .linearFrequency(binCount: 1, nyquist: 24_000)).value(at: 3) == 0)
        #expect(RowAxisMapping(axis: .constantQ(minimumFrequency: 55, binsPerOctave: 0, binCount: 4)).position(of: 110) == 1.5)
        #expect(ClosedRange.ordered(Double.nan, 1) == nil && ClosedRange.ordered(3.0, 1) == 1 ... 3, "bounds in either order; no range of no number")
        #expect(RowAxisMapping(axis: Self.linear).fullRange == 0 ... 24_000)
        #expect(RowAxisMapping(axis: .tempo(beatsPerMinute: [100, 100, 120])).position(of: 90) == 0.5, "below rows of one value")
        // Rows whose values are no numbers have no range to show: nothing traps, nothing is shown.
        let nonsense = FeedAxis.mel(centers: [.nan, .nan])
        #expect(RowAxisMapping(axis: nonsense).fullRange == 0 ... 0)
        let layout = RowLayout(axis: nonsense, scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        #expect(layout.visibleRange == 0 ... 0 && layout.visibleCoordinates == 0 ... 2)
        // An axis that has no end has no coordinates to lay out.
        let endless = RowLayout(axis: .linearFrequency(binCount: 8, nyquist: .infinity), scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        #expect(endless.fullCoordinates == 0 ... 0)
    }

    // MARK: Fractions of the height

    @Test func rowsEvenlySpacedInHertzAreLaidOutByTheScale() {
        let linear = RowLayout(axis: Self.linear, scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        #expect(linear.fraction(of: 0) == 0 && linear.fraction(of: 24_000) == 1 && linear.fraction(of: 6_000) == 0.25)
        #expect(linear.value(atFraction: 0.5) == 12_000 && linear.visibleRange == 0 ... 24_000)

        let logarithmic = RowLayout(axis: Self.linear, scale: AnyFrequencyScale(LogarithmicFrequencyScale(lowestFrequency: 20)), range: 100 ... 6_400)
        #expect(logarithmic.fraction(of: 100) == 0)
        expectClose(logarithmic.fraction(of: 6_400), 1, .absolute(1e-12))
        expectClose(logarithmic.fraction(of: 800), 0.5, .absolute(1e-12), "three of six octaves")
        expectClose(logarithmic.value(atFraction: 0.5), 800, .relative(1e-12))
        expectClose(logarithmic.fraction(of: 12_800), 7.0 / 6, .absolute(1e-12), "above the top edge")

        let mel = RowLayout(axis: Self.linear, scale: AnyFrequencyScale(MelFrequencyScale(formula: SlaneyMelFormula())), range: nil)
        #expect(mel.fraction(of: 0) == 0)
        expectClose(mel.fraction(of: 24_000), 1, .absolute(1e-12))
        #expect(mel.fraction(of: 1_000) > linear.fraction(of: 1_000), "a mel axis gives the low frequencies more room")
    }

    /// The fractions are the ones the renderer draws: a range kept inside the axis, and the
    /// whole axis for a range that covers nothing.
    @Test func theVisibleRangeIsKeptInsideTheAxis() {
        let scale = AnyFrequencyScale(LinearFrequencyScale())
        #expect(RowLayout(axis: Self.linear, scale: scale, range: -500 ... 48_000).visibleRange == 0 ... 24_000)
        #expect(RowLayout(axis: Self.linear, scale: scale, range: 30_000 ... 40_000).visibleRange == 0 ... 24_000, "nothing of the axis: the whole of it")
        #expect(RowLayout(axis: Self.linear, scale: scale, range: 1_000 ... 1_000).visibleRange == 0 ... 24_000)
        #expect(RowLayout(axis: Self.linear, scale: scale, range: 2_000 ... 6_000).fraction(of: 3_000) == 0.25)
    }

    @Test func otherAxesAreDrawnBinForBinWhateverTheScale() {
        for scale in [AnyFrequencyScale(LinearFrequencyScale()), AnyFrequencyScale(LogarithmicFrequencyScale())] {
            let layout = RowLayout(axis: Self.mel, scale: scale, range: nil)
            // Five rows of equal height: the centre of row k sits at (k + 0.5) / 5.
            for (row, center) in [100.0, 200, 400, 800, 1_600].enumerated() {
                expectClose(layout.fraction(of: center), (Double(row) + 0.5) / 5, .absolute(1e-12))
            }
            #expect(layout.visibleCoordinates == 0 ... 5 && layout.fullCoordinates == 0 ... 5)
        }
        let chroma = RowLayout(axis: .pitchClasses, scale: AnyFrequencyScale(LogarithmicFrequencyScale()), range: nil)
        #expect(chroma.fraction(of: 0) == 0.5 / 12 && chroma.fraction(of: 11) == 11.5 / 12)
        let zoomed = RowLayout(axis: Self.tempo, scale: AnyFrequencyScale(LinearFrequencyScale()), range: 110 ... 130)
        #expect(zoomed.visibleCoordinates == 3.0 ... 4.0 && zoomed.fraction(of: 120) == 0.5 && zoomed.visibleRange == 110 ... 130)
        #expect(zoomed.value(atFraction: 0.25) == 115)
    }

    /// A scale that does not put the top of the axis above its bottom is replaced by the
    /// linear one, as the renderer does.
    @Test func aScaleThatCannotOrderTheAxisFallsBackToHertz() {
        struct Flat: FrequencyScale {
            func position(of hertz: Double) -> Double { 7 }
            func frequency(at position: Double) -> Double { 0 }
        }
        let layout = RowLayout(axis: Self.linear, scale: AnyFrequencyScale(Flat()), range: nil)
        #expect(layout.fraction(of: 12_000) == 0.5 && layout.value(atFraction: 0.25) == 6_000)
        #expect(layout.coordinate(of: 300) == 300 && layout.value(atCoordinate: 300) == 300)
        let single = RowLayout(axis: .linearFrequency(binCount: 1, nyquist: 0), scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        #expect(single.fraction(of: 5) == 0, "an axis of no height")
    }

    // MARK: The picture agrees with the layout (WP-803b)

    /// A feed whose rows are mel bands or constant-Q bins is drawn bin for bin: a single loud
    /// row is shown exactly where the layout puts that row's value, whatever scale is set.
    @Test(arguments: [mel, constantQ, tempo])
    @MainActor
    func aLoudRowIsDrawnWhereTheLayoutPutsItsValue(axis: FeedAxis) async throws {
        let rows = axis.rowCount, loud = rows / 2
        let column = (0 ..< rows).map { $0 == loud ? Float(0) : Float(-90) }
        let feed = HeatmapFeed(history: 2)
        try FeedWriter.append(column + column, rows: rows, axis: axis, to: feed)
        await mainQueueDrained()
        var appearance = HeatmapAppearance()
        appearance.rowInterpolation = .nearest
        appearance.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale())
        let height = rows * 8
        let stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 4, height: CGFloat(height)))
        stage.settle()
        let picture = try stage.surface.pixels()
        let layout = RowLayout(axis: axis, scale: appearance.frequencyScale, range: nil)
        let fraction = layout.fraction(of: axis.value(ofRow: loud))
        // The picture's rows count from the top.
        let y = height - 1 - Int(fraction * Double(height))
        let quiet = picture.pixel(x: 2, y: height - 1)
        #expect(picture.pixel(x: 2, y: y) != quiet, "the loud row is at the fraction the layout gives")
        #expect(picture.pixel(x: 2, y: y - 8) == quiet && picture.pixel(x: 2, y: y + 8) == quiet, "and its neighbours are not")
    }

    /// Rows evenly spaced in hertz are warped by the scale: a loud bin is shown where the
    /// layout puts its frequency on a logarithmic axis.
    @Test @MainActor func aLoudBinOnALogarithmicAxisIsDrawnWhereTheLayoutPutsItsFrequency() async throws {
        let bins = 257, loud = 32
        let axis = FeedAxis.linearFrequency(binCount: bins, nyquist: 24_000)
        let column = (0 ..< bins).map { $0 == loud ? Float(0) : Float(-90) }
        let feed = HeatmapFeed(history: 2)
        try FeedWriter.append(column + column, rows: bins, axis: axis, to: feed)
        await mainQueueDrained()
        var appearance = HeatmapAppearance()
        appearance.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale())
        appearance.rowRange = 100 ... 12_800
        let height = 280
        let stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 4, height: CGFloat(height)))
        stage.settle()
        let picture = try stage.surface.pixels()
        let layout = RowLayout(axis: axis, scale: appearance.frequencyScale, range: appearance.rowRange)
        let frequency = axis.value(ofRow: loud)
        let y = height - 1 - Int(layout.fraction(of: frequency) * Double(height))
        // The brightest row of the picture is the one the layout names, within a pixel.
        let brightest = (0 ..< height).max { picture.pixel(x: 2, y: $0).green < picture.pixel(x: 2, y: $1).green }
        #expect(abs((brightest ?? -1) - y) <= 1, "bin \(loud), \(frequency) Hz, is drawn at row \(String(describing: brightest)), the layout says \(y)")
    }
}
