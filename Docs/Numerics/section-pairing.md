Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 rows 3 and 4: Oppenheim & Schafer; Parks & Burrus). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, rows 3 and 3a (the supplement of 2026-11-18). Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# ZPK → second-order sections (WP-404, register rows 3 and 4)

`ZeroPoleGain.secondOrderSections()`: `Sources/ZTronDSPDesign/Systems/SectionPairing.swift`.

## Hazard

1. A cascade obtained by expanding the system into one polynomial and factoring it again loses poles that crowd z = 1 (low cutoffs, high orders).
2. A sharp resonance placed early in the cascade overshoots before the tamer sections have shaped the signal, which costs headroom and, in single precision, accuracy.
3. A pole pair combined with a distant zero pair gives a section with a large peak gain.

## Measured behaviour

- Parity with `scipy.signal.zpk2sos(pairing='nearest')` over 27 systems (19 designs, 8 hand-made): coefficients within 1.4e-17 of each section's largest (tolerance 1e-9).
- Fixture `hp-20Hz-96k-order8` (`StressFixture.filtersNearZero`): poles read back from the sections agree with the design to 1.7e-13; the same poles through the expanded denominator are off by 1.7e-2.
- Fixture `hp-90Hz-48k-order8`: with the sections in the order the pairing gives, no partial cascade exceeds the filter's own peak (ratio 1.000); with the order reversed the first section alone overshoots by a factor 2.61 (8.3 dB).

## Mitigation

- Each section's coefficients are formed in closed form from two roots (`−2·Re r`, `|r|²`, or sum and product of two real roots): no polynomial of higher degree is ever expanded.
- "Nearest" pairing: the pole closest to the unit circle takes the nearest zero; the pair forms the last section, and the rule is repeated for the section before it.
- Zeros or poles are added at the origin to make the counts equal and even; they are cancelled again when the cascade's roots are read.
- The design's gain goes into the first section, as in the oracle. (This is the filter's own normalisation, not a `Gain` folded into a filter, which F1 forbids.)

Known limit: where two candidates are exactly equidistant the earlier one is taken. NumPy's unstable sort may choose otherwise for more than 16 candidates; no case of the grid depends on it.

## Stress tests (`SectionPairingTests`)

- `stressSectionsKeepThePolesThatAnExpandedPolynomialLoses` fails when sections are obtained through an expanded polynomial.
- `stressTheOrderingKeepsPartialCascadesBelowThePeak` fails when the order of the sections is reversed.
- `thePairingMatchesTheReferenceSectionForSection` fails when either the pairing or the ordering is changed.
