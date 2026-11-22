Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 6: Savitzky & Golay 1964). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 6. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Savitzky–Golay coefficients (WP-426, register row 6)

`DSP.savitzkyGolayCoefficients(window:polynomialOrder:derivative:)` and the fit behind it, `SavitzkyGolayFit.weights`: `Sources/ZTronDSPDesign/Smoothing/SavitzkyGolayDesign.swift`. The LAPACK call: `LAPACK.solveByOrthogonalFactorization` (`dgels`) in `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK+LeastSquares.swift`.

## Hazard

The fit is a Vandermonde system: column `i` holds the powers 0 … order of the abscissa of sample `i`.

1. Solved through its normal equations, the system has the square of its condition number.
2. On the raw abscissa (the sample index) the powers themselves leave the range of a double: 200ᵏ overflows at k = 134.

## Measured behaviour

Parity: coefficients for windows 5, 11, 31, orders 2, 3, 4 and derivatives 0, 1, 2 agree with `scipy.signal.savgol_coeffs` within 4.5e-13 (bound 1e-10). The filtered Float32 signal agrees with `savgol_filter` within 7.5e-9 in each of the five edge modes (bound 1e-5; WP-427).

Stress: a fit of order 24 across 401 samples, applied to the well-conditioned polynomials of degree 5 and above of the stress-fixture library (WP-016) sampled across the window. A fit of that order holds every one of them, so it must return the polynomial and its derivative at the middle of the window. Worst error, relative to the size of what is returned:

| Route | Scaled abscissa (−1 … 1) | Raw abscissa (−200 … 200) |
|---|---|---|
| orthogonal factorisation (`dgels`), as shipped | 8.9e-16 | 8.9e-16 |
| normal equations (`dposv`) | 8.5e-8 | 7.2e-8 |

At this order the factorisation is indifferent to the scaling (LAPACK equilibrates), and the normal equations have lost half their digits either way. What the scaling buys is hazard 2: at order 150 the raw system holds infinities and is refused, and the scaled one is still a system of numbers.

## Mitigation

- The weights are the minimum-norm solution of the `(order + 1) × window` system, found by `dgels` (QR of the transposed matrix): the normal equations are never formed.
- The abscissa is divided by the largest distance in the window, so that every power lies in −1 … 1; the right-hand side carries `d!/sᵈ`.
- A window that is even, an order at or above the window, and a negative derivative are typed errors; a derivative above the order returns zeros without a solve. A system with a value that is not finite, and a solution that is not, are `DSPError.numericalFailure`, never a NaN.
- The same weights, evaluated at the positions of the first and last half window, give the `.interpolate` edge mode: no second method.

## Stress test

`SavitzkyGolayCoefficientTests.stressAWideWindowAndAHighOrderNeedTheOrthogonalFactorisation` (`Tests/ZTronDSPDesignTests/SavitzkyGolayTests.swift`): holds the shipped route to 1e-12 on the fixtures and shows that the normal equations are at least 10⁴ times worse on either abscissa. It fails when the fit is routed through the normal equations (run against that mutation on 2026-11-15).

Register audit (WP-905a), 2026-11-21: routed through the normal equations, the test fails again. With the abscissa left unscaled it passed: on that fixture the orthogonal factorisation is as accurate on the raw abscissa (8.9e-16) as on the scaled one, and the check of order 150 accepts a typed error from either. What the scaling is for is range, not accuracy: `SavitzkyGolayCoefficientTests.stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa` fits order 84 across 10 001 samples, a well-posed fit (about 2·√window, 200 here, is what equispaced samples resolve) whose raw powers reach 5 000⁸⁴ = 10³¹⁰·⁷. On the scaled abscissa the weights reproduce the polynomial fixtures to 6.2e-15 (held to 1e-12); with the scaling removed the system is one of infinities and the test fails with `DSPError.numericalFailure(routine: "dgels")`.
