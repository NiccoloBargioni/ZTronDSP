/// A pipeline whose stages are not known when the app is compiled: a preset read from a file,
/// a rack the user edits (ORD-5).
///
/// A typed `Pipeline` has its order checked by the compiler. Here the same rules are applied
/// when a stage is appended: each stage description carries the rule the types express, as a
/// function from the domain it finds to the domain it leaves, and an append that the rule
/// refuses throws `DSPError.invalidStageOrder` with the stage's path. Whatever is appended is
/// checked again, with its values, when the pipeline is attached (ORD-6).
///
/// It attaches and updates like a typed pipeline, and equal stages give the same plan.
///
/// An immutable value, usable on any thread: appending returns a new pipeline.
public struct DynamicPipeline: Hashable, Sendable {
    /// The stages, in order.
    public let stages: [StageDescription]
    /// The domain of the signal after the last stage.
    public let outputTag: DomainTag

    /// An empty pipeline on samples.
    public init() {
        stages = []
        outputTag = .samples
    }

    private init(stages: [StageDescription], outputTag: DomainTag) {
        self.stages = stages
        self.outputTag = outputTag
    }

    /// The stages of a typed pipeline, checked again as descriptions: the types say what the
    /// caller says, and a pipeline built with `Pipeline(unchecked:)` may say anything.
    ///
    /// - Throws: `invalidStageOrder` for the first stage that cannot follow what precedes it.
    public init<Output>(_ pipeline: Pipeline<Samples, Output>) throws(DSPError) {
        self = try DynamicPipeline().appending(contentsOf: pipeline.stages)
    }

    /// The pipeline followed by a self-typed stage.
    ///
    /// - Throws: `invalidStageOrder` when the stage cannot follow a signal of `outputTag`.
    public func appending(_ stage: some PipelineStage) throws(DSPError) -> DynamicPipeline {
        try appending(contentsOf: stage.stageDescriptions)
    }

    /// The pipeline followed by a sequence stage.
    public func appending(_ stage: some SequenceStage) throws(DSPError) -> DynamicPipeline {
        try appending(contentsOf: stage.stageDescriptions)
    }

    /// The pipeline followed by a step given as its description: a step of a family, a tap, a
    /// group, a sink.
    public func appending(_ description: StageDescription) throws(DSPError) -> DynamicPipeline {
        try appending(contentsOf: [description])
    }

    /// The pipeline followed by several steps, each checked in turn. Either all are appended
    /// or none is.
    public func appending(contentsOf descriptions: [StageDescription]) throws(DSPError) -> DynamicPipeline {
        var tag = outputTag
        try DynamicPipeline.check(descriptions, from: &tag, prefix: StagePath(), offset: stages.count)
        return DynamicPipeline(stages: stages + descriptions, outputTag: tag)
    }

    /// Appends a self-typed stage in place.
    public mutating func append(_ stage: some PipelineStage) throws(DSPError) {
        self = try appending(stage)
    }

    /// Appends a sequence stage in place.
    public mutating func append(_ stage: some SequenceStage) throws(DSPError) {
        self = try appending(stage)
    }

    /// Appends a step given as its description in place.
    public mutating func append(_ description: StageDescription) throws(DSPError) {
        self = try appending(description)
    }

    /// Appends several steps in place, each checked in turn. Either all are appended or none
    /// is.
    public mutating func append(contentsOf descriptions: [StageDescription]) throws(DSPError) {
        self = try appending(contentsOf: descriptions)
    }

    /// Tier 2 of the order rules (§5.8.2): walks `stages` from the domain `tag`, applying each
    /// stage's rule, and leaves in `tag` the domain after the last one. A tap is walked from
    /// the domain it taps and does not move the main line; a group is walked in place; a
    /// reader is walked as what it produces in the reference environment, whose domains are
    /// the same in every environment because its closure has one return type.
    static func check(_ stages: [StageDescription], from tag: inout DomainTag, prefix: StagePath, offset: Int = 0) throws(DSPError) {
        for (index, stage) in stages.enumerated() {
            let path = prefix.appending(stage.name, index: offset + index)
            switch stage.content {
            case .tap(let nested):
                var branch = tag
                try check(nested, from: &branch, prefix: path)
            case .group(let nested, _):
                try check(nested, from: &tag, prefix: path)
            case .reader(let box):
                try check(box.make(.reference), from: &tag, prefix: path)
            case .stage, .emit:
                guard let output = stage.rule(tag) else { throw DSPError.invalidStageOrder(stage: path, found: tag) }
                tag = output
            }
        }
    }
}
