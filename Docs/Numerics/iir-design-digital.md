Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 4: Parks & Burrus; Orfanidis 2006). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 4. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# IIRDesign, digital (WP-418b, register row 4)

`IIRDesign(_:_:order:domain: .digital(sampleRate:))`: `Sources/ZTronDSPDesign/IIR/IIRDesign.swift`. Pre-warp, frequency transformation, bilinear transform, section pairing.

## Hazard

Row 4 of the stability register: expanding poles and zeros into coefficients is ill-conditioned for clustered poles. A low cutoff at a high order puts every pole within a few thousandths of z = 1; the expanded order-16 Butterworth denominator at 1 kHz / 48 kHz returns roots that are wrong by 1e-1 (`polynomial-roots.md`).

## Measured behaviour

- Against `scipy.signal.iirfilter` over the matrix (5 families × 4 responses × orders 1, 2, 5, 8; 80 designs at 48 kHz): poles within 9.0e-15, zeros within 1.0e-15, gain within 5.7e-15, relative; sections against `output='sos'` within 9.1e-15 of each section's largest coefficient; coefficient form within 9.0e-15 of each coefficient's scale (tolerance 1e-9 throughout).
- The seven stress fixtures (`StressFixture.filtersNearZero`, `.filtersNearNyquist`: 10 Hz at 192 kHz to 0.49·fs, orders 2…8): every pole, mapped back through the bilinear transform, lies on the Butterworth circle of the pre-warped cutoff within 5.2e-13 relative, and the response is −3 dB at the cutoff within 1e-9.
- An edge lands where it was asked for: −3 dB at the cutoff within 1e-11 for orders 1…8 and cutoffs from 50 Hz to 0.45·fs at 44.1 kHz.

## Mitigation

- No polynomial is expanded between the prototype and the sections (REAL-1). Each step maps roots to roots; see `bilinear-transform.md`, `iir-design-analog.md`, `section-pairing.md`.
- The pre-warp is done in double precision, on the oracle's normalisation (an internal sample rate of 2), so the tangent is taken of a number in 0 … π/2.
- An edge at 0 Hz or at the Nyquist frequency and beyond is rejected with `DSPError.invalidParameter`.

## Stress test

`IIRDesignTests.stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles`: fails when any step of the chain is routed through coefficients (the companion measurement in `SectionPairingTests.stressSectionsKeepThePolesThatAnExpandedPolynomialLoses` shows the size of the loss: 1.7e-2 for 20 Hz at 96 kHz, order 8).
