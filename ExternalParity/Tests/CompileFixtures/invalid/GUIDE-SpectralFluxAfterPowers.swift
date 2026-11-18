// expect: This stage takes another domain than the pipeline delivers at this point.
//
// ORD-4: a self-typed stage written outside the package gets the sentence the core has for any self-typed stage.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); SpectralFlux() }
