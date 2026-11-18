// expect: An IIRSystem holds poles, zeros, sections
//
// §6.3.7: taps are an element of an FIRSystem.
import ZTronDSP

let wrong = IIRSystem { Taps([0.5, 0.5]) }
