import Foundation
import ZTronDSPCore

// The sentences of the order rules for the harmonic–percussive separation (ORD-4): see
// `OrderDiagnostics.swift` for how the catch-alls work.

extension PipelineBuilder {
    @available(*, unavailable, message: "A block cannot begin with HarmonicPercussive: its domains depend on the stage before it. Begin the block with the stage it follows, or write the branch fluently, as .tap { $0.harmonicPercussive(select: .harmonic) }.")
    public static func buildPartialBlock(first: HarmonicPercussive) -> Pipeline<Spectrum<LinearFrequency, ComplexValues>, Spectrum<LinearFrequency, ComplexValues>> {
        Pipeline(unchecked: [])
    }

    @available(*, unavailable, message: "HarmonicPercussive needs the complex spectrum of an STFT, or magnitudes: put it directly after STFT, where it keeps the phase, or after Magnitude(). Its medians are taken of magnitudes, which powers and decibels are not, and samples have no bins yet.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: HarmonicPercussive) -> Pipeline<I, O> { accumulated }

    @available(*, unavailable, message: "HarmonicPercussive needs the complex spectrum of an STFT, or magnitudes: put it directly after STFT, where it keeps the phase, or after Magnitude(). Its medians are taken of magnitudes, which powers and decibels are not, and samples have no bins yet.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: HarmonicPercussive) -> SequenceChain { accumulated }

    @available(*, unavailable, message: "HPSS needs samples: it transforms the signal, separates it and returns samples itself. After a spectrum, write HarmonicPercussive(select:) and InverseSTFT() instead.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: HPSS) -> Pipeline<I, O> { accumulated }
}
