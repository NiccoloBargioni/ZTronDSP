import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// The sizes of the axes a component lays out beside its picture.
enum AxisMetrics {
    /// The width of a vertical axis, in points.
    static let rowAxisWidth: CGFloat = 44
    /// The height of a time axis, in points.
    static let timeAxisHeight: CGFloat = 20
    /// The room one label needs along a vertical and along a horizontal axis, in points.
    static let rowLabelHeight: CGFloat = 28
    static let timeLabelWidth: CGFloat = 56
    /// The length of a tick mark, in points.
    static let tickLength: CGFloat = 4
}

/// Counts how often an axis was drawn, and at which size: what the tests of WP-808 assert
/// on. Injected through the environment; an axis that is given none counts nothing.
///
/// Threading: main actor.
@MainActor
final class AxisProbe {
    /// Times a `Canvas` of an axis ran its drawing.
    private(set) var draws = 0
    /// The size of the canvas at each of those drawings, in points, in order.
    private(set) var sizes: [CGSize] = []

    func recordDraw(size: CGSize) {
        draws += 1
        sizes.append(size)
    }
}

private struct AxisProbeKey: EnvironmentKey {
    static let defaultValue: AxisProbe? = nil
}

extension EnvironmentValues {
    /// The probe the axes of a hierarchy count into, when a test injects one.
    var dspAxisProbe: AxisProbe? {
        get { self[AxisProbeKey.self] }
        set { self[AxisProbeKey.self] = newValue }
    }
}

/// What an axis shows, whatever its size: the rows of a feed under a scale and a range, or a
/// span of seconds. The marks are chosen from this when the axis is drawn, for the room it
/// has then. Two equal ones are one drawing: an axis is redrawn only when this changes, or
/// its size (WP-808).
///
/// An immutable value, usable on any thread.
enum AxisSpec: Equatable, Sendable {
    /// A vertical axis: the rows of a feed, laid out as the picture beside it lays them out.
    case rows(RowLayout)
    /// A horizontal axis: this many seconds, the present at the right edge.
    case time(span: Double)
    /// Nothing to show: a feed without an axis, or without a feature rate.
    case nothing

    /// The vertical axis of a feed of `shape`, under the scale and the range the environment
    /// holds. A feed without an axis shows `fallback`, or nothing.
    static func rows(shape: FeedShape, fallback: FeedAxis?, scale: AnyFrequencyScale?, range: ClosedRange<Double>?) -> AxisSpec {
        guard let axis = shape.axis ?? fallback else { return .nothing }
        return .rows(RowLayout(axis: axis, scale: scale ?? AnyFrequencyScale(LinearFrequencyScale()), range: range))
    }

    /// The time axis of a feed of `shape` that shows `span` seconds, or its whole history. A
    /// feed that does not say how many columns a second it gets has no time axis: seconds
    /// mean nothing for it yet.
    static func time(shape: FeedShape, span: Double?) -> AxisSpec {
        guard let whole = shape.historySpan else { return .nothing }
        return .time(span: span.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? whole)
    }

    /// The marks of the axis at `size`: as many as it has room for.
    func model(size: CGSize) -> AxisModel {
        switch self {
        case .rows(let layout):
            guard size.height > 0 else { return AxisModel(ticks: [], edge: .leading) }
            return AxisModel(ticks: AxisTicks.rows(layout, maximumCount: max(Int(size.height / AxisMetrics.rowLabelHeight), 2)), edge: .leading)
        case .time(let span):
            guard size.width > 0 else { return AxisModel(ticks: [], edge: .bottom) }
            return AxisModel(ticks: AxisTicks.time(span: span, maximumCount: max(Int(size.width / AxisMetrics.timeLabelWidth), 2)), edge: .bottom)
        case .nothing:
            return AxisModel(ticks: [], edge: .leading)
        }
    }
}

/// What an axis draws at one size: its marks, and along which edge of the picture it lies.
///
/// An immutable value, usable on any thread.
struct AxisModel: Equatable, Sendable {
    enum Edge: Equatable, Sendable {
        /// A vertical axis to the left of the picture: labels right-aligned towards it.
        case leading
        /// A horizontal axis below the picture.
        case bottom
    }

    var ticks: [AxisTick]
    var edge: Edge
}

/// One drawing of an axis: the specification a canvas draws from, as an object. A view that
/// holds the same drawing holds the same thing, whatever was evaluated around it.
///
/// Immutable; main actor.
@MainActor
final class AxisDrawing {
    let spec: AxisSpec

    init(_ spec: AxisSpec) {
        self.spec = spec
    }
}

/// What an axis view keeps for as long as it is on screen: the watcher of its feed's shape,
/// and the drawing it shows.
///
/// SwiftUI decides whether a view changed by comparing what the view stores, and it
/// evaluates a view that reads the environment whenever something above it is evaluated
/// again (observed on iOS 27; conforming to `Equatable` changes neither). A specification
/// that is computed anew is new storage and so looks changed, although it says the same.
/// The keeper hands back the drawing that is on screen for as long as it is asked for an
/// equal specification, so that the canvas is given the same object and is left alone: an
/// axis is redrawn only when what it shows changes (WP-808).
///
/// Threading: main actor. `drawing(for:)` is called while a body is evaluated, as a memo of
/// that body's result; it invalidates nothing.
@MainActor
final class AxisKeeper {
    let watcher = FeedShapeWatcher()
    private var shown: AxisDrawing?

    /// The drawing for `spec`: the one on screen when it shows an equal specification.
    func drawing(for spec: AxisSpec) -> AxisDrawing {
        if let shown, shown.spec == spec { return shown }
        let drawing = AxisDrawing(spec)
        shown = drawing
        return drawing
    }
}

/// Draws an axis with `Canvas` (VC-2). The marks are chosen when the canvas draws, for the
/// size it has then.
///
/// Threading: main actor.
struct AxisCanvas: View {
    let drawing: AxisDrawing
    let probe: AxisProbe?

    var body: some View {
        let spec = drawing.spec, probe = probe
        Canvas { context, size in
            MainActor.assumeIsolated { probe?.recordDraw(size: size) }
            let model = spec.model(size: size)
            for tick in model.ticks {
                let text = Text(tick.label).font(.caption2).foregroundColor(.secondary)
                var mark = Path()
                switch model.edge {
                case .leading:
                    let y = size.height * (1 - tick.fraction)
                    mark.move(to: CGPoint(x: size.width - AxisMetrics.tickLength, y: y))
                    mark.addLine(to: CGPoint(x: size.width, y: y))
                    // A label at an end of the axis stays inside it.
                    let anchor: UnitPoint = tick.fraction > 0.97 ? .topTrailing : tick.fraction < 0.03 ? .bottomTrailing : .trailing
                    context.draw(text, at: CGPoint(x: size.width - AxisMetrics.tickLength - 2, y: y), anchor: anchor)
                case .bottom:
                    let x = size.width * tick.fraction
                    mark.move(to: CGPoint(x: x, y: 0))
                    mark.addLine(to: CGPoint(x: x, y: AxisMetrics.tickLength))
                    let anchor: UnitPoint = tick.fraction > 0.97 ? .topTrailing : tick.fraction < 0.03 ? .topLeading : .top
                    context.draw(text, at: CGPoint(x: x, y: AxisMetrics.tickLength + 1), anchor: anchor)
                }
                context.stroke(mark, with: .color(.secondary), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A vertical axis for a heat-map feed: what the three public row-axis views show.
///
/// It reads the frequency scale and the vertical range from the environment, as the component
/// beside it does, and the feed's shape from the feed. It keeps the shape in state, which a
/// ``FeedShapeWatcher`` writes when the shape changes, and never at data rate (V-2).
struct RowAxisContent: View {
    let feed: HeatmapFeed
    /// The axis shown while the feed has none of its own.
    let fallback: FeedAxis?

    @Environment(\.dspFrequencyScale) private var scale
    @Environment(\.dspFrequencyRange) private var range
    @Environment(\.dspClockSource) private var clocks
    @Environment(\.dspAxisProbe) private var probe
    @State private var watched: FeedShape?
    @State private var keeper: AxisKeeper?

    var body: some View {
        let spec = AxisSpec.rows(shape: watched ?? FeedReference.heatmap(feed).shape, fallback: fallback, scale: scale, range: range?.value)
        AxisCanvas(drawing: keeper?.drawing(for: spec) ?? AxisDrawing(spec), probe: probe)
            .onAppear {
                let keeper = AxisKeeper()
                self.keeper = keeper
                keeper.watcher.watch(.heatmap(feed), clock: clocks?.makeClock()) { watched = $0 }
            }
            .onDisappear {
                keeper?.watcher.stop()
                keeper = nil
            }
    }
}

/// A time axis for a feed of either kind: what ``TimeAxisView`` shows.
struct TimeAxisContent: View {
    let feed: FeedReference

    @Environment(\.dspTimeSpan) private var span
    @Environment(\.dspClockSource) private var clocks
    @Environment(\.dspAxisProbe) private var probe
    @State private var watched: FeedShape?
    @State private var keeper: AxisKeeper?

    var body: some View {
        let spec = AxisSpec.time(shape: watched ?? feed.shape, span: span?.value)
        AxisCanvas(drawing: keeper?.drawing(for: spec) ?? AxisDrawing(spec), probe: probe)
            .onAppear {
                let keeper = AxisKeeper()
                self.keeper = keeper
                keeper.watcher.watch(feed, clock: clocks?.makeClock()) { watched = $0 }
            }
            .onDisappear {
                keeper?.watcher.stop()
                keeper = nil
            }
    }
}

// MARK: The public axis views (VC-2)

/// The frequency axis of a heat map, as a view of its own: marks and labels for the rows of
/// `feed`, drawn with `Canvas`.
///
/// Place it beside the component that shows the same feed, inside the same appearance
/// modifiers, or let the component place it with `.axis(.frequency)`:
///
/// ```swift
/// HStack(spacing: 0) {
///     FrequencyAxisView(feed: feed).frame(width: 44)
///     SpectrogramView(feed: feed)
/// }
/// .frequencyScale(.logarithmic)
/// .frequencyRange(50 ... 8_000)
/// ```
///
/// The labels come from the feed's `FeedAxis` (VC-5): hertz on the scale and range the
/// environment sets for rows evenly spaced in hertz; the centre of each band, bin for bin,
/// for mel bands and constant-Q bins. A feed whose rows are something else is labelled as
/// what it is. The axis is redrawn only when the scale, the range, the feed's axis or its
/// size changes, never when data arrives.
///
/// Threading: main actor, like every view; creating one does not allocate, and laying out its
/// labels allocates.
public struct FrequencyAxisView: View, Equatable {
    private let feed: HeatmapFeed

    /// An axis for the rows of `feed`.
    public init(feed: HeatmapFeed) {
        self.feed = feed
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// feed's identity and on appearance values, never on what the feed holds (V-1).
    public var body: some View {
        RowAxisContent(feed: feed, fallback: nil).id(ObjectIdentifier(feed))
    }

    /// Two views are equal when they label the same feed object. Usable on any thread.
    nonisolated public static func == (lhs: FrequencyAxisView, rhs: FrequencyAxisView) -> Bool {
        lhs.feed === rhs.feed
    }
}

/// The pitch-class axis of a chromagram, as a view of its own: the names of the twelve
/// classes, C at the bottom, one per row (VC-2).
///
/// The names are shown before a pipeline writes the feed, too: a chroma feed can have no
/// other rows. A feed whose rows turn out to be something else is labelled as what it is
/// (VC-5). Redrawn only when the feed's axis, the vertical range or its size changes.
///
/// Threading: main actor, like every view; creating one does not allocate, and laying out its
/// labels allocates.
public struct PitchClassAxisView: View, Equatable {
    private let feed: HeatmapFeed

    /// An axis for the rows of `feed`.
    public init(feed: HeatmapFeed) {
        self.feed = feed
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// feed's identity and on appearance values, never on what the feed holds (V-1).
    public var body: some View {
        RowAxisContent(feed: feed, fallback: .pitchClasses).id(ObjectIdentifier(feed))
    }

    /// Two views are equal when they label the same feed object. Usable on any thread.
    nonisolated public static func == (lhs: PitchClassAxisView, rhs: PitchClassAxisView) -> Bool {
        lhs.feed === rhs.feed
    }
}

/// The tempo axis of a tempogram, as a view of its own: beats per minute, where the feed's
/// rows put them (VC-2, VC-5).
///
/// `.frequencyRange(_:)` gives the visible range, in beats per minute. A feed whose rows are
/// something else is labelled as what it is. Redrawn only when the feed's axis, the range or
/// its size changes.
///
/// Threading: main actor, like every view; creating one does not allocate, and laying out its
/// labels allocates.
public struct TempoAxisView: View, Equatable {
    private let feed: HeatmapFeed

    /// An axis for the rows of `feed`.
    public init(feed: HeatmapFeed) {
        self.feed = feed
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// feed's identity and on appearance values, never on what the feed holds (V-1).
    public var body: some View {
        RowAxisContent(feed: feed, fallback: nil).id(ObjectIdentifier(feed))
    }

    /// Two views are equal when they label the same feed object. Usable on any thread.
    nonisolated public static func == (lhs: TempoAxisView, rhs: TempoAxisView) -> Bool {
        lhs.feed === rhs.feed
    }
}

/// The time axis of a component, as a view of its own: the present at the right edge and the
/// seconds before it to the left (VC-2).
///
/// It shows the span `.timeSpan(_:)` sets, or the feed's whole history. The seconds come
/// from the feed's own record of its feature rate (ENV-4), so the axis is empty until a
/// pipeline writes the feed. Redrawn only when the span, the feed's rate or history, or its
/// size changes.
///
/// Threading: main actor, like every view; creating one does not allocate, and laying out its
/// labels allocates.
public struct TimeAxisView: View, Equatable {
    private let feed: FeedReference

    /// A time axis for a heat-map feed.
    public init(feed: HeatmapFeed) {
        self.feed = .heatmap(feed)
    }

    /// A time axis for a waveform feed.
    public init(feed: WaveformFeed) {
        self.feed = .waveform(feed)
    }

    /// What the view is made of. SwiftUI evaluates it on the main actor; it depends on the
    /// feed's identity and on appearance values, never on what the feed holds (V-1).
    public var body: some View {
        TimeAxisContent(feed: feed).id(feed.identity)
    }

    /// Two views are equal when they label the same feed object. Usable on any thread.
    nonisolated public static func == (lhs: TimeAxisView, rhs: TimeAxisView) -> Bool {
        lhs.feed == rhs.feed
    }
}
