// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1, EXT-2: a sequence stage written outside the package that brings no sentence of its own is
// still order-checked, with the sentence the core has for every sequence stage, stock or not.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); FeedbackComb(delay: 0.010, feedback: 0.5) }
