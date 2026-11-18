# Verifier report — WP-320c, lens A

| Field | Value |
|---|---|
| Package | WP-320c — Source hub: several attachments on one source (ATT-6) |
| Lens | A (the first lens of the row: A, R) |
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
| Two pipelines on one source see identical blocks | `EngineTests.twoPipelinesOnOneSourceSeeTheSameBlocks` (irregular batches; the second attachment joins at a block boundary and sees the same samples), `ProcessedSourceTests.severalPipelinesShareOneProcessedSource` | Debug ×3 and Release ×1: passed |
| The source starts once and stops with the last attachment | `EngineTests.aSourceStartsOnceAndStopsWithTheLastAttachment` (prepares 1, connects 1, starts 1, stops with the last; again after a restart); mutation: the guard `guard !hub.isStarted` removed from `startSource` | Debug ×3 and Release ×1: passed; the mutation fails the test at `EngineTests.swift:89, 95` |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Architecture: one `SourceHub` per source and engine, control side only; its analysis half is `HubRunner`, handed immutable `HubStage`s through an atomic slot (RT-4). The hub is internal, registered in `unchecked-sendable.md` with its contract. Concurrent attachments share one preparation (`EngineCore.swift:125-147`).
- ATT-2: under `Engine/` there is no cast to a source type; the hub asks `SourceAdapter` (push, pull) and `SourceAdapter.processed(_:)` (derived).
- CR-015 item 8 (one engine per source) is what `SourceRegistry` does (`ControlContext.swift:55-75`); `severalPipelinesShareOneProcessedSource` shows the source free for another engine after the last detachment.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ATT-6 and §4.5: a start after the stream has ended | `Sources/ZTronDSPCore/Engine/EngineCore.swift:445-459` | An attachment started from `idle` on a source whose stream another attachment ran to its end receives nothing and finishes at once (probe: 0 of 1 000 samples); see WP-320a, finding 2. | non-blocking |
| 2 | RT-3 on the hub's hand-over (the other lens of this package) | `Sources/ZTronDSPCore/Engine/Run/HubRunner.swift:97-108` | The stage a hub replaces can be freed on the analysis thread; see WP-319a, finding 1. | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
