// expect: An FIRSystem holds FIR elements
//
// §6.3.7: a system with poles is not an element of an FIR system.
import ZTronDSP

let wrong = FIRSystem { IIRSystem { Pole(radius: 0.5, frequency: .hertz(1_000)) } }
