Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 19, "Cepstrum: DFT → log → inverse DFT; DCT-II for the coefficients": Oppenheim & Schafer; no alternative registered). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 19. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Real and power cepstrum (WP-509)

Stability register row 19. Code: `Sources/ZTronDSPAnalysis/Nodes/CepstrumNodes.swift` (`CepstrumNode`), `Steps/Cepstrum.swift`. Tests: `Tests/ZTronDSPAnalysisTests/CepstrumTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **The logarithm of a magnitude that is zero.** ln 0 is −∞, and the inverse transform spreads it over the whole frame as NaN. Silence does it, and so does one exact null in an otherwise ordinary spectrum.
2. **The logarithm of a magnitude that is noise.** A bin under the floor of the single-precision transform that produced the spectrum (`real-fft.md`: about 10⁻⁷ of the frame's largest bin) is round-off, and its logarithm is a number anywhere between ln(10⁻⁷·maximum) and the floor. The cepstrum is a mean of logarithms, so such bins move every quefrency.
3. A cepstral transform in single precision would add a floor of its own under the logarithms.

## Bound or measured behaviour

With a floor f on the magnitudes, every logarithm lies between ln f and ln of the frame's largest bin, and each quefrency is a mean of them: no value exceeds the larger of |ln f| and the logarithm of the largest bin. On Hann frames of 1 024 samples of every signal of `StressFixture.signals` (WP-016), with the default floor of 10⁻¹⁰, every value of the real cepstrum is finite and at most 23.03 = |ln 10⁻¹⁰| in magnitude, and every value of the power cepstrum lies between 0 and that squared. Silence is the floor's logarithm at quefrency 0 and nothing elsewhere.

Hazard 2, the largest distance from the definition evaluated in double precision, as a fraction of the frame maximum, by the floor:

| Signal | Floor 10⁻¹⁰ | 10⁻⁴ | 10⁻² | 1 |
|---|---|---|---|---|
| `dc`, `nyquist` | 0.20 | 1.4·10⁻⁸ | 4.5·10⁻⁸ | 5.5·10⁻⁸ |
| `full-scale-sine` | 2.9·10⁻² | 2.6·10⁻⁵ | 2.1·10⁻⁷ | 1.1·10⁻⁷ |
| `full-scale-square` | 8.1·10⁻⁵ | 4.5·10⁻⁵ | 6.8·10⁻⁷ | 6.4·10⁻⁸ |
| `decaying-tail` | 6.5·10⁻⁵ | 1.4·10⁻⁸ | 1.4·10⁻⁸ | 0 |
| `white-noise` | 5.6·10⁻⁸ | 5.6·10⁻⁸ | 5.6·10⁻⁸ | 5.6·10⁻⁸ |
| `silence`, `denormal`, `impulse` | 2.8·10⁻⁸ | 1.4·10⁻⁸ | 1.4·10⁻⁸ | 0 |

A windowed constant has bins that are zero in exact arithmetic and about 10⁻⁵ in single precision: under a floor of 10⁻¹⁰ their logarithms are those of the round-off, and the cepstrum is off by a fifth of its largest value. With the floor at 10⁻², which is 2·10⁻⁵ of a full-scale frame's largest bin and so above the floor of the transform, single precision is within 6.8·10⁻⁷ of the definition for every signal (test bound: 10⁻⁵). A signal with a noise floor of its own, like the white noise here, does not depend on the floor at all.

The acceptance against the reference (NumPy, from the definition, 10⁻⁴ of the frame maximum) is met on the speech and music fixtures, which carry a noise floor for this reason: without one, the pauses and the gaps between partials of the music fixture were tens of decibels apart between the two precisions in the logarithm.

## Mitigation

- **A log floor** (`Cepstrum(_:floor:)`, 10⁻¹⁰ by default): the squared magnitudes are clamped at the floor, squared, before the logarithm (`vDSP_vthrD`), so the logarithm never sees zero and the frame is always finite (NUM-1). A floor that is not positive and finite is refused when the pipeline is attached. Raised to the noise floor of the material, it also makes the result independent of the transform's round-off, as the table shows.
- **Double precision from the magnitudes on**: the squared magnitudes, the logarithm (`vvlog`) and the inverse transform (`DoubleDFT`) are double; only the frame that leaves the node is rounded to `Float` (§6.1).
- The inversion report counts the bins at the floor and states what they cost (`complex-cepstrum.md`, `inversion-analysis.md`).

## Stress test

`StabilityTests.theCepstrumOfEveryStressSignalIsBoundedByItsFloor`, on every signal of `StressFixture.signals`: the bound above for the real and the power cepstrum, the agreement with the double-precision definition at a floor of 10⁻², and the cepstrum of silence. With the floor removed (the clamp of the node given a threshold of 0) it fails for eight of the nine signals: frames of `silence`, `dc`, `nyquist`, `decaying-tail`, `denormal` and `impulse` are NaN, and `full-scale-sine` and `full-scale-square` leave the bound or the definition. `CepstrumTests.theLogarithmIsFloored`, the golden test and the pitch tests fail with it. Checked by making exactly that change, 2026-11-15.
