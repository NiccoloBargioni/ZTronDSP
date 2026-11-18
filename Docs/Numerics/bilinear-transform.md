Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 4. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Pre-warp and bilinear transform (WP-414, register row 4)

`ZeroPoleGain.bilinear(sampleRate:)`, `TransferFunction.bilinear(sampleRate:)`, `DSP.prewarpedAngularFrequency(hertz:sampleRate:)`: `Sources/ZTronDSPDesign/Transformations/Bilinear.swift`.

## Hazard

1. For a low cutoff every pole lands close to z = 1. What defines the filter is the pole's *distance* from 1, about |s|/fs; in the coefficient form that distance is spread over the alternating sums of a polynomial that is almost (z − 1)ⁿ.
2. For a cutoff close to the Nyquist frequency the pre-warped edge 2·fs·tan(π·f/fs) grows without bound.
3. The gain is a ratio of two products of n factors each.

## Measured behaviour

- Against `scipy.signal.bilinear_zpk` over the grid (5 prototypes × orders 2, 5, 8 × edges 0.05, 0.2, 0.45·fs × low-pass, high-pass, band-pass and band-stop 0.1 and 1 octave wide; 270 cases): poles within 4.7e-16, zeros within 4.6e-16, gain within 1.3e-15, relative (tolerance 1e-9).
- Against `scipy.signal.bilinear` (coefficient form), orders 2 and 5 (180 cases): within 3.2e-15 of each polynomial's largest coefficient.
- Fixtures `hp-90Hz-48k-order8`, `hp-20Hz-96k-order8`, `lp-10Hz-192k-order8` (`StressFixture.filtersNearZero`): the digital poles, mapped back to the analog plane, are the analog poles within 9.5e-13 relative.
- The hazard: the same three filters through the coefficient form of the transform have poles that are off by up to 1.8e-2.

## Mitigation

- The transform acts on each root, z = (2fs + s)/(2fs − s); nothing is expanded on the design path.
- The gain ratio Π(2fs − zᵢ)/Π(2fs − pᵢ) is accumulated with numerator and denominator factors alternating.
- A digital design pre-warps its edges in double precision and rejects an edge at or beyond the Nyquist frequency, so the tangent stays finite.
- The coefficient form exists for parity with etk4j and SciPy only; it is capped at degree 512 and throws when its coefficients leave the range of a double.

## Stress test

`FrequencyTransformationTests.stressTheBilinearTransformOfRootsKeepsWhatTheCoefficientFormLoses`: fails when the zero-pole transform is routed through coefficients, and measures the hazard.
