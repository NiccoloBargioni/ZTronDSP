// expect: ExternalLowPass runs on a sampled sequence: samples, a novelty curve or a scalar track.
//
// O-1: a filter after the mel projection of the suite. The sentence is the stage's own and names it (ORD-4).
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40); ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
