// expect: Despike runs on a sampled sequence: samples, a novelty curve or a scalar track.
//
// O-1: a sample-domain stage written outside the package, after a spectrum. One unavailable overload gives it a sentence that names it (ORD-4).
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Despike() }
