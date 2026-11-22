Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 20: Bristow-Johnson; Orfanidis 2005; Vicanek 2016). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 20. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# High-order band-boost (WP-421, register row 20)

`EqualizerDesign.bandBoost(center:gain:bandwidth:order:sampleRate:)`: `Sources/ZTronDSPDesign/Equalizers/EqualizerDesign.swift`.

## Hazard

Orfanidis' design gives each fourth-order section in closed form, as five numerator and five denominator coefficients. For a narrow band at a low centre the four roots of each quartic crowd z = 1, and evaluating (or running) the quartic cancels most of the digits of its coefficients.

## Measured behaviour

Over the acceptance grid of §6.3.5 at 48 kHz (orders 1…8; gains ±1, ±6, ±24 dB; centres 20 Hz, 100 Hz, 1 kHz, 5 kHz, 12 kHz, 0.45·fs; bandwidths of 1/10, 1/3 and 1 times the centre in hertz, 0.1 and 1 octave, Q 0.5 and 4; the bands that reach 0.49·fs removed), evaluated from the zero-pole form:

| Property | Worst over the grid | Bound |
|---|---|---|
| 1. centre gain | 7.8e-11 dB | 0.01 dB |
| 2. half-gain frequencies: exactly two; distance against the bandwidth | 2.7e-11 relative | 0.5 % |
| 3. gain at 0 Hz and at Nyquist | 6.0e-12 dB | 0.01 dB |
| 4. largest step against the monotonic direction | 1.4e-11 dB | 1e-9 dB |
| 5. largest pole radius | 0.99998553 | < 1 |
| 6. boost · cut − 1 | 9.3e-14 | 1e-6 |

The stress fixture: centre 20 Hz at 96 kHz, order 8 (from `StressFixture.filtersNearZero`, `hp-20Hz-96k-order8`), 2 Hz wide, ±12 dB.

| Route | Centre gain error | boost · cut − 1 |
|---|---|---|
| zero-pole form | 6.0e-11 dB | 1.8e-15 |
| the biquads paired from it (centre gain) | 7.3e-9 dB | |
| closed-form fourth-order sections | 0.95 dB | 0.24 |

## Mitigation

- The analog shelf is written down as zeros and poles (two circles of Butterworth angles), and the band transformation s = (z² − 2·cos ω₀·z + 1)/(z² − 1) is applied to each root: z = (cos ω₀ ± √(a² − sin²ω₀))/(1 − a). The radicand uses sin ω₀ itself, not cos²ω₀ − 1.
- The 2N roots are paired into N biquads by the nearest rule (`section-pairing.md`); no fourth-order section is ever formed.
- With the band edges at half the gain in decibels, the zeros of a cut are the poles of the boost and conversely, which is why property 6 holds to rounding.
- Order 1 uses the Cookbook's coefficients directly (they are well-conditioned) and the same closed-form roots.
- A band whose upper half-gain frequency would reach 0.49·fs is rejected.

## Stress test

`BandBoostTests.stressANarrowLowBandKeepsItsAccuracyInZeroPoleForm`: holds the zero-pole route to properties 1 and 6 on the fixture and shows that closed-form fourth-order sections miss both. It fails when the design is routed through those sections.

Register audit, 2026-11-21 (WP-905d): every figure is reproduced (the MEASURED lines of `BandBoostTests`): properties 1 to 6 over the grid 7.774·10⁻¹¹ dB, 2.723·10⁻¹¹, 5.991·10⁻¹² dB, 1.431·10⁻¹¹ dB, 0.99998553 and 9.286·10⁻¹⁴; on the stress fixture 5.983·10⁻¹¹ dB and 1.790·10⁻¹⁵ in zero-pole form, 7.261·10⁻⁹ dB for the paired biquads, 0.954 dB and 0.237 through closed-form fourth-order sections. The poles taken back from the expanded polynomial (the hazard itself) fail four tests, among them the stress test; the pole radius without the per-order gain fails properties 2 and 6 and the stress test; the limit at 0.49·fs widened fails `aBandThatReachesFortyNineHundredthsOfTheSampleRateIsRejected`. Order 1's Cookbook section had no test that told it from a section paired from the same zeros and poles (the two agree within 10⁻¹³): `orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads` now also asks for the Cookbook's one middle coefficient, b₁ = a₁ bit for bit, which the paired section misses by a unit in the last place in each of the six order-one bands of the test. Two mitigations survived and are recorded as equivalent for this row. The radicand from cos²ω₀ − 1 carries an absolute error of about 2ε, a relative error of up to 1.3·10⁻¹⁰ at the lowest corner of the stress library (20 Hz at 96 kHz, sin²ω₀ = 1.7·10⁻⁶); with it the figures move from 5.98·10⁻¹¹ to 3.76·10⁻¹¹ dB (zero-pole form) and from 7.26·10⁻⁹ to 2.00·10⁻⁸ dB (paired biquads), against bounds of 0.01 dB, so the form with sin ω₀ guards nothing the design states; it is kept, as it costs nothing. The nearest pairing is the mitigation of `section-pairing.md` (row 4, where a zero taken in list order fails two tests); for the band boost a zero taken in list order leaves the paired biquads within 6.29·10⁻⁹ dB.
