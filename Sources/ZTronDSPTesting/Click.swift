/// The click test of the specification (CLICK-1, §5.5.4).
///
/// A full-scale 1 kHz sine at 48 kHz runs through a change. The largest sample-to-sample
/// difference of the output, during the change and for one block after it, must not exceed
/// 1.5 times the largest such difference in steady state on either side of the change.
///
/// Plain functions, usable on any thread: `largestStep` and `measure` do not allocate, and
/// `probeSignal` allocates the signal it returns.
public enum Click {
    /// The largest absolute difference between neighbouring samples of `samples[range]`.
    public static func largestStep(_ samples: [Float], in range: Range<Int>) -> Float {
        var largest: Float = 0
        var index = max(range.lowerBound, 0) + 1
        let end = min(range.upperBound, samples.count)
        while index < end {
            largest = max(largest, abs(samples[index] - samples[index - 1]))
            index += 1
        }
        return largest
    }

    /// The figures of one CLICK-1 measurement.
    ///
    /// An immutable value, usable on any thread; it does not allocate, but for ``description``.
    public struct Measurement: Sendable, Equatable, CustomStringConvertible {
        /// The largest step in steady state before the change.
        public let before: Float
        /// The largest step during the change and for one block after it.
        public let during: Float
        /// The largest step in steady state after the change.
        public let after: Float
        /// `during` over the larger of `before` and `after`.
        public var ratio: Float {
            let steady = max(before, after)
            return steady > 0 ? during / steady : (during > 0 ? .infinity : 0)
        }
        /// True when CLICK-1 holds.
        public var passes: Bool { ratio <= 1.5 }

        /// The three steps and their ratio against the limit of 1.5, in words.
        public var description: String {
            "largest step \(during) during the change against \(before) before and \(after) after (ratio \(ratio); the limit is 1.5)"
        }
    }

    /// Measures CLICK-1 on an output signal.
    ///
    /// - Parameters:
    ///   - output: what came out, from well before the change to well after it.
    ///   - change: the samples over which the change happens, plus the one block after it.
    ///   - settle: samples next to `change` that are left out of the steady-state regions on
    ///     both sides, so a filter's settling does not count as steady state.
    public static func measure(_ output: [Float], change: Range<Int>, settle: Int = 0) -> Measurement {
        Measurement(
            before: largestStep(output, in: 0 ..< max(change.lowerBound - settle, 0)),
            during: largestStep(output, in: max(change.lowerBound - 1, 0) ..< min(change.upperBound + 1, output.count)),
            after: largestStep(output, in: min(change.upperBound + settle, output.count) ..< output.count))
    }

    /// The signal CLICK-1 is measured with: a full-scale 1 kHz sine at 48 kHz.
    public static func probeSignal(count: Int) -> [Float] {
        TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: count)
    }
}
