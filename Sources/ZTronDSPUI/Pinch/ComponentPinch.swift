import CoreGraphics
import Foundation
import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// What one pinch does to a heat map (WP-820): a horizontal pinch scales the time span, a
/// vertical one the frequency or tempo range. It is made when the pinch begins, from what the
/// view shows then, and every later step of the pinch is computed from that beginning.
///
/// An immutable value, usable on any thread.
struct HeatmapPinch: Equatable {
    /// The time span when the pinch began, in seconds, and its limits (PINCH-6). `nil` when
    /// the feed does not say how many columns a second it gets: then seconds mean nothing yet.
    let span: Double?
    let spanLimits: ClosedRange<Double>?
    /// The vertical pinch; `nil` for rows that are fixed (pitch classes) and for a feed that
    /// has no axis yet.
    let rows: RowPinch?

    /// - Parameters:
    ///   - scalesRows: `false` for a chromagram, whose twelve rows are fixed (§8.8).
    ///   - anchorFraction: the height of the pinch's centroid when it began, 0 at the bottom.
    init(appearance: HeatmapAppearance, shape: FeedShape, scalesRows: Bool, anchorFraction: Double) {
        if let rate = shape.columnRate, let whole = shape.historySpan {
            span = appearance.timeSpan ?? whole
            spanLimits = PinchScaling.spanLimits(history: shape.history, columnRate: rate)
        } else {
            span = nil
            spanLimits = nil
        }
        if scalesRows, let axis = shape.axis, axis != .pitchClasses, axis.rowCount > 0 {
            rows = RowPinch(layout: RowLayout(axis: axis, scale: appearance.frequencyScale, range: appearance.rowRange), anchorFraction: anchorFraction)
        } else {
            rows = nil
        }
    }

    /// The time span a step of the pinch asks for; `nil` when this pinch does not scale time.
    /// The time axis stays anchored at the present (PINCH-4).
    func timeSpan(for state: PinchState, resisting: Bool) -> Double? {
        guard state.axes.contains(.horizontal), let span, let spanLimits else { return nil }
        let extent = PinchScaling.extent(start: span, scale: Double(state.scale), limits: spanLimits)
        return resisting ? extent : PinchScaling.settled(extent, limits: spanLimits)
    }

    /// The vertical range a step of the pinch asks for, in the unit of the feed's axis;
    /// `nil` when this pinch does not scale the rows.
    func rowRange(for state: PinchState, height: CGFloat, resisting: Bool) -> ClosedRange<Double>? {
        guard state.axes.contains(.vertical), let rows else { return nil }
        return rows.range(scale: Double(state.scale), centroidFraction: Self.fraction(of: state.centroid, height: height), resisting: resisting)
    }

    /// The height of a point in a view of `height`, from the bottom edge (0) to the top (1);
    /// `nil` where there is no point or no height.
    static func fraction(of point: CGPoint?, height: CGFloat) -> Double? {
        guard let point, height > 0 else { return nil }
        return min(max(1 - Double(point.y / height), 0), 1)
    }
}

/// What one pinch does to a waveform (WP-821): a horizontal pinch scales the time span, a
/// vertical one the amplitude range.
///
/// An immutable value, usable on any thread.
struct WaveformPinch: Equatable {
    let span: Double?
    let spanLimits: ClosedRange<Double>?
    let amplitude: AmplitudePinch

    init(appearance: WaveformAppearance, shape: FeedShape, anchorFraction: Double) {
        if let rate = shape.columnRate, let whole = shape.historySpan {
            span = appearance.timeSpan ?? whole
            spanLimits = PinchScaling.spanLimits(history: shape.history, columnRate: rate)
        } else {
            span = nil
            spanLimits = nil
        }
        amplitude = AmplitudePinch(range: appearance.amplitudeRange, anchorFraction: anchorFraction)
    }

    /// The time span a step of the pinch asks for; `nil` when this pinch does not scale time.
    func timeSpan(for state: PinchState, resisting: Bool) -> Double? {
        guard state.axes.contains(.horizontal), let span, let spanLimits else { return nil }
        let extent = PinchScaling.extent(start: span, scale: Double(state.scale), limits: spanLimits)
        return resisting ? extent : PinchScaling.settled(extent, limits: spanLimits)
    }

    /// The amplitude range a step of the pinch asks for; `nil` when this pinch does not
    /// scale the amplitude.
    func amplitudeRange(for state: PinchState, height: CGFloat, resisting: Bool) -> ClosedRange<Float>? {
        guard state.axes.contains(.vertical) else { return nil }
        return amplitude.range(scale: Double(state.scale), centroidFraction: HeatmapPinch.fraction(of: state.centroid, height: height), resisting: resisting)
    }
}
