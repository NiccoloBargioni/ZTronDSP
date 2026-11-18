// expect: requires that 'DecibelValues' conform to 'LinearValued'
//
// O-5, in the fluent spelling: decibels are not linear values.
import ExternalStages
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 1_024, hop: 256).power().decibels().externalMelScale(bands: 40)
