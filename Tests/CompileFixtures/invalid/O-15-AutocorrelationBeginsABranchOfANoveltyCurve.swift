// expect: A Tap starts in the domain of the point it taps
//
// O-15: a block that begins with an autocorrelation is taken to start from samples, as a block of
// sequence stages is; the lags of a novelty curve are tapped fluently, as
// .tap { $0.autocorrelation(window: 384, hop: 1) }.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Tap { Autocorrelation(window: 384, hop: 1) } }
