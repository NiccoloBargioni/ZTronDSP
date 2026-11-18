# Verifier report — WP-321b, lens R

| Field | Value |
|---|---|
| Package | WP-321b — `FeatureStream` (a bounded `AsyncSequence`) and `FeatureCallback` |
| Lens | R — real-time safety and performance (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (the task statement of the integrator; no separate brief file exists for the package)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: tests, lint, compile fixtures; coverage as stated below)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The oldest frames are dropped and counted when the consumer lags | `FeedTests/aStreamDropsTheOldestAndCountsThemWhenItsConsumerLags()` (capacity 4, 10 frames: 6, 7, 8, 9 delivered, 6 counted) | pass |
| No unbounded growth | the same test (100 000 writes to a consumer that never comes; 1 000 writes inside `expectNoAllocations`); `StockKernelTests/tenThousandBlocks…` holds a stream of capacity 8. An allocation added to `FeatureStream.write` (`FeatureStream.swift:124`) is killed by both. | pass |
| No Combine | `Scripts/lint-bans.sh` (part 3) | clean |
| Delivery, whole frames, cancellation | `aStreamDeliversEveryFrameToAConsumerThatKeepsUp`, `aStreamKeepsVectorsAndComplexFramesWhole`, `aCancelledConsumerStopsWaiting`, `aCallbackRunsOnTheThreadThatRunsThePlan` | pass |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - RT-2: `FeatureStream.write` copies the frame into storage allocated at `claim`, with two atomic counters around the copy and one atomic store to ask for attention; no allocation, no lock, no wake-up. The consumer's lock is never taken by the writer. `FeatureCallback.write` is one closure call.
  - The allocation audit exists and passes for scalar frames (suite). The verifier added real, complex and sample frames (`vb321b_writingAStreamOfVectorsAllocatesNothing`, 1 000 writes each: 0) and audited the analysis thread itself while a stream made it ask for the control context on every block (`vb319_theAnalysisThreadInSteadyState`, 60 blocks of a real-time session: 0 allocations, 0 deallocations).
  - Waking the consumer: the analysis thread signals a dispatch source between turns (CR-015 item 9); `DispatchSource.add(data:)` made no allocation in 1 000 calls (`vb321b_wakingTheControlContextAllocatesNothing`). It is a system call per turn in which a stream received a frame, as the change request says.
  - RT-4: frames cross through pre-allocated storage guarded by a begin / complete counter pair; a slot overwritten while it was copied is dropped and counted.
  - No hidden copies: one copy per frame into the ring (§5.2: "a stream copies it"), one into the `FeatureFrame` the consumer keeps.
  - A benchmark is recorded: none. Indicative: see Notes.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | R: robustness of the consumer | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:189-198` | A second task that iterates the same stream is resumed at once whenever another task already waits (`reader.waiter != nil` → `resumeNow`), finds nothing and asks again: it spins on a thread of the cooperative pool. The documentation says one task iterates at a time; nothing enforces it or fails loudly. | non-blocking |
| 2 | R: a benchmark is recorded | — | No benchmark of a stream write; no committed baseline. | non-blocking |
| 3 | R: the allocation audit | `Tests/ZTronDSPCoreTests/FeedTests.swift:308-314` | The suite's audit writes scalar frames only; vectors, complex frames and blocks of samples take other branches of `write`. The verifier's audit of those passes. | non-blocking |

## Notes

Indicative timings by the verifier (`VBScratchTests2/vb_timings`; Release build, simulator, a host whose load average was above 40; minima of repeated loops; not a recorded benchmark): `FeatureStream<Samples>.write` of a block of 512 frames 33 ns; `FeatureStream<Scalar>.write` 8 ns.

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `FeatureStream.swift` 93.0 % (267 of 287 lines) — **below 97.5 %**, `FeatureCallback.swift` 100.0 % (8 of 8 lines), `FeatureFrame.swift` 46.0 % (17 of 37 lines) — **below 97.5 %**.

## Change requests filed (FIX-4)

None by this verifier.
