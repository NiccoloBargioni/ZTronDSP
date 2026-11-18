// expect: Emit needs a sink that can hold the frames before it
//
// O-11: a complex spectrum is nothing a heat map draws; put Magnitude() and Decibels() before the sink.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

func wrong(heat: HeatmapFeed) -> some PipelineContent { Pipeline { ConstantQ(); Emit(to: heat) } }
