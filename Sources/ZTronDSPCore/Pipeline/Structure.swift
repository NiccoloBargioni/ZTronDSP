// The constructs that give a pipeline its shape and keep the domain (§5.2): Tap, Group,
// EnvironmentReader and Emit. They live in the core target because they process nothing.

// MARK: Tap

/// A side branch. It reads the signal at its position and leaves the main line untouched, so
/// the main line can stay in the time domain while branches analyse it. Branches nest.
///
/// A branch starts in the domain of the point it taps (O-15): `STFT(…); Tap { STFT(…) }` does
/// not compile, because the branch would receive spectra, not samples.
///
/// Switched off, a tap suspends its branch: nothing in it runs and its sinks receive nothing
/// (ACT-3). Framing steps shared with other branches keep running for them (ACT-9).
///
/// An immutable value, usable on any thread; describing it allocates.
public struct Tap<Domain: SignalDomain, BranchOutput: SignalDomain>: PipelineStage {
    /// The domain tapped: the branch starts in it.
    public typealias Input = Domain
    /// The same domain: the main line passes the tap unchanged.
    public typealias Output = Domain

    let branch: [StageDescription]
    /// The tap's switch: off, it suspends its branch (ACT-3).
    public let activation: StageActivation

    /// A branch from a block of stages. Runs the block where it is called, on any thread, and
    /// allocates the branch.
    public init(isActive: some ActivationSource = .active, @PipelineBuilder _ content: () -> Pipeline<Domain, BranchOutput>) {
        self.branch = content().stages
        self.activation = isActive.stageActivation
    }

    init(branch: [StageDescription], activation: StageActivation) {
        self.branch = branch
        self.activation = activation
    }

    /// One description of kind `tap`, which holds the branch.
    public var stageDescriptions: [StageDescription] {
        [StageDescription(name: "Tap", rule: .any, activation: activation, content: .tap(branch))]
    }

    /// Never called: the plan compiler lowers a tap from its description.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

extension Tap where Domain == Samples, BranchOutput == Samples {
    /// A branch of sequence stages only. Such a block has no domain of its own; in a `Tap` it is
    /// taken to tap samples. On another sampled sequence, write the branch fluently:
    /// `.tap { $0.lowPass(…) }`. Runs the block where it is called, on any thread, and allocates
    /// the branch.
    public init(isActive: some ActivationSource = .active, @PipelineBuilder _ content: () -> SequenceChain) {
        self.init(branch: content().stages, activation: isActive.stageActivation)
    }
}

extension Pipeline {
    /// A side branch, written fluently: the closure receives an empty pipeline at this point and
    /// returns the branch. The main line continues from the same point. Runs the closure where it
    /// is called, on any thread, and allocates the pipeline it returns.
    public func tap<BranchOutput: SignalDomain>(
        isActive: some ActivationSource = .active,
        _ branch: (Pipeline<Output, Output>) -> Pipeline<Output, BranchOutput>
    ) -> Pipeline<Input, Output> {
        let content = branch(Pipeline<Output, Output>(unchecked: []))
        return appending(Tap<Output, BranchOutput>(branch: content.stages, activation: isActive.stageActivation))
    }
}

// MARK: Group

/// A named run of stages, switched or given an environment as one. It has the type of its
/// content.
///
/// A stage with a bound activation is not fused with its neighbours, because it must be
/// removable on its own. To switch several stages as one fused unit, wrap them in
/// `Group(isActive:)`: the stages inside fuse with one another (ACT-6).
///
/// SwiftUI has a `Group` of its own. Inside a pipeline block the compiler tells the two
/// apart; where it cannot (a group built on its own in a file that imports SwiftUI, then
/// given a modifier), write `ZTronDSP.Group`.
///
/// An immutable value, usable on any thread; building one allocates.
public struct Group<Content: PipelineContent>: StageValue {
    let content: Content
    /// The switch of the stages inside, as one.
    public let activation: StageActivation
    let overrides: [EnvironmentOverride]

    /// A group of the stages of `content` under one switch.
    public init(isActive: some ActivationSource = .active, @PipelineBuilder _ content: () -> Content) {
        self.content = content()
        self.activation = isActive.stageActivation
        self.overrides = []
    }

    init(content: Content, activation: StageActivation, overrides: [EnvironmentOverride]) {
        self.content = content
        self.activation = activation
        self.overrides = overrides
    }

    /// The group with a settable environment key overridden for the stages inside it (ENV-3).
    public func environment<K: SettableDSPEnvironmentKey>(
        _ keyPath: KeyPath<DSPEnvironment.SettableKeys, K.Type>, _ value: K.Value
    ) -> Group<Content> {
        let key = DSPEnvironment.SettableKeys()[keyPath: keyPath]
        let replaced = overrides.filter { $0.key != ObjectIdentifier(key) }
            + [EnvironmentOverride(key: ObjectIdentifier(key), value: AnyStrategy(value))]
        return Group(content: content, activation: activation, overrides: replaced)
    }

    /// One description of kind `group`, which holds the content and its environment overrides.
    public var stageDescriptions: [StageDescription] {
        [StageDescription(name: "Group", rule: .any, activation: activation, content: .group(content.stages, overrides: overrides))]
    }

    /// Never called: the plan compiler lowers a group from its description.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

extension Group: SequenceStage where Content == SequenceChain {}

extension Group: PipelineStage where Content: PipelineStage {
    /// The content's input domain. A type alias: no context runs it, and it allocates nothing.
    public typealias Input = Content.Input
    /// The content's output domain. A type alias: no context runs it, and it allocates nothing.
    public typealias Output = Content.Output
}

extension Pipeline {
    /// The pipeline with a settable environment key overridden for all of its stages (ENV-3).
    /// Returns a new pipeline; this one is unchanged (IMM-5). Usable on any thread; allocates the
    /// pipeline it returns.
    public func environment<K: SettableDSPEnvironmentKey>(
        _ keyPath: KeyPath<DSPEnvironment.SettableKeys, K.Type>, _ value: K.Value
    ) -> Pipeline<Input, Output> {
        let key = DSPEnvironment.SettableKeys()[keyPath: keyPath]
        let override = EnvironmentOverride(key: ObjectIdentifier(key), value: AnyStrategy(value))
        // A pipeline that is already one environment scope gains an override; no scope nests.
        if stages.count == 1, case .group(let inner, let overrides) = stages[0].content, !overrides.isEmpty,
           stages[0].activation == .active {
            let replaced = overrides.filter { $0.key != override.key } + [override]
            return Pipeline(unchecked: [StageDescription(name: "Group", rule: .any, activation: .active, content: .group(inner, overrides: replaced))])
        }
        return Pipeline(unchecked: [StageDescription(name: "Group", rule: .any, activation: .active, content: .group(stages, overrides: [override]))])
    }
}

// MARK: EnvironmentReader

/// Builds its content from the environment at its position (§5.4):
///
/// ```swift
/// EnvironmentReader { env in
///     LowPass(.butterworth, cutoff: .hertz(env.nyquistFrequency * 0.8), order: 6)
/// }
/// ```
///
/// The closure is a builder body with one return type, so its domains are known to the
/// compiler whatever the environment holds. It runs on the control context when the plan is
/// compiled, once per attachment and again after a format change.
///
/// The reader itself is an immutable value, usable on any thread; creating it allocates a box
/// for the closure.
public struct EnvironmentReader<Content: PipelineContent>: StageValue {
    let box: EnvironmentReaderBox

    /// A reader whose content `content` builds from the environment at its position.
    public init(@PipelineBuilder _ content: @escaping @Sendable (DSPEnvironment) -> Content) {
        self.box = EnvironmentReaderBox { content($0).stages }
    }

    /// One description of kind `environmentReader`; its content exists once it is resolved.
    public var stageDescriptions: [StageDescription] {
        [StageDescription(name: "EnvironmentReader", rule: .any, activation: .active, content: .reader(box))]
    }

    /// Never called: the plan compiler expands a reader in its resolve pass.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

extension EnvironmentReader: SequenceStage where Content == SequenceChain {}

extension EnvironmentReader: PipelineStage where Content: PipelineStage {
    /// The content's input domain. A type alias: no context runs it, and it allocates nothing.
    public typealias Input = Content.Input
    /// The content's output domain. A type alias: no context runs it, and it allocates nothing.
    public typealias Output = Content.Output
}

// MARK: Emit

/// Sends the current frames to a sink and passes them on, so several sinks, or more steps, can
/// follow (§5.2).
///
/// `Emit` is a step family (ORD-1): what it may follow depends on its sink. A `HeatmapFeed`
/// and a `Binding<[Float]>` take any domain whose frame is a vector of reals; a `WaveformFeed`
/// takes an envelope; a `Binding<Float>` or `Binding<ScalarFrame>` takes a scalar or a novelty
/// value; a `FeatureStream`, a `FeatureCallback` or a sink of your own takes its own domain
/// (O-11). Switched off, the frames pass and the sink receives nothing.
///
/// An immutable value, usable on any thread; describing it allocates.
public struct Emit<Target>: StageValue {
    let sink: SinkDescription
    /// The step's switch: off, the frames pass and the sink receives nothing.
    public let activation: StageActivation

    init(sink: SinkDescription, activation: StageActivation) {
        self.sink = sink
        self.activation = activation
    }

    /// The description of this step.
    public var stageDescription: StageDescription {
        StageDescription(name: "Emit", rule: sink.accepts, activation: activation, content: .emit(sink))
    }

    /// Never called: the plan compiler lowers a sink from its description.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}

/// Marks an `Emit` that writes a scalar result binding.
/// A type with no values, usable on any thread; it does not allocate.
public enum ScalarBindingTarget {}
/// Marks an `Emit` that writes a vector result binding.
/// A type with no values, usable on any thread; it does not allocate.
public enum VectorBindingTarget {}

extension Emit where Target: FeatureSink {
    /// Sends frames to a sink that takes one domain: a `FeatureStream`, a `FeatureCallback`, or a
    /// `FeatureSink` of your own. Usable on any thread; it allocates the description of its sink.
    public init(to sink: Target, isActive: some ActivationSource = .active) {
        let tag = Target.Domain.tag
        let rule = DomainRule.keeping("a sink of \(tag) frames") { $0 == tag }
        // A sink of the package knows the plan's own protocol and is told the shape of its
        // frames; any other is reached through the public one.
        let target: any NamedSink = (sink as? any NamedSink) ?? FeatureSinkAdapter(sink)
        self.init(sink: SinkDescription(target: .object(target, identity: ObjectIdentifier(sink)), accepts: rule),
                  activation: isActive.stageActivation)
    }
}

extension Emit where Target == HeatmapFeed {
    /// Sends each frame to a heat-map feed as one column. Follows any domain whose frame is a
    /// vector of reals: a real-valued spectrum, a cepstrum, chroma, lags, a tempogram (O-11).
    /// Usable on any thread; it may allocate, for the rule of its sink.
    public init(to feed: HeatmapFeed, isActive: some ActivationSource = .active) {
        let rule = DomainRule.keeping("a heat map of real vectors") { $0.isRealVector }
        self.init(sink: SinkDescription(target: .object(feed, identity: ObjectIdentifier(feed)), accepts: rule), activation: isActive.stageActivation)
    }
}

extension Emit where Target == WaveformFeed {
    /// Sends each (minimum, maximum) pair to a waveform feed. Follows an envelope (O-11). Usable on
    /// any thread; it may allocate, for the rule of its sink.
    public init(to feed: WaveformFeed, isActive: some ActivationSource = .active) {
        let rule = DomainRule.keeping("a waveform of envelope pairs") { $0 == .envelope }
        self.init(sink: SinkDescription(target: .object(feed, identity: ObjectIdentifier(feed)), accepts: rule), activation: isActive.stageActivation)
    }
}

extension Emit where Target == ScalarBindingTarget {
    /// Writes each scalar or novelty value to a `Binding<Float>` or a `Binding<ScalarFrame>`, on
    /// the main thread, at the result rate, and only when the value changed (§5.10). Usable on any
    /// thread; it may allocate, for the rule of its sink.
    public init(to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) {
        let rule = DomainRule.keeping("a binding of one value") { $0.isScalarValued }
        self.init(sink: SinkDescription(target: .result(binding.boundResult), accepts: rule), activation: isActive.stageActivation)
    }
}

extension Emit where Target == VectorBindingTarget {
    /// Writes each real-vector frame to a `Binding<[Float]>`: a new array per delivery, on the main
    /// thread, at the result rate. Meant for small frames such as chroma (OUT-5). Usable on any
    /// thread; it may allocate, for the rule of its sink.
    public init(to binding: some VectorResultTarget, isActive: some ActivationSource = .active) {
        let rule = DomainRule.keeping("a binding of a real vector") { $0.isRealVector }
        self.init(sink: SinkDescription(target: .result(binding.boundResult), accepts: rule), activation: isActive.stageActivation)
    }
}

extension Pipeline {
    /// Sends frames to a sink that takes this pipeline's output domain, and passes them on. Usable
    /// on any thread; allocates the pipeline it returns.
    public func emit<Sink: FeatureSink>(to sink: Sink, isActive: some ActivationSource = .active) -> Pipeline<Input, Output>
    where Sink.Domain == Output {
        appending(Emit<Sink>(to: sink, isActive: isActive).stageDescription)
    }
}

extension Pipeline where Output: ScalarValuedDomain {
    /// Writes each value to a `Binding<Float>` or a `Binding<ScalarFrame>` and passes it on. Usable
    /// on any thread; allocates the pipeline it returns.
    public func emit(to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Emit<ScalarBindingTarget>(to: binding, isActive: isActive).stageDescription)
    }
}

extension Pipeline where Output: RealVectorDomain {
    /// Sends each frame to a heat-map feed as one column, and passes it on. Usable on any thread;
    /// allocates the pipeline it returns.
    public func emit(to feed: HeatmapFeed, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Emit<HeatmapFeed>(to: feed, isActive: isActive).stageDescription)
    }

    /// Writes each frame to a `Binding<[Float]>` and passes it on. Usable on any thread; allocates
    /// the pipeline it returns.
    public func emit(to binding: some VectorResultTarget, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Emit<VectorBindingTarget>(to: binding, isActive: isActive).stageDescription)
    }
}

extension Pipeline where Output == Envelope {
    /// Sends each (minimum, maximum) pair to a waveform feed, and passes the frame on. Usable on
    /// any thread; allocates the pipeline it returns.
    public func emit(to feed: WaveformFeed, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Emit<WaveformFeed>(to: feed, isActive: isActive).stageDescription)
    }
}

extension Pipeline {
    /// Catches a heat-map feed after a domain it cannot hold, with a message that says what it
    /// takes (ORD-4). Never called, being unavailable: no context runs it, and it allocates
    /// nothing.
    @available(*, unavailable, message: "A HeatmapFeed takes frames of real values: a spectrum of magnitudes, powers or decibels, chroma, a cepstrum, lags or a tempogram. The pipeline delivers something else at this point (a complex spectrum, samples or a single value): put the stage that produces real vectors before emit(to:).")
    public func emit(to feed: HeatmapFeed, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> { self }

    /// Catches a waveform feed after a domain it cannot hold, with a message that says what it
    /// takes (ORD-4). Never called, being unavailable: no context runs it, and it allocates
    /// nothing.
    @available(*, unavailable, message: "A WaveformFeed takes an envelope, the (minimum, maximum) pairs a waveform step produces. The pipeline delivers something else at this point: put that step before emit(to:).")
    public func emit(to feed: WaveformFeed, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> { self }

    /// Catches a binding of one value after a domain that is not one value, with a message that
    /// says what it takes (ORD-4). Never called, being unavailable: no context runs it, and it
    /// allocates nothing.
    @available(*, unavailable, message: "A Binding<Float> or Binding<ScalarFrame> takes a scalar or a novelty value. The pipeline delivers something else at this point: put the step that reduces the signal to one value before emit(to:).")
    public func emit(to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> { self }

    /// Catches a binding of a vector after a domain that is not a real vector, with a message that
    /// says what it takes (ORD-4). Never called, being unavailable: no context runs it, and it
    /// allocates nothing.
    @available(*, unavailable, message: "A Binding<[Float]> takes frames of real values: a spectrum of magnitudes, powers or decibels, chroma, a cepstrum. The pipeline delivers something else at this point (a complex spectrum, samples or a single value): put the stage that produces real vectors before emit(to:).")
    public func emit(to binding: some VectorResultTarget, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> { self }
}

// MARK: The measuring spelling (OUT-1)

extension StageDescription {
    /// The measuring spelling of a step that reduces the signal to one value (OUT-1):
    /// `Tap { step; Emit(to: binding) }` as one description. The value goes to the binding,
    /// and the signal the step measured passes on unchanged, so the chain continues from the
    /// domain it was in.
    ///
    /// This is what a step family builds its `Step(…, to:)` spelling from; a self-typed step uses
    /// ``Measuring``. Usable on any thread; it allocates the description.
    public static func measuring(
        _ step: [StageDescription], to binding: some ScalarResultTarget, isActive: some ActivationSource = .active
    ) -> StageDescription {
        let emit = Emit<ScalarBindingTarget>(to: binding).stageDescription
        return StageDescription(name: "Tap", rule: .any, activation: isActive.stageActivation, content: .tap(step + [emit]))
    }
}

/// A step that reduces the signal to one value, in its measuring spelling (OUT-1): the value
/// is delivered to a binding and the signal passes on unchanged.
///
/// ```swift
/// Pipeline {
///     Measuring(Level(.rms), to: $level)           // measures; the samples pass on
///     HighPass(.butterworth, cutoff: .hertz(90), order: 4)
/// }
/// ```
///
/// It equals `Tap { step; Emit(to: binding) }`, description for description. Stock steps
/// offer the same thing as an initialiser, `Level(.rms, to: $level)`.
///
/// An immutable value, usable on any thread; describing it allocates.
public struct Measuring<Step: PipelineStage>: PipelineStage where Step.Output: ScalarValuedDomain {
    /// The measured step's input domain.
    public typealias Input = Step.Input
    /// The same domain: the signal passes on unchanged.
    public typealias Output = Step.Input

    let description: StageDescription

    /// - Parameters:
    ///   - step: the stage that measures; its value goes to `binding`, the signal goes on unchanged.
    ///   - binding: written on the main thread, at the result rate (§5.10).
    ///   - isActive: switches the measurement off without touching the signal.
    ///
    /// Usable on any thread; it allocates the description of the measuring tap.
    public init(_ step: Step, to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) {
        description = .measuring(step.stageDescriptions, to: binding, isActive: isActive)
    }

    /// The measurement's switch.
    public var activation: StageActivation { description.activation }

    /// The one description of the measuring tap.
    public var stageDescriptions: [StageDescription] { [description] }

    /// Never called: the plan compiler lowers a tap from its description.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        throw context.structuralStage()
    }
}
