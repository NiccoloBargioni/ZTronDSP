Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 21, "Window analysis: grid refinement for jumps and smoothness; a zero-padded transform for the spectral figures": Harris 1978; alternative: symbolic analysis, which a closure does not allow). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 21): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Window analysis, part 3: the spectral figures and the overlap-add sums (WP-501f)

Stability register row 21. Code: `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift` (`spectrum(of:checkpoint:)`, the overlap-add part of the initialiser), `Steps/FramingSupport.swift` (`OverlapAdd`), `Nodes/TransformPlans.swift` (`DoubleDFT`). Tests: `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift`, and `StabilityTests.swift` for the figures below. Everything here is double-precision arithmetic in background work; the figures are from the iOS 27.0 simulator on the host of §3.

## Hazard

1. **Figures read between the points of a sampled spectrum.** The top of a side lobe and the bottom of a null fall between the points of any transform. Read at the nearest point, a side-lobe level is too low and a null too wide. A parabola through decibels, the usual refinement, fails beside a null, where the level has no bottom: for the Blackman–Harris window it gave a peak side lobe of −70 dB in place of −92 dB.
2. **The power at a null is round-off**, about 10⁻³² of the power at 0 Hz in double precision, or exactly zero. Its logarithm is a number of no meaning, or −∞.
3. **A window without a sum has no power at 0 Hz** to refer the spectrum to: every level would be x / 0.
4. **Figures that do not exist.** A spectrum without a minimum has no main-lobe width between nulls and no side lobes; reporting 0 for them would be a figure.
5. **The fall-off is a fit.** The lobes next to the main lobe are not yet regular, and towards the Nyquist bin the lobes of a sampled window stop falling, because the spectrum of the samples is the sum of shifted copies of the spectrum of the function.
6. **The overlap-add sums.** The frame-bound ratio divides the greatest value of Σ w² over shifts by the least; where the least is zero, or the round-off of terms that cancel, the ratio is ∞ or noise.
7. In single precision the transform's own floor, about 140 dB under the main lobe (`real-fft.md`), lies above the side lobes of the windows one most wants to measure.

## Bound or measured behaviour

Main-lobe widths at −3 dB and between nulls within 0.05 bin, peak side lobe, scalloping loss and side-lobe fall-off within 0.1 dB (per octave for the last) of the reference, for eight stock windows at 64, 1 024 and 4 096 samples: rectangular, Hann, Hamming, Blackman, Blackman–Harris, flat-top, Kaiser β = 8.6, Gaussian σ = 0.15 (`WindowAnalysisTests.theFiguresOfTheStockWindowsEqualTheReference`; the reference takes the windows of `scipy.signal.get_window` and reads each figure from the transform evaluated where the figure lies, by root-finding and bounded minimisation, not on a grid). The overlap-add verdicts at a quarter and at half a frame equal `scipy.signal.check_NOLA` and `check_COLA`.

On the signals of `StressFixture.signals` (WP-016) taken as windows of 1 024 samples, at hops of 1, 256 and 1 024 samples, every figure of the 24 reports is a finite number or `nil`, and every point of every spectrum lies between −400 dB and the spectrum's own maximum:

- `dc` is the rectangular window: a peak side lobe of −13.26 dB, 2 bins between the nulls. `denormal`, the same rectangle 860 dB down, gives the same spectrum, point for point within 10⁻⁶ dB, and the same figures.
- `impulse` has a flat spectrum: no null, no side lobe, no fall-off (`nil`), a scalloping loss of 0, and a spectrum of 0 dB throughout. At a hop of 1 its overlap-add sums are constant; at any longer hop most samples are weighed by nothing, and the ratio is `nil`.
- `nyquist` sums to zero: the spectrum is referred to its largest value, which is 0 dB at the Nyquist bin, and reads −400 dB at 0 Hz.
- `decaying-tail` has no null either. At a hop of one frame its last samples, which have decayed to exact zeros, are weighed by nothing: not non-zero overlap-add, no ratio. At a hop of one sample every sum is the same and the ratio is 1.

## Mitigation

- **Double precision and sixteen-fold zero-padding** (`DoubleDFT`, the next transform length at or above 16·N): the floor of the transform is 300 dB under the main lobe, and a lobe is sampled by at least sixteen points.
- **A lobe's top is the top of a parabola through three powers**, not through three levels: in power the spectrum near a maximum is a parabola to second order, and a null beside it is a small number, not a pole.
- **A null is where the transform itself crosses zero.** Through a null the complex transform passes through zero in a straight line; the null is placed where the line between two neighbouring points comes nearest to zero.
- **A floor of −400 dB** under the reference on every power, before any logarithm.
- **The reference is the power at 0 Hz, or the largest power** when there is none there.
- **`nil` for what does not exist**: no first minimum, no width between nulls and no side lobes; fewer than three lobes in the fitting range, no fall-off.
- **The fall-off is fitted between N/32 (never below 8) and N/4 bins**, on the lobe tops, against the octave; lobes within 20 dB of the floor are left out.
- **Non-zero overlap-add is a relative test**: the least of Σ w² must exceed 10⁻¹⁰ of the greatest (`OverlapAdd.nonZeroFloor`). The ratio B/A is reported only then.

## Stress test

`StabilityTests.theSpectralFiguresOfEveryStressWindowAreNumbersOrNothing`, on the eight signals of `StressFixture.signals` that are windows at all, three hops each. With the floor of the powers removed the test fails: the spectra of `full-scale-square`, `dc`, `nyquist` and `denormal` hold values under −400 dB or −∞ at their nulls. Checked by making exactly that change, 2026-11-15.
