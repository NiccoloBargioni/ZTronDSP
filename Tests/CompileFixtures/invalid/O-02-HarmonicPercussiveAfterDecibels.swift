// expect: HarmonicPercussive needs the complex spectrum of an STFT, or magnitudes: put it directly after STFT, where it keeps the phase, or after Magnitude().
//
// O-2: decibels are not magnitudes.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); Decibels(); HarmonicPercussive(select: .percussive) }
