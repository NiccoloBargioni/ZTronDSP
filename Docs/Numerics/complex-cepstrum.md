Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 19, "Cepstrum: DFT → log → inverse DFT; DCT-II for the coefficients": Oppenheim & Schafer; no alternative registered). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 19. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Complex cepstrum and its inverse (WP-510)

Stability register row 19. Code: `Sources/ZTronDSPAnalysis/Nodes/CepstrumNodes.swift` (`CepstrumNode`, `InverseCepstrumNode`), `Steps/Cepstrum.swift`; the report is `Inversion/StageInversions.swift`. Tests: `Tests/ZTronDSPAnalysisTests/CepstrumTests.swift`, `InversionTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **Phase unwrapping is ambiguous.** The complex cepstrum needs the phase as a continuous function of frequency, and the transform gives it modulo 2π at N/2 + 1 points. Where the true phase moves by π or more from one bin to the next there is no way to tell which turn it took: near a zero of the spectrum, in noise, and for a signal that sits half a frame into its frame.
2. **A delay is a ramp.** A signal d samples into the frame carries a phase of −2π·d·k / N. Left in, the ramp is the cepstrum of the delay, (−1)ⁿ·d / n over every quefrency: it buries the cepstrum of the signal, makes most phase steps large (hazard 1), and costs digits, since a frame of single-precision values then has to carry a phase of up to π·d.
3. **The sign of bin 0.** A real signal has a real bin 0; where it is negative the phase starts at π and the logarithm of a negative number is asked for.
4. The logarithm of a magnitude at zero, as for the real cepstrum (`cepstrum.md`). In the round trip a bin at the floor comes back as the floor.

## Bound or measured behaviour

The round trip `Cepstrum(.complex)` → `InverseCepstrum`, on rectangular frames of 256 samples centred on every 64th sample of each signal of `StressFixture.signals` (WP-016), as the inversion report measures it: the largest error of a frame, of that frame's maximum.

| Signal | Measured | Predicted | Flagged |
|---|---|---|---|
| `full-scale-sine` | 3.5·10⁻⁷ | 10⁻⁵ | phase steps of π |
| `white-noise` | 6.8·10⁻⁷ | 10⁻⁵ | phase steps of π |
| `full-scale-square` | 1.8·10⁻⁷ | 10⁻⁵ | bins at the floor; phase steps of π |
| `dc`, `nyquist` | 8.9·10⁻⁷ | 10⁻⁵ | bins at the floor |
| `impulse` | 2.0·10⁻⁷ | 10⁻⁵ | bins at the floor (its silent frames); a phase step of exactly π in the frame it sits half-way into |
| `decaying-tail` | 1.7·10²⁸ | 1.7·10²⁸ | bins at the floor: the floor against a frame whose largest value is subnormal; phase steps of π |
| `denormal` | 4.4·10³⁰ | 4.4·10³⁰ | bins at the floor, all of them |
| `silence` | infinite | infinite | bins at the floor, all of them: nothing to hold the floor against |

Where no bin is at the floor the spectrum comes back within 10⁻⁶ of the frame maximum, whether or not the phase could be unwrapped unambiguously: the exponential returns the same spectrum for any choice of turns. The measured error never exceeds the predicted one, and no value of any cepstrum is NaN or infinite. The acceptance (10⁻⁵) is met on the speech, music and noise fixtures (`CepstrumTests.theInverseReturnsTheSpectrum`).

The impulse of the library, seen 64 samples into a frame, has a cepstrum that is zero to 2.8·10⁻¹⁴ at every quefrency, with its position of 64 samples beside it; seen at the start of a frame, exact zeros and no delay. Seen exactly half a frame in, every phase step is π: the delay is not recovered, and the report says so.

## Mitigation

- **The phase is unwrapped, then the delay is taken out.** Steps of more than π between neighbouring bins are taken to be wraps. With the sign of bin 0 removed the unwrapped phase starts at 0 and ends, at the Nyquist bin, on a whole number of half turns: that number is the delay in samples. The ramp of that delay is subtracted before the inverse transform, so what is transformed is the phase of the signal without its position in the frame.
- **The delay and the sign travel with the frame**, as two values after the N quefrencies (`CepstrumLayout`). `InverseCepstrum` puts the ramp and the sign back; `Lifter` leaves the two values alone.
- **Double precision** for the logarithm, the phase (`vvatan2`), the unwrapping and both transforms; the frame is rounded to `Float` once, after the delay is out.
- **The ambiguity is reported, not hidden.** The inversion report of `Cepstrum` (§6.13) carries "a phase unwrapped without ambiguity" with the largest phase step found and its margin under π, and "a finite log spectrum" with the bins at the floor and what they cost: the floor over the frame's maximum, which is the predicted error.
- The floor of the logarithm, as in `cepstrum.md`.

## Stress test

`StabilityTests.theComplexCepstrumOfEveryStressSignalInvertsOrSaysWhyNot`, on every signal of `StressFixture.signals`: finite values, a delay within the frame, a measured round trip at or below the predicted error and below 10⁻⁵ where the report calls the stage exactly invertible, the flags of the table, and the cepstrum of the `impulse` signal. With the delay left in (the ramp not subtracted in `CepstrumNode`) it fails: the cepstrum of the delayed impulse is no longer zero, and the round trip is off by 0.67 to 2.2 of the frame maximum for `full-scale-sine`, `full-scale-square`, `impulse` and `white-noise`. `CepstrumTests.theComplexCepstrumOfADelayedImpulseIsItsDelay`, `theInverseReturnsTheSpectrum`, `theRoundTripRunsThroughAnInverseSTFT` and two inversion tests fail with it. Checked by making exactly that change, 2026-11-15.
