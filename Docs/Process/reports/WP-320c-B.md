# Verifier report — WP-320c, lens R

| Field | Value |
|---|---|
| Package | WP-320c — Source hub: several attachments on one source (ATT-6) |
| Lens | R — real-time safety and performance (the second lens of the row in §12) |
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
| Two pipelines on one source see identical blocks | `EngineTests/twoPipelinesOnOneSourceSeeTheSameBlocks()`; one line of the hub changed so that only the first attachment is ever run | test passes — and still passes with the change (finding 1). Verifier's `VBScratchTests/vb320c_twoAttachmentsOnOneSourceSeeIdenticalBlocks` (three attachments on a hand-driven engine, a fourth joining later): samples, indices and times equal: the product is right |
| The source starts once and stops with the last attachment | `EngineTests/aSourceStartsOnceAndStopsWithTheLastAttachment()`; changes at `EngineCore.swift:446` and `:526` are killed by it | pass |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - RT-2: the hub's turn (`HubRunner.turn`, `run`) reads the ring, clears non-finite samples and calls each session's runner in a `while` loop over an immutable array handed over whole; no allocation, no lock, no logging, no `await`. Lint part 2 clean on `Engine/Run/`.
  - The allocation audit: the suite audits the hub's turn with one session (`StockKernelTests/tenThousandBlocksOfALiveSessionAllocateNothing`, 10⁴ blocks). With several sessions it is audited only by the verifier's `vb320c_…` (two sessions, 1 000 blocks: 0 allocations) and, on the engine's own thread, `vb319_theAnalysisThreadInSteadyState` (60 blocks: 0).
  - No hidden copies: every session receives the same `FrameView` of the hub's one input block; a kernel run writes into its own buffer, never into the input.
  - RT-3 / RT-4: a change of the set of sessions is a new immutable `HubStage` through the atomic slot; the control context waits for the thread to take it and frees the old one.
  - A benchmark is recorded: none for the hub. Verifier's indicative figures, Release, simulator on a busy host: see Notes.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | Acceptance check exercises the code ("Two pipelines on one source see identical blocks") | `Tests/ZTronDSPCoreTests/EngineTests.swift:62-77`; `Sources/ZTronDSPCore/Engine/Run/HubRunner.swift:178` | With `while index < stage.sessions.count` changed to run the first session only, all 325 tests pass: the second attachment of the test receives nothing and the test accepts it. Its source is asked as fast as possible and delivers its 6 000 frames in the hub's first turn (64 blocks per turn); the second `start()` takes effect at the next turn, when the stream is over. The assertions on the second sink then hold for an empty result: `second.samples == signal.suffix(0)…`, and `0 % 100 == 6 000 % 100`. Reproduce: make the change, run `ZTD_DEVICE=ztdsp-27-vb Scripts/xc.sh test ZTronDSPCoreTests`. Resolve: attach both to a source the test feeds by hand (the `Rig`) and compare samples, indices and times of both sinks; `vb320c_…` does and fails for the change. | blocking |
| 2 | R: the allocation audit exists | `Tests/ZTronDSPCoreTests/StockKernelTests.swift:241-271` | No audit runs the hub with more than one session. The verifier's passes. | non-blocking |
| 3 | R: a benchmark is recorded | — | No benchmark of the hub's turn; no baseline is committed and `Scripts/benchmarks.sh` does not exist (gate 8 is skipped). | non-blocking |

## Notes

Indicative timings by the verifier (`VBScratchTests2/vb_timings`; Release build, simulator, a host whose load average was above 40; minima of repeated loops; not a recorded benchmark): one turn of the hub for a block of 512 frames with one session of one gain 470 ns, with four such sessions 1 104 ns.

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `SourceHub.swift` 100.0 % (24 of 24 lines), `HubRunner.swift` 98.5 % (136 of 138 lines).

## Change requests filed (FIX-4)

None by this verifier.
