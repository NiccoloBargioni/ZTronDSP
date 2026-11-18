import Foundation
import ZTronDSPCore
import ZTronDSPMetal

/// Where the values of a feed's rows sit among the rows: the bridge between a value in the
/// unit of the feed's axis (hertz, beats per minute, seconds, a pitch class, an index) and a
/// **row position**, which counts from 0 at the lower edge of the first row to the row count
/// at the upper edge of the last one, so that row `k` has its centre at `k + 0.5`. That is
/// the unit a heat-map renderer takes the visible rows in for a feed it draws bin for bin
/// (VC-5).
///
/// Views label from this, a pinch scales through it, and `.frequencyRange` is turned into
/// rows with it, so the labels, the gesture and the picture agree.
///
/// An immutable value, usable on any thread.
struct RowAxisMapping: Equatable, Sendable {
    let axis: FeedAxis

    /// The row position of `value`. Between two rows the position is interpolated, linearly
    /// in the value, or in its logarithm on a constant-Q axis; beyond the first or the last
    /// row the nearest spacing is continued.
    func position(of value: Double) -> Double {
        switch axis {
        case .linearFrequency(let count, let nyquist):
            guard count > 1, nyquist > 0 else { return 0.5 }
            return value / nyquist * Double(count - 1) + 0.5
        case .mel(let centers):
            return Self.position(of: value, in: centers)
        case .tempo(let tempi):
            return Self.position(of: value, in: tempi)
        case .constantQ(let minimum, let binsPerOctave, _):
            guard minimum > 0, value > 0 else { return 0 }
            return log2(value / minimum) * Double(max(binsPerOctave, 1)) + 0.5
        case .lags(_, let rate), .quefrency(_, let rate):
            return rate > 0 ? value * rate + 0.5 : 0.5
        case .pitchClasses, .indices:
            return value + 0.5
        }
    }

    /// The value at a row position: the inverse of ``position(of:)``.
    func value(at position: Double) -> Double {
        switch axis {
        case .linearFrequency(let count, let nyquist):
            guard count > 1 else { return 0 }
            return (position - 0.5) / Double(count - 1) * nyquist
        case .mel(let centers):
            return Self.value(at: position, in: centers)
        case .tempo(let tempi):
            return Self.value(at: position, in: tempi)
        case .constantQ(let minimum, let binsPerOctave, _):
            return minimum * exp2((position - 0.5) / Double(max(binsPerOctave, 1)))
        case .lags(_, let rate), .quefrency(_, let rate):
            return rate > 0 ? (position - 0.5) / rate : 0
        case .pitchClasses, .indices:
            return position - 0.5
        }
    }

    /// The values at the two ends of the axis, in rising order. For rows that are evenly
    /// spaced in hertz these are 0 Hz and the Nyquist frequency, which is where such an axis
    /// ends; for every other axis they are the outer edges of the first and the last row.
    var fullRange: ClosedRange<Double> {
        if case .linearFrequency(_, let nyquist) = axis { return 0 ... max(nyquist, 0) }
        let first = value(at: 0), last = value(at: Double(axis.rowCount))
        return ClosedRange.ordered(first, last) ?? 0 ... 0
    }

    /// The row positions at the two ends of a range of values, in rising order and inside the
    /// axis: what a renderer is given for a feed it draws bin for bin. `nil` for a range that
    /// covers no row.
    func rows(for range: ClosedRange<Double>) -> ClosedRange<Double>? {
        let count = Double(axis.rowCount)
        guard count > 0, let positions = ClosedRange.ordered(position(of: range.lowerBound), position(of: range.upperBound)) else { return nil }
        let low = min(max(positions.lowerBound, 0), count), high = min(max(positions.upperBound, 0), count)
        return high > low ? low ... high : nil
    }

    // MARK: Tables

    /// The position of `value` among rows whose values are `table`, rising or falling.
    static func position(of value: Double, in table: [Double]) -> Double {
        guard let first = table.first, let last = table.last else { return 0 }
        guard table.count > 1, first != last else { return 0.5 + (value - first) }
        let rising = last > first
        // The segment whose two rows enclose the value, or the nearest one beyond the ends.
        var low = 0, high = table.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if rising ? table[middle] <= value : table[middle] >= value { low = middle } else { high = middle - 1 }
        }
        let from = table[low], to = table[low + 1]
        guard to != from else { return Double(low) + 0.5 }
        return Double(low) + 0.5 + (value - from) / (to - from)
    }

    /// The value at `position` among rows whose values are `table`.
    static func value(at position: Double, in table: [Double]) -> Double {
        guard let first = table.first else { return 0 }
        guard table.count > 1 else { return first + (position - 0.5) }
        let offset = position - 0.5
        let segment = min(max(Int(offset.rounded(.down)), 0), table.count - 2)
        return table[segment] + (offset - Double(segment)) * (table[segment + 1] - table[segment])
    }
}

/// Where a value of a feed's axis sits on the height of a view: 0 at the bottom edge, 1 at
/// the top. It follows the picture a heat-map renderer draws: rows evenly spaced in hertz are
/// laid out by the frequency scale between the two ends of the visible range; every other
/// axis is drawn bin for bin, each row a cell of the same height.
///
/// An immutable value, usable on any thread.
struct RowLayout: Equatable, Sendable {
    let mapping: RowAxisMapping
    let scale: AnyFrequencyScale
    /// The visible range in the unit of the axis; `nil` shows the whole axis.
    let range: ClosedRange<Double>?

    init(axis: FeedAxis, scale: AnyFrequencyScale, range: ClosedRange<Double>?) {
        mapping = RowAxisMapping(axis: axis)
        self.scale = scale
        self.range = range
    }

    var axis: FeedAxis { mapping.axis }

    /// True when the frequency scale lays the rows out: rows evenly spaced in hertz, and a
    /// scale that puts the top of the axis above its bottom. A scale that does not is
    /// replaced by the linear one, as the renderer does.
    private var usesScale: Bool {
        guard case .linearFrequency(let count, let nyquist) = axis, count > 1, nyquist > 0 else { return false }
        let low = scale.base.position(of: 0), high = scale.base.position(of: nyquist)
        return low.isFinite && high.isFinite && high > low
    }

    /// True when the view is linear in hertz: rows evenly spaced in hertz under the linear
    /// scale, or under a scale that cannot order the axis and is replaced by it.
    var isLinearInHertz: Bool {
        axis.isLinearFrequency && (scale.isLinear || !usesScale)
    }

    /// Where `value` sits on the axis the view is linear in: the scale's unit for rows the
    /// scale lays out, hertz for other rows evenly spaced in hertz, row positions otherwise.
    func coordinate(of value: Double) -> Double {
        if usesScale { return scale.base.position(of: value) }
        if axis.isLinearFrequency { return value }
        return mapping.position(of: value)
    }

    /// The inverse of ``coordinate(of:)``.
    func value(atCoordinate coordinate: Double) -> Double {
        if usesScale { return scale.base.frequency(at: coordinate) }
        if axis.isLinearFrequency { return coordinate }
        return mapping.value(at: coordinate)
    }

    /// The coordinates at the two ends of the whole axis.
    var fullCoordinates: ClosedRange<Double> {
        if axis.isLinearFrequency {
            let full = mapping.fullRange
            return ClosedRange.ordered(coordinate(of: full.lowerBound), coordinate(of: full.upperBound)) ?? 0 ... 0
        }
        return 0 ... Double(axis.rowCount)
    }

    /// The coordinates at the bottom and at the top edge of the view: the visible range,
    /// kept inside the axis; the whole axis when there is no range or it covers nothing.
    var visibleCoordinates: ClosedRange<Double> {
        let full = fullCoordinates
        guard let range, let wanted = ClosedRange.ordered(coordinate(of: range.lowerBound), coordinate(of: range.upperBound)) else { return full }
        let low = min(max(wanted.lowerBound, full.lowerBound), full.upperBound)
        let high = min(max(wanted.upperBound, full.lowerBound), full.upperBound)
        return high > low ? low ... high : full
    }

    /// The visible range in the unit of the axis, in rising order.
    var visibleRange: ClosedRange<Double> {
        let visible = visibleCoordinates
        return ClosedRange.ordered(value(atCoordinate: visible.lowerBound), value(atCoordinate: visible.upperBound)) ?? mapping.fullRange
    }

    /// Where `value` sits between the bottom edge (0) and the top edge (1). Values outside
    /// the visible range give numbers outside 0 … 1.
    func fraction(of value: Double) -> Double {
        let visible = visibleCoordinates
        let height = visible.upperBound - visible.lowerBound
        guard height > 0 else { return 0 }
        return (coordinate(of: value) - visible.lowerBound) / height
    }

    /// The value shown at `fraction` of the height, from the bottom.
    func value(atFraction fraction: Double) -> Double {
        let visible = visibleCoordinates
        return value(atCoordinate: visible.lowerBound + fraction * (visible.upperBound - visible.lowerBound))
    }
}
