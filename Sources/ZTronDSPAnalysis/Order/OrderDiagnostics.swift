import Foundation
import ZTronDSPCore

// The sentences of the order rules (ORD-4). With many overloads of `buildPartialBlock` the
// compiler's own report of a failed match is often unusable, so every rule the types enforce
// has a catch-all overload here, marked unavailable, whose message names the stage and says
// what it needs: one per step family and one per self-typed stock step, after a typed
// pipeline and after a block of sequence stages. The compiler prefers an available overload,
// so none of these is ever chosen where a stage is in its place; the must-not-compile
// fixtures assert on the sentences.
//
// The fluent spelling needs none of this: a constrained method reports the mismatched
// domains unaided.

extension PipelineBuilder {
    // MARK: A block cannot begin with a context-dependent step (ORD-3)
    //
    // The first line of a block is type-checked on its own, so a catch-all for it has to name
    // the domains the block would have. Each family names the spectrum it most often follows;
    // a branch that taps that spectrum then fails with the family's sentence, and one that
    // taps another fails with the compiler's own report (the limit E-21 records).

    @available(*, unavailable, message: "A block cannot begin with a step whose domains depend on the stage before it: begin the block with the stage it follows, or write the branch fluently, as .tap { $0.magnitude() }.")
    public static func buildPartialBlock<Step: ContextDependentStep>(first: Step) -> Pipeline<Samples, Samples> {
        Pipeline()
    }

    @available(*, unavailable, message: "A block cannot begin with Magnitude: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.magnitude() }.")
    public static func buildPartialBlock(first: Magnitude) -> Pipeline<Spectrum<LinearFrequency, ComplexValues>, Spectrum<LinearFrequency, MagnitudeValues>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with Power: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.power() }.")
    public static func buildPartialBlock(first: Power) -> Pipeline<Spectrum<LinearFrequency, ComplexValues>, Spectrum<LinearFrequency, PowerValues>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with Decibels: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.decibels() }.")
    public static func buildPartialBlock(first: Decibels) -> Pipeline<Spectrum<LinearFrequency, PowerValues>, Spectrum<LinearFrequency, DecibelValues>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with InverseDecibels: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.inverseDecibels(.power) }.")
    public static func buildPartialBlock<Values>(first: InverseDecibels<Values>) -> Pipeline<Spectrum<LinearFrequency, DecibelValues>, Spectrum<LinearFrequency, Values>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with MelScale: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.melScale(bands: 40) }.")
    public static func buildPartialBlock(first: MelScale) -> Pipeline<Spectrum<LinearFrequency, PowerValues>, Spectrum<MelFrequency, PowerValues>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with SpectralCentroid: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.spectralCentroid() }.")
    public static func buildPartialBlock(first: SpectralCentroid<Scalar>) -> Pipeline<Spectrum<LinearFrequency, MagnitudeValues>, Scalar> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "A block cannot begin with SpectralCentroid: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.spectralCentroid(to: binding) }.")
    public static func buildPartialBlock(first: SpectralCentroid<MeasuredSpectrum>) -> Pipeline<Spectrum<LinearFrequency, MagnitudeValues>, Spectrum<LinearFrequency, MagnitudeValues>> {
        Pipeline(unchecked: [])
    }

    // MARK: The families

    @available(*, unavailable, message: "Magnitude needs a complex spectrum: put it directly after STFT. Magnitudes, powers and decibels are already real, and samples have no bins yet.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Magnitude) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Magnitude needs a complex spectrum: put it directly after STFT. Magnitudes, powers and decibels are already real, and samples have no bins yet.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: Magnitude) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "Power needs a complex spectrum: put it directly after STFT. Magnitudes, powers and decibels are already real, and samples have no bins yet.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Power) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Power needs a complex spectrum: put it directly after STFT. Magnitudes, powers and decibels are already real, and samples have no bins yet.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: Power) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "Decibels needs magnitudes or powers: put Magnitude() or Power() before it. It cannot follow a complex spectrum, and the logarithm of a spectrum that is already in decibels means nothing.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Decibels) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Decibels needs magnitudes or powers: put Magnitude() or Power() before it. It cannot follow a complex spectrum, and the logarithm of a spectrum that is already in decibels means nothing.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: Decibels) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "InverseDecibels needs a spectrum in decibels: put it after Decibels().")
    public static func buildPartialBlock<I, O, Values>(accumulated: Pipeline<I, O>, next: InverseDecibels<Values>) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "InverseDecibels needs a spectrum in decibels: put it after Decibels().")
    public static func buildPartialBlock<Values>(accumulated: SequenceChain, next: InverseDecibels<Values>) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "MelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: MelScale) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "MelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: MelScale) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "SpectralCentroid needs magnitudes or powers on a linear-frequency axis: put it after Magnitude() or Power(), before MelScale() and Decibels(). Decibels are not energies, and over mel bands the same formula is not the centroid.")
    public static func buildPartialBlock<I, O, Continuation>(accumulated: Pipeline<I, O>, next: SpectralCentroid<Continuation>) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "SpectralCentroid needs magnitudes or powers on a linear-frequency axis: put it after Magnitude() or Power(), before MelScale() and Decibels(). Decibels are not energies, and over mel bands the same formula is not the centroid.")
    public static func buildPartialBlock<Continuation>(accumulated: SequenceChain, next: SpectralCentroid<Continuation>) -> SequenceChain { accumulated }

    // MARK: The self-typed steps

    @available(*, unavailable, message: "STFT needs samples: it frames the signal and cannot follow a spectrum, a cepstrum or any other frame of bins. For a second analysis, start a Tap where the signal is still samples.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: STFT) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "InverseSTFT needs the complex linear-frequency spectrum of an STFT: put it before Magnitude(), Power() or MelScale(), which discard the phase or the resolution it rebuilds the samples from.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: InverseSTFT) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "InverseSTFT needs the complex linear-frequency spectrum of an STFT: put it before Magnitude(), Power() or MelScale(), which discard the phase or the resolution it rebuilds the samples from.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: InverseSTFT) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "Level needs samples: it measures the signal over its own window and cannot follow a spectrum or a feature. Put it where the signal is still samples, or in a Tap that starts there.")
    public static func buildPartialBlock<I, O, Result>(accumulated: Pipeline<I, O>, next: Level<Result>) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Waveform needs samples: it reduces the signal to its envelope and cannot follow a spectrum or a feature. Put it in a Tap that starts where the signal is still samples.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Waveform) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Cepstrum needs the complex linear-frequency spectrum of an STFT: put it directly after STFT, before Magnitude() or Power() discard the phase.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Cepstrum) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Cepstrum needs the complex linear-frequency spectrum of an STFT: put it directly after STFT, before Magnitude() or Power() discard the phase.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: Cepstrum) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "InverseCepstrum needs a cepstrum: put it after Cepstrum(.complex), with any Lifter in between.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: InverseCepstrum) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "InverseCepstrum needs a cepstrum: put it after Cepstrum(.complex), with any Lifter in between.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: InverseCepstrum) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "Lifter needs a cepstrum: put it after Cepstrum. A spectrum is windowed over frequency, not over quefrency.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Lifter) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "Lifter needs a cepstrum: put it after Cepstrum. A spectrum is windowed over frequency, not over quefrency.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: Lifter) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "CepstralPitch needs a cepstrum: put it after Cepstrum, or after a Lifter that follows one.")
    public static func buildPartialBlock<I, O, Result>(accumulated: Pipeline<I, O>, next: CepstralPitch<Result>) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "CepstralPitch needs a cepstrum: put it after Cepstrum, or after a Lifter that follows one.")
    public static func buildPartialBlock<Result>(accumulated: SequenceChain, next: CepstralPitch<Result>) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "CepstralCoefficients needs a mel spectrum in decibels: put MelScale() and then Decibels() before it. The coefficients are defined on log energies.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: CepstralCoefficients) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "CepstralCoefficients needs a mel spectrum in decibels: put MelScale() and then Decibels() before it. The coefficients are defined on log energies.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: CepstralCoefficients) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "InverseCepstralCoefficients needs mel-frequency cepstral coefficients: put it after CepstralCoefficients.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: InverseCepstralCoefficients) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "InverseCepstralCoefficients needs mel-frequency cepstral coefficients: put it after CepstralCoefficients.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: InverseCepstralCoefficients) -> SequenceChain { accumulated }

    // MARK: The recipes

    @available(*, unavailable, message: "Spectrogram needs samples: it taps the signal and analyses it itself. After a spectrum, write Decibels() and Emit(to:) instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Spectrogram) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "MelSpectrogram needs samples: it taps the signal and analyses it itself. After a spectrum, write MelScale(), Decibels() and Emit(to:) instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: MelSpectrogram) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "MFCC needs samples: it taps the signal and analyses it itself. After a mel spectrum in decibels, write CepstralCoefficients() and Emit(to:) instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: MFCC) -> Pipeline<I, O> { accumulated }
}
