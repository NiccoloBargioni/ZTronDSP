Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 3, "IIR filtering: … a transposed direct form II in double": Oppenheim & Schafer). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 3. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Biquad cascade, double precision (WP-211)

Stability register row 3. Code: `Sources/CZTronDSP/ztd_biquad_double.c`. Tests: `Tests/CZTronDSPTests/DoubleBiquadKernelTests.swift`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

Poles near z = 1 amplify round-off. The fixture of the acceptance, a Butterworth high-pass at 20 Hz, order 8, 96 kHz (`hp-20Hz-96k-order8` of the stress library, sections from SciPy), has its poles within 1.3e-3 of z = 1. In Float32 the state of such a cascade carries errors of the order of the signal itself.

## Bound or measured behaviour

The response of the kernel on that fixture, from 131 072 frames of its impulse response, against `scipy.signal.sosfreqz` at fifteen frequencies from 10 Hz (48 dB down) to 40 kHz:

| Kernel | Largest response error |
|---|---|
| double (this package) | 3.4e-5 dB (acceptance: 0.01 dB) |
| single, C loop | 15.9 dB |
| single, `vDSP_biquad` | 39.1 dB |

The kernel is its definition bit for bit: transposed direct form II with every product and sum rounded on its own, in double, the result rounded to Float32. `theKernelIsItsDefinitionBitForBitForAnyBlockSizes` compares bit patterns against that recurrence written in Swift, for blocks of 1, 7, 512 and irregular ones, on four cascades.

A live exchange of coefficients keeps the two state values of each section (`aLiveExchangeKeepsTheState`, bit for bit against the recurrence with the same exchange); for a cutoff step of a tenth of an octave under a full-scale 1 kHz sine the largest step is 1.03 times the steady one (CLICK-1 allows 1.5).

**A limit of state hygiene**, measured on the lowest corner of the stress library (`lp-10Hz-192k-order8`). SciPy gives the whole gain of a cascade to its first section: 5e-31 here, so that section works 23 decades below the signal. Its state is legitimate, far from subnormal in double, and below the floor of RT-6: it is cleared at the end of every block, and the output is off by the full scale of the reference (0 dB). With the same gain spread over the sections (each at unity gain at 0 Hz, the same filter to 1e-9) the kernel is its definition again, bit for bit. The single-precision `vDSP_biquad` kernel fails the same way; the `vDSP_biquadm` kernel, which clears its memory as a whole and only in silence, does not. `stateHygieneNeedsEverySectionToWorkNearTheLevelOfTheSignal` shows all of it.

## Mitigation

- **Double state and double coefficients** (REAL-3): about nine decimal digits more than Float32 has to lose. Samples stay Float32 at both ends.
- **No fused multiply-add** (`#pragma STDC FP_CONTRACT OFF`): the kernel computes what its definition says, in the order it says it, on every compiler setting. That is what lets the tests hold it to its definition bit for bit.
- **State hygiene (RT-6)**: at the end of each block every state value below 1e-20 is set to zero (`ztd_flush_state_double`); without it a double state decays through 300 decades, and the Float32 output through its whole subnormal range. `aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind` shows it.
- The limit above is the designer's to avoid: **the gain of a cascade must be spread over its sections.** It is stated in the kernel header and reported to the integrator as a finding against RT-6 and the design stage.

## Stress test

`DoubleBiquadKernelTests.theTwentyHertzHighPassIsWithinAHundredthOfADecibelOfTheReference`, on `hp-20Hz-96k-order8` (WP-016), with `singlePrecisionMissesThatMarkOnTheSameFixture` beside it. With the kernel's state narrowed to Float32 the first fails at six of its fifteen frequencies. Checked by making exactly that change, 2026-11-15.
