// expect: A block cannot begin with HarmonicPercussive: its domains depend on the stage before it.
//
// ORD-3: the body of an `if` is a block, and a block cannot begin with a step of a family. A step
// that keeps the domain is switched instead: HarmonicPercussive(select: .harmonic, isActive: flag).
import SwiftUI
import ZTronDSP

func wrong(flag: Bool) -> some PipelineContent {
    Pipeline { STFT(frame: 2_048, hop: 512); if flag { HarmonicPercussive(select: .harmonic) }; InverseSTFT() }
}
