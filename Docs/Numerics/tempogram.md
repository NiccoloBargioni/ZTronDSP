Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 15, "Tempogram: windowed autocorrelation by FFT; Fourier tempogram": Grosche, Müller & Kurth 2010; Grosche & Müller 2011; alternative: the cyclic tempogram). No literature search was possible offline, so none was made. The register-wide search of 2026-11-15 (`currency-2026-11.md`, row 15) found nothing that replaces the two.

# Tempograms (WP-526, WP-527)

Stability register row 15. Code: `Sources/ZTronDSPAnalysis/Nodes/TempogramNodes.swift` (`TempogramNode`, `AutocorrelationTempogramTransform`, `FourierTempogramTransform`), `Steps/Tempogram.swift`; the autocorrelation is `Nodes/WienerKhinchin.swift` (`autocorrelation.md`). Tests: `Tests/ZTronDSPAnalysisTests/TempogramTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. References: `Tests/Golden/generators/tempogram.py`, the published definitions written out with NumPy (librosa is not installed in the generator environment). Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **0/0.** The autocorrelation tempogram divides every lag by the value at lag 0, the energy of the window. A novelty curve that is silent, or that does not move, has none once its mean is out.
2. **A mean that swamps the tempo rows.** An onset strength is not negative, so a novelty curve stands on a mean. Left in, the mean contributes the autocorrelation of the window function to every lag, a broad hump as high as the mean is large against what moves, and the spectrum of the window function to the low rows of the Fourier tempogram. What repeats in the curve is then a ripple on something that says nothing about tempo.
3. **Lag 0 and its neighbours.** The value at lag 0 is 1 by construction and the lags next to it are close to 1 for any curve: as rows they would be the largest of every column.
4. Removing the mean of a curve that stands on a large pedestal is a difference of nearly equal single-precision numbers.
5. The transform's floor under lag 0 (`autocorrelation.md`): a row is right to about 10⁻⁷ of 1, not of itself.

## Bound or measured behaviour

A coefficient of the autocorrelation tempogram is at most 1 in magnitude, up to the floor of the transform; a row of the Fourier tempogram is at most the sum of the window function times the spread of the curve.

Each signal of `StressFixture.signals` (WP-016), 1 024 values, taken as a novelty curve at 93.75 values per second (48 kHz in hops of 512), windows of 384 values, Hann, 30 to 300 beats per minute: the rows are the 169 lags from 19 to 187, lag 0 not among them, and the bins inside the range.

| Curve | Autocorrelation tempogram | Fourier tempogram |
|---|---|---|
| `silence`, `dc`, `denormal`: nothing moves | Exact zeros, 641 columns each | Exact zeros |
| The same three on a pedestal of 1 000 times their largest value | Exact zeros | Exact zeros |
| `full-scale-sine`, `full-scale-square`, `nyquist`, `white-noise` on such a pedestal, against the curve without it | Within 3.7·10⁻⁵ | Within 3.7·10⁻⁵ of the bound of a row |
| `full-scale-square`, 24 values up and 24 down | The largest coefficient of every column is at lag 48, 117.19 beats per minute, with and without the pedestal | The largest row is the one nearest to that tempo, or a neighbour |
| Every curve | No coefficient above 0.985 in magnitude | Within the bound |

Against the reference: frame-wise cosine similarity at least 0.99999999998 and values within 6.4·10⁻⁷ of the largest (`TempogramTests`, "measured WP-526/527"; the acceptance is a similarity of 0.99).

## Mitigation

- **The mean is removed** from every window before the window function is applied (`TempogramNode`): what is transformed is what moves.
- **The lag-0 guard** (NUM-1): a window whose value at lag 0 does not exceed the method's floor (`AutocorrelationTempogram(floor:)`, 10⁻¹⁰ by default), or is not a number, gives a column of zeros and is not divided. The Fourier tempogram divides by nothing.
- **Only the rows inside `range`** are written to the column and named on the axis: lag 0, the lags shorter than the fastest tempo and the bins under the slowest are not among them.
- A value of the curve that is not finite (a NaN or an infinity) is taken as 0 where it enters the window.
- Hazard 4 is bounded by the figures above: a pedestal of 1 000 costs three of the seven digits.

## Stress test

`RhythmSeparationStabilityTests.theTempogramOfEveryStressCurveShowsWhatMovesAndNothingElse`, on every signal of `StressFixture.signals` as a curve: the bounds; zeros for the curves that do not move; the same picture with and without a pedestal; the tempo of the square.

With the mean left in (the window multiplied by the window function as it is) the test fails: on the pedestal the rows of `full-scale-sine`, `full-scale-square`, `nyquist` and `white-noise` are no longer those of the curve without it, the largest row is no longer at the tempo of the square, and `dc` has rows in both tempograms; `TempogramTests.silenceAndACurveThatDoesNotMoveGiveZeros` and the golden comparisons fail with it. With the lag-0 guard removed it fails for `silence`, `dc`, `denormal`, `impulse` and `decaying-tail`, whose columns hold NaN and infinity where a window has no energy. Both checked by making exactly those changes, 2026-11-16.

Register audit, 2026-11-21 (WP-905c): the figures are reproduced: within 3.7193·10⁻⁵ on the pedestal, no coefficient above 0.98402, the square's largest row at lag 48, exact zeros for the curves that do not move, and against the reference a least similarity of 0.99999999998682 and 6.363·10⁻⁷ of the largest value. The mean left in and the lag-0 guard removed fail the stress test as described (1 289 and 3 146 issues). The replacement of a value that is not finite removed failed no test, since the entry of a pipeline replaces non-finite samples before a curve is made of them; `TempogramTests.aValueOfTheCurveThatIsNotFiniteIsTakenAsZero` hands the step `StressFixture.nonFiniteSignal` as a curve through a stage of the tests' own: in four tempograms, 2 948 columns, every value is finite and every column is that of the curve with its three values at 0, bit for bit, and the mutation fails it.
