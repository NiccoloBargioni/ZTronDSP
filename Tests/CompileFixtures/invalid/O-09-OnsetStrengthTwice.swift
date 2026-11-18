// expect: OnsetStrength needs a spectrum in decibels: put Decibels() before it, after Magnitude() or Power() and, by custom, MelScale().
//
// O-9: a novelty curve is not a spectrum.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); OnsetStrength() }
