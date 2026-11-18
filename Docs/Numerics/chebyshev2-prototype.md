Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4a (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Chebyshev type II prototype (WP-407, register row 4)

`AnalogPrototype.chebyshev2(order:stopband:)`: `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`.

## Hazard

1. δ⁻² = 10^(rs/10) − 1 cancels for a small attenuation, as ε² does for type I.
2. The gain is the ratio of two products that grow and shrink geometrically with the order: Π(−zᵢ) reaches about 2ⁿ, Π(−pᵢ) the reciprocal.
3. The zeros must lie exactly on the imaginary axis; a real part of rounding size would move the notches of the digital filter off the unit circle.

## Measured behaviour

- Against `scipy.signal.cheb2ap`, orders 1…12 × attenuation 40, 60, 80 dB: poles within 1.7e-15 relative, zeros exact, gain within 3.8e-15 (tolerance 1e-9).
- 1/δ read back from the poles for 1e-9 … 0.1 dB: within 2.3e-16 relative.
- Order 512, 60 dB: the gain is a normal double; unity at 0 rad/s within 1e-10, the stated attenuation at 1 rad/s within 1e-8; all 512 zeros have a real part of exactly 0.

## Mitigation

- δ⁻² through `expm1`.
- Zeros constructed as (0, 1/sin θₘ): the real part is not computed, it is 0. An odd order has no zero for m = 0 (it lies at infinity) and none is materialised.
- The gain is accumulated with numerator and denominator factors alternating, so the running value stays near the size of the result.
- The order cap of 512 keeps both products representable.

## Stress tests (`AnalogPrototypeTests`)

- `stressASmallRippleKeepsItsDigits` fails when `expm1` is replaced by a power minus one.
- `stressTheHighestOrderIsStillRepresentable` pins the order-512 gain, response and zeros.
