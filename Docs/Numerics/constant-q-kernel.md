Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 13, "Constant-Q: octave-recursive multirate with one sparse spectral kernel": Schörkhuber & Klapuri 2010; Brown & Puckette 1992; alternative: the invertible sliced constant-Q of Holighaus et al. 2013). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 13. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Constant-Q sparse spectral kernel (WP-518)

Stability register row 13. Code: `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQKernel.swift` (`ConstantQKernel`, `ConstantQAtom`, `ConstantQAtomTransform`); the bins are `ConstantQ/ConstantQGeometry.swift`. Tests: `Tests/ZTronDSPAnalysisTests/ConstantQKernelTests.swift`, and `ConstantQStabilityTests.swift` for the stress test. References: `Tests/Golden/generators/constant_q.py`. Figures are from the iOS 27.0 simulator on the host of §3; the kernel is computed in double precision and is the same in Debug and in Release.

## Hazard

1. **Sparsification.** A row of the kernel is the transform of an atom: a main lobe around the bin's frequency and side lobes over the whole spectrum. Keeping only the large entries is what makes the transform cheap, and what is dropped is an error on every coefficient: by the Cauchy–Schwarz inequality at most √(share of the row's energy dropped) of ‖row‖·‖spectrum of the frame‖, reached by a spectrum that lies where the dropped entries are. A threshold stated as a share of the row's summed magnitude does not bound that energy: the smallest entries that make up 0.3 of the magnitude of a Hann row are up to 16 % of its energy, those that make up 0.6 of it 43 %, and 0.9 of it 71 % (the kernel of the defaults at 48 kHz).
2. **A one-sided spectrum.** The transform of a real frame is kept as bins 0 … N/2. What the transform of an atom has at negative frequencies is dropped before any threshold is applied. For an atom of many periods that is the far skirt of its window; for an atom of one or two periods it is a large part of the atom, and the coefficient of such a bin is not that of its definition.
3. **The top of the band.** Every octave but the highest is read from a signal halved by half-band decimators, which keep the lower 80 % of the band clean and no more (`half-band-decimator.md`). A row that weighs bins above that reads what the decimators have attenuated, and the aliases they have let through. The same holds for the Nyquist frequency itself, across which a transform folds.
4. Atoms of even and odd length centred half a sample apart would give the octaves of one frame different instants (`constant-q-transform.md`).

## Bound or measured behaviour

For the defaults of §6.8 (C1 up, 7 octaves of 36 bins, Hann, sparsity 0.01) the kernel of an octave is 36 rows over the spectrum of a transform of 640 points at 22.05 kHz and of 1 280 points at 44.1 and 48 kHz:

| Sample rate | Longest atom | Transform | Entries kept, of all | Per row | Least energy kept by a row |
|---|---|---|---|---|---|
| 22.05 kHz | 542 | 640 | 383 of 11 556 | 10.6 | 0.999 957 |
| 44.1 kHz | 1 084 | 1 280 | 383 of 23 076 | 10.6 | 0.999 955 |
| 48 kHz | 1 180 | 1 280 | 364 of 23 076 | 10.1 | 0.999 954 |

Sparsity 0.01 drops 4.5·10⁻⁵ of a row's energy, twenty times less than the 0.1 % the register allows. By sparsity, at 48 kHz: 0 keeps the 18 468 entries of the readable band; 0.001 keeps 1 042; 0.01 keeps 364; from 0.05 on the energy criterion decides and 209 entries stay, at 0.999 001 of the energy, whatever is asked for (0.3, 0.9, 0.999).

Kept entries equal the dense kernel computed with NumPy from the definition within 10⁻⁶ of the largest entry of their row, for three geometries (`theSparseKernelIsTheDenseKernelWhereItKeepsIt`, `withoutSparsityTheKernelIsTheDenseKernelOverTheBandItReads`), and a kernel transformed by its definition in the test itself agrees under Hann, Hamming, Blackman–Harris and a custom window (`aKernelIsTheTransformOfItsAtoms`).

What a thinned kernel costs on signals: the transform of the fixtures is within 0.9 % of the definition, of the largest magnitude of the excerpt, and within 0.82 % with nothing dropped (`constant-q-transform.md`): with nothing dropped what is left is the recursion's rounding of the atom lengths (hazard 4 there), largest on the speech fixture, whose atoms are short. A quiet bin beside a loud transient is known to that floor only: in a frame whose own maximum is small the same absolute error is up to 13 % of that maximum (the top-octave fixture at a hop of 128, between two clicks).

Hazard 2, measured on atoms of 16.6 periods and white noise, with nothing dropped by the threshold (`ConstantQTests.theHighestOctaveIsTheDefinitionWithoutTheSparsity`):

| Window | Energy of the atom at negative frequencies | The highest octave against the definition, of a frame's maximum |
|---|---|---|
| Blackman–Harris | 3·10⁻¹¹ | 1.2·10⁻⁵ |
| Hann | 7·10⁻⁹ | 1.5·10⁻⁴ |
| Hamming, which does not reach zero at its edges | 5.7·10⁻⁵ | 1.3 % |

Under a rectangular window, whose side lobes fall by 6 dB an octave, atoms of 17 periods are refused for that reason (`ConstantQKernelTests.argumentsOutOfRangeAreRefused`); the share of their energy at negative frequencies has not been measured separately.

## Mitigation

- **The threshold is set by the energy criterion.** `ConstantQAtom.threshold` drops entries from the smallest up while the magnitudes dropped stay below `sparsity` of their sum **and** while the row keeps at least `ConstantQKernel.keptEnergyFloor`, 0.999, of its energy. `sparsity` can only make a kernel denser than the criterion asks, never sparser.
- **The energy is that of the whole atom.** By Parseval's theorem the energy of a row over both halves of the spectrum is the energy of the atom over N, computed in the time domain. What lies at negative frequencies, and above the band a row may read, is counted as dropped from the start.
- **A row that cannot keep 99.9 % in full is refused** when the transform is made, with a typed error that names the bin and says which of the three it is: too few periods (raise `binsPerOctave` or `filterScale`, lower `gamma`), too close to 0.8 of the Nyquist frequency of its octave (lower `fmin` or `octaves`), or too close to the Nyquist frequency itself.
- **A row reads no bin above 0.8 of the Nyquist frequency** where the transform has more than one octave: entries there are not candidates.
- **One centre for every atom.** The window of an atom of N samples is sampled at t = ½ + m/N for m = −⌊N/2⌋ … ⌈N/2⌉ − 1 (`ConstantQAtom.window`), so its peak is on the centre sample for even and odd N alike.
- The kernel is computed in double precision (two real transforms per atom) and rounded to single once.

## Stress test

`ConstantQStabilityTests.aKernelKeepsItsEnergyAtEveryCornerOfTheStressLibrary`, on the corners of `StressFixture.filtersNearZero` and `filtersNearNyquist` (WP-016): from each corner near 0 Hz up, as many octaves as fit at its sample rate (7 from 90 Hz at 48 kHz, 10 from 20 Hz at 96 kHz, 12 from 10 Hz at 192 kHz, 10 from 10 Hz at 44.1 kHz), every row keeps 99.9 % at sparsities 0, 0.01, 0.3, 0.9 and 0.999, and one octave more is refused for the top of the band; with a corner near the Nyquist frequency as the highest bin of a single octave, 0.45 of the sample rate is kept and 0.49 refused, and two octaves are refused for the decimators.

With the energy test removed from the thinning (`ConstantQAtom.threshold` stopping on the share of the magnitude alone) the test fails at sparsities 0.3 and above for every corner (a row then keeps 84 % of its energy at 0.3 and 30 % at 0.9), and `ConstantQKernelTests.aRowKeepsItsEnergyWhateverTheSparsityAsksFor` with it. With the refusal removed (a row accepted whatever it keeps in full) it fails for the corners near the Nyquist frequency and for the octave too many, and `ConstantQKernelTests.aRowThatCannotKeepItsEnergyIsRefusedAndTheErrorSaysWhy` with it. Both checked by making exactly those changes, 2026-11-15.

Register audit, 2026-11-21 (WP-905c): the figures of the table, of the sparsities at 48 kHz and of hazard 2 are printed by the tests now ("measured WP-518" in `ConstantQKernelTests.aRowKeepsItsEnergyWhateverTheSparsityAsksFor`, `ConstantQTests.theHighestOctaveIsTheDefinitionWithoutTheSparsity` and `ConstantQStabilityTests.aKernelKeepsItsEnergyAtEveryCornerOfTheStressLibrary`) and are those above: 383 of 11 556, 383 of 23 076 and 364 of 23 076 entries, rows keeping at least 0.999 9565, 0.999 9554 and 0.999 9539; 18 468, 1 042, 364 and 209 entries at sparsities 0, 0.001, 0.01 and 0.05 up, at 0.999 0010; 3.4·10⁻¹¹, 7.3·10⁻⁹ and 5.7·10⁻⁵ of an atom's energy at negative frequencies. The sentence on what a thinned kernel costs said "within 0.5 % with nothing dropped": the speech fixture is off by 0.81 % with nothing dropped, as `constant-q-transform.md` says, and the sentence is corrected. One mutation per mitigation, each made and restored by `cmp`: the energy test removed from the thinning fails the stress test and `aRowKeepsItsEnergyWhateverTheSparsityAsksFor` (a row then keeps 0.85 of its energy at sparsity 0.3 and 0.29 at 0.9); the energy taken from the one-sided magnitudes instead of the whole atom fails five tests, among them the stress test and the stated shares (`theSparseKernelIsTheDenseKernelWhereItKeepsIt`, 5·10⁻⁹ against 10⁻⁹); the refusal removed fails five tests; the band of 0.8 of the Nyquist frequency opened fails four, with 3 083 issues; the atoms of even length centred half a sample off fail six, among them `aKernelIsTheTransformOfItsAtoms`. The kernel rounded twice (to single, then again after the scaling by 1/N) passed every test: it moves an entry by at most a unit in the last place, far below the 10⁻⁶ of the comparisons. `ConstantQStabilityTests.everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary` was added: at every corner of `StressFixture.filtersNearZero` each of 2 876 parts of the kept entries is within half a unit of its value by the definition, summed in the test in double precision (0.499 69 at worst), and the kernel rounded twice fails it.
