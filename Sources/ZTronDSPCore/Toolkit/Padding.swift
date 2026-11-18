import Darwin

extension DSP {
    /// Whether the transform backend accepts a length: `f · 2ⁿ` with `f` in 1, 3, 5, 15 and
    /// `n ≥ 4` (§6.4.1). The answer is arithmetic. A transform setup is never created to find
    /// out: doing so crashes for some lengths (E-09).
    ///
    /// The same rule admits a length for the DCT behind the cepstral coefficients (§6.6).
    public static func isFastLength(_ length: Int) -> Bool {
        guard length >= 16 else { return false }
        let twos = length.trailingZeroBitCount
        guard twos >= 4 else { return false }
        let odd = length >> twos
        return odd == 1 || odd == 3 || odd == 5 || odd == 15
    }

    /// The smallest fast length at or above `length`; 16 for anything smaller.
    public static func nextFastLength(_ length: Int) -> Int {
        guard length > 16 else { return 16 }
        // The candidates are f · 2ⁿ for the four factors: take the smallest that reaches `length`.
        var best = Int.max
        for factor in [1, 3, 5, 15] {
            var candidate = factor * 16
            while candidate < length {
                let (doubled, overflow) = candidate.multipliedReportingOverflow(by: 2)
                if overflow { candidate = Int.max; break }
                candidate = doubled
            }
            best = min(best, candidate)
        }
        return best
    }

    /// The largest fast length at or below `length`, or `nil` below 16.
    public static func previousFastLength(_ length: Int) -> Int? {
        guard length >= 16 else { return nil }
        var best = 16
        for factor in [1, 3, 5, 15] {
            var candidate = factor * 16
            guard candidate <= length else { continue }
            while candidate <= length / 2 { candidate *= 2 }
            best = max(best, candidate)
        }
        return best
    }
}

/// Where the zeros go when a frame is padded (§6.12).
public enum ZeroPadding: Hashable, Sendable {
    /// After the samples.
    case trailing
    /// Split around the samples: `(count − n) / 2` zeros before (rounded down), the rest after.
    case centered
}

/// Pads `samples` with zeros to `count` elements. Finer bins when the result is transformed;
/// no new information (§6.12). A `count` at or below the current length returns the samples
/// unchanged. Allocates a new array; not for the analysis thread.
public func zeroPadded<Element: AdditiveArithmetic>(_ samples: [Element], to count: Int, placement: ZeroPadding = .trailing) -> [Element] {
    guard count > samples.count else { return samples }
    let leading = placement == .centered ? (count - samples.count) / 2 : 0
    var result = [Element](repeating: .zero, count: count)
    result.replaceSubrange(leading ..< leading + samples.count, with: samples)
    return result
}

/// Copies `count` samples into `destination` and fills the rest of its `paddedCount` elements
/// with zeros. `paddedCount` below `count` copies only what fits. Source and destination must
/// not overlap. Allocation-free; callable on the analysis thread.
@inlinable
public func zeroPad(
    _ source: UnsafePointer<Float>, count: Int, into destination: UnsafeMutablePointer<Float>, paddedCount: Int,
    placement: ZeroPadding = .trailing
) {
    guard paddedCount > 0 else { return }
    let copied = min(max(count, 0), paddedCount)
    let leading = placement == .centered ? (paddedCount - copied) / 2 : 0
    let stride = MemoryLayout<Float>.stride
    if leading > 0 { memset(destination, 0, leading * stride) }
    if copied > 0 { memcpy(destination + leading, source, copied * stride) }
    let trailing = paddedCount - leading - copied
    if trailing > 0 { memset(destination + leading + copied, 0, trailing * stride) }
}
