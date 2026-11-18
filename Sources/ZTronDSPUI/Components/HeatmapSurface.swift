import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// What tells the heat-map components apart: nothing but a few defaults. The spectrogram,
/// the chromagram and the tempogram are the generic heat map with another one of these.
///
/// An immutable value, usable on any thread.
struct HeatmapRole: Equatable, Sendable {
    /// The value range shown when no `.valueRange` is set.
    let valueRange: ClosedRange<Float>
    /// How the space between two rows is filled.
    let rowInterpolation: RowInterpolation
    /// Whether a vertical pinch scales the rows. A chromagram's twelve rows are fixed (§8.8).
    let scalesRows: Bool
    /// The axis an `.axis(_:)` shows before a pipeline has written the feed.
    let fallbackAxis: FeedAxis?

    /// Any heat map: decibels from −90 to 0, rows blended.
    static let generic = HeatmapRole(valueRange: -90 ... 0, rowInterpolation: .linear, scalesRows: true, fallbackAxis: nil)
    /// A spectrum in decibels.
    static let spectrogram = generic
    /// Twelve pitch classes as cells with hard edges, values from 0 to 1.
    static let chromagram = HeatmapRole(valueRange: 0 ... 1, rowInterpolation: .nearest, scalesRows: false, fallbackAxis: .pitchClasses)
    /// Tempo strengths from 0 to 1.
    static let tempogram = HeatmapRole(valueRange: 0 ... 1, rowInterpolation: .linear, scalesRows: true, fallbackAxis: nil)
}

/// What every heat-map component is made of: the values the appearance modifiers set, read
/// from the environment; the Metal surface that shows them; the axes, when `.axis(_:)` asks
/// for them; the pinch, when `.pinchScaling(_:)` enables it.
///
/// The body depends on the feed's identity and on appearance values only, never on what the
/// feed holds (V-1). The state it writes is what a pinch left of a value that was given as a
/// constant (PINCH-5): at the rate of a gesture, never at data rate (V-2).
///
/// Threading: main actor.
struct HeatmapSurface: View {
    let feed: HeatmapFeed
    let role: HeatmapRole

    @Environment(\.dspColorMap) private var colorMap
    @Environment(\.dspValueRange) private var valueRange
    @Environment(\.dspFrequencyScale) private var frequencyScale
    @Environment(\.dspFrequencyRange) private var frequencyRange
    @Environment(\.dspTimeSpan) private var timeSpan
    @Environment(\.dspPinchAxes) private var pinchAxes
    @Environment(\.dspShownAxes) private var shownAxes
    @State private var keptSpan: Kept<Double>?
    @State private var keptRows: Kept<ClosedRange<Double>>?
    /// The pinch in progress: written when it begins and when it ends.
    @State private var pinch: HeatmapPinch?

    /// The appearance the modifiers and the pinches so far add up to.
    private var appearance: HeatmapAppearance {
        Self.appearance(role: role, colorMap: colorMap, valueRange: valueRange?.value, frequencyScale: frequencyScale,
                        rowRange: frequencyRange.shown(keeping: keptRows), timeSpan: timeSpan.shown(keeping: keptSpan))
    }

    /// The appearance a heat map of `role` has under these values; `nil` leaves a value to
    /// the role's default.
    static func appearance(
        role: HeatmapRole, colorMap: AnyColorMap?, valueRange: ClosedRange<Float>?, frequencyScale: AnyFrequencyScale?,
        rowRange: ClosedRange<Double>?, timeSpan: Double?
    ) -> HeatmapAppearance {
        var appearance = HeatmapAppearance()
        if let colorMap { appearance.colorMap = colorMap }
        appearance.valueRange = valueRange ?? role.valueRange
        if let frequencyScale { appearance.frequencyScale = frequencyScale }
        appearance.rowRange = rowRange
        // A span that is no time shows the whole history.
        appearance.timeSpan = timeSpan.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        appearance.rowInterpolation = role.rowInterpolation
        return appearance
    }

    /// The continuous values of `appearance` for a feed of `shape`: what an animation
    /// interpolates.
    static func vector(_ appearance: HeatmapAppearance, shape: FeedShape) -> AppearanceVector {
        appearance.vector(fullRows: shape.axis.map { RowAxisMapping(axis: $0).fullRange }, fullSpan: shape.historySpan)
    }

    var body: some View {
        let appearance = appearance
        let showsRows = shownAxes.contains(.rows), showsTime = shownAxes.contains(.time)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsRows {
                    RowAxisContent(feed: feed, fallback: role.fallbackAxis)
                        .frame(width: AxisMetrics.rowAxisWidth)
                        .id(ObjectIdentifier(feed))
                }
                SurfaceFrame(
                    content: .heatmap(feed, appearance), vector: Self.vector(appearance, shape: FeedReference.heatmap(feed).shape),
                    pinchAxes: role.scalesRows ? pinchAxes : pinchAxes.intersection(.horizontal), onPinch: pinched)
            }
            if showsTime {
                TimeAxisContent(feed: .heatmap(feed))
                    .frame(height: AxisMetrics.timeAxisHeight)
                    .padding(.leading, showsRows ? AxisMetrics.rowAxisWidth : 0)
                    .id(ObjectIdentifier(feed))
            }
        }
        // The axes label what is shown, a pinched value included.
        .environment(\.dspFrequencyRange, appearance.rowRange.map { .constant($0) })
        .environment(\.dspTimeSpan, appearance.timeSpan.map { .constant($0) })
    }

    /// One step of a pinch (WP-820). The scaled values go where the modifiers say: into the
    /// binding, or into what the view keeps for a constant. When the fingers lift, a value
    /// past its limit springs back (PINCH-6).
    private func pinched(_ state: PinchState, size: CGSize, ended: Bool) {
        let current = pinch ?? HeatmapPinch(
            appearance: appearance, shape: FeedReference.heatmap(feed).shape, scalesRows: role.scalesRows,
            anchorFraction: HeatmapPinch.fraction(of: state.startCentroid ?? state.centroid, height: size.height) ?? 0.5)
        if pinch == nil, !ended { pinch = current }
        let span = current.timeSpan(for: state, resisting: !ended)
        let rows = current.rowRange(for: state, height: size.height, resisting: !ended)
        if ended {
            pinch = nil
            withAnimation(.spring()) { store(span: span, rows: rows) }
        } else {
            store(span: span, rows: rows)
        }
    }

    private func store(span: Double?, rows: ClosedRange<Double>?) {
        if let span {
            let kept = timeSpan.storing(span)
            if kept != keptSpan { keptSpan = kept }
        }
        if let rows {
            let kept = frequencyRange.storing(rows)
            if kept != keptRows { keptRows = kept }
        }
    }
}
