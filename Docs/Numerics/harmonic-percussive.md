Currency check (§7.3), 2026-11-16: the registered source of this row was confirmed from the specification's register (§7.2 row 16, "Median filtering: odd-even-merge selection network, pruned to the median output, applied to whole vectors": Fitzgerald 2010; Driedger et al. 2014, for the separation; alternatives: incremental sorted lanes, a sort-based sliding median). No literature search was possible offline, so none was made. The register-wide search of 2026-11-15 (`currency-2026-11.md`, row 16) found median filtering still what the libraries do for this separation.

# Streaming harmonic–percussive separation (WP-531a), with its centred mode and its way back to samples (WP-531b, WP-532)

Stability register rows 16 and 22. Code: `Sources/ZTronDSPAnalysis/Nodes/HarmonicPercussiveNode.swift`, `Steps/HarmonicPercussive.swift`, `Recipes/HPSS.swift`. Its parts have notes of their own: `median-lanes.md`, `separation-masks.md`; the overlap-add it returns through is `inversion-analysis.md`. Tests: `Tests/ZTronDSPAnalysisTests/HarmonicPercussiveTests.swift`, `HPSSTests.swift`, and `RhythmSeparationStabilityTests.swift` for the figures below. References: `Tests/Golden/generators/hpss.py`. Figures are from the iOS 27.0 simulator on the host of §3, measured in Debug; the tests that bound them pass in Debug and in Release.

## Hazard

1. **A history that is not the stream's.** The median along time is taken over the last frames. After a reset, a suspension or a switch back on, frames of before are still in the ring: the first frames of the new stream would be separated by the medians of another signal.
2. **The start of a stream.** Fewer frames have arrived than the median is taken over. Whatever stands in for the missing ones decides the first frames: zeros make every start percussive.
3. **A component that is more than its spectrum.** A mask above 1, or not a number, in one bin of one frame is a click in the resynthesis.
4. **Three components that do not add up.** Each component is computed by a node of its own from medians of its own; the residual is a difference (`separation-masks.md`).
5. **Resynthesis of a masked first frame.** Overlap-add divides by the sum of the squared windows that cover a sample. At the very start of a causally framed stream that sum is the edge of one window, next to nothing. For an unmodified spectrum the quotient is exact, numerator and denominator being small together; a masked frame is not the transform of any signal, and the same division then multiplies what the mask changed by the reciprocal of the window's edge (register row 22). Framed that way, the harmonic and the percussive component of `white-noise` come back with a largest sample 489 times that of the signal.
6. **A look-ahead that is not a delay.** Centred, a frame is known (kernel − 1) / 2 frames late. If the step simply wrote nothing until then, the frames behind it would be the same frames at earlier positions in the stream: a resynthesis would begin (kernel − 1) / 2 hops early, and a bypass that delays the dry signal by the declared latency would be out of step with it.

## Bound or measured behaviour

Every bin of a component is the bin of the spectrum times a share between 0 and 1: its magnitude is at most that of the bin, its phase the same, and the three components add up to the spectrum to within the round-off of three products.

Measured on every signal of `StressFixture.signals` (WP-016), 8 192 samples, Hann frames of 1 024 at a hop of 256, kernels of 17 and 17, margins of 2 and 2, the complex spectrum, causal: 261 frames of 513 bins.

| Quantity | Measured, worst | Held by the test |
|---|---|---|
| A component's bin larger than the bin, or not a number | none | none |
| Harmonic + percussive + residual against the bin | 8.0·10⁻⁸ of the bin (0.7 ε) | 8 ε |
| The harmonic part against its definition, medians by the sort-based oracle over the frames so far, reflected at the start, mask in double precision | 1.4·10⁻⁷ of the frame maximum | 10⁻⁵ |
| Frames after a cold start against those of a fresh stream | equal, bit for bit | equal |
| The largest sample of a component returned by `HPSS`, causal and centred, three components, against the largest of the signal | 1.02 times (`full-scale-square`, harmonic, causal) | 1.5 times |

On the speech and music fixtures the centred step equals the offline separation exactly on every frame, the causal one equals the offline medians exactly on interior frames ("measured WP-531a", "measured WP-531b"), and the three components returned by `HPSS` add up to the signal with a signal-to-noise ratio of 138.6 to 139.3 dB ("measured WP-532"; the acceptance is 100 dB).

## Mitigation

- Hazard 1: **`reset()` is a cold start** (ACT-10): the node forgets how many frames it has seen and where its ring stands, and resets both median filters, whose own history is the one the median along time is taken over.
- Hazard 2: the filter along time takes the missing frames from the frames that have arrived, **reflected with the edge frame repeated** (`median-lanes.md`), which is what the offline separation does at the left edge of a spectrogram: centred, the step equals it from the first frame on.
- Hazards 3 and 4: the masks are shares by construction (`separation-masks.md`), and are applied as one real factor to both parts of a bin.
- Hazard 5: **the recipe frames the signal so that its first frames have whole window sums.** With a causal median `HPSS` frames centred: the first frame is centred on the first sample, the reflected start gives every sample of the output its full overlap, and the latency is the same frame − hop. With a centred median it frames causally behind the frames of silence the step begins with (below): the first frames that reach the synthesis are zeros, and the first samples of the component fade in with the window instead of being divided by its edge.
- Hazard 6: **on a complex spectrum a centred step is a delay line of its look-ahead and begins as one**: while its first frame waits, it writes frames of silence, each stamped with the time of the frame whose place it takes, so a frame leaves for every frame that arrives. On magnitudes, which have no way back to samples, it writes nothing until then. Frames keep the time of the spectrum they describe, from a ring of times beside the ring of frames; the look-ahead is declared as latency (REAL-5).
- A live frame is never filtered on the GPU (GPU-1): `.metal` is refused when the pipeline is attached.

## Stress test

Two tests of `RhythmSeparationStabilityTests`, on every signal of `StressFixture.signals`.

`theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold`: the first four rows of the table.

With the history kept over a reset (the node's `reset()` no longer resetting the filter along time) the test fails for the four signals whose frames differ from one to the next, `full-scale-sine`, `full-scale-square`, `decaying-tail` and `white-noise`: the frames after a cold start are not those of a fresh stream. `HarmonicPercussiveTests.aColdStartRefillsTheHistoryOfTheMedian` fails with it. Checked by making exactly that change, 2026-11-16.

`theComponentsOfEveryStressSignalComeBackNoLargerThanTheSignal`: the last row, for the three components and both alignments.

With the recipe framing causally whatever the median (hazard 5 unmitigated for a causal median) the test fails: the harmonic and the percussive component of `full-scale-sine` peak at 3.1 and 3.4 times the signal's largest sample, those of `full-scale-square` at 4.5 and 3.5 times, those of `white-noise` at 489 times. `HPSSTests.theComponentsReconstructTheInput`, `theLatencyIsOneFrameLessAHopPlusTheLookAhead` and `theRecipeIsItsExpansion` fail with it. Checked by making exactly that change, 2026-11-16.
