import Foundation
import ZTronDSPCore

// The sentences of the order rules for the correlation steps (ORD-4): see `OrderDiagnostics.swift`
// for how the catch-alls work. `Convolve` is a sequence stage and brings the sentence of the
// sequence stages; `Autocorrelation` is a family of its own.

extension PipelineBuilder {
    @available(*, unavailable, message: "Autocorrelation needs a sampled sequence: samples, a novelty curve or a scalar track. It frames the sequence itself and cannot follow a spectrum or any other frame of bins: put it where the signal is still a sequence, or in a Tap that starts there.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Autocorrelation) -> Pipeline<I, O> { accumulated }
}
