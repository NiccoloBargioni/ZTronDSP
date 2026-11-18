// OUT-2, OUT-5: a Binding<[Float]> after a real-valued spectrum, a Binding<Float> and a
// Binding<ScalarFrame> after a scalar, each in the builder and in the fluent spelling.
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

@MainActor func right(vector: Binding<[Float]>, level: Binding<Float>, frame: Binding<ScalarFrame>) -> some PipelineContent {
    Pipeline { Tap { Loudness(); Emit(to: level); Emit(to: frame) }; Frames(); Bins(); Emit(to: vector) }
}

@MainActor func fluent(vector: Binding<[Float]>, level: Binding<Float>) -> some PipelineContent {
    Pipeline<Samples, Samples>().tap { $0.appending(Loudness()).emit(to: level) }.appending(Frames()).appending(Bins()).emit(to: vector)
}
