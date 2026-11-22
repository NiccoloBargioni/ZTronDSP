Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 21, "Window analysis: grid refinement for jumps and smoothness; a zero-padded transform for the spectral figures": Harris 1978; alternative: symbolic analysis, which a closure does not allow). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 21): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Window analysis, part 2: continuity, smoothness, integrability (WP-501e)

Stability register row 21. Code: `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift` (`grids`, `jumps(ofDerivative:on:peak:)`, `change(ofDerivative:on:)`, `steepestStep`, `converges`). Tests: `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift`, and `StabilityTests.swift` for the figures below. Everything here is double-precision arithmetic in background work; the figures are from the iOS 27.0 simulator on the host of §3.

## Hazard

1. **Finite differences amplify round-off as ε / hᵏ.** A window is a closure: its derivatives can only be estimated from differences of its samples. A difference of order k of samples that each carry a round-off of ε·peak carries 2ᵏ·ε·peak / hᵏ. At the finest step used, h = 2⁻¹² of the frame, that is 2·10⁻¹² of the peak for k = 1 and 1.0 for k = 4; one order further it is 8·10³, more than the fifth derivative of a Hann window, which is 5·10³ in the same units.
2. **One grid cannot tell a jump from a slope.** A steep slope crosses as much between two samples of a coarse grid as a jump does. Only refinement separates them: across a jump the change stays, across a slope it halves with the step.
3. **Round-off that grows looks like a jump that stays.** The noise of hazard 1 doubles or more with each halving of the step, so a test that asks only "did it not shrink" takes noise for a jump.
4. **Thresholds against fixed numbers** give a different verdict for the same shape at a different height: a faint window would be all noise, a tall one all jumps.
5. Jumps closer together than the stencil that looks for them cannot be told apart.

## Bound or measured behaviour

Reliable to the fourth derivative at steps of 2⁻¹² of the frame or more, as registered. Smoothness is 0 for the rectangular and the Hamming window, 1 for a triangle, 2 for Hann and Blackman, at frames of 16 to 16 384 samples; 3 and 4 for sin³ and sin⁴, and 4 for a function smooth to every order; a kink is not reported as a jump; an interior jump is located within one sample at frames of 64 to 16 384 (`WindowAnalysisTests.smoothnessIsTheOrderOfTheLowestDerivativeThatJumps`, `higherOrdersAreToldApart`, `aKinkIsNotAJump`, `anInteriorJumpIsLocatedWithinOneSample`).

On the signals of `StressFixture.signals` (WP-016) taken as windows of 1 024 samples, each sample held until the next:

| Window | Jumps found | Where, against where they are |
|---|---|---|
| `full-scale-square` | 44: the 42 steps of 2 and the two edges of 1 | the steps within ⅛ sample, the edges exact |
| `nyquist` | 1 025: a step of 2 at every sample and the two edges | the steps within ⅛ sample, none twice; the edges exact |
| `dc` | the two edges, of 1 | exact |
| `impulse` | 2, of 1: the edge and the end of the one sample | exact, and within ⅛ sample |
| `denormal` | the two edges, of 9·10⁻⁴⁴ | exact |

The ⅛ sample is half a step of the finest grid, which has four points per sample here: a jump is placed in the middle of the step it was found in. All of these have smoothness 0.

The verdicts are those of the shape whatever its height: at 9·10⁻⁴⁴, 10⁻²⁰, 1, 10²⁰ and 10³⁰ times their size, a Hann window has smoothness 2, sin⁴ has 4, a triangle 1, and a step from 1 to 0.25 at 0.3 of the frame has 0, with its jump found within one sample and three quarters of the height in size.

What the grids cannot resolve is not reported (hazard 5, WIN-6): `full-scale-sine` held per sample is a staircase whose every step is small against the next grid's stencil, and only its trailing edge is reported; of `decaying-tail`, whose every step is half the one before, only the leading edge.

## Mitigation

- **Double precision**: the grids are sampled with `Window.doubleSamples`.
- **A bounded step.** Three grids of 2¹⁰, 2¹¹ and 2¹² points over the frame, whatever the frame's length: never finer than 2⁻¹² of the frame, and never so coarse that a short frame decides the verdict.
- **No order beyond the fourth**, where the round-off of hazard 1 overtakes the derivative it is added to and hazard 3 would apply: `smoothness` 4 stands for the fourth derivative or any beyond it.
- **A jump must persist.** The change of the k-th derivative across 2k + 3 steps is taken on each grid; a place counts when the change keeps at least three quarters of its size from each grid to the next finer one. A continuous derivative keeps half.
- **A noise threshold relative to the window and to the step**: a change below 64·ε·2ᵏ⁺¹·peak / hᵏ, the round-off of such a difference at the finest step, is not a candidate, so a flat stretch has no jumps of size nothing. Being relative to the peak, it is the same test for the same shape at any height.
- **Verdicts are stated per grid** (WIN-6): the report documents the three grids, and a jump of the window itself is placed in the middle of the steepest step of the finest grid near it; of two equal steps, the nearer one.
- Integrability on the frame is read from Riemann sums on the same three grids: they agree, or close in, or the function is of bounded variation.

## Stress test

`StabilityTests.theJumpsOfEveryStressWindowAreFoundWhereTheyAre`, on the `full-scale-square`, `dc`, `impulse`, `nyquist` and `denormal` signals of `StressFixture.signals`, and on four shapes at five heights from the library's subnormal level to 10³⁰. With the noise threshold made absolute (the window's peak taken out of it) the test fails: the edges of the `denormal` rectangle are no longer found, and at heights of 9·10⁻⁴⁴ and 10⁻²⁰ the Hann window, the triangle and the step are all reported smooth to the fourth order, the step without its jump. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905d): the table is reproduced and now printed ("measured WP-501e"): `full-scale-square` 44 jumps, `nyquist` 1 025, `dc`, `impulse` and `denormal` 2 each, `full-scale-sine` and `decaying-tail` 1 each, all of smoothness 0; the steps within 0.125 sample, the edges exact. Each mitigation removed or weakened fails a test: the grids sampled in single precision (`higherOrdersAreToldApart`, and the stress test with 13 issues: the triangle at 9·10⁻⁴⁴ of smoothness 0), three grids at the finest step (eight tests), no order beyond the third (sin⁴ of smoothness 3, two tests), a persistence of one half (seven tests), the noise threshold made absolute (the stress test, nine issues, as described), a jump left where the coarse grid found it (three tests, 1 070 issues), and Riemann sums taken to agree untested (`integrabilityOnTheFrame`). The registered limit, a jump within one sample, is A-3 and B-10 of wave 2 above 4 096 and 8 192 samples, open (`register-audit-2026-11.md`, row 21).
