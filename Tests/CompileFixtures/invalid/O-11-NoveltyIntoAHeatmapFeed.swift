// expect: Emit needs a sink that can hold the frames before it
//
// O-11: a novelty curve is one value per frame; a heat map takes vectors.
import SwiftUI
import ZTronDSP

func wrong(heat: HeatmapFeed) -> some PipelineContent { Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Emit(to: heat) } }
