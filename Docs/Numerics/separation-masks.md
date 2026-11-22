Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering …": Fitzgerald 2010; Driedger et al. 2014, whose masks these are: the soft mask of the first, the margins and the residual of the second; no alternative registered for the masks). No literature search was possible offline, so none was made. The register-wide search of 2026-11-15 (`currency-2026-11.md`, row 16) found median filtering still what the libraries do for this separation, and kernel additive modelling as an iterative refinement beside it.

# Masks of the harmonic–percussive separation (WP-530)

Stability register row 16, of which the masks are the arithmetic: the medians are exact (`median-lanes.md`), the masks divide. Code: `Sources/ZTronDSPAnalysis/Separation/MaskStrategy.swift` (`SoftMask`, `HardMask`), `Nodes/HarmonicPercussiveNode.swift` (`SeparationMasks`). Tests: `Tests/ZTronDSPAnalysisTests/SeparationMaskTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. References: `Tests/Golden/generators/hpss.py`: librosa 0.11.0's masks, `librosa.decompose.hpss(…, mask=True)` with every argument explicit, held within 10⁻¹² to the published definition written out with NumPy and SciPy (STG-2). Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

With H the median along time, P the median along frequency and m the margin of the other side, the soft mask of the harmonic part is Hᵖ / (Hᵖ + (m·P)ᵖ).

1. **0/0.** Where both medians are zero the mask has no value: every bin of a frame of silence, and every bin that is zero in most of the frames and of the bins around it.
2. **The powers leave the range of single precision before the quotient is formed.** The square of a magnitude under 10⁻¹⁹ has lost digits and under 4·10⁻²³ is zero; that of one above 1.8·10¹⁹ is infinite; and the quotient depends on the ratio of the two medians alone. A spectrogram of a quiet signal, or one in other units, then has masks of 0/0 and ∞/∞ where a louder one has shares. The larger the power, the narrower the range.
3. **The residual is a difference.** 1 − M_H − M_P is formed of three numbers near each other; where the two masks add up to 1 its round-off can be negative.
4. Margins below 1 would let the two masks claim more than the bin holds.
5. A hard mask flips where the two sides tie: a property of the definition, which the acceptance allows for.

## Bound or measured behaviour

A share lies between 0 and 1; with margins of at least 1 the two shares of a bin add up to at most 1; the residual is not negative.

Measured on the magnitude spectrogram of every signal of `StressFixture.signals` (WP-016), 8 192 samples, Hann frames of 1 024 at a hop of 256, kernels of 17 and 17, for the soft mask with powers of 2, 1 and 4.5 and for the hard mask, with margins of 1 and 1 and of 2 and 3:

| Quantity | Measured |
|---|---|
| Pairs of shares outside 0 … 1, not numbers, or adding up to more than 1 + 4 ε | none of 1 071 144 (133 893 bins in eight settings) |
| A share against its definition in double precision, on the medians of the sort-based oracle | within 2.3·10⁻⁷ (the test holds 10⁻⁵; a hard mask is compared where its two sides do not tie) |
| Pairs of shares where neither median, the competitor's times its margin included, reaches the floor of 10⁻¹⁰ | 588 888, all exact zeros |
| The same spectrograms 2⁷⁰ times smaller and 2⁹⁰ times larger, the floor scaled with them | the same masks, bit for bit |
| Bins lost at 2⁻⁷⁰ of the level when the powers are taken before the quotient, power 2 | 41 919 of the nine spectrograms |

Against the reference on the speech and music fixtures: soft masks within 5.5·10⁻⁵ on the bins above −60 dB of the frame maximum, hard masks equal on every one of them (`SeparationMaskTests.theMasksOfTheFixturesEqualTheReference`, "measured WP-530"; the acceptance is 10⁻³ and 99.9 %).

## Mitigation

- **The zero-denominator rule** (§6.10, NUM-1): where neither median, the competitor's times its margin, reaches `floor` (10⁻¹⁰ by default), the share is 0 for either side, so the bin goes to the residual. The comparison is written so that a value that is not a number fails it.
- **The ratio is taken first**: the share is computed as 1 / (1 + (m·P / H)ᵖ). The ratio of two medians is the same number at any level of the spectrum, and its power overflows or underflows only where the share is 0 or 1 to the last bit anyway; a zero component gives ∞ and a share of 0, a zero competitor a share of 1. Where the ratio itself has no value, both medians zero under a floor of 0, the share is one half for either side.
- The residual is held at 0 where the difference comes out below it.
- A margin below 1, a power that is not positive and finite, and a floor that is negative are refused when the pipeline is attached or the offline separation is called (`HarmonicPercussive.check`, `MaskStrategy.validate`).

## Stress test

`RhythmSeparationStabilityTests.theMasksOfEveryStressSpectrogramAreSharesAtAnyLevel`, on the spectrogram of every signal of `StressFixture.signals`: the figures of the table.

With the powers taken before the quotient (`Hᵖ / (Hᵖ + (m·P)ᵖ)` as it is written) the test fails at 2⁻⁷⁰ and at 2⁹⁰ of the level, with powers of 2 and of 4.5, for the six spectrograms that have bins above the floor (`full-scale-sine`, `full-scale-square`, `dc`, `nyquist`, `decaying-tail`, `white-noise`); a power of 1 takes no power and passes. `SeparationMaskTests.noShareIsEverNotANumber` fails with it. With the zero-denominator rule removed, a bin where both medians are zero falls to the rule for a ratio without a value and gets a share of one half for either side instead of going to the residual: 14 877 pairs of shares of `silence`, `denormal` and `impulse`, 14 364 of `decaying-tail`, 7 308 of `dc` and of `nyquist`, in each setting of the soft mask. This test and `theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold` fail, and `SeparationMaskTests.whereNeitherMedianReachesTheFloorBothMasksAreZero` and `marginsLeaveAResidual` with them; the samples `HPSS` returns stay numbers no larger than the signal's. Both checked by making exactly those changes, 2026-11-16.

Register audit, 2026-11-21 (WP-905c): the figures are reproduced ("measured stability WP-530", "measured WP-530"): 1 071 144 pairs of shares within 2.250·10⁻⁷ of their definition, 588 888 exact zeros where neither median reaches the floor, 41 919 bins lost at 2⁻⁷⁰ of the level, soft masks within 5.51·10⁻⁵ of the reference and hard masks on 100.0 % of 85 454 bins. The powers taken before the quotient fail the stress test (48 issues), `noShareIsEverNotANumber` (9) and `theHardMaskIsTheLimitOfTheSoftOne`. The zero-denominator rule removed does not give shares that are not numbers, as this note said: the quotient's rule for a ratio without a value gives one half, and the stress paragraph is corrected above (72 issues in the stress test). The residual no longer held at 0 fails `theThreeComponentsAddUpToTheSpectrum` (3 111 issues); a margin of 0.5 admitted fails the two refusal tests.
