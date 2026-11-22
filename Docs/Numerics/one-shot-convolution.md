Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 10, "One-shot convolution, correlation: FFT at a fast length; direct below the crossover", no external source registered; no alternative registered). No literature search was possible offline, so none was made. The register-wide record of 2026-11-15 (`currency-2026-11.md`, row 10) made none either: what the row registers is classical.

# One-shot convolution and correlation (WP-513, WP-514)

Stability register row 10. Code: `Sources/ZTronDSPAnalysis/Correlation/Convolution.swift` (`DSP.convolve`, `OneShotConvolution`), `Correlation/Correlation.swift` (`DSP.correlate`); the strategy value is `ConvolutionStrategy` in `Sources/ZTronDSPDesign/Stages/Convolve.swift`. Tests: `Tests/ZTronDSPAnalysisTests/ConvolutionTests.swift`, `CorrelationTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. References: `Tests/Golden/generators/convolution.py` (`numpy.convolve`, `scipy.signal.correlate`). Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **The FFT method loses small outputs beside large ones.** It multiplies two spectra and transforms the product back: every output carries the round-off of the whole transform, a floor that is set by the largest values that went in and not by the output in question. An output far under the largest is that floor and nothing else.
2. **The floor lies under the largest output the inputs can give, not under the largest there is.** The round-off of the signal's spectrum is spread over all bins and is multiplied by the kernel's response at each of them, also where the signal has nothing. A kernel whose taps cancel (a difference, a high-pass) gives small outputs from a large signal, and they are small beside the floor too.
3. **Outputs that are exactly zero are not.** Where the kernel has run past the signal, or the signal is silent, the sum of products is 0; the transform writes its floor there, with either sign.
4. The direct method sums K products per output: the hazard of a short FIR (row 7), benign.
5. The `.unbiased` normalisation of a correlation divides each lag by the number of its products. At the last lags that is a division by one or two: the floor of a transform is then not divided down with the sum, as it is in the middle.
6. A sample that is not a number reaches every output of a transform, and K outputs of the direct method.

## Bound or measured behaviour

On every signal of `StressFixture.signals` (WP-016), 4 096 samples, convolved with kernels of 1, 2, 5 and 16 taps (`[1]`, `[0.5, 0.5]`, `[1, −2, 3, −2, 1]`, seeded noise), against the sums in double precision:

| Method | Error of an output | Measured, worst |
|---|---|---|
| Direct (what `.automatic` takes here) | Within K·ε of the sum of the magnitudes of its own products, plus half a step of the subnormal range per product | 0.94 ε of that sum |
| FFT (forced) | Within a floor under the largest output the inputs can give, max\|x\|·Σ\|h\| | 6.6·10⁻⁷ of it (`full-scale-square`, 1 tap); the test holds 2·10⁻⁶ |
| FFT, held against the largest output there is | No bound of its own: the taps of `[1, −2, 3, −2, 1]` sum to 1 and their magnitudes to 9 | 2.0·10⁻⁶ (`full-scale-sine`, 5 taps) |

Of the 281 outputs of these convolutions that lie 180 dB or more under the largest output of their convolution and are still normal numbers (the tail of `decaying-tail` through the four kernels), the direct method has every one to within half of itself, and in fact to K·ε of the sum of its products; the FFT method has one of them to within half of itself. 27 843 outputs that are exactly zero, behind `impulse` and behind the end of `decaying-tail`, read something by the FFT method.

On the grid of STG-2, seeded noise of lengths (16, 5), (1 024, 255), (48 000, 4 096) and the two reversed, three modes, against `numpy.convolve` and `scipy.signal.correlate`, of the largest output (the acceptance is 10⁻⁵; printed by `ConvolutionTests.theConvolutionEqualsTheReference` and `CorrelationTests.theCorrelationEqualsTheReference` as "measured WP-513" and "measured WP-514"):

| Method | Convolution, worst | Correlation, worst |
|---|---|---|
| Direct | 1.2·10⁻⁶ (48 000 by 4 096: 4 096 products an output) | 1.1·10⁻⁶ |
| FFT | 2.2·10⁻⁷ | 2.2·10⁻⁷ |
| Partitioned | 4.6·10⁻⁷ | 3.9·10⁻⁷ |
| Automatic | 2.2·10⁻⁷ | 2.2·10⁻⁷ |

Noise has no outputs far under its largest, which is why the acceptance cannot see hazard 1.

Hazard 5: the unbiased correlation of the two noise fixtures of 1 024 samples by the FFT method is off by 1.07·10⁻⁵ of its largest value, where the direct method is off by 7.6·10⁻⁸; multiplied back by the number of products of each lag, the sums are within 10⁻⁵ of their largest (`theNormalisationsEqualTheirDefinitions`, which holds the transform methods to the sums and the direct method to the quotients).

## Mitigation

- **The direct method below the crossover.** `.automatic` computes `vDSP_conv` unless the cost model of the table says the transform pays, `N·K > factor·(N + K)·log₂(N + K)` (`CrossoverTable.convolutionUsesFFT`; the factor is 4 as shipped and is measured by `Calibration.measureAnalysis`, WP-611c): for 4 096 samples that is every kernel of up to 48 taps. Below the crossover every output keeps its own accuracy; from it on the floor of the transform applies, as the documentation says.
- **A forced `.direct` is honoured whatever the lengths**, and the documentation of `DSP.convolve` states the floor of the other methods: a caller who needs the small outputs of a long kernel asks for them.
- Hazard 5 is stated in the documentation of `DSP.correlate`, and the direct method does not have it.
- Hazard 6: NUM-1 replaces such samples where a signal enters a pipeline. A one-shot function is given its arrays by the caller, and says in its documentation what one such value does.
- A result of more than 2²⁸ values is refused; a single transform of more than 2²² points is not asked for by `.automatic`, which then runs the partitioned kernel, whose floor is that of each partition (row 8).

## Stress test

`RhythmSeparationStabilityTests.aConvolutionBelowTheCrossoverKeepsItsSmallOutputs`, on every signal of `StressFixture.signals`: the bound of the direct method for what `.automatic` returns, the floor of the FFT method, and the count of small outputs each of them keeps.

With the mitigation removed (`OneShotConvolution.method` returning the FFT method for `.automatic` whatever the lengths) the test fails for six of the nine signals: nearly every output of `decaying-tail` (4 027 to 4 080 of them, by the kernel) and of `impulse` through the kernels of two taps and more (3 993 to 4 087) is further than K·ε from its sum, as are 2 573 outputs of `full-scale-sine` through the single tap and fewer through the longer kernels, and outputs of `full-scale-square`, `dc` and `white-noise`; the small outputs are no longer kept. `ConvolutionTests.automaticFollowsTheCostModelOfTheTable` fails with it. Checked by making exactly that change, 2026-11-16.

Register audit, 2026-11-21 (WP-905b): the change above made again; it fails as described (four kernels, 57 issues). Three more, one at a time. A forced method overridden for large inputs fails `automaticFollowsTheCostModelOfTheTable`. The partitioned method never chosen past 2²² points fails the same test. The refusal of results longer than 2²⁸ values, removed, is caught by no test: such a test needs inputs of 2²⁸ values, a gibibyte. That is open as F-905b-1 of the audit.
