// expect: OnsetStrength needs a spectrum in decibels: put Decibels() before it, after Magnitude() or Power() and, by custom, MelScale().
//
// O-2: there is no spectrum yet.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { Halve(); OnsetStrength() }
