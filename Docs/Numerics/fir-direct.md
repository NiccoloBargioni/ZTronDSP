Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 7, "FIR, short: `vDSP_conv`, `vDSP_desamp`; a plain loop below the crossover": Apple vDSP). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 7. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Direct FIR kernel (WP-212)

Stability register row 7. Code: `Sources/CZTronDSP/ztd_fir.c`, `ztd_history.c`. Tests: `Tests/CZTronDSPTests/FIRKernelTests.swift`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **A sum of K products** in Float32. Benign: nothing is fed back, so nothing accumulates.
2. **The rounding of `vDSP_conv` depends on the shape of the call.** As observed on the host, it computes sixteen outputs at a time, and an output's rounding depends on its place among the sixteen and on whether it falls in the remainder of the call. Measured there: for 255 taps, four in ten outputs of one call of 6 000 differ in the last bits from the same outputs computed in shorter calls (of 1, 7, 64, 100, 512 and irregular lengths); filters of up to three taps are not affected. A kernel that handed `vDSP_conv` whatever block it was given would not be block-size invariant.
3. **Subnormal input** would sit in the history for K − 1 frames and make every product with it subnormal.

## Bound or measured behaviour

Error ≤ K · ε · Σ|h| · max|x| (the register's bound). Measured against a naive convolution in double precision on 5 000 frames of full-scale noise, as a fraction of that bound: 0.47 for 1 tap, 0.30 for 2, 0.11 for 5, 0.011 for 31, 0.0057 for 64, 0.0012 for 255, 0.00032 for 1 500 (`theKernelEqualsOfflineConvolution`). The bound is never reached; the longer the filter, the looser it is.

The output is the same bit for bit for any sequence of block sizes, frame by frame, 63, 64, 65, 512 and irregular ones included, and wherever the caller's buffers lie (`theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`).

## Mitigation

- Hazard 1 needs none. Each output is recomputed from the input history; `theErrorStaysWithinTheRegistersBoundOnTheStressSignals` shows that after 190 000 frames of a full-scale square wave the error is within the same bound as at the start.
- Hazard 2: **cells.** The kernel cuts the stream into cells of 64 frames, counted from its first frame, and calls `vDSP_conv` in one shape only: a whole cell, from its own aligned history into its own aligned scratch. Output n is always element n mod 64 of such a call. A block that ends inside a cell computes the cell on what has arrived and the next block computes it again; blocks that are whole cells compute each cell once. Measured cost of a bad practical case, 255 taps and blocks of 48 frames: about twice the time of blocks of 512.
- Hazard 3: **input is cleaned as it enters** the history (RT-6): a sample below 1e-20 is stored as zero. Per sample and on entry, so independent of the block sizes.

## Stress test

`FIRKernelTests.theErrorStaysWithinTheRegistersBoundOnTheStressSignals`, on every signal of `StressFixture.signals` (WP-016): the error is within the register's bound of the convolution of the cleaned input, no subnormal value comes out, and silence and subnormal input give exact zeros. With the cleaning of the input removed the test fails on the `denormal` signal (subnormal products come out). With the cells removed (`vDSP_conv` called with the block's own length) `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes` fails for every tested length from five taps up. Both checked by making exactly those changes, 2026-11-15.
