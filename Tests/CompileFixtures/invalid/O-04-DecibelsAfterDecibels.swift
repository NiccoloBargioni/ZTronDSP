// expect: Decibels needs magnitudes or powers: put Magnitude() or Power() before it.
//
// O-4: the logarithm of a logarithm.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Decibels(); Decibels() }
