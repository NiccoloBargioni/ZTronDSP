import Foundation

/// What to do when a slope is not a whole number of filter orders (§6.3.4).
public enum RollOffRounding: Hashable, Sendable {
    /// Accept the slope only when it lies within `relativeTolerance` of a whole order;
    /// otherwise the request is an error. The default, with a tolerance of 2 %.
    case exact(relativeTolerance: Double = 0.02)
    /// Take the nearest whole order.
    case nearest
    /// Take the smallest whole order whose slope is at least the one requested (to within one
    /// part in a million, so that 6.0206 dB per octave is order 1).
    case up
}

/// The steepness of a filter's skirt: decibels per octave, decibels per decade, or the order
/// itself (§6.3.4). One order contributes 20·log₁₀2 ≈ 6.0206 dB per octave, 20 dB per decade.
///
/// What the slope means for a given design (exact, bounded or nominal) is stated in the table
/// of §6.3.4 and in the documentation of each filter. An immutable value, usable on any thread.
public struct RollOff: Hashable, Sendable, CustomStringConvertible {
    @usableFromInline
    enum Unit: Hashable, Sendable {
        case decibelsPerOctave
        case decibelsPerDecade
        case order
    }

    @usableFromInline let unit: Unit
    /// The number as it was stated.
    public let value: Double

    @usableFromInline
    init(unit: Unit, value: Double) {
        self.unit = unit
        self.value = value
    }

    /// The slope one filter order contributes, in decibels per octave: 20·log₁₀2.
    public static let decibelsPerOctavePerOrder = 20 * log10(2.0)
    /// The slope one filter order contributes, in decibels per decade.
    public static let decibelsPerDecadePerOrder = 20.0

    public static func decibelsPerOctave(_ slope: Double) -> RollOff { RollOff(unit: .decibelsPerOctave, value: slope) }
    public static func decibelsPerDecade(_ slope: Double) -> RollOff { RollOff(unit: .decibelsPerDecade, value: slope) }
    public static func order(_ order: Int) -> RollOff { RollOff(unit: .order, value: Double(order)) }

    /// The slope in decibels per octave.
    public var decibelsPerOctave: Double {
        switch unit {
        case .decibelsPerOctave: value
        case .decibelsPerDecade: value * Self.decibelsPerOctavePerOrder / Self.decibelsPerDecadePerOrder
        case .order: value * Self.decibelsPerOctavePerOrder
        }
    }

    /// The slope in decibels per decade.
    public var decibelsPerDecade: Double {
        switch unit {
        case .decibelsPerOctave: value * Self.decibelsPerDecadePerOrder / Self.decibelsPerOctavePerOrder
        case .decibelsPerDecade: value
        case .order: value * Self.decibelsPerDecadePerOrder
        }
    }

    /// The slope as a number of orders, not rounded.
    public var fractionalOrder: Double {
        switch unit {
        case .decibelsPerOctave: value / Self.decibelsPerOctavePerOrder
        case .decibelsPerDecade: value / Self.decibelsPerDecadePerOrder
        case .order: value
        }
    }

    /// The filter order for this slope.
    ///
    /// 12, 24, 48 and 96 dB per octave give 2, 4, 8 and 16. 25 dB per octave is an error under
    /// `.exact` and gives 5 under `.up`.
    ///
    /// - Throws: `DSPError.invalidParameter` when the slope is not positive and finite, when
    ///   it rounds to an order below 1, or, under `.exact`, when it is not within tolerance of
    ///   a whole order. The reason names the two nearest slopes that are.
    public func order(rounding: RollOffRounding = .exact()) throws(DSPError) -> Int {
        let orders = fractionalOrder
        guard orders.isFinite, orders > 0 else {
            throw .invalidParameter(stage: .none, parameter: "rollOff", reason: "a roll-off must be positive and finite, not \(self)")
        }
        guard orders < 4_096 else {
            throw .invalidParameter(stage: .none, parameter: "rollOff", reason: "\(self) asks for an order above 4 096")
        }
        let nearest = orders.rounded()
        let result: Double
        switch rounding {
        case .exact(let tolerance):
            guard nearest >= 1, abs(orders - nearest) <= tolerance * nearest else {
                let below = max(1, orders.rounded(.down))
                let above = max(1, orders.rounded(.up))
                let lower = String(format: "%.2f", below * Self.decibelsPerOctavePerOrder)
                let upper = String(format: "%.2f", above * Self.decibelsPerOctavePerOrder)
                throw .invalidParameter(
                    stage: .none, parameter: "rollOff",
                    reason: "\(self) is not a whole number of orders: the nearest slopes are \(lower) and \(upper) dB per octave (orders \(Int(below)) and \(Int(above))); pass a rounding of .nearest or .up to accept one")
            }
            result = nearest
        case .nearest:
            result = nearest
        case .up:
            // A slope within one part in a million of a whole order is that order, so the
            // usual rounded figure, 6.0206 dB per octave, is order 1 and not order 2.
            result = abs(orders - nearest) <= 1e-6 * max(1, nearest) ? nearest : orders.rounded(.up)
        }
        guard result >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "rollOff", reason: "\(self) is less than half an order: the smallest filter has order 1 (\(String(format: "%.2f", Self.decibelsPerOctavePerOrder)) dB per octave)")
        }
        return Int(result)
    }

    public var description: String {
        switch unit {
        case .decibelsPerOctave: "\(value) dB per octave"
        case .decibelsPerDecade: "\(value) dB per decade"
        case .order: "order \(Int(value))"
        }
    }
}
