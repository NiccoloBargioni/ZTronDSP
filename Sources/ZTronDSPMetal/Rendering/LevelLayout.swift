import Foundation

/// Where the reduced levels of a row of entries sit when they are stored one after another:
/// level 0 is the entries themselves, and level `k + 1` holds one entry for every two of level
/// `k`, an entry without a partner being carried up alone, until one entry is left. A range of
/// level-0 entries is reduced exactly by walking up the levels, as a segment tree is queried.
///
/// The heat map stores the bins of a column this way, reduced by maximum (V-8); the waveform
/// stores the pairs of its ring this way, reduced by minimum and maximum (§8.2).
struct LevelLayout: Hashable, Sendable {
    /// Entries in each level, level 0 first.
    let counts: [Int]
    /// Where each level starts.
    let offsets: [Int]
    /// Entries in all levels together.
    let total: Int

    init(count: Int) {
        var counts = [max(count, 1)], offsets = [0]
        var total = counts[0]
        while let last = counts.last, last > 1 {
            offsets.append(total)
            counts.append((last + 1) / 2)
            total += (last + 1) / 2
        }
        self.counts = counts
        self.offsets = offsets
        self.total = total
    }
}

/// The largest and the smallest value a half-float texel holds. Values are clamped to this
/// range when they are uploaded, so a texel is never infinite (§7.5, row 23).
enum HalfFloat {
    static let largest: Float = 65_504

    /// Sets every value that is not a number to `replacement`. NUM-1 keeps such values out of
    /// a feed; one that arrives anyway must not reach a texel, where it has no colour.
    static func replaceNotANumber(_ values: UnsafeMutablePointer<Float>, count: Int, with replacement: Float) {
        var index = 0
        while index < count {
            if values[index].isNaN { values[index] = replacement }
            index += 1
        }
    }
}
