// expect: STFT
//
// O-15: a side branch starts in the domain of the point it taps: here it receives spectra, not samples.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Tap { STFT(frame: 512, hop: 128) } }
