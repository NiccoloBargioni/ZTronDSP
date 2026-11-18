// expect: MelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.
//
// O-5: a mel band sums energy, and decibels do not add.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Power(); Decibels(); MelScale(bands: 40) }
