import Foundation
import ZTronDSP

// The extension guide, row 1 of §5.11.1: a step between domains (Docs/ExtensionGuide.md).

// snippet:begin flux-stage
/// The spectral flux of a magnitude spectrum: how much the bins rose since the frame before,
/// summed over the bins. One value per hop, so the chain goes on as a novelty curve.
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct SpectralFlux: PipelineStage {
    public typealias Input = Spectrum<LinearFrequency, MagnitudeValues>
    public typealias Output = Novelty

    /// The step's switch (§5.9). Switched off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// Emits the node. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        // The positional environment says what arrives here: how many bins, how often.
        let environment = context.environment
        guard let bins = environment.frequencyAxis?.rowCount, let rate = environment.featureRate, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(
                reason: "SpectralFlux needs the frames of a spectral scope, and there is none at this position", stage: context.path)
        }
        // One value per frame: downstream is a sampled sequence at the feature rate.
        context.emit(.analysis(AnalysisStep(name: "SpectralFlux", key: bins, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in
            try SpectralFluxNode(bins: bins)
        }))
    }
}
// snippet:end flux-stage

// snippet:begin flux-node
/// What runs a `SpectralFlux`.
///
/// Threading: created on the control context, where it allocates the frame it remembers.
/// `process` and `reset` belong to the analysis thread: no allocation, no lock, no logging
/// (RT-2), and the loop is a `while` loop. One thread at a time.
final class SpectralFluxNode: AnalysisNode {
    private let bins: Int
    private let previous: AlignedBuffer<Float>
    private var hasPrevious = false

    /// The flux of a frame is stamped with that frame: nothing is delayed.
    var latencyFrames: Int { 0 }
    /// One frame after a cold start the node has the frame it compares with.
    var settlingFrames: Int { 1 }

    init(bins: Int) throws(DSPError) {
        self.bins = bins
        previous = try AlignedBuffer<Float>(count: max(bins, 1))
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= bins, let current = frame.values.baseAddress else { return }
        let last = previous.baseAddress
        if hasPrevious {
            var flux: Float = 0
            var bin = 0
            while bin < bins {
                let rise = current[bin] - last[bin]
                if rise > 0 { flux += rise }
                bin &+= 1
            }
            output.emit(scalar: ScalarFrame(value: flux))
        }
        // The first frame after a cold start has nothing to be compared with: no frame is written.
        previous.copy(from: current, count: bins)
        hasPrevious = true
    }

    func reset() {
        hasPrevious = false
    }
}
// snippet:end flux-node

extension Pipeline where Output == Spectrum<LinearFrequency, MagnitudeValues> {
    /// The spectral flux of the magnitudes, as a novelty curve: see ``SpectralFlux``. Usable on
    /// any thread.
    public func spectralFlux(isActive: some ActivationSource = .active) -> Pipeline<Input, Novelty> {
        appending(SpectralFlux(isActive: isActive))
    }
}
