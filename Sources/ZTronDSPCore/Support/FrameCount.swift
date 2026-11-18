/// Counts of frames that come out of a time and a rate (§9.3).
///
/// A ramp, a fade and a latency are times, and a plan counts them in frames at the rate of
/// the place where they are used. Both figures can come from outside the package: a stage
/// states its ramp and its latency, a source its rate, a kernel of the caller's own the ratio
/// by which it changes the rate. Their product need not be a count of frames at all, and the
/// conversion of such a number to an integer traps. So the product is never converted
/// blindly: where a plan is compiled it is either a count the place can hold, or the pipeline
/// is refused with a typed error that names the stage.
///
/// Control context: pure functions.
enum FrameCount {
    /// `seconds` at `rate` as a whole number of frames, the nearest, or `nil` when that is no
    /// count of frames (not a finite number, or a negative one) or more than `limit`.
    ///
    /// - Parameter limit: the most frames the place can count; at most 2⁵³, so that it is a
    ///   `Double` exactly.
    static func exact(_ seconds: Double, at rate: Double, atMost limit: Int) -> Int? {
        let frames = (seconds * rate).rounded()
        // A NaN fails both comparisons.
        guard frames >= 0, frames <= Double(limit) else { return nil }
        return Int(frames)
    }

    /// A ramp of `seconds` at `rate` as a kernel counts it, in 32 bits, or `nil` when it is
    /// no such count. A ramp that is over before it begins is no ramp.
    ///
    /// Asked where a kernel is made, and where two gains in a row would become one kernel:
    /// a ramp that cannot be counted stays with the stage that stated it (`PlanCompiler.merge`).
    static func ramp(_ seconds: Double, at rate: Double) -> UInt32? {
        exact(seconds < 0 ? 0 : seconds, at: rate, atMost: Int(UInt32.max)).flatMap { UInt32(exactly: $0) }
    }

    /// `seconds` at `rate` in whole frames, for a time the plan only runs for and holds
    /// nothing for: the settling time of what is new, which the specification caps at one
    /// second (SWAP-2, ACT-7), and the 10 ms of an exchange's fade. A count that is none, or
    /// negative, is no time at all, and one beyond what an `Int` holds stays at 2⁶²: neither
    /// can be reached from a pipeline that compiled, and neither traps.
    static func capped(_ seconds: Double, at rate: Double, rounding rule: FloatingPointRoundingRule = .up) -> Int {
        let frames = (seconds * rate).rounded(rule)
        guard frames > 0 else { return 0 }
        return frames < 0x1p62 ? Int(frames) : 1 << 62
    }
}
