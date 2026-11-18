import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// Shows a waveform as the envelope between its minima and its maxima, drawn with Metal:
/// live and scrolling while its session runs, or a still overview of a signal that was run
/// through a pipeline offline (§8.1).
///
/// ```swift
/// WaveformView(source: mic)                                  // the view analyses the source itself …
///     .amplitudeRange(-0.5 ... 0.5)
///     .timeSpan(4)
///     .pinchScaling([.horizontal, .vertical])
///     .axis(.time)
/// WaveformView(feed: model.envelope)                         // … or shows a feed the app's own pipeline writes
/// ```
///
/// **Two ways in (VC-3).** `init(source:)` takes any `SampleSource` and keeps one attachment
/// of the step `Waveform` on it while the view is in the hierarchy; `init(feed:)` takes a
/// feed that the app's own pipeline writes, live or filled by an offline run.
///
/// The view fills the size it is offered and adds nothing around it (VC-1). Appearance is set
/// with modifiers (VC-4): `.amplitudeRange` (the default is −1 … 1), `.timeSpan`,
/// `.maximumFrameRate`. The envelope is drawn in black in a light colour scheme and in white
/// in a dark one, on a transparent ground: a background is a SwiftUI modifier on the view.
/// A pixel that covers several pairs shows the smallest minimum and the largest maximum among
/// them, and silence is a line.
///
/// Stability and threading are those of ``HeatmapView``, whichever way in is used: nothing
/// is drawn without a cause, the display link is paused while the feed is not live, and a
/// change of appearance costs one draw and uploads nothing (§8.4).
public struct WaveformView: View, Equatable {
    private let input: ComponentInput<WaveformFeed>

    /// A waveform of a feed the app's own pipeline writes.
    ///
    /// Threading: main actor, like every view. It stores the feed and nothing else.
    public init(feed: WaveformFeed) {
        input = .feed(feed)
    }

    /// A waveform of `source`, which the view analyses itself (VC-3, SRC-3).
    ///
    /// While the view is in the hierarchy it keeps one attachment on `source`: the step
    /// `Waveform`, one pair of minimum and maximum per five milliseconds, behind the
    /// pipeline of `.processing(_:)` when there is one. The attachment is made on the engine
    /// found in the environment, `DSPEngine.shared` unless `.dspEngine(_:)` says otherwise,
    /// and it writes a feed the view owns, which keeps the newest 2 048 pairs: a little over
    /// ten seconds. The view detaches when it leaves the hierarchy. A waveform is not framed:
    /// `.analysisFrame(_:hop:window:)` is not read.
    ///
    /// The source is something the app keeps, in state or in a model, not something made in
    /// a `body`: another source object is another attachment, and another picture. Every
    /// picture starts empty: that of another source, and that of a view that comes back into
    /// the hierarchy. The source may serve other attachments at the same time (ATT-6). A
    /// source the engine cannot attach to is logged and leaves the view empty.
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
        case .feed(let feed): WaveformSurface(feed: feed)
        case .source(let source): SourceFedWaveform(source: source)
        }
    }

    /// Two views are equal when they show the same feed object, or analyse the same source
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: WaveformView, rhs: WaveformView) -> Bool {
        lhs.input == rhs.input
    }
}

/// What a waveform component is made of: the values the modifiers set, the Metal surface,
/// the time axis and the pinch. See ``HeatmapSurface``.
///
/// Threading: main actor.
struct WaveformSurface: View {
    let feed: WaveformFeed

    @Environment(\.dspAmplitudeRange) private var amplitudeRange
    @Environment(\.dspTimeSpan) private var timeSpan
    @Environment(\.dspPinchAxes) private var pinchAxes
    @Environment(\.dspShownAxes) private var shownAxes
    @Environment(\.colorScheme) private var colorScheme
    @State private var keptSpan: Kept<Double>?
    @State private var keptAmplitude: Kept<ClosedRange<Float>>?
    /// The pinch in progress: written when it begins and when it ends.
    @State private var pinch: WaveformPinch?

    private var appearance: WaveformAppearance {
        Self.appearance(amplitudeRange: amplitudeRange.shown(keeping: keptAmplitude), timeSpan: timeSpan.shown(keeping: keptSpan),
                        isDark: colorScheme == .dark)
    }

    /// The appearance a waveform has under these values; `nil` leaves a value to its default.
    static func appearance(amplitudeRange: ClosedRange<Float>?, timeSpan: Double?, isDark: Bool) -> WaveformAppearance {
        var appearance = WaveformAppearance()
        if let amplitudeRange { appearance.amplitudeRange = amplitudeRange }
        appearance.timeSpan = timeSpan.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        appearance.fill = isDark ? .white : .black
        return appearance
    }

    var body: some View {
        let appearance = appearance
        VStack(spacing: 0) {
            SurfaceFrame(
                content: .waveform(feed, appearance), vector: appearance.vector(fullSpan: FeedReference.waveform(feed).shape.historySpan),
                pinchAxes: pinchAxes, onPinch: pinched)
            if shownAxes.contains(.time) {
                TimeAxisContent(feed: .waveform(feed))
                    .frame(height: AxisMetrics.timeAxisHeight)
                    .id(ObjectIdentifier(feed))
            }
        }
        .environment(\.dspTimeSpan, appearance.timeSpan.map { .constant($0) })
    }

    /// One step of a pinch (WP-821): horizontal scales the time span, vertical the amplitude
    /// range.
    private func pinched(_ state: PinchState, size: CGSize, ended: Bool) {
        let current = pinch ?? WaveformPinch(
            appearance: appearance, shape: FeedReference.waveform(feed).shape,
            anchorFraction: HeatmapPinch.fraction(of: state.startCentroid ?? state.centroid, height: size.height) ?? 0.5)
        if pinch == nil, !ended { pinch = current }
        let span = current.timeSpan(for: state, resisting: !ended)
        let amplitude = current.amplitudeRange(for: state, height: size.height, resisting: !ended)
        if ended {
            pinch = nil
            withAnimation(.spring()) { store(span: span, amplitude: amplitude) }
        } else {
            store(span: span, amplitude: amplitude)
        }
    }

    private func store(span: Double?, amplitude: ClosedRange<Float>?) {
        if let span {
            let kept = timeSpan.storing(span)
            if kept != keptSpan { keptSpan = kept }
        }
        if let amplitude {
            let kept = amplitudeRange.storing(amplitude)
            if kept != keptAmplitude { keptAmplitude = kept }
        }
    }
}
