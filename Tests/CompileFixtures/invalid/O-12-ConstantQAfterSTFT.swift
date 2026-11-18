// expect: ConstantQ needs samples: it frames the signal and cannot follow a spectrum, a cepstrum or any other frame of bins.
//
// A framing step starts from samples.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 4_096, hop: 512); ConstantQ() }
