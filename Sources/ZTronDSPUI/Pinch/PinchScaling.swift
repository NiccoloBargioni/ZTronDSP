import Foundation
import ZTronDSPCore
import ZTronDSPMetal

/// The arithmetic of a pinch (§8.8): what a scale does to a time span or to a range, where
/// the limits are, how the value resists past them, and where it comes to rest.
///
/// A pinch changes what is shown, never what is computed (PINCH-2): everything here turns one
/// appearance value into another.
///
/// Pure functions on values; usable on any thread.
enum PinchScaling {
    /// Past a limit the value follows the fingers only this much: the excess is raised to
    /// this power, so that pulling twice as far past the limit moves the value by a fifth.
    static let resistance = 0.25
    /// The shortest time span, in seconds (PINCH-6).
    static let shortestSpan = 0.5
    /// The narrowest frequency range on an axis that is not linear in hertz: an eighth of an
    /// octave, as the ratio of its two ends (PINCH-6).
    static let narrowestRatio = exp2(1.0 / 8)
    /// The fewest rows a range covers on an axis that is linear (PINCH-6).
    static let fewestRows = 16.0
    /// The smallest amplitude range, as a share of full scale (PINCH-6).
    static let smallestAmplitudeShare = 1.0 / 1_000

    /// The extent a pinch asks for when it began at `start`: the fingers moving apart
    /// (`scale` above 1) show less, so the extent is `start / scale`. Past `limits` it
    /// resists.
    static func extent(start: Double, scale: Double, limits: ClosedRange<Double>) -> Double {
        guard start.isFinite, start > 0, scale.isFinite, scale > 0 else { return start }
        let wanted = start / scale
        if wanted < limits.lowerBound, limits.lowerBound > 0 {
            return limits.lowerBound * pow(wanted / limits.lowerBound, resistance)
        }
        if wanted > limits.upperBound, limits.upperBound > 0 {
            return limits.upperBound * pow(wanted / limits.upperBound, resistance)
        }
        return wanted
    }

    /// Where an extent comes to rest when the fingers lift: inside the limits (PINCH-6).
    static func settled(_ extent: Double, limits: ClosedRange<Double>) -> Double {
        min(max(extent, limits.lowerBound), limits.upperBound)
    }

    /// The limits of a time span, in seconds: from half a second to the feed's history. A
    /// history shorter than half a second is the only span there is.
    static func spanLimits(history: Int, columnRate: Double) -> ClosedRange<Double> {
        let longest = Double(max(history, 1)) / columnRate
        return min(shortestSpan, longest) ... longest
    }

    /// A window of `extent` on an axis that keeps `anchor` at `fraction` of the way from its
    /// lower to its upper end: the value under the pinch's centroid stays under it
    /// (PINCH-4). A window that fits inside `full` is moved inside it; a wider one, which a
    /// pinch reaches only while it resists, reaches past both ends.
    static func window(extent: Double, anchor: Double, fraction: Double, within full: ClosedRange<Double>) -> ClosedRange<Double> {
        let whole = full.upperBound - full.lowerBound
        let share = min(max(fraction, 0), 1)
        guard extent.isFinite, extent > 0, anchor.isFinite else { return full }
        var lower = anchor - share * extent
        if extent <= whole {
            lower = min(max(lower, full.lowerBound), full.upperBound - extent)
        } else {
            lower = full.lowerBound - (extent - whole) * share
        }
        return lower ... lower + extent
    }
}

/// One pinch along the vertical axis of a heat map: the frequency or tempo range it began
/// with, the point it is anchored at, and what a scale makes of them.
///
/// The arithmetic runs on the axis the view is linear in (`RowLayout`'s coordinates): the
/// scale's own unit for rows that are evenly spaced in hertz, row positions for every other
/// feed. That is what keeps the value under the centroid where it is on a logarithmic axis
/// as well as on a linear one.
///
/// An immutable value, usable on any thread.
struct RowPinch: Equatable {
    /// The layout when the pinch began, with the range that was visible then.
    let layout: RowLayout
    /// The ends of what was visible when the pinch began.
    let start: ClosedRange<Double>
    /// The whole axis.
    let full: ClosedRange<Double>
    /// Where the pinch's centroid was when it began, from the bottom edge (0) to the top (1).
    let anchorFraction: Double

    /// - Parameter anchorFraction: the centroid's height in the view when the pinch began,
    ///   0 at the bottom edge; the middle where the gesture does not say.
    init(layout: RowLayout, anchorFraction: Double = 0.5) {
        self.layout = layout
        start = layout.visibleCoordinates
        full = layout.fullCoordinates
        self.anchorFraction = min(max(anchorFraction, 0), 1)
    }

    private var anchor: Double {
        start.lowerBound + anchorFraction * (start.upperBound - start.lowerBound)
    }

    /// The narrowest and the widest window a pinch comes to rest at (PINCH-6): no narrower
    /// than an eighth of an octave where the axis is not linear in hertz, or 16 rows where it
    /// is linear, and no wider than the feed's axis.
    var limits: ClosedRange<Double> {
        let whole = full.upperBound - full.lowerBound
        return min(narrowest, whole) ... whole
    }

    private var narrowest: Double {
        switch layout.axis {
        case .linearFrequency(let count, let nyquist):
            // Linear in hertz: sixteen rows, which the view's axis counts in hertz.
            if layout.isLinearInHertz { return PinchScaling.fewestRows * (count > 1 ? nyquist / Double(count - 1) : nyquist) }
            return heightOfAnEighthOfAnOctave
        case .mel, .constantQ:
            return heightOfAnEighthOfAnOctave
        default:
            return PinchScaling.fewestRows
        }
    }

    /// The height of the window around the anchor whose ends are an eighth of an octave
    /// apart, found by bisection: the ratio of the ends grows with the height.
    private var heightOfAnEighthOfAnOctave: Double {
        let whole = full.upperBound - full.lowerBound
        func isWideEnough(_ height: Double) -> Bool {
            let low = layout.value(atCoordinate: anchor - anchorFraction * height)
            let high = layout.value(atCoordinate: anchor + (1 - anchorFraction) * height)
            return low <= 0 || high / low >= PinchScaling.narrowestRatio
        }
        guard whole > 0, !isWideEnough(0) else { return 0 }
        guard isWideEnough(whole) else { return whole }
        var narrow = 0.0, wide = whole
        for _ in 0 ..< 48 {
            let middle = (narrow + wide) / 2
            if isWideEnough(middle) { wide = middle } else { narrow = middle }
        }
        return wide
    }

    /// The window a scale asks for, on the view's axis.
    ///
    /// - Parameters:
    ///   - centroidFraction: where the centroid is now; `nil` keeps it where it began.
    ///   - resisting: `true` while the fingers are down, when the window may go past its
    ///     limits a little; `false` for where it comes to rest.
    func window(scale: Double, centroidFraction: Double? = nil, resisting: Bool = true) -> ClosedRange<Double> {
        let limits = limits
        var extent = PinchScaling.extent(start: start.upperBound - start.lowerBound, scale: scale, limits: limits)
        if !resisting { extent = PinchScaling.settled(extent, limits: limits) }
        return PinchScaling.window(extent: extent, anchor: anchor, fraction: centroidFraction ?? anchorFraction, within: full)
    }

    /// The range a scale asks for, in the unit of the feed's axis: what `.frequencyRange`
    /// holds.
    func range(scale: Double, centroidFraction: Double? = nil, resisting: Bool = true) -> ClosedRange<Double> {
        let window = window(scale: scale, centroidFraction: centroidFraction, resisting: resisting)
        return ClosedRange.ordered(layout.value(atCoordinate: window.lowerBound), layout.value(atCoordinate: window.upperBound))
            ?? layout.visibleRange
    }
}

/// One pinch along the amplitude axis of a waveform.
///
/// An immutable value, usable on any thread.
struct AmplitudePinch: Equatable {
    /// Full scale.
    static let full: ClosedRange<Double> = -1 ... 1

    /// The amplitude range when the pinch began.
    let start: ClosedRange<Double>
    /// Where the centroid was when it began, from the bottom edge (0) to the top (1).
    let anchorFraction: Double

    init(range: ClosedRange<Float>, anchorFraction: Double = 0.5) {
        start = Double(range.lowerBound) ... Double(range.upperBound)
        self.anchorFraction = min(max(anchorFraction, 0), 1)
    }

    /// From a thousandth of full scale to full scale (PINCH-6).
    var limits: ClosedRange<Double> {
        let whole = Self.full.upperBound - Self.full.lowerBound
        return whole * PinchScaling.smallestAmplitudeShare ... whole
    }

    /// The amplitude range a scale asks for; see ``RowPinch/window(scale:centroidFraction:resisting:)``.
    func range(scale: Double, centroidFraction: Double? = nil, resisting: Bool = true) -> ClosedRange<Float> {
        var extent = PinchScaling.extent(start: start.upperBound - start.lowerBound, scale: scale, limits: limits)
        if !resisting { extent = PinchScaling.settled(extent, limits: limits) }
        let anchor = start.lowerBound + anchorFraction * (start.upperBound - start.lowerBound)
        let window = PinchScaling.window(extent: extent, anchor: anchor, fraction: centroidFraction ?? anchorFraction, within: Self.full)
        return Float(window.lowerBound) ... Float(window.upperBound)
    }
}
