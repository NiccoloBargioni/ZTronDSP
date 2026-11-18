// expect: conform to 'SampledSequence'
//
// O-1, in the fluent spelling: the compiler names the constraint unaided.
import SwiftUI
import ZTronDSP

// What a fixture brings along: a stage into a spectrum.
struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

let spectral = Pipeline().appending(Frames())
let wrong = spectral.gain(.decibels(-6))
