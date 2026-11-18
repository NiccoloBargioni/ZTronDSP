import Foundation
import ZTronDSPCore

/// One mark of an axis: where it sits along the axis, from 0 at its start (the bottom of a
/// vertical axis, the left of a horizontal one) to 1 at its end, and what it says.
///
/// An immutable value, usable on any thread.
struct AxisTick: Equatable, Sendable {
    var fraction: Double
    var label: String
}

/// Chooses the marks of an axis: round values of the feed's own unit, placed where the
/// picture shows them (VC-5), and no more of them than the axis has room for.
///
/// Pure functions on values; usable on any thread. They run when an axis is laid out, never
/// per frame.
enum AxisTicks {
    /// The marks of a vertical axis.
    ///
    /// - Parameter maximumCount: how many labels the height has room for.
    static func rows(_ layout: RowLayout, maximumCount: Int) -> [AxisTick] {
        let axis = layout.axis
        guard axis.rowCount > 0, maximumCount > 0 else { return [] }
        var ticks: [AxisTick]
        if axis == .pitchClasses {
            ticks = FeedAxis.pitchClassNames.enumerated().map { AxisTick(fraction: layout.fraction(of: Double($0.offset)), label: $0.element) }
        } else {
            let visible = layout.visibleRange
            let values = axis.unit == .hertz && !layout.isLinearInHertz
                ? decades(in: visible)
                : steps(in: visible, count: maximumCount)
            ticks = values.map { AxisTick(fraction: layout.fraction(of: $0), label: label($0, unit: axis.unit)) }
        }
        return thinned(ticks, maximumCount: maximumCount)
    }

    /// The marks of a time axis that shows `span` seconds, the present at its end: 0 at the
    /// right edge, and the seconds before it to the left.
    static func time(span: Double, maximumCount: Int) -> [AxisTick] {
        guard span.isFinite, span > 0, maximumCount > 0 else { return [] }
        let step = niceStep(span / Double(maximumCount))
        var ticks: [AxisTick] = []
        var index = 0
        while Double(index) * step <= span * (1 + 1e-9), index < 1_000 {
            let seconds = Double(index) * step
            ticks.append(AxisTick(fraction: 1 - seconds / span, label: index == 0 ? "0" : "−" + label(seconds, unit: .seconds)))
            index += 1
        }
        return thinned(ticks, maximumCount: maximumCount)
    }

    /// The smallest of 1, 2 and 5 times a power of ten that is not below `rough`.
    static func niceStep(_ rough: Double) -> Double {
        guard rough.isFinite, rough > 0 else { return 1 }
        let power = pow(10, (log10(rough)).rounded(.down))
        let share = rough / power
        if share <= 1 { return power }
        if share <= 2 { return 2 * power }
        if share <= 5 { return 5 * power }
        return 10 * power
    }

    /// Evenly spaced round values inside `range`, about `count` of them.
    static func steps(in range: ClosedRange<Double>, count: Int) -> [Double] {
        let width = range.upperBound - range.lowerBound
        guard width.isFinite, width > 0, count > 0 else { return [] }
        let step = niceStep(width / Double(count))
        var values: [Double] = []
        var value = (range.lowerBound / step).rounded(.up) * step
        while value <= range.upperBound + step * 1e-9, values.count < 1_000 {
            // Whole steps, without the dust of repeated addition; no "-0".
            values.append((value / step).rounded() * step + 0)
            value += step
        }
        return values
    }

    /// 1, 2 and 5 times the powers of ten inside `range`: the round values of an axis that is
    /// not linear in its unit. At most four decades below the top of the range are looked at.
    static func decades(in range: ClosedRange<Double>) -> [Double] {
        guard range.upperBound.isFinite, range.upperBound > 0 else { return [] }
        let low = max(range.lowerBound, range.upperBound * 1e-4)
        var values: [Double] = []
        var power = pow(10, log10(low).rounded(.down))
        while power <= range.upperBound, values.count < 64 {
            for factor in [1.0, 2, 5] where factor * power >= low * (1 - 1e-9) && factor * power <= range.upperBound * (1 + 1e-9) {
                values.append(factor * power)
            }
            power *= 10
        }
        return values
    }

    /// What a value reads as in its unit: `440`, `2.5k`, `120`, `5 ms`, `1.5 s`.
    static func label(_ value: Double, unit: FeedAxis.Unit) -> String {
        switch unit {
        case .hertz:
            return abs(value) >= 1_000 ? number(value / 1_000) + "k" : number(value)
        case .seconds:
            return abs(value) < 1 && value != 0 ? number(value * 1_000) + " ms" : number(value) + " s"
        case .beatsPerMinute, .index:
            return number(value)
        case .pitchClass:
            let names = FeedAxis.pitchClassNames
            let index = Int(value.rounded())
            return names.indices.contains(index) ? names[index] : number(value)
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%g", (value * 1e6).rounded() / 1e6)
    }

    /// The marks inside the axis, from its start to its end, without those that would sit
    /// closer to the one before than the axis has room for.
    private static func thinned(_ ticks: [AxisTick], maximumCount: Int) -> [AxisTick] {
        let spacing = 1 / Double(max(maximumCount, 1))
        var kept: [AxisTick] = []
        for tick in ticks.sorted(by: { $0.fraction < $1.fraction }) where tick.fraction >= -1e-9 && tick.fraction <= 1 + 1e-9 {
            if let last = kept.last, tick.fraction - last.fraction < spacing * 0.999 { continue }
            kept.append(AxisTick(fraction: min(max(tick.fraction, 0), 1), label: tick.label))
        }
        return kept
    }
}
