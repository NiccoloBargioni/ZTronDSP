import SwiftUI
import ZTronDSPCore

/// The frame, the hop and the window of the transform a source-fed component runs: what
/// `.analysisFrame(_:hop:window:)` says, as the one value it puts into the environment (VC-4).
///
/// An immutable value, usable on any thread.
struct AnalysisFrame: Equatable, Sendable {
    /// Samples per frame.
    var frame: Int
    /// Samples from the start of one frame to the start of the next.
    var hop: Int
    /// What a frame is multiplied by before it is transformed.
    var window: Window

    /// What a component runs when no modifier says otherwise: the defaults of the recipes
    /// (§5.2).
    static let standard = AnalysisFrame(frame: 2_048, hop: 512, window: .hann)
}

// MARK: Keys

// Every analysis modifier sets one value in the SwiftUI environment (VC-4). The keys are
// internal: the modifiers are the API. `nil` means that no modifier said anything, and the
// component runs its recipe with the recipe's own defaults.
//
// Each default is one stored value, and each value is `Equatable`. A parent that is evaluated
// again makes its frame and its pipeline anew, in other storage, and sets them once more.
// The views that read the keys are not evaluated again for that (observed on iOS 27): the
// values are equal, though their bytes are not. So an equal value disturbs nothing below it
// (§8.4), and a component's body runs when a value really changes.

private struct AnalysisFrameKey: EnvironmentKey {
    static let defaultValue: AnalysisFrame? = nil
}

private struct MelBandsKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private struct ProcessingKey: EnvironmentKey {
    static let defaultValue: Pipeline<Samples, Samples>? = nil
}

extension EnvironmentValues {
    /// What `.analysisFrame(_:hop:window:)` set for the source-fed components of the hierarchy.
    var dspAnalysisFrame: AnalysisFrame? {
        get { self[AnalysisFrameKey.self] }
        set { self[AnalysisFrameKey.self] = newValue }
    }

    /// What `.melBands(_:)` set.
    var dspMelBands: Int? {
        get { self[MelBandsKey.self] }
        set { self[MelBandsKey.self] = newValue }
    }

    /// What `.processing(_:)` set: the pipeline a source-fed component puts in front of its
    /// recipe.
    var dspProcessing: Pipeline<Samples, Samples>? {
        get { self[ProcessingKey.self] }
        set { self[ProcessingKey.self] = newValue }
    }
}
