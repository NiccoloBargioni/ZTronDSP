// expect: A block cannot begin with OnsetStrength: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as
// .tap { $0.onsetStrength() }.
import SwiftUI
import ZTronDSP

func wrong(level: Binding<Float>) -> some PipelineContent {
    Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); Tap { OnsetStrength(); Emit(to: level) } }
}
