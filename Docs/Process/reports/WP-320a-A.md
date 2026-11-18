# Verifier report — WP-320a, lens A

| Field | Value |
|---|---|
| Package | WP-320a — `PipelineSession`: the state table of §4.5, `SessionEvent` |
| Lens | A (the first lens of the row: A, T) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `blocking` |

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
| Every cell of the table, repeated calls included | `SessionStateTests` (11 tests), `SessionUpdateTests.aFormatChangeIsSurvived`, `anIdleSessionTakesANewTopologyAtOnce`; probes for the cells without a test | Debug ×3 and Release ×1: passed for the cells that have a test; the cells without one behave as the table says (probes, Debug and Release) |
| `SessionEvent` | `SessionStateTests.idle`, `everyListenerHasAStreamOfItsOwn`; `SourceTests.nonFiniteSamplesBecomeZeroAndAreCounted`, `anOverrunIsReported`; `FeedTests.memoryPressureTrimsOnlyFeedsThatDeclaredASmallerMinimum` | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Names and shapes: `PipelineSession` is `final`, `Sendable`, `Identifiable`; `environment`, `state`, `events`, `start() throws(DSPError)`, `stop()`, the two `update`s, `@MainActor syncBindings()` and `detach()` are as §4.5 writes them; `SessionState` and `SessionEvent` have the cases of §4.5 (both also `Hashable`). CR-015 items 1, 2 and 7 describe what the code does (`environment` with the main line's latency; `start()` from `finished` / `failed` prepares asynchronously, the outcome arrives as a state; a released session detaches itself).
- §9.2: control state is touched on the engine's serial control queue; what any thread may read (`state`, `environment`, the event listeners) is behind small locks of its own (`SessionCore.swift:63-71`). The sentence of §9.2 that the lock is "only ever taken on the control context" does not hold to the letter for those; they are never taken on the analysis thread.
- `start()`, `stop()` and `detach()` wait for the control queue (`ControlContext.sync`), so a caller on the main thread waits for as long as a plan takes to compile or a hand-over to settle; the type's documentation says so.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | Acceptance of the row: every cell of the table has a check | `Tests/ZTronDSPCoreTests/SessionStateTests.swift`, `SessionUpdateTests.swift` | No test visits: `update(_:)` while `interrupted`; `update(_:)` while `finished` or `failed`; `detach()` while `interrupted` (and no assertion on the state after `detach()` while `running`); source `.formatChanged` while `idle` and while `interrupted`. The header of the suite says every cell is covered. | blocking |
| 2 | §4.5 and the documentation of `SampleSource.prepare()` ("again before a session that finished … is started anew") | `Sources/ZTronDSPCore/Engine/EngineCore.swift:393-405, 445-459` | A session that finished and is stopped, then started, delivers nothing: `finished → stop() → idle → start()` starts the source without preparing it, a `BufferSource` is at its end, and the session is `finished` again at once with 0 of 1 000 samples (probe, Debug and Release). The same holds for a second attachment that is started from `idle` on a source another attachment ran to its end. `finished → start()` replays, as the table says. Each cell is as the table writes it; the outcome is a hole the table leaves. | non-blocking |
| 3 | VIS-2 | `Sources/ZTronDSPCore/Engine/DSPEngine.swift:99, 105` | `PipelineSession.id` and `.state` have no documentation comment (the type's comment gives the threading contract of every member). | non-blocking |
| 4 | Concurrency of `events` | `Sources/ZTronDSPCore/Engine/SessionCore.swift:126-138, 164-171` | A stream obtained between `isOver.get()` and the registration of its continuation, while `finishEvents` runs, is never finished. Probe: 400 detachments racing `session.events`, no stream left open; read as possible, not observed. | non-blocking |

**Finding 1, to reproduce or resolve.** Cells of the table of §4.5 that no test of the package visits, and the probes that visited them (all passed, Debug and
Release; `source` is a `ManualPushSource`, `sink` a `CollectingSink<Samples>`, `block` 64 samples of 0.5):

- `update(_:)` while `interrupted`: start, `source.send(.interrupted)`, `update(Pipeline { TestGain(2) }.emit(to: sink))`;
  the state stays `interrupted`, `core.runner.installedGeneration == 2`; after `.resumed` and one block every sample is 1.
- `update(_:)` while `finished` and while `failed`: the same after `.ended` or `.failed(error)`; the state stays, the plan is
  replaced, `start()` then runs it.
- `detach()` while `interrupted` (and while `running`, asserted): the state is `detached`, `source.stops == 1`.
- Source `.formatChanged` while `idle` and while `interrupted`: `source.changeFormat(to:)`; the environment follows, the state
  stays, `.replanned(.formatChanged)` is reported, and the plan compiled for the new format runs after `start()` or `.resumed`.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

Suggested: §4.5 does not say what `start()` from `idle` does when the source's stream has ended. Proposed reading: the hub remembers that its stream ended and prepares the source again at the next start, whatever the state of the session that asks.
