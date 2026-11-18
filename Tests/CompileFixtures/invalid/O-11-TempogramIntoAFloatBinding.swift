// expect: Emit needs a sink that can hold the frames before it
//
// O-11: the rows of a tempogram do not fit a binding of one value.
import SwiftUI
import ZTronDSP

@MainActor func wrong(value: Binding<Float>) -> some PipelineContent {
    Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Tempogram(); Emit(to: value) }
}
