import Foundation
import ZTronDSPCore

/// The inverse short-time Fourier transform: complex spectra in, samples out (§6.4.1). It is
/// overlap-add with window-sum-of-squares normalisation: each frame is transformed back,
/// multiplied by the window again, added in at its hop, and every finished sample is divided
/// by the sum of the squared windows that reached it.
///
/// ```swift
/// let analysis = STFT(frame: 2_048, hop: 512, window: .hann)
/// Pipeline {
///     analysis
///     // … change the spectrum …
///     analysis.inverse                    // the InverseSTFT that matches it
/// }
/// ```
///
/// The synthesis has to be told what the analysis did: its window, its window normalisation
/// and its alignment. The defaults are those of `STFT`, so `InverseSTFT()` undoes `STFT(frame:hop:)`,
/// and `STFT.inverse` gives the match of any other. The frame, the hop and the transform
/// length are read from the spectral scope it sits in.
///
/// - The window and the hop must satisfy the non-zero overlap-add condition,
///   `Σₖ w²(n − k·hop) > 0` for every `n`; a pair that does not is refused when the pipeline
///   is attached (O-17, WIN-3).
/// - The output is one channel, in blocks of one hop, delayed by `frame − hop` samples against
///   the signal that entered the `STFT`: that is how long a sample waits for the last frame
///   that covers it. The delay is reported as latency (REAL-5), and the output begins with
///   that many zeros, as the output of a filter does.
/// - With a constant-overlap-add window the reconstruction is exact to the round-off of the
///   transform (SNR ≥ 100 dB). §6.13 gives the report.
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on
/// any thread; `lower(_:)` runs on the control context.
public struct InverseSTFT: PipelineStage {
    public typealias Input = Spectrum<LinearFrequency, ComplexValues>
    public typealias Output = Samples

    /// The window of the analysis, applied again by the synthesis.
    public let window: Window
    /// The window normalisation of the analysis, undone by the synthesis.
    public let normalization: WindowNormalization
    /// The alignment of the analysis.
    public let alignment: FrameAlignment
    let backendBox: AnyStrategy
    public let activation: StageActivation
    /// False only for the round trip of an inversion report, which measures what a window
    /// that fails the overlap-add condition loses instead of refusing it (INV-3).
    let enforcesOverlapAdd: Bool

    public init(
        window: Window = .hann, normalization: WindowNormalization = .none, alignment: FrameAlignment = .causal,
        backend: some FFTBackend = .vDSP, isActive: some ActivationSource = .active
    ) {
        self.window = window
        self.normalization = normalization
        self.alignment = alignment
        self.backendBox = AnyStrategy(backend)
        self.activation = isActive.stageActivation
        self.enforcesOverlapAdd = true
    }

    /// The transform backend the step was declared with.
    public var backend: any FFTBackend { backendBox.value(as: (any FFTBackend).self) ?? VDSPFFTBackend() }

    struct Key: Hashable, Sendable {
        let frame: Int
        let hop: Int
        let transformLength: Int
        let window: [Float]
        let scale: Float
        let alignment: FrameAlignment
        let backend: AnyStrategy
    }

    /// Samples the output is delayed by against the input of the analysis: what a sample
    /// waits for the last frame that covers it, and never less than the analysis already
    /// declared.
    static func delay(frame: Int, hop: Int, alignment: FrameAlignment) -> (total: Int, own: Int) {
        let analysis = alignment == .centered ? frame / 2 : 0
        let total = max(analysis, frame - hop)
        return (total, total - analysis)
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let environment = context.environment
        let rate = environment.sampleRate
        guard let frame = environment.frameSize, let hop = environment.hopSize, frame >= 1, hop >= 1, hop <= frame, rate > 0,
              case .linearFrequency(let bins, _)? = environment.frequencyAxis, bins >= 2
        else {
            throw DSPError.unsupportedConfiguration(
                reason: "InverseSTFT needs the frames of an STFT: there is no frame, hop and linear-frequency axis at this position", stage: context.path)
        }
        let length = 2 * (bins - 1)
        guard length >= frame else {
            throw context.invalid("frame", "spectra of \(bins) bins come from a transform of \(length) points, which is shorter than the frame of \(frame)")
        }
        _ = try StageValidation.transformLength(length, named: "transform length", in: context)
        let backend = backend
        guard backend.supports(length: length) else {
            throw context.invalid("backend", "\(type(of: backend)) does not transform frames of \(length) points")
        }
        let sampled = try SampledWindow(window, frame: frame)
        let factor = try normalization.factor(window: sampled.double, transformLength: length)
        let bounds = OverlapAdd.frameBounds(sampled.double, hop: hop)
        guard OverlapAdd.isNonZero(bounds) || !enforcesOverlapAdd else {
            let passing = [frame / 2, frame / 3, frame / 4].first { $0 >= 1 && $0 < hop && OverlapAdd.isNonZero(OverlapAdd.frameBounds(sampled.double, hop: $0)) }
            let advice = passing.map { " A hop of \($0) passes." } ?? ""
            throw context.invalid(
                "window", "\(window) with a hop of \(hop) samples fails the non-zero overlap-add condition: the least value of Σ w²(n − k·hop) is \(bounds.least) against a greatest of \(bounds.greatest), so some samples cannot be recovered.\(advice)")
        }

        let delay = InverseSTFT.delay(frame: frame, hop: hop, alignment: alignment)
        let window = sampled.single, scale = Float(1 / factor), alignment = alignment
        let key = Key(frame: frame, hop: hop, transformLength: length, window: window, scale: scale, alignment: alignment, backend: backendBox)
        context.emit(.analysis(AnalysisStep(
            name: "InverseSTFT", key: key, output: .samples(channelCount: 1, maximumFrames: hop),
            scope: .samples(maximumBlockFrames: hop, channelCount: 1), latency: Double(delay.own) / rate
        ) { () throws(DSPError) -> any AnalysisNode in
            try InverseSTFTNode(frame: frame, hop: hop, window: window, scale: scale, alignment: alignment, preroll: delay.total,
                                ownDelay: delay.own, plan: backend.makePlan(length: length), sampleRate: rate)
        }))
    }
}

extension Pipeline where Output == Spectrum<LinearFrequency, ComplexValues> {
    /// Back to samples by overlap-add: see ``InverseSTFT``.
    public func inverseSTFT(
        window: Window = .hann, normalization: WindowNormalization = .none, alignment: FrameAlignment = .causal,
        backend: some FFTBackend = .vDSP, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(InverseSTFT(window: window, normalization: normalization, alignment: alignment, backend: backend, isActive: isActive))
    }
}

extension STFT {
    /// The synthesis that undoes this analysis: an `InverseSTFT` with its window, its
    /// normalisation, its alignment and its backend (INV-1).
    public var inverse: InverseSTFT {
        InverseSTFT(window: window, normalization: normalization, alignment: alignment, backendBox: backendBox, activation: .active)
    }
}

extension InverseSTFT {
    init(window: Window, normalization: WindowNormalization, alignment: FrameAlignment, backendBox: AnyStrategy, activation: StageActivation,
         enforcesOverlapAdd: Bool = true) {
        self.window = window
        self.normalization = normalization
        self.alignment = alignment
        self.backendBox = backendBox
        self.activation = activation
        self.enforcesOverlapAdd = enforcesOverlapAdd
    }
}
