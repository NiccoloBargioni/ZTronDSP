internal import CExtensionGuide
import Foundation
import ZTronDSP

// The extension guide, row 3 of §5.11.1: a sample-domain stage in C (Docs/ExtensionGuide.md).
// The kernel is extg_comb_create of the target CExtensionGuide.

// snippet:begin comb-stage
/// A feedback comb filter: the signal plus its own output of `delay` seconds ago, scaled by
/// `feedback`. A resonator, and the building block of a reverberator.
///
/// The stage runs on any sampled sequence and keeps its domain. An immutable value, usable on
/// any thread. `lower(_:)` runs on the control context.
public struct FeedbackComb: SequenceStage {
    /// What tells one comb from another: its delay in frames and its feedback.
    struct Key: Hashable, Sendable {
        let frames: UInt32
        let feedback: Float
    }

    /// The time between a sample and its echo, in seconds. Usable on any thread.
    public let delay: TimeInterval
    /// What each echo keeps of the one before, below 1 in magnitude. Usable on any thread.
    public let feedback: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(delay: TimeInterval, feedback: Double, isActive: some ActivationSource = .active) {
        self.delay = delay
        self.feedback = feedback
        self.activation = isActive.stageActivation
    }

    /// Emits the kernel. Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a delay of less than one frame at the sample
    ///   rate here, and for a feedback that is not below 1 in magnitude.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        // Seconds become frames at the sample rate of the stage's position (ENV-1).
        let frames = (delay * context.environment.sampleRate).rounded()
        guard frames >= 1, frames <= 16_777_216 else {
            throw context.invalid("delay", "\(delay) s is \(frames) frames at \(context.environment.sampleRate) Hz; an echo comes at least one frame late")
        }
        guard feedback.isFinite, abs(feedback) < 1 else {
            throw context.invalid("feedback", "a feedback of \(feedback) does not decay: its magnitude lies below 1")
        }
        let key = Key(frames: UInt32(frames), feedback: Float(feedback))
        // `make` runs on the control context when a plan needs the kernel; the plan owns the
        // kernel from then on and frees it through its `destroy`.
        context.emit(.custom(CustomKernel(name: "FeedbackComb", key: key, latencyFrames: 0) { channels, _, _ in
            extg_comb_create(UInt32(max(channels, 0)), key.frames, key.feedback)
        }))
    }
}
// snippet:end comb-stage

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a feedback comb filter: see ``FeedbackComb``. Usable on any
    /// thread.
    public func feedbackComb(delay: TimeInterval, feedback: Double, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(FeedbackComb(delay: delay, feedback: feedback, isActive: isActive))
    }
}
