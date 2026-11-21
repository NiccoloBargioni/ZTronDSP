/// A run of stages as a description: what the result builder and the fluent spelling produce.
///
/// Conformers are immutable values, usable on any thread; building one allocates its list.
public protocol PipelineContent: Hashable, Sendable {
    /// The stages, in order.
    var stages: [StageDescription] { get }
}

/// A block made only of sequence stages. It has no domain of its own and takes the domain of
/// the place where it is used: samples at the top of a pipeline, a novelty curve after an
/// onset-strength step (§5.8.2).
///
/// An immutable value, usable on any thread; building one allocates its list.
public struct SequenceChain: PipelineContent, SequenceStage {
    /// The stages, in order.
    public let stages: [StageDescription]

    /// A chain of these stages; without any, an empty chain that contributes nothing.
    public init(stages: [StageDescription] = []) {
        self.stages = stages
    }

    /// The chain's stages, which the pipeline that holds it splices in.
    public var stageDescriptions: [StageDescription] { stages }

    /// Never called: a chain is spliced into the pipeline that holds it.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

/// A declarative chain of processing and analysis stages: an immutable, typed wrapper around
/// an ordered list of stage descriptions (API-1).
///
/// A pipeline is source-independent and holds no run-time state: the same value attaches to a
/// microphone, a file or a mock, and every attachment gets its own state (IN-1, ATT-1).
/// `Input` and `Output` are the signal domains at its ends; the compiler accepts a stage only
/// where the domain before it is the one it consumes (API-4), and only a pipeline that starts
/// from `Samples` can be attached to a source (O-12).
///
/// Build one with the result builder, one stage per line, or fluently, each call returning a
/// new description; both spellings give equal values:
///
/// ```swift
/// let a = Pipeline { Gain(.decibels(-3)); HighPass(.butterworth, cutoff: .hertz(90), order: 4) }
/// let b = Pipeline().gain(.decibels(-3)).highPass(.butterworth, cutoff: .hertz(90), order: 4)
/// // a == b
/// ```
///
/// An immutable value, usable on any thread. Building one, in either spelling, allocates its
/// list of descriptions.
public struct Pipeline<Input: SignalDomain, Output: SignalDomain>: PipelineContent, PipelineStage {
    /// The stages, in order.
    public let stages: [StageDescription]

    /// A pipeline over `stages`, taken on trust: the types say what the caller says. This is
    /// the entry for the author of a step family (ORD-1), whose constraint on the extension
    /// that calls it is the compile-time rule. Whatever the types claim, the order is checked
    /// again on the descriptions when the pipeline is attached (ORD-6).
    public init(unchecked stages: [StageDescription]) {
        self.stages = stages
    }

    /// The pipeline's stages, which a pipeline that holds it splices in.
    public var stageDescriptions: [StageDescription] { stages }

    /// Never called: a pipeline is spliced into the pipeline that holds it.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

extension Pipeline where Input == Samples, Output == Samples {
    /// An empty pipeline on samples: where the fluent spelling starts. Usable on any thread; it
    /// does not allocate.
    public init() {
        self.init(unchecked: [])
    }

    /// A pipeline of sequence stages only, on samples. Runs the block where it is called, on any
    /// thread, and allocates the stages.
    public init(@PipelineBuilder _ content: () -> SequenceChain) {
        self.init(unchecked: content().stages)
    }
}

extension Pipeline {
    /// A pipeline from a block of stages. Runs the block where it is called, on any thread, and
    /// allocates the stages.
    public init(@PipelineBuilder _ content: () -> Pipeline<Input, Output>) {
        self.init(unchecked: content().stages)
    }

    // MARK: The appending core of the fluent spelling (WP-303)

    /// The pipeline followed by a self-typed stage. Compiles only where the stage consumes this
    /// pipeline's output domain. Usable on any thread; allocates the pipeline it returns.
    public func appending<S: PipelineStage>(_ stage: S) -> Pipeline<Input, S.Output> where S.Input == Output {
        Pipeline<Input, S.Output>(unchecked: stages + stage.stageDescriptions)
    }

    /// The pipeline followed by a sequence stage. Compiles only on a sampled sequence (O-1). Usable
    /// on any thread; allocates the pipeline it returns.
    public func appending<S: SequenceStage>(_ stage: S) -> Pipeline<Input, Output> where Output: SampledSequence {
        Pipeline(unchecked: stages + stage.stageDescriptions)
    }

    /// The pipeline followed by a step of a family, producing `NewOutput`. For the author of a
    /// family: constrain the extension that calls this to the domains the step may follow. Usable
    /// on any thread; allocates the pipeline it returns.
    public func appending<NewOutput: SignalDomain>(
        _ description: StageDescription, producing output: NewOutput.Type = NewOutput.self
    ) -> Pipeline<Input, NewOutput> {
        Pipeline<Input, NewOutput>(unchecked: stages + [description])
    }

    /// The domain the pipeline consumes, as a run-time tag. Usable on any thread; it does not
    /// allocate.
    public var inputTag: DomainTag { Input.tag }
    /// The domain the pipeline produces, as a run-time tag. Usable on any thread; it does not
    /// allocate.
    public var outputTag: DomainTag { Output.tag }

    // MARK: Parameters (ANI-2)

    /// Every continuous value of every stage, in order: what an animation interpolates. Usable on
    /// any thread; it allocates the vector.
    public var parameters: ParameterVector {
        ParameterVector(stages.flatMap(\.parameters))
    }

    /// The pipeline with its continuous values replaced. A vector of another length belongs to
    /// another topology and leaves the pipeline unchanged. Passing the pipeline's own vector
    /// returns an equal pipeline. Usable on any thread; it allocates the pipeline it returns,
    /// unless that is this one.
    public func replacingParameters(_ vector: ParameterVector) -> Pipeline<Input, Output> {
        guard vector.count == parameters.count, !vector.isReplacement else { return self }
        var remaining = vector.values[...]
        return Pipeline(unchecked: stages.map { $0.replacingParameters(&remaining) })
    }
}
