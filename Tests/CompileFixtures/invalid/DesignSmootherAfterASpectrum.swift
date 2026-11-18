// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1: a smoother runs along time, not along the bins of a frame.
import SwiftUI
import ZTronDSP

// What a fixture brings along: a stage into a spectrum.
struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

let wrong = Pipeline { Frames(); SavitzkyGolay(window: 11, polynomialOrder: 3) }
