// expect: A block cannot begin with ConstantQScale: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as
// .tap { $0.constantQScale() }.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 4_096, hop: 512); Magnitude(); Tap { ConstantQScale(fmin: .hertz(440), octaves: 4) } }
