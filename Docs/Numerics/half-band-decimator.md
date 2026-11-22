Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 13, "Constant-Q: octave-recursive multirate with one sparse spectral kernel": Schörkhuber & Klapuri 2010; Brown & Puckette 1992; and for the filter §7.2 row 9, "Rate changes: filter-and-keep decimation", Crochiere & Rabiner 1983, whose registered alternative is the multistage half-band used here). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 13. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Half-band decimator and octave schedule (WP-519)

Stability register row 13. Code: `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQSchedule.swift` (`HalfBand`, `ConstantQSchedule`), `Nodes/ConstantQNodes.swift` (`HalfBandDecimator`); the filter is designed by `ZTronDSPDesign` (`FIRDesign`, `fir-design.md`) and run by the decimator kernel of the C layer (`decimator.md`). Tests: `Tests/ZTronDSPAnalysisTests/ConstantQScheduleTests.swift`, and `ConstantQStabilityTests.swift` for the stress tests. Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **Aliasing accumulated over octaves.** Each octave is read from the signal of the one above, halved. Halving folds everything above a quarter of the sample rate onto the band below it, and what one decimator lets through is in the signal of every octave beneath: with seven octaves the lowest has been through six.
2. **The transition band.** No filter of finite length falls from 1 to nothing at one frequency. Between its pass band and its stop band a decimator attenuates what the octave below still needs, or passes what will fold onto it.
3. **Delay.** A filter of K taps delays the signal by (K − 1)/2 samples of its input, and every octave beneath pays that again at its own, slower rate: the delays add up to (K − 1)/2 · (2^(octaves − 1) − 1) input samples, which is latency.
4. **Half samples.** After d halvings a delay of (K − 1)/2 · (2^d − 1) input samples is in general no whole number of the octave's own samples: no sample of that octave would lie on the instant a frame is centred on (`constant-q-transform.md`).
5. A hop that the octaves cannot halve would have to be rounded, and the frames of the octaves would drift apart.

## Bound or measured behaviour

The filter is a Kaiser windowed sinc whose amplitude is one half at a quarter of the sample rate: 53 taps, a delay of 26 samples. In units of the Nyquist frequency of the rate it halves, measured on 20 001 frequencies:

| Band | Edges | Measured |
|---|---|---|
| Pass band | 0 … 0.4 | within 0.000 84 dB of unity |
| Transition band | 0.4 … 0.6 | one half at 0.5; mirrors itself about it within 0.002 |
| Stop band | 0.6 … 1 | 80.38 dB down at worst |

Every second tap off the centre is zero to 10⁻¹² of the centre tap, and the taps sum to 1 within 10⁻¹². Σ|h| is 1.63: no output is larger than that times the largest input.

Through the decimator itself (single-precision taps, `vDSP_desamp`), a full-scale tone in the stop band leaves at −92 dB (0.6 of the Nyquist frequency), −119 dB (0.7), −105 dB (0.8), −97 dB (0.9) and −103 dB (the Nyquist frequency); a tone in the pass band comes out as itself within 1.5·10⁻³; a constant passes at its own level within 10⁻⁵ through six decimators in a row.

Through the whole transform (defaults of §6.8 at 22.05 kHz): a full-scale tone at the frequency that would fold onto a bin of the octave at depth 1 … 6 reads at most −94 dB in any bin of that octave or of an octave below it (`aToneThatWouldFoldOntoABinOfALowerOctaveIsNotSeen`).

Delay: for seven octaves the six filters add 1 638 input samples (26 · 63) to the 37 697 of the half of the longest atom that follows its centre at 48 kHz, 4 % of the latency of 39 335. A filter that kept the whole new band free of aliases (stop band from 0.5 up, pass band to 0.4) needs 103 taps by the same search and would add 3 213.

## Mitigation

- **A stop band 80 dB down, per octave** (§6.8): everything that would fold onto the lower 80 % of the band of the octave below. The filter is found by the same search as every FIR tolerance scheme (`FIRDesign`), which measures the stop band and lengthens the filter until the scheme is met with a tenth of a decibel to spare.
- **A kernel reads the clean band only.** The transition band folds onto the upper 20 % of the octave below; `ConstantQKernel` gives no row an entry there, and refuses a bin whose transform does not fit below it (`constant-q-kernel.md`). The half-band shape is what buys the short filter: its transition band is twice as wide as that of a filter that cleans the whole band.
- **One decimator kernel per octave, in one shape of call** (`decimator.md`): the phase is carried across blocks, so the octaves do not depend on the block size, bit for bit.
- **Whole lags.** `ConstantQSchedule` feeds one zero to a decimator ahead of its first sample where that makes the lag of the octave below a whole number of its samples (`primes`); the lag of each octave, in its own samples, is `delays`. For 53 taps and seven octaves: zeros ahead of the decimators at depths 1, 3 and 4, lags of 0, 13, 20, 23, 25, 26 and 26 samples.
- **The hop is a multiple of 2^(octaves − 1)** (O-17): another hop is refused when the pipeline is attached, and the error names the nearest hops that are.

## Stress test

`ConstantQStabilityTests.noStressSignalAliasesThroughTheDecimators`, on every signal of `StressFixture.signals` (WP-016) through six decimators in a row: every output is finite and within Σ|h| per stage of the largest input; `silence` and `denormal` give exact zeros; `dc` passes at its own level; `nyquist`, a full-scale tone at the Nyquist frequency, leaves at −95 dB; `full-scale-sine`, 997 Hz, passes the first four decimators at its own level and, like the fundamental of `full-scale-square` at 1 kHz, leaves the fifth, in whose stop band it lies, 80 dB down or more. `aToneThatWouldFoldOntoABinOfALowerOctaveIsNotSeen` holds the same at the level of the transform, for three bins of each of the six octaves that have a decimator above them.

With the filter replaced by three taps (¼, ½, ¼, in `HalfBand.taps`) both fail: the stop band of that filter is 9 dB down, the tone of 997 Hz leaves the fifth decimator at −15 dB and reads −22 dB in a bin of the transform it folds onto, and `ConstantQScheduleTests.theHalfBandFilterPassesTheLowerBandAndRejectsWhatWouldFoldOntoItByEightyDecibels` and `aToneThatWouldAliasLeavesTheDecimatorEightyDecibelsDown` fail with them. With the priming zeros removed (`primes` all 0) `ConstantQScheduleTests.everyOctaveOfAFrameIsCentredOnTheSameSample` and `everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples` fail. Both checked by making exactly those changes, 2026-11-15.

Register audit, 2026-11-21 (WP-905c): the figures are printed by the tests now ("measured WP-519") and reproduced on 4 001 frequencies, the grid of `theHalfBandFilterPassesTheLowerBandAndRejectsWhatWouldFoldOntoItByEightyDecibels`: 53 taps, the pass band within 0.000 84 dB, the stop band 80.38 dB down, Σ|h| = 1.6293, the taps summing to 1 within 2.2·10⁻¹⁶; through the decimator −92.1, −118.9, −105.3, −96.8 and −103.0 dB at 0.6, 0.7, 0.8, 0.9 and 1.0 of the Nyquist frequency; through the transform −94.06 dB; through six decimators `nyquist` −94.8 dB and the fifth decimator −95.8 dB for `full-scale-sine`, −101.9 dB for `full-scale-square`; 103 taps for a stop band from 0.5 up. The mutations of the stress paragraph made again, and one per mitigation more, each restored by `cmp`: three taps (eight tests fail, 150 issues), the priming zeros removed (four), the hop that cannot halve admitted (`theHopHalvesFromOctaveToOctaveAndAHopThatCannotIsRefusedWithTheNearestThatCan` and `theStepRefusesAnIllegalHopWhenThePipelineIsAttachedAndNamesTheStage`), and the decimator's phase dropped at every call (thirteen tests, 936 issues, `aDecimatorDoesNotDependOnHowItsInputIsCutAndStartsAgainAfterAReset` among them). The band a kernel reads is `constant-q-kernel.md`'s mutation.
