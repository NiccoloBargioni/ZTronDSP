// expect: STFT
//
// O-13: a stage that may be absent keeps the domain; the pipeline must be valid without it.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

func wrong(flag: Bool) -> some PipelineContent { Pipeline { Halve(); if flag { STFT(frame: 1_024, hop: 256) } } }
