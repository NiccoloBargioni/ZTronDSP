Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 9, "Rate changes: filter-and-keep decimation; polyphase interpolation": Crochiere & Rabiner 1983; alternative: multistage half-band). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 9. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Interpolator kernel (WP-223)

Stability register row 9. Code: `Sources/CZTronDSP/ztd_rate.c`, `ztd_history.c`. Tests: `Tests/CZTronDSPTests/RateKernelTests.swift`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **Imaging.** Inserting L − 1 zeros after each sample repeats the spectrum at every multiple of the old sample rate. This is not round-off: what remains of the images is what the low-pass lets through.
2. **The gain.** Zero-stuffing divides the level of the signal by L. An interpolator that does not give it back is L times too quiet; one that gives it back per phase by some other route than the filter's own taps is uneven from phase to phase.
3. **The rounding of `vDSP_conv` depends on the shape of the call** (see `fir-direct.md`); with an output stride it takes another path again, which rounds differently from the path without one.
4. Round-off of the sums: each output is a sum of ⌈K / L⌉ products, bounded as for the direct FIR and benign.

## Bound or measured behaviour

With the default filters of §6.12 (Kaiser windowed sincs from SciPy with unity gain at 0 Hz, at least 80 dB down from the new Nyquist frequency up; `KernelFixtures.lowPass`), a constant comes out at its own level (mean within 1e-5) with its images at −99.6 dB, −95.9 dB and −98.2 dB for factors 2, 3 and 4. The response to an impulse is the taps times L, exactly, and sums to L within 1e-6.

The output equals zero-stuff-then-filter with gain L, zero-stuffed with the toolkit's `upsampled(_:by:)` and filtered in double precision, within the register's bound, for factors 1 to 5 and ten ways of cutting the input (`theOutputEqualsZeroStuffThenFilter`), also when the filter has fewer taps than the factor or a number that is not a multiple of it; and it is the same bit for bit for all cuts (`theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`).

## Mitigation

- **A polyphase filter**: output phase p is the taps p, p + L, p + 2L, … applied to the input, so no multiplication is spent on an inserted zero and no rounding either.
- **The gain is folded into the phase taps** when the kernel is created: each tap is multiplied by L once (exactly, when L is a power of two; rounded once otherwise). "The polyphase gain is exact" in the register's sense: no gain is applied to the signal at run time.
- **One shape of call**: every phase is one `vDSP_conv` over a whole cell of 64 input frames with an output stride of L, from the kernel's own aligned history into its own aligned scratch.
- Input is cleaned as it enters the history (RT-6).

## Stress test

`InterpolatorKernelTests.theGainIsTheFactor`, on the `dc` signal of `StressFixture.signals` (WP-016) and on an impulse. With the gain left out of the phase taps it fails: the constant comes out at 1 / L. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905b): the change above made again (the gain test fails at all three factors, with `theOutputEqualsZeroStuffThenFilter` and `latencySettlingTimeAndResetAreAsStated`). `vDSP_conv` called on the block's own frames instead of the whole cell fails `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`, but for a factor of 1 only, the one call without an output stride. On this simulator the strided path of factors 2 to 5 rounds the same whatever the length of the call (hazard 3: it is another path). The cells are what makes the factor of 1 exact.
