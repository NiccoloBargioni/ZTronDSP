// expect: requires the types 'Spectrum<LinearFrequency, ComplexValues>' and 'Samples' be equivalent
//
// A recipe that frames the signal starts from samples; in the fluent spelling the compiler names
// the two domains unaided.
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 2_048, hop: 512).hpss(select: .harmonic)
