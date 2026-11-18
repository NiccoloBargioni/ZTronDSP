// expect: Autocorrelation needs a sampled sequence: samples, a novelty curve or a scalar track.
//
// O-1: lags are a frame of values, not a sequence in time.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { Autocorrelation(); Autocorrelation(window: 64, hop: 8) }
