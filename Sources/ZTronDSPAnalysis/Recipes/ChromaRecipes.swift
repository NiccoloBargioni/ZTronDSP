import Foundation
import ZTronDSPCore

// The recipe of §6.8 (§5.2): a stage defined entirely by what it expands to. A pipeline that
// holds it equals a pipeline that holds its expansion, description for description, and both
// compile to the same plan: an equal `ConstantQ` in another tap is computed once (F5).

/// Chroma from a constant-Q transform into a feed or a binding:
/// `Tap { ConstantQ; Magnitude; ChromaFold; Emit }` (§6.8).
///
/// ```swift
/// let chromagram = HeatmapFeed(history: 940)
/// Pipeline { ChromaCQT(to: chromagram) }
/// ```
///
/// The samples pass on unchanged: the analysis is a side branch. The arguments are those of
/// ``ConstantQ`` and of ``ChromaFold``; `binsPerOctave` must be a multiple of 12. A
/// `HeatmapFeed` receives every frame, with the twelve pitch classes as its rows; a
/// `Binding<[Float]>` receives a new array of twelve values per delivery, at the result rate
/// (OUT-5). The frames describe the signal a latency ago, that of the transform's longest
/// atom: `gamma` above 0 shortens it. Switched off, the branch is suspended (ACT-3). An
/// immutable value, usable on any thread.
public struct ChromaCQT: Recipe {
    public typealias Input = Samples
    public typealias Output = Samples

    public let expansion: Pipeline<Samples, Samples>
    public let activation: StageActivation

    public init(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, gamma: Double = 0, hop: Int = 512,
        normalization: some ChromaNormalization = .max, threshold: Double = 0, to feed: HeatmapFeed,
        isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                ConstantQ(fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, gamma: gamma, hop: hop)
                Magnitude()
                ChromaFold(normalization: normalization, threshold: threshold)
                Emit(to: feed)
            }
        }
    }

    public init(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, gamma: Double = 0, hop: Int = 512,
        normalization: some ChromaNormalization = .max, threshold: Double = 0, to binding: some VectorResultTarget,
        isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        expansion = Pipeline {
            Tap(isActive: isActive) {
                ConstantQ(fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, gamma: gamma, hop: hop)
                Magnitude()
                ChromaFold(normalization: normalization, threshold: threshold)
                Emit(to: binding)
            }
        }
    }
}

extension Pipeline where Output == Samples {
    /// Chroma of the signal into a feed; the samples pass on: see ``ChromaCQT``.
    public func chromaCQT(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, gamma: Double = 0, hop: Int = 512,
        normalization: some ChromaNormalization = .max, threshold: Double = 0, to feed: HeatmapFeed,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(ChromaCQT(
            fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, gamma: gamma, hop: hop, normalization: normalization,
            threshold: threshold, to: feed, isActive: isActive))
    }

    /// Chroma of the signal into a binding; the samples pass on: see ``ChromaCQT``.
    public func chromaCQT(
        fmin: Frequency = .midiNote(24), octaves: Int = 7, binsPerOctave: Int = 36, tuning: Double = 0, gamma: Double = 0, hop: Int = 512,
        normalization: some ChromaNormalization = .max, threshold: Double = 0, to binding: some VectorResultTarget,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(ChromaCQT(
            fmin: fmin, octaves: octaves, binsPerOctave: binsPerOctave, tuning: tuning, gamma: gamma, hop: hop, normalization: normalization,
            threshold: threshold, to: binding, isActive: isActive))
    }
}
