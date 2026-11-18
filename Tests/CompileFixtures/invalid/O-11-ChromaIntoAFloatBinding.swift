// expect: Emit needs a sink that can hold the frames before it
//
// O-11: twelve values do not fit a binding of one.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

@MainActor func wrong(value: Binding<Float>) -> some PipelineContent { Pipeline { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: value) } }
