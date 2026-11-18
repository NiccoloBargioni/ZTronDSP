// expect: A block cannot begin with HarmonicPercussive: its domains depend on the stage before it.
//
// ORD-3: a branch that begins with a step of a family is written fluently, as
// .tap { $0.harmonicPercussive(select: .harmonic) }.
import SwiftUI
import ZTronDSP

let wrong = Pipeline { STFT(frame: 2_048, hop: 512); Tap { HarmonicPercussive(select: .harmonic); InverseSTFT() } }
