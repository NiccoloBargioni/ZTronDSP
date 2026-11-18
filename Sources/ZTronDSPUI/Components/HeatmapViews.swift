import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// Shows any `HeatmapFeed` as a heat map, colour-mapped, drawn with Metal: the generic base
/// that ``SpectrogramView``, ``ChromagramView`` and ``TempogramView`` specialise (§8.1).
///
/// ```swift
/// HeatmapView(feed: model.lags)          // a feed the app's own pipeline writes
///     .colorMap(.inferno)
///     .valueRange(0 ... 1)
///     .timeSpan(5)
/// ```
///
/// The view fills the size it is offered and adds nothing around it (VC-1). Appearance is set
/// with modifiers (VC-4): `.colorMap`, `.valueRange` (the default is −90 … 0), `.frequencyScale`,
/// `.frequencyRange`, `.timeSpan`, `.maximumFrameRate`; `.axis(_:)` adds axes and
/// `.pinchScaling(_:)` a pinch. One feed can drive several views.
///
/// **Stability (§8.4).** The view stores the feed and nothing of its contents, and its body
/// depends on no per-frame data. It draws only when there is a cause: new data, a changed
/// appearance, a changed size, coming on screen, another feed. While the feed is not live
/// (its session is stopped, or its branch suspended) the view's display link is paused and it
/// wakes nobody. A change of appearance costs one draw and uploads nothing.
///
/// Threading: main actor, like every view. Create the feed once, in state or in a model, not
/// in a `body`.
public struct HeatmapView: View, Equatable {
    private let feed: HeatmapFeed

    /// A heat map of `feed`.
    public init(feed: HeatmapFeed) {
        self.feed = feed
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// feed's identity and on appearance values, never on what the feed holds (V-1).
    public var body: some View {
        HeatmapSurface(feed: feed, role: .generic)
    }

    /// Two views are equal when they show the same feed object. Usable on any thread.
    nonisolated public static func == (lhs: HeatmapView, rhs: HeatmapView) -> Bool {
        lhs.feed === rhs.feed
    }
}

/// Shows a spectrum over time: frequency upwards, time to the right, the level as a colour
/// (§8.1).
///
/// ```swift
/// @State private var mic = HardwareInputSource()             // or FileSource(url:), GeneratorSource(…), any SampleSource
///
/// SpectrogramView(source: mic)                               // the view analyses the source itself …
///     .processing { HighPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
///     .analysisFrame(2_048, hop: 512, window: .hann)
///     .colorMap(.magma)
///     .valueRange(-90 ... 0)
///     .frequencyScale(.logarithmic)
///     .frequencyRange(50 ... 12_000)
///     .timeSpan($span)
///     .pinchScaling(.horizontal)
///     .axis(.frequency)
/// SpectrogramView(feed: model.spectrum)                      // … or shows a feed the app's own pipeline writes
/// ```
///
/// **Two ways in (VC-3).** `init(source:)` takes any `SampleSource`: a microphone, a file, a
/// mock, a processed signal (SRC-3). While the view is in the hierarchy it keeps one
/// attachment of the recipe `Spectrogram` (`STFT → Power → Decibels`) on that source, into a
/// feed of its own, and it detaches when it leaves. `.analysisFrame(_:hop:window:)` sets the
/// transform and `.processing(_:)` puts a pipeline in front of it. `init(feed:)` takes a feed
/// that the app's own pipeline writes; one feed can drive several views.
///
/// The feed holds a spectrum in decibels on any axis. Rows that are evenly spaced in hertz
/// are laid out by `.frequencyScale` (linear, logarithmic, mel) between the ends of
/// `.frequencyRange`. Rows that are already mel bands or constant-Q bins are drawn bin for
/// bin, whatever the scale, and labelled from the feed's `FeedAxis` (VC-5). A pixel that
/// covers several bins shows their maximum, so a one-bin peak is visible at every scale
/// (V-8).
///
/// Stability, appearance modifiers and threading are those of ``HeatmapView``, whichever way
/// in is used.
public struct SpectrogramView: View, Equatable {
    private let input: ComponentInput<HeatmapFeed>

    /// A spectrogram of a feed the app's own pipeline writes.
    ///
    /// Threading: main actor, like every view. It stores the feed and nothing else.
    public init(feed: HeatmapFeed) {
        input = .feed(feed)
    }

    /// A spectrogram of `source`, which the view analyses itself (VC-3, SRC-3).
    ///
    /// While the view is in the hierarchy it keeps one attachment on `source`: the recipe
    /// `Spectrogram`, 2 048 samples per frame and 512 from one frame to the next under a Hann
    /// window unless `.analysisFrame(_:hop:window:)` says otherwise, behind the pipeline of
    /// `.processing(_:)` when there is one. The attachment is made on the engine found in
    /// the environment, `DSPEngine.shared` unless `.dspEngine(_:)` says otherwise, and it
    /// writes a feed the view owns, which keeps the newest 1 024 columns: a little over ten
    /// seconds of the default analysis at 48 kHz. The view detaches when it leaves the
    /// hierarchy. A full-scale sine reads 0 dB whatever the frame and the window.
    ///
    /// The source is something the app keeps, in state or in a model, not something made in
    /// a `body`: another source object is another attachment, and another picture. Every
    /// picture starts empty: that of another source, and that of a view that comes back into
    /// the hierarchy. The source may serve other attachments at the same time (ATT-6). A
    /// source the engine cannot attach to, or a frame it refuses, is logged and leaves the
    /// view empty, or showing what it ran before.
    ///
    /// Threading: main actor, like every view. It stores the source and nothing else;
    /// attaching suspends off the main thread once the view is in the hierarchy.
    public init(source: any SampleSource) {
        input = .source(source)
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// identity of the feed or of the source and on the values of modifiers, never on data
    /// (V-1).
    public var body: some View {
        switch input {
        case .feed(let feed): HeatmapSurface(feed: feed, role: .spectrogram)
        case .source(let source): SourceFedHeatmap(source: source, analysis: .spectrogram)
        }
    }

    /// Two views are equal when they show the same feed object, or analyse the same source
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: SpectrogramView, rhs: SpectrogramView) -> Bool {
        lhs.input == rhs.input
    }
}

/// Shows chroma over time: the twelve pitch classes upwards, C at the bottom, time to the
/// right (§8.1).
///
/// ```swift
/// ChromagramView(source: mic)                                // the view analyses the source itself …
/// ChromagramView(feed: model.chroma)                         // … or shows a feed the app's own pipeline writes
/// ```
///
/// The twelve rows are cells with hard edges: the pitch axis is not interpolated. Values are
/// shown from 0 to 1 unless `.valueRange` says otherwise. A horizontal pinch scales the time
/// span; a vertical one does nothing, because the rows are fixed (§8.8).
///
/// **Two ways in (VC-3).** `init(source:)` takes any `SampleSource` and keeps one attachment
/// of the recipe `ChromaCQT` on it while the view is in the hierarchy; `init(feed:)` takes a
/// `Chroma` feed that the app's own pipeline writes.
///
/// Stability, appearance modifiers and threading are those of ``HeatmapView``, whichever way
/// in is used.
public struct ChromagramView: View, Equatable {
    private let input: ComponentInput<HeatmapFeed>

    /// A chromagram of a `Chroma` feed the app's own pipeline writes.
    ///
    /// Threading: main actor, like every view. It stores the feed and nothing else.
    public init(feed: HeatmapFeed) {
        input = .feed(feed)
    }

    /// A chromagram of `source`, which the view analyses itself (VC-3, SRC-3).
    ///
    /// While the view is in the hierarchy it keeps one attachment on `source`: the recipe
    /// `ChromaCQT` with its own defaults (a constant-Q transform of seven octaves from C1,
    /// 36 bins to the octave, one column every 512 samples, folded into twelve classes and
    /// scaled so that the strongest reads 1), behind the pipeline of `.processing(_:)` when
    /// there is one. The engine, the feed the view owns, the life of the attachment and the
    /// rule for the source are those of ``SpectrogramView/init(source:)``.
    ///
    /// The columns describe the signal a latency ago, that of the transform's longest atom:
    /// about 0.8 s at 48 kHz, so the picture starts that much after the source does. A
    /// constant-Q transform has no frame: `.analysisFrame(_:hop:window:)` is not read.
    ///
    /// Threading: main actor, like every view. It stores the source and nothing else;
    /// attaching suspends off the main thread once the view is in the hierarchy.
    public init(source: any SampleSource) {
        input = .source(source)
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// identity of the feed or of the source and on the values of modifiers, never on data
    /// (V-1).
    public var body: some View {
        switch input {
        case .feed(let feed): HeatmapSurface(feed: feed, role: .chromagram)
        case .source(let source): SourceFedHeatmap(source: source, analysis: .chromagram)
        }
    }

    /// Two views are equal when they show the same feed object, or analyse the same source
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: ChromagramView, rhs: ChromagramView) -> Bool {
        lhs.input == rhs.input
    }
}

/// Shows tempo over time: beats per minute upwards, time to the right (§8.1).
///
/// ```swift
/// TempogramView(source: mic)                                 // the view analyses the source itself …
///     .melBands(64)
/// TempogramView(feed: model.tempogram)                       // … or shows a feed the app's own pipeline writes
/// ```
///
/// The rows follow the feed's `FeedAxis`: each row is the tempo the feed says it is, drawn
/// bin for bin. `.frequencyRange(_:)` gives the visible tempi, in beats per minute, and a
/// vertical pinch scales them. Values are shown from 0 to 1 unless `.valueRange` says
/// otherwise.
///
/// **Two ways in (VC-3).** `init(source:)` takes any `SampleSource` and keeps one attachment
/// on it while the view is in the hierarchy: a mel spectrogram, its onset strength, and the
/// tempogram of that. `init(feed:)` takes a `TempoSpectrum` feed that the app's own pipeline
/// writes.
///
/// Stability, appearance modifiers and threading are those of ``HeatmapView``, whichever way
/// in is used.
public struct TempogramView: View, Equatable {
    private let input: ComponentInput<HeatmapFeed>

    /// A tempogram of a `TempoSpectrum` feed the app's own pipeline writes.
    ///
    /// Threading: main actor, like every view. It stores the feed and nothing else.
    public init(feed: HeatmapFeed) {
        input = .feed(feed)
    }

    /// A tempogram of `source`, which the view analyses itself (VC-3, SRC-3).
    ///
    /// While the view is in the hierarchy it keeps one attachment on `source`: a mel
    /// spectrogram (`STFT → Power → MelScale → Decibels`), then `OnsetStrength`, then
    /// `Tempogram`, behind the pipeline of `.processing(_:)` when there is one.
    /// `.analysisFrame(_:hop:window:)` sets the transform (2 048 samples per frame, 512 from
    /// one frame to the next, a Hann window without it) and `.melBands(_:)` the number of
    /// bands (128 without it); the onset strength and the tempogram run with their own
    /// defaults: the autocorrelation of the last 384 onset values, the tempi from 30 to 300
    /// beats per minute. The engine, the feed the view owns, the life of the attachment and
    /// the rule for the source are those of ``SpectrogramView/init(source:)``.
    ///
    /// The first column appears once a whole window of onset values is held: about four
    /// seconds after the source starts, with the default frame at 48 kHz.
    ///
    /// Threading: main actor, like every view. It stores the source and nothing else;
    /// attaching suspends off the main thread once the view is in the hierarchy.
    public init(source: any SampleSource) {
        input = .source(source)
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// identity of the feed or of the source and on the values of modifiers, never on data
    /// (V-1).
    public var body: some View {
        switch input {
        case .feed(let feed): HeatmapSurface(feed: feed, role: .tempogram)
        case .source(let source): SourceFedHeatmap(source: source, analysis: .tempogram)
        }
    }

    /// Two views are equal when they show the same feed object, or analyse the same source
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: TempogramView, rhs: TempogramView) -> Bool {
        lhs.input == rhs.input
    }
}
