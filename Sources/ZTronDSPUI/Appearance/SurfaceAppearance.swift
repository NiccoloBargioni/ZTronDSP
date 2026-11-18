import Foundation
import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// A colour map whose type is not known where it is kept: what `.colorMap(_:)` puts into the
/// environment. Two are equal when the maps are of one type and equal, so an equal map
/// causes no update (WP-812).
///
/// An immutable value, usable on any thread.
struct AnyColorMap: Equatable, Sendable {
    let base: any ColorMap
    private let key: AnyStrategy

    init(_ map: some ColorMap) {
        base = map
        key = AnyStrategy(map)
    }

    static func == (lhs: AnyColorMap, rhs: AnyColorMap) -> Bool {
        lhs.key == rhs.key
    }
}

/// A frequency scale whose type is not known where it is kept: what `.frequencyScale(_:)`
/// puts into the environment. Equal when the scales are of one type and equal.
///
/// An immutable value, usable on any thread.
struct AnyFrequencyScale: Equatable, Sendable {
    let base: any FrequencyScale
    private let key: AnyStrategy

    init(_ scale: some FrequencyScale) {
        base = scale
        key = AnyStrategy(scale)
    }

    static func == (lhs: AnyFrequencyScale, rhs: AnyFrequencyScale) -> Bool {
        lhs.key == rhs.key
    }

    /// True for the scale that is linear in hertz.
    var isLinear: Bool { base is LinearFrequencyScale }
}

/// How a heat map is shown: every value the appearance modifiers of §8.1 set, resolved for
/// one component. `updateUIView` compares two of these and returns when they are equal (V-3).
///
/// An immutable value, usable on any thread.
struct HeatmapAppearance: Equatable, Sendable {
    /// `.colorMap(_:)`.
    var colorMap = AnyColorMap(ListedColorMap.viridis)
    /// `.valueRange(_:)`: the values shown as the first and as the last colour.
    var valueRange: ClosedRange<Float> = -90 ... 0
    /// `.frequencyScale(_:)`: warps rows that are evenly spaced in hertz, and no others (VC-5).
    var frequencyScale = AnyFrequencyScale(LinearFrequencyScale())
    /// `.frequencyRange(_:)`: what the bottom and the top edge show, in the unit of the
    /// feed's axis: hertz, beats per minute, seconds, or rows. `nil` shows the whole axis.
    var rowRange: ClosedRange<Double>?
    /// `.timeSpan(_:)`: the seconds across the width. `nil` shows the whole history.
    var timeSpan: Double?
    /// How the space between two rows is filled: the component decides, not a modifier.
    var rowInterpolation = RowInterpolation.linear
}

/// How a waveform is shown.
///
/// An immutable value, usable on any thread.
struct WaveformAppearance: Equatable, Sendable {
    /// `.amplitudeRange(_:)`: the amplitudes at the bottom and at the top edge.
    var amplitudeRange: ClosedRange<Float> = -1 ... 1
    /// `.timeSpan(_:)`: the seconds across the width. `nil` shows the whole history.
    var timeSpan: Double?
    /// The envelope's colour: the component takes it from the colour scheme.
    var fill = DisplayColor.white
}

/// What a Metal surface shows: a feed and how. This is what `updateUIView` compares (V-3):
/// two contents are equal when they name the same feed object and equal appearances.
///
/// An immutable value. The feeds are `Sendable`; the value is used on the main actor.
enum SurfaceContent: Equatable, Sendable {
    case heatmap(HeatmapFeed, HeatmapAppearance)
    case waveform(WaveformFeed, WaveformAppearance)

    static func == (lhs: SurfaceContent, rhs: SurfaceContent) -> Bool {
        switch (lhs, rhs) {
        case (.heatmap(let left, let leftAppearance), .heatmap(let right, let rightAppearance)):
            return left === right && leftAppearance == rightAppearance
        case (.waveform(let left, let leftAppearance), .waveform(let right, let rightAppearance)):
            return left === right && leftAppearance == rightAppearance
        default:
            return false
        }
    }

    /// The feed the content names.
    var feed: FeedReference {
        switch self {
        case .heatmap(let feed, _): .heatmap(feed)
        case .waveform(let feed, _): .waveform(feed)
        }
    }

    /// True when both name the same feed object.
    func hasSameFeed(as other: SurfaceContent) -> Bool {
        feed == other.feed
    }
}

// MARK: The animatable numbers (ANI-1)

/// The continuous values of an appearance, as the vector SwiftUI interpolates: value range,
/// time span, vertical range and amplitude range (ANI-1). Colour map and scale are discrete
/// and are not in it.
///
/// A time span or a vertical range may be left to the feed (`nil`: the whole history, the
/// whole axis), and what that stands for is known only once a pipeline writes the feed. The
/// last lane says which of the two the vector knows. While an animation runs between two
/// vectors that differ there, that lane holds neither of their codes, and the values it
/// speaks for are not interpolated: they change at once.
///
/// An immutable value, usable on any thread.
struct AppearanceVector: VectorArithmetic, Sendable {
    /// Lanes 0 and 1: the value range. 2: the time span. 3 and 4: the vertical range.
    /// 5 and 6: the amplitude range. 7: which of the time span (1) and the vertical range (2)
    /// are known, added up.
    var lanes: SIMD8<Double>

    init(lanes: SIMD8<Double> = .zero) {
        self.lanes = lanes
    }

    static var zero: AppearanceVector { AppearanceVector() }

    static func + (lhs: AppearanceVector, rhs: AppearanceVector) -> AppearanceVector {
        AppearanceVector(lanes: lhs.lanes + rhs.lanes)
    }

    static func - (lhs: AppearanceVector, rhs: AppearanceVector) -> AppearanceVector {
        AppearanceVector(lanes: lhs.lanes - rhs.lanes)
    }

    mutating func scale(by factor: Double) {
        lanes *= factor
    }

    var magnitudeSquared: Double {
        (lanes * lanes).sum()
    }

    enum Lane {
        static let valueLow = 0, valueHigh = 1, timeSpan = 2, rowLow = 3, rowHigh = 4, amplitudeLow = 5, amplitudeHigh = 6, known = 7
    }

    /// True for an animation frame in which the time span and the vertical range may be
    /// taken from the vector: both ends of the animation knew the same of them.
    func agreesOnWhatIsKnown(with rest: AppearanceVector) -> Bool {
        lanes[Lane.known] == rest.lanes[Lane.known]
    }
}

extension ClosedRange where Bound: FloatingPoint {
    /// The range between two numbers in either order; `nil` when one of them is no number.
    /// An interpolation that overshoots may hand the bounds over crossed.
    static func ordered(_ first: Bound, _ second: Bound) -> ClosedRange<Bound>? {
        guard first.isFinite, second.isFinite else { return nil }
        return Swift.min(first, second) ... Swift.max(first, second)
    }
}

extension HeatmapAppearance {
    /// The appearance's continuous values. `fullRows` and `fullSpan` are what `nil` stands
    /// for at the moment, the whole axis and the whole history, when the feed's shape is
    /// known.
    func vector(fullRows: ClosedRange<Double>?, fullSpan: Double?) -> AppearanceVector {
        typealias Lane = AppearanceVector.Lane
        var lanes = SIMD8<Double>.zero
        var known = 0.0
        lanes[Lane.valueLow] = Double(valueRange.lowerBound)
        lanes[Lane.valueHigh] = Double(valueRange.upperBound)
        if let span = timeSpan ?? fullSpan, span.isFinite {
            lanes[Lane.timeSpan] = span
            known += 1
        }
        if let rows = rowRange ?? fullRows, rows.lowerBound.isFinite, rows.upperBound.isFinite {
            lanes[Lane.rowLow] = rows.lowerBound
            lanes[Lane.rowHigh] = rows.upperBound
            known += 2
        }
        lanes[Lane.known] = known
        return AppearanceVector(lanes: lanes)
    }

    /// The appearance an animation frame shows: this one with the continuous values `shown`
    /// holds, where they differ from `rest`, the vector of this appearance itself. At rest the
    /// appearance is returned as it is, so a range that follows the feed keeps following it.
    func showing(_ shown: AppearanceVector, rest: AppearanceVector) -> HeatmapAppearance {
        guard shown.lanes != rest.lanes else { return self }
        typealias Lane = AppearanceVector.Lane
        var copy = self
        if shown.lanes[Lane.valueLow] != rest.lanes[Lane.valueLow] || shown.lanes[Lane.valueHigh] != rest.lanes[Lane.valueHigh],
           let range = ClosedRange.ordered(Float(shown.lanes[Lane.valueLow]), Float(shown.lanes[Lane.valueHigh])) {
            copy.valueRange = range
        }
        guard shown.agreesOnWhatIsKnown(with: rest) else { return copy }
        if shown.lanes[Lane.timeSpan] != rest.lanes[Lane.timeSpan], shown.lanes[Lane.timeSpan].isFinite, shown.lanes[Lane.timeSpan] > 0 {
            copy.timeSpan = shown.lanes[Lane.timeSpan]
        }
        if shown.lanes[Lane.rowLow] != rest.lanes[Lane.rowLow] || shown.lanes[Lane.rowHigh] != rest.lanes[Lane.rowHigh],
           let range = ClosedRange.ordered(shown.lanes[Lane.rowLow], shown.lanes[Lane.rowHigh]) {
            copy.rowRange = range
        }
        return copy
    }
}

extension WaveformAppearance {
    /// The appearance's continuous values; see ``HeatmapAppearance/vector(fullRows:fullSpan:)``.
    func vector(fullSpan: Double?) -> AppearanceVector {
        typealias Lane = AppearanceVector.Lane
        var lanes = SIMD8<Double>.zero
        if let span = timeSpan ?? fullSpan, span.isFinite {
            lanes[Lane.timeSpan] = span
            lanes[Lane.known] = 1
        }
        lanes[Lane.amplitudeLow] = Double(amplitudeRange.lowerBound)
        lanes[Lane.amplitudeHigh] = Double(amplitudeRange.upperBound)
        return AppearanceVector(lanes: lanes)
    }

    /// The appearance an animation frame shows; see ``HeatmapAppearance/showing(_:rest:)``.
    func showing(_ shown: AppearanceVector, rest: AppearanceVector) -> WaveformAppearance {
        guard shown.lanes != rest.lanes else { return self }
        typealias Lane = AppearanceVector.Lane
        var copy = self
        if shown.lanes[Lane.amplitudeLow] != rest.lanes[Lane.amplitudeLow] || shown.lanes[Lane.amplitudeHigh] != rest.lanes[Lane.amplitudeHigh],
           let range = ClosedRange.ordered(Float(shown.lanes[Lane.amplitudeLow]), Float(shown.lanes[Lane.amplitudeHigh])) {
            copy.amplitudeRange = range
        }
        guard shown.agreesOnWhatIsKnown(with: rest) else { return copy }
        if shown.lanes[Lane.timeSpan] != rest.lanes[Lane.timeSpan], shown.lanes[Lane.timeSpan].isFinite, shown.lanes[Lane.timeSpan] > 0 {
            copy.timeSpan = shown.lanes[Lane.timeSpan]
        }
        return copy
    }
}
