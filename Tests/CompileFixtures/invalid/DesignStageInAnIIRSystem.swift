// expect: An IIRSystem holds poles, zeros, sections
//
// §6.3.7: a gain stage is not an element of a system; a system has its gain in its elements.
import ZTronDSP

let wrong = IIRSystem { Pole(radius: 0.5, frequency: .hertz(1_000)); Gain(.decibels(3)) }
