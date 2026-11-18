import ExtensionGuide
import SwiftUI
import ZTronDSP
import ZTronDSPUI

// The extension guide, row 11 of §5.11.1: a display (Docs/ExtensionGuide.md).

// snippet:begin spectrogram-view
/// A spectrogram whose every column is scaled to its own peak: the shape of the spectrum over
/// time, whatever the level. A stock heat map on a feed that a pipeline of the app's own
/// writes; the pipeline ends in a step written outside the package.
///
/// Threading: main actor, like every view. The view stores the source and the feed and
/// nothing of their contents, so its body depends on no per-frame data, and it is `Equatable`
/// by what it shows (V-1). Keep the source and the feed in state or in a model, not in a
/// `body`.
public struct NormalizedSpectrogram: View, Equatable {
    private let source: any SampleSource
    private let feed: HeatmapFeed

    /// A spectrogram of `source`, drawn from `feed`. Main actor.
    public init(source: any SampleSource, feed: HeatmapFeed) {
        self.source = source
        self.feed = feed
    }

    /// The analysis behind the view: built in a function of its sink, so that one description
    /// serves several sources, each with a feed of its own (ATT-5). Usable on any thread.
    nonisolated public static func analysis(into feed: HeatmapFeed) -> Pipeline<Samples, Samples> {
        Pipeline().tap { $0.stft(frame: 1_024, hop: 256).magnitude().peakNormalized().emit(to: feed) }
    }

    public var body: some View {
        HeatmapView(feed: feed)
            .valueRange(0 ... 1)
            .timeSpan(4)
            .colorMap(.magma)
            .axis(.frequency)
            // The view hosts the pipeline: attached while the view is in the hierarchy, detached when it leaves.
            .pipeline(NormalizedSpectrogram.analysis(into: feed), on: source)
    }

    /// Two views are equal when they show the same source object through the same feed
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: NormalizedSpectrogram, rhs: NormalizedSpectrogram) -> Bool {
        lhs.source === rhs.source && lhs.feed === rhs.feed
    }
}
// snippet:end spectrogram-view
