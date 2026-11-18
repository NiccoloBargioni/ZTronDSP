// expect: keeps the domain: the pipeline must be valid without it
//
// O-13: a stage that may be absent keeps the domain; the pipeline must be valid without it.
import SwiftUI
import ZTronDSP

func wrong(flag: Bool) -> some PipelineContent { Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); if flag { Tempogram() } } }
