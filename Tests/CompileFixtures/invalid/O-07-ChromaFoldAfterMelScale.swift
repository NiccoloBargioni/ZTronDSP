// expect: ChromaFold needs the magnitudes of a constant-Q spectrum: put it after ConstantQ() and Magnitude(), or after Magnitude() and ConstantQScale().
//
// O-7: mel bands are not spaced by semitones either.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 4_096, hop: 512); Magnitude(); MelScale(bands: 40); ChromaFold() }
