// expect: requires that 'ComplexValues' conform to 'LinearValued'
//
// O-5, in the fluent spelling: the compiler names the mismatched domain unaided.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 1_024, hop: 256).externalMelScale(bands: 40)
