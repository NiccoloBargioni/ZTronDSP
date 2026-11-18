// expect: HarmonicPercussive needs the complex spectrum of an STFT, or magnitudes: put it directly after STFT, where it keeps the phase, or after Magnitude().
//
// O-2: there are no bins yet.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { Halve(); HarmonicPercussive(select: .harmonic) }
