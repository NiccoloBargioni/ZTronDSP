/// The checks stock stages make on their parameters when a plan is compiled, for stages
/// written outside the package (§5.11.4). Every check throws `DSPError.invalidParameter` with
/// the path of the stage being lowered, so an error names the stage that raised it, and
/// returns the value it checked, resolved, so a stage writes one line per parameter:
///
/// ```swift
/// func lower(_ context: inout LoweringContext) throws(DSPError) {
///     let cutoff = try StageValidation.frequency(cutoff, named: "cutoff", in: context)
///     let length = try StageValidation.transformLength(frame, named: "frame", in: context)
///     …
/// }
/// ```
///
/// Control context: the functions are pure and allocate only the error they throw.
public enum StageValidation {
    /// A frequency in hertz that lies strictly between 0 Hz and the Nyquist frequency at the
    /// stage's position (O-16, ENV-2). A filter edge at or beyond either end would not be the
    /// filter that was asked for, so it is rejected here and never becomes a silently aliased
    /// one.
    ///
    /// - Parameters:
    ///   - allowingZero: accept 0 Hz, for a parameter where it means something (the lower
    ///     end of a range).
    ///   - allowingNyquist: accept the Nyquist frequency itself (the upper end of a range).
    public static func frequency(
        _ frequency: Frequency, named parameter: String, in context: LoweringContext, allowingZero: Bool = false,
        allowingNyquist: Bool = false
    ) throws(DSPError) -> Double {
        let rate = context.environment.sampleRate
        let hertz: Double
        do throws(DSPError) {
            hertz = try frequency.hertz(sampleRate: rate)
        } catch {
            if case .invalidParameter(_, _, let reason) = error { throw context.invalid(parameter, reason) }
            throw error.inStage(context.path)
        }
        let nyquist = rate / 2
        guard hertz > 0 || (allowingZero && hertz == 0) else {
            throw context.invalid(parameter, "\(frequency) is \(hertz) Hz, which is not above 0 Hz")
        }
        guard hertz < nyquist || (allowingNyquist && hertz == nyquist) else {
            throw context.invalid(
                parameter, "\(frequency) is \(hertz) Hz, which is not below the Nyquist frequency of \(nyquist) Hz at this position")
        }
        return hertz
    }

    /// Two frequencies in hertz, both between 0 Hz and Nyquist, the first below the second:
    /// the edges of a band.
    public static func band(
        from lower: Frequency, to upper: Frequency, named parameter: String, in context: LoweringContext
    ) throws(DSPError) -> ClosedRange<Double> {
        let low = try frequency(lower, named: parameter, in: context)
        let high = try frequency(upper, named: parameter, in: context)
        guard low < high else {
            throw context.invalid(parameter, "the band runs from \(low) Hz to \(high) Hz; its lower edge must lie below its upper edge")
        }
        return low ... high
    }

    /// A transform length the fast transforms accept: `f · 2ⁿ` with `f` of 1, 3, 5 or 15 and
    /// `n ≥ 4` (O-17, §6.4.1). The error names the nearest lengths that are.
    public static func transformLength(_ length: Int, named parameter: String, in context: LoweringContext) throws(DSPError) -> Int {
        guard length >= 1 else { throw context.invalid(parameter, "a length of \(length) holds no sample") }
        guard DSP.isFastLength(length) else {
            let nearest = [DSP.previousFastLength(length), DSP.nextFastLength(length)].compactMap { $0 }.map(String.init)
            throw context.invalid(
                parameter, "\(length) is not a transform length (f·2ⁿ with f of 1, 3, 5 or 15 and n ≥ 4); the nearest are \(nearest.joined(separator: " and "))")
        }
        return length
    }

    /// A hop of at least one sample and at most one frame.
    public static func hop(_ hop: Int, frame: Int, named parameter: String, in context: LoweringContext) throws(DSPError) -> Int {
        guard hop >= 1, hop <= frame else {
            throw context.invalid(parameter, "a hop of \(hop) samples does not fit a frame of \(frame): it lies between 1 and the frame size")
        }
        return hop
    }

    /// A value inside a closed range.
    public static func value<T: Comparable>(
        _ value: T, named parameter: String, in range: ClosedRange<T>, context: LoweringContext
    ) throws(DSPError) -> T {
        guard range.contains(value) else {
            throw context.invalid(parameter, "\(value) lies outside \(range.lowerBound) … \(range.upperBound)")
        }
        return value
    }

    /// A value at or above a bound: a count, an order, a size.
    public static func value<T: Comparable>(
        _ value: T, named parameter: String, atLeast minimum: T, context: LoweringContext
    ) throws(DSPError) -> T {
        guard value >= minimum else { throw context.invalid(parameter, "\(value) is below \(minimum)") }
        return value
    }

    /// A number that is neither infinite nor NaN.
    public static func finite<T: BinaryFloatingPoint>(_ value: T, named parameter: String, in context: LoweringContext) throws(DSPError) -> T {
        guard value.isFinite else { throw context.invalid(parameter, "\(value) is not a finite number") }
        return value
    }
}
