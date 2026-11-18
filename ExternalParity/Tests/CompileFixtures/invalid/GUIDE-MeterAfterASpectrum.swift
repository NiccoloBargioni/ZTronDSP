// expect: Emit needs a sink that can hold the frames before it
//
// O-11: a sink written outside the package takes its own domain, here a scalar track, and nothing else.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let meter = PeakHoldMeter()
let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Emit(to: meter) }
