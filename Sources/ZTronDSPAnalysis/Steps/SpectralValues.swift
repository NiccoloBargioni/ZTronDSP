import Foundation
import ZTronDSPCore

/// A step whose domains depend on the stage before it: a member of a step family (ORD-1).
///
/// Such a step cannot name an `Input` and an `Output` (E-20), so it is a plain value, and its
/// typing rule is written once per family: as an overload of
/// `PipelineBuilder.buildPartialBlock(accumulated:next:)` constrained on the accumulated
/// domain, as a fluent method on `Pipeline` constrained on `Output`, and as the `DomainRule`
/// its description carries, which is what the plan compiler checks again when the pipeline is
/// attached (§5.8.2).
///
/// A block cannot begin with such a step (ORD-3): begin it with the stage the step follows,
/// or write the branch fluently, as `.tap { $0.magnitude() … }`.
public protocol ContextDependentStep: StageValue {
    /// The step as a pipeline holds it, with its typing rule.
    var stageDescription: StageDescription { get }
}

// MARK: Magnitude and Power (O-3)

/// The magnitudes `|X|` of a complex spectrum, on whatever axis it has (§6.4.1). It follows
/// a complex spectrum only: magnitudes, powers and decibels are already real (O-3).
///
/// The phase is discarded, so there is no way back from here (§6.13). Switched off, it
/// suspends the rest of its branch (ACT-3). An immutable value, usable on any thread.
public struct Magnitude: ContextDependentStep {
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// From a complex spectrum to magnitudes on the same axis.
    public static let rule = DomainRule.spectral("Magnitude: a complex spectrum to magnitudes") { axis, values in
        values == .complex ? .spectrum(axis: axis, values: .magnitude) : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: Magnitude.rule) }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try SpectralValueOperation.magnitude.emit(named: "Magnitude", in: &context)
    }
}

/// The powers `|X|²` of a complex spectrum, on whatever axis it has (§6.4.1). It follows a
/// complex spectrum only (O-3).
///
/// The phase is discarded, so there is no way back from here (§6.13). Switched off, it
/// suspends the rest of its branch (ACT-3). An immutable value, usable on any thread.
public struct Power: ContextDependentStep {
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// From a complex spectrum to powers on the same axis.
    public static let rule = DomainRule.spectral("Power: a complex spectrum to powers") { axis, values in
        values == .complex ? .spectrum(axis: axis, values: .power) : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: Power.rule) }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try SpectralValueOperation.power.emit(named: "Power", in: &context)
    }
}

// MARK: Decibels and back (O-4)

/// Magnitudes or powers in decibels, on whatever axis they have (§6.2): `20·log₁₀(m / reference)`
/// for magnitudes, `10·log₁₀(p / reference)` for powers, clamped at `floor` so that silence is
/// a number and not −∞ (NUM-1).
///
/// It follows magnitudes or powers: not a complex spectrum, and not decibels, whose logarithm
/// means nothing (O-4). `InverseDecibels` undoes it wherever a value lay above the floor.
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on
/// any thread.
public struct Decibels: ContextDependentStep {
    /// What reads 0 dB, in the unit of the values: an amplitude for magnitudes, a power for
    /// powers.
    public let reference: Double
    /// The least value the step writes, in decibels.
    public let floor: Double
    public let activation: StageActivation

    public init(reference: Double = 1, floor: Double = DSP.decibelFloor, isActive: some ActivationSource = .active) {
        self.reference = reference
        self.floor = floor
        activation = isActive.stageActivation
    }

    /// From magnitudes or powers to decibels on the same axis.
    public static let rule = DomainRule.spectral("Decibels: magnitudes or powers to decibels") { axis, values in
        values == .magnitude || values == .power ? .spectrum(axis: axis, values: .decibel) : nil
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: Decibels.rule) }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard reference > 0, reference.isFinite else { throw context.invalid("reference", "the reference of a decibel value is positive and finite, not \(reference)") }
        _ = try StageValidation.finite(floor, named: "floor", in: context)
        let operation: SpectralValueOperation
        if case .spectrum(_, .power) = context.domain {
            operation = .decibelsFromPower(reference: Float(reference), floor: Float(floor))
        } else {
            operation = .decibelsFromAmplitude(reference: Float(reference), floor: Float(floor))
        }
        try operation.emit(named: "Decibels", in: &context)
    }
}

/// Which linear values a step produces: `.magnitude` or `.power`. It carries the choice in
/// its type, so the compiler knows the domain that follows (§5.8.2).
///
/// An immutable value, usable on any thread.
public struct LinearValueKind<Values: LinearValued>: Hashable, Sendable {
    init() {}
}

extension LinearValueKind where Values == MagnitudeValues {
    /// Magnitudes: `reference · 10^(dB / 20)`.
    public static var magnitude: LinearValueKind<MagnitudeValues> { LinearValueKind() }
}

extension LinearValueKind where Values == PowerValues {
    /// Powers: `reference · 10^(dB / 10)`.
    public static var power: LinearValueKind<PowerValues> { LinearValueKind() }
}

/// A spectrum in decibels back to magnitudes or to powers, on whatever axis it has (§6.13):
/// `InverseDecibels(.magnitude)` or `InverseDecibels(.power)`, whichever the `Decibels` it
/// undoes was given.
///
/// A value that was clamped at the floor comes back as the floor, not as what it was; the
/// inversion report counts them. Switched off, it suspends the rest of its branch (ACT-3).
/// An immutable value, usable on any thread.
public struct InverseDecibels<Values: LinearValued>: ContextDependentStep {
    /// What 0 dB stands for, in the unit of the values produced.
    public let reference: Double
    public let activation: StageActivation

    public init(_ values: LinearValueKind<Values>, reference: Double = 1, isActive: some ActivationSource = .active) {
        self.reference = reference
        activation = isActive.stageActivation
    }

    /// From decibels to this step's kind of value, on the same axis.
    public static var rule: DomainRule {
        let produced = Values.valuesTag
        return DomainRule.spectral("InverseDecibels: decibels to \(produced == .power ? "powers" : "magnitudes")") { axis, values in
            values == .decibel ? .spectrum(axis: axis, values: produced) : nil
        }
    }

    public var stageDescription: StageDescription { StageDescription(self, rule: InverseDecibels.rule) }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard reference > 0, reference.isFinite else { throw context.invalid("reference", "the reference of a decibel value is positive and finite, not \(reference)") }
        let operation: SpectralValueOperation = Values.valuesTag == .power
            ? .powerFromDecibels(reference: Float(reference)) : .amplitudeFromDecibels(reference: Float(reference))
        try operation.emit(named: "InverseDecibels", in: &context)
    }
}

// MARK: The typing rules (tier 1)

extension PipelineBuilder {
    public static func buildPartialBlock<I, Axis>(
        accumulated: Pipeline<I, Spectrum<Axis, ComplexValues>>, next: Magnitude
    ) -> Pipeline<I, Spectrum<Axis, MagnitudeValues>> {
        accumulated.appending(next.stageDescription)
    }

    public static func buildPartialBlock<I, Axis>(
        accumulated: Pipeline<I, Spectrum<Axis, ComplexValues>>, next: Power
    ) -> Pipeline<I, Spectrum<Axis, PowerValues>> {
        accumulated.appending(next.stageDescription)
    }

    public static func buildPartialBlock<I, Axis, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<Axis, Values>>, next: Decibels
    ) -> Pipeline<I, Spectrum<Axis, DecibelValues>> {
        accumulated.appending(next.stageDescription)
    }

    public static func buildPartialBlock<I, Axis, Values>(
        accumulated: Pipeline<I, Spectrum<Axis, DecibelValues>>, next: InverseDecibels<Values>
    ) -> Pipeline<I, Spectrum<Axis, Values>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The magnitudes of the complex spectrum: see ``Magnitude``.
    public func magnitude<Axis>(isActive: some ActivationSource = .active) -> Pipeline<Input, Spectrum<Axis, MagnitudeValues>>
    where Output == Spectrum<Axis, ComplexValues> {
        appending(Magnitude(isActive: isActive).stageDescription)
    }

    /// The powers of the complex spectrum: see ``Power``.
    public func power<Axis>(isActive: some ActivationSource = .active) -> Pipeline<Input, Spectrum<Axis, PowerValues>>
    where Output == Spectrum<Axis, ComplexValues> {
        appending(Power(isActive: isActive).stageDescription)
    }

    /// The magnitudes or powers in decibels: see ``Decibels``.
    public func decibels<Axis, Values: LinearValued>(
        reference: Double = 1, floor: Double = DSP.decibelFloor, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<Axis, DecibelValues>> where Output == Spectrum<Axis, Values> {
        appending(Decibels(reference: reference, floor: floor, isActive: isActive).stageDescription)
    }

    /// The decibels back to magnitudes or powers: see ``InverseDecibels``.
    public func inverseDecibels<Axis, Values>(
        _ values: LinearValueKind<Values>, reference: Double = 1, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<Axis, Values>> where Output == Spectrum<Axis, DecibelValues> {
        appending(InverseDecibels(values, reference: reference, isActive: isActive).stageDescription)
    }
}

// MARK: Lowering

/// What a value step does to each frame. It is the key of the node: equal operations at one
/// position are one node (F5).
enum SpectralValueOperation: Hashable, Sendable {
    case magnitude
    case power
    case decibelsFromAmplitude(reference: Float, floor: Float)
    case decibelsFromPower(reference: Float, floor: Float)
    case amplitudeFromDecibels(reference: Float)
    case powerFromDecibels(reference: Float)

    /// Emits the node. The frames keep their length and their axis.
    func emit(named name: String, in context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(reason: "\(name) needs the frames of a spectral scope: there is no frequency axis at this position", stage: context.path)
        }
        let operation = self
        context.emit(.analysis(AnalysisStep(name: name, key: self, output: .real(count: bins)) { () throws(DSPError) -> any AnalysisNode in
            SpectralValueNode(operation, bins: bins)
        }))
    }
}
