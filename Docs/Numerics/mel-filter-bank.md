Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 18, "Mel conversion: banded triangular filter bank; a dense product above the crossover": Stevens, Volkmann & Newman 1937; Slaney 1998; no alternative registered). No literature search was possible offline, so none was made.

Currency of the whole register was looked at again with network access on 2026-11-15 (`currency-2026-11.md`, row 18): this row registers a definition, a standard routine or the package's own design, so there was no method to look for a successor of, and no search was made for it.

# Mel filter bank (WP-508)

Stability register row 18. Code: `Sources/ZTronDSPAnalysis/Mel/MelFilterBank.swift`; the formulas are Core's (`MelFormula`, `Frequency.mel`). Tests: `Tests/ZTronDSPAnalysisTests/MelTests.swift`, and `StabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3; nothing here is single-precision arithmetic but the final rounding of a weight.

## Hazard

1. **A band that covers no bin.** Band m is a triangle from edge m over edge m + 1 to edge m + 2, evaluated at the bin frequencies. The mel scale is finest at low frequencies, so on a short frame the lowest bands are narrower than the distance between two bins: no bin lies inside, every weight is zero, and the band reads 0 for every signal. In decibels that is a row at the floor that looks like a quiet band; in cepstral coefficients it is a constant mixed into every coefficient.
2. **Edges through the formula and back.** hertz → mel → hertz does not return the ends of the range exactly. An upper edge one unit in the last place above the Nyquist frequency, or a lower one below the range, changes which bins the first and the last band own.
3. **Slopes from differences.** A weight is (f − lower) / (centre − lower) or its mirror image: differences of nearby numbers, harmless in double precision (a relative error of the order of ε·f / width, below 10⁻¹³ for every band of the cases below) and then rounded to a `Float`.
4. A bin exactly on an edge has weight 0 and does not belong to the band. Which side it falls on is the reference's convention as well.

## Bound or measured behaviour

The conversions round-trip within 10⁻⁹ and equal the reference values; the weights of five banks (both formulas, both normalisations, with and without a range, 12 to 128 bands) equal the reference filter bank within 10⁻⁶, absolutely and of the largest weight; each weight lies on its triangle within 10⁻⁶ of itself, and under `.slaney` the peak of band m is 2 / (f₍m+2₎ − f₍m₎) (`MelTests.theConversionsRoundTripAndEqualTheReference`, `theWeightsEqualTheReferenceFilterBank`). Every weight is finite and not negative.

Hazard 1 at the sample rates and corners of the stress library, `StressFixture.filtersNearZero` and `filtersNearNyquist` (WP-016): 128 bands from the fixture's corner up to the Nyquist frequency for the corners near 0 Hz, and from 0 Hz up to the corner for those near Nyquist.

| Fixture | Range | 256 points | 1 024 points | 4 096 points | Smallest transform that fills every band |
|---|---|---|---|---|---|
| `hp-90Hz-48k-order8` | 90 Hz … 24 kHz | 32 empty | none | none | 768 |
| `hp-20Hz-96k-order8` | 20 Hz … 48 kHz | 43 empty | 6 empty | none | 1 536 |
| `lp-10Hz-192k-order8` | 10 Hz … 96 kHz | 51 empty | 19 empty | none | 2 560 |
| `hp-10Hz-44k1-order2` | 10 Hz … 22.05 kHz | 32 empty | none | none | 768 |
| `lp-0.45fs-48k-order8` | 0 Hz … 21.6 kHz | 35 empty | none | none | 960 |
| `hp-0.45fs-44k1-order4` | 0 Hz … 19.845 kHz | 34 empty | none | none | 768 |
| `lp-0.49fs-48k-order2` | 0 Hz … 23.52 kHz | 34 empty | none | none | 768 |

Nine of the 21 banks have a band without a bin, the first of them band 0 each time. In each case `firstEmptyBand` is the band the definition gives (no bin strictly between the band's outer edges), the length in the last column has no empty band, and the transform length before it has one.

## Mitigation

- **The empty-band check** (O-18): a bank reports its first band without a weight, `firstEmptyBand`; the `MelScale` step refuses such a bank when the pipeline is attached and names the band and the smallest transform length that fills every band (`mel-projection.md`). That length is found by arithmetic on the edges (`smallestFillingLength`), over the transform lengths the rule admits.
- **The ends of the edges are the range itself**, whatever the round trip through the formula gives.
- **Weights are computed in double precision** and clamped at zero before they are rounded, so every weight is non-negative: the sums of the projection have no cancellation.
- A range that is empty or leaves 0 Hz … Nyquist, and counts that hold nothing, are typed errors when the bank is made.

## Stress test

`StabilityTests.aBandThatCoversNoBinIsFoundAtEveryRateOfTheLibrary`, on the seven filters of `StressFixture.filtersNearZero` and `filtersNearNyquist`, three frame lengths each. With the check removed (`firstEmptyBand` answering that there is none) it fails for the nine banks above, and with it `MelTests.aBandThatCoversNoBinIsReportedNotHidden`, `anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt` and `StabilityTests.theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`. Checked by making exactly that change, 2026-11-15.
