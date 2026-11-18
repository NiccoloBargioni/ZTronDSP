import Foundation
import ZTronDSPCore

// The sentences of the order rules of the constant-Q transform and chroma (ORD-4): one
// catch-all overload per step family and per self-typed step, marked unavailable, whose
// message names the stage and says what it needs. The compiler prefers an available
// overload, so none of these is ever chosen where a stage is in its place; the
// must-not-compile fixtures assert on the sentences. The fluent spelling needs none of this:
// a constrained method reports the mismatched domains unaided.

extension PipelineBuilder {
    // MARK: A block cannot begin with a context-dependent step (ORD-3)

    @available(*, unavailable, message: "A block cannot begin with ConstantQScale: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.constantQScale() }.")
    public static func buildPartialBlock(first: ConstantQScale) -> Pipeline<Spectrum<LinearFrequency, MagnitudeValues>, Spectrum<ConstantQFrequency, MagnitudeValues>> {
        Pipeline(unchecked: [])
    }

    // MARK: The family

    @available(*, unavailable, message: "ConstantQScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it. For a spectrum that keeps its phase, use ConstantQ() on the samples instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ConstantQScale) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "ConstantQScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it. For a spectrum that keeps its phase, use ConstantQ() on the samples instead.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: ConstantQScale) -> SequenceChain { accumulated }

    // MARK: The self-typed steps

    @available(*, unavailable, message: "ConstantQ needs samples: it frames the signal and cannot follow a spectrum, a cepstrum or any other frame of bins. For a constant-Q axis on the magnitudes or powers of an STFT, use ConstantQScale(); for a second analysis, start a Tap where the signal is still samples.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ConstantQ) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "ChromaFold needs the magnitudes of a constant-Q spectrum: put it after ConstantQ() and Magnitude(), or after Magnitude() and ConstantQScale(). The bins of an STFT are not spaced by semitones, and complex values, powers and decibels are not what a pitch class sums.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ChromaFold) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "ChromaFold needs the magnitudes of a constant-Q spectrum: put it after ConstantQ() and Magnitude(), or after Magnitude() and ConstantQScale(). The bins of an STFT are not spaced by semitones, and complex values, powers and decibels are not what a pitch class sums.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: ChromaFold) -> SequenceChain { accumulated }

    // MARK: The recipe

    @available(*, unavailable, message: "ChromaCQT needs samples: it taps the signal and analyses it itself. After a constant-Q spectrum, write Magnitude(), ChromaFold() and Emit(to:) instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ChromaCQT) -> Pipeline<I, O> { accumulated }
}
