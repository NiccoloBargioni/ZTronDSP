/// The result builder behind `Pipeline { … }`: one stage per line (§5.1).
///
/// The builder composes with partial blocks. Appending a stage `S` to an accumulated
/// `Pipeline<I, M>` requires `S.Input == M` and yields `Pipeline<I, S.Output>`, so a stage
/// compiles only where the domain before it is the one it consumes, and the accumulated type
/// is always a `Pipeline`, never a nested generic (§5.8.2, E-19, E-22).
///
/// Control flow (API-2, ORD-3): a stage inside `if` without `else`, inside `for`, or inside
/// `if #available` must keep the domain (O-13); the branches of `if … else` and `switch` must
/// end in the same domain (O-14). A block begins with a self-typed stage, a sequence stage, a
/// `Group` or an `EnvironmentReader`.
///
/// A step family adds its typing rule by extending this builder with an overload of
/// `buildPartialBlock(accumulated:next:)` constrained on the accumulated output domain, and,
/// for a readable diagnostic, a catch-all overload marked unavailable (ORD-1, ORD-4).
@resultBuilder
public enum PipelineBuilder {
    // MARK: Every statement is a stage

    /// Each line of a block is type-checked on its own, as a stage value, before it is
    /// composed with the lines above it. That keeps a line's own overloads (a `Group` in a
    /// file that also imports SwiftUI, say) apart from the composition rules below.
    public static func buildExpression<Stage: StageValue>(_ stage: Stage) -> Stage { stage }

    // MARK: The first stage of a block

    /// A self-typed stage opens a block in its own input domain.
    public static func buildPartialBlock<S: PipelineStage>(first: S) -> Pipeline<S.Input, S.Output> {
        Pipeline(unchecked: first.stageDescriptions)
    }

    /// A sequence stage opens a block whose domain the context decides (ORD-3).
    public static func buildPartialBlock<S: SequenceStage>(first: S) -> SequenceChain {
        SequenceChain(stages: first.stageDescriptions)
    }

    /// A sink that takes one domain may open a block: the block starts in that domain.
    public static func buildPartialBlock<Sink: FeatureSink>(first: Emit<Sink>) -> Pipeline<Sink.Domain, Sink.Domain> {
        Pipeline(unchecked: [first.stageDescription])
    }

    /// Catches an `Emit` that opens a block with a sink that has no domain of its own, with a message that says what to write.
    @available(*, unavailable, message: "An Emit that opens a block needs a sink of one domain, a FeatureStream or a FeatureCallback: the block then starts in that domain. A HeatmapFeed, a WaveformFeed or a Binding takes what the stage before it delivers: write that stage first.")
    public static func buildPartialBlock<Target>(first: Emit<Target>) -> SequenceChain {
        SequenceChain()
    }

    // MARK: A stage after a typed pipeline

    /// A self-typed stage follows a pipeline that ends in its input domain (ORD-1).
    public static func buildPartialBlock<I, M, S: PipelineStage>(accumulated: Pipeline<I, M>, next: S) -> Pipeline<I, S.Output>
    where S.Input == M {
        accumulated.appending(next)
    }

    /// A sequence stage follows any sampled sequence and keeps its domain (ORD-3).
    public static func buildPartialBlock<I, M: SampledSequence, S: SequenceStage>(accumulated: Pipeline<I, M>, next: S) -> Pipeline<I, M> {
        accumulated.appending(next)
    }

    /// Catches a `Tap` whose branch starts in another domain than the point it taps (O-15), with a message that says so.
    @available(*, unavailable, message: "A Tap starts in the domain of the point it taps: this branch begins with a stage that takes another domain than the pipeline delivers here. Tap where the signal is what the branch needs, or begin the branch with a stage that takes what stands before the Tap.")
    public static func buildPartialBlock<I, M, D, B>(accumulated: Pipeline<I, M>, next: Tap<D, B>) -> Pipeline<I, M> {
        accumulated
    }

    /// Catches a self-typed stage after a domain it does not take, with a message that says what decides it. A stock
    /// stage brings a sentence of its own, which names what it needs (ORD-4).
    @available(*, unavailable, message: "This stage takes another domain than the pipeline delivers at this point. The order of the stages decides what each one receives: put the stage that produces what it needs before it.")
    public static func buildPartialBlock<I, M, S: PipelineStage>(accumulated: Pipeline<I, M>, next: S) -> Pipeline<I, M> {
        accumulated
    }

    // MARK: A stage after a block of sequence stages

    /// Sequence stages one after another stay a chain without a domain of its own.
    public static func buildPartialBlock<S: SequenceStage>(accumulated: SequenceChain, next: S) -> SequenceChain {
        SequenceChain(stages: accumulated.stages + next.stageDescriptions)
    }

    /// The first self-typed stage after sequence stages gives the block its domain.
    public static func buildPartialBlock<S: PipelineStage>(accumulated: SequenceChain, next: S) -> Pipeline<S.Input, S.Output>
    where S.Input: SampledSequence {
        Pipeline(unchecked: accumulated.stages + next.stageDescriptions)
    }

    /// A sink of one sampled domain after sequence stages gives the block that domain.
    public static func buildPartialBlock<Sink: FeatureSink>(accumulated: SequenceChain, next: Emit<Sink>) -> Pipeline<Sink.Domain, Sink.Domain>
    where Sink.Domain: SampledSequence {
        Pipeline(unchecked: accumulated.stages + [next.stageDescription])
    }

    /// Catches an `Emit` after sequence stages alone whose sink does not take a sampled sequence, with a message that says which does.
    @available(*, unavailable, message: "Emit needs a sink that can hold the frames before it: after sequence stages alone the block carries a sampled sequence, which a FeatureStream or a FeatureCallback of samples, of a novelty curve or of a scalar track takes. A HeatmapFeed or a Binding<[Float]> takes real vectors, a WaveformFeed takes an envelope, a Binding<Float> or Binding<ScalarFrame> takes a scalar or a novelty value: put the stage that produces them before the Emit.")
    public static func buildPartialBlock<Target>(accumulated: SequenceChain, next: Emit<Target>) -> SequenceChain {
        accumulated
    }

    // MARK: Emit, the reference family (O-11)

    /// A sink of one domain takes the frames of a pipeline that ends in it.
    public static func buildPartialBlock<I, Sink: FeatureSink>(accumulated: Pipeline<I, Sink.Domain>, next: Emit<Sink>) -> Pipeline<I, Sink.Domain> {
        accumulated.appending(next.stageDescription)
    }

    /// A `Binding<Float>` or `Binding<ScalarFrame>` takes the values of a scalar domain (OUT-2).
    public static func buildPartialBlock<I, D: ScalarValuedDomain>(accumulated: Pipeline<I, D>, next: Emit<ScalarBindingTarget>) -> Pipeline<I, D> {
        accumulated.appending(next.stageDescription)
    }

    /// A `Binding<[Float]>` takes the frames of a domain of real vectors (OUT-5).
    public static func buildPartialBlock<I, D: RealVectorDomain>(accumulated: Pipeline<I, D>, next: Emit<VectorBindingTarget>) -> Pipeline<I, D> {
        accumulated.appending(next.stageDescription)
    }

    /// A `HeatmapFeed` takes the frames of a domain of real vectors as its columns.
    public static func buildPartialBlock<I, D: RealVectorDomain>(accumulated: Pipeline<I, D>, next: Emit<HeatmapFeed>) -> Pipeline<I, D> {
        accumulated.appending(next.stageDescription)
    }

    /// A `WaveformFeed` takes the pairs of an envelope.
    public static func buildPartialBlock<I>(accumulated: Pipeline<I, Envelope>, next: Emit<WaveformFeed>) -> Pipeline<I, Envelope> {
        accumulated.appending(next.stageDescription)
    }

    /// Catches an `Emit` whose sink cannot hold the frames before it, with a message that says which can.
    @available(*, unavailable, message: "Emit needs a sink that can hold the frames before it: a HeatmapFeed or a Binding<[Float]> takes real vectors (not a complex spectrum, not samples), a WaveformFeed takes an envelope, a Binding<Float> or Binding<ScalarFrame> takes a scalar or a novelty value, a FeatureStream or FeatureCallback takes its own domain.")
    public static func buildPartialBlock<I, O, Target>(accumulated: Pipeline<I, O>, next: Emit<Target>) -> Pipeline<I, O> {
        accumulated
    }

    /// Catches a sequence stage after a domain that is not a sampled sequence, with a message that says why.
    @available(*, unavailable, message: "A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins; filtering each band along time is not part of this version.")
    public static func buildPartialBlock<I, O, S: SequenceStage>(accumulated: Pipeline<I, O>, next: S) -> Pipeline<I, O> {
        accumulated
    }

    // MARK: Control flow (API-2, ORD-3)

    /// `if` without `else`, on sequence stages: absent, the block contributes nothing.
    public static func buildOptional(_ component: SequenceChain?) -> SequenceChain {
        component ?? SequenceChain()
    }

    /// `if` without `else`, on stages that keep the domain (O-13).
    public static func buildOptional<D>(_ component: Pipeline<D, D>?) -> Pipeline<D, D> {
        component ?? Pipeline(unchecked: [])
    }

    /// Catches a stage inside `if` without `else` that changes the domain (O-13), with a message that says why it cannot.
    @available(*, unavailable, message: "A stage inside `if` without `else` keeps the domain: the pipeline must be valid without it. Give the `if` an `else` that ends in the same domain, or take the stage out of the condition.")
    public static func buildOptional<I, O>(_ component: Pipeline<I, O>?) -> Pipeline<I, O> {
        component ?? Pipeline(unchecked: [])
    }

    /// `if … else` and `switch`: both branches have one type, so they end in one domain (O-14).
    public static func buildEither<Component: PipelineContent>(first component: Component) -> Component { component }
    /// The second branch of `if … else` and of `switch`.
    public static func buildEither<Component: PipelineContent>(second component: Component) -> Component { component }

    /// `for … in`, on sequence stages.
    public static func buildArray(_ components: [SequenceChain]) -> SequenceChain {
        SequenceChain(stages: components.flatMap(\.stages))
    }

    /// `for … in`, on stages that keep the domain (O-13).
    public static func buildArray<D>(_ components: [Pipeline<D, D>]) -> Pipeline<D, D> {
        Pipeline(unchecked: components.flatMap(\.stages))
    }

    /// Catches stages inside `for … in` that change the domain (O-13).
    @available(*, unavailable, message: "The stages inside `for … in` keep the domain: the loop may run any number of times, none included.")
    public static func buildArray<I, O>(_ components: [Pipeline<I, O>]) -> Pipeline<I, O> {
        Pipeline(unchecked: components.flatMap(\.stages))
    }

    /// `if #available`, on sequence stages.
    public static func buildLimitedAvailability(_ component: SequenceChain) -> SequenceChain { component }

    /// `if #available`, on stages that keep the domain (O-13).
    public static func buildLimitedAvailability<D>(_ component: Pipeline<D, D>) -> Pipeline<D, D> { component }

    /// Catches a stage inside `if #available` that changes the domain (O-13).
    @available(*, unavailable, message: "A stage inside `if #available` keeps the domain: the pipeline must be valid where the stage is not available.")
    public static func buildLimitedAvailability<I, O>(_ component: Pipeline<I, O>) -> Pipeline<I, O> { component }
}
