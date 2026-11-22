Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 21, "Window analysis: grid refinement for jumps and smoothness; a zero-padded transform for the spectral figures": Harris 1978; alternative: symbolic analysis, which a closure does not allow). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 21): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Window analysis, part 1: gains, edges and the tail (WP-501d)

Stability register row 21. Code: `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift` (the initialiser, `isMirrorImage`, `tail(of:peak:)`), and `Transform/FrameAlignment.swift` (`WindowNormalization.factor`). Tests: `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift`, and `StabilityTests.swift` for the figures below. Everything here is double-precision arithmetic on the control context or in background work; the figures are from the iOS 27.0 simulator on the host of §3.

## Hazard

1. **A sum that is zero, or the round-off of its terms.** The equivalent noise bandwidth is N·Σw² / (Σw)² and the amplitude normalisation is 2 / Σw. A window with lobes of both signs can sum to nothing: exactly, or to the round-off of N terms, about 10⁻¹⁵ of its peak. Dividing by the first is ∞; dividing by the second is a factor of 10¹⁵ that a framing step would apply to every frame without complaint.
2. **Tests against fixed numbers.** "Is this zero", "are these two samples equal" answered against a constant give a different verdict for the same shape at a different height.
3. **A closure far outside the frame.** To say what a custom window's function does out there it has to be called there, at arguments up to a million frame lengths away: it may return NaN, overflow, oscillate, or never settle.
4. **Samples in single precision.** The stock windows that vDSP generates exist bit for bit in `Float` (WIN-1); gains computed from those would carry 6·10⁻⁸.
5. The end of the frame is not a sample of a periodic window: "the value at the trailing edge" read from the last sample would be the value one sample before it.

## Bound or measured behaviour

Peak, coherent gain, noise gain, noise bandwidth and both normalisation factors of eight stock windows at 64, 1 024 and 4 096 samples equal the reference (NumPy and SciPy, from the definitions) within 10⁻¹² of each (`WindowAnalysisTests.theFiguresOfTheStockWindowsEqualTheReference`). The tail verdicts of eleven closures are the expected ones: decaying, constant, periodic, diverging, overflowing, returning NaN, oscillating, one-sided, settling slowly, and decaying as 1/t and as 1/t² (`theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven`).

On the signals of `StressFixture.signals` (WP-016) taken as windows of 1 024 samples:

- `silence` is a typed error (WIN-3).
- For the other eight, peak, gains and the power normalisation equal the sums taken directly, within 10⁻¹².
- `nyquist` sums to exactly 0: the noise bandwidth and the amplitude normalisation are `nil`.
- With its mean taken out and a tenth as high, `full-scale-sine` sums to −4.6·10⁻¹⁶, `full-scale-square` to −7.9·10⁻¹⁵, `decaying-tail` to 2.2·10⁻¹⁵, `impulse` to 1.5·10⁻¹⁵ and `white-noise` to −5.8·10⁻¹⁶: both figures are `nil`, `WindowNormalization.amplitude` throws, and an `STFT` asked for that normalisation with such a window is refused when it is attached. The power normalisation is finite for all of them.
- `denormal`, a rectangle 9·10⁻⁴⁴ high, has a noise bandwidth of exactly 1 bin and is symmetric, like `dc`.

## Mitigation

- **A sum counts when it stands out of its round-off**: |Σw| > 10⁻⁹·N·peak. Below that the window has no coherent gain, the two figures that divide by it are `nil` in the report, and `WindowNormalization.amplitude.factor` throws a typed error with the same test, so the report and the framing steps agree. The power normalisation divides by Σw², which is zero only for a window that is zero everywhere, and that is refused when the window is sampled.
- **Every threshold is relative** to the window's peak (symmetry, the sum) or to the larger of the two values compared (the tail).
- **The tail is probed, not trusted**: 21 arguments on each side, at 2ᵏ frame lengths, k = 0 … 20. A NaN anywhere is `.undefined`, an infinity `.unbounded`; otherwise the verdict is read from the seven farthest probes (settled, closing in, still growing, still falling), and the integrability on the line from whether |f|·|t| keeps falling. Nothing is computed from a value that is not finite. A custom window analysed without its function is not examined outside the frame, and says so (`nil`).
- **Double-precision samples** (`Window.doubleSamples`) throughout the analysis.
- The edge values are read from the symmetric form of the window on three points, which are t = 0, ½ and 1.

## Stress test

`StabilityTests.theGainsOfEveryStressWindowAreNumbersOrNothing`, on every signal of `StressFixture.signals`. With the test of the sum reduced to "not exactly zero" in the analysis, it fails for the five windows above whose sums are round-off: a noise bandwidth and an amplitude normalisation are reported for them. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905d): the figures are reproduced and now printed ("measured WP-501d"): with their mean taken out and a tenth as high, `full-scale-sine` sums to −4.58·10⁻¹⁶, `full-scale-square` to −7.88·10⁻¹⁵, `decaying-tail` to 2.24·10⁻¹⁵, `impulse` to 1.51·10⁻¹⁵ and `white-noise` to −5.83·10⁻¹⁶, `nyquist` to exactly 0: five windows sum to round-off, not to zero. `denormal` has a peak of 8.97·10⁻⁴⁴, a noise bandwidth of exactly 1 bin and is symmetric. The test of the sum reduced to "not exactly zero" fails as described (five issues), and the same change in `WindowNormalization` fails ten (the framing steps attach). The tail probed at 11 arguments in place of 21 fails `theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven`; single-precision samples fail four tests (128 issues of the reference figures); the edge values read from the samples fail `shapeAndEdgesOfTheStockWindows`. Two thresholds relative to the peak had no test that failed without them, and now have one. The symmetry: `theJumpsOfEveryStressWindowAreFoundWhereTheyAre` asks its four shapes at five heights whether they are mirror images; with an absolute tolerance the Hann and sin⁴ windows at 10²⁰ and 10³⁰ are not, and the step at 9·10⁻⁴⁴ and 10⁻²⁰ is. The tail: `StabilityTests.theTailOfAStressWindowIsJudgedAtEveryHeight` takes five functions, a Gaussian, a constant, one settling to 1 + 1/(1 + |t|), one falling as 1/|t| and one a hundredth outside the frame, whose verdicts are zero, 1, 1.00000095, zero and 0.01, and finds the same verdicts and integrability at the library's subnormal height, 10⁻²⁰, 10²⁰ and 10³⁰; with the scale fixed at 1 the constant, the settling function and the hundredth tend to zero at the two small heights.
