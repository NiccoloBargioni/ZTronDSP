# Verifier report — WP-321a, lens A

| Field | Value |
|---|---|
| Package | WP-321a — `AnalysisNode`, the node schedule in the plan, `FeatureSink` |
| Lens | A — API, architecture, platform (the second lens of the row in §12) |
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
| Nodes run in declared order at their tap position | `ExecutionTests/nodesRunInDeclaredOrderAtTheirTapPosition()` (framer → magnitude → mean in a tap after a gain; values, indices and times of 99 frames at three sinks). A change that puts nodes at the head of their segment (`ExecutionPlan.swift:217`) is killed by it. | pass |
| Allocation-free | `ExecutionTests/aPlanWithKernelsNodesBranchesAndSinksRunsWithoutAllocating()` (1 000 blocks), `StockKernelTests/tenThousandBlocksOfALiveSessionAllocateNothing()`; Debug and Release. An allocation added to `NodeSlot.process` (`PlanStructures.swift:181`) is killed by both. | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Shapes per §5.11.1: `AnalysisNode` (`latencyFrames`, `settlingFrames`, `process(_:_:)`, `reset()`), `SampleProcessor` and `FeatureSink` (`associatedtype Domain`, `claim(axis:environment:) throws(DSPError)`, `write(_:)`, `release()`; `AnyObject, Sendable`) are exactly as printed. `FrameWriter` and `FrameView` are the types the specification names.
  - VIS-1: the three are `public protocol`s; the plan, its slots and the node schedule are `internal`; `FrameWriter`'s accessors are `@inlinable` with `@usableFromInline` internals. No `open` declaration, no public setter (lint part 4 clean).
  - EXT-1 / DEP-1: no processing stage in Core; the file imports nothing.
  - `Sendable` and threading: `AnalysisNode` is deliberately not `Sendable` (made on the control context, then owned by the analysis thread); `FeatureSink` is. The contract is written at each declaration (VIS-2).
  - Typed errors; no configuration object; no Combine, no `AnyView` (lint part 3 clean).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | A: EXT-3, the tools are public | `Sources/ZTronDSPCore/Nodes/AnalysisNode.swift:36-43, 68-79` | `FrameWriter` has no public initialiser and `FrameDelivery` is internal, so a node written outside the package cannot be driven in a unit test of its own; it can only be run inside a pipeline (`pipeline.process`). `ZTronDSPTesting` offers no harness for it either. | non-blocking |
| 2 | A: public surface against CR-015 item 11 | `Docs/Process/changes/CR-015.md`, `Docs/API/ZTronDSPCore.txt` | Item 11 lists eleven public additions "the specification implies but does not name". The committed digest holds 51 public types named neither in the specification nor in a change request; in this package's files: `SinkDescription`; next to it `AnalysisStep`, `ScopeChange`, `CustomKernel`, `CustomProcessor`. Either the list is meant as examples (then it should say so) or it is incomplete. | non-blocking |

## Notes

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `AnalysisNode.swift` 84.8 % (50 of 59 lines) — **below 97.5 %**, `FeatureSink.swift` 98.6 % (72 of 73 lines), `ExecutionPlan.swift` 87.9 % (408 of 464 lines) — **below 97.5 %**.

## Change requests filed (FIX-4)

None by this verifier.
