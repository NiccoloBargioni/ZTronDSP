// expect: A Tap starts in the domain of the point it taps
//
// O-15: a side branch starts in the domain of the point it taps: here it receives spectra, and a
// block that begins with an autocorrelation starts from samples.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Tap { Autocorrelation() } }
