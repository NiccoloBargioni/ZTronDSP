// expect: Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels.
//
// O-9: a spectrum in decibels is what the onset strength takes, not the tempogram.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); Tempogram() }
