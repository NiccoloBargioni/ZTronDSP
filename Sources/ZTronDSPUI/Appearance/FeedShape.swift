import Foundation
import ZTronDSPCore

/// What a view needs to know of a feed besides its data: what the rows are, how many columns
/// arrive per second, and how many the feed keeps. A pipeline writes these into the feed when
/// it is attached (ENV-4); a view reads them from there.
///
/// An immutable value, usable on any thread.
struct FeedShape: Equatable, Sendable {
    /// What the rows are; `nil` for a waveform, and for a feed no pipeline writes yet.
    var axis: FeedAxis?
    /// Columns, or pairs, per second; `nil` until a pipeline writes the feed inside a
    /// spectral scope.
    var columnRate: Double?
    /// Columns, or pairs, the feed keeps.
    var history: Int

    /// The seconds the whole history spans, when the rate is known.
    var historySpan: Double? {
        columnRate.map { Double(max(history, 1)) / $0 }
    }
}

/// A feed of either kind, for the views that only label it.
///
/// An immutable value; the feeds are `Sendable`.
enum FeedReference: Equatable, Sendable {
    case heatmap(HeatmapFeed)
    case waveform(WaveformFeed)

    static func == (lhs: FeedReference, rhs: FeedReference) -> Bool {
        lhs.identity == rhs.identity
    }

    /// What tells this feed object from every other.
    var identity: ObjectIdentifier {
        switch self {
        case .heatmap(let feed): ObjectIdentifier(feed)
        case .waveform(let feed): ObjectIdentifier(feed)
        }
    }

    /// The feed's shape now. Reads the feed's record of its axis and its environment: a lock
    /// the writer never takes.
    var shape: FeedShape {
        switch self {
        case .heatmap(let feed):
            FeedShape(axis: feed.axis, columnRate: Self.rate(feed.environment), history: feed.history)
        case .waveform(let feed):
            FeedShape(axis: nil, columnRate: Self.rate(feed.environment), history: feed.history)
        }
    }

    var isLive: Bool {
        switch self {
        case .heatmap(let feed): feed.isLive
        case .waveform(let feed): feed.isLive
        }
    }

    func observeLiveness(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> FeedObservation {
        switch self {
        case .heatmap(let feed): feed.onLivenessChange(handler)
        case .waveform(let feed): feed.onLivenessChange(handler)
        }
    }

    private static func rate(_ environment: DSPEnvironment?) -> Double? {
        guard let rate = environment?.featureRate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }
}
