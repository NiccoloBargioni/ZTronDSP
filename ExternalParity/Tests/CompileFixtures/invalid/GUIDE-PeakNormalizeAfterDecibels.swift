// expect: PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// ORD-4: the family of the extension guide brings its own sentence; decibels are not linear values.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); Decibels(); PeakNormalize() }
