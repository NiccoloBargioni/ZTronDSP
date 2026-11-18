Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 8, "FIR, long: uniformly partitioned frequency-domain delay line": Wefers 2015; Gardner 1995; alternative: non-uniform partitioning). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 8. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Partitioned convolution: delay-line structure and kernel spectra (WP-214)

Stability register row 8. Code: `Sources/CZTronDSP/ztd_partitioned.c` (`ztd_partitioned_create`, `ztd_partitioned_spectrum`). Tests: `Tests/CZTronDSPTests/PartitionedKernelTests.swift`, suite `PartitionedStructureTests`. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **The transform floor.** Each partition of the filter is transformed once, in Float32: its spectrum carries an error of about 1e-7 of its largest bin (E-30), which every output of the kernel then inherits.
2. **Conventions.** vDSP's real transform returns twice the transform, does not scale its inverse, and packs a spectrum of 2B real values as B real and B imaginary ones in which index 0 holds two different real bins, bin 0 and bin B. A factor or a bin misplaced here is not a rounding error: it is a wrong filter, and at one bin only it would pass a test on broadband noise.
3. **Transform lengths.** Creating a setup is not a safe test of a length (E-09).

## Bound or measured behaviour

The spectra the kernel holds equal the transform of each partition, computed from the definition in double precision, within 1.3e-7 of the largest bin of the partition (the largest error over all the cases tested; tolerance 1e-6): 1, 5, 8 and 9 taps in partitions of 8; 300 and 1 000 in 64; 1 000 in 256; 2 001 in 512. Where the taps make the bins small integers the spectra are exact.

## Mitigation

- The kernel spectra are computed **once, when the kernel is created**, from the taps as given; nothing is recomputed or accumulated at run time.
- The scale that makes the inverse transform of a product the convolution itself, 1 / (4N), is **a power of two** and is folded into the stored spectra: exact. The accessor undoes it, exactly.
- The two real bins are handled as what they are, in the spectra, in the products (`ztd_partitioned_convolve`) and in the accessor.
- The partition is **admitted by arithmetic** (a power of two from 8 up, so that the transform length is a documented one); a setup is created only then.

## Stress test

`PartitionedStructureTests.theSpectraOfTheStressSignalsAreExactWhereTheirEnergyIs`: taps taken from the `dc`, `nyquist`, `impulse` and `white-noise` signals of `StressFixture.signals` (WP-016) put the energy of a partition in bin 0, in bin B, evenly in all bins. With bin B left out of what the accessor returns the test fails on `nyquist`, and `theSpectraEqualTheTransformOfEachPartition` fails with it. Checked by making exactly that change, 2026-11-15.
