Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4a (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Butterworth prototype (WP-405, register row 4)

`AnalogPrototype.butterworth(order:)`: `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`.

## Hazard

The poles are the left-half-plane roots of 1 + (−s²)ⁿ. Found as roots of that polynomial they are ill-conditioned: at order 20 the largest root condition number is 3.3e8.

## Measured behaviour

- Against `scipy.signal.buttap`, orders 1…20: poles within 2.5e-16 relative, gain exact (tolerance 1e-9).
- Orders 20, 511, 512: every pole within 2 ulp of the unit circle, exact conjugate pairs, the real pole of an odd order exactly −1; −3 dB at 1 rad/s and unity at 0 rad/s within 1e-12.
- The hazard: the order-20 poles recovered from the expanded denominator are off by 4.8e-9, five times the golden tolerance.

## Mitigation

Each pole is written down in closed form from its integer index, pₘ = −exp(jπm/2n); the two members of a pair use ±m and are exact conjugates. The gain is 1 by definition, not a computed product. The prototype stays in zero-pole-gain form through the whole design chain.

## Stress test

`AnalogPrototypeTests.stressButterworthPolesAreClosedFormNotRootsOfAPolynomial`: fails if the poles are obtained through a polynomial (the radius and conjugacy assertions), and measures the hazard.
