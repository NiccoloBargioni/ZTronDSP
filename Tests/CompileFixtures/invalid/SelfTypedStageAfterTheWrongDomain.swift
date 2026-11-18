// expect: This stage takes another domain than the pipeline delivers at this point
//
// API-4: a self-typed stage compiles only where the domain before it is the one it consumes.
// Bins needs a complex spectrum and is given a scalar.
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

let wrong = Pipeline { Loudness(); Bins() }
