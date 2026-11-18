Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering: odd-even-merge selection network, pruned to the median output, applied to whole vectors; per texel on the GPU offline": Fitzgerald 2010; Driedger et al. 2014; Batcher 1968; Suomela 2014). The network itself is the core's (`MedianNetwork`, WP-528). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 16. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Median on the GPU (WP-610)

Stability register row 16. Code: `Sources/ZTronDSPMetal/Compute/MetalMedianFilter.swift`, `Sources/ZTronDSPMetal/Shaders/Median.metal`. Tests: `Tests/ZTronDSPMetalTests/MetalMedianFilterTests.swift`. Figures are from the iOS 27.0 simulator ("Apple iOS simulator GPU") on the host of §3, and are the same in Debug and in Release.

## Hazard

The register says "none in arithmetic: comparisons only; ties and non-finite values". On a GPU that is not the whole of it:

1. **Subnormal values.** The Metal shading language does not promise subnormal floats: a device may treat them as zero. A comparison of floats then cannot tell 10⁻⁴⁰ from 0, and a minimum and maximum of the two may return either. Measured on the simulator with the network written on floats: of the windows of the stress fixture that mix zeros and subnormal values, the medians came back as 0 where a sort gives 9·10⁻⁴⁴, for kernels of 3, 17 and 31 along time. The error is below 1.2·10⁻³⁸, which no picture and no mask can show, but the result is no longer one of the input values, the GPU no longer equals the CPU lanes, and "≡ the oracle" is false.
2. **Ties between zeros of different sign.** −0 and +0 compare equal as floats; which of them a minimum returns is the device's choice. The CPU lanes follow the minimum and maximum of IEEE 754-2019, where −0 orders below +0 (`Docs/Numerics/lane-exchange.md`).
3. **Values that are not numbers.** A comparison with one is false both ways; what a network does with it depends on the lane it sits in.
4. **Edges.** A kernel wider than the spectrogram reflects more than once.

## Bound or measured behaviour

Exact. Every output is one of the input values, bit for bit, the one a sort puts in the middle:

- 228 120 elements of seeded spectrograms (33 × 20, 64 × 7, 1 × 9, 5 × 1, 257 × 40, 2 × 2; kernels 1, 3, 5, 17, 31; both axes; with and without ties) equal a sort-based oracle (`theMedianEqualsTheSortBasedOracleOnRandomSpectrograms`); so do the default kernels of §6.10 on 513 × 64 (`theDefaultKernelsOfTheSeparationAreExact`), the largest network, 255 lanes, also where it is wider than the spectrogram and reflects more than once (`theLargestKernelIsExact`), and a spectrogram of 2 049 × 600 that is computed in two dispatches, the columns at the seam included (`aSpectrogramLargerThanOneDispatchIsCutIntoRunsOfColumns`).
- Subnormal medians come back bit for bit, and of −0, +0, +0 the median is +0, of −0, −0, +0 it is −0 (`tiesAndSubnormalValuesAreTheOraclesToo`).
- One window through the core's network on the CPU and through the kernel gives the same value (`theNetworkOnTheGPUIsTheNetworkOfTheCore`).

## Mitigation

- Hazards 1 and 2: **the kernel never compares floats.** It reads each value as its 32 bits and turns them into a key, an unsigned integer that orders as the float does: `bits | 0x80000000` for a positive value, `~bits` for a negative one. Keys of negative values are reversed and lie below those of positive values, and −0 lies directly below +0, which is the order of IEEE 754-2019 that the CPU lanes use. The compare-exchanges of the network are integer minima and maxima on the keys, and the median's key is turned back into the bits it came from. A device cannot flush an integer.
- Hazard 3: NUM-1 keeps such values out of every spectrogram. If one arrives anyway its key lies above +∞ (below −∞ with the sign bit set), so it is sorted like a very large value and is returned only where it is the median; the CPU lanes make both lanes not-a-number instead. The two sides are not required to agree there.
- Hazard 4: the reflection is computed with the period of twice the extent, `((i mod 2n) + 2n) mod 2n`, mirrored above n, which is right for any reach.

## Stress test

`MetalMedianFilterTests.tiesAndSubnormalValuesAreTheOraclesToo`, on columns of `StressFixture.signals` (WP-016): silence, the full-scale square (ties), the constant, the tail that decays through the subnormal range, the subnormal constant, the impulse and the alternating signal, each as magnitudes and signed. The output equals the sort-based oracle for kernels of 3, 17 and 31 along both axes, every subnormal median is the oracle's bit for bit, and zeros of both signs come out in the order above. With the mitigation removed the test fails: subnormal medians read back as zero. Observed on 2026-11-15 when the kernel was first written with `float` lanes and float minima and maxima (it failed along time for all three kernels), and checked again the same day by passing each value through one float operation before its key is made (the sum of its maximum and its minimum against zero, which is the value itself): the subnormal medians, the subnormal constant and the order of the zeros all fail.

A network run with every exchange the wrong way round still leaves the median on the middle lane, by symmetry, so that change is not one a test can see; with one exchange dropped, or with the reflection off by one, `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms` fails.
