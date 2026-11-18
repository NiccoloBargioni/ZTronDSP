Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Orfanidis 2006, elliptic functions by Landen transformation). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4b (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Elliptic prototype (WP-409, register row 4)

`AnalogPrototype.elliptic(order:ripple:stopband:)`: `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`, on `EllipticFunctions` (see `elliptic-functions.md`).

## Hazard

1. The selectivity k = ω_p/ω_s approaches 1 geometrically with the order. The poles depend on 1 − k²: at 1 dB / 60 dB it is 1e-6 at order 30, 2e-11 at order 50, 8e-14 at order 60. Formed by subtraction it holds five digits at order 50.
2. Beyond that the transition band is narrower than the spacing of doubles around 1: the first stop-band zero would sit on the pass-band edge.
3. ε² = 10^(rp/10) − 1 and the discrimination parameter k₁² cancel for small ripples.
4. The expanded coefficient form is only moderately conditioned here (κ = 2e5 at order 12, poles through coefficients off by 4.5e-12); the real risk is 1.

## Measured behaviour

- Against `scipy.signal.ellipap`, orders 1…12 × ripple 0.1, 1, 3 dB × attenuation 40, 60, 80 dB (108 cases): poles within 2.3e-14, zeros within 1.7e-14, gain within 1.2e-13, relative (tolerance 1e-9).
- Orders 30, 50, 60 at 1 dB / 60 dB, sampled at 20 001 points per band: the pass band stays inside [10^(−1/20), 1] and the stop band below 10⁻³ to within 7.8e-16 relative, and both bounds are reached.
- Order 64 and above at those tolerances is rejected (`DSPError.invalidParameter`, parameter `order`).

## Mitigation

- 1 − k² comes from the degree equation's complementary nome and is passed, with k², to every elliptic function. It is never formed by subtraction.
- ε² and k₁² through `expm1`.
- Zeros are constructed on the imaginary axis (real part exactly 0); the upper-half-plane poles are computed and their conjugates mirrored, so the set is exactly conjugate-symmetric; the real pole of an odd order has an imaginary part of exactly 0.
- A design whose 1 − k² is below 64 ε is refused instead of returned wrong.
- No minimiser and no iteration to a tolerance anywhere in the chain (§6.3.2).

## Stress tests (`AnalogPrototypeTests`)

- `stressAHighOrderEllipticPrototypeStaysEquiripple` fails when the complement is taken as 1 − m (order 50 and 60).
- `anEllipticOrderBeyondWhatADoubleResolvesIsRejected` pins the refusal.
