// expect: A Binding<Float> or Binding<ScalarFrame> takes a scalar or a novelty value
//
// OUT-2, O-11, in the fluent spelling: a Binding<Float> holds one value, not a spectrum.
import SwiftUI
import ZTronDSPCore

struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

struct Bins: PipelineStage {
    typealias Input = Spectrum<LinearFrequency, ComplexValues>
    typealias Output = Spectrum<LinearFrequency, MagnitudeValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

struct Loudness: PipelineStage {
    typealias Input = Samples
    typealias Output = Scalar
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

@MainActor func wrong(level: Binding<Float>) -> some PipelineContent { Pipeline().appending(Frames()).emit(to: level) }
