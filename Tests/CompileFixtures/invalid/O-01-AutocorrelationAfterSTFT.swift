// expect: Autocorrelation needs a sampled sequence: samples, a novelty curve or a scalar track.
//
// O-1: an autocorrelation frames a sampled sequence itself; the bins of a spectrum are not one.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Autocorrelation() }
