// expect: Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels.
//
// O-9: a column of a tempogram is not a novelty curve.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Tempogram(); Tempogram(.fourier) }
