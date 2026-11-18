// expect: requires that 'ComplexValues' conform to 'LinearValued'
//
// O-5, in the fluent spelling: the compiler names the mismatched domain unaided.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline().stft(frame: 1_024, hop: 256).melScale(bands: 40)
