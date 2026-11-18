// expect: Waveform needs samples: it reduces the signal to its envelope
//
// An envelope is reduced from samples, not from a scalar track.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { Level(.rms); Waveform() }
