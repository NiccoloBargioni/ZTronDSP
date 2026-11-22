Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 11, "Autocorrelation: Wiener–Khinchin on a zero-padded frame", no external source registered; no alternative registered). No literature search was possible offline, so none was made. The register-wide record of 2026-11-15 (`currency-2026-11.md`, row 11) made none either: what the row registers is classical.

# Autocorrelation (WP-515)

Stability register row 11. Code: `Sources/ZTronDSPAnalysis/Nodes/WienerKhinchin.swift` (the transform the three users share), `Nodes/AutocorrelationNode.swift`, `Steps/Autocorrelation.swift`, and `DSP.autocorrelate` in `Correlation/Correlation.swift`. The autocorrelation tempogram uses the same transform (`tempogram.md`). Tests: `Tests/ZTronDSPAnalysisTests/CorrelationTests.swift`, `AutocorrelationStepTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **Wrap-around.** The inverse transform of a frame's squared magnitudes is the circular autocorrelation: at lag ℓ it holds the products of lag ℓ and those of lag L − ℓ, L being the transform length. Transformed at its own length, a frame of ones reads N at every lag instead of N − ℓ.
2. **Round-off at the floor of the transform.** Every lag is right to about 10⁻⁷ of the value at lag 0, not of itself. A lag that is exactly zero reads that much, with either sign: an autocorrelation with small negative values where none can be. Two lags that differ by less than the floor come out in either order: for a frame smooth enough, lag 0 can read below lag 1, and a coefficient above 1.
3. **0/0.** The `.coefficient` normalisation divides by the value at lag 0, which is zero for a frame of silence, and for one of subnormal samples, whose squares underflow.
4. Lags at and past the frame's length have no product. The transform gives its floor there, not zero.

## Bound or measured behaviour

Frames of 1 024 samples at a hop of 512, all 1 024 lags, of every signal of `StressFixture.signals` (WP-016), 4 096 samples each, through the `Autocorrelation` step, against the sums in double precision. Of the 63 frames, 37 have energy and 26 have none (all of `silence` and `denormal`, and the frames of `impulse` and `decaying-tail` after their first).

| Quantity | Measured, worst | Held by the test |
|---|---|---|
| A lag, of the value at lag 0 | 2.8·10⁻⁷ | 10⁻⁶ |
| A coefficient, against lag over lag 0 | 2.5·10⁻⁷ | 10⁻⁶; never above 1 + 10⁻⁶; lag 0 exactly 1 |
| Lags that are exactly zero and read below zero | 431 | within the first bound |
| Frames without energy, as coefficients | exact zeros | exact zeros |

A Hann window of 16 384 samples taken as a frame: lag 1 lies 2.5·10⁻⁸ of lag 0 under it, less than the floor. Here the transform reads it 7.9·10⁻⁸ under, and the coefficient at lag 1 reads 0.99999994: the order is right, and it is right by round-off. The one-shot function by the transform, over 1 500 lags of each signal, gives coefficients that are numbers and never above 1 + 10⁻⁶.

The one-shot function against the sum in double precision on seeded noise of 1 to 4 096 samples (`CorrelationTests.theAutocorrelationByTransformEqualsTheDirectSum`, printed as "measured WP-515"): by the transform within 8.2·10⁻⁸ of the value at lag 0, by `vDSP_conv` within 7.0·10⁻⁷ (the tests hold 2·10⁻⁶ and 10⁻⁶).

## Mitigation

- **Zero-padding by rule** (§6.7): the frame is followed by zeros up to a fast length at or above frame + lags − 1 (`WienerKhinchin.transformLength`), so no product of another lag reaches a lag that is returned. The zeros are never written: only the frame is copied into the transform's buffer.
- **The normalisation is guarded at the floor** (NUM-1): a frame whose value at lag 0 does not exceed `floor` (`DSP.correlationFloor`, 10⁻²⁰, by default), or is not a number, gives zeros and is not divided. Where it is divided, lag 0 is written as 1, not as the product of a value and its rounded reciprocal.
- Lags at and past the frame's length are set to 0 after the transform.
- Hazard 2 is the method's and is not removed: the documentation of `DSP.autocorrelate` and of the step states the floor, and the one-shot function has `.direct`, which `.automatic` takes below the crossover of the table and which sums the products instead.

## Stress test

`RhythmSeparationStabilityTests.theAutocorrelationOfEveryStressSignalIsLinearAndGuarded`, on every signal of `StressFixture.signals`: every lag of every frame within the floor of the linear autocorrelation in double precision; a coefficient of 1 at lag 0 and within the floor elsewhere, or zeros; the smooth frame.

With the padding removed (`WienerKhinchin.transformLength` returning a fast length at or above the frame alone) the test fails for 36 of the 37 frames that have energy, every one but the frame that holds the impulse alone, which has nothing to wrap: the frames of `dc`, `full-scale-sine` and `full-scale-square` are off by 0.999, 0.99 and 0.98 of the value at lag 0. `CorrelationTests`, `AutocorrelationStepTests` and the golden comparisons of the tempograms fail with it. With the guard removed from the node (the coefficient divided whatever lag 0 holds) it fails for the 26 frames without energy, which are no longer zeros, and `AutocorrelationStepTests.theNormalisationsAreThoseOfTheOneShotFunction` with it. Both checked by making exactly those changes, 2026-11-16.

Register audit, 2026-11-21 (WP-905b): both changes made again, with the outcome above. Two more, one at a time. Lag 0 left as the product of a value and its rounded reciprocal fails `aPeriodicFixturePeaksAtItsPeriod`, `theAutocorrelationOfEveryStressSignalIsLinearAndGuarded` (a coefficient off by 6.0e-8 to 1.9e-7) and `theNormalisationsAreThoseOfTheOneShotFunction`. Lags past the frame left as the transform gives them fails `AutocorrelationStepTests.theFramesEqualTheDirectSumForAnyBlockSize` and `CorrelationTests.theTransformOfAnAutocorrelationPadsByRule`.
