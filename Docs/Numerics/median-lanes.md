Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering: odd-even-merge selection network, pruned to the median output, applied to whole vectors": Fitzgerald 2010; Driedger et al. 2014; Batcher 1968; Suomela 2014; alternatives: incremental sorted lanes, a sort-based sliding median). No literature search was possible offline, so none was made. The register-wide search of 2026-11-15 (`currency-2026-11.md`, row 16) found the selection still current for medians along one axis at a time; what it found beside it is in `Docs/Process/changes/CR-020.md`, item 2.

# Median kernels on CPU lanes (WP-529)

Stability register row 16. Code: `Sources/ZTronDSPAnalysis/Nodes/MedianKernels.swift` (`LaneMedianNetwork`, `TimeLaneMedian`, `FrequencyLaneMedian`), `Separation/MedianStrategy.swift` (`SelectionNetworkMedian`, `MedianOffline`); the oracle is `Sources/ZTronDSPTesting/MedianOracle.swift`. The network is the core's (`median-network.md`), its one primitive the lane exchange of the C layer (`lane-exchange.md`), and the GPU kernel has a note of its own (`median-metal.md`). Tests: `Tests/ZTronDSPAnalysisTests/MedianKernelTests.swift`, `Tests/ZTronDSPTestingTests/MedianOracleTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

The register says "none in arithmetic: comparisons only; ties and non-finite values". Run on lanes of a stream, there is more that can go wrong, and none of it is round-off:

1. **Edges.** A median over k values has no values to take before the start of a stream or outside a frame of bins. A filter that takes zeros there, or the edge value k/2 times over, is right on interior values and wrong on the first k/2 frames and the outermost k/2 bins, which is where an onset or the lowest partial sits. A kernel longer than the stream is long, or wider than the frame, runs off the far edge as well.
2. **Ties, zeros of either sign, subnormal values.** A median is one of the values it is taken over, bit for bit, only if every exchange returns its two operands; the two implementations of the lane exchange have to return the same ones (`lane-exchange.md`).
3. **Lanes that are left as the network leaves them.** A run of the network sorts the lanes far enough for one of them to hold the median and leaves them partly ordered. Run again with one new frame in the place of the oldest, the lanes are no longer the frames.
4. **Values that are not numbers.** A comparison with one is false; what the median lane then holds is not defined by the order of the inputs.
5. A filter that is told to write where it read.

## Bound or measured behaviour

Exact: every median is the middle value of the sorted values it is taken over, bit for bit, edges included.

- The stress library (`StressFixture.signals`, WP-016), each signal cut into frames of 33 bins, 12 and 40 frames, as magnitudes and with every third value's sign turned (zeros included), kernels of 3, 17, 31 and 63, along time, along frequency and as a stream, on both lane exchanges: 741 312 medians equal the sort-based oracle bit for bit. Of those along time 14 288 are subnormal (`denormal`, the end of `decaying-tail`) and 6 739 are −0. With 12 frames the kernels of 31 and 63 reach past both ends of the stream and reflect more than once.
- Seeded data with and without ties, kernels 1 to 63, 1 to 1 025 bins: 1 074 960 medians of single filters equal the oracle (`MedianKernelTests`, "measured WP-529"), and whole spectrograms of six shapes beside them.
- Exchanges per frame, each one a minimum and a maximum over a lane of bins: 3 for 3 lanes, 70 for 17, 152 for 31, 439 for 63.

## Mitigation

- Hazard 1: **reflection with the edge value repeated** (§6.1), as often as it takes: lane j of a start is frame `held − 1 − j` reflected in the frames that have arrived, with the period of twice their number (`reflectedIndex`); a frame of bins is extended by its reflection on either side before its shifted copies are taken. The whole-spectrogram filter feeds a filter along time the stream followed by its own reflection, so that the last frames are filtered as the first are.
- Hazard 2: the lanes run on the lane exchange bound when the filter is made (SEL-3), whose two implementations follow one rule, the minimum and maximum of IEEE 754-2019 (−0 below +0), which is also the order of the oracle and of the GPU kernel's keys.
- Hazard 3: **the lanes are filled anew for every frame**, from the ring of frames along time and from the padded frame along frequency; nothing a run leaves behind is read again.
- Hazard 4: NUM-1 replaces such values where the signal enters, in the source adapter and in the offline runner; a filter that is handed one directly says in its documentation that the medians it reaches are unspecified.
- Hazard 5: the frame is copied into the lanes before anything is written.

## Stress test

`RhythmSeparationStabilityTests.theMedianLanesOfEveryStressSignalAreTheSortedMiddle`: the comparison above, and a pipeline given `StressFixture.nonFiniteSignal`, whose harmonic frames are numbers and are those of the signal with its three values replaced.

With the reflection removed from a start (the missing lanes taken from the oldest frame there is, the edge value as often as it takes) the test fails for every signal whose frames differ, `full-scale-sine`, `decaying-tail`, `impulse` and `white-noise`, and `full-scale-square` and `nyquist` with their signs: as a stream, for kernels of 17, 31 and 63 on both lane exchanges (for a kernel of 3 the two rules give the same lanes), and as a whole spectrogram along time. `silence`, `dc` and `denormal`, whose frames are all the same, pass, as do the magnitudes of the square and of the alternating signal. `MedianKernelTests` fails with it in four tests, and so do the stress tests of the masks and of the separation, which hold the step against the same oracle. Checked by making exactly that change, 2026-11-16.

Register audit, 2026-11-21 (WP-905c): the figures are reproduced: 741 312 medians equal the oracle bit for bit, 14 288 of them subnormal and 6 739 of them −0 along time, and 3, 70, 152 and 439 exchanges a frame ("measured stability row 16"); the "measured WP-529" lines add up to 1 074 960 medians, 232 560 along frequency and 842 400 along time. The reflection at a start removed, as described above, fails `MedianKernelTests` in four tests, the stress test (236 issues), and the stress tests of the masks (31) and of the separation. The padding along frequency replaced by the edge bin fails the stress test (152 issues) and `theMedianAlongFrequencyEqualsTheOracle` (80); the lanes not filled anew for every frame fail the stress test (152) and `theMedianAlongTimeEqualsTheOracle` (80); medians written before the frame is copied into the lanes fail `aFilterMayWriteWhereItRead`; the replacement of non-finite samples in the offline runner removed fails the stress test's pipeline on `StressFixture.nonFiniteSignal`.
