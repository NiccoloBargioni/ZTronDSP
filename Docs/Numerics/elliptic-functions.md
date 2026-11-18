Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Orfanidis 2006, elliptic functions by Landen transformation). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4b (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Elliptic helpers (WP-408, register row 4)

`EllipticFunctions`: `Sources/ZTronDSPDesign/Prototypes/EllipticFunctions.swift`. The complete integral K, the degree equation, sn / cn / dn, and the inverses of sn and sc.

## Hazard

1. **The complement.** Every function depends on the modulus k and on k′ = √(1 − k²). Close to k = 1, which is where a high-order elliptic filter lives, 1 − k² formed by subtraction holds only as many digits as k is short of 1. The textbook Landen step, which recomputes k′ₙ = √(1 − kₙ²) each time, repeats the loss at every step and, for a complement below ε, never leaves k = 1.
2. **The degree equation** returns m = k². The elliptic prototype needs 1 − m as well.
3. **The inverse sine** behind the inverse sn and sc: the logarithmic form, −j·ln(jz + √(1 − z²)), subtracts nearly equal numbers for a small argument.
4. **Iteration.** A minimiser or a fixed-point iteration to a tolerance (how older implementations solve the degree equation) leaves a tolerance in the result.

## Measured behaviour

Against tables generated from `scipy.special` (`ellipk`, `ellipkm1`, `ellipj`, `ellipkinc`) and, for the degree equation, from `scipy.optimize.brentq` on its definition; acceptance tolerance 1e-12:

| Quantity | Grid | Worst error |
|---|---|---|
| K(m) | m from 1e-12 to 0.999999 | 6.4e-16 relative |
| K(1 − p) | p from 1e-300 to 1e-3 | 3.4e-15 relative |
| degree equation, m | m₁ = 1e-10 … 1e-2, orders 1…12 | 4.0e-14 relative |
| degree equation, 1 − m | the same | 7.2e-15 relative |
| sn, cn (absolute), dn (relative) | 10 parameters × 10 arguments | 6.1e-14 |
| inverse sn | w from 0 to 1 | 1.0e-14 relative |
| inverse sc | w from 0 to 100 | 1.2e-14 relative |

The hazards, measured: K(1 − 1e-30) by the textbook recursion is wrong by a factor (relative error 8e17 at p = 1e-300, where it never converges); 1 − m by subtraction disagrees with the complementary nome by 2.8e-14 at order 12, 1.1e-9 at order 30 and 6.2e-5 at order 50 (1 dB against 60 dB); asinh by the logarithmic form is off by 2.2e-5 at an argument of 1e-12.

One limit of the *oracle*: `ellipkinc(atan(w), 1 − m)` loses digits beyond w ≈ 100 for small m (atan(w) crowds π/2); at w = 1e6, m = 1e-12 it differs by 2e-7 from this implementation, from SciPy's own Landen routine and from a quadrature of the defining integral, which agree. The table stops at w = 100.

## Mitigation

- All functions take the parameter *and* its complement. The Landen sequence carries both: kₙ₊₁ = (kₙ/(1 + k′ₙ))², k′ₙ₊₁ = 2√k′ₙ/(1 + k′ₙ). Each is a product of positive numbers; nothing is subtracted.
- The degree equation is solved through the nome, q = q₁^(1/n), and the theta-function series, summed to convergence; the complement comes from the complementary nome q′ = exp(π²/ln q) by the same series, never as 1 − m. No iteration to a tolerance.
- dn is taken from whichever of 1 − m·sn² and (1 − m)/(1 − m·cd²) subtracts less (the two differences multiply to 1 − m, so the larger is at least √(1 − m)).
- The inverse sine uses Kahan's formulas; on the imaginary axis the inverse sc reduces to a real recursion ending in `asinh`.
- K at m = 1 returns the largest finite double (NUM-1).

## Stress tests (`EllipticFunctionTests`)

- `stressTheLandenSequenceCarriesTheComplement` and `theCompleteIntegralMatchesTheTable` fail when the complement is recomputed at each Landen step.
- `stressTheDegreeEquationKeepsTheComplement` and `theDegreeEquationMatchesTheTable` fail when the complement is returned as 1 − m.
- `stressTheInverseSineOfASmallArgumentKeepsItsDigits` and `theInverseSnAndScMatchTheTable` fail with the logarithmic inverse sine.
