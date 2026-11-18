// expect: ExternalGain runs on a sampled sequence: samples, a novelty curve or a scalar track.
//
// O-1: the gain is a sequence stage; a spectrum is not a sequence in time. The sentence is the
// stage's own and names it (ORD-4); the core's sentence for every sequence stage names the kind.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); ExternalGain(.decibels(-6)) }
