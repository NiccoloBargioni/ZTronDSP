// expect: requires that 'Spectrum<LinearFrequency, ComplexValues>' conform to 'SampledSequence'
//
// O-1, in the fluent spelling: the compiler names the mismatched domain unaided.
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 1_024, hop: 256).autocorrelation()
