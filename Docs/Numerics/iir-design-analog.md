Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus; Orfanidis 2006). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 4 and 4a to 4c (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# IIRDesign, analog (WP-418a, register row 4)

`IIRDesign(_:_:order:domain: .analog)`: `Sources/ZTronDSPDesign/IIR/IIRDesign.swift`, on the prototypes and on `ZeroPoleGain.transformed(by:)` (`Transformations/FrequencyTransformation.swift`).

## Hazard

1. Expanding the design into coefficients is ill-conditioned for clustered poles (a narrow band, a high order).
2. A band transformation sends each prototype root r to r ± √(r² − ω₀²). For a band that is wide against its centre the smaller of the two is a difference of nearly equal numbers: its relative error grows as (bandwidth/ω₀)².
3. Gains are ratios of products of the roots.

## Measured behaviour

- Against `scipy.signal.iirfilter(analog=True)` over the matrix (5 families × 4 responses × orders 1, 2, 5, 8; 80 designs): poles within 1.4e-11, zeros within 7.2e-15, gain within 5.4e-15, relative (tolerance 1e-9). The 1.4e-11 is the oracle's and comes from one design, the order-1 Chebyshev II band-stop: its prototype pole is −0.001, the image of that pole is −1.26e7, and the oracle forms the other image, −9.42, as the difference of two numbers of that size (hazard 2). Against 60-digit arithmetic the oracle's value is off by 1.39e-11 and the one computed here by nothing.
- Coefficient form against `iirfilter(output='ba')`: within 1.4e-11 of each coefficient's scale (the same root).
- A Butterworth band-pass from 20 to 20 000 rad/s: every pair of images multiplies to ω₀² within 1e-15, and each satisfies its defining quadratic to 1e-13.

## Mitigation

- The whole chain acts on zeros and poles; the coefficient form is produced only on request, from the finished roots.
- Of the two images of a root the larger is formed directly and the smaller as ω₀² divided by it.
- Zeros at infinity are placed exactly: at the origin for a high-pass and a band-pass, at ±jω₀ for a band-stop.
- Gain ratios are accumulated with alternating factors.

## Stress test

`FrequencyTransformationTests.stressAWideBandKeepsItsAccuracy`: fails when the smaller image is formed by subtraction.
