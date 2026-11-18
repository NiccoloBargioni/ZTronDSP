Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4a (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Chebyshev type I prototype (WP-406, register row 4)

`AnalogPrototype.chebyshev1(order:ripple:)`: `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`.

## Hazard

1. The ripple factor ε² = 10^(rp/10) − 1 subtracts two nearly equal numbers for a small ripple: written as a power minus one it keeps 16 + log₁₀(0.23·rp) digits, about six for a ripple of 1e-9 dB.
2. The gain is Re Π(−pᵢ) = 2^(1−n)/ε, which shrinks geometrically with the order.

## Measured behaviour

- Against `scipy.signal.cheb1ap`, orders 1…12 × ripple 0.1, 1, 3 dB: poles within 4.1e-16 relative, gain within 1.4e-15 (tolerance 1e-9).
- ε read back from the poles (sinh(n·asinh(−p_real)) = 1/ε) for ripples of 1e-9, 1e-6, 1e-3 and 0.1 dB: within 3.6e-16 relative.
- Order 512, 1 dB: gain 2^(−511)/ε ≈ 3e-154, a normal double, equal to the closed form within 1e-11; the response at 0 and at 1 rad/s is the ripple floor within 1e-9.

## Mitigation

- ε² through `expm1(ln 10 · rp/10)`.
- Poles in closed form, −sinh(μ + jθₘ), with θₘ from the integer index (exact conjugates, an exactly real middle pole).
- The order is capped at 512, inside which the gain is representable.

## Stress tests (`AnalogPrototypeTests`)

- `stressASmallRippleKeepsItsDigits` fails when `expm1` is replaced by a power minus one.
- `stressTheHighestOrderIsStillRepresentable` pins the gain at the cap.
