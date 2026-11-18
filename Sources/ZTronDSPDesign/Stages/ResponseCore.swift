import ZTronDSPCore

/// What a response stage resolves to at a sample rate (§6.3.3): the design its arguments
/// name. A response stage takes its design as its first argument, an IIR `FilterFamily` or
/// an FIR `FIRDesignMethod`, and resolves to the one or to the other.
///
/// An immutable value, usable on any thread.
public enum FilterDesign: Hashable, Sendable {
    /// An IIR filter: zeros, poles and gain, run as second-order sections.
    case iir(IIRDesign)
    /// An FIR filter: taps.
    case fir(FIRDesign)

    /// The IIR design, or `nil` for an FIR one. Usable on any thread.
    public var iir: IIRDesign? {
        if case .iir(let design) = self { return design }
        return nil
    }

    /// The FIR design, or `nil` for an IIR one. Usable on any thread.
    public var fir: FIRDesign? {
        if case .fir(let design) = self { return design }
        return nil
    }
}

/// What the four response stages share: the response, its edges as they were stated, the
/// design and the way its order or length was given. The stages are thin values around it.
struct ResponseCore: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case lowPass, highPass, bandPass, bandStop
    }

    /// How the size of the filter was given.
    enum Size: Hashable, Sendable {
        /// IIR: the order of the prototype.
        case order(Int)
        /// IIR: a roll-off, turned into an order (§6.3.4).
        case rollOff(RollOff, RollOffRounding)
        /// IIR or FIR: a tolerance scheme; the edges are those of the pass band, `stopband`
        /// those of the stop band.
        case scheme(stopband: [Frequency], maximumLoss: Amplification, minimumAttenuation: Amplification)
        /// FIR: the number of taps, with the width of the transition bands when it was stated.
        case length(Int, transition: Frequency?)
        /// FIR: a roll-off down to a stop-band attenuation (§6.3.4).
        case slope(RollOff, attenuation: Amplification)
    }

    let kind: Kind
    /// The `FilterFamily` or the `FIRDesignMethod`, boxed for comparison.
    let design: AnyStrategy
    let isFIR: Bool
    /// One edge for a low-pass or a high-pass, two for a band.
    let edges: [Frequency]
    let size: Size

    init(_ kind: Kind, family: some FilterFamily, edges: [Frequency], size: Size) {
        self.kind = kind
        self.design = AnyStrategy(family)
        self.isFIR = false
        self.edges = edges
        self.size = size
    }

    init(_ kind: Kind, method: some FIRDesignMethod, edges: [Frequency], size: Size) {
        self.kind = kind
        self.design = AnyStrategy(method)
        self.isFIR = true
        self.edges = edges
        self.size = size
    }

    private init(kind: Kind, design: AnyStrategy, isFIR: Bool, edges: [Frequency], size: Size) {
        self.kind = kind
        self.design = design
        self.isFIR = isFIR
        self.edges = edges
        self.size = size
    }

    private func response(_ hertz: [Double]) -> FilterResponse {
        switch kind {
        case .lowPass: .lowPass(cutoff: hertz[0])
        case .highPass: .highPass(cutoff: hertz[0])
        case .bandPass: .bandPass(from: hertz[0], to: hertz[1])
        case .bandStop: .bandStop(from: hertz[0], to: hertz[1])
        }
    }

    private static func hertz(_ frequencies: [Frequency], sampleRate: Double) throws(DSPError) -> [Double] {
        var result: [Double] = []
        for frequency in frequencies { result.append(try frequency.hertz(sampleRate: sampleRate)) }
        return result
    }

    // MARK: Resolution

    /// The design the stage's arguments name, at `sampleRate`.
    func resolve(sampleRate: Double) throws(DSPError) -> FilterDesign {
        let response = response(try Self.hertz(edges, sampleRate: sampleRate))
        if isFIR {
            guard let method = design.value(as: (any FIRDesignMethod).self) else {
                throw .invalidParameter(stage: .none, parameter: "method", reason: "the stage has no FIR design method")
            }
            return .fir(try fir(method, response, sampleRate: sampleRate))
        }
        guard let family = design.value(as: (any FilterFamily).self) else {
            throw .invalidParameter(stage: .none, parameter: "family", reason: "the stage has no filter family")
        }
        return .iir(try iir(family, response, sampleRate: sampleRate))
    }

    private func iir(_ family: some FilterFamily, _ response: FilterResponse, sampleRate: Double) throws(DSPError) -> IIRDesign {
        let domain = IIRDesign.Domain.digital(sampleRate: sampleRate)
        switch size {
        case .order(let order):
            return try IIRDesign(family, response, order: order, domain: domain)
        case .rollOff(let rollOff, let rounding):
            return try IIRDesign(family, response, rollOff: rollOff, rounding: rounding, domain: domain)
        case .scheme(let stopband, let maximumLoss, let minimumAttenuation):
            return try IIRDesign(family, passband: response, stopband: self.response(try Self.hertz(stopband, sampleRate: sampleRate)),
                                 maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, domain: domain)
        case .length, .slope:
            throw .invalidParameter(stage: .none, parameter: "family", reason: "a length is not a way to size an IIR filter")
        }
    }

    private func fir(_ method: some FIRDesignMethod, _ response: FilterResponse, sampleRate: Double) throws(DSPError) -> FIRDesign {
        switch size {
        case .length(let length, let transition):
            var width: Double?
            if let transition { width = try transition.hertz(sampleRate: sampleRate) }
            return try FIRDesign(method, response, length: length, transition: width, sampleRate: sampleRate)
        case .slope(let rollOff, let attenuation):
            return try FIRDesign(method, response, rollOff: rollOff, stopband: attenuation, sampleRate: sampleRate)
        case .scheme(let stopband, let maximumLoss, let minimumAttenuation):
            return try FIRDesign(method, passband: response, stopband: self.response(try Self.hertz(stopband, sampleRate: sampleRate)),
                                 maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, sampleRate: sampleRate)
        case .order, .rollOff:
            throw .invalidParameter(stage: .none, parameter: "method", reason: "an order is not a way to size an FIR filter")
        }
    }

    // MARK: As an element of a system

    func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        guard case .iir(let design) = try resolve(sampleRate: sampleRate) else {
            throw .invalidParameter(stage: .none, parameter: "method", reason: "an FIR design is not an element of an IIR system: put it in an FIRSystem, and run the two systems as two Filter stages")
        }
        return design.zeroPoleGain
    }

    func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        guard case .fir(let design) = try resolve(sampleRate: sampleRate) else {
            throw .invalidParameter(stage: .none, parameter: "family", reason: "an FIR system has no pole away from the origin, and an IIR design has them: give the stage an FIR method (.windowedSinc(), .leastSquares), or put it in an IIRSystem")
        }
        return design.taps
    }

    var dependsOnSampleRate: Bool {
        allFrequencies.contains { !$0.dependsOnSampleRate }
    }

    // MARK: Animation (ANI-2)

    /// Every frequency the stage states, in the order of its arguments: the edges, the
    /// stop-band edges of a tolerance scheme, the transition width.
    private var allFrequencies: [Frequency] {
        switch size {
        case .scheme(let stopband, _, _): edges + stopband
        case .length(_, let transition): edges + (transition.map { [$0] } ?? [])
        case .order, .rollOff, .slope: edges
        }
    }

    var parameters: [Double] { allFrequencies.map(\.animatableValue) }

    func replacingParameters(_ values: ArraySlice<Double>) -> ResponseCore {
        let current = allFrequencies
        guard values.count == current.count else { return self }
        let replaced = zip(current, values).map { $0.replacing(animatableValue: $1) }
        let newEdges = Array(replaced.prefix(edges.count))
        let rest = Array(replaced.dropFirst(edges.count))
        let newSize: Size
        switch size {
        case .scheme(_, let maximumLoss, let minimumAttenuation):
            newSize = .scheme(stopband: rest, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)
        case .length(let length, let transition):
            newSize = .length(length, transition: transition == nil ? nil : rest.first)
        case .order, .rollOff, .slope:
            newSize = size
        }
        return ResponseCore(kind: kind, design: design, isFIR: isFIR, edges: newEdges, size: newSize)
    }

    // MARK: Lowering

    /// Checks the edges against the environment at the stage's position (ENV-2, O-16),
    /// designs the filter there, and emits the cascade or the taps.
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let isScheme: Bool
        if case .scheme(let stopband, _, _) = size {
            isScheme = true
            // The stop band of an FIR scheme may start at 0 Hz or end at the Nyquist frequency.
            for edge in stopband {
                _ = try StageValidation.frequency(edge, named: "stopband", in: context, allowingZero: isFIR, allowingNyquist: isFIR)
            }
        } else {
            isScheme = false
        }
        let names: [String] = isScheme ? ["passband", "passband"] : (edges.count == 1 ? ["cutoff"] : ["from", "to"])
        var hertz: [Double] = []
        for (edge, name) in zip(edges, names) {
            hertz.append(try StageValidation.frequency(edge, named: name, in: context))
        }
        if hertz.count == 2, hertz[0] >= hertz[1] {
            throw context.invalid(names[1], "the band runs from \(hertz[0]) Hz to \(hertz[1]) Hz; its lower edge must lie below its upper edge")
        }
        switch try resolve(sampleRate: context.environment.sampleRate) {
        case .iir(let design):
            try FilterLowering.emit(try design.secondOrderSections, into: &context)
        case .fir(let design):
            try FilterLowering.emit(taps: design.taps, into: &context)
        }
    }
}
