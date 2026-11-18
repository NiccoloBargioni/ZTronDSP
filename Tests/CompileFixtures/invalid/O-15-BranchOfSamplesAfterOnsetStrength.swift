// expect: A Tap starts in the domain of the point it taps
//
// O-15: a side branch starts in the domain of the point it taps: here it receives a novelty curve,
// not samples.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Tap { STFT(frame: 512, hop: 128) } }
