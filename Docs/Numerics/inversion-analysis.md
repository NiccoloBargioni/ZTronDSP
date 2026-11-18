Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 22, "Inversion analysis: frame bounds from Σ w²; band-limit from the signal's spectrum; a measured round trip": Shannon 1949; Griffin & Lim 1984; no alternative registered). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 22): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Inversion analysis (WP-537, with the reports of WP-538 and WP-539)

Stability register row 22. Code: `Sources/ZTronDSPAnalysis/Inversion/InversionReport.swift` (`InversionCondition`, `InversionMeasurement`, `InversionReport`, `InvertibleStage`), `StageInversions.swift` (`STFT`, `Cepstrum`, `CepstralCoefficients`, `Decibels`), `RateInversions.swift` (up- and subsampling, `SamplingTheorem`), `Steps/FramingSupport.swift` (`OverlapAdd`). Tests: `Tests/ZTronDSPAnalysisTests/InversionTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **Division by a small Σ w².** Overlap-add synthesis divides each sample by the sum of the squared windows of the frames that cover it. Where that sum is small the round-off of the transforms is amplified; where it is zero the sample is gone.
2. **The measurement is limited by single precision.** A round trip that is exact in theory still differs from its input by the round-off of two transforms: a report cannot show more than about 140 dB, and must not read that as a defect of the stage.
3. **A prediction that understates.** A predicted error is useful only as a bound. Round-off left out of it, or a floor that comes back rounded upwards, puts the measured error above the predicted one.
4. **Relative errors against nothing.** A frame of silence has no maximum to hold an error against; a signal of subnormal numbers has one that is smaller than the steps between its values.
5. **Leakage counted as aliasing.** The band limit of a signal is read from its spectrum; the side lobes of the analysis window put energy above any frequency, which would fail every signal.

## Bound or measured behaviour

Hazards 1 and 2, on the signals of `StressFixture.signals` (WP-016), 16 384 samples, through `STFT(frame: 1_024, …)` and its inverse, for windows whose frame-bound ratio B/A (the greatest of Σ w² over the least) runs from 1 to 10⁸: a Hann window at a quarter-frame hop and at a hop of 700, and a Hann window on a pedestal of 10⁻² and of 10⁻⁴ at a hop of one frame. The largest error relative to the signal's peak, over the signals with normal samples:

| B/A | Measured, at worst | Signal-to-noise ratio | Predicted |
|---|---|---|---|
| 1 | 3.6·10⁻⁷ | 138.9 to 145.9 dB | 1.9·10⁻⁵ |
| 9.67 | 8.3·10⁻⁷ | 134.9 to 141.5 dB | 1.8·10⁻⁴ |
| 10⁴ | 2.8·10⁻⁵ | 113.7 to 119.9 dB | 0.19 |
| 10⁸ | 1.9·10⁻³ | 84.0 to 90.5 dB | 1 |

The error grows as the square root of B/A (a sample weighed by one small window value w is divided by w², after being multiplied by w), so the registered bound, round-off times B/A, is safe by a wide margin and is capped at 1. `silence` comes back as exact zeros, and so do `impulse` and `decaying-tail`, whose content lies in the first frame, which a causal analysis leaves out of the comparison: an infinite ratio. On a tight frame the round trip shows 139 to 146 dB: the register's "about 140 dB".

Below a least Σ w² of 10⁻¹⁰ of the greatest (a pedestal of 10⁻⁶: B/A = 10¹²) the condition is reported as failed, the predicted error is 1, and the measured error is that of losing the samples: 0.99 to 1.0 of the peak.

The `denormal` signal, whose samples are 9·10⁻⁴⁴, comes back with errors of at most 71 units of the smallest subnormal number, which is up to 1.1 of its peak. A relative bound does not speak about such a signal (hazard 4), and the test holds it to an absolute one, 128 units.

On the fixtures of the acceptance: the predicted bound is at or above the measured error for seven analyses on the speech and music fixtures (`InversionTests.thePredictedBoundOfAnSTFTIsAtOrAboveTheMeasuredErrorOnTheFixtures`); an up- and subsampling pair is exact bit for bit; a band-limited fixture passes the sampling theorem with more than 100 dB, and four aliasing fixtures fail with the aliased share within 1 dB of the truth (`aBandLimitedFixturePassesTheSamplingTheorem`, `anAliasingFixtureFailsWithTheAliasedEnergyWithinOneDecibel`).

For the stages with a floor (`Cepstrum`, `Decibels`), on the stress signals: the measured error is at or below the predicted one for every signal, including those where both are enormous or infinite (`complex-cepstrum.md`).

## Mitigation

- **B/A is reported, and the prediction carries it.** The condition "non-zero overlap-add" holds the least of Σ w² as a fraction of the greatest (the reciprocal of B/A), its margin, and a predicted error of the transform's round-off times B/A; "constant overlap-add" says whether the frame is tight. `WindowAnalysis.frameBoundRatio` is the same figure.
- **A relative floor under Σ w²** (`OverlapAdd.nonZeroFloor`, 10⁻¹⁰ of the greatest): below it the condition fails and the report says the samples are lost; nothing is predicted from a quotient of round-off. A failed condition is reported, never thrown (INV-3); the pipeline itself refuses such a pair when it is attached (O-17).
- **Conditions carry margins** (§6.13): each states the quantity it measured, the measured value, and how far that lies on the safe side.
- **The measurement says what it is held against**: the signal's peak for samples, the maximum of its own frame for frames (§6.1). An exact round trip is an infinite ratio; nothing compared is 0; an error against a signal that is zero everywhere is infinite, and the conditions predict the same.
- **Round-off has head-room in the prediction**: 16·ε·log₂ M for a transform and its inverse, 10⁻⁵ for a logarithm and its exponential, the latter also relative to a floor that comes back.
- **The band limit is measured through a window whose side lobes lie under single precision** (Kaiser, β = 24, averaged over half-overlapping segments), and energy at or below a share of 10⁻¹⁰ counts as none.

## Stress test

`StabilityTests.whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal`, on every signal of `StressFixture.signals` and the four windows of the table: the reported ratio, a measured error that is a number and lies at or below the predicted one, the growth of the error with the ratio, the lost samples below the floor, and the 130 dB a tight frame must show. With the amplification taken out of the prediction (round-off alone, not times B/A) it fails: at B/A = 10⁴ the `full-scale-sine` and `full-scale-square` signals measure 2.8·10⁻⁵ and 2.1·10⁻⁵ against a predicted 1.9·10⁻⁵, and at 10⁸ five signals measure 4.3·10⁻⁴ to 1.9·10⁻³. `InversionTests.theConditionsOfAnSTFTAreItsFrameBounds` fails with it. Checked by making exactly that change, 2026-11-15.
