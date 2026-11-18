Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus; normalisations as in `scipy.signal.besselap`). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4c (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Bessel prototype, three normalisations (WP-411, register row 4)

`AnalogPrototype.bessel(order:normalization:)`: `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`, on `BesselPolynomial` (see `bessel-roots.md`).

## Hazard

1. The poles inherit the conditioning of the Bessel roots (κ up to 7.8e12 at order 25).
2. The magnitude normalisation needs the −3 dB frequency of the delay-normalised filter, which has no closed form. The oracle finds it by a secant iteration with a tolerance of 1.5e-8.
3. The gain constant (2n − 1)!! is 5.8e30 at order 25.

## Measured behaviour

- Against `scipy.signal.besselap`, orders 1…25 × `phase`, `delay`, `mag` (75 cases): poles within 1.3e-14 relative, gain within 2.6e-13 (tolerance 1e-9).
- Order 25: the delay normalisation has a group delay of 1 s at 0, 1, 4 and 8 rad/s within 1e-9; the magnitude normalisation is −3 dB at 1 rad/s within 1e-12; the phase normalisation has gain 1 and poles that multiply to 1 within 1e-12.
- The hazard: the same order-25 poles through their expanded polynomial are off by 1.1e-5.

## Mitigation

- Roots from `BesselPolynomial.roots(order:)`, accurate to the last place.
- The −3 dB frequency is the root of Σ ln|jω − pᵢ| − ln k − ½·ln 2, found by Newton's method inside a bracket that bisection keeps valid, to 2 ε. The magnitude of a Bessel filter falls monotonically, so the root is unique. The oracle's own value agrees with it to 2.6e-14.
- The phase normalisation scales the poles by 10^(−log₁₀((2n − 1)!!)/n); the gain is 1 by definition.

## Stress test

`AnalogPrototypeTests.stressBesselOrderTwentyFiveMeetsItsDefinitions`, together with the order-25 rows of `besselMatchesTheOracleForOrdersOneToTwentyFiveInThreeNormalisations`: both fail when the roots are found in plain double precision.
