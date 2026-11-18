// expect: Emit needs a sink that can hold the frames before it
//
// O-11: a waveform feed takes an envelope.
import SwiftUI
import ZTronDSP

func wrong(wave: WaveformFeed) -> some PipelineContent { Pipeline { Autocorrelation(); Emit(to: wave) } }
