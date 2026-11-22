Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 5: Kaiser 1974; Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 5. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# FIR design (WP-423, WP-425, register row 5)

`WindowedSincMethod`, `LeastSquaresMethod`: `Sources/ZTronDSPDesign/FIR/FIRDesignMethod.swift`. The fit: `Sources/ZTronDSPDesign/FIR/LeastSquaresFIR.swift`. Lengths from estimates and from measurement: `Sources/ZTronDSPDesign/FIR/FIRDesign.swift`. The LAPACK calls: `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK+LeastSquares.swift`.

## Hazards

1. **Least squares.** The normal equations square the condition number of the fit. Where the bands cover the whole axis the matrix is close to diagonal. Where they leave part of the axis out (the `LeastSquares` element of an `FIRSystem` may), the cosines are no longer independent over what is left, and the matrix loses its rank in double precision.
2. **Kaiser's estimate** is made for one transition band on its own. A band that comes within its own width of 0 Hz or of the Nyquist frequency has its mirror image beside it, and the two ripples add.
3. **Symmetry.** The ideal response and the window are each symmetric only up to their last bit; a filter that is not symmetric to the bit is not exactly linear-phase, and its delay is not exactly `(K − 1)/2`.
4. **The window.** Kaiser's I₀ grows like e^β/√β; a formula with alternating terms would cancel.

## Measured behaviour

Parity (golden vectors, `Tests/Golden/generators/fir_design.py`):

| What | Against | Worst | Bound |
|---|---|---|---|
| Windowed-sinc taps: four responses; lengths 31, 101, 255 and two even ones; Hann and Kaiser windows; β from a width and from the default | `scipy.signal.firwin` | 1.1e-15 | 1e-9 |
| Kaiser's estimates, 21 cases | `kaiserord` | lengths equal; β within 1e-12 | |
| Least-squares taps, whole axis fitted | `firls` | 5.6e-16 | 1e-9 |
| Least-squares taps with a gap, reciprocal condition 2.3e-2 and 1.8e-6 | `firls` | 3.5e-18, 2.7e-14 | 1e-9 |

Least squares with a gap, by how much of the axis is left out (hazard 1). `rcond` is `dpocon`'s estimate for the normal equations:

(Register audit, 2026-11-21: the rows of 61 and 101 taps, the `rcond` and largest taps of the 31-tap row, and the errors at 41 and 101 taps were measured once, on 2026-11-15, and are printed by no test. The tests print and hold the stress fixture's 2.75e-5, the golden row, and the 31-tap ratios of error, 1.0019, and of norm, 2.386.)

| Fit | `rcond` | Cholesky alone (`dposv`) | With the test and the fall-back |
|---|---|---|---|
| bands 0…0.3 and 0.4…0.9 of Nyquist, 61 taps | 1.7e-8 | used | the same taps |
| the same, 101 taps | 5.9e-14 | error over the bands 2.298e-10; largest tap 1.2667 | fall-back; the same error to eight digits; largest tap 1.2659 |
| bands 0…0.1 and 0.3…0.5, 31 taps | 7.4e-18 | error over the bands 2.760e-9; largest tap 1 145 | fall-back; error 2.754e-9; largest tap 388 |
| the same, 41 taps and longer | not positive definite | fails (`info` 1) | fall-back; error 6.6e-11 at 41 taps, 2.0e-17 at 101 |
| stress fixture: 0…45 Hz stopped, 90…180 Hz passed at 48 kHz, 101 taps | not positive definite | fails (`info` 1) | fall-back; error 2.75e-5 |
| golden `firls-gap-ill-conditioned` | below 1e-10 | not used | error over the bands within 1.4e-11 of the oracle's; response over the bands within 1.5e-8; taps within 9.9e-6 of the largest |

So a Cholesky factor of such a system either does not exist, or it returns one of many solutions that fit the bands equally well, with taps up to three times larger than they need be. The taps of an ill-conditioned fit are not determined to 1e-9 (in the golden fixture the fourth singular value stands at 2e-12 of the first, and SciPy's own fall-back resolves that direction differently); what is determined is the fit, and that is what the fall-back is held to.

Windowed sinc at the edges of the band (hazards 2 and 3). The seven filters of `StressFixture.filtersNearZero` and `filtersNearNyquist`, each designed for 80 dB with a transition band as wide as the corner's distance from its end of the axis (103 to 96 363 taps):

| What | Worst over the seven | Bound |
|---|---|---|
| asymmetry of the taps | 0 (equal to the bit) | 0 |
| gain at the reference frequency, distance from 1 | 1.7e-14 | 1e-10 |
| stop-band attenuation with the length and β of Kaiser's estimate alone | 77.35 dB: 2.65 dB short | within 3 dB |
| stop-band attenuation from the tolerance scheme | 80.62 dB | ≥ 80 dB |

## Mitigation

- **The solve is tested.** `dposv`, then `dpocon`; when the matrix is not positive definite, or its reciprocal condition is below 1e-10, the system is solved again by `dgelsd`, whose minimum-norm solution is defined whatever the rank. A fit that covers the whole axis never takes the fall-back.
- **A length that matters is measured, not estimated.** The initialisers by tolerance scheme and by roll-off (`FIRDesign.search`) start from the method's estimate, measure the result on a grid of at least 16 points per tap, and ask for one decibel more until the scheme is met with 0.1 dB to spare. The initialiser that takes a length takes it as given; its documentation says the attenuation is then Kaiser's estimate.
- **The taps are mirrored**: the first half is copied onto the second, so that the phase is linear exactly. The least-squares taps are built symmetric.
- **The window** comes from `Window.kaiser(beta:)` of the core (WP-501b), whose I₀ is the power series with positive terms only. Kaiser's β and length follow his piecewise formulas; an attenuation below 8 dB, where they do not hold, is a typed error.
- The least-squares estimate of a length is the method's own (`LeastSquaresMethod.estimatedLength`): its error at the corner of a linear transition band falls as 1/length, so a scheme no length of at most 4 095 taps meets is a typed error that names the windowed sinc.

## Stress tests (`Tests/ZTronDSPDesignTests/FIRDesignTests.swift`)

Each was run against the mutation it names (2026-11-15) and failed.

- `LeastSquaresFIRTests.stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack` fails when the fall-back is removed (`dposv` alone has no solution for the fixture), and when the condition test is removed (the 31-tap fit then takes the Cholesky solution, whose taps are 2.4 times the norm of the smallest).
- `LeastSquaresFIRTests.anIllConditionedFitTakesTheFallBackAndStillMeetsTheOracle` fails when the fall-back is removed.
- `WindowedSincTests.stressFiltersAtTheEdgesOfTheBandAreLinearPhaseToTheBitAndReachTheirAttenuation` fails when the taps are not mirrored, and when the tolerance scheme takes its first estimate without measuring.
