Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 8, "FIR, long: uniformly partitioned frequency-domain delay line": Wefers 2015; Gardner 1995; alternative: non-uniform partitioning). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 8. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Partitioned convolution: processing (WP-215)

Stability register row 8. Code: `Sources/CZTronDSP/ztd_partitioned.c` (`ztd_partitioned_process`). Tests: `Tests/CZTronDSPTests/PartitionedKernelTests.swift`, suite `PartitionedKernelTests`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **The transform floor in each partition.** Every block of output is the inverse transform of a sum of spectral products: its error is that of Float32 transforms of length 2B, relative to the largest values that went into them. Where the filter removes most of the signal (a tone in its stop band) the floor is that of the input, not of the output.
2. **Accumulation.** A structure that carried spectra or partial sums from block to block would let that floor grow with time.
3. **Two paths.** A block that is not whole partitions is computed from the first B taps convolved directly plus the rest of the filter from the delay line. The two paths round differently, so the output depends on the block sizes at the level of the floor.

## Bound or measured behaviour

Against the direct kernel on 7 000 frames of full-scale noise, the largest deviation over nine ways of cutting the input (whole partitions, several, halves, a partition and a frame, frame by frame, 7, two irregular ones, everything at once), relative to the output's peak (acceptance: −100 dB):

| Taps | Partition | Largest deviation |
|---|---|---|
| 2 001 | 512 | −120.8 dB |
| 2 001 | 64 | −120.5 dB |
| 1 000 | 256 | −124.3 dB |
| 300 | 8 | −129.8 dB |
| 100 | 128 | −130.0 dB |
| 65 | 64 | −130.1 dB |
| 64 | 64 | −134.1 dB |
| 1 | 16 | −129.5 dB |

The register has −139 dB; that figure is not reached here for long filters. No latency is added for any block size: an impulse through a 2 001-tap linear-phase filter peaks at the frame the stated latency names, for all nine cuts.

After 110 000 frames of a full-scale square wave the deviation from the direct kernel is still below −100 dB. Silence and subnormal input give exact zeros; after a burst the output is exactly zero once the filter has run out.

## Mitigation

- **Overlap-save, without feedback**: each partition of output is recomputed from the last P input windows, whose spectra are computed once each from the input history. Nothing computed for one block is added to anything computed for another, so nothing accumulates.
- The sum of products is **cleared before every use**.
- Input is cleaned as it enters (RT-6), and the spectra in the delay line and the tail taken from it are flushed when they are made, so a silent input gives an exactly silent output.
- Hazard 3 is bounded, not removed: both paths are held to −100 dB of the direct kernel, and the kernel header says that different block sizes agree within that, not bit for bit.

## Stress test

`PartitionedKernelTests.theStressSignalsStayWithinMinus100dBAndSilenceStaysSilent`, on every signal of `StressFixture.signals` (WP-016) and on a long full-scale passage. With the clearing of the sum removed (so that every partition's output carries the ones before it) the test fails, as do `theOutputIsWithinMinus100dBOfTheDirectKernel` and `noLatencyIsAddedWhateverTheBlockSize`. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905b): the change above made again (it fails as described, and `aResetIsAColdStart` with it). Two more mitigations, one at a time:

- Without the cleaning of the input, the tests above all passed. The filter of the stress test has its smallest taps in its head, and a product of them with the `denormal` signal is already zero. `subnormalInputGivesExactZerosOnBothPaths` was added, with a filter whose largest taps are in its head (255 taps, partitions of 128). Without the cleaning it fails for the three ways of cutting that take the direct head, where a subnormal value comes out and the `denormal` signal no longer gives zeros. Whole partitions still give zeros, because their spectra are flushed.
- Without the flush of the spectra in the delay line and of the tail, every test passes, and no test can tell. The input is already cleaned, so no window holds a value below 10⁻²⁰. A bin or a value of the tail is below it only by the round-off of values above it, and no subnormal value is made from it. What the flush removes lies far under the −100 dB the kernel is held to. The flush keeps the state clean (RT-6); it does not change the output. Recorded as equivalent.
