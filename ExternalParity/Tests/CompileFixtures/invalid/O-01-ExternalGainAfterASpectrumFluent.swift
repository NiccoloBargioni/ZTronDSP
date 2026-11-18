// expect: conform to 'SampledSequence'
//
// O-1, in the fluent spelling: the compiler names the constraint unaided.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 1_024, hop: 256).externalGain(.decibels(-6))
