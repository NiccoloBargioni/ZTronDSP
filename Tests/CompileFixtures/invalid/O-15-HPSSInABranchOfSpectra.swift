// expect: A Tap starts in the domain of the point it taps
//
// O-15: a side branch starts in the domain of the point it taps: here it receives spectra, not samples.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); HarmonicPercussive(select: .harmonic); Tap { HPSS(select: .percussive) } }
