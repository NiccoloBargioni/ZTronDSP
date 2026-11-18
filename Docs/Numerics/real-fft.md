Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 1, "Real FFT: vDSP DFT, lengths 2ⁿ and f·2ⁿ": Apple vDSP, E-09; alternative: MPSGraph FFT for batches). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 1. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Real FFT (WP-502)

Stability register row 1. Code: `Sources/ZTronDSPAnalysis/Nodes/TransformPlans.swift` (`VDSPFFTPlan`, `DoubleDFT`), `Transform/FFTBackend.swift`, `Transform/DFT.swift`; the decibel floor is applied in `Nodes/SpectralValueNode.swift`. Tests: `Tests/ZTronDSPAnalysisTests/TransformTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **Round-off grows with the length.** Each of the log₂ N levels of the transform adds an error of the order of ε times the values it combines. The transform is backward stable: what it returns is the exact spectrum of a slightly different frame. Seen from the spectrum, that is an absolute error of about the same size in every bin, proportional to the frame's largest bin.
2. **A small bin beside a large one.** A bin far below the frame maximum carries that same absolute error, so its relative error has no bound. The logarithm of such a bin, in decibels or in a cepstrum, is the logarithm of noise.
3. **The conventions of the library.** `vDSP_DFT_zrop` takes the even and the odd samples apart, returns twice the DFT with the Nyquist bin in the place of the imaginary part of bin 0, and its inverse returns N times the signal. A factor left in is 6 dB; a bin left where the library puts it is a wrong spectrum. Neither is round-off, and neither shows on a signal without energy at the Nyquist frequency.
4. **Lengths.** A setup asked for a length outside the documented rule may be refused, may crash, or may be granted and wrong (E-09).

## Bound or measured behaviour

This re-measures the figure of E-30, whose probe was not kept. The worst deviation of the single-precision transform from the double-precision DFT of the same samples, over the nine signals of `StressFixture.signals` (WP-016), relative to the frame's largest bin; and of the forward transform followed by the inverse, relative to the signal's peak:

| Length | Forward | Forward, then inverse |
|---|---|---|
| 16 | 5.0·10⁻⁸ | 1.2·10⁻⁷ |
| 48 | 1.1·10⁻⁷ | 3.6·10⁻⁷ |
| 80 | 1.1·10⁻⁷ | 3.6·10⁻⁷ |
| 240 | 1.2·10⁻⁷ | 3.6·10⁻⁷ |
| 1 024 | 1.2·10⁻⁷ | 4.8·10⁻⁷ |
| 4 096 | 1.4·10⁻⁷ | 6.6·10⁻⁷ |
| 16 384 | 1.7·10⁻⁷ | 6.0·10⁻⁷ |

The register has "about 8·10⁻⁸"; the floor measured here is of that order and up to twice the figure at the long lengths. The tests hold it to 2.5·10⁻⁷ and the round trip to 1.5·10⁻⁶. `silence`, `impulse` and `denormal` transform exactly at every length, the last one in the subnormal range; `dc` and `nyquist` do at every length but 240, where they are off by 7·10⁻⁹.

Hazard 2, on a Hann-windowed full-scale sine of 4 096 points (the `full-scale-sine` signal): the largest error of a bin relative to the bin itself, by how far the bin lies below the frame maximum.

| Below the maximum | Error of the bin, of itself |
|---|---|
| 0 to 60 dB | 3.7·10⁻⁶ |
| 60 to 80 dB | 5.7·10⁻⁵ |
| 80 to 100 dB | 4.1·10⁻⁴ |
| 100 to 120 dB | 1.0 % |
| 120 to 140 dB | 14 % |
| 140 to 160 dB | 58 % |
| beyond 160 dB | 14 to 67 times the bin |

So a bin 100 dB below the peak is known to a per cent, as §6.1 says, and one 140 dB below it is not known at all.

In decibels: on amplitude-normalised Hann frames of 1 024 samples of every stress signal, with a floor 80 dB under full scale, single precision is within 7.3·10⁻⁴ dB of the definition computed in double precision (test bound: 0.05 dB). With the default floor of −160 dB every value is finite and at or above the floor, and what lies between about −137 dB under the frame maximum and the floor is the noise of the transform.

## Mitigation

- **Tolerances are relative to the frame maximum** wherever a spectrum is held against a reference: in the acceptance tests (`complexDeviation`, `Tolerance.relativeToMaximum`), and in the product in `InversionMeasurement`, which holds the error of a frame against the largest value of that frame (§6.13).
- **Decibel floors.** `Decibels(reference:floor:)` clamps in the linear domain before the logarithm (Core's `DSP.decibels`, called from `SpectralValueNode` with the step's floor), so a bin the transform cannot resolve reads the floor at worst and never −∞ (NUM-1). `Cepstrum(floor:)` does the same for its logarithm (`cepstrum.md`). A floor, or a display range, that ends 80 dB or less under the frame maximum hides the floor of the transform altogether.
- **The library's conventions are absorbed in one place**, `VDSPFFTPlan`: the signal is halved while it is split (exact, but for the last bit of a subnormal), the Nyquist bin is moved to its place, the inverse is scaled by 1/N. `TransformTests.theForwardTransformIsTheUnscaledDFT` holds the result against the definition, and `aConstantAndTheNyquistSignalLandInTheirBins` against the two bins a factor or a misplaced bin would spoil.
- **Lengths are admitted by arithmetic** (`TransformLength.admit`); no setup is created for a length the rule refuses (`anIllegalLengthIsATypedErrorAndNoSetupIsCreatedForIt`).
- **Double precision where figures are derived**, not displayed: the window analysis, the cepstral steps and the inversion analysis use `DoubleDFT`, whose floor is nine orders lower.

## Stress test

`StabilityTests.theErrorOfASinglePrecisionTransformIsAFloorUnderTheFrameMaximum` (the floor, on every signal of `StressFixture.signals`, seven lengths), `aBinFarBelowTheFrameMaximumIsKnownToAFloorOnly` (hazard 2, on `full-scale-sine`) and `decibelsOfEveryStressSignalAreNumbersAtOrAboveTheirFloor` (the mitigation, on every signal). With the floor of the conversion removed (`SpectralValueNode` passing −∞ in place of the floor it was given) the last one fails for eight of the nine signals: values as low as −379 dB where a floor of −160 dB or of −80 dB was asked for, up to 299 dB from what double precision reads. So do `ValueStepTests.silenceIsTheFloorAndNeverMinusInfinity`, `aFullScaleSineReadsZeroDecibelsWithEitherValue`, `aSpectrogramFillsItsFeedAndLeavesTheSamplesAlone` and `InversionTests.decibelsInvertWhereNoValueIsAtTheFloor`. With the Nyquist bin left where the library puts it (hazard 3) the first one fails as well, with twenty other tests. Both checked by making exactly that change, 2026-11-15.
