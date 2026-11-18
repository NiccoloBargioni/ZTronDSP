Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 24, "Implementation selection: a measured crossover per primitive, bound when the plan is compiled"; registered alternative: timing each call at run time; the register names no external source for it). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 24): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Crossover search and calibration (WP-611a…d)

Stability register row 24. Code: `Sources/ZTronDSPMetal/Calibration/Calibration.swift` (the search, the timer, `measure()`), `CrossoverMeasurement.swift` (the report and its table), `StockCandidates.swift` (what is measured). Tests: `Tests/ZTronDSPMetalTests/CalibrationTests.swift`. Timings are from an optimised build on the iOS 27.0 simulator on the host of §3, the suite run alone, coverage off; they are the host's processor, not a phone's.

## Hazard

The choice between two implementations changes no result beyond round-off (SEL-6, shown per primitive by WP-113, WP-114, WP-208, WP-215 and WP-219): a wrong crossover costs speed, never correctness. What can go wrong is the measurement.

1. **A disturbed timing.** Something else takes the processor during one sample, and for one size the slower implementation looks faster. A search that took the first size at which the heavier implementation wins would move the crossover to wherever the disturbance fell.
2. **Curves that are level.** Where two implementations take the same time within the noise, they cross wherever the noise says.
3. **The clock's resolution.** One call of a small primitive takes a few nanoseconds, less than a reading of the clock.
4. **Work that the optimiser removes**, and set-up that is timed with the work.

## Bound or measured behaviour

- A synthetic pair whose times are formulas, `a·n` against `b + c·n` for five sets of figures, is found at the first size of the grid past its crossing `b / (a − c)`, that is within one grid step, exactly (`aSyntheticPairWithAKnownCrossoverIsFoundWithinOneGridStep`). A real pair, `n` units of work against 512 units, timed through the clock on a grid of fourfold steps, is found at 1 024 (`aRealPairOfWorkloadsIsFoundThroughTheClock`; measured 36.7 ns at 16 units to 35.8 µs at 16 384 against a steady 1.1 µs).
- The host, in nanoseconds per call (`theMeasurementsOfThisDeviceAreRecorded`, nine samples of a millisecond each, the fastest):

  | Entry | Size | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1 024 | 2 048 | 4 096 | 8 192 | Crossover |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
  | Element-wise (scale) | Swift loop | 4.2 | 1.9 | 1.9 | 3.1 | 6.6 | 18.9 | 31.5 | 54.5 | 122 | 381 | 601 | none: level |
  | | `vDSP_vsmul` | 3.7 | 5.1 | 3.2 | 4.1 | 7.2 | 14.4 | 26.7 | 72.7 | 102 | 235 | 617 | |
  | Dot product | scalar loop | 3.1 | 3.3 | 6.5 | 16.8 | 44.2 | 115 | 283 | 668 | 1 447 | 3 035 | | 32 |
  | | 8-lane loop | 3.8 | 3.8 | 5.3 | 8.0 | 14.7 | 26.9 | 146 | 283 | 561 | 1 118 | | |
  | | `vDSP_dotpr` | 4.5 | 4.8 | 5.5 | 6.2 | 7.9 | 13.9 | 26.8 | 53.0 | 103 | 215 | | 64 |
  | Lane exchange | C loop | 2.2 | 3.5 | 4.7 | 7.1 | 13.0 | 24.6 | 54.5 | 108 | 211 | 408 | 732 | none |
  | | vDSP | 10.2 | 11.3 | 9.2 | 14.8 | 26.6 | 53.9 | 98.5 | 196 | 409 | 808 | 1 577 | |
  | Gain kernel | C loop | 5.9 | 4.9 | 5.9 | 8.5 | 8.7 | 14.4 | 26.5 | 51.1 | 103 | 186 | | none: level |
  | | `vDSP_vsmul` | 6.7 | 6.6 | 8.5 | 8.0 | 8.4 | 14.0 | 26.6 | 54.2 | 101 | 193 | | |

  | Entry | Size | 1 | 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1 024 | Crossover |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
  | Biquad, four sections | C loop | 11.5 | 19.2 | 37.0 | 77.1 | 157 | 302 | 627 | 1 198 | 2 440 | 4 708 | 9 432 | 4 |
  | | `vDSP_biquad` | 25.2 | 27.5 | 30.6 | 38.5 | 48.9 | 78.3 | 166 | 315 | 738 | 1 603 | 3 312 | |

  | Entry | Taps | 16 | 32 | 64 | 128 | 256 | 512 | 1 024 | 2 048 | 4 096 | Crossover |
  |---|---|---|---|---|---|---|---|---|---|---|---|
  | FIR, blocks of 512 | Direct | 609 | 820 | 1 109 | 1 815 | 3 541 | 7 091 | 14 697 | 30 154 | 60 121 | 256 |
  | | Partitioned | 2 198 | 2 337 | 2 202 | 2 215 | 2 156 | 2 370 | 2 451 | 2 659 | 3 233 | |

  The biquad, the FIR and the second reduction confirm the initial values of §7.4 (4, 256, 64); the first reduction comes out at 32 instead of 16. The lane exchange has no crossover, as WP-219 found. Scaling a vector and the gain kernel are level from 128 elements up: on this host the Swift and C loops are vectorised to what vDSP does, and the crossover found for them changes from run to run between a few hundred and none.
- The GPU median, a 17-lane kernel along time over 513 bins, end to end with both copies: 0.66 ms for 8 frames, 0.66 ms for 32, 1.0 ms for 128, 2.6 ms for 512 (10 ns per element at that size). It has no CPU partner below this target, so it decides nothing yet; `CrossoverTable.medianGPU` keeps its initial value.
- `Calibration.report()` takes between half a second and a few seconds on the host, depending on what else runs.

## Mitigation

- Hazard 1: three things. The fastest of the samples counts, not their mean: a disturbance only ever adds time. At every size the candidates are timed one after the other, so a slow moment of the machine reaches both. And the crossover is the smallest size from which the heavier implementation is faster **at that size and at every larger size** of the grid (`Calibration.crossover`): a win that does not last is not a crossover.
- Hazard 2: by the same rule, level curves give the last crossing or none, which keeps the lighter implementation, the one without a library call, wherever the two are level. Either choice costs the same there.
- Hazard 3: `CallTimer` repeats the call until one sample lasts the sample duration (0.2 ms by default: tens of thousands of repetitions of a small primitive) and reports the time of one repetition.
- Hazard 4: every stock workload leaves its result where the optimiser cannot follow (the output lane, a heap cell for a reduction, the kernel's output buffer), and makes its buffers and its kernel before the timed call and frees them after it.
- An implementation that never wins on the grid gets `Int.max` in the table: never chosen. One that could not be measured gets no curve, and its entry keeps the value of the table the measurement started from.

## Stress test

`CalibrationTests.aDisturbedTimingDoesNotMoveTheCrossover`: the curves `3n` and `400 + n`, which cross at 200, with one sample of the lighter one disturbed at 16 so that the heavier one appears to win there, and with every timing off by up to a tenth by the white noise of `StressFixture.signals` (WP-016). The crossover stays at 256, or at 256 or 512 under the noise: within one grid step. With the rule replaced by "the first size at which the heavier implementation is faster" the test fails: the disturbed sample makes 16 the crossover. Checked by making exactly that change, 2026-11-15.
