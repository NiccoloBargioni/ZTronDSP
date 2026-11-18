// expect: (aka 'Pipeline<Spectrum<MelFrequency, DecibelValues>, TempoSpectrum>')
//
// O-12: `attach(Pipeline { OnsetStrength() … })`. Written inside the call, the pipeline is
// refused in the compiler's own words: it names the spectrum the block would have to start
// from, where `attach` takes a pipeline from samples.
import SwiftUI
import ZTronDSP

func wrong(engine: DSPEngine, source: any SampleSource) async throws {
    _ = try await engine.attach(Pipeline { OnsetStrength(); Tempogram() }, to: source)
}
