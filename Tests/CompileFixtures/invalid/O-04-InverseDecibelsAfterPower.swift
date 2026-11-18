// expect: InverseDecibels needs a spectrum in decibels: put it after Decibels().
//
// O-4, the way back: powers are not decibels.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); InverseDecibels(.power) }
