// expect: CepstralCoefficients needs a mel spectrum in decibels: put MelScale() and then Decibels() before it.
//
// O-10: the coefficients are defined on log energies.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40); CepstralCoefficients() }
