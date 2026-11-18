// expect: Emit needs a sink that can hold the frames before it
//
// OUT-5, O-11: a Binding<[Float]> takes real vectors, not a complex spectrum.
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

@MainActor func wrong(vector: Binding<[Float]>) -> some PipelineContent { Pipeline { Frames(); Emit(to: vector) } }
