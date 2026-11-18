Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus; Orfanidis 2006; the root method is the one §6.3.2 names, Campos starting values refined by Aberth iteration). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4c (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Bessel polynomial roots (WP-410, register row 4)

`BesselPolynomial.roots(order:)`: `Sources/ZTronDSPDesign/Prototypes/BesselPolynomial.swift`.

## Hazard

The poles of a Bessel filter are the roots of the reverse Bessel polynomial θₙ(s) = Σ aₖsᵏ, whose coefficients reach (2n − 1)!! (5.8e30 at order 25, beyond 2⁵³ from order 16). The roots are ill-conditioned with respect to those coefficients: the largest condition number is 4e4 at order 10, 1.3e10 at order 20 and 7.8e12 at order 25. Beside a root, a double-precision evaluation of θₙ therefore has no more than three or four correct digits at order 25, and so has any Newton or Aberth correction computed from it.

The three-term recurrence θₙ = (2n − 1)θₙ₋₁ + s²θₙ₋₂ is no way out: near the negative real axis θₙ is the *recessive* solution of the recurrence, and running it forwards loses the same digits. (Tried: the roots of order 25 came out wrong by 3.5e-4.)

## Measured behaviour

- Residual |θₙ(r)| / Σ aₖ|r|ᵏ over all roots of orders 1…25: at most 7.8e-18 (acceptance: 1e-12).
- The roots sum to −n(n + 1)/2 within 1e-13 and multiply to (−1)ⁿ(2n − 1)!! within 1e-12 (orders 1, 2, 3, 8, 15, 25).
- Aberth's iteration settles, to a step below 4 ε, within eight steps from the Campos starting values (asserted for order 25).
- The hazard: the order-25 poles recovered from the polynomial in double precision (through the root finder) are off by 1.1e-5 … 1.0e-4, depending on the normalisation.

## Mitigation

- θₙ and θₙ′ are evaluated by Horner's rule in double-double arithmetic (`ExtendedHorner`), on coefficients that are themselves carried in double-double (exact integer recurrence aₖ₋₁ = aₖ·(2n − k + 1)·k / (2(n − k + 1))). The error of a root is then about κ·1e-32: below one unit of the last place up to order 25.
- Starting values of Campos and Calderón, inverted into the s plane; simultaneous Aberth–Ehrlich refinement; conjugates averaged so that the set is exactly symmetric.
- An iteration that does not settle is `DSPError.numericalFailure(routine: "besselRoots")`, never a half-converged answer.
- The order is capped at 25, the highest that is verified (`DSPError.unsupportedConfiguration` above). At order 30 κ is 5e15 and the margin of double-double is still ample, but nothing above 25 is tested.

## Stress tests (`BesselPolynomialTests`)

- `stressTheRootsAreFarMoreAccurateThanTheirConditioningAllowsInDoublePrecision` and `theResidualIsBelowTenToTheMinusTwelveUpToOrderTwentyFive` fail when the evaluation drops to plain double precision (the iteration then no longer settles).
