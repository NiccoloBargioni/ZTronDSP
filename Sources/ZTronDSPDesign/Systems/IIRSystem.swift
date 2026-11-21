import ZTronDSPCore

/// The elements an `IIRSystem { }` block gathered, in order. What the builder passes around;
/// an app never names it. An immutable value, usable on any thread; the builder allocates it
/// as it gathers.
public struct IIRSystemContent: Hashable, Sendable {
    let elements: [AnyStrategy]
}

/// The result builder behind `IIRSystem { … }`: one element per line (§6.3.7), with `if`,
/// `if … else`, `switch`, `for … in` and `if #available` around them.
///
/// Its functions run where the system is described, on any thread, and may allocate the
/// content they return.
@resultBuilder
public enum IIRSystemBuilder {
    /// An element. Usable on any thread.
    public static func buildExpression(_ element: some IIRSystemElement) -> IIRSystemContent {
        IIRSystemContent(elements: [AnyStrategy(element)])
    }

    /// Unavailable: it exists for its diagnostic, which names the elements an `IIRSystem` holds and
    /// where the value belongs instead. Never called, being unavailable: no context runs it, and it
    /// allocates nothing.
    @available(*, unavailable, message: "An IIRSystem holds poles, zeros, sections, difference equations and the IIR forms of the response and equaliser stages (Pole, Zero, Section, DifferenceEquation, LowPass, HighPass, BandPass, BandStop, BandBoost, LowShelf, HighShelf): this value is none of them. Taps and LeastSquares belong in an FIRSystem; a smoother, a gain or a rate changer belongs in the pipeline, beside Filter(system).")
    public static func buildExpression<Value>(_ value: Value) -> IIRSystemContent {
        IIRSystemContent(elements: [])
    }

    /// The lines of a block, in order. Usable on any thread.
    public static func buildBlock(_ parts: IIRSystemContent...) -> IIRSystemContent {
        IIRSystemContent(elements: parts.flatMap(\.elements))
    }

    /// `if` without `else`. Usable on any thread.
    public static func buildOptional(_ part: IIRSystemContent?) -> IIRSystemContent {
        part ?? IIRSystemContent(elements: [])
    }

    /// `if … else` and `switch`. Usable on any thread.
    public static func buildEither(first part: IIRSystemContent) -> IIRSystemContent { part }
    /// `if … else` and `switch`. Usable on any thread.
    public static func buildEither(second part: IIRSystemContent) -> IIRSystemContent { part }

    /// `for … in`. Usable on any thread.
    public static func buildArray(_ parts: [IIRSystemContent]) -> IIRSystemContent {
        IIRSystemContent(elements: parts.flatMap(\.elements))
    }

    /// `if #available`. Usable on any thread.
    public static func buildLimitedAvailability(_ part: IIRSystemContent) -> IIRSystemContent { part }
}

/// An IIR system designed declaratively (§6.3.7): the cascade of the elements of its block.
///
/// ```swift
/// let hum = IIRSystem {
///     Zero(onUnitCircleAt: .hertz(50))                       // the conjugate is added automatically
///     Pole(radius: 0.985, frequency: .hertz(50))
///     HighPass(.butterworth, cutoff: .hertz(30), rollOff: .decibelsPerOctave(12))
///     Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
/// }
/// let report = try await hum.analysis(sampleRate: 48_000)
/// Pipeline { Filter(hum) }
/// ```
///
/// **What the system is.** The product of its elements, each a rational function of `z⁻¹`,
/// kept as zeros, poles and a gain: no polynomial is expanded, and only a
/// ``DifferenceEquation`` has its roots found from coefficients (§6.3.8). A zero and a pole
/// that both lie at the origin cancel; a pole in excess of the zeros is a delay of one
/// sample, and is kept.
///
/// **How it runs.** As second-order sections (REAL-1), formed by pairing *all* its zeros and
/// poles by the nearest rule, with the poles closest to the unit circle last: a zero and a
/// pole that were written as two elements end up in one section when they belong together.
///
/// **Sample rate.** A system holds frequencies as they were stated and is resolved against a
/// rate when it is analysed (`analysis(sampleRate:)`), asked for its roots
/// (``zeroPoleGain(sampleRate:)``) or compiled into a plan, where the rate is the one at the
/// stage's position (ENV-1). The members it has as an `LTISystem` need no rate and therefore
/// exist only for a system that does not depend on one (``dependsOnSampleRate``); for any
/// other they throw `DSPError.invalidParameter` naming the sample rate.
///
/// **Switching.** A system is switched whole, through `Filter(_:isActive:)`. An element of
/// the block with an `isActive` other than the default is rejected when the system is
/// resolved (ACT-1).
///
/// An immutable value, usable on any thread. Resolving it is design maths: it allocates and
/// belongs on a control or background context.
public struct IIRSystem: LTISystem, IIRSystemElement {
    let elements: [AnyStrategy]

    /// A system from a block of elements. Runs the block where it is called, on any thread, and
    /// allocates the elements.
    public init(@IIRSystemBuilder _ content: () -> IIRSystemContent) {
        elements = content().elements
    }

    init(elements: [AnyStrategy]) {
        self.elements = elements
    }

    /// The number of elements in the block. Usable on any thread.
    public var elementCount: Int { elements.count }

    // MARK: Resolution

    /// The system at a sample rate, with what is known about the accuracy of its roots.
    struct Resolved {
        let system: ZeroPoleGain
        /// For each zero and each pole of `system`: its condition number when it was found
        /// from coefficients, `nil` when it was placed, designed or read from a section.
        let zeroConditions: [Double?]
        let poleConditions: [Double?]
    }

    func resolved(sampleRate: Double) throws(DSPError) -> Resolved {
        try IIRDesign.validate(sampleRate: sampleRate)
        var zeros: [Complex] = []
        var poles: [Complex] = []
        var zeroConditions: [Double?] = []
        var poleConditions: [Double?] = []
        var gain = 1.0
        for (index, boxed) in elements.enumerated() {
            guard let element = boxed.value(as: (any IIRSystemElement).self) else {
                throw .invalidParameter(stage: .none, parameter: "element \(index)", reason: "this value is not an element of an IIR system")
            }
            try SystemResolution.requireDefaultActivation(of: element, index: index)
            let part: ZeroPoleGain
            do throws(DSPError) {
                part = try element.zeroPoleGain(sampleRate: sampleRate)
            } catch {
                throw SystemResolution.attributed(error, to: element, index: index)
            }
            guard part.domain == .digital, part.isFinite else {
                throw .invalidParameter(stage: .none, parameter: "element \(index)", reason: "\(type(of: element)) is not a finite digital system at \(sampleRate) Hz")
            }
            zeros += part.zeros
            poles += part.poles
            gain *= part.gain
            if let conditioned = element as? any ConditionedSystemElement {
                let conditions = try conditioned.rootConditions(sampleRate: sampleRate)
                zeroConditions += conditions.zeros.count == part.zeros.count ? conditions.zeros.map { Optional($0) } : [Double?](repeating: nil, count: part.zeros.count)
                poleConditions += conditions.poles.count == part.poles.count ? conditions.poles.map { Optional($0) } : [Double?](repeating: nil, count: part.poles.count)
            } else {
                zeroConditions += [Double?](repeating: nil, count: part.zeros.count)
                poleConditions += [Double?](repeating: nil, count: part.poles.count)
            }
        }
        guard gain.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "the gains of the elements multiply to a number that is not finite")
        }

        // A zero and a pole that both lie at the origin cancel, wherever they came from.
        var cancelled = min(zeros.filter { $0 == .zero }.count, poles.filter { $0 == .zero }.count)
        while cancelled > 0 {
            if let zero = zeros.firstIndex(of: .zero) {
                zeros.remove(at: zero)
                zeroConditions.remove(at: zero)
            }
            if let pole = poles.firstIndex(of: .zero) {
                poles.remove(at: pole)
                poleConditions.remove(at: pole)
            }
            cancelled -= 1
        }
        // More poles than zeros is a delay, and is kept: every pole in excess is a sample of
        // it. More zeros than poles would be a system that answers before it is asked; an
        // element that was written that way (zeros alone, in the `z` plane) is made causal by
        // as many poles at the origin as it lacks.
        if poles.count < zeros.count {
            let missing = zeros.count - poles.count
            poles += [Complex](repeating: .zero, count: missing)
            poleConditions += [Double?](repeating: nil, count: missing)
        }
        return Resolved(system: ZeroPoleGain(zeros: zeros, poles: poles, gain: gain, domain: .digital),
                        zeroConditions: zeroConditions, poleConditions: poleConditions)
    }

    /// The system at `sampleRate` as zeros, poles and a gain: the product of its elements.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a sample rate that is not positive and
    ///   finite, an element whose values make no system at this rate, and an element with an
    ///   `isActive` other than the default (ACT-1); what a root finder throws for a
    ///   ``DifferenceEquation``.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try resolved(sampleRate: sampleRate).system
    }

    /// The system at `sampleRate` as the cascade it runs as: all its zeros and poles paired
    /// by the nearest rule, the gain in the first section, a delay of the system as numerator
    /// coefficients that start with zeros. Control or background context; allocates.
    ///
    /// - Throws: what ``zeroPoleGain(sampleRate:)`` throws; `DSPError.invalidParameter` when
    ///   the zeros or the poles are not closed under conjugation.
    public func secondOrderSections(sampleRate: Double) throws(DSPError) -> SecondOrderSections {
        let system = try zeroPoleGain(sampleRate: sampleRate)
        if system.zeros.isEmpty, system.poles.isEmpty, system.gain == 1 {
            return SecondOrderSections(sections: [], domain: .digital)
        }
        // The pairing fills the system up with zeros at the origin until it has as many zeros
        // as poles, which takes its delay away. The delay is put back: a zero at the origin of
        // a section is exchanged for a delay of one sample, as often as there were poles in
        // excess.
        var delay = system.poles.count - system.zeros.count
        var sections = try system.secondOrderSections().sections
        var index = 0
        while delay > 0, index < sections.count {
            let section = sections[index]
            if section.b2 == 0, section.b0 != 0 || section.b1 != 0 {
                sections[index] = .init(b0: 0, b1: section.b0, b2: section.b1, a1: section.a1, a2: section.a2)
                delay -= 1
            } else {
                index += 1
            }
        }
        return SecondOrderSections(sections: sections, domain: .digital)
    }

    // MARK: Element of a system, and animation

    /// True when an element depends on the sample rate. Usable on any thread.
    public var dependsOnSampleRate: Bool {
        elements.contains { ($0.value(as: (any IIRSystemElement).self))?.dependsOnSampleRate ?? true }
    }

    /// The continuous values of the elements, in order (ANI-2). Usable on any thread; it may
    /// allocate.
    public var parameters: [Double] {
        elements.flatMap { ($0.value(as: (any IIRSystemElement).self))?.parameters ?? [] }
    }

    /// The system with the continuous values of its elements replaced. Usable on any thread; it may
    /// allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> IIRSystem {
        guard values.count == parameters.count else { return self }
        var remaining = values
        var replaced: [AnyStrategy] = []
        for boxed in elements {
            guard let element = boxed.value(as: (any IIRSystemElement).self) else {
                replaced.append(boxed)
                continue
            }
            func open<Element: IIRSystemElement>(_ element: Element) -> AnyStrategy {
                let count = element.parameters.count
                let own = remaining.prefix(count)
                remaining = remaining.dropFirst(count)
                return count == 0 ? boxed : AnyStrategy(element.replacingParameters(own))
            }
            replaced.append(open(element))
        }
        return IIRSystem(elements: replaced)
    }

    // MARK: LTISystem, for a system that needs no sample rate

    /// A system of this kind is digital. Usable on any thread.
    public var domain: SystemDomain { .digital }

    private func fixed() throws(DSPError) -> ZeroPoleGain {
        try SystemResolution.requireFixed(dependsOnSampleRate)
        return try zeroPoleGain(sampleRate: SystemResolution.referenceRate)
    }

    /// The zeros, for a system that does not depend on the sample rate. Control or
    /// background context; allocates.
    public var zeros: [Complex] {
        get throws(DSPError) { try fixed().zeros }
    }

    /// The poles, for a system that does not depend on the sample rate. Control or
    /// background context; allocates.
    public var poles: [Complex] {
        get throws(DSPError) { try fixed().poles }
    }

    /// The gain, for a system that does not depend on the sample rate. Control or background
    /// context; allocates.
    public var gain: Double {
        get throws(DSPError) { try fixed().gain }
    }
}

/// What the two system builders share when they are resolved.
enum SystemResolution {
    /// The rate a system that does not depend on one is resolved at.
    static let referenceRate = 1.0

    /// ACT-1: an element of a system is not switched on its own.
    static func requireDefaultActivation(of element: Any, index: Int) throws(DSPError) {
        guard let stage = element as? any StageValue, stage.activation != .active else { return }
        throw .invalidParameter(
            stage: .none, parameter: "isActive",
            reason: "element \(index) of the system (\(type(of: stage).stageName)) has an isActive of its own: a system is switched whole, through Filter(_:isActive:)")
    }

    /// The members a system has as an `LTISystem` take no sample rate.
    static func requireFixed(_ dependsOnSampleRate: Bool) throws(DSPError) {
        guard !dependsOnSampleRate else {
            throw .invalidParameter(
                stage: .none, parameter: "sampleRate",
                reason: "this system states a frequency in hertz (or as a note, or in mels), so it is a system only at a sample rate: analyse it with analysis(sampleRate:), or resolve it first")
        }
    }

    /// An element's error with the element named in front of its reason.
    static func attributed(_ error: DSPError, to element: Any, index: Int) -> DSPError {
        guard case .invalidParameter(let stage, let parameter, let reason) = error else { return error }
        return .invalidParameter(stage: stage, parameter: parameter, reason: "element \(index) of the system (\(type(of: element))): \(reason)")
    }
}
