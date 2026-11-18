// expect: MelSpectrogram needs samples: it taps the signal and analyses it itself.
//
// A recipe that frames the signal starts from samples.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

func wrong(heat: HeatmapFeed) -> some PipelineContent { Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelSpectrogram(to: heat) } }
