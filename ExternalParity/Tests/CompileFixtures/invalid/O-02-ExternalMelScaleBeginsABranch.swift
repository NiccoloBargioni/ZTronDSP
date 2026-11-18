// expect: A block cannot begin with ExternalMelScale: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as .tap { $0.externalMelScale(bands: 40) }.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); Tap { ExternalMelScale(bands: 40) } }
