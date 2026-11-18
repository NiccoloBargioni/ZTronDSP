// expect: Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels.
//
// O-9: the autocorrelation tempogram correlates the novelty curve itself; it does not follow
// the lags of an Autocorrelation step.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Autocorrelation(window: 384, hop: 1); Tempogram() }
