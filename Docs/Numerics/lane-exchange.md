Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering: odd-even-merge selection network, pruned to the median output, applied to whole vectors": Fitzgerald 2010; Driedger et al. 2014; Batcher 1968; Suomela 2014), of which the lane exchange is the primitive. No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 16. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Lane exchange (WP-219)

Stability register rows 16 and 24. Code: `Sources/CZTronDSP/ztd_lane_exchange.c`. Tests: `Tests/CZTronDSPTests/LaneExchangeTests.swift`. Figures are from the iOS 27.0 simulator on the host of §3.

## Hazard

There is no arithmetic in a minimum and a maximum: for two different numbers every implementation gives the same result. Two implementations can part only where the comparison does not decide:

1. **Values that are not numbers.** A comparison with a NaN is false whichever way it is asked. A loop written as `x < y ? x : y` then keeps one operand or the other depending on which lane held the NaN, so a NaN moves, stays or disappears by position; `vDSP_vmin` and `vDSP_vmax` make both results NaN.
2. **Ties between zeros of different sign.** −0 and +0 compare equal; which one a loop calls the minimum depends on how the comparison is written.

A median network built on an exchange that differed between implementations would give different medians on the C loop and on vDSP for the same data, which SEL-6 forbids.

## Bound or measured behaviour

Exact. Both implementations give the same lanes, bit for bit (any NaN counted as NaN), as the scalar exchange written out in the test, for lengths 0 to 4 097 around every boundary the implementations have (`bothImplementationsEqualTheScalarExchange`), and for every pairing of 0, −0, NaN, ±∞, ±1, the smallest subnormal and the largest finite value (`theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers`).

Timings over the size grid, recorded for WP-611b by `timingsOverTheSizeGridAreRecorded` (Release without coverage instrumentation, nanoseconds per call, the smallest of four runs):

| Lane size | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1 024 | 1 025 | 2 048 | 4 096 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| C loop | 5.8 | 5.4 | 7.0 | 8.7 | 16 | 29 | 64 | 122 | 141 | 233 | 457 |
| vDSP | 12 | 13 | 11 | 18 | 33 | 64 | 122 | 280 | 244 | 484 | 978 |

On this host the C loop is faster than vDSP at every size, by a factor of about two: it makes one pass where the vDSP form makes three (a minimum, a maximum, and a copy of the minimum back). The initial crossover of §7.4, 1 024, is not confirmed: there is none. The figures are host-only, as E-26's are. They must be taken without coverage instrumentation, which the build helper leaves on by default and which slows a C loop and not vDSP.

## Mitigation

**One rule for both implementations**, the minimum and maximum of IEEE 754-2019, which is what `vDSP_vmin` and `vDSP_vmax` compute: a NaN in either lane makes both lanes NaN, and −0 orders below +0. The C loop implements it with the instructions that are that minimum and maximum (FMIN and FMAX, four lanes at a time, on arm64) and, for the frames that are left over and on any other processor, with a scalar exchange that spells the rule out. NUM-1 keeps values that are not numbers out of the signal path; the rule makes sure that if one arrives anyway it stays visible, and the same on every implementation.

## Stress test

`LaneExchangeTests.theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers`, on `StressFixture.nonFiniteSignal` (WP-016) with zeros of both signs worked in, at lengths that put the special pairs in the four-lane body of the C loop and in its tail. With the rule removed from the scalar exchange (a plain compare-and-swap) the test fails. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905c): the exactness is what `bothImplementationsEqualTheScalarExchange` and `theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers` assert, and both pass; the timings are host figures recorded for WP-611b and were not measured again. The rule removed from the scalar exchange (a plain compare-and-swap) fails the stress test again (9 issues: the bits of the zeros and the NaN pairs).
