Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 17, "Spectral centroid: dot product with a pre-computed ramp", no external source registered; no alternative registered). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 17): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Spectral centroid (WP-507)

Stability register row 17. Code: `Sources/ZTronDSPAnalysis/Nodes/SpectralCentroidNode.swift`, `Steps/SpectralCentroid.swift`. Tests: `Tests/ZTronDSPAnalysisTests/SpectralCentroidTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **A ratio with a small denominator.** The centroid is Σ fₖ·mₖ / Σ mₖ. On a frame without energy the denominator is zero and the ratio is 0/0. On a frame with next to none, numerator and denominator are both the round-off of the transform (`real-fft.md`): the ratio is a finite number near the middle of the band that says nothing about the signal, and it would be delivered with the same confidence as a real one.
2. **Weights that are not energies.** With negative weights the two sums can cancel and the ratio can lie anywhere, outside the band included. Decibels are such weights.
3. Round-off of the two sums: N products and 2·N additions in single precision.

## Bound or measured behaviour

For non-negative weights the centroid is a weighted mean of the bin frequencies: it lies between the first and the last bin of the range, and each sum is exact to about N·ε of itself, so the centroid is exact to about N·ε of the Nyquist frequency (the register's ε·N). Measured on Hann frames of 1 024 samples at 48 kHz, 513 bins, for every signal of `StressFixture.signals` (WP-016), against the centroid of the same magnitudes in double precision:

| Signal | Largest error | Of the centroid |
|---|---|---|
| `white-noise` | 1.7·10⁻³ Hz | 1.4·10⁻⁷ |
| `nyquist` | 4.2·10⁻⁴ Hz | 1.7·10⁻⁸ |
| `full-scale-square` | 2.8·10⁻⁴ Hz | 4.6·10⁻⁸ |
| `full-scale-sine` | 2.5·10⁻⁴ Hz | 2.5·10⁻⁷ |
| `decaying-tail` | 4.3·10⁻⁶ Hz | 1.0·10⁻⁹ |
| `dc` | 1.2·10⁻⁶ Hz | 7.9·10⁻⁸ |

That is at most about two ε of the centroid (2.1 ε for `full-scale-sine`), three orders under the bound; the test holds it to 8·ε of the Nyquist frequency, 0.023 Hz. Of the 261 frames of the nine signals, 146 have a centroid and 115 have none (all of `silence`, `denormal` and `impulse`, whose one sample a Hann window weighs by zero, and the frames of `decaying-tail` after its first): those carry confidence 0 and repeat the last value, or 0 before the first. No frame is NaN or infinite.

## Mitigation

- **A floor, and confidence 0 below it** (§6.5, NUM-1): a frame whose weights sum to `floor` or less (`SpectralCentroid(floor:)`, 10⁻¹⁰ by default), or to something that is not finite, is not divided. The node writes the last value it had, or 0, with confidence 0. A result that is not finite is treated the same way.
- **The order rule keeps other weights out** (O-8): the step follows magnitudes or powers on a linear-frequency axis, by the types and by its `DomainRule`; a spectrum in decibels does not compile, and one built without the builder is refused when it is attached.
- The ramp is computed once, in double precision, and rounded; the two reductions are Core's `Vector`, bound to their implementation when the plan is compiled (SEL-3, SEL-6).

## Stress test

`StabilityTests.theCentroidOfEveryStressSignalIsAFrequencyOrNothing`, on every signal of `StressFixture.signals`: each frame is a frequency inside the band with confidence 1 and within the bound of the double-precision value, or the last value with confidence 0; and the same signals 180 dB down, under a floor of 10⁻³ that their frames do not reach, give no centroid at all. With the floor removed from the node's guard (only "the sum is a number" left) the second part fails for the six signals that have energy: their frames come out as confident centroids of what is under the floor. `SpectralCentroidTests.silenceHasNoCentroid` fails with it. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905c): the table and the counts are reproduced and now printed ("measured stability row 17"): 146 frames with a centroid and 115 without; `white-noise` 1.750·10⁻³ Hz (1.42·10⁻⁷ of the centroid), `nyquist` 4.16·10⁻⁴ Hz, `full-scale-square` 2.76·10⁻⁴ Hz, `full-scale-sine` 2.50·10⁻⁴ Hz (2.51·10⁻⁷), `decaying-tail` 4.31·10⁻⁶ Hz, `dc` 1.23·10⁻⁶ Hz. Two statements were made exact: the guard on the sum refuses one that is not finite, not only one that is not a number, and "one to two ε" is at most 2.1 ε. Two mitigations had no test that a change to them failed. The guard on a result that is not finite: `StabilityTests.theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing` reads each stress signal as a spectrum of 513 magnitudes and scales it by powers of two up to 2¹²⁶; the weighted sum overflows before the sum of the weights does (10 frames, from 2¹¹⁰ on), every value stays finite, 35 of 35 centroids are bit for bit those of the unscaled weights, and with the guard removed the frames come out as +∞ with confidence 1. The ramp rounded once: `SpectralCentroidTests.theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce` puts all the weight of a frame in one bin, 361 bins 66.67 Hz apart, and finds each bin's frequency rounded once; rounding the width first would move 151 of them. At the widths of power-of-two transforms at 44.1, 48, 96 and 192 kHz, which are floats, the two roundings agree. The floor removed fails as described (`silenceHasNoCentroid`, six signals in the stress test).
