// expect: to expected argument type 'Pipeline<Samples, Spectrum<MelFrequency, PowerValues>>'
//
// O-12: only a pipeline that starts from samples is attached; one that the step opens fluently on a spectrum is not.
import ExternalStages
import SwiftUI
import ZTronDSP

let branch = Pipeline<Spectrum<LinearFrequency, PowerValues>, Spectrum<LinearFrequency, PowerValues>>(unchecked: []).externalMelScale(bands: 40)
func attach(_ engine: DSPEngine, _ source: BufferSource) async throws { _ = try await engine.attach(branch, to: source) }
