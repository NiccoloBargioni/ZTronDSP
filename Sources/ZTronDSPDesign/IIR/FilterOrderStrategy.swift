import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// The answer to a tolerance scheme: the smallest order that meets it and the response to
/// design at that order. An immutable value, usable on any thread; it does not allocate.
public struct FilterOrderEstimate: Hashable, Sendable {
    /// The minimum order of the prototype. A band-pass or band-stop filter has twice as many
    /// poles. Usable on any thread.
    public let order: Int
    /// The response whose edges are the natural frequencies: hand it to `IIRDesign` together
    /// with ``order``. The edges are in the unit of the scheme. Usable on any thread.
    public let response: FilterResponse

    /// Usable on any thread.
    public init(order: Int, response: FilterResponse) {
        self.order = order
        self.response = response
    }
}

/// How a family turns a tolerance scheme into an order and a natural frequency (§5.3,
/// §6.3.2). It mirrors etk4j's `FilterOrderCalculationStrategy`: there is one per family,
/// except Bessel.
///
/// A conformer answers two questions about the family's normalised low-pass prototype, whose
/// pass band ends at 1; ``minimumOrder(passband:stopband:maximumLoss:minimumAttenuation:domain:)``
/// does the rest for all four responses and both domains, the same way for every family.
///
/// Conformers are immutable values, usable on any thread; the stock ones do not allocate, and
/// ``minimumOrder(passband:stopband:maximumLoss:minimumAttenuation:domain:)`` allocates.
/// Design maths: control or background context.
public protocol FilterOrderStrategy: Hashable, Sendable {
    /// The order, not rounded, at which the prototype loses at most `maximumLoss` up to
    /// frequency 1 and attenuates by at least `minimumAttenuation` from `selectivity` on.
    /// Usable on any thread; allocation-free.
    ///
    /// - Parameters:
    ///   - selectivity: The stop-band edge as a multiple of the pass-band edge; greater than
    ///     1.
    ///   - maximumLoss: The most the pass band may lose, up to frequency 1.
    ///   - minimumAttenuation: The least the stop band must attenuate, from `selectivity` on.
    /// - Throws: `DSPError.invalidParameter` when no order can meet the three values.
    func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double

    /// The natural frequency of the prototype of the whole order `order` that meets the
    /// scheme, as a multiple of its pass-band edge: the number to design the filter with.
    /// 1 for a family whose natural frequency *is* the pass-band edge.
    /// Usable on any thread; allocation-free.
    func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double
}

extension FilterOrderStrategy {
    /// The minimum order and the natural frequencies for a tolerance scheme.
    ///
    /// `passband` and `stopband` are the same kind of response. `passband` carries the
    /// edge, or the two edges, up to which the loss stays within `maximumLoss`; `stopband`
    /// carries the edge or edges from which the attenuation is at least
    /// `minimumAttenuation`:
    ///
    /// | Response | Order of the edges |
    /// |---|---|
    /// | low-pass | pass < stop |
    /// | high-pass | stop < pass |
    /// | band-pass | stop.from < pass.from < pass.to < stop.to |
    /// | band-stop | pass.from < stop.from < stop.to < pass.to |
    ///
    /// The edges are in radians per second for `.analog` and in hertz for
    /// `.digital(sampleRate:)`; the natural frequencies come back in the same unit. For a
    /// digital design the scheme is pre-warped, solved in the analog domain and mapped back.
    /// For a band-stop each pass-band edge is first moved to where the order is smallest, as
    /// the oracle does.
    ///
    /// Oracles: `scipy.signal.buttord`, `cheb1ord`, `cheb2ord`, `ellipord`. Control or
    /// background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the two responses differ in kind, the
    ///   edges are out of order or out of range, or the loss and the attenuation are not
    ///   positive numbers of decibels with the attenuation the larger;
    ///   `DSPError.unsupportedConfiguration` when the scheme needs an order above 512.
    public func minimumOrder(
        passband: FilterResponse, stopband: FilterResponse,
        maximumLoss: Amplification, minimumAttenuation: Amplification,
        domain: IIRDesign.Domain
    ) throws(DSPError) -> FilterOrderEstimate {
        guard passband.isSameKind(as: stopband) else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "the pass band is given as a \(passband.name) and the stop band as a \(stopband.name): both must be the same kind of response")
        }
        let loss = try AnalogPrototype.decibels(maximumLoss, parameter: "maximumLoss")
        let attenuation = try AnalogPrototype.decibels(minimumAttenuation, parameter: "minimumAttenuation")
        guard attenuation > loss else {
            throw .invalidParameter(stage: .none, parameter: "minimumAttenuation", reason: "the minimum attenuation (\(attenuation) dB) must exceed the maximum loss (\(loss) dB)")
        }

        // Edges on the analog axis: as given, or pre-warped (tan(π·f/fs), the oracle's scale).
        var pass = try FilterOrderMapping.analogEdges(passband.edges, parameter: "passband", domain: domain)
        let stop = try FilterOrderMapping.analogEdges(stopband.edges, parameter: "stopband", domain: domain)
        try FilterOrderMapping.validateOrder(of: passband, pass: pass, stop: stop)

        let selectivity: Double
        switch passband {
        case .lowPass:
            selectivity = stop[0] / pass[0]
        case .highPass:
            selectivity = pass[0] / stop[0]
        case .bandPass:
            selectivity = FilterOrderMapping.bandPassSelectivity(pass: pass, stop: stop)
        case .bandStop:
            // Move each pass-band edge to where the order is smallest, the lower one first.
            for index in 0 ..< 2 {
                let lower = index == 0 ? pass[0] : stop[1] + 1e-12
                let upper = index == 0 ? stop[0] - 1e-12 : pass[1]
                let fixed = pass
                pass[index] = try BoundedMinimizer.minimize(from: lower, to: upper) { (edge: Double) throws(DSPError) -> Double in
                    var trial = fixed
                    trial[index] = edge
                    return try self.fractionalOrder(
                        selectivity: FilterOrderMapping.bandStopSelectivity(pass: trial, stop: stop),
                        maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)
                }
            }
            selectivity = FilterOrderMapping.bandStopSelectivity(pass: pass, stop: stop)
        }

        let fractional = try fractionalOrder(selectivity: selectivity, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)
        guard fractional.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "no finite order meets this scheme")
        }
        let rounded = max(1, fractional.rounded(.up))
        guard rounded <= Double(AnalogPrototype.maximumOrder) else {
            throw .unsupportedConfiguration(reason: "the scheme needs order \(Int(min(rounded, 1e9))), above the largest supported order of \(AnalogPrototype.maximumOrder): widen the transition band or relax the tolerances")
        }
        let order = Int(rounded)
        let ratio = try naturalFrequency(order: order, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)
        guard ratio.isFinite, ratio > 0 else {
            throw .invalidParameter(stage: .none, parameter: "maximumLoss", reason: "the natural frequency of this scheme is not a positive, finite number")
        }

        // A family whose natural frequency is the pass-band edge gets its edges back as they
        // were given, to the bit. (Not for a band-stop: there the edges were moved above.)
        if ratio == 1, !passband.isBandStop {
            return FilterOrderEstimate(order: order, response: passband)
        }
        let natural = FilterOrderMapping.naturalEdges(of: passband, pass: pass, ratio: ratio)
        let edges = FilterOrderMapping.reportedEdges(natural, domain: domain)
        return FilterOrderEstimate(order: order, response: passband.replacingEdges(edges))
    }
}

/// The part of an order estimate that does not depend on the family: the mapping of a
/// scheme onto the normalised low-pass prototype and back.
enum FilterOrderMapping {
    /// The edges on the analog axis. Analog edges are used as they are; digital edges, in
    /// hertz, are pre-warped to `tan(π·f/fs)`.
    static func analogEdges(_ edges: [Double], parameter: String, domain: IIRDesign.Domain) throws(DSPError) -> [Double] {
        switch domain {
        case .analog:
            guard edges.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "an analog edge must be a positive, finite angular frequency")
            }
            return edges
        case .digital(let sampleRate):
            try IIRDesign.validate(sampleRate: sampleRate)
            guard edges.allSatisfy({ $0.isFinite && $0 > 0 && $0 < sampleRate / 2 }) else {
                throw .invalidParameter(stage: .none, parameter: parameter, reason: "a digital edge must lie strictly between 0 Hz and the Nyquist frequency, \(sampleRate / 2) Hz")
            }
            return edges.map { tan(Double.pi * (2 * $0 / sampleRate) / 2) }
        }
    }

    /// Edges back in the unit they were given in.
    static func reportedEdges(_ edges: [Double], domain: IIRDesign.Domain) -> [Double] {
        switch domain {
        case .analog: edges
        case .digital(let sampleRate): edges.map { atan($0) * 2 / Double.pi * sampleRate / 2 }
        }
    }

    static func validateOrder(of response: FilterResponse, pass: [Double], stop: [Double]) throws(DSPError) {
        let ordered: Bool
        let rule: String
        switch response {
        case .lowPass:
            ordered = pass[0] < stop[0]
            rule = "the pass-band edge must lie below the stop-band edge"
        case .highPass:
            ordered = stop[0] < pass[0]
            rule = "the stop-band edge must lie below the pass-band edge"
        case .bandPass:
            ordered = stop[0] < pass[0] && pass[0] < pass[1] && pass[1] < stop[1]
            rule = "the edges must be ordered stop.from < pass.from < pass.to < stop.to"
        case .bandStop:
            ordered = pass[0] < stop[0] && stop[0] < stop[1] && stop[1] < pass[1]
            rule = "the edges must be ordered pass.from < stop.from < stop.to < pass.to"
        }
        guard ordered else {
            throw .invalidParameter(stage: .none, parameter: "stopband", reason: "for a \(response.name) scheme \(rule)")
        }
    }

    /// The smaller of the two images of the stop-band edges under the band-pass mapping
    /// `ω → (ω² − p₀p₁) / (ω·(p₁ − p₀))`.
    static func bandPassSelectivity(pass: [Double], stop: [Double]) -> Double {
        stop.map { abs(($0 * $0 - pass[0] * pass[1]) / ($0 * (pass[0] - pass[1]))) }.min() ?? .infinity
    }

    /// The smaller of the two images of the stop-band edges under the band-stop mapping
    /// `ω → ω·(p₁ − p₀) / (p₀p₁ − ω²)`.
    static func bandStopSelectivity(pass: [Double], stop: [Double]) -> Double {
        stop.map { abs(($0 * (pass[0] - pass[1])) / ($0 * $0 - pass[0] * pass[1])) }.min() ?? .infinity
    }

    /// The natural frequencies: the images of the prototype's natural frequency `ratio`
    /// under the inverse of the response's frequency mapping. With a ratio of 1 they are the
    /// pass-band edges themselves, returned untouched.
    static func naturalEdges(of response: FilterResponse, pass: [Double], ratio: Double) -> [Double] {
        if ratio == 1 { return pass }
        switch response {
        case .lowPass:
            return [ratio * pass[0]]
        case .highPass:
            return [pass[0] / ratio]
        case .bandPass:
            let width = pass[1] - pass[0]
            let radical = (ratio * ratio / 4 * width * width + pass[0] * pass[1]).squareRoot()
            return [abs(-ratio * width / 2 + radical), abs(ratio * width / 2 + radical)].sorted()
        case .bandStop:
            let width = pass[1] - pass[0]
            let radical = (width * width + 4 * ratio * ratio * pass[0] * pass[1]).squareRoot()
            return [abs((width + radical) / (2 * ratio)), abs((width - radical) / (2 * ratio))].sorted()
        }
    }

    /// `10^(dB/10) − 1` for the loss and the attenuation of a scheme.
    static func powerRatios(_ maximumLoss: Amplification, _ minimumAttenuation: Amplification) throws(DSPError) -> (pass: Double, stop: Double) {
        let loss = try AnalogPrototype.decibels(maximumLoss, parameter: "maximumLoss")
        let attenuation = try AnalogPrototype.decibels(minimumAttenuation, parameter: "minimumAttenuation")
        return (pow(10, 0.1 * loss) - 1, pow(10, 0.1 * attenuation) - 1)
    }

    static func requireSelectivity(_ selectivity: Double) throws(DSPError) {
        guard selectivity.isFinite, selectivity > 1 else {
            throw .invalidParameter(stage: .none, parameter: "selectivity", reason: "the stop band must begin beyond the pass band: the selectivity is \(selectivity), not above 1")
        }
    }

    static func requireOrder(_ order: Int) throws(DSPError) {
        guard order >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a filter order must be at least 1, not \(order)")
        }
    }
}

/// Butterworth: `n = log((G_s − 1)/(G_p − 1)) / (2·log(selectivity))` with
/// `G = 10^(dB/10)`. The natural frequency is the −3 dB point that puts the loss exactly on
/// the pass-band edge. Oracle: `scipy.signal.buttord`. An immutable value, usable on any
/// thread; it does not allocate.
public struct ButterworthOrderStrategy: FilterOrderStrategy {
    /// Usable on any thread.
    public init() {}

    /// The order, not rounded, that the scheme needs at this selectivity. Usable on any thread.
    public func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireSelectivity(selectivity)
        let ratios = try FilterOrderMapping.powerRatios(maximumLoss, minimumAttenuation)
        return log10(ratios.stop / ratios.pass) / (2 * log10(selectivity))
    }

    /// The natural frequency as a multiple of the pass-band edge. Usable on any thread.
    public func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireOrder(order)
        let ratios = try FilterOrderMapping.powerRatios(maximumLoss, minimumAttenuation)
        return pow(ratios.pass, -1 / (2 * Double(order)))
    }
}

/// Chebyshev type I: `n = acosh(√((G_s − 1)/(G_p − 1))) / acosh(selectivity)`. The natural
/// frequency is the pass-band edge. Oracle: `scipy.signal.cheb1ord`. An immutable value,
/// usable on any thread; it does not allocate.
public struct Chebyshev1OrderStrategy: FilterOrderStrategy {
    /// Usable on any thread.
    public init() {}

    /// The order, not rounded, that the scheme needs at this selectivity. Usable on any thread.
    public func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireSelectivity(selectivity)
        let ratios = try FilterOrderMapping.powerRatios(maximumLoss, minimumAttenuation)
        return acosh((ratios.stop / ratios.pass).squareRoot()) / acosh(selectivity)
    }

    /// The natural frequency as a multiple of the pass-band edge. Usable on any thread.
    public func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireOrder(order)
        return 1
    }
}

/// Chebyshev type II: the order of type I; the natural frequency is the stop-band edge of
/// the prototype, `cosh(acosh(√((G_s − 1)/(G_p − 1))) / n)` times the pass-band edge.
/// Oracle: `scipy.signal.cheb2ord`. An immutable value, usable on any thread; it does not
/// allocate.
public struct Chebyshev2OrderStrategy: FilterOrderStrategy {
    /// Usable on any thread.
    public init() {}

    /// The order, not rounded, that the scheme needs at this selectivity. Usable on any thread.
    public func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireSelectivity(selectivity)
        let ratios = try FilterOrderMapping.powerRatios(maximumLoss, minimumAttenuation)
        return acosh((ratios.stop / ratios.pass).squareRoot()) / acosh(selectivity)
    }

    /// The natural frequency as a multiple of the pass-band edge. Usable on any thread.
    public func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireOrder(order)
        let ratios = try FilterOrderMapping.powerRatios(maximumLoss, minimumAttenuation)
        return cosh(acosh((ratios.stop / ratios.pass).squareRoot()) / Double(order))
    }
}

/// Elliptic: the degree equation solved for the order,
/// `n = K(k²)·K′(k₁²) / (K′(k²)·K(k₁²))` with `k = 1/selectivity` and
/// `k₁² = (G_p − 1)/(G_s − 1)`. The natural frequency is the pass-band edge. Oracle:
/// `scipy.signal.ellipord`. An immutable value, usable on any thread; it does not allocate.
public struct EllipticOrderStrategy: FilterOrderStrategy {
    /// Usable on any thread.
    public init() {}

    /// The order, not rounded, that the scheme needs at this selectivity. Usable on any thread.
    public func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireSelectivity(selectivity)
        let loss = try AnalogPrototype.decibels(maximumLoss, parameter: "maximumLoss")
        let attenuation = try AnalogPrototype.decibels(minimumAttenuation, parameter: "minimumAttenuation")
        let discrimination = AnalogPrototype.powerRatioMinusOne(loss) / AnalogPrototype.powerRatioMinusOne(attenuation)   // k₁²
        guard discrimination > 0, discrimination < 1 else {
            throw .invalidParameter(stage: .none, parameter: "minimumAttenuation", reason: "the minimum attenuation must exceed the maximum loss")
        }
        let k = 1 / selectivity
        let m = k * k
        let complement = (1 - k) * (1 + k)
        let selectivityRatio = EllipticFunctions.completeIntegral(m: m, complement: complement)
            / EllipticFunctions.completeIntegral(m: complement, complement: m)
        let discriminationRatio = EllipticFunctions.complementaryIntegral(m: discrimination)
            / EllipticFunctions.completeIntegral(m: discrimination)
        return selectivityRatio * discriminationRatio
    }

    /// The natural frequency as a multiple of the pass-band edge. Usable on any thread.
    public func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
        try FilterOrderMapping.requireOrder(order)
        return 1
    }
}

extension FilterOrderStrategy where Self == ButterworthOrderStrategy {
    /// The Butterworth estimate. Usable on any thread.
    public static var butterworth: ButterworthOrderStrategy { ButterworthOrderStrategy() }
}

extension FilterOrderStrategy where Self == Chebyshev1OrderStrategy {
    /// The Chebyshev type I estimate. Usable on any thread.
    public static var chebyshev1: Chebyshev1OrderStrategy { Chebyshev1OrderStrategy() }
}

extension FilterOrderStrategy where Self == Chebyshev2OrderStrategy {
    /// The Chebyshev type II estimate. Usable on any thread.
    public static var chebyshev2: Chebyshev2OrderStrategy { Chebyshev2OrderStrategy() }
}

extension FilterOrderStrategy where Self == EllipticOrderStrategy {
    /// The elliptic estimate. Usable on any thread.
    public static var elliptic: EllipticOrderStrategy { EllipticOrderStrategy() }
}
