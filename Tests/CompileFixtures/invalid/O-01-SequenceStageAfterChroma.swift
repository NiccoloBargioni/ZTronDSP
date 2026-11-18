// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1: twelve pitch-class values are not a sequence in time.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { ConstantQ(); Magnitude(); ChromaFold(); Halve() }
