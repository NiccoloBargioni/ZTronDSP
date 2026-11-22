Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 9, "Rate changes: filter-and-keep decimation; polyphase interpolation": Crochiere & Rabiner 1983; alternative: multistage half-band). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 9. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Decimator kernel (WP-213)

Stability register row 9. Code: `Sources/CZTronDSP/ztd_rate.c`, `ztd_history.c`. Tests: `Tests/CZTronDSPTests/RateKernelTests.swift`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **Aliasing.** Keeping every M-th sample folds everything above the new Nyquist frequency into the band. This is not round-off: it is whatever the low-pass before the subsampling lets through.
2. **The phase.** Which samples are kept must not depend on where blocks end. A phase kept wrongly across a block boundary shifts the output by a fraction of an output sample from then on.
3. **The rounding of `vDSP_desamp` depends on the shape of the call.** Measured on the simulator: for 103 taps and a factor of 2, three in four outputs computed in calls of 7 differ in the last bits from the same outputs computed in calls of 16 (a third of them for 5 taps); calls of 16 and one call of 1 024 agree. The alignment of the input, of the output and of the taps was measured not to matter. As for the direct FIR, a kernel that called it with whatever block it was given would not be block-size invariant.
4. Round-off of the K-term sums: as for the direct FIR, bounded by K · ε · Σ|h| · max|x| and benign.

## Bound or measured behaviour

With the default filter of §6.12 for a factor of 2 (a Kaiser windowed sinc from SciPy: 103 taps, at least 80.9 dB down from the new Nyquist frequency up; `KernelFixtures.lowPass`), a full-scale tone at the old Nyquist frequency comes out at −99.5 dB. The same signal through plain subsampling comes out as a full-scale constant. A constant passes at its own level within 1e-6.

The output equals filter-then-subsample, computed in double precision at the full rate and subsampled with the toolkit's `subsampled(_:by:)`, within the register's bound, for factors 1, 2, 3, 4 and 7 and for ten ways of cutting the input (`theOutputEqualsFilterThenSubsampleForIrregularBlockSizes`); and it is the same bit for bit for all of them (`theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`).

## Mitigation

- **Filter and keep in one step**: the low-pass and the subsampling are one `vDSP_desamp`, so there is no unfiltered path. How much a given filter rejects is the designer's; what a given signal loses is measured by the inversion report (§6.13, WP-539).
- **The phase is where the kernel stands in its cell.** A cell is 16 outputs, which is 16 · M input frames counted from the kernel's first frame; output j of a cell is due when input frame j · M of the cell has arrived. There is no separate phase variable to get out of step.
- **One shape of call**: a whole cell, from the kernel's own aligned history into its own aligned scratch, whatever the blocks and wherever the caller's buffers lie. The output is the same bit for bit by construction, not by a property of `vDSP_desamp` that happened to be measured.
- Input is cleaned as it enters the history (RT-6).

## Stress test

`DecimatorKernelTests.aFullScaleToneAtNyquistDoesNotAliasIntoTheBand`, on the `nyquist` and `dc` signals of `StressFixture.signals` (WP-016). With the low-pass removed (the taps replaced by a unit impulse when the kernel is created) it fails: the alias is at full scale. Checked by making exactly that change, 2026-11-15.

Register audit, 2026-11-21 (WP-905b): the change above made again ("the alias is 0.0 dB"), and two more, one at a time. An output that is due only once the frame after its own has arrived (the phase rounded down) fails `theOutputEqualsFilterThenSubsampleForIrregularBlockSizes` for every factor from 2 up: an output short at the end (857 where 858 are due). `vDSP_desamp` called for the due outputs only, not the whole cell, fails `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes` for every factor, which confirms hazard 3. The cleaning of the input is the history's, shared with the direct FIR (`fir-direct.md`).
