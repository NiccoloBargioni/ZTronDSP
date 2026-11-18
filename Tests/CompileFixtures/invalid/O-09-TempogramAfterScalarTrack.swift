// expect: Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels.
//
// O-9: a scalar track is a sampled sequence, and not an onset strength.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); SpectralCentroid(); Tempogram() }
