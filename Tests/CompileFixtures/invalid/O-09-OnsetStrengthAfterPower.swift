// expect: OnsetStrength needs a spectrum in decibels: put Decibels() before it, after Magnitude() or Power() and, by custom, MelScale().
//
// O-9: what the onset strength sums are rises of level; powers are not levels.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); OnsetStrength() }
