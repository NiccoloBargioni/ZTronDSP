// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1: a filter runs on a sequence in time; a frame of bins is not one.
import SwiftUI
import ZTronDSP

// What a fixture brings along: a stage into a spectrum.
struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

let wrong = Pipeline { Frames(); LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
