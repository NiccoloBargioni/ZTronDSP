// expect: requires the types 'Spectrum<MelFrequency, PowerValues>' and 'Spectrum<MelFrequency, DecibelValues>' be equivalent
//
// O-9, in the fluent spelling: the compiler names the two domains unaided.
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 2_048, hop: 512).power().melScale(bands: 128).onsetStrength()
