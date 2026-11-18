// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1: an equaliser is a filter; it does not follow a spectrum.
import SwiftUI
import ZTronDSP

// What a fixture brings along: a stage into a spectrum.
struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

let wrong = Pipeline { Frames(); BandBoost(center: .hertz(1_000), gain: .decibels(6), bandwidth: .octaves(1)) }
