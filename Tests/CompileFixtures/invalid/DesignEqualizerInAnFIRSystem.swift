// expect: An FIRSystem holds FIR elements
//
// §6.3.7: an equaliser has poles; it is an element of an IIRSystem only.
import ZTronDSP

let wrong = FIRSystem { Taps([1, 1]); BandBoost(center: .hertz(1_000), gain: .decibels(6), bandwidth: .octaves(1)) }
