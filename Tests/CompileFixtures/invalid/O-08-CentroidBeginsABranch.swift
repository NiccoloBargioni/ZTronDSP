// expect: A block cannot begin with SpectralCentroid: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as
// .tap { $0.spectralCentroid(to: binding) }.
import SwiftUI
import ZTronDSP

@MainActor func wrong(value: Binding<Float>) -> some PipelineContent {
    Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Tap { SpectralCentroid(to: value) } }
}
