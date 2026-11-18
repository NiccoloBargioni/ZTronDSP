// expect: PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// ORD-4: after sequence stages alone there are no bins yet.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline { Despike(); PeakNormalize() }
