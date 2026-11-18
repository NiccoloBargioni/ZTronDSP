Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 13, "Constant-Q: octave-recursive multirate with one sparse spectral kernel": Brown & Puckette 1992 for the spectral kernel whose magnitude this step projects through; §7.2 row 18 for the banded projection it shares with the mel conversion). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 13. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Pseudo constant-Q projection (WP-523)

Stability register rows 13 and 18. Code: `Sources/ZTronDSPAnalysis/Steps/ConstantQScale.swift`, `ConstantQ/ConstantQProjection.swift`, `Nodes/ConstantQScaleNodes.swift` (`BandedConstantQNode`, `DenseConstantQNode`); the atoms are those of `ConstantQ/ConstantQKernel.swift` (`constant-q-kernel.md`). Tests: `Tests/ZTronDSPAnalysisTests/ConstantQScaleTests.swift`, and `ConstantQStabilityTests.swift` for the stress test. References: `Tests/Golden/generators/constant_q.py`. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **A bin the frame does not resolve.** A band is the response of a constant-Q atom, and the atom of a low bin is long: 34 683 samples for C1 at 22.05 kHz. The spectra the step is given come from frames of a few thousand samples. A response narrower than the distance between two bins of the frame would weigh one bin or none, and the band would read that bin whatever the pitch: a row of the chromagram that follows the frame's grid, not the music.
2. **Sums of products in single precision.** A band is a dot product of up to several hundred weights with as many bins; the dense form is one product over all bins, most of its terms zero.
3. **Two implementations.** The banded loops and `cblas_sgemv` sum in different orders (§7.4): they must agree (SEL-6).
4. **Powers.** Projecting powers through the magnitude of the response, instead of its square, would weigh the skirts of a band too heavily.
5. A band thinned too far loses what it should sum; a band near 0 Hz or the Nyquist frequency folds across it.

## Bound or measured behaviour

Every weight is a magnitude, or its square, and the step accepts magnitudes and powers only, so every term of a band is non-negative: nothing cancels, and a band is exact to about n·ε of its own value, n being its bins (the register's ε·bins for row 18).

With nothing dropped, the step equals the dense projection computed with NumPy in double precision within 3.1·10⁻⁷ of the frame maximum for magnitudes and 2.4·10⁻⁷ for powers, on the music and the speech fixture (frames of 4 096 samples; 72 semitone bins from 110 Hz, and 144 bins of a third of a semitone from C4); 10⁻⁵ is the acceptance (`thePseudoConstantQOfTheFixturesEqualsTheDenseProjection`).

On every signal of `StressFixture.signals` (WP-016), 60 semitone bands from 440 Hz on frames of 4 096 samples at 48 kHz, against the same sums in double precision; a band is 16 to 474 bins, so ε·bins is 5.6·10⁻⁵, and a band keeps 8 214 of 122 940 weights in all:

| Signal | Banded, of the band | Dense, of the band |
|---|---|---|
| `full-scale-square` | 3.2·10⁻⁷ | 5.5·10⁻⁷ |
| `full-scale-sine` | 3.5·10⁻⁷ | 2.7·10⁻⁷ |
| `white-noise` | 2.5·10⁻⁷ | 2.5·10⁻⁷ |
| `dc`, `nyquist`, `decaying-tail` | 2.3·10⁻⁷ | 2.5·10⁻⁷ |
| `silence`, `denormal`, `impulse` | exact zeros | exact zeros |

The larger of magnitudes and powers in each cell: five ε at worst, relative to each band's own value. No band is negative or not a number. A tone at a bin centre is the largest band of its frame for all 60 bins, for magnitudes and for powers (`aToneAtABinCentrePeaksInItsBin`).

Hazard 1: at each sample rate of `StressFixture.filtersNearZero` (44.1, 48, 96 and 192 kHz) a frame of 2 048 samples does not hold the atom of the fixture's corner (10 to 90 Hz); it holds the bins from Q·rate / 2 048 up, 362 Hz to 1.58 kHz for semitones.

## Mitigation

- **The frame must hold the longest atom**, checked when the pipeline is attached: the atom of the lowest bin, `⌈Q·rate / (f + γ/α)⌉` samples, is compared with the frame the spectra come from (the frame, not the length it is padded to). A longer one is an `invalidParameter` on `fmin` that names the bin, the length of its atom, a frame that holds it and the frequency from which this frame holds the bins. An atom no longer than the frame has a main lobe at least four bins of the frame wide.
- **Non-negative terms.** The weights are magnitudes of a response computed in double precision; the order rule admits magnitudes and powers on a linear-frequency axis and nothing else, at compile time and again when a description is attached.
- **Powers through the square.** The step reads the domain at its position: for powers the weights are the squares of the response, band for band over the same bins.
- **A band keeps 99.9 % of its response**, by the criterion of the kernel (`ConstantQAtom.threshold`, `constant-q-kernel.md`), and is a run from the lowest to the highest bin kept with every weight in between as it is; a band that cannot is refused.
- **The implementation is bound when the plan is compiled** (SEL-3): banded dot products, each bound to the loop its length calls for, or one dense product above the crossover of a band projection. Neither tests a size per frame.

## Stress test

`ConstantQStabilityTests.theBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`: on every signal of `StressFixture.signals`, for magnitudes and for powers, both implementations give bands that are non-negative numbers within ε·bins of the double-precision sums; and at the four sample rates of `StressFixture.filtersNearZero` a band at the fixture's corner on frames of 2 048 samples is refused with the frame that would hold it and the frequency this frame resolves from in the error, attaches from that frequency, and is refused 1 % below it.

With the check removed from `ConstantQScale` (the longest atom no longer compared with the frame) the test fails: the pipeline is refused for another reason, or attaches with bands the frame cannot tell apart. `ConstantQScaleTests.aBinTheFrameDoesNotResolveIsRefusedAndTheErrorNamesTheFrameThatWould` fails with it. With the weights of powers left unsquared `ConstantQScaleTests.thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` fails for powers. Both changes were made and run on 2026-11-16 (Debug, iOS 27.0 simulator) and the sources restored: without the comparison that test fails on four expectations; with the weights unsquared `thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` fails on both fixtures and `aBandIsTheResponseOfItsAtomAroundItsCentre` fails with it.
