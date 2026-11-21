/// An immutable copy of a feed's history with its axis and the time of each column (WP-341):
/// what an export or an image is made from (§6.14, §8.2).
///
/// A snapshot is consistent: every column in it is one the writer finished, in order, even
/// when it was taken while the feed was being written. An immutable value, usable on any
/// thread. Taking or making one allocates its arrays.
public struct FeedSnapshot: Sendable, Hashable {
    /// What kind of feed the snapshot was taken from.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum Content: Sendable, Hashable {
        /// A `HeatmapFeed`: columns of `rowCount` values.
        case heatmap
        /// A `WaveformFeed`: columns of two values, a minimum and a maximum.
        case waveform
    }

    /// The kind of feed the snapshot was taken from.
    public let content: Content
    /// What the rows are; `nil` for a waveform, and for a feed that was never attached.
    public let axis: FeedAxis?
    /// The environment at the feed's `Emit`.
    public let environment: DSPEnvironment?
    /// Values per column.
    public let rowCount: Int
    /// The values, column after column, oldest first: column `c` is
    /// `values[c * rowCount ..< (c + 1) * rowCount]`.
    public let values: [Float]
    /// The time of each column, in seconds since the session started.
    public let times: [Double]

    /// A snapshot of values that did not come from a feed: for a test, a preview, an export.
    /// `values` holds `times.count` columns of `rowCount` values each. Any thread.
    public init(content: Content, axis: FeedAxis?, environment: DSPEnvironment?, rowCount: Int, values: [Float], times: [Double]) {
        self.content = content
        self.axis = axis
        self.environment = environment
        self.rowCount = max(rowCount, 0)
        self.values = values
        self.times = times
    }

    /// Columns in the snapshot.
    public var columnCount: Int { times.count }

    /// The values of one column. Empty for a column that does not exist.
    public func column(_ index: Int) -> ArraySlice<Float> {
        guard index >= 0, index < columnCount, rowCount > 0 else { return [] }
        return values[(index * rowCount) ..< ((index + 1) * rowCount)]
    }

    /// The values of one row across all columns, oldest first. Empty for a row that does not exist.
    /// It allocates the row it returns.
    public func row(_ index: Int) -> [Float] {
        guard index >= 0, index < rowCount else { return [] }
        return stride(from: index, to: values.count, by: rowCount).map { values[$0] }
    }

    /// The minima of a waveform's pairs, oldest first; empty for a heat map.
    public var minima: [Float] { content == .waveform ? row(0) : [] }

    /// The maxima of a waveform's pairs, oldest first; empty for a heat map.
    public var maxima: [Float] { content == .waveform ? row(1) : [] }

    /// The min / max pyramid of a waveform snapshot (§8.2). Empty for a heat map.
    public func pyramid() -> EnvelopePyramid {
        EnvelopePyramid(minima: minima, maxima: maxima)
    }
}

/// A waveform's envelope at every zoom: the (minimum, maximum) pairs, and the same pairs
/// reduced by two again and again until one is left (§8.2). A view that shows many pairs per
/// pixel samples the level whose pairs are about a pixel wide, so a peak is never missed and
/// no more is read than is drawn.
///
/// Level 0 is the pairs as given. A pair of level `k + 1` covers two pairs of level `k`: its
/// minimum is the smaller of their minima, its maximum the larger of their maxima; a last
/// pair without a partner is carried up alone.
///
/// An immutable value, usable on any thread. Building it is linear in the number of pairs and
/// allocates its levels.
public struct EnvelopePyramid: Sendable, Hashable {
    /// One level of the pyramid.
    ///
    /// An immutable value, usable on any thread; reading it does not allocate.
    public struct Level: Sendable, Hashable {
        /// The smallest sample under each pair.
        public let minima: [Float]
        /// The largest sample under each pair.
        public let maxima: [Float]
        /// Pairs of level 0 that one pair of this level covers: 1, 2, 4, …
        public let span: Int

        /// Pairs in the level.
        public var count: Int { minima.count }
    }

    /// The levels, finest first. Empty when there are no pairs.
    public let levels: [Level]

    /// The pyramid over pairs given as two arrays of one length; a longer array is cut to the
    /// shorter.
    public init(minima: [Float], maxima: [Float]) {
        let count = min(minima.count, maxima.count)
        guard count > 0 else {
            levels = []
            return
        }
        var built = [Level(minima: Array(minima[..<count]), maxima: Array(maxima[..<count]), span: 1)]
        while let last = built.last, last.count > 1 {
            let half = (last.count + 1) / 2
            var lows = [Float](repeating: 0, count: half), highs = [Float](repeating: 0, count: half)
            for index in 0 ..< half {
                let a = 2 * index, b = min(2 * index + 1, last.count - 1)
                lows[index] = min(last.minima[a], last.minima[b])
                highs[index] = max(last.maxima[a], last.maxima[b])
            }
            built.append(Level(minima: lows, maxima: highs, span: last.span * 2))
        }
        levels = built
    }

    /// The coarsest level whose pairs are no wider than `pairsPerPoint` pairs of level 0: the
    /// one to draw when that many pairs fall on one point of the display. `nil` for an empty
    /// pyramid.
    public func level(forPairsPerPoint pairsPerPoint: Double) -> Level? {
        guard !levels.isEmpty else { return nil }
        var chosen = 0
        while chosen + 1 < levels.count, Double(levels[chosen + 1].span) <= pairsPerPoint { chosen += 1 }
        return levels[chosen]
    }
}
