# Verifier report — WP-531b, lens R

| Field | Value |
|---|---|
| Package | WP-531b — Centred mode with look-ahead; latency |
| Lens | R (real-time safety and performance): the second lens of the package's row in §12 |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced again by the verifier in that checkout)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs, all on the simulator `ztdsp-27-vm5bb` through `Scripts/xc.sh` (commands and outputs in `VerifierB/README.md`): (1) the tree as received, Debug, `ZTronDSPAnalysisTests` and `ZTronDSPTestingTests`: 420 tests in 41 suites and 52 in 7, pass; (2) the same in Release: pass; (3) the instrumented build for COV-3: pass; (4) the 17 suites of the batch, each test three times (`-test-iterations 3`), Debug, on the restored tree: no failure; (5) the mutation build (`VerifierB/mutants.diff`): the control passes, every row killed. Gates (api-digest, dependency graph, compile fixtures, golden, ledger, lint, order matrix): all pass. Rule 6 probes in `VerifierB/Probes/VerifierBTrapProbes.swift`, each in a process of its own.

| Check | How it was run | Result |
|---|---|---|
| ≡ offline | `HarmonicPercussiveTests.theCentredStepEqualsTheOfflineSeparation(caseIndex:)`: the centred step on music (hop 512, kernels 31 and 31), speech (hop 256, 17 and 31) and music (hop 512, 5 and 3), every component, frame by frame against the offline separation of the whole spectrogram; the stream ends (k − 1)/2 frames early, waiting for the look-ahead of its last frames | Pass in every run; 71, 77 and 84 frames of 513 bins equal the offline separation bit for bit, the left edge included |
| Latency equals the look-ahead | `theLookAheadIsLatencyAndFramesKeepTheirTimes`: a time kernel of 17, centred, at a hop of 256 and 48 kHz, declares 8 · 256 / 48 000 s and gives 8 frames fewer, each with the time of the uncentred frame it describes, to the bit; `lookAhead(timeKernel: 31, alignment: .centered)` is 15; the node's `latencyFrames` and `settlingFrames` are 8 | Pass in every run |
| The lead-in on a complex spectrum, the latency through `HPSS`, the cold start, the GPU side | `HPSSTests.theLatencyIsOneFrameLessAHopPlusTheLookAhead` (centred: an impulse at sample 5 000 comes out at 5 000 + 768 + 8 · 256, value 1 within 10⁻⁵, nothing elsewhere above 10⁻⁵), `aColdStartRefillsTheHistoryOfTheMedian` (centred, the second pass waits for its look-ahead again: 2 × (frames − 8) frames), `OfflineSeparationTests.theOfflineSeparationOnTheGPUEqualsTheCentredStream` | Pass in every run |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - RT-2 (read: the centred path of `HarmonicPercussiveNode.process`, `Nodes/HarmonicPercussiveNode.swift:151-185`): the slot of the ring by wrapping arithmetic (`:155-156`); during the look-ahead after a start two `memset` and an `emit` stamped `input.time − leadIn` on a complex spectrum, nothing on magnitudes (`:161-168`); then the frequency median, the masks and the product of the centre slot, the oldest of the ring (`:171-185`), emitted with that frame's own time. No allocation, lock, log or `await`.
  - The allocation audit exists and passes: `HarmonicPercussiveTests.theNodeRunsWithoutAllocating` (a centred percussive step on magnitudes, kernels 17 and 17; a centred hard percussive step on the complex spectrum, kernels 5 and 5) and `HPSSTests.theRecipeRunsWithoutAllocating` (a centred hard residual recipe; a centred recipe with a bound switch through six rounds), Debug and Release. It would fail: a `malloc`/`free` planted on the centred path after the lead-in (after `:170`, taken only when `lookAhead > 0`, mutant 5312) makes both fail; restored, `diff -r` clean.
  - RT-3, RT-5: the ring holds `lookAhead + 1` frames (`:122-126`; 128 frames of the bins for the largest time kernel, 255), with their times, made in `init` when the plan is compiled; `leadIn` is computed there (`:118`). RT-6: no recursive state.
  - RT-7, layer 2: nothing to annotate (vDSP, `memcpy`, `memset`, existentials; E-05).
  - Latency (REAL-5): the step declares `ahead / featureRate` (`Steps/HarmonicPercussive.swift:167`), the node `latencyFrames = lookAhead` and `settlingFrames = timeKernel − 1 − lookAhead` (`:130-132`, `Steps/HarmonicPercussive.swift:170`). The latency of `HPSS` that builds on it (frame − hop + look-ahead · hop) is CR-023 item 5 and WP-532's check.
  - Complexity: that of WP-531a, plus O(bins) of lead-in per frame during the first `lookAhead` frames. A benchmark is recorded: none for this package (backlog BL-5).
  - Rule 6: `t531TimeKernel` and `t531FrequencyKernel` run centred too: Int.max, Int.min, 0, −1, 2 and 257 refused; no trap. The centred step shares the lowering of WP-531a, so the narrowing of the margins and of the floor (finding 2 of `WP-531a-B.md`) applies to it as well; it is filed there once, and its resolution resolves it here.
  - VIS-2: the package declares no public symbol of its own (`alignment:` is a parameter of the step of WP-531a; `FrameAlignment` is the core's).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding of this package's own. It inherits finding 2 of `WP-531a-B.md` through the shared lowering (`Steps/HarmonicPercussive.swift:162`) | — |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
