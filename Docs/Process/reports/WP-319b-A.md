# Verifier report — WP-319b, lens R

| Field | Value |
|---|---|
| Package | WP-319b — Polling wake against an injected clock (§4.3); a thread of its own for an offline session |
| Lens | R (the first lens of the row: R, T) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Simulator `ztdsp-27-va` (iOS 27.0, arm64) on the host of §3. `ZTD_DEVICE=ztdsp-27-va Scripts/xc.sh test ZTronDSPCoreTests` four times in Debug (three runs: 325 of 325 passed; the first run failed one test, `AnalysisThreadTests.aRealTimePullSourceTakesAsLongAsItsSignal`, see WP-319b) and once with `ZTD_CONFIG=Release` (325 of 325 passed). `Scripts/lint-bans.sh`: clean. A "probe" is a test the verifier wrote in the checkout with the package's own test doubles (`TestStages.swift`, `EngineSupport.swift`); its body is given under the finding it supports.

| Check | How it was run | Result |
|---|---|---|
| Wake-ups every half I/O buffer and never under 1 ms | `AnalysisThreadTests.pollingComesRoundEveryHalfBlockAndNeverUnderAMillisecond` (injected `TestClock`; 512 and 4 096 frames: half a block; 64 frames at 48 kHz and 16 at 192 kHz: 1 ms; 20 turns each, within 10⁻¹² s), `aPacedPullSourceIsAskedOncePerBlockDuration` (one render per 10 ms; catches up after 35 ms) | Debug ×3 and Release ×1: passed |
| An offline session does not run on the analysis thread | `anOfflineSessionDoesNotRunOnTheAnalysisThread` (thread identifiers of a `.realTime` and an `.asFastAsPossible` generator, read in callbacks) | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**

- The poll interval is `max(1 ms, blockSize / sampleRate / 2)` (`SourceHub.swift:60-62`): half the engine's block, see finding 2.
- RT-2 on the loop: `turn()` (`RunnerThread.swift:172-193`) walks an immutable list, calls each hub once and notifies the control context between turns through a dispatch source, only when the attention word was set (CR-015 item 9); measured on the real thread, see WP-319a.
- The offline thread is created at `.utility` and runs free; it parks when its stream is over.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | Lens R / T: tests do not depend on the machine's load | `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift:136-146` | `aRealTimePullSourceTakesAsLongAsItsSignal` holds wall-clock time to 0.25 … 1.5 s. In the first full Debug run (325 tests in parallel, a second build running on the machine) it measured 2.18 s and failed the run; alone and in the next three full runs it passed (0.31 s). | non-blocking |
| 2 | §4.3: "polling the ring at half the I/O buffer duration" | `Sources/ZTronDSPCore/Engine/SourceHub.swift:58-62` | The interval is derived from the engine's block size, not from the I/O buffer of the source, which the three protocols of §4.4 do not carry. The two differ for a hardware source (M7). No change request says so. | non-blocking |

**Finding 1, to reproduce or resolve.** To resolve: assert on the injected clock (as `aPacedPullSourceIsAskedOncePerBlockDuration` does), or widen the upper bound and say why.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

Suggested (not filed, the verifier writes reports only): §4.3 names the I/O buffer duration as the base of the poll interval, and SRC-1 gives a source no way to state it. Either the interval is defined on the engine's block, or `PushSampleSource` gains the figure.
