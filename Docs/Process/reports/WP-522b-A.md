# Verifier report — WP-522b, lens N

| Field | Value |
|---|---|
| Package | WP-522b — Time alignment across octaves; latency |
| Lens | N (the first lens of the row: N, R) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`briefs/37-verifier-a-m5c.md`)
- [x] The specification sections it cites (§6.8, REAL-5, SWAP-2, ACT-7, §9.3, VIS-2, §11, the M5 table)
- [x] The revision under review, as a checkout that can be run and modified (scratch copy, Debug and Release, simulator `ztdsp-27-vm5ca`)
- [x] The test and lint output: produced by this verifier. No coverage output exists (CR-022, "Not done")
- [x] Nothing of the other verifier's findings before this report was filed (see the disclosure in `WP-517-A.md`)

## Acceptance checks run by the verifier (VER-3)

Row: "Octaves aligned to the sample; latency reported". No ALG flag.

| Check | How it was run | Result |
|---|---|---|
| Every octave of a frame centred on the same input sample | `VA_Dumps`: an impulse through `ConstantQ`, read in the frame it lies in; `python3 -I -B VerifierA/scripts/ref.py alignment` takes the phase of every bin, undoes the phase of the impulse's offset from the frame centre, and turns what is left into a lag in input samples (an atom symmetric about its centre has no phase of its own) | impulse on a frame centre (sample 20 480, frame 40; the defaults at 22.05 kHz, 7 octaves): the largest lag of each octave is 0.0000 samples in all seven; the magnitudes are those of the definition within 0.9958 … 1.0044, and the whole run is within 2.97·10⁻³ of the excerpt's maximum. Impulse 3 samples after a centre (sample 9 475, frame 37; 5 octaves of 24 at 16 kHz, hop 256, sparsity 0): at most 0.0003 samples in any octave, magnitudes 0.9976 … 1.0000 of the definition, 6.82·10⁻⁴ of the excerpt. **pass** |
| Each frame stamped with the time of its centre | the 13 transform dumps of WP-521/522a (1 to 7 octaves, 16 … 48 kHz, hops 128 … 512, 50 … 341 frames), times and indices as the sink (`CollectingSink`, through `emit(to:)` and the offline runner) received them | every time within 4.4·10⁻¹⁶ s of `n · hop / fs` (2.2·10⁻¹⁶ s in 10 of them), the indices 0, 1, 2, … without a gap in all 13. **pass** |
| The start of the signal | the definition of `ref.py` takes the signal as zero before its first sample (CR-022 item 2), and frame 0 is centred on sample 0 | frame 0 and the frames after it are within the figures of `WP-522a-A.md` in every dump. **pass** |
| Latency: when a frame leaves | the 13 dumps: signal length n, hop, the latency L the sink's environment declares, frames out | in all 13 the frames out are exactly ⌊(n − L) / hop⌋ + 1, so frame k leaves once k · hop + L samples have arrived (L = 542 … 39 335; one octave to seven; γ = 0, 3.1, 4.45 and 5 Hz). **pass** |
| Latency: its value | by hand from §6.8 and the filters, for the defaults: the lowest octave is read at fs/64, where its longest atom is 542 samples at 22.05 kHz (1 180 at 48 kHz), and frame n is centred on its sample n · hop/64; the atom reaches 270 (589) samples of that rate beyond the centre sample, and the six decimators (53 taps, linear phase) delay that octave by 26 samples of each of their input rates, 26 · (1 + 2 + … + 32) = 1 638 input samples (the schedule's whole lag of 26 samples at depth 6, less its 26 priming samples, is the same 1 638) | 270 · 64 + 1 + 1 638 = 18 919 at 22.05 kHz and 589 · 64 + 1 + 1 638 = 39 335 at 48 kHz: the declared figures. The schedule and `MultirateSparseKernelStrategy.latency(of:…)` agree for all 8 geometries of `schedules.json` (also 542, 1 283, 1 775, 6 231, 6 311, 24 327), and so does the node's `latencyFrames` where one was made (18 919, `trap-T08.log`). The settling time, by the same reckoning the look-back of that frame, is 245 · 64 + 52 · 63 + 26 = 18 982 at 22.05 kHz, as declared. **pass** |
| Latency reported | `sink.environment.latency` of every dump, against L | equal in every dump (0.858005 s = 18 919 samples at 22.05 kHz; 0.819479 s = 39 335 at 48 kHz; 0.131479 s = 6 311 with γ = 4.45 Hz, the figures of CR-022 item 2). **pass** |
| The package's tests | `ConstantQScheduleTests/everyOctaveOfAFrameIsCentredOnTheSameSample(octaves:hop:)`, `everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples(filterLength:)`, `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore(…)`, `gammaIsTheLeverOnLatency()`; `ConstantQTests/afterAColdStartTheFramesAreThoseOfAFreshStream(gamma:)`, `whatCameBeforeNoLongerShowsOnceTheSettlingTimeHasPassed()`, in the runs of the flakiness record | pass in every run. They exercise the code: with the priming zeros removed (M4, `WP-519-A.md`) the first two fail (4 and 7 cases), and with the lag of the octaves left out of the schedule (M7, `WP-521-A.md`) the first fails in all 4 cases with 2 155 issues |

§6.8 says the latency is the lowest octave's "half-atom length": half of N₀ = 34 683 is 17 342 samples at 22.05 kHz, half of 75 499 is 37 750 at 48 kHz. What is declared is when that octave is complete: its half-atom as rounded at its own rate (17 281 and 37 697) and the 1 638 samples of the six decimators. CR-022 item 2 states this reading and its figure ("The latency is the moment the lowest octave completes … 39 335 samples at 48 kHz"), and the measurement agrees with it; with one octave (no decimator) the two readings coincide (542 = half of 1 084). A deviation that a change request describes accurately: B-8, not blocking.

## Lens N

- **Definition.** Independent: the alignment is read from the phases of the output against the impulse's known position, and the latency from the frame counts against the signal length, neither from the schedule's own numbers; the hand derivation above uses only §6.8 and the filter length.
- **Precision.** Integer arithmetic for lags and latencies (exact); time stamps in `Double` (within 4.4·10⁻¹⁶ s). Right: a lag is a whole number of samples of each octave's rate by construction (the priming samples), so alignment to the input sample is exact, and the measured residue (≤ 0.0003 samples) is the phase noise of `Float` coefficients.
- **Edge cases:**
  - *empty, length 1*: no frame and no trap (the first frame needs L samples).
  - *silence*: frames of zeros, stamped as any other (WP-521's edge probe, 81 frames).
  - *DC, Nyquist, full scale, NaN/±∞ samples*: do not apply to the time axis; their values are graded in `WP-521-A.md` and `WP-522a-A.md` (the frame counts and times of those runs are the same as for any signal of their length).
  - *one octave*: L = 542 = half the atom of 1 084 samples, no filter (`schedules.json`).
  - *odd offsets*: the impulse 3 samples after a centre, above; the hops 64 at 44.1 kHz (4 octaves) and 1 024 at 32 kHz (5 octaves) in the schedules.
  - *a reset*: two passes with a reset between them give the same frames and times (50 frames each).
  - *Int arguments of `latency(of:hop:…)`* (`VA_T08`, a process per trap): hop Int.min, −1, 0, 100 refused with the nearest legal hops; 64 gives 18 919; Int.max − 63 refused ("above the longest supported"); **Int.max traps (A-4)**.
  - *Double arguments*: `sparsity` ±greatestFiniteMagnitude, subnormal, ±0, NaN, ±∞: `latency(of:…)` returns 18 919 for every one of them, also those `makeNode` refuses (B-6).
- **ALG**: the row carries no ALG flag; no stability note belongs to it.
- **STG-1**: the package adds no step; the latency and settling time it computes are the ones `ConstantQ` declares (STG-1 item "latency and settling", graded with the step in `WP-521-A.md`: declared, and equal to what is measured here).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-9 | VIS-2 (brief, lesson 1) | `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQStrategy.swift:88` `MultirateSparseKernelStrategy.latency(of:hop:window:sparsity:)` | A public function with no documentation comment of its own. The requirement (`:16-26`) says "Control context … it should be arithmetic", but the conforming type does not say that its witnesses follow the requirements, and this witness is not arithmetic on its first call (it designs the half-band filter, `HalfBand.taps()`, as `schedule(of:hop:)` says at `:82-83`), so whether it allocates is exactly what a caller cannot tell. Scan: `VerifierA/out/doc-scan.txt` ("NO DOC COMMENT"). Resolve: a comment that states the context and whether it allocates (on its first call it does), or the sentence of CR-A1 on the type | blocking |
| A-4 | §9.3 | `ConstantQ/ConstantQSchedule.swift:108-112` (WP-519's code), reached through `latency(of:hop: Int.max…)` | Ends the process (`trap-T08.log`; `VA_Repro/r522b_latencyOfHopIntMaxTraps()`: "Crash: xctest"). One finding with WP-519, 521, 522a and 524; evidence and resolution in `WP-519-A.md` | blocking |

Backlog (non-blocking):

- B-6. `latency(of:hop:window:sparsity:)` ignores `sparsity` and `window`: it returns 18 919 for a sparsity of NaN, ±∞ or ±greatestFiniteMagnitude, which `makeNode` refuses (`trap-T08.log`). The requirement asks that the latency be the node's for "the same arguments"; for arguments that make no node there is none, and the step refuses them before it asks. A refusal, or a sentence that the latency does not depend on them, would close it.
- B-8. The latency is that of the lowest octave's completion, not §6.8's "half-atom length" (17 342 against 18 919 samples at 22.05 kHz): described accurately by CR-022 item 2, which is proposed and not yet decided; the owner's decision settles it.

## Change requests filed (FIX-4)

None for this package (CR-022 item 2 already covers B-8; the VIS-2 reading for protocol witnesses is CR-A1, in `WP-521-A.md`).
