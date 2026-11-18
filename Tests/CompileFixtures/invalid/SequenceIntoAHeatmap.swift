// expect: Emit needs a sink that can hold the frames before it: after sequence stages alone
//
// O-11, ORD-4: after sequence stages alone the block carries a sampled sequence; a HeatmapFeed takes real vectors.
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

func wrong(heat: HeatmapFeed) -> some PipelineContent { Pipeline { Halve(); Emit(to: heat) } }
