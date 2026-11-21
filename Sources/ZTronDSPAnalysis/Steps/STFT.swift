import Foundation
import ZTronDSPCore

/// The short-time Fourier transform: samples in, one complex spectrum per hop out (§6.4.1).
/// It opens a spectral scope (§5.2): downstream, `frameSize`, `hopSize`, `featureRate` and
/// `frequencyAxis` are set.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512)                                       // Hann, causal
/// STFT(frame: 2_048, hop: 512, window: .kaiser(beta: 8.6), paddedTo: 4_096)
/// STFT(frame: 1_024, hop: 256, normalization: .amplitude, alignment: .centered)
/// ```
///
/// - The transform length is the frame, or `paddedTo`: each windowed frame is followed by
///   zeros up to that length. The bins are spaced more finely; no information is added, and
///   the frame still sets the resolution (§6.12). The length must be one the backend
///   transforms; another is refused when the pipeline is attached, with the nearest legal
///   lengths in the error (O-17).
/// - Spectra are one-sided, `length / 2 + 1` bins, and unscaled but for the window
///   normalisation asked for (§6.1).
/// - A frame's time is the time of the point it is aligned to: its last sample when causal,
///   its centre when centred. Centred framing adds half a frame of latency.
/// - A multichannel signal is reduced by `channels` (MIC-6).
/// - Equal `STFT`s at one position, in different taps, are computed once (F5).
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on any
/// thread. Its backend is kept boxed (`AnyStrategy`): creating one, and reading `backend`, allocate
/// only for a backend larger than three words, which the stock one is not. `lower(_:)` runs on the
/// control context and may allocate.
public struct STFT: PipelineStage {
    /// Audio samples.
    public typealias Input = Samples
    /// A one-sided complex spectrum on a linear-frequency axis.
    public typealias Output = Spectrum<LinearFrequency, ComplexValues>

    /// Samples per frame.
    public let frame: Int
    /// Samples between the starts of two frames.
    public let hop: Int
    /// The window each frame is multiplied by.
    public let window: Window
    /// The transform length when it is longer than the frame.
    public let paddedTo: Int?
    /// How the window scales the spectra: `.none`, `.amplitude` or `.power`.
    public let normalization: WindowNormalization
    /// What a frame's time is that of: its last sample when causal, its centre when centred.
    public let alignment: FrameAlignment
    /// How a signal of several channels is reduced (MIC-6): the mixdown unless told otherwise.
    public let channels: ChannelPolicy
    let backendBox: AnyStrategy
    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// Frames of `frame` samples every `hop` samples under `window`, transformed at `paddedTo`
    /// points when it is given, by the transform of `backend`. Nothing is checked here:
    /// `lower(_:)` checks the values when the plan is compiled (O-17, WIN-3).
    public init(
        frame: Int, hop: Int, window: Window = .hann, paddedTo: Int? = nil, normalization: WindowNormalization = .none,
        alignment: FrameAlignment = .causal, channels: ChannelPolicy = .mixdown, backend: some FFTBackend = .vDSP,
        isActive: some ActivationSource = .active
    ) {
        self.frame = frame
        self.hop = hop
        self.window = window
        self.paddedTo = paddedTo
        self.normalization = normalization
        self.alignment = alignment
        self.channels = channels
        self.backendBox = AnyStrategy(backend)
        self.activation = isActive.stageActivation
    }

    /// The transform backend the step was declared with.
    public var backend: any FFTBackend { backendBox.value(as: (any FFTBackend).self) ?? VDSPFFTBackend() }

    /// The transform length: the frame, or what it is padded to.
    public var transformLength: Int { paddedTo ?? frame }

    /// Checks the values (O-17, WIN-3) and emits the node; a logged window writes its analysis
    /// when the node is made (WIN-5). Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(try step(in: context)))
    }

    /// Everything that determines the node, and nothing else: equal keys at one position are
    /// one node (F5, SWAP-1).
    struct Key: Hashable, Sendable {
        let frame: Int
        let hop: Int
        let transformLength: Int
        let taper: [Float]
        let alignment: FrameAlignment
        let channel: Int?
        let backend: AnyStrategy
        /// A logged window writes its analysis when the node is made (WIN-5), so asking for
        /// the log on a running pipeline makes a new node.
        let logs: Bool
    }

    /// The attach-time checks (O-17, WIN-3) and the step they lead to.
    func step(in context: LoweringContext) throws(DSPError) -> AnalysisStep {
        let rate = context.environment.sampleRate
        guard rate > 0, rate.isFinite else { throw context.invalid("sampleRate", "an STFT needs a sample rate, and there is none here") }
        _ = try StageValidation.value(frame, named: "frame", atLeast: 1, context: context)
        if let paddedTo {
            guard paddedTo >= frame else {
                throw context.invalid("paddedTo", "a frame of \(frame) samples cannot be padded to \(paddedTo): padding makes the transform longer than the frame")
            }
        }
        let length = try StageValidation.transformLength(transformLength, named: paddedTo == nil ? "frame" : "paddedTo", in: context)
        _ = try StageValidation.hop(hop, frame: frame, named: "hop", in: context)
        let backend = backend
        guard backend.supports(length: length) else {
            throw context.invalid("backend", "\(type(of: backend)) does not transform frames of \(length) points")
        }
        let channel = try ChannelSelection.resolve(channels, in: context)
        let sampled = try SampledWindow(window, frame: frame)
        let taper = sampled.taper(factor: try normalization.factor(window: sampled.double, transformLength: length))

        let bins = length / 2 + 1
        let key = Key(frame: frame, hop: hop, transformLength: length, taper: taper, alignment: alignment, channel: channel,
                      backend: backendBox, logs: window.isLogged)
        let frame = frame, hop = hop, alignment = alignment, window = window
        let channelCount = max(context.environment.channelCount, 1), blockFrames = context.maximumBlockFrames
        return AnalysisStep(
            name: "STFT", key: key, output: .complex(count: bins),
            scope: .spectral(frameSize: frame, hopSize: hop, axis: .linearFrequency(binCount: bins, nyquist: rate / 2)),
            latency: alignment == .centered ? Double(frame / 2) / rate : 0
        ) { () throws(DSPError) -> any AnalysisNode in
            if window.isLogged { WindowDiagnostics.logAttachment(of: window, frame: frame, hop: hop) }
            return try STFTNode(
                frame: frame, hop: hop, taper: taper, alignment: alignment, plan: backend.makePlan(length: length),
                mixer: ChannelMixer(channel: channel, channelCount: channelCount, maximumFrames: blockFrames), sampleRate: rate)
        }
    }
}

extension Pipeline where Output == Samples {
    /// The short-time Fourier transform of the signal: see ``STFT``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func stft(
        frame: Int, hop: Int, window: Window = .hann, paddedTo: Int? = nil, normalization: WindowNormalization = .none,
        alignment: FrameAlignment = .causal, channels: ChannelPolicy = .mixdown, backend: some FFTBackend = .vDSP,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<LinearFrequency, ComplexValues>> {
        appending(STFT(frame: frame, hop: hop, window: window, paddedTo: paddedTo, normalization: normalization, alignment: alignment,
                       channels: channels, backend: backend, isActive: isActive))
    }
}
