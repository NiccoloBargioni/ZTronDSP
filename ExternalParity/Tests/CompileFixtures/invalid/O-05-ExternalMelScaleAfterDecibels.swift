// expect: ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// O-5: a mel band sums energy, and decibels do not add. The sentence names the step written outside the package (ORD-4).
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); Decibels(); ExternalMelScale(bands: 40) }
