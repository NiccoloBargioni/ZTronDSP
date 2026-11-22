Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 20: Bristow-Johnson; Orfanidis 2005; Vicanek 2016). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 20. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Matched second-order peak (WP-422, register row 20)

`MatchedPeakDesign`: `Sources/ZTronDSPDesign/Equalizers/MatchedPeakDesign.swift`. WP-422 is an optional package; this note records what its first formulation got wrong.

## Hazard

With `x = sin²(ω/2)` the squared magnitude of a biquad is a ratio of two quadratics in `x`, whose coefficients are squares of sums of the filter's coefficients: `(1 + a₁ + a₂)²` and the like. For a narrow band at a low centre the poles and zeros crowd z = 1, these sums cancel, and everything computed from them (the numerator fitted to the three conditions, the two half-gain frequencies) is known to a few digits only.

## Measured behaviour

The first formulation solved the three conditions for the expanded coefficients. At 48 kHz its half-gain width was known to 1e-8 for a band 2 Hz wide at 20 Hz, the design's own check asks for 1e-9, and 20 bands of the acceptance grid were refused as "no matched section": every band of 2 Hz, 6.7 Hz and 0.1 octave at 20 Hz, and the 0.1-octave band at 100 Hz for ±24 dB.

In factored form, over the acceptance grid of §6.3.5 at 48 kHz (gains ±1, ±6, ±24 dB; centres 20 Hz, 100 Hz, 1 kHz, 5 kHz, 12 kHz, 0.45·fs; bandwidths of 1/10, 1/3 and 1 times the centre in hertz, 0.1 and 1 octave, Q 0.5 and 4; the bands that reach 0.49·fs removed):

| Property | Worst over the grid | Bound |
|---|---|---|
| 1. centre gain | 2.3e-11 dB | 0.01 dB |
| 2. half-gain frequencies: exactly two; distance against a bandwidth in hertz or octaves | 1.8e-11 relative | 0.5 % |
| 4. largest step against the monotonic direction | 3.9e-15 dB | 1e-9 dB |
| 5. largest pole radius | 0.99997720 | < 1 |
| boost · cut − 1 | 2.7e-15 | 1e-6 |

Stress: bands 0.02 Hz, 2 Hz and 0.5 Hz wide at 20 Hz and 0.01 Hz wide at 5 Hz, at 48, 96 and 192 kHz: centre gain within 3.42e-9 dB, bandwidth within 4.2e-10.

Shape, against the analog peak with the same centre, gain and half-gain width, over 200 fixtures with centres from 0.2 to 0.45 of the sample rate: the matched peak's largest deviation is at most 0.534 of the Cookbook peak's in every fixture; the worst fixtures are 2.14 dB (matched) and 9.80 dB (Cookbook).

## Mitigation

- The three conditions have a closed form: `|H|² = G² − (G² − 1)·(D(0)/D(x))·((x − x₀)/x₀)²`, with `D` the squared magnitude of the denominator.
- `D` is the product over the poles of `(1 − r)² + 4·r·sin²((ω ∓ θ)/2)`, with `1 − r` from `expm1` and `ω₀ − θ` without the subtraction; `x − x₀` is `sin((ω − ω₀)/2)·sin((ω + ω₀)/2)`.
- The half-gain frequencies are found by bisection on their offset from the centre; the bandwidth by bisection on the pole quality.
- The zeros are the roots of the numerator in `x − x₀`, taken to the z plane as their distance to z = 1; of the two solutions `z` and `1/z` the one whose terms do not cancel is formed first. The gain follows from 0 dB at 0 Hz.
- `zeroPoleGain` holds these roots; the coefficients of the one section are formed from them.

## Stress test

`MatchedPeakTests.stressANarrowLowBandKeepsItsAccuracy` (`Tests/ZTronDSPDesignTests/MatchedPeakTests.swift`). With the first formulation it fails (the designs throw), as does `theBandsTheLimitRejectsAreTheOnesThatReachIt`.

Register audit, 2026-11-21 (WP-905d): the figures of the factored form are reproduced (the MEASURED lines of `MatchedPeakTests`): over the grid 2.276·10⁻¹¹ dB, 1.760·10⁻¹¹, 3.857·10⁻¹⁵ dB, 0.99997720 and 2.715·10⁻¹⁵; the stress 3.412·10⁻⁹ dB and 4.193·10⁻¹⁰; the shape 0.534 at most, the worst fixtures 2.139 and 9.801 dB. Two bounds above had been rounded below what is measured and now give the measured figure: the centre gain under stress (3.4e-9) and the shape (0.53). The first formulation's figures (a width known to 10⁻⁸, twenty bands refused) are history: that code is gone, and no test reproduces them. Twenty bisection steps in place of 200 fail five tests, and the half-gain level with x₀ in place of x₀² fails six. Four mitigations survived and are recorded as equivalent at the precision in which the design holds its poles. (1) `1 − r` taken as `1 − exp(−decay)` and (2) `ω₀ − θ` taken as `ω₀ − ω₀·root` are subtractions that are exact where they cancel (Sterbenz: r within a factor of two of 1, θ of ω₀) and harmless where they do not; they give the gap and the detune of the poles as stored, where `expm1` and the form without the subtraction give the prototype's, and the two differ by the rounding of r and θ, which the stored poles carry either way. With the first the stress figures are smaller still (the bandwidth 7.93·10⁻¹¹ against 4.19·10⁻¹⁰, the centre gain 3.33·10⁻⁹ against 3.41·10⁻⁹ dB); with the second they do not move. (3) `x − x₀` taken as a difference of squares cancels by x₀ / |x − x₀| ≈ f₀ / Δf, at most 1 000 in the stress (0.02 Hz at 20 Hz): three digits of sixteen, and no printed figure moves. (4) Of `z` and `1/z`, the cancelling one formed first: their distances to z = 1 have the sum −4x and the product 4x, so the cancelling one loses about log₁₀ 2|x| digits, which counts only for a zero far from the unit circle (|x| ≫ 1); the figures move in their seventh digit or below 10⁻¹⁴.
