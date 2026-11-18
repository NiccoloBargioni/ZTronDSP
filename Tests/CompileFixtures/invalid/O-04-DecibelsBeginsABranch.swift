// expect: A block cannot begin with Decibels: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as
// .tap { $0.decibels() … }.
import SwiftUI
import ZTronDSP

func wrong(heat: HeatmapFeed) -> some PipelineContent {
    Pipeline { STFT(frame: 1_024, hop: 256); Power(); Tap { Decibels(); Emit(to: heat) } }
}
