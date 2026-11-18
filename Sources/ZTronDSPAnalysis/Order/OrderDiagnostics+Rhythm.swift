import Foundation
import ZTronDSPCore

// The sentences of the order rules for the onset strength and the tempograms (ORD-4, O-9):
// see `OrderDiagnostics.swift` for how the catch-alls work.

extension PipelineBuilder {
    @available(*, unavailable, message: "A block cannot begin with OnsetStrength: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.onsetStrength() }.")
    public static func buildPartialBlock(first: OnsetStrength) -> Pipeline<Spectrum<MelFrequency, DecibelValues>, Novelty> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "OnsetStrength needs a spectrum in decibels: put Decibels() before it, after Magnitude() or Power() and, by custom, MelScale(). What it sums are rises of level, and samples, complex bins, magnitudes and powers are not levels.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: OnsetStrength) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "OnsetStrength needs a spectrum in decibels: put Decibels() before it, after Magnitude() or Power() and, by custom, MelScale(). What it sums are rises of level, and samples, complex bins, magnitudes and powers are not levels.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: OnsetStrength) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels. Sequence stages may stand between the two; samples, spectra and scalar tracks are not onset strengths.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Tempogram) -> Pipeline<I, O> { accumulated }

    // There is no catch-all for a Tempogram after sequence stages alone. Such a block has no
    // domain of its own and a Tempogram gives it the novelty curve it takes, by the core's
    // rule for a self-typed stage after sequence stages: `Pipeline { Gain(…); Tempogram() }`
    // is a pipeline from a novelty curve, as its type says. It is refused where it has to
    // start from samples: after a stage that delivers them, with the sentence above, and by
    // `attach`, which takes a pipeline from samples (O-12), in the compiler's own words. An
    // unavailable overload cannot say more: the available one of the core is always preferred.
}
