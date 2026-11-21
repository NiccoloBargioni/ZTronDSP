# Verifier report — WP-501d, lens T

| Field | Value |
|---|---|
| Package | WP-501d — `WindowAnalysis`, part 1: gains, noise bandwidth, symmetry, edge values, the tail limit (WIN-4) |
| Lens | T — tests and coverage (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/30-verifier-b-m5a.md` of the hand-over)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: Debug and Release runs, the gated mutations, llvm-cov through `.build/covtools`)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| Reference values for the stock windows | `WindowAnalysisTests/theFiguresOfTheStockWindowsEqualTheReference(name:)`: 24 cases of the `window_analysis` golden (rectangular, Hann, Hamming, Blackman, Blackman–Harris, flat-top, Kaiser β 8.6, Gaussian σ 0.15; 64, 1 024, 4 096 samples): peak, coherent gain, noise gain, noise bandwidth and both normalisation factors within 10⁻¹² relative; `shapeAndEdgesOfTheStockWindows()` (symmetry, sign, edge values). Debug (`Scripts/xc.sh test-only ZTronDSPAnalysisTests/WindowAnalysisTests`, 4 runs) and Release (1 run) | pass |
| The right verdict for closures that do not decay, diverge, or return NaN far out | `theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven()`: a constant is `.value(1)` and not integrable on the line; t² + 1, ∞ beyond 1 000, \|t\|, √\|t\|, ln \|t\| are `.unbounded`; NaN beyond 100, sin t outside the frame, 0 on one side and 1 on the other are `.undefined`; a Gaussian is `.zero`; 1 + 1/\|t\| tends to 1; 1/\|t\| is square- but not absolutely integrable. `withoutItsFunctionACustomWindowIsNotExaminedOutsideTheFrame()` | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** Both checks fail when the implementation is broken; the lines changed (gated mutations, `VerifierB/mutations.py`, `VerifierB/run-gates.sh`, one gate on per run):
  - `WindowAnalysis.swift:353`, a growing tail reported as `.undefined` instead of `.unbounded` (`m501d`): `theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven` fails (4 issues: t² + 1 and the three slow growths).
  - `WindowAnalysis.swift:224`, the coherent gain divided by N + 1 (`m501d2`): `theFiguresOfTheStockWindowsEqualTheReference` fails in 24 of 24 cases.
  - COV-3: `WindowAnalysis.swift` 100 % (397 of 397 lines, shared with WP-501e and WP-501f).
  - Deterministic: no random input, no sleep; the background test checks `BackgroundWork.isCurrent` inside the closure. Negative paths: `whatCannotBeAnalysedIsATypedError` (a frame of 0 and of 2²³, a hop of 0, a zero and a NaN window, Kaiser β −1) and cancellation (`theAnalysisRunsInTheBackgroundAndCanBeCancelled`, `DSPError.cancelled`).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding through this lens. | — |

## Change requests filed (FIX-4)

None by this verifier.
