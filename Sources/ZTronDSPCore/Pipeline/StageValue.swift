@_exported import CZTronDSP

/// A stage as a value: what every stage, step and recipe of a pipeline is (API-3).
///
/// A stage holds no run-time state (ATT-1). It describes; `lower(_:)` turns the description
/// into kernels or a node when a pipeline is attached. Three protocols refine this one:
///
/// - ``PipelineStage`` names the domain it consumes and the one it produces.
/// - ``SequenceStage`` runs on any sampled sequence and keeps its domain.
/// - A context-dependent step (a *family*, ORD-1) adopts neither: it is a plain value, and its
///   typing rule is written once as a builder overload, a fluent method and a `DomainRule`.
///
/// Stages are immutable values, usable on any thread. `lower(_:)` runs on the control context.
public protocol StageValue: Hashable, Sendable {
    /// What errors and paths call the stage. The default is the type's name.
    static var stageName: String { get }

    /// The stage's switch (§5.9). The default is the constant `.active`. Stock stages take it
    /// as their trailing `isActive:` argument; any stage gets it from `.active(_:)`.
    var activation: StageActivation { get }

    /// The stage's continuous values, for animation (ANI-2): frequencies as their
    /// `animatableValue`, gains in decibels. Orders, sizes and strategies are structure and
    /// are left out. The default is no values.
    var parameters: [Double] { get }

    /// The stage with its continuous values replaced; `values` holds as many as `parameters`.
    /// Passing the stage's own values returns the stage unchanged, bit for bit.
    func replacingParameters(_ values: ArraySlice<Double>) -> Self

    /// Emits the stage's kernels or its node into the plan being compiled. Runs on the control
    /// context and may allocate. The environment the stage reads is the one at its position
    /// (ENV-1); a stage that changes the rate or the domain says so through the context.
    func lower(_ context: inout LoweringContext) throws(DSPError)
}

extension StageValue {
    public static var stageName: String {
        // "Tap<Samples, Chroma>" reads as "Tap".
        let full = String(describing: Self.self)
        return full.firstIndex(of: "<").map { String(full[..<$0]) } ?? full
    }

    public var activation: StageActivation { .active }
    public var parameters: [Double] { [] }
    public func replacingParameters(_ values: ArraySlice<Double>) -> Self { self }
}

/// A stage that names the domain it consumes and the domain it produces (§5.2). A composition
/// compiles only where the domain before the stage is the one it consumes (§5.8, tier 1).
public protocol PipelineStage: StageValue {
    associatedtype Input: SignalDomain
    associatedtype Output: SignalDomain

    /// What the stage contributes to a pipeline's description: itself, by default. A recipe
    /// contributes the stages it expands to, and a pipeline its own stages, so nesting leaves
    /// no trace (API-1).
    var stageDescriptions: [StageDescription] { get }
}

extension PipelineStage {
    public var stageDescriptions: [StageDescription] {
        [StageDescription(self, rule: .fixed(Input.tag, Output.tag))]
    }
}

/// A stage that runs on any sampled sequence (samples, a novelty curve, a scalar track) and
/// keeps its domain: gains, filters, smoothers, rate changers (§5.2).
public protocol SequenceStage: StageValue {
    /// What the stage contributes to a pipeline's description: itself, by default.
    var stageDescriptions: [StageDescription] { get }
}

extension SequenceStage {
    public var stageDescriptions: [StageDescription] {
        [StageDescription(self, rule: .sequence)]
    }
}

/// A stage defined entirely by what it expands to (§5.2): it adds no behaviour of its own, and
/// a pipeline that holds it equals one that holds its expansion.
public protocol Recipe: PipelineStage {
    /// The stages the recipe stands for.
    var expansion: Pipeline<Input, Output> { get }
}

extension Recipe {
    public var stageDescriptions: [StageDescription] { expansion.stages }

    /// Never called: a recipe is replaced by its expansion before anything is lowered.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

// MARK: Activation for any stage (ACT-1)

/// A self-typed stage with a switch: what `.active(_:)` returns.
public struct ActivatedStage<Base: PipelineStage>: PipelineStage {
    public typealias Input = Base.Input
    public typealias Output = Base.Output
    public let base: Base
    public let activation: StageActivation

    public static var stageName: String { Base.stageName }
    public var parameters: [Double] { base.parameters }

    public func replacingParameters(_ values: ArraySlice<Double>) -> ActivatedStage<Base> {
        ActivatedStage(base: base.replacingParameters(values), activation: activation)
    }

    public var stageDescriptions: [StageDescription] {
        StageDescription.switched(base.stageDescriptions, by: activation, name: Base.stageName)
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try base.lower(&context)
    }
}

/// A sequence stage with a switch: what `.active(_:)` returns.
public struct ActivatedSequenceStage<Base: SequenceStage>: SequenceStage {
    public let base: Base
    public let activation: StageActivation

    public static var stageName: String { Base.stageName }
    public var parameters: [Double] { base.parameters }

    public func replacingParameters(_ values: ArraySlice<Double>) -> ActivatedSequenceStage<Base> {
        ActivatedSequenceStage(base: base.replacingParameters(values), activation: activation)
    }

    public var stageDescriptions: [StageDescription] {
        StageDescription.switched(base.stageDescriptions, by: activation, name: Base.stageName)
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try base.lower(&context)
    }
}

extension PipelineStage {
    /// The stage with a switch: `true` or `false`, `.active` or `.bypassed`, or a SwiftUI
    /// `Binding<Bool>` (ACT-1). A stage that keeps the domain and the rate is bypassed when it
    /// is off; one that changes them suspends the rest of its branch (ACT-3).
    public func active(_ isActive: some ActivationSource) -> ActivatedStage<Self> {
        ActivatedStage(base: self, activation: isActive.stageActivation)
    }
}

extension SequenceStage {
    /// The stage with a switch: `true` or `false`, `.active` or `.bypassed`, or a SwiftUI
    /// `Binding<Bool>` (ACT-1).
    public func active(_ isActive: some ActivationSource) -> ActivatedSequenceStage<Self> {
        ActivatedSequenceStage(base: self, activation: isActive.stageActivation)
    }
}
