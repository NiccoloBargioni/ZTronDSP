/// The sort-based oracle of the median filters (WP-529): for every value, the values around
/// it are laid out, sorted, and the middle one is taken. It is slow and obviously right, which
/// is what the selection networks on CPU lanes and on the GPU are held against.
///
/// Edges are reflected with the edge value repeated, `x[−k] = x[k − 1]` (§6.1): a line reads
/// `… c b a | a b c d | d c b …`, as often as a wide kernel needs it.
///
/// Values are ordered as the minimum and maximum of IEEE 754-2019 order them, which is what
/// the lane exchange follows: −0 lies below +0. A value that is not a number is sorted to an
/// end by its sign; a filter is not required to agree with the oracle on such input (NUM-1
/// keeps it out of every spectrum).
///
/// Plain functions, usable on any thread but the analysis thread: `reflected(_:count:)` does
/// not allocate, and the others allocate as they copy and sort.
public enum MedianOracle {
    /// The direction a median is taken along: a value, usable on any thread; it does not allocate.
    public enum Axis: Hashable, Sendable {
        /// Across frames: the same bin of the frames before and after.
        case time
        /// Across bins: the neighbouring bins of the same frame.
        case frequency
    }

    /// The position in `0 ..< count` that `index` stands for on a line reflected at both
    /// ends, the edge value repeated. 0 for a line without values.
    public static func reflected(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let period = 2 * count
        let wrapped = ((index % period) + period) % period
        return wrapped < count ? wrapped : period - 1 - wrapped
    }

    /// The middle value of `values` once they are sorted; of an even number, the lower of the
    /// two in the middle. NaN for no values at all.
    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted { $0.bitPattern != $1.bitPattern && $0.isTotallyOrdered(belowOrEqualTo: $1) }
        return sorted[(values.count - 1) / 2]
    }

    /// The median filter of a whole spectrogram: every value replaced by the median of the
    /// `kernel` values centred on it along `axis`.
    ///
    /// - Parameters:
    ///   - values: `rowCount` values per frame, frame after frame.
    ///   - rowCount: values per frame: the bins.
    ///   - kernel: how many values a median is taken over: odd, at least 1.
    ///   - axis: `.time` across frames, `.frequency` across bins.
    /// - Returns: as many values, in the same order; nothing for values that do not fill whole
    ///   frames, a row count below 1, or a kernel that is even or below 1.
    public static func filter(_ values: [Float], rowCount: Int, kernel: Int, along axis: Axis) -> [Float] {
        guard rowCount >= 1, values.count % rowCount == 0, kernel >= 1, kernel % 2 == 1 else { return [] }
        let frameCount = values.count / rowCount
        let reach = kernel / 2
        var result = values
        var window = [Float](repeating: 0, count: kernel)
        for frame in 0 ..< frameCount {
            for row in 0 ..< rowCount {
                for offset in -reach ... reach {
                    switch axis {
                    case .time: window[offset + reach] = values[reflected(frame + offset, count: frameCount) * rowCount + row]
                    case .frequency: window[offset + reach] = values[frame * rowCount + reflected(row + offset, count: rowCount)]
                    }
                }
                result[frame * rowCount + row] = median(window)
            }
        }
        return result
    }

    /// The running median of a stream of frames, as a filter along time gives it while the
    /// stream arrives: frame `t` of the result is the median, bin by bin, of the `kernel`
    /// frames that end at frame `t`. Where the stream has not yet given that many, the frames
    /// it has given are reflected at its start, the edge frame repeated, as often as it takes.
    ///
    /// From frame `kernel / 2` on, frame `t` of the result is frame `t − kernel / 2` of
    /// `filter(_:rowCount:kernel:along:)` along time: the centred median, known half a kernel
    /// late.
    ///
    /// - Returns: as many frames; nothing for frames of different lengths or a kernel that is
    ///   even or below 1.
    public static func running(_ frames: [[Float]], kernel: Int) -> [[Float]] {
        guard kernel >= 1, kernel % 2 == 1, let rowCount = frames.first?.count, frames.allSatisfy({ $0.count == rowCount }) else { return [] }
        var result = frames
        var window = [Float](repeating: 0, count: kernel)
        for newest in frames.indices {
            for row in 0 ..< rowCount {
                for lane in 0 ..< kernel {
                    window[lane] = frames[reflected(newest - lane, count: newest + 1)][row]
                }
                result[newest][row] = median(window)
            }
        }
        return result
    }
}
