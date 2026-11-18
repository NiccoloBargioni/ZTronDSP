import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// An IIR filter designed from a family, a response and an order (§6.3.2), by the chain
///
///     analog low-pass prototype → frequency transformation → bilinear transform → section pairing
///
/// carried out on zeros and poles throughout: no polynomial is expanded on the way
/// (REAL-1). The steps after the prototype are skipped for an analog design, which stops at
/// the transformed prototype.
///
/// ```swift
/// let design = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain:
/// .digital(sampleRate: 48_000))
/// let sections = try design.secondOrderSections      // what the kernel runs
/// let analog = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)),
///                            .bandPass(from: 2_000, to: 3_000), order: 5, domain: .analog)
/// let coefficients = try analog.transferFunction     // for interchange
/// ```
///
/// The order can also be given as a roll-off (§6.3.4) or left to a tolerance scheme
/// (§6.3.2). The design is computed when the value is created; reading it afterwards costs
/// nothing but the conversion that is asked for.
///
/// Oracle: `scipy.signal.iirfilter`. An immutable value, usable on any thread. Creating one
/// is design maths: it allocates and belongs on a control or background context.
public struct IIRDesign: Hashable, Sendable {
    /// Where a design lives, and with it the unit of its edges.
    ///
    /// An immutable value, usable on any thread.
    public enum Domain: Hashable, Sendable {
        /// Continuous time. Edges are angular frequencies in radians per second.
        case analog
        /// Discrete time at `sampleRate`. Edges are in hertz, strictly between 0 and half the
        /// sample rate. With a sample rate of 1 they are in cycles per sample.
        case digital(sampleRate: Double)

        /// The plane the designed system is described in. Usable on any thread.
        public var system: SystemDomain {
            switch self {
            case .analog: .analog
            case .digital: .digital
            }
        }
    }

    /// The family, boxed for comparison. Usable on any thread.
    public let family: AnyStrategy
    /// The response that was designed, with its edges in the unit of ``domain``. For a
    /// design from a tolerance scheme these are the natural frequencies. Usable on any
    /// thread.
    public let response: FilterResponse
    /// The order of the prototype. A band-pass or band-stop filter has twice as many poles.
    /// Usable on any thread.
    public let order: Int
    /// Where the design lives. Usable on any thread.
    public let domain: Domain
    /// The design: the working form, exact to the accuracy of the prototype. Usable on any
    /// thread.
    public let zeroPoleGain: ZeroPoleGain

    /// A filter of the given family, response and order.
    ///
    /// For a band-pass or a band-stop, `order` is the order of the prototype; the filter has
    /// twice as many poles. A digital design pre-warps its edges, so they land exactly where
    /// they were asked for. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order the family does not design, an
    ///   edge that is not positive and finite (or, for a digital design, not below half the
    ///   sample rate), band edges that are not ascending, or a sample rate that is not
    ///   positive and finite; `DSPError.unsupportedConfiguration` beyond what a family
    ///   implements.
    public init(_ family: some FilterFamily, _ response: FilterResponse, order: Int, domain: Domain) throws(DSPError) {
        self.family = AnyStrategy(family)
        self.response = response
        self.order = order
        self.domain = domain
        zeroPoleGain = try Self.design(family, response, order: order, domain: domain)
    }

    /// A filter whose order is given as a roll-off (§6.3.4): one order is 20·log₁₀2 ≈ 6.02 dB
    /// per octave, 20 dB per decade.
    ///
    /// What the slope means depends on the design:
    ///
    /// - **Butterworth, Chebyshev I, Bessel, analog:** the asymptotic slope of the stop-band
    ///   skirt. Exact.
    /// - **The same, digital high-pass:** the slope towards 0 Hz. Exact.
    /// - **The same, digital low-pass, and the upper skirt of a digital band-pass:** the
    ///   slope well below the Nyquist frequency: within ±0.5 dB per octave in octaves that
    ///   end at or below a thirty-second of the sample rate. The bilinear transform puts the
    ///   zeros at the Nyquist frequency, so the skirt steepens towards it.
    /// - **Band-pass:** the slope of each skirt; the filter has twice the order.
    /// - **Band-stop:** a notch has no asymptotic skirt. The roll-off only sets the order of
    ///   the prototype.
    /// - **Chebyshev II, elliptic:** nominal. The order is the one whose all-pole
    ///   counterpart has that slope; the real transition is steeper and the stop band is
    ///   bounded by the stated attenuation, not by a slope.
    ///
    /// Control or background context; allocates.
    ///
    /// - Throws: what `RollOff.order(rounding:)` throws for a slope that is not a whole
    ///   number of orders under `rounding`, and what the initialiser by order throws.
    public init(
        _ family: some FilterFamily, _ response: FilterResponse, rollOff: RollOff,
        rounding: RollOffRounding = .exact(), domain: Domain
    ) throws(DSPError) {
        try self.init(family, response, order: try rollOff.order(rounding: rounding), domain: domain)
    }

    /// The filter of the lowest order that meets a tolerance scheme (§6.3.2): at most
    /// `maximumLoss` up to the pass-band edges and at least `minimumAttenuation` from the
    /// stop-band edges.
    ///
    /// The family's ``FilterFamily/orderStrategy`` returns the order and the natural
    /// frequencies
    /// (``FilterOrderStrategy/minimumOrder(passband:stopband:maximumLoss:minimumAttenuation:domain:)``
    /// states how the two responses are read). The filter is then designed with the member
    /// of the family that the scheme selects
    /// (``FilterFamily/fitted(maximumLoss:minimumAttenuation:)``):
    /// the ripple of a Chebyshev I or elliptic filter is the maximum loss, the stop-band
    /// attenuation of a Chebyshev II or elliptic filter is the minimum attenuation, whatever
    /// the family value was created with. This is the procedure of etk4j and SciPy
    /// (`buttord` then `butter`, and so on). ``order`` and ``response`` report what was
    /// found. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for a family without order estimation
    ///   (Bessel); otherwise what the strategy and the initialiser by order throw.
    public init(
        _ family: some FilterFamily, passband: FilterResponse, stopband: FilterResponse,
        maximumLoss: Amplification, minimumAttenuation: Amplification, domain: Domain
    ) throws(DSPError) {
        guard let strategy = family.orderStrategy else {
            throw .unsupportedConfiguration(reason: "this filter family has no order estimation: give an order or a roll-off instead of a tolerance scheme")
        }
        let estimate = try strategy.minimumOrder(
            passband: passband, stopband: stopband, maximumLoss: maximumLoss,
            minimumAttenuation: minimumAttenuation, domain: domain)
        try self.init(family.fitted(maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation),
                      estimate.response, order: estimate.order, domain: domain)
    }

    /// The coefficient form, expanded from the zeros and poles: for interchange and for
    /// parity with etk4j, not for running (§6.3.1). Control or background context;
    /// allocates.
    public var transferFunction: TransferFunction {
        get throws(DSPError) { try zeroPoleGain.transferFunction() }
    }

    /// The cascade the run-time kernel takes, paired by the nearest rule with the poles
    /// closest to the unit circle last. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for an analog design.
    public var secondOrderSections: SecondOrderSections {
        get throws(DSPError) { try zeroPoleGain.secondOrderSections() }
    }

    // MARK: Internals

    static func validate(sampleRate: Double) throws(DSPError) {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
    }

    private static func design(
        _ family: some FilterFamily, _ response: FilterResponse, order: Int, domain: Domain
    ) throws(DSPError) -> ZeroPoleGain {
        var edges = response.edges
        let parameter = response.isBand ? "response" : "cutoff"
        switch domain {
        case .analog:
            guard edges.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "an analog edge must be a positive, finite angular frequency, not \(edges)")
            }
        case .digital(let sampleRate):
            try validate(sampleRate: sampleRate)
            guard edges.allSatisfy({ $0.isFinite && $0 > 0 && $0 < sampleRate / 2 }) else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "a digital edge must lie strictly between 0 Hz and the Nyquist frequency, \(sampleRate / 2) Hz, not \(edges)")
            }
            // Pre-warp onto the analog axis of an internal sample rate of 2, the oracle's
            // normalisation: 2·fs·tan(π·f/fs) with the edge as a fraction of Nyquist.
            edges = edges.map { 4 * tan(Double.pi * (2 * $0 / sampleRate) / 2) }
        }
        if response.isBand {
            guard edges[0] < edges[1] else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "the lower edge of a band must lie below its upper edge")
            }
        }

        let transformation: FrequencyTransformation
        switch response {
        case .lowPass: transformation = .lowPass(cutoff: edges[0])
        case .highPass: transformation = .highPass(cutoff: edges[0])
        case .bandPass: transformation = .bandPass(center: (edges[0] * edges[1]).squareRoot(), bandwidth: edges[1] - edges[0])
        case .bandStop: transformation = .bandStop(center: (edges[0] * edges[1]).squareRoot(), bandwidth: edges[1] - edges[0])
        }

        let analog = try family.prototype(order: order).transformed(by: transformation)
        switch domain {
        case .analog: return analog
        case .digital: return try analog.bilinear(sampleRate: 2)
        }
    }
}
