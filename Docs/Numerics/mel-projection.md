Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 18, "Mel conversion: banded triangular filter bank; a dense product above the crossover": Stevens, Volkmann & Newman 1937; Slaney 1998; no alternative registered). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 18): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Mel projection (WP-535)

Stability register row 18. Code: `Sources/ZTronDSPAnalysis/Steps/MelScale.swift`, `Nodes/MelNodes.swift` (`BandedMelNode`, `DenseMelNode`); the bank is `Mel/MelFilterBank.swift` (`mel-filter-bank.md`). Tests: `Tests/ZTronDSPAnalysisTests/MelTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **A band that covers no bin** (`mel-filter-bank.md`, hazard 1). The step is where it becomes real: the frame length is known only where the step stands, and a band of zero weights would run for the whole session as a row that reads zero.
2. **Sums of products in single precision.** A band is a dot product of up to a few dozen weights with as many bins; the dense form is one product over all bins, most of its terms zero.
3. **Two implementations.** The banded loops and `cblas_sgemv` sum in different orders (§7.4): they must agree, or choosing by size would change what a pipeline computes (SEL-6).
4. Powers below the normal range of a `Float` (a signal 380 dB down) underflow to zero before the projection sees them.

## Bound or measured behaviour

Every weight is non-negative and the step accepts magnitudes and powers only, so every term of a band is non-negative: nothing cancels, and a band is exact to about n·ε of its own value, n being the bins of the band (the register's ε·bins). Measured on Hann frames of 1 024 samples at 48 kHz, 64 bands, for every signal of `StressFixture.signals` (WP-016), against the same sums in double precision; the longest band has 62 bins, so ε·bins is 7.4·10⁻⁶:

| Signal | Banded, of the band | Dense, of the band |
|---|---|---|
| `full-scale-sine` | 2.3·10⁻⁷ | 1.6·10⁻⁷ |
| `white-noise` | 1.9·10⁻⁷ | 1.3·10⁻⁷ |
| `full-scale-square` | 1.5·10⁻⁷ | 9.5·10⁻⁸ |
| `decaying-tail` | 1.3·10⁻⁷ | 9.2·10⁻⁸ |
| `dc` | 1.2·10⁻⁷ | 1.1·10⁻⁷ |
| `nyquist` | 8.0·10⁻⁸ | 1.0·10⁻⁷ |
| `silence`, `denormal`, `impulse` | exact zeros | exact zeros |

Two ε at worst, relative to each band's own value, however far the band lies under the frame maximum. No band is negative or not a number. The mel power spectrograms of the speech and music fixtures equal the reference within 10⁻⁴ of the frame maximum (`theMelPowerSpectrogramOfTheFixturesEqualsTheReference`), and the two implementations agree within 10⁻⁵ of each value (`bandedAndDenseProjectionsAgree`).

Hazard 1: at each sample rate of `StressFixture.filtersNearZero` (44.1, 48, 96 and 192 kHz), 128 bands on a frame of 256 samples leave band 0 without a bin.

## Mitigation

- **The empty-band check when the pipeline is attached** (O-18): `MelScale` builds its bank for the bins and the Nyquist frequency of its position and refuses one with an empty band. The error is an `invalidParameter` on `bands` that names the band, its edges, the transform length it was tried on and the smallest transform length that fills every band.
- **Non-negative terms.** The weights are clamped at zero when the bank is made; the order rule (O-5) admits magnitudes and powers on a linear-frequency axis and nothing else, at compile time and again when a description is attached.
- **The implementation is bound when the plan is compiled** (SEL-3): banded dot products, each bound to the loop its length calls for, or one dense product above the crossover. Neither tests a size per frame.

## Stress test

`StabilityTests.theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`: on every signal of `StressFixture.signals`, both implementations give bands that are non-negative numbers within ε·bins of the double-precision sums; and at the four sample rates of `StressFixture.filtersNearZero` the pipeline with 128 bands on 256 samples is refused with the band and the filling length in the error, and attaches at that length. With the check removed from `MelScale` (the bank no longer asked for an empty band) the test fails: the pipeline attaches with its empty bands. `MelTests.anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt` fails with it. Checked by making exactly that change, 2026-11-15.
