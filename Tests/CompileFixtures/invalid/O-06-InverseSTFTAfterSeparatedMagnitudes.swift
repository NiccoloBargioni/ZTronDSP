// expect: InverseSTFT needs the complex linear-frequency spectrum of an STFT
//
// O-6: a component separated from magnitudes has no phase to go back with. Separate the complex
// spectrum instead: STFT, HarmonicPercussive, InverseSTFT, which is what HPSS is.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); HarmonicPercussive(select: .harmonic); InverseSTFT() }
