import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// What a component was given to show (VC-3): a feed the app's own pipeline writes, or a
/// source the component analyses itself.
///
/// An immutable value. The feeds and the sources are `Sendable`; two inputs are equal when
/// they name the same feed object, or the same source object.
enum ComponentInput<Feed: AnyObject & Sendable>: Sendable {
    case feed(Feed)
    case source(any SampleSource)
}

extension ComponentInput: Equatable {
    static func == (lhs: ComponentInput, rhs: ComponentInput) -> Bool {
        switch (lhs, rhs) {
        case (.feed(let left), .feed(let right)): left === right
        case (.source(let left), .source(let right)): left === right
        default: false
        }
    }
}

/// A source, compared by which object it is: what a view watches to learn that it was given
/// another one.
///
/// An immutable value; a source is `Sendable`.
struct SourceReference: Equatable, Sendable {
    let source: any SampleSource

    init(_ source: any SampleSource) {
        self.source = source
    }

    static func == (lhs: SourceReference, rhs: SourceReference) -> Bool {
        lhs.source === rhs.source
    }
}

/// The feed a source-fed component owns, with the source it is the picture of. The two
/// change together: the picture of one source is never continued with another's.
///
/// An immutable value; the feed and the source are `Sendable`.
struct OwnedFeed<Feed: AnyObject & Sendable>: Sendable {
    let feed: Feed
    let source: any SampleSource
}

/// A heat-map component on a source (VC-3, SRC-3): what `SpectrogramView(source:)`,
/// `ChromagramView(source:)` and `TempogramView(source:)` are made of.
///
/// While the view is in the hierarchy it keeps one attachment on the source: the pipeline
/// that `.processing(_:)` set, if any, followed by the component's analysis, which writes a
/// feed the view owns. The attachment is the one `.pipeline(_:on:)` keeps, so everything said
/// there holds here: it is made on the engine of the environment when the view appears,
/// updated when the pipeline changes, animated over the pipeline's continuous values
/// (ANI-3), and ended when the view leaves.
///
/// What is drawn is the feed-driven component over that feed, unchanged: every appearance
/// modifier, axis, pinch and size transition works as it does there (§8.1).
///
/// **The feed.** Every picture starts empty. The view makes a feed when it first appears,
/// another one for every other source it is given, and another one when it leaves, for the
/// time it comes back: a feed keeps what it holds when it is attached again in the shape it
/// has, and what one source left would otherwise be continued with what the next one brings.
/// To the surface another feed is the feed replaced: its texture is cleared once (§8.4). A
/// changed analysis keeps the feed, and the session clears it where the branch changed
/// (SWAP-3).
///
/// **Stability (§8.4).** The body depends on the source's identity and on the values of the
/// analysis modifiers, never on data. A parent that is evaluated again with the same source
/// and equal values attaches nothing and updates nothing. The one state written here is the
/// feed: when the view appears, when it leaves, and when its source is another one.
///
/// Threading: main actor.
struct SourceFedHeatmap: View {
    let source: any SampleSource
    let analysis: HeatmapAnalysis

    @Environment(\.dspAnalysisFrame) private var frame
    @Environment(\.dspMelBands) private var melBands
    @Environment(\.dspProcessing) private var processing
    /// The feed the view's own analysis writes, and the source it is the picture of.
    @State private var owned: OwnedFeed<HeatmapFeed>?

    private static func feed(of source: any SampleSource) -> OwnedFeed<HeatmapFeed> {
        OwnedFeed(feed: HeatmapFeed(history: HeatmapAnalysis.history), source: source)
    }

    var body: some View {
        // The place the component fills exists from the first evaluation; the picture comes
        // into it with the feed.
        Color.clear
            .overlay {
                if let owned {
                    HeatmapSurface(feed: owned.feed, role: analysis.role)
                        .pipeline(analysis.pipeline(processing: processing, frame: frame, melBands: melBands, into: owned.feed), on: owned.source)
                }
            }
            .onAppear {
                if owned == nil { owned = Self.feed(of: source) }
            }
            .onDisappear {
                // The attachment ends with this; what comes back starts an empty picture.
                if let owned { self.owned = Self.feed(of: owned.source) }
            }
            .onChange(of: SourceReference(source)) { next in
                // The source is read off the value handed over: SwiftUI calls the closure of
                // the evaluation before the change, whose view still holds the old one.
                if owned != nil { owned = Self.feed(of: next.source) }
            }
    }
}

/// A waveform component on a source: what `WaveformView(source:)` is made of. See
/// ``SourceFedHeatmap``.
///
/// Threading: main actor.
struct SourceFedWaveform: View {
    let source: any SampleSource

    @Environment(\.dspProcessing) private var processing
    /// The feed the view's own analysis writes, and the source it is the picture of.
    @State private var owned: OwnedFeed<WaveformFeed>?

    private static func feed(of source: any SampleSource) -> OwnedFeed<WaveformFeed> {
        OwnedFeed(feed: WaveformFeed(history: WaveformAnalysis.history), source: source)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let owned {
                    WaveformSurface(feed: owned.feed)
                        .pipeline(WaveformAnalysis.pipeline(processing: processing, into: owned.feed), on: owned.source)
                }
            }
            .onAppear {
                if owned == nil { owned = Self.feed(of: source) }
            }
            .onDisappear {
                if let owned { self.owned = Self.feed(of: owned.source) }
            }
            .onChange(of: SourceReference(source)) { next in
                if owned != nil { owned = Self.feed(of: next.source) }
            }
    }
}
