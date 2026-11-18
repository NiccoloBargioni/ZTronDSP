// expect: Emit needs a sink that can hold the frames before it
//
// O-11: a complex spectrum has nothing to draw.
import SwiftUI
import ZTronDSPCore

// Stages every order-rule fixture of the core brings along: the core holds no processing stage
// (EXT-1), so a fixture writes its own against the public API, as a client would.
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

func wrong(heat: HeatmapFeed) -> some PipelineContent { Pipeline { Frames(); Emit(to: heat) } }
