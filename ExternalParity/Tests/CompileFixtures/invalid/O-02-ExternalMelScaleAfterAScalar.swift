// expect: ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// O-2: a scalar track has no bins.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { Level(.rms); ExternalMelScale(bands: 40) }
