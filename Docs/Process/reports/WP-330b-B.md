# Verifier report — WP-330b, lens N

| Field | Value |
|---|---|
| Package | WP-330b — Activation at run time: bypass or suspension by stage kind, for kernels and nodes; cold resume (ACT-3, ACT-10) |
| Lens | N — numerical correctness (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (the task statement of the integrator; no separate brief file exists for the package)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: tests, lint, compile fixtures; coverage as stated below)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| A suspended branch runs no kernel and no node (probe) | `BindingTests/aSuspendedBranchRunsNoNodeAndStartsColdWhenItResumes()`, `aBoundStageThatChangesTheDomainSuspendsWhatFollowsIt()` (nodes); verifier's `vb330b_aSuspendedBranchRunsNoKernel` (a counting processor and an FIR in a switched tap) | pass |
| Flipping a binding compiles nothing | `BindingTests/aWriteOffTheMainThreadIsSeenBySyncBindings()` (generation 1 after the fade), `RegionSwitchTests` | pass |
| No stale frame after a resume | `BindingTests/aSuspendedBranchRunsNoNodeAndStartsColdWhenItResumes()` (one tap, its own framer); verifier's `vb330b_aSuspendedBranchRunsNoKernel` (FIR state), `vb330b_aBoundRateChangerOnTheMainLineSuspendsAndResumesCold` (phase of a subsampler), and `vb330b_sharedFramingStartsColdWhenItsLastConsumerResumes` (two taps, one shared framer) | pass for a branch with a framer of its own, for kernels and for a gate; **fail** when the framing is shared (finding 1) |
| Bypass with latency, fades | `StockKernelTests/aSwitchedFilterWithLatencyKeepsTheSignalAligned()`, `RegionSwitchTests` (4 tests); verifier's `vb330b_theFadeIsNeverShorterThanOneBlock` (block of 1 024 frames: 1 023 frames differ from both signals, CLICK-1 ratio 1.0) | pass |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - Bypass: a switched stage that keeps domain and rate gives the unprocessed signal delayed by the stage's latency, exactly (bit-equal comparisons in the suite; a pure delay under a switch gives the delayed signal throughout in the verifier's `vb339_…`).
  - Fades: 10 ms and never shorter than one block; the weight is computed from the frame's position, not accumulated; CLICK-1 holds off and on (ratios ≤ 1.5 measured by the suite; 1.0 at a block of 1 024 frames).
  - Cold resume: the state after a resume equals the state at session start for a tap with its own steps, for kernels in a tap, for everything behind a gate, and for a faded region. It does not for a framing step shared by several taps (finding 1).
  - Edge cases: a switch that turns round inside a fade and during pre-roll (suite); a stage that starts bypassed (suite); a rate changer that resumes at an odd phase (verifier).
  - No tolerance was loosened: the comparisons are exact except where a filter's own round-off is the floor (−100 dB, as registered).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ACT-10: "A branch that resumes starts as it does at session start … No stale frame is emitted" (acceptance: "no stale frame after a resume") | `Sources/ZTronDSPCore/Engine/Run/PlanRunner.swift:140-145` (`setSwitch`, `.branch`: resets the branch's own segment only); `Engine/Run/PlanStructures.swift:411-423` (`refreshLiveness` brings the shared segment back without a reset) | Two taps with equal framing share one framer (F5). When both are switched off the shared framer stops (ACT-9). When one is switched on again, only that tap's own remainder is reset; the shared framer goes on from the history it held when it stopped. `Pipeline().tap(isActive: a) { framer(256, 64) → magnitude → sink A }.tap(isActive: b) { framer(256, 64) → magnitude → sink B }`, blocks of 64: 640 samples (7 frames each), both off, 640 samples (no frame, framer idle), `a` on, 640 samples: sink A receives 10 frames where a cold start gives 7, and the first of them holds 192 samples from before the suspension; the framer was reset once in the whole run, at session start. The committed test of ACT-9 (`sharedFramingRunsOnlyWhileAConsumerNeedsIt`) uses a hop equal to the frame, where warm and cold give the same count, and does not compare contents. Reproduce: `VBScratchTests/vb330b_sharedFramingStartsColdWhenItsLastConsumerResumes` (committed test stages only). Resolve: when a shared segment goes from not live to live, reset its steps before it runs. | blocking |

## Notes

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `PlanRunner.swift` 91.8 % (180 of 196 lines) — **below 97.5 %**, `PlanStructures.swift` 92.9 % (222 of 239 lines) — **below 97.5 %**.

## Change requests filed (FIX-4)

None by this verifier.
