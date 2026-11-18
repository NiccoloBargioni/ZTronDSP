import Foundation
import ZTronDSPCore

/// The constant-Q transform: samples in, one complex spectrum per hop out, on bins spaced by
/// a constant ratio, `binsPerOctave` to the octave (§6.8). It opens a spectral scope (§5.2):
/// downstream, `hopSize`, `featureRate` and `frequencyAxis` are set, and `frameSize` is the
/// length of the longest atom.
///
/// ```swift
/// ConstantQ()                                                    // C1 up, 7 octaves, 36 bins each, hop 512
/// ConstantQ(fmin: .midiNote(36), octaves: 5, binsPerOctave: 12)  // C2 up, one bin per semitone
/// ConstantQ(gamma: 20)                                           // variable-Q: shorter atoms at the bottom
/// ```
///
/// - Bin `k` is centred on `fmin · 2^((k + tuning) / binsPerOctave)`; its atom is a window
///   `⌈Q · sampleRate / (fₖ + γ/α)⌉` samples long with `α = 2^(1/binsPerOctave) − 1` and
///   `Q = filterScale / α` (``ConstantQGeometry``). `tuning`, in fractions of a bin, moves the
///   bin centres: it belongs to the transform, not to the folding into chroma. With `gamma`
///   above 0 hertz the transform is variable-Q: the low atoms are shorter, and so is the
///   delay.
/// - A sine at the centre of a bin reads its own amplitude in that bin.
/// - Frame `n` is centred on sample `n · hop`, with the signal taken as zero before it
///   starts, and its time is the time of that sample. A frame is complete when the longest
///   atom has seen its last sample: the step's latency is half the longest atom, plus what
///   the strategy's filters delay the signal by. It is declared, so everything downstream
///   knows it (REAL-5); in real time `gamma` is the lever on it.
/// - `strategy` is how the transform is computed (§5.3). Under `.multirateSparseKernel` the
///   hop must be a multiple of `2^(octaves − 1)`: another hop is refused when the pipeline is
///   attached, with the nearest hops that are (O-17). So are bins that reach the Nyquist
///   frequency at the step's position, and what else the strategy cannot compute.
/// - `sparsity` is the share of a kernel row's summed magnitude that may be dropped; no row
///   loses more than 0.1 % of its energy, whatever it is set to.
/// - A multichannel signal is reduced by `channels` (MIC-6).
/// - Equal `ConstantQ`s at one position, in different taps, are computed once (F5).
///
/// The transform has no inverse here (§6.13). Switched off, it suspends the rest of its
/// branch (ACT-3). An immutable value, usable on any thread; `lower(_:)` runs on the control
/// context.
public struct ConstantQ: PipelineStage {
    public typealias Input = Samples
    public typealias Output = Spectrum<ConstantQFrequency, ComplexValues>

    /// The centre of the lowest bin, before tuning.
    public let fmin: Frequency
    /// How many octaves the bins span.
    public let octaves: Int
    /// Bins per octave.
    public let binsPerOctave: Int
    /// The offset of every bin centre, in fractions of a bin.
    public let tuning: Double
    /// The factor on `Q`: above 1 the atoms are longer and the bins narrower.
    public let filterScale: Double
    /// The bandwidth every bin is widened by, in hertz: 0 for constant Q.
    public let gamma: Double
    /// Samples between two frames.
    public let hop: Int
    /// The window of the atoms.
    public let window: Window
    /// The share of a kernel row's summed magnitude that may be dropped.
    public let sparsity: Double
    public let channels: ChannelPolicy
    let strategyBox: AnyStrategy
    public let activation: StageActivation

    public init(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, filterScale: Double = 1,
        gamma: Double = 0, hop: Int = 512, window: Window = .hann, sparsity: Double = 0.01,
        strategy: some ConstantQStrategy = .multirateSparseKernel, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) {
        self.fmin = fmin
        self.octaves = octaves
        self.binsPerOctave = binsPerOctave
        self.tuning = tuning
        self.filterScale = filterScale
        self.gamma = gamma
        self.hop = hop
        self.window = window
        self.sparsity = sparsity
        self.channels = channels
        self.strategyBox = AnyStrategy(strategy)
        self.activation = isActive.stageActivation
    }

    /// The strategy the step was declared with.
    public var strategy: any ConstantQStrategy {
        strategyBox.value(as: (any ConstantQStrategy).self) ?? MultirateSparseKernelStrategy()
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(try step(in: context)))
    }

    /// Everything that determines the node, and nothing else: equal keys at one position are
    /// one node (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let geometry: ConstantQGeometry
        let hop: Int
        let window: Window
        let sparsity: Double
        let channel: Int?
        let strategy: AnyStrategy
    }

    /// The bins at the sample rate of a position, checked.
    func geometry(in context: LoweringContext) throws(DSPError) -> ConstantQGeometry {
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "a constant-Q transform needs a sample rate, and there is none here") }
        let lowest = try StageValidation.frequency(fmin, named: "fmin", in: context)
        return try ConstantQGeometry(
            minimumFrequency: lowest, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, filterScale: filterScale, gamma: gamma,
            sampleRate: rate)
    }

    /// The attach-time checks (O-17) and the step they lead to.
    func step(in context: LoweringContext) throws(DSPError) -> AnalysisStep {
        let geometry = try geometry(in: context)
        _ = try StageValidation.value(hop, named: "hop", atLeast: 1, context: context)
        guard sparsity >= 0, sparsity < 1 else {
            throw context.invalid("sparsity", "the sparsity is the share of a kernel row that may be dropped, from 0 up to but not 1, not \(sparsity)")
        }
        guard !window.isHalf else {
            throw context.invalid("window", "\(window) covers the first half of a frame only: an atom needs a window over its whole length")
        }
        let channel = try ChannelSelection.resolve(channels, in: context)
        let strategy = strategy
        let latency = try strategy.latency(of: geometry, hop: hop, window: window, sparsity: sparsity)
        guard latency >= 0 else { throw context.invalid("strategy", "\(type(of: strategy)) states a latency of \(latency) samples") }

        let hop = hop, window = window, sparsity = sparsity
        let channelCount = max(context.environment.channelCount, 1), blockFrames = context.maximumBlockFrames
        return AnalysisStep(
            name: "ConstantQ", key: Key(geometry: geometry, hop: hop, window: window, sparsity: sparsity, channel: channel, strategy: strategyBox),
            output: .complex(count: geometry.binCount),
            scope: .spectral(frameSize: geometry.atomLength(ofBin: 0), hopSize: hop, axis: geometry.axis),
            latency: Double(latency) / geometry.sampleRate
        ) { () throws(DSPError) -> any AnalysisNode in
            try strategy.makeNode(
                of: geometry, hop: hop, window: window, sparsity: sparsity, channel: channel, channelCount: channelCount,
                maximumBlockFrames: blockFrames)
        }
    }
}

extension Pipeline where Output == Samples {
    /// The constant-Q transform of the signal: see ``ConstantQ``.
    public func constantQ(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, filterScale: Double = 1,
        gamma: Double = 0, hop: Int = 512, window: Window = .hann, sparsity: Double = 0.01,
        strategy: some ConstantQStrategy = .multirateSparseKernel, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<ConstantQFrequency, ComplexValues>> {
        appending(ConstantQ(
            fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, filterScale: filterScale, gamma: gamma, hop: hop,
            window: window, sparsity: sparsity, strategy: strategy, channels: channels, isActive: isActive))
    }
}
