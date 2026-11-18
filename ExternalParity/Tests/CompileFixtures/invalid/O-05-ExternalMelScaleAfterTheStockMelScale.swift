// expect: ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// O-5: the axis is already mel, whichever step made it so.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 64); ExternalMelScale(bands: 40) }
