Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 14, "Onset envelope: log-mel spectral flux with frequency max-filter": Böck & Widmer 2013; no alternative registered). No literature search was possible offline, so none was made. The register-wide search of 2026-11-15 (`currency-2026-11.md`, row 14) found the method current, with one preprint to watch (`Docs/Process/changes/CR-020.md`, item 5).

# Onset strength (WP-525)

Stability register row 14. Code: `Sources/ZTronDSPAnalysis/Nodes/OnsetStrengthNode.swift`, `Steps/OnsetStrength.swift`. Tests: `Tests/ZTronDSPAnalysisTests/OnsetStrengthTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. References: `Tests/Golden/generators/onset_strength.py`, the published definition written out with NumPy and SciPy (librosa is not installed in the generator environment). Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **A difference of logarithms does not know how far down it is taken.** The onset strength is the mean over the bands of the rise of a level in decibels since the frame before. Scaling the signal moves every level by the same amount and no difference at all: the noise floor of a recording fluctuates by as many decibels from frame to frame as noise at full scale, and counts as onsets as loudly.
2. **Under the floor of the transform the levels are round-off.** A band 140 dB under the frame's largest is the round-off of a single-precision transform (`real-fft.md`), and its level moves by tens of decibels between two frames of the same signal.
3. A band that holds nothing has no logarithm. That is the business of the step before (`Decibels` has a floor of its own); a rise from that floor to a level is then as large as the floor is deep.
4. The first frames after a start have no frame to be compared with.

## Bound or measured behaviour

With the levels raised to a floor f before they are compared, no band rises from further down than f: a value lies between 0 and the level of the frame's highest band above f, and is 0 for a signal that lies under f everywhere.

Measured on every signal of `StressFixture.signals` (WP-016), 8 192 samples, as levels relative to full scale in 40 mel bands of Hann frames of 1 024 samples at a hop of 256, the `Decibels` step floored at −400 dB so that the floor of this step is the one that acts:

| Signal | Floor −80 dB | Floor −1 000 dB, which reaches nothing |
|---|---|---|
| Every signal at full scale | Within 4.8·10⁻⁸ dB of the definition evaluated in double precision on the same levels; the largest value 1.35 dB | — |
| Every signal 180 dB down | 0, exactly, in every frame | — |
| `white-noise` 180 dB down | 0 | 0.80 dB a frame on average, as at full scale (0.80 dB) |

Against the reference on the speech and music fixtures, with floors of −80, −20, 0 and +10 dB: within 1.6·10⁻⁷ of the largest value (`OnsetStrengthTests.theOnsetStrengthOfTheFixturesEqualsTheReference`, "measured WP-525"; the acceptance is 10⁻³).

## Mitigation

- **The explicit floor** (§6.9; `OnsetStrength(floor:)`, −80 dB by default): every level of a frame is raised to it (`vDSP_vthr`) before the frame is compared and before it is kept as the reference of a later frame. What lies under the floor is level with it and does not rise. A floor that is not a finite number is refused when the pipeline is attached.
- The first `lag` frames after a start, and after a cold start (ACT-10), are written as 0 with confidence 0: no value, not a rise from nothing (hazard 4).
- A mean that is not a number, which only levels that are not numbers can give, is written as 0 with confidence 0 (NUM-1).
- The order rule (O-9) admits spectra in decibels and nothing else, so the differences are differences of levels.

## Stress test

`RhythmSeparationStabilityTests.theOnsetStrengthOfEveryStressSignalIsBoundedByItsFloor`, on every signal of `StressFixture.signals`: each value against the definition and against the bound; the same signals 180 dB down, which give nothing; and white noise 180 dB down under a floor that does not reach it, which rises as at full scale.

With the floor removed from the node (the levels compared as they arrive) the test fails: `full-scale-sine`, `full-scale-square` and `white-noise` 180 dB down count onsets, and at full scale the stationary sine, whose bands away from the tone are the round-off of the transform, reads up to 3.0 dB a frame where the definition gives 10⁻⁴ dB (hazard 2). `OnsetStrengthTests.valuesUnderTheFloorAreRaisedToItFirst` and golden comparisons of the same suite fail with it. Checked by making exactly that change, 2026-11-16.
