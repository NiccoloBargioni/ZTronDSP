Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 13, "Constant-Q: octave-recursive multirate with one sparse spectral kernel": Schörkhuber & Klapuri 2010; Brown & Puckette 1992; no alternative registered for the product). Accelerate's complex sparse routines are iOS 18.5 and later (E-11), above the deployment target, so the product is the package's own. No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 13. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Sparse kernel × spectrum product (WP-520)

Stability register row 13. Code: `Sources/ZTronDSPAnalysis/Nodes/ConstantQNodes.swift` (`SparseKernelProduct`); the kernel is `ConstantQ/ConstantQKernel.swift` (`constant-q-kernel.md`). Tests: `Tests/ZTronDSPAnalysisTests/ConstantQKernelTests.swift`, and `ConstantQStabilityTests.swift` for the stress test. Figures are from the iOS 27.0 simulator on the host of §3; the errors are the same in Debug and in Release, the timings are those of a Release build.

## Hazard

1. **A sum of complex products in single precision.** A coefficient is Σ (a + jb)(x + jy) over the entries of a row: 2n products and 2n − 1 additions for each of its two parts. The entries of a row alternate in sign (the atom is centred half a frame from the start of the frame, which is a factor of about (−1)^bin on its transform), so the terms of a coefficient cancel: a bin that reads nothing reads the round-off of terms that are not nothing.
2. **Indices.** Compressed sparse rows read the spectrum through stored column indices: an index outside the spectrum would read outside it.
3. **Values that are not numbers.** A NaN in the spectrum would pass into every coefficient that reads its bin.
4. Row lengths differ: a loop written for the longest would test a size for each.

## Bound or measured behaviour

The error of a part is at most (2n + 1)·ε·T with T = Σ (|a| + |b|)·(|x| + |y|), the sum of the magnitudes of the terms, and n the entries of the row (7 to 14, 10 on average, for the defaults at 48 kHz). It is relative to the terms, not to the coefficient: nothing is fed back, so nothing accumulates from frame to frame.

Measured on the kernel of the defaults at 48 kHz (36 rows, 364 entries) against the same sums in double precision, on the spectrum of every signal of `StressFixture.signals` (WP-016), at the scale of the signal and 2⁴⁰ above and below it:

| Signal | Worst error of a row, in ε·T |
|---|---|
| `full-scale-square` | 0.78 |
| `white-noise` | 0.51 |
| `full-scale-sine`, `decaying-tail` | 0.18 |
| `impulse` | 0.16 |
| `silence`, `dc`, `nyquist`, `denormal` | 0: the kernel reads bins 51 … 115, where these have nothing |

Under one ε of the terms in every row, against a bound of 15 to 29 ε. The product equals the same kernel as a dense matrix through four `vDSP_mmul` within 10⁻⁵ of the largest coefficient, at sparsities 0, 0.01 and 0.3 (`theSparseProductIsTheDenseProduct`).

Timing (PERF-1): `theProductIsTimedAgainstTheDenseProduct` records the sparse product of the 36 rows and the same kernel as a dense 36 × 641 matrix through `Benchmark.record`, held against nothing. Recorded on 2026-11-16 in Release on the iOS 27.0 simulator of a host that other work was loading, so the figures are indicative: the sparse product takes 0.24 µs (least and median of 11 samples of 200 products), the dense one 6.1 µs at its least and 6.2 µs at its median, a factor of 25.

## Mitigation

- Hazard 1 needs none beyond what the bound says: a row is a dozen terms, each coefficient is recomputed from the spectrum of its own frame, and tolerances on spectra are stated relative to the frame maximum (§6.1). The kernel is thinned in double precision and rounded once (`constant-q-kernel.md`), so the entries carry no error of their own beyond that rounding.
- Hazard 2: the columns are those of `ConstantQKernel`, which are below `columnCount` by construction, and `ConstantQNode` refuses a kernel that is not for the length of its transform before a product is made of it.
- Hazard 3: a non-finite sample is replaced where a signal enters (NUM-1), and the transform of finite samples is finite; the product adds no division and no logarithm.
- Hazard 4: one loop over the entries, the row ends read from the row offsets; a plain loop, which is what leads at a dozen terms (E-26). It is annotated `@_noAllocation @_noLocks` under `ZTRONDSP_PERF_ANNOTATIONS` (RT-7).

## Stress test

`ConstantQStabilityTests.theProductOfEveryStressSpectrumIsWithinTheBoundOfItsTerms`: on the spectrum of every signal of `StressFixture.signals`, at three scales 80 binary orders of magnitude apart, every coefficient is finite and within (2n + 1)·ε·T of the sum in double precision, the worst row within two ε·T, and silence gives exact zeros. There is no mitigation to remove; with the sign of one product changed in the loop (`a·y − b·x` for the imaginary part) the test fails in every row of every signal that has a spectrum where the kernel reads, and `ConstantQKernelTests.theSparseProductIsTheDenseProduct` with it. Checked by making exactly that change, 2026-11-15.
