// expect: InverseSTFT needs the complex linear-frequency spectrum of an STFT
//
// O-6: the resolution is gone.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 40); InverseSTFT() }
