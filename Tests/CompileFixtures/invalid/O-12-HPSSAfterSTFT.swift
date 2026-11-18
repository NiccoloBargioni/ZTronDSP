// expect: HPSS needs samples: it transforms the signal, separates it and returns samples itself.
//
// A recipe that frames the signal starts from samples.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); HPSS(select: .harmonic) }
