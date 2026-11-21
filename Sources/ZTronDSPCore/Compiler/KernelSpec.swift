import Foundation

/// One second-order section as the run-time kernels take it:
/// `y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]` (a0 = 1).
public struct BiquadSection: Hashable, Sendable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// A section that passes its input unchanged.
    public static let identity = BiquadSection(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// The five numbers in the order the kernels take them.
    public var coefficients: [Double] { [b0, b1, b2, a1, a2] }
}

/// How the environment changes downstream of an analysis step (ENV-1, §5.2).
public enum ScopeChange: Hashable, Sendable {
    /// The step keeps the scope it is in.
    case none
    /// A framing step: downstream is a spectral scope with this frame, hop and axis.
    case spectral(frameSize: Int, hopSize: Int, axis: FeedAxis)
    /// The step changes what the rows of a frame are: a mel projection, a cepstrum, lags.
    case axis(FeedAxis)
    /// The step produces one value per frame: downstream is a new sampled sequence at `rate`
    /// values per second, outside any spectral scope.
    case featureSequence(rate: Double)
    /// The step returns to samples, in blocks of at most `maximumBlockFrames` frames.
    case samples(maximumBlockFrames: Int, channelCount: Int)
}

/// An analysis step as a stage emits it: what the node will produce and how to make it.
///
/// Two steps are the same step when their names, keys, formats, scope changes and latencies
/// are equal. Equal steps at the same position in different branches are computed once (F5),
/// and an unchanged step keeps its node across a plan change (SWAP-1), so make `key` the
/// value that determines the node: usually the stage itself.
public struct AnalysisStep: Hashable, Sendable {
    public let name: String
    public let key: AnyStrategy
    /// The shape of the frames the node writes.
    public let output: FrameFormat
    public let scope: ScopeChange
    /// The delay the step adds, in seconds (REAL-5).
    public let latency: TimeInterval
    let make: @Sendable () throws(DSPError) -> any AnalysisNode

    /// - Parameter make: creates the node. It runs on the control context, once per plan that
    ///   needs a new node, and may allocate and throw.
    public init(
        name: String, key: some Hashable & Sendable, output: FrameFormat, scope: ScopeChange = .none, latency: TimeInterval = 0,
        make: @escaping @Sendable () throws(DSPError) -> any AnalysisNode
    ) {
        self.name = name
        self.key = AnyStrategy(key)
        self.output = output
        self.scope = scope
        self.latency = latency
        self.make = make
    }

    public static func == (lhs: AnalysisStep, rhs: AnalysisStep) -> Bool {
        lhs.name == rhs.name && lhs.key == rhs.key && lhs.output == rhs.output && lhs.scope == rhs.scope && lhs.latency == rhs.latency
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(key)
        hasher.combine(output)
    }
}

/// A sample-domain stage backed by the caller's own C kernel (§5.11.1).
///
/// `make` receives the channel count and the sample rate at the stage's position and returns
/// a `ztd_kernel_t` whose state it allocated; the plan owns the kernel from then on and frees
/// it through its `destroy`. A kernel with its own code is a fusion barrier (EXT-2).
///
/// A description has two parts (§5.5.4). Its structure, the name, the key, the rate ratio, the
/// latency and the number of values, says which kernel it is: another structure is another
/// kernel, made anew. Its `values` say what the kernel is set to: other values of the same
/// number are sent to the kernel that runs, and nothing is compiled.
///
/// An immutable value, usable on any thread; `make` runs on the control context.
public struct CustomKernel: Hashable, Sendable {
    /// The name of the stage, as errors and the description of the plan show it.
    public let name: String
    /// What tells this kernel from another of the same name: two descriptions with equal names
    /// and keys are the same stage, and an update keeps the kernel's state (SWAP-1).
    public let key: AnyStrategy
    /// The stage's continuous values, in the order the kernel takes them: a gain, the
    /// coefficients of a filter (§5.5.4). They stand outside the identity. When an update
    /// changes them and nothing else, the kernel that runs is handed the new ones through its
    /// `command` entry, on the analysis thread at a block boundary, as
    /// `ZTD_COMMAND_SET_VALUES` with `count` doubles at `values` (memory the engine owns and
    /// frees off that thread; the kernel copies what it needs). The kernel keeps its state,
    /// and a kernel that is moved into a later plan keeps the values it was sent last. A
    /// change of their number is a change of structure. Empty for a kernel without values.
    /// Usable on any thread.
    public let values: [Double]
    /// Output frames per input frame, as a ratio: 1 and 1 for a kernel that keeps the rate.
    public let interpolation: Int
    /// The denominator of that ratio.
    public let decimation: Int
    /// The delay the kernel adds, in input frames (REAL-5). It must equal the
    /// `latency_frames` of the kernel `make` returns.
    public let latencyFrames: Int
    /// Makes the kernel, set to the values of this description.
    let make: @Sendable (_ channelCount: Int, _ sampleRate: Double, _ maximumFrames: Int) -> ztd_kernel_t

    /// A kernel without values: everything that tells it from another is in `key`.
    ///
    /// - Parameter make: creates the kernel for the channel count, the sample rate and the
    ///   largest block at the stage's position. Control context; may allocate. A kernel whose
    ///   `process` is null is taken as a failed allocation.
    public init(
        name: String, key: some Hashable & Sendable, interpolation: Int = 1, decimation: Int = 1, latencyFrames: Int = 0,
        make: @escaping @Sendable (_ channelCount: Int, _ sampleRate: Double, _ maximumFrames: Int) -> ztd_kernel_t
    ) {
        self.name = name
        self.key = AnyStrategy(key)
        self.values = []
        self.interpolation = max(interpolation, 1)
        self.decimation = max(decimation, 1)
        self.latencyFrames = max(latencyFrames, 0)
        self.make = make
    }

    /// A kernel with values that can change while it runs (§5.5.4).
    ///
    /// Any thread, typically the control context in `lower(_:)`; allocates (the description
    /// keeps a copy of `values`). Nothing of `make` runs here.
    ///
    /// - Parameters:
    ///   - key: the structure of the stage, without its values: an order, a family, a strategy.
    ///   - values: the stage's continuous values; see ``values``.
    ///   - make: creates the kernel for the channel count, the sample rate and the largest
    ///     block at the stage's position, set to `values`. Control context; may allocate. A
    ///     kernel whose `process` is null is taken as a failed allocation. When `values` is
    ///     not empty the kernel has a `command` entry that takes `ZTD_COMMAND_SET_VALUES`:
    ///     a plan with a kernel that could never be given its values is refused.
    public init(
        name: String, key: some Hashable & Sendable, values: [Double], interpolation: Int = 1, decimation: Int = 1, latencyFrames: Int = 0,
        make: @escaping @Sendable (_ channelCount: Int, _ sampleRate: Double, _ maximumFrames: Int, _ values: [Double]) -> ztd_kernel_t
    ) {
        self.name = name
        self.key = AnyStrategy(key)
        self.values = values
        self.interpolation = max(interpolation, 1)
        self.decimation = max(decimation, 1)
        self.latencyFrames = max(latencyFrames, 0)
        self.make = { channelCount, sampleRate, maximumFrames in make(channelCount, sampleRate, maximumFrames, values) }
    }

    public static func == (lhs: CustomKernel, rhs: CustomKernel) -> Bool {
        lhs.hasSameStructure(as: rhs) && lhs.values == rhs.values
    }

    /// True when the two describe one kernel, set to the same values or to others (§5.5.4).
    func hasSameStructure(as other: CustomKernel) -> Bool {
        name == other.name && key == other.key && interpolation == other.interpolation && decimation == other.decimation
            && latencyFrames == other.latencyFrames && values.count == other.values.count
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(key)
    }
}

/// A sample-domain stage written in Swift (§5.11.1): a factory for a `SampleProcessor`.
///
/// As for a `CustomKernel`, the name, the key, the latency and the number of values say which
/// processor it is, and the `values` what it is set to (§5.5.4).
///
/// An immutable value, usable on any thread; `make` runs on the control context.
public struct CustomProcessor: Hashable, Sendable {
    /// The name of the stage, as errors and the description of the plan show it.
    public let name: String
    /// What tells this processor from another of the same name: two descriptions with equal
    /// names and keys are the same stage, and an update keeps the processor (SWAP-1).
    public let key: AnyStrategy
    /// The stage's continuous values, in the order the processor takes them (§5.5.4). They
    /// stand outside the identity. When an update changes them and nothing else, the
    /// processor that runs is handed the new ones through
    /// `AdjustableSampleProcessor.setValues(_:)`, on the analysis thread between two blocks;
    /// it keeps its state, and a processor that is moved into a later plan keeps the values
    /// it was sent last. A change of their number is a change of structure. Empty for a
    /// processor without values. Usable on any thread.
    public let values: [Double]
    /// The delay the processor adds, in frames (REAL-5). It must equal the `latencyFrames`
    /// of the processor `make` returns.
    public let latencyFrames: Int
    /// Makes the processor, set to the values of this description.
    let make: @Sendable (DSPEnvironment) throws(DSPError) -> any SampleProcessor
    /// The same for a description that states values: the processor as the one that takes
    /// new values while it runs. `nil` for a description without values.
    let makeAdjustable: (@Sendable (DSPEnvironment) throws(DSPError) -> any AdjustableSampleProcessor)?

    /// A processor without values: everything that tells it from another is in `key`.
    ///
    /// - Parameter make: creates the processor for the environment at the stage's position.
    ///   Control context; may allocate and throw.
    public init(
        name: String, key: some Hashable & Sendable, latencyFrames: Int = 0,
        make: @escaping @Sendable (DSPEnvironment) throws(DSPError) -> any SampleProcessor
    ) {
        self.name = name
        self.key = AnyStrategy(key)
        self.values = []
        self.latencyFrames = max(latencyFrames, 0)
        self.make = make
        self.makeAdjustable = nil
    }

    /// A processor with values that can change while it runs (§5.5.4).
    ///
    /// Any thread, typically the control context in `lower(_:)`; allocates (the description
    /// keeps a copy of `values`). Nothing of `make` runs here.
    ///
    /// - Parameters:
    ///   - key: the structure of the stage, without its values.
    ///   - values: the stage's continuous values; see ``values``.
    ///   - make: creates the processor for the environment at the stage's position, set to
    ///     `values`. Control context; may allocate and throw.
    public init(
        name: String, key: some Hashable & Sendable, values: [Double], latencyFrames: Int = 0,
        make: @escaping @Sendable (DSPEnvironment, _ values: [Double]) throws(DSPError) -> any AdjustableSampleProcessor
    ) {
        self.name = name
        self.key = AnyStrategy(key)
        self.values = values
        self.latencyFrames = max(latencyFrames, 0)
        self.make = { (environment: DSPEnvironment) throws(DSPError) -> any SampleProcessor in try make(environment, values) }
        self.makeAdjustable = { (environment: DSPEnvironment) throws(DSPError) -> any AdjustableSampleProcessor in try make(environment, values) }
    }

    public static func == (lhs: CustomProcessor, rhs: CustomProcessor) -> Bool {
        lhs.hasSameStructure(as: rhs) && lhs.values == rhs.values
    }

    /// True when the two describe one processor, set to the same values or to others (§5.5.4).
    func hasSameStructure(as other: CustomProcessor) -> Bool {
        name == other.name && key == other.key && latencyFrames == other.latencyFrames && values.count == other.values.count
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(key)
    }
}

/// What a stage lowers to: a closed set of stock kernels, plus a kernel or a processor of the
/// caller's own, plus an analysis node (§5.5.3, pass 3).
///
/// A stage that lowers to stock specs is fused like a stock stage; one with its own kernel is
/// a fusion barrier (EXT-2). Each spec is bound to an implementation by its size when the plan
/// is compiled (SEL-3).
public enum KernelSpec: Hashable, Sendable {
    /// `out = in · factor`, every channel alike. A changed factor ramps over `ramp` seconds.
    case gain(factor: Float, ramp: TimeInterval)
    /// Gains applied one after another, every channel alike: what adjacent gains fuse into
    /// (F1). The factors are applied in sequence, not multiplied into one, so the output is
    /// bit-identical to that of the separate gains.
    case gainCascade(factors: [Float], ramp: TimeInterval)
    /// A gain per channel.
    case channelGains(factors: [Float], ramp: TimeInterval)
    /// Second-order sections in series, in single or double precision (REAL-1, REAL-3).
    /// `.automatic` is not a precision a kernel can run in: the stage resolves it first.
    case biquad(sections: [BiquadSection], precision: BiquadPrecision)
    /// An FIR; `latency` is its delay in frames, (taps − 1) / 2 when it is linear-phase.
    case fir(taps: [Float], latency: Int)
    /// Low-pass by `taps`, then keep every `factor`-th sample.
    case decimator(factor: Int, taps: [Float], latency: Int)
    /// Insert zeros, then low-pass by `taps` with gain `factor`, as a polyphase filter.
    case interpolator(factor: Int, taps: [Float], latency: Int)
    /// Keep every `factor`-th sample, starting at `phase`. No filter.
    case subsample(factor: Int, phase: Int)
    /// Insert `factor − 1` zeros after each sample. No filter.
    case zeroStuff(factor: Int)
    /// The two-state tracker; outputs the position, or the velocity.
    case alphaBeta(alpha: Float, beta: Float, initialPosition: Float, initialVelocity: Float, outputVelocity: Bool)
    /// A C kernel of the caller's own.
    case custom(CustomKernel)
    /// A Swift processor of the caller's own.
    case processor(CustomProcessor)
    /// An analysis node.
    case analysis(AnalysisStep)

    /// Output frames per input frame, as (interpolation, decimation).
    public var rate: (interpolation: Int, decimation: Int) {
        switch self {
        case .decimator(let factor, _, _), .subsample(let factor, _): (1, max(factor, 1))
        case .interpolator(let factor, _, _), .zeroStuff(let factor): (max(factor, 1), 1)
        case .custom(let kernel): (kernel.interpolation, kernel.decimation)
        default: (1, 1)
        }
    }

    /// True for a spec that keeps the rate.
    public var keepsRate: Bool {
        let ratio = rate
        return ratio.interpolation == ratio.decimation
    }

    /// The delay the spec declares, in input frames. A custom kernel or a processor reports
    /// its own when it is created.
    public var latencyFrames: Int {
        switch self {
        case .fir(_, let latency), .decimator(_, _, let latency), .interpolator(_, _, let latency): max(latency, 0)
        case .custom(let kernel): kernel.latencyFrames
        case .processor(let processor): processor.latencyFrames
        default: 0
        }
    }

    /// True for a spec that does nothing: a unity gain, a cascade without sections, an FIR
    /// that is a single unit tap. Such a kernel is removed (F4).
    public var isIdentity: Bool {
        switch self {
        case .gain(let factor, _): factor == 1
        case .gainCascade(let factors, _), .channelGains(let factors, _): factors.allSatisfy { $0 == 1 }
        case .biquad(let sections, _): sections.isEmpty
        case .fir(let taps, let latency): taps == [1] && latency == 0
        default: false
        }
    }

    /// True for an identity that is one by the values it holds and would be a kernel of the
    /// same structure with other values: a gain at 0 dB, a single unit tap. A cascade without
    /// sections is an identity by its structure and is not one of these.
    var isIdentityByValue: Bool {
        switch self {
        case .gain, .gainCascade, .channelGains, .fir: isIdentity
        default: false
        }
    }
}

extension KernelSpec {
    /// The values of the spec as a command carries them to the kernel that runs it (§5.5.4,
    /// and the kernels' documentation): floats for gains and taps, doubles for coefficients
    /// and for the values of a kernel or a processor of the caller's own, in memory the
    /// caller owns and frees once the command has been applied. `nil` for a spec whose values
    /// are its structure: such a kernel takes none by command.
    func commandPayload() -> (pointer: UnsafeMutableRawPointer, count: Int)? {
        func floats(_ values: [Float]) -> (UnsafeMutableRawPointer, Int) {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
            pointer.initialize(from: values, count: values.count)
            return (UnsafeMutableRawPointer(pointer), values.count)
        }
        func doubles(_ values: [Double]) -> (UnsafeMutableRawPointer, Int) {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: max(values.count, 1))
            pointer.initialize(from: values, count: values.count)
            return (UnsafeMutableRawPointer(pointer), values.count)
        }
        switch self {
        case .gain(let factor, _):
            return floats([factor])
        case .gainCascade(let factors, _), .channelGains(let factors, _):
            return floats(factors)
        case .fir(let taps, _):
            return floats(taps)
        case .biquad(let sections, _):
            return doubles(sections.flatMap(\.coefficients))
        case .custom(let kernel):
            return kernel.values.isEmpty ? nil : doubles(kernel.values)
        case .processor(let processor):
            return processor.values.isEmpty ? nil : doubles(processor.values)
        case .decimator, .interpolator, .subsample, .zeroStuff, .alphaBeta, .analysis:
            return nil
        }
    }
}
