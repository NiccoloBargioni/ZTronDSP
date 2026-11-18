// expect: requires the types 'Spectrum<LinearFrequency, MagnitudeValues>' and 'Spectrum<ConstantQFrequency, MagnitudeValues>' be equivalent
//
// O-7, in the fluent spelling: the compiler names the two domains unaided.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline().stft(frame: 4_096, hop: 512).magnitude().chromaFold()
