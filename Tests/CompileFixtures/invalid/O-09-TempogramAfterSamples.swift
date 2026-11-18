// expect: Tempogram needs a novelty curve: put OnsetStrength() before it, after a spectrum in decibels.
//
// O-9: `Gain → Tempogram`. The tempogram of a signal is that of its onset strength: after
// samples, sequence stages included, there is no novelty curve yet.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

let wrong = Pipeline { HPSS(select: .percussive); Halve(); Tempogram() }
