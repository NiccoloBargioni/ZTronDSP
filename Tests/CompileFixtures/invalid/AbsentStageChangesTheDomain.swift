// expect: A stage inside `if` without `else` keeps the domain
//
// O-13: a stage that may be absent keeps the domain; the pipeline must be valid without it.
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

func wrong(flag: Bool) -> some PipelineContent { Pipeline { Halve(); if flag { Frames() } } }
