import ExtensionGuide
import ExtensionGuideUI
import ExternalTestSupport
import Foundation
import SwiftUI
import Testing
import ZTronDSP
import ZTronDSPTesting
import ZTronDSPUI

// WP-908, row 11 of §5.11.1: a display. The view is a stock heat map on a feed that a pipeline
// of the app's own writes. The tests build the view, and run the analysis behind it on an
// engine; they do not put the view on a screen (hosting a view in a test needs UIKit, which
// the suite does not import).

@Suite("Guide 11: a display")
struct DisplayExampleTests {
    /// A second of silence between two seconds of a tone that sweeps.
    let signal = TestSignal.chirp(from: 200, to: 8_000, sampleRate: 48_000, count: 24_000, amplitude: 0.4)
        + TestSignal.silence(count: 12_000)
        + TestSignal.chirp(from: 8_000, to: 200, sampleRate: 48_000, count: 24_000, amplitude: 0.02)

    @MainActor
    @Test func theViewIsBuiltFromItsSourceAndItsFeed() throws {
        let feed = HeatmapFeed(history: 256)
        let source = BufferSource(signal, sampleRate: 48_000)
        let view = NormalizedSpectrogram(source: source, feed: feed)
        // The body is the stock heat map with its appearance and the hosted pipeline: evaluating
        // it reads nothing from the feed (V-1), and the feed stays unclaimed until a host attaches.
        _ = view.body
        _ = VStack { view }
        #expect(feed.columnCount == 0 && !feed.isLive)
        // V-1: the view is equatable by what it shows, the source and the feed as objects.
        let other = HeatmapFeed(history: 256)
        #expect(view == NormalizedSpectrogram(source: source, feed: feed))
        #expect(view != NormalizedSpectrogram(source: source, feed: other))
        #expect(view != NormalizedSpectrogram(source: BufferSource(signal, sampleRate: 48_000), feed: feed))
        // One description serves several sources, each with a feed of its own (ATT-5).
        #expect(NormalizedSpectrogram.analysis(into: feed) == NormalizedSpectrogram.analysis(into: feed))
        #expect(NormalizedSpectrogram.analysis(into: feed) != NormalizedSpectrogram.analysis(into: other))
    }

    @Test func theAnalysisBehindItFillsTheFeedWithColumnsThatPeakAtOne() async throws {
        let feed = HeatmapFeed(history: 512)
        let engine = DSPEngine(blockSize: 512)
        let session = try await engine.attach(NormalizedSpectrogram.analysis(into: feed), to: BufferSource(signal, sampleRate: 48_000))
        try session.start()
        try #require(await session.reaches(.finished))
        let snapshot = feed.snapshot()
        session.detach()
        // A frame of 1 024 samples every 256: 513 rows, one column per frame.
        #expect(snapshot.rowCount == 513 && snapshot.columnCount == (signal.count - 1_024) / 256 + 1, "\(snapshot.rowCount) rows, \(snapshot.columnCount) columns")
        var loud = 0, silent = 0, other = 0
        for column in 0 ..< snapshot.columnCount {
            let values = snapshot.column(column)
            let peak = values.max() ?? -1, least = values.min() ?? -1
            if abs(peak - 1) <= 1.0e-6 && least >= 0 {
                loud += 1
            } else if peak == 0 && least == 0 {
                silent += 1
            } else {
                other += 1
            }
        }
        // Whatever the level of the sweep, 0.4 or 0.02, its columns fill the value range 0 … 1 of
        // the view; the columns of the silence in between are zeros.
        #expect(other == 0 && silent >= 30 && loud >= 180, "\(loud) columns peak at 1, \(silent) are silent, \(other) are neither")
    }
}
