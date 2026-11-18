/// The type-erased description of one stage of a pipeline: `Hashable`, `Sendable`, and all a
/// pipeline is made of (API-1).
///
/// A description carries the stage's `DomainRule`, so the order of a pipeline can be checked
/// without its types (§5.8, tier 2), and its activation (ACT-12). Two descriptions are equal
/// when they describe the same stage with the same values; a value that carries a closure
/// compares by what it produces.
///
/// An immutable value, usable on any thread.
public struct StageDescription: Hashable, Sendable {
    /// The stage's name, as errors and paths show it.
    public let name: String
    /// From the domain before the stage to the domain after it.
    public let rule: DomainRule
    /// The stage's switch.
    public let activation: StageActivation
    let content: Content

    indirect enum Content: Hashable, Sendable {
        /// A stage that lowers itself.
        case stage(AnyStageValue)
        /// A side branch: it reads the signal and leaves the main line untouched.
        case tap([StageDescription])
        /// A named run of stages, switched or given an environment as one.
        case group([StageDescription], overrides: [EnvironmentOverride])
        /// Stages built from the environment at their position.
        case reader(EnvironmentReaderBox)
        /// A sink: the frames go to it and pass on.
        case emit(SinkDescription)
    }

    init(name: String, rule: DomainRule, activation: StageActivation, content: Content) {
        self.name = name
        self.rule = rule
        self.activation = activation
        self.content = content
    }

    /// Describes a stage. `rule` is the stage's typing rule: `.fixed(Input.tag, Output.tag)`
    /// for a self-typed stage, `.sequence` for a sequence stage, the family's rule for a
    /// context-dependent step.
    public init(_ stage: some StageValue, rule: DomainRule) {
        self.init(name: type(of: stage).stageName, rule: rule, activation: stage.activation, content: .stage(AnyStageValue(stage)))
    }

    /// The descriptions under one switch: the description itself when there is one and its
    /// own activation is the default, otherwise a group around them.
    static func switched(_ descriptions: [StageDescription], by activation: StageActivation, name: String) -> [StageDescription] {
        if activation == .active { return descriptions }
        if descriptions.count == 1, descriptions[0].activation == .active {
            let only = descriptions[0]
            return [StageDescription(name: only.name, rule: only.rule, activation: activation, content: only.content)]
        }
        return [StageDescription(name: name, rule: .any, activation: activation, content: .group(descriptions, overrides: []))]
    }

    /// The stage this description was made from, when it is of type `T`.
    public func stage<T: StageValue>(as type: T.Type = T.self) -> T? {
        if case .stage(let erased) = content { return erased.base as? T }
        return nil
    }

    /// The stages nested in this one: the content of a `Tap` or a `Group`. Empty for a stage
    /// that has none, and for an `EnvironmentReader`, whose content exists only once it is
    /// resolved against an environment.
    public var nestedStages: [StageDescription] {
        switch content {
        case .tap(let stages), .group(let stages, _): stages
        case .stage, .reader, .emit: []
        }
    }

    /// What kind of structure the description is.
    public enum Kind: Hashable, Sendable {
        case stage, tap, group, environmentReader, emit
    }

    public var kind: Kind {
        switch content {
        case .stage: .stage
        case .tap: .tap
        case .group: .group
        case .reader: .environmentReader
        case .emit: .emit
        }
    }

    // MARK: Parameters (ANI-2)

    /// The continuous values of the stage and of everything nested in it, in order. An
    /// `EnvironmentReader` contributes none: its stages exist only per environment.
    public var parameters: [Double] {
        switch content {
        case .stage(let erased): erased.base.parameters
        case .tap(let stages), .group(let stages, _): stages.flatMap(\.parameters)
        case .reader, .emit: []
        }
    }

    /// The description with its continuous values taken from the front of `values`, which is
    /// advanced past them.
    func replacingParameters(_ values: inout ArraySlice<Double>) -> StageDescription {
        switch content {
        case .stage(let erased):
            let count = erased.base.parameters.count
            guard count > 0, values.count >= count else { return self }
            let own = values.prefix(count)
            values = values.dropFirst(count)
            return StageDescription(name: name, rule: rule, activation: activation, content: .stage(erased.replacingParameters(own)))
        case .tap(let stages):
            return StageDescription(name: name, rule: rule, activation: activation, content: .tap(stages.map { $0.replacingParameters(&values) }))
        case .group(let stages, let overrides):
            return StageDescription(name: name, rule: rule, activation: activation,
                                    content: .group(stages.map { $0.replacingParameters(&values) }, overrides: overrides))
        case .reader, .emit:
            return self
        }
    }
}

/// A stage value, erased, with the equality of the value it holds.
struct AnyStageValue: Hashable, Sendable {
    let base: any StageValue

    init(_ base: some StageValue) {
        self.base = base
    }

    func replacingParameters(_ values: ArraySlice<Double>) -> AnyStageValue {
        func open<S: StageValue>(_ stage: S) -> AnyStageValue { AnyStageValue(stage.replacingParameters(values)) }
        return open(base)
    }

    static func == (lhs: AnyStageValue, rhs: AnyStageValue) -> Bool {
        func equal<S: StageValue>(_ stage: S) -> Bool { (rhs.base as? S) == stage }
        return equal(lhs.base)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: base)))
        base.hash(into: &hasher)
    }
}

/// One `.environment(_:_:)` override of a scope: a settable key and its value (ENV-3).
struct EnvironmentOverride: Hashable, Sendable {
    let key: ObjectIdentifier
    let value: AnyStrategy
}

/// The closure of an `EnvironmentReader`. Two readers are equal when they produce equal stages
/// in the reference environment: a value that carries a closure compares by what it produces
/// (API-1). Once a pipeline is resolved against its real environment the readers are gone, and
/// the comparison that decides what a session does is made on resolved descriptions.
struct EnvironmentReaderBox: Hashable, Sendable {
    let make: @Sendable (DSPEnvironment) -> [StageDescription]

    static func == (lhs: EnvironmentReaderBox, rhs: EnvironmentReaderBox) -> Bool {
        lhs.make(.reference) == rhs.make(.reference)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(make(.reference))
    }
}
