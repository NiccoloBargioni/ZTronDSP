Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 3: Apple vDSP; Oppenheim & Schafer). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 3. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# The realised cascade: gain spreading and precision by measurement (WP-433, WP-428b; register row 3)

`SecondOrderSections.spreadingGain()`, `singleVersusDoubleDeviation()`, `recommendedPrecision()`, `PrecisionMeasurement` and `FilterLowering`: `Sources/ZTronDSPDesign/Systems/Realization.swift`. The figures of an analysis: `Sources/ZTronDSPDesign/Systems/SystemAnalysis.swift`. Figures are from the iOS 27.0 simulator on the host of §3.

## Hazards

1. **A section far below the signal.** The pairing puts the whole gain of a design into its first section, as the reference does. For a low cutoff at a high rate that gain is tiny (5e-31 for the 10 Hz low-pass of order 8 at 192 kHz): the first section then works twenty decades below the signal, where the kernels clear its memory at the end of every block (RT-6, `biquad-single.md` hazard 4).
2. **Single precision near z = 1** (`biquad-single.md`): the deviation of `vDSP_biquad` from double precision grows as poles approach the unit circle.
3. **A measurement that passes what it cannot compare.** `max` passes a NaN by. A cascade whose spread gain exceeds single precision gives NaN in the single kernel; compared by maxima alone it measured as −160 dB, "single precision is exact".
4. **The measurement speaks about two signals.** The threshold of REAL-3 is met on the impulse and on the seeded noise it measures with, not on every signal.

## Measured behaviour

The grid of WP-433: Butterworth low-pass and high-pass, orders 2 … 8, eight cutoffs from 10 Hz to 0.45·fs at 44.1, 48, 96 and 192 kHz: 448 designs.

| What | Worst over the grid | Bound |
|---|---|---|
| chosen path against the double reference, on the signals of the measurement | −100.2 dB | −100 dB |
| the same on noise the measurement has not seen | −97.2 dB | held to −95 dB |
| designs that run in single precision | 180 of 448 | |
| response up to every section but the last, after spreading: distance of its peak from 0 dB | 0.30 dB | 1 dB |

One design on the three single-precision kernels a plan may create (4th-order high-pass at 1 kHz and 48 kHz, against double): `vDSP_biquad` −99.1 dB, the C loop −111.1 dB, `vDSP_biquadm` −115.9 dB. The measurement therefore runs the kernel the plan would create at the stage's position.

The stress fixtures (WP-016), as `SystemAnalysis` reports them:

| Fixture | Stability margin | Single against double | Round-off level, single | Round-off level, double | Precision |
|---|---|---|---|---|---|
| hp-90Hz-48k-order8 | 2.2957e-3 | −60.15 dB | −82.65 dB | −257.24 dB | double |
| hp-20Hz-96k-order8 | 2.5534e-4 | −44.28 dB | −54.06 dB | −228.66 dB | double |
| lp-10Hz-192k-order8 | 6.3841e-5 | −27.87 dB | −34.75 dB | −209.34 dB | double |
| hp-10Hz-44k1-order2 | 1.0069e-3 | −51.91 dB | −63.61 dB | −238.21 dB | double |
| lp-0.45fs-48k-order8 | 5.8574e-2 | −108.69 dB | −124.12 dB | −298.72 dB | single |
| hp-0.45fs-44k1-order4 | 1.1202e-1 | −120.34 dB | −127.89 dB | −302.49 dB | single |
| lp-0.49fs-48k-order2 | 4.3456e-2 | −92.22 dB | −112.57 dB | −287.17 dB | double |

The stability margins agree with `scipy.signal.butter` to 2e-12. The round-off level is the estimate of §6.3.8 (the power gain from each section's summing node to the output, times the rounding unit squared); the measured deviation is a peak, and lies above it.

`lp-10Hz-192k-order8`, a step of one second through the stage: −144.5 dB from the recurrence in double precision (bound −100 dB). Without the spreading the first section loses its memory at every block and the test fails.

Eight resonators within 1e-7 of the unit circle (hazard 3): spread, the last section's gain is about 1e53. Measured as an infinite deviation, run in double precision by `.automatic`, refused with a typed error under `.single`; in double precision the stage is within −100 dB of the recurrence.

## Mitigation

- **The gain is spread.** Section by section the cascade is scaled so that the response from its input to the output of every section but the last peaks at 1; the last section carries the rest. The peaks are taken on 257 frequencies to which the angle of every pole and zero is added. This is the form the stages run and the form the figures are measured on.
- **Precision is measured** (REAL-3): the realised cascade is run through the single-precision kernel the plan would create and through the double-precision kernel, on an impulse and on seeded noise of 4 096 samples; above −100 dB the double path is chosen. The measurement runs on the control context when the plan is compiled.
- **What is not finite is counted, not compared**: an output that is not a finite number, in either precision, is an infinite deviation. A cascade forced to `.single` whose coefficients exceed single precision is a typed error.
- **Precision is structure**: an update whose design would choose the other precision replaces the kernel as a topology change (SWAP-2).
- The round-off figure sums at most 2²² samples per section, at checkpoints, and reports `.infinity` when a response leaves the range of a sample.

## Stress tests (`Tests/ZTronDSPDesignTests/PrecisionTests.swift`, `SystemAnalysisTests.swift`)

The first three were run against the mutation they name (2026-11-15) and failed.

- `PrecisionTests.stressALowCutoffAtAHighRateRunsBecauseItsGainIsSpread` fails when the cascade is emitted without `spreadingGain()`.
- `PrecisionTests.aCascadeBeyondSinglePrecisionIsMeasuredAsSuchAndRunsInDouble` fails when the measurement no longer counts what is not finite.
- `PrecisionTests.overTheGridTheChosenPathIsWithinMinus100DecibelsOfTheDoubleReference` fails when the threshold is raised.
- `SystemAnalysisFigureTests.theFiguresOfTheStressFixturesEqualTheirRecordedValues` holds the table above.
