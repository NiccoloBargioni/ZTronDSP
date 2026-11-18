import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// What tells the components apart (WP-803b, WP-805, WP-806): the picture each one's defaults
/// give, drawn by the coordinator into an off-screen texture.
@MainActor
@Suite("Components")
struct ComponentTests {
    /// The colours of one pixel column of a picture, from the top, without repeats in a row.
    private func runs(_ picture: PixelImage, x: Int) -> [[UInt8]] {
        var runs: [[UInt8]] = []
        for y in 0 ..< picture.height {
            let pixel = picture.pixel(x: x, y: y)
            let colour = [pixel.red, pixel.green, pixel.blue]
            if runs.last != colour { runs.append(colour) }
        }
        return runs
    }

    private func appearance(_ role: HeatmapRole) -> HeatmapAppearance {
        HeatmapSurface.appearance(role: role, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: nil)
    }

    /// WP-805: twelve rows, nearest filtering. Each pitch class is a cell of one colour with
    /// hard edges; the generic heat map blends the same rows into one another.
    @Test func aChromagramHasTwelveCellsWithHardEdges() async throws {
        // One column of chroma: the classes get louder in steps, C the quietest.
        let column = (0 ..< 12).map { Float($0) / 11 }
        let feed = HeatmapFeed(history: 1)
        try FeedWriter.append(column, rows: 12, axis: .pitchClasses, to: feed)
        await mainQueueDrained()
        let size = CGSize(width: 4, height: 120)
        let chroma = try await Stage(.heatmap(feed, appearance(.chromagram)), size: size)
        chroma.settle()
        let cells = runs(try chroma.surface.pixels(), x: 2)
        #expect(cells.count == 12, "twelve colours down the picture, and nothing between them: \(cells.count)")
        // Every cell is ten pixels of one colour: the boundaries sit where the rows meet.
        let picture = try chroma.surface.pixels()
        for row in 0 ..< 12 {
            let top = picture.pixel(x: 2, y: 119 - (row * 10 + 9)), bottom = picture.pixel(x: 2, y: 119 - row * 10)
            #expect(top == bottom, "pitch class \(row) is one colour from edge to edge")
        }
        #expect(picture.pixel(x: 2, y: 119) != picture.pixel(x: 2, y: 0), "C at the bottom, B at the top")

        // The same feed in the generic heat map: rows blended, so far more than twelve colours.
        var generic = appearance(.generic)
        generic.valueRange = 0 ... 1
        let blended = try await Stage(.heatmap(feed, generic), size: size)
        blended.settle()
        #expect(runs(try blended.surface.pixels(), x: 2).count > 24)
    }

    /// WP-806: the rows of a tempogram follow the feed's axis, bin for bin, and the visible
    /// range is given in beats per minute.
    @Test func aTempogramShowsTheRowsTheFeedsAxisNames() async throws {
        let tempi = (0 ..< 20).map { 60.0 + 6 * Double($0) }
        // 120 beats per minute, row 10, is the only tempo with any strength.
        let column = (0 ..< 20).map { $0 == 10 ? Float(1) : Float(0) }
        let feed = HeatmapFeed(history: 1)
        try FeedWriter.append(column, rows: 20, axis: .tempo(beatsPerMinute: tempi), to: feed)
        await mainQueueDrained()
        var appearance = appearance(.tempogram)
        #expect(appearance.valueRange == 0 ... 1)
        var stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 4, height: 200))
        stage.settle()
        let whole = try stage.surface.pixels()
        let layout = RowLayout(axis: .tempo(beatsPerMinute: tempi), scale: appearance.frequencyScale, range: nil)
        #expect(layout.fraction(of: 120) == 10.5 / 20)
        // Viridis runs from a dark violet to a bright yellow: the green channel tells strong from weak.
        func strength(_ picture: PixelImage, at fraction: Double) -> UInt8 {
            picture.pixel(x: 2, y: 199 - Int(fraction * 200)).green
        }
        #expect(strength(whole, at: layout.fraction(of: 120)) > 200, "the strong tempo is drawn where the axis puts 120 beats per minute")
        #expect(strength(whole, at: layout.fraction(of: 90)) < 20 && strength(whole, at: layout.fraction(of: 150)) < 20 && strength(whole, at: 0) < 20)
        // 105 … 135 beats per minute: five rows, the strong one in the middle.
        appearance.rowRange = 105 ... 135
        stage.show(.heatmap(feed, appearance))
        stage.settle()
        let zoomed = try stage.surface.pixels()
        #expect(strength(zoomed, at: 0.5) > 200 && strength(zoomed, at: 0.02) < 20 && strength(zoomed, at: 0.98) < 20)
        #expect(stage.probe.uploads == 1)
    }

    /// WP-803b: a spectrogram lays rows that are evenly spaced in hertz out by its scale, and
    /// draws rows that are mel bands bin for bin whatever the scale says.
    @Test func theFrequencyScaleWarpsLinearRowsAndLeavesBandsAlone() async throws {
        func picture(axis: FeedAxis, scale: AnyFrequencyScale) async throws -> PixelImage {
            let rows = axis.rowCount
            let column = (0 ..< rows).map { $0 == rows / 4 ? Float(0) : Float(-90) }
            let feed = HeatmapFeed(history: 1)
            try FeedWriter.append(column, rows: rows, axis: axis, to: feed)
            await mainQueueDrained()
            var appearance = appearance(.spectrogram)
            appearance.frequencyScale = scale
            let stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 4, height: 256))
            stage.settle()
            return try stage.surface.pixels()
        }
        let linear = AnyFrequencyScale(LinearFrequencyScale()), logarithmic = AnyFrequencyScale(LogarithmicFrequencyScale())
        let bins = FeedAxis.linearFrequency(binCount: 65, nyquist: 24_000)
        let straight = try await picture(axis: bins, scale: linear), warped = try await picture(axis: bins, scale: logarithmic)
        #expect(straight != warped, "rows evenly spaced in hertz are warped")
        let bands = FeedAxis.mel(centers: (0 ..< 64).map { 60 * pow(1.09, Double($0)) })
        let first = try await picture(axis: bands, scale: linear), second = try await picture(axis: bands, scale: logarithmic)
        #expect(first == second, "mel bands are drawn bin for bin")
    }

    /// V-1: a component stores its feed and nothing of its contents, and two views of the
    /// same feed are equal.
    @Test func componentsAreEqualWhenTheyShowTheSameFeed() {
        let feed = HeatmapFeed(), other = HeatmapFeed(), wave = WaveformFeed()
        #expect(HeatmapView(feed: feed) == HeatmapView(feed: feed) && HeatmapView(feed: feed) != HeatmapView(feed: other))
        #expect(SpectrogramView(feed: feed) == SpectrogramView(feed: feed) && SpectrogramView(feed: feed) != SpectrogramView(feed: other))
        #expect(ChromagramView(feed: feed) == ChromagramView(feed: feed) && ChromagramView(feed: feed) != ChromagramView(feed: other))
        #expect(TempogramView(feed: feed) == TempogramView(feed: feed) && TempogramView(feed: feed) != TempogramView(feed: other))
        #expect(WaveformView(feed: wave) == WaveformView(feed: wave) && WaveformView(feed: wave) != WaveformView(feed: WaveformFeed()))
        // A view is as large as a reference to what it shows, a feed or, for the components
        // that take one, a source: there is nothing in it that could change from frame to
        // frame.
        #expect(MemoryLayout<HeatmapView>.size == MemoryLayout<HeatmapFeed>.size)
        #expect(MemoryLayout<SpectrogramView>.size == MemoryLayout<any SampleSource>.size && MemoryLayout<WaveformView>.size == MemoryLayout<any SampleSource>.size)
    }
}
