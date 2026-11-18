// expect: requires the types 'Samples' and 'Novelty' be equivalent
//
// O-9, in the fluent spelling: the compiler names the two domains unaided.
import SwiftUI
import ZTronDSP

let wrong = Pipeline().hpss(select: .percussive).gain(.decibels(-6)).tempogram()
