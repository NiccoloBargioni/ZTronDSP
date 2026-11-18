// expect: (aka 'Pipeline<Novelty, TempoSpectrum>')
//
// O-12, O-9: `Gain → Tempogram`. A block of sequence stages has no domain of its own and takes
// that of the tempogram after it, so the pipeline starts from a novelty curve, as its type says;
// a source delivers samples. The compiler reports the two types in its own words.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

func wrong(engine: DSPEngine, source: any SampleSource) async throws {
    _ = try await engine.attach(Pipeline { Halve(); Tempogram() }, to: source)
}
