Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 13, "Constant-Q: octave-recursive multirate with one sparse spectral kernel": Schörkhuber & Klapuri 2010; Brown & Puckette 1992; alternative: the invertible sliced constant-Q of Holighaus et al. 2013, which this package has no use for while the transform has no inverse, §6.13). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 13. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Constant-Q transform: the highest octave and the octave recursion (WP-521, WP-522a)

Stability register row 13. Code: `Sources/ZTronDSPAnalysis/Steps/ConstantQ.swift`, `ConstantQ/ConstantQStrategy.swift` (`MultirateSparseKernelStrategy`), `Nodes/ConstantQNodes.swift` (`ConstantQNode`), `ConstantQ/ConstantQSchedule.swift`. Its parts have notes of their own: `constant-q-kernel.md`, `sparse-kernel-product.md`, `half-band-decimator.md`. Tests: `Tests/ZTronDSPAnalysisTests/ConstantQTests.swift`, `ConstantQScheduleTests.swift`, and `ConstantQStabilityTests.swift` for the stress tests. References: `Tests/Golden/generators/constant_q.py`, the definition evaluated directly in double precision. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **Long atoms at low frequencies.** The atom of C1 at 48 kHz is 75 499 samples; from 10 Hz at 192 kHz it is a million. Transformed as they stand, a coefficient would be a sum of that many single-precision products per hop, and the frame a megabyte.
2. **Errors that add up over the octaves.** The lowest of seven octaves has been through six decimators (`half-band-decimator.md`) and is read through a thinned kernel (`constant-q-kernel.md`): each has an error of its own.
3. **The octaves of one frame at different instants.** An octave is complete when its longest atom has seen its last sample, the high octaves early and the lowest last; its signal lags the input by the delays of the filters above it. Frames assembled as they come would mix instants up to the latency apart.
4. **Atom lengths.** An octave is read at its own rate, where the atom of a bin is as many samples long as that of the bin an octave above at twice the rate. The definition rounds a length up to a whole sample of the input rate; an octave rounds it up to a whole sample of its own.
5. **The start of the signal.** A frame centred on the first samples reaches back before them.
6. Subnormal input (`denormal`, `decaying-tail`) in the histories of the octaves.

## Bound or measured behaviour

A sine at the centre of a bin reads its amplitude within 0.012 dB in every one of the 252 bins of the defaults at 22.05 kHz, and within 0.009 dB in the highest octave at 22.05, 44.1 and 48 kHz (the tests hold 0.05 dB) (`aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude`, `aToneAtABinCentreOfTheHighestOctaveReadsItsAmplitude`); 0.5 dB is the acceptance of §6.8.

Against the definition on the fixtures, as a share of the largest magnitude of the excerpt (`theTransformOfTheFixturesIsThatOfTheDefinition`); in brackets the worst frame against its own maximum and, for sparsity 0.01, the mean over the frames:

| Fixture, bins | Sparsity 0.01 | Sparsity 0 |
|---|---|---|
| Music, the defaults: 7 octaves of 36 | 0.46 % (2.1 %, 0.64 %) | 0.18 % (0.41 %) |
| Speech, 6 octaves of 12, tuned | 0.86 % (1.5 %, 0.67 %) | 0.81 % (1.1 %) |
| Music, 7 octaves of 24, gamma 5 Hz | 0.69 % (2.4 %, 0.70 %) | 0.47 % (1.2 %) |
| Music, one octave of 36, hop 128 | 0.49 % (13 %, 0.78 %) | 0.0014 % (0.032 %) |

One octave without sparsity is the definition to the floor of a single-precision transform. What sparsity 0.01 adds is the energy a thinned row drops; what the recursion adds, with nothing dropped, is hazard 4: where the atoms are short (the speech fixture, 12 bins per octave: 175 samples at most in the highest octave at 22.05 kHz) a sample more is 0.6 % of an atom. The 13 % is a frame between two clicks of the top-octave fixture, whose own maximum is small (`constant-q-kernel.md`).

On every signal of `StressFixture.signals` (WP-016), five octaves of semitones from 220 Hz at 48 kHz, against the definition evaluated in the test:

| Signal | Largest magnitude of the definition | Off by, of that |
|---|---|---|
| `full-scale-square` | 1.24 | 0.36 % |
| `full-scale-sine` | 0.98 | 0.40 % |
| `white-noise` | 0.31 | 0.71 % |
| `decaying-tail` | 0.042 | 0.35 % |
| `dc` (its onset) | 0.039 | 1.7 % |
| `impulse` | 0.033 | 0.26 % |
| `nyquist` (its onset) | 0.018 | 0.44 % |
| `silence` | 0 | exact zeros |
| `denormal` | 3·10⁻⁴⁵ | 3.4·10⁻⁴⁵ at most, a few units of the smallest number there is (1.4·10⁻⁴⁵): a subnormal value keeps no relative precision |

Behind its onset a full-scale tone at the Nyquist frequency reads 6·10⁻⁶ by the definition and 6·10⁻⁵ through the transform (−84 dB), and a full-scale constant 7·10⁻⁵ and 3·10⁻⁴ (−70 dB): what a thinned row has dropped of the cancellation that makes the skirt of a Hann window as low as it is.

Latency (`ConstantQScheduleTests.aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore`): for the defaults 39 335 samples at 48 kHz, 0.82 s, of which 37 697 are the half of the longest atom that follows its centre and 1 638 the six filters (26 samples each, at rates that halve); 36 263 at 44.1 kHz; 18 919 at 22.05 kHz. With a `gamma` of 4.45 Hz it is 0.13 s at 48 kHz, with 8 Hz 0.09 s. A frame leaves in the block that brings the last sample of its lowest octave, and with one sample fewer it does not.

## Mitigation

- **The recursion itself is the mitigation of hazard 1.** No transform is longer than the longest atom of the highest octave, in samples of the rate the octave is read at: 1 180 samples for the defaults at 48 kHz whichever octave, and 429 to 483 at the corners of the stress library. A bin at 10 Hz is read from a signal halved eleven times.
- **Every part is held to a criterion of its own**: a row keeps 99.9 % of its energy, a decimator's stop band is 80 dB down and its pass band flat within 0.001 dB, and a kernel reads only what the decimators keep clean. Acceptance is by property (§6.8).
- **One instant for every octave of a frame.** `ConstantQSchedule` gives each octave a whole lag and a hop of `hop / 2^depth`; every atom is centred on the same sample (`ConstantQAtom.window`); the coefficients of an octave wait in a ring until the last octave of their frame is complete, and the frame is stamped with the time of the sample it is centred on. The latency is declared (REAL-5).
- **Hazard 4 is accepted and stated**: the lengths of an octave are those of the definition applied at its own rate, less than one sample of that rate from the definition at the input rate. That is what lets one kernel serve every octave when `gamma` is 0.
- **Before its first sample a signal is zero**: the histories of the octaves start as zeros, a reset returns them to zeros (ACT-10), and the first frames are those of the definition for a signal that begins there.
- Hazard 6: the decimators take a sample below 10⁻²⁰ as zero as it enters them (RT-6), so no octave below the highest sees subnormal input; a history holds what it is given for one span and feeds nothing back.

## Stress test

`ConstantQStabilityTests.theTransformOfEveryStressSignalIsFiniteAndThatOfTheDefinition`: on every signal of `StressFixture.signals` the frames are finite and within 3 % of the definition's largest magnitude, silence gives exact zeros, and behind their onsets a tone at the Nyquist frequency and a constant read 80 dB and 60 dB down. `theLongestAtomsOfTheLibraryAreReadFromSignalsHalvedAThousandTimesOver`: with the corners of `StressFixture.filtersNearZero` as the lowest bin (atoms of 27 434, 246 906, 987 622 and 226 845 samples; 7, 10, 12 and 10 octaves), a tone at the lowest bin and one at the highest read their amplitudes within 0.5 dB.

With the octaves written to the frame in the wrong order (the highest octave first) both fail, and `ConstantQTests.aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude`, `aToneBetweenTwoBinsIsSharedByThem` and the golden comparison with them. With the lag of the octaves left out of the schedule (`firstEnds` without `delays`) `ConstantQScheduleTests.everyOctaveOfAFrameIsCentredOnTheSameSample` fails, and the golden comparison of `ConstantQTests` rises to 190 % of the largest magnitude of the excerpt. Both checked by making exactly those changes, 2026-11-15.

Register audit, 2026-11-21 (WP-905c): every figure above is printed by the test that bounds it now ("measured WP-521", "WP-522a" and "WP-521/522a") and reproduced, with two corrections made to the note: the 252 bins are off by 0.0112 dB at worst, not 0.008 dB (the highest octave by 0.0077, 0.0078 and 0.0089 dB); and the `denormal` signal is off by 3.4·10⁻⁴⁵, two and a half units of the smallest subnormal number, not one. The fixtures: 0.46, 0.86, 0.69 and 0.49 % (frames 2.1, 1.5, 2.4 and 12.9 %; means 0.64, 0.67, 0.70 and 0.78 %), and 0.18, 0.81, 0.47 and 0.0014 % with nothing dropped (frames 0.41, 1.1, 1.2 and 0.032 %). The stress signals: 0.36, 0.40, 0.71, 0.35, 1.7, 0.26 and 0.44 % of 1.24, 0.98, 0.31, 0.042, 0.039, 0.033 and 0.018; behind the onsets 6.2·10⁻⁶ and 6.5·10⁻⁵ for the tone at the Nyquist frequency, 7.3·10⁻⁵ and 3.1·10⁻⁴ for the constant. The longest atoms (27 434 to 987 622 samples) read within 0.0061 dB. Latency 39 335, 36 263 and 18 919 samples; zeros ahead of the decimators at depths 1, 3 and 4 and lags 0, 13, 20, 23, 25, 26 and 26. One mutation per mitigation, each made and restored by `cmp`: the octaves written in the wrong order fail six tests (256 issues); the lags left out of the schedule fail seven (2 428 issues); the frames stamped without the block's origin fail `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore` and `theFramesDoNotDependOnTheBlockSize`; the histories kept over a reset fail `afterAColdStartTheFramesAreThoseOfAFreshStream`; the cleaning of subnormal input removed from the decimators' history fails `noStressSignalAliasesThroughTheDecimators`. Hazard 4 has no code to remove: it is accepted.
