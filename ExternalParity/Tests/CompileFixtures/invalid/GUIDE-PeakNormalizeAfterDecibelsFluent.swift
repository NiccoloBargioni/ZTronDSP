// expect: requires that 'DecibelValues' conform to 'LinearValued'
//
// O-4 in the fluent spelling: the compiler names the constraint unaided.
import ExtensionGuide
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 1_024, hop: 256).power().decibels().peakNormalized()
