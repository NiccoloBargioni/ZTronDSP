// expect: A sequence stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence
//
// O-1: a convolution is a sequence stage, and a frame of bins is not a sequence in time.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 1_024, hop: 256); Convolve(kernel: [0.25, 0.5, 0.25]) }
