# Verifier report — WP-438a, lens A

| Field | Value |
|---|---|
| Package | WP-438a — `Subsample(by:)` and `Upsample(by:)` stages |
| Lens | A — API, architecture, platform (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/26-verifier-b-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: see `VerifierB/README.md`)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs on `ztdsp-27-vm4bb`:

- Debug, the whole design target: 334 tests, passed in two runs.
- Release with the verifier's probes: 344 tests, passed.

| Check | How it was run | Result |
|---|---|---|
| ≡ the toolkit functions | `RateStageTests/subsampleAndUpsampleAreTheToolkitFunctions()`. Factors 1, 2, 3 and 7, block sizes 1, 64, 100 and 512, and phases 0, 1, M − 1, M + 1 and −1. The output equals `subsampled(_:by:phase:)` and `upsampled(_:by:)` bit for bit, and up then down by the same factor is the identity. | pass |
| The rates in the environment follow | The same test, at 48 kHz. `Subsample(by: 3)` gives 16 kHz; `Upsample(by: 4)` gives 192 kHz; `Upsample(by: 3)` then `Subsample(by: 2)` gives 72 kHz. Each gives the expected number of samples, and the two single stages report latency 0. A cutoff legal only behind the upsampler is rejected in front of it (`cutoff`). | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.12).**
    - `Subsample(by:phase:isActive:)` and `Upsample(by:isActive:)` (digest 513, 517).
    - The fluent twins have the same labels (digest 651–652).
    - The toolkit functions are `subsampled` and `upsampled` in the core (`ZTronDSPCore.txt:816, 818`).
    - Neither stage has a filter, as §6.12 says. A phase outside 0 … M − 1 is taken modulo M, as the toolkit function takes it.
  - **STG-1.**
    - Fluent modifier and `isActive:`: present.
    - The order matrix is current.
    - `DesignRateChangerAfterASpectrum` fails with its sentence.
    - Latency 0 and settling time 0: the kernels hold no filter state (`ztd_rate.c:252, 298`).
    - Allocation audits: `aThousandBlocksOfTheRateChangersAllocateNothing()` and `StockPipelineAuditTests`, in Debug and Release.
    - ACT-3: `aRateChangerThatIsSwitchedOffSuspendsWhatFollows()`. The factor is structure, not a continuous value (`parameters` is empty).
  - **Typed errors.** Factors 0, −2 and 4 097 are rejected (`factor`).
  - **VIS-2.** `Stages/RateStages.swift` has 29 public declarations, all documented with their threading context.
  - **Gates.** `Scripts/api-digest.sh --check`, `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | None | — |

## Change requests filed (FIX-4)

None by this verifier.
