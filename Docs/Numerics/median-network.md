Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering: odd-even-merge selection network, pruned to the median output, applied to whole vectors": Fitzgerald 2010; Driedger et al. 2014; Batcher 1968; Suomela 2014). No literature search was possible offline; the row is taken as current.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 16. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Median network (WP-528)

Stability register row 16. Code: `Sources/ZTronDSPCore/Toolkit/MedianNetwork.swift`. Tests: `Tests/ZTronDSPCoreTests/MedianNetworkTests.swift`.

## Hazard

There is no arithmetic in a selection network: every step is a comparison and, at most, an exchange of two values. Nothing is rounded and nothing accumulates. What can go wrong is of another kind.

1. **A network that is not one.** The generator builds Batcher's odd-even merge sort for the next power of two, removes the lanes that do not exist, and prunes every exchange the median's lane does not depend on. An error in any of the three gives a network that selects the median for most inputs and misses it for some.
2. **Ties.** Two equal values may leave an exchange in either order. The value on the median's lane is the same number either way. For +0 and −0, which compare equal, it is one of the two zeros: equal as a number, not always in its sign bit.
3. **Values that are not numbers.** A comparison with a NaN is false, so an exchange that meets one leaves the two lanes as they are, and what arrives on the median's lane is then not defined by the inputs' order.

## Bound or measured behaviour

Exact: for finite inputs the value on the median's lane equals the middle element of the sorted inputs, as a number, for every count from 1 to 255.

- Exhaustive over every input of zeros and ones for odd counts up to 15 (the 0–1 principle: a network that is right for those is right for all).
- 200 random inputs per odd count up to 63, with ties, negative values and ranges of forty orders of magnitude.
- Every signal of the stress library, in windows of 3 to 63 lanes: silence (all ties), full scale, an impulse, denormal values, a decaying tail, alternating signs.

Exchanges kept after pruning: 3 for 3 lanes, at most 9 for 5, at most 26 for 9; the count grows as k·log²k.

## Mitigation

1. The network is checked by construction, not trusted: the exhaustive 0–1 test, and the test that pruning it again changes nothing (so every exchange that is kept is one the median depends on).
2. Ties need none for the value. Where the two implementations of the lane exchange must give the same bits, the lane exchange's own note says how (`lane-exchange.md`), and the GPU kernel compares integer keys (`median-metal.md`).
3. NUM-1 keeps values that are not numbers out of the signal where it enters the engine (`ztd_copy_finite` in the source adapter), so no step after it sees one. A caller that uses the network directly on its own data owns that guarantee.

## Stress test

`MedianNetworkTests.theMedianOfEveryStressSignalIsTheSortedMiddle`: windows over each signal of `StressFixture.signals(count:)`, and lanes that mix +0 and −0, against a sort. It fails when one exchange is dropped from the pruned network or when the pruning keeps the wrong lane.
