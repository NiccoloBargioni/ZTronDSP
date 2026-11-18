// expect: HarmonicPercussive needs the complex spectrum of an STFT, or magnitudes: put it directly after STFT, where it keeps the phase, or after Magnitude().
//
// O-2: of the complex spectra only that of an STFT is separated with its phase kept; a constant-Q
// spectrum is separated as magnitudes.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { ConstantQ(); HarmonicPercussive(select: .harmonic) }
