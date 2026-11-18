// expect: no exact matches in call to instance method 'harmonicPercussive'
//
// O-2, in the fluent spelling: the method exists after a complex linear-frequency spectrum and after
// magnitudes, and the compiler says that neither fits.
import SwiftUI
import ZTronDSP

let wrong = Pipeline().stft(frame: 2_048, hop: 512).power().harmonicPercussive(select: .harmonic)
