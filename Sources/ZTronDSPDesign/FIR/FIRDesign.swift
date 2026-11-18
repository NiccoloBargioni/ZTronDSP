import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// A linear-phase FIR filter designed from a method and a response (§6.3.3), with its length
/// given in one of three ways:
///
/// ```swift
/// // The length itself.
/// let a = try FIRDesign(.windowedSinc(window: .kaiser(beta: 8.6)), .lowPass(cutoff: 4_000), length: 255, sampleRate: 48_000)
/// // A tolerance scheme: the shortest filter the search finds that meets it.
/// let b = try FIRDesign(.windowedSinc(), passband: .lowPass(cutoff: 4_000), stopband: .lowPass(cutoff: 5_000),
///                       maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80), sampleRate: 48_000)
/// // A roll-off: the average slope across the transition band (§6.3.4).
/// let c = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), rollOff: .decibelsPerOctave(96),
///                       stopband: .decibels(80), sampleRate: 48_000)
/// ```
///
/// The design is computed when the value is created. An immutable value, usable on any
/// thread. Creating one is design maths: it allocates and belongs on a control or background
/// context.
public struct FIRDesign: Hashable, Sendable {
    /// The method, boxed for comparison. Usable on any thread.
    public let method: AnyStrategy
    /// The response the taps were designed for, with its edges in hertz: the frequencies at
    /// which the amplitude is one half. For a design from a tolerance scheme or a roll-off
    /// these lie in the transition bands, half the narrowest of them away from the pass-band
    /// edges. Usable on any thread.
    public let response: FilterResponse
    /// The sample rate the filter was designed for, in hertz. Usable on any thread.
    public let sampleRate: Double
    /// The taps, lowest delay first: `y[n] = Σ taps[k]·x[n − k]`. Symmetric. Usable on any
    /// thread.
    public let taps: [Double]

    /// The number of taps. Usable on any thread.
    public var length: Int { taps.count }

    /// The delay of the filter in samples, `(length − 1) / 2`: whole for an odd length. Usable
    /// on any thread.
    public var delay: Double { Double(taps.count - 1) / 2 }

    /// A filter of `length` taps.
    ///
    /// The edges of `response` are in hertz and are where the amplitude is one half.
    /// `transition` is the width of each transition band in hertz, for a method that takes
    /// one (see ``FIRDesignMethod``). Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an edge that does not lie strictly between
    ///   0 Hz and half the sample rate, band edges that are not ascending, a length the
    ///   method does not design (an even one where the response passes the Nyquist
    ///   frequency), or a sample rate that is not positive and finite.
    public init(
        _ method: some FIRDesignMethod, _ response: FilterResponse, length: Int, transition: Double? = nil, sampleRate: Double
    ) throws(DSPError) {
        self.method = AnyStrategy(method)
        self.response = response
        self.sampleRate = sampleRate
        taps = try Self.checked(method.taps(response, length: length, transition: transition, attenuation: nil, sampleRate: sampleRate), length: length)
    }

    /// The shortest filter the search finds that meets a tolerance scheme: within
    /// `maximumLoss` of unity gain, to either side, up to the pass-band edges, and at least
    /// `minimumAttenuation` down from the stop-band edges on.
    ///
    /// `passband` and `stopband` are the same kind of response and carry the edges of the
    /// pass band and of the stop band in hertz, ordered as for an IIR tolerance scheme
    /// (``FilterOrderStrategy``): pass < stop for a low-pass, stop < pass for a high-pass,
    /// the stop band outside the pass band for a band-pass and inside it for a band-stop. A
    /// stop-band edge may sit at 0 Hz or at the Nyquist frequency.
    ///
    /// One length serves every edge, so the narrowest of the transition bands decides it;
    /// across a wider one the response falls faster than asked. The search starts at the
    /// method's estimate (Kaiser's, by default), measures the result on a grid of sixteen
    /// points per tap, and asks for one decibel more until the scheme is met with a tenth of
    /// a decibel to spare. The length is odd, so the delay is a whole number of samples.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the responses differ in kind, an edge is
    ///   out of range or out of order, the tolerances are not positive numbers of decibels,
    ///   or the method cannot reach the scheme at any length (a window whose side lobes are
    ///   higher than the attenuation asked for); `DSPError.unsupportedConfiguration` when the
    ///   scheme needs more taps than a filter may have.
    public init(
        _ method: some FIRDesignMethod, passband: FilterResponse, stopband: FilterResponse,
        maximumLoss: Amplification, minimumAttenuation: Amplification, sampleRate: Double
    ) throws(DSPError) {
        let loss = try AnalogPrototype.decibels(maximumLoss, parameter: "maximumLoss")
        let attenuation = try AnalogPrototype.decibels(minimumAttenuation, parameter: "minimumAttenuation")
        let found = try Self.search(method, passband: passband, stopband: stopband, loss: loss, attenuation: attenuation, sampleRate: sampleRate)
        self.method = AnyStrategy(method)
        self.response = found.response
        self.sampleRate = sampleRate
        self.taps = found.taps
    }

    /// A filter whose steepness is given as a roll-off (§6.3.4): the *average* slope across
    /// each transition band, from the pass-band edge down to the stop-band attenuation.
    ///
    /// The edges of `response` are the pass-band edges. With an attenuation of `A` decibels
    /// and a slope of `s` decibels per octave the transition band is `A / s` octaves wide:
    /// the stop band starts at `f·2^(A/s)` above a pass band and at `f·2^(−A/s)` below one,
    /// and the filter is the one the tolerance scheme with those edges gives. The measured
    /// slope is therefore at least the one asked for; across the wider of two transition
    /// bands (the upper one of a band-pass) it is steeper. Control or background context;
    /// allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the slope is not positive and finite, and
    ///   when a stop-band edge would fall at or beyond the Nyquist frequency, or the two
    ///   skirts of a band-stop would meet: the reason names the smallest slope that fits.
    ///   Otherwise what the initialiser by tolerance scheme throws.
    public init(
        _ method: some FIRDesignMethod, _ response: FilterResponse, rollOff: RollOff, stopband: Amplification, sampleRate: Double
    ) throws(DSPError) {
        let attenuation = try AnalogPrototype.decibels(stopband, parameter: "stopband")
        let stop = try Self.stopbandEdges(of: response, rollOff: rollOff, attenuation: attenuation, sampleRate: sampleRate)
        let found = try Self.search(method, passband: response, stopband: response.replacingEdges(stop), loss: nil,
                                    attenuation: attenuation, sampleRate: sampleRate)
        self.method = AnyStrategy(method)
        self.response = found.response
        self.sampleRate = sampleRate
        self.taps = found.taps
    }

    // MARK: Roll-off (§6.3.4)

    /// The stop-band edges a roll-off puts beside the pass-band edges of `response`.
    static func stopbandEdges(
        of response: FilterResponse, rollOff: RollOff, attenuation: Double, sampleRate: Double
    ) throws(DSPError) -> [Double] {
        try IIRDesign.validate(sampleRate: sampleRate)
        let slope = rollOff.decibelsPerOctave
        guard slope.isFinite, slope > 0 else {
            throw .invalidParameter(stage: .none, parameter: "rollOff", reason: "a roll-off must be positive and finite, not \(rollOff)")
        }
        let nyquist = sampleRate / 2
        let pass = response.edges
        guard pass.allSatisfy({ $0.isFinite && $0 > 0 && $0 < nyquist }) else {
            throw .invalidParameter(stage: .none, parameter: response.isBand ? "response" : "cutoff", reason: "an edge must lie strictly between 0 Hz and the Nyquist frequency, \(nyquist) Hz, not \(pass)")
        }
        let ratio = pow(2, attenuation / slope)
        func tooShallow(_ octaves: Double, _ what: String) -> DSPError {
            let smallest = attenuation / octaves
            return .invalidParameter(stage: .none, parameter: "rollOff", reason: "at \(rollOff) the \(what): the smallest slope that fits is \(String(format: "%.2f", smallest)) dB per octave (\(String(format: "%.2f", smallest * RollOff.decibelsPerDecadePerOrder / RollOff.decibelsPerOctavePerOrder)) dB per decade), and the roll-off must exceed it")
        }
        switch response {
        case .lowPass:
            let stop = pass[0] * ratio
            guard stop < nyquist else {
                throw tooShallow(log2(nyquist / pass[0]), "stop band would start at \(stop) Hz, at or beyond the Nyquist frequency of \(nyquist) Hz")
            }
            return [stop]
        case .highPass:
            return [pass[0] / ratio]
        case .bandPass:
            guard pass[0] < pass[1] else {
                throw .invalidParameter(stage: .none, parameter: "response", reason: "the lower edge of a band must lie below its upper edge")
            }
            let upper = pass[1] * ratio
            guard upper < nyquist else {
                throw tooShallow(log2(nyquist / pass[1]), "upper stop band would start at \(upper) Hz, at or beyond the Nyquist frequency of \(nyquist) Hz")
            }
            return [pass[0] / ratio, upper]
        case .bandStop:
            guard pass[0] < pass[1] else {
                throw .invalidParameter(stage: .none, parameter: "response", reason: "the lower edge of a band must lie below its upper edge")
            }
            let lower = pass[0] * ratio
            let upper = pass[1] / ratio
            guard lower < upper else {
                throw tooShallow(log2(pass[1] / pass[0]) / 2, "two skirts would meet before the stop band is reached (\(lower) Hz from below, \(upper) Hz from above)")
            }
            return [lower, upper]
        }
    }

    // MARK: The search for a length

    /// The margin, in decibels, by which the search wants a scheme met on its grid: more than
    /// the grid can miss between two of its points.
    static let searchMargin = 0.1
    /// How many times the search asks for one decibel more before it gives up.
    static let searchLimit = 60

    /// - Parameter lengthStep: the length is one more than a multiple of this even number: 2
    ///   for an odd length, twice the factor for the filter of a rate change, whose delay is
    ///   then a whole number of samples at both rates.
    static func search(
        _ method: some FIRDesignMethod, passband: FilterResponse, stopband: FilterResponse, loss: Double?,
        attenuation: Double, sampleRate: Double, lengthStep: Int = 2
    ) throws(DSPError) -> (response: FilterResponse, taps: [Double]) {
        try IIRDesign.validate(sampleRate: sampleRate)
        guard passband.isSameKind(as: stopband) else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "the pass band is given as a \(passband.name) and the stop band as a \(stopband.name): both must be the same kind of response")
        }
        let nyquist = sampleRate / 2
        let pass = passband.edges
        let stop = stopband.edges
        guard pass.allSatisfy({ $0.isFinite && $0 > 0 && $0 < nyquist }) else {
            throw .invalidParameter(stage: .none, parameter: "passband", reason: "a pass-band edge must lie strictly between 0 Hz and the Nyquist frequency, \(nyquist) Hz, not \(pass)")
        }
        guard stop.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= nyquist }) else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "a stop-band edge must lie between 0 Hz and the Nyquist frequency, \(nyquist) Hz, not \(stop)")
        }
        let ordered: Bool
        switch passband {
        case .lowPass: ordered = pass[0] < stop[0]
        case .highPass: ordered = stop[0] < pass[0]
        case .bandPass: ordered = stop[0] < pass[0] && pass[0] < pass[1] && pass[1] < stop[1]
        case .bandStop: ordered = pass[0] < stop[0] && stop[0] < stop[1] && stop[1] < pass[1]
        }
        guard ordered else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "the edges of a \(passband.name) scheme are out of order: pass \(pass), stop \(stop)")
        }
        if let loss {
            guard attenuation > loss else {
                throw .invalidParameter(stage: .none, parameter: "minimumAttenuation", reason: "the minimum attenuation (\(attenuation) dB) must exceed the maximum loss (\(loss) dB)")
            }
        }

        // One length serves every edge: the narrowest transition band decides it, and each
        // half-amplitude edge sits half that width from its pass-band edge.
        let width = zip(pass, stop).map { abs($0 - $1) }.min() ?? 0
        let centres = zip(pass, stop).map { $0 + ($1 > $0 ? width / 2 : -width / 2) }
        let response = passband.replacingEdges(centres)

        // The bands the scheme speaks about, in units of the Nyquist frequency.
        let passBands: [(Double, Double)]
        let stopBands: [(Double, Double)]
        switch passband {
        case .lowPass: passBands = [(0, pass[0])]; stopBands = [(stop[0], nyquist)]
        case .highPass: passBands = [(pass[0], nyquist)]; stopBands = [(0, stop[0])]
        case .bandPass: passBands = [(pass[0], pass[1])]; stopBands = [(0, stop[0]), (stop[1], nyquist)]
        case .bandStop: passBands = [(0, pass[0]), (pass[1], nyquist)]; stopBands = [(stop[0], stop[1])]
        }

        let stopRipple = pow(10, -attenuation / 20)
        let passRipple = loss.map { 1 - pow(10, -$0 / 20) }
        let target = -20 * log10(min(stopRipple, passRipple ?? stopRipple))
        let spare = pow(10, -searchMargin / 20)

        var asked = max(target, 8)
        var reached = 0.0
        for _ in 0 ..< searchLimit {
            let estimate = try method.estimatedLength(transition: width, attenuation: .decibels(asked), sampleRate: sampleRate)
            let step = max(lengthStep, 2)
            let length = (max(estimate, 1) - 1 + step - 1) / step * step + 1
            guard length <= WindowedSincMethod.maximumLength else {
                throw .unsupportedConfiguration(reason: "the scheme needs about \(length) taps, above the longest supported filter of \(WindowedSincMethod.maximumLength): widen the transition band or relax the tolerances")
            }
            let taps = try checked(method.taps(response, length: length, transition: width, attenuation: .decibels(asked), sampleRate: sampleRate), length: length)
            let grid = try FIRMath.magnitudeGrid(of: taps)
            var worstStop = 0.0
            for band in stopBands {
                worstStop = max(worstStop, FIRMath.extremes(of: taps, grid: grid, from: band.0 / nyquist, to: band.1 / nyquist).greatest)
            }
            reached = -20 * log10(max(worstStop, .leastNormalMagnitude))
            var met = worstStop <= stopRipple * spare
            if met, let loss {
                // The same spare on the ripple of the pass band, to either side of unity.
                let least = 1 - (1 - pow(10, -loss / 20)) * spare
                let greatest = 1 + (pow(10, loss / 20) - 1) * spare
                for band in passBands {
                    let extremes = FIRMath.extremes(of: taps, grid: grid, from: band.0 / nyquist, to: band.1 / nyquist)
                    if extremes.least < least || extremes.greatest > greatest { met = false }
                }
            }
            if met { return (response, taps) }
            asked += 1
        }
        throw .invalidParameter(stage: .none, parameter: "minimumAttenuation", reason: "this method does not reach \(attenuation) dB of attenuation with a transition band of \(width) Hz at any length it was tried at (it stops near \(String(format: "%.1f", reached)) dB): a window with lower side lobes, or `.windowedSinc()` without one, does")
    }

    // MARK: Validation shared with the methods

    /// The edges of a response as fractions of the Nyquist frequency, checked.
    static func normalizedEdges(of response: FilterResponse, sampleRate: Double) throws(DSPError) -> [Double] {
        try IIRDesign.validate(sampleRate: sampleRate)
        let nyquist = sampleRate / 2
        let edges = response.edges
        let parameter = response.isBand ? "response" : "cutoff"
        guard edges.allSatisfy({ $0.isFinite && $0 > 0 && $0 < nyquist }) else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "an edge must lie strictly between 0 Hz and the Nyquist frequency, \(nyquist) Hz, not \(edges)")
        }
        if response.isBand {
            guard edges[0] < edges[1] else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "the lower edge of a band must lie below its upper edge")
            }
        }
        return edges.map { $0 / nyquist }
    }

    /// A transition width as a fraction of the Nyquist frequency, checked.
    static func normalizedWidth(_ transition: Double, sampleRate: Double) throws(DSPError) -> Double {
        try IIRDesign.validate(sampleRate: sampleRate)
        guard transition.isFinite, transition > 0, transition < sampleRate / 2 else {
            throw .invalidParameter(stage: .none, parameter: "transition", reason: "a transition band must be wider than 0 Hz and narrower than the whole band up to the Nyquist frequency, not \(transition) Hz")
        }
        return transition / (sampleRate / 2)
    }

    static func validate(length: Int) throws(DSPError) {
        guard length >= 1, length <= WindowedSincMethod.maximumLength else {
            throw .invalidParameter(stage: .none, parameter: "length", reason: "an FIR filter has between 1 and \(WindowedSincMethod.maximumLength) taps, not \(length)")
        }
    }

    /// What a method returned, held to what it was asked for.
    private static func checked(_ taps: [Double], length: Int) throws(DSPError) -> [Double] {
        guard taps.count == length, taps.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "method", reason: "the design method returned \(taps.count) taps where \(length) finite ones were due")
        }
        return taps
    }
}
