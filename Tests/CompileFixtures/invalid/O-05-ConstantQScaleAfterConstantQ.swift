// expect: ConstantQScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// The rule of an axis conversion (O-5): the axis is already constant-Q.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { ConstantQ(); Magnitude(); ConstantQScale(fmin: .hertz(440), octaves: 4) }
