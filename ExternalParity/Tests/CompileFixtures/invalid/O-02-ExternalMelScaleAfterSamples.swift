// expect: ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// O-2: after sequence stages alone there are no bins yet.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { ExternalGain(.decibels(-3)); ExternalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4); ExternalMelScale(bands: 40) }
