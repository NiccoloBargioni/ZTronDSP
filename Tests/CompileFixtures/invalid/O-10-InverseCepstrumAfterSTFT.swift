// expect: InverseCepstrum needs a cepstrum: put it after Cepstrum(.complex), with any Lifter in between.
//
// O-10, the way back: a spectrum is not a cepstrum.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); InverseCepstrum() }
