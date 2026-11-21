# Verifier report — WP-501f, lens T

| Field | Value |
|---|---|
| Package | WP-501f — `WindowAnalysis`, part 3: main-lobe width, side-lobe level and fall-off, scalloping loss; the overlap-add tests for a hop |
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
| Reference figures for the stock windows within 0.1 dB and 0.05 bin | `WindowAnalysisTests/theFiguresOfTheStockWindowsEqualTheReference(name:)`, 24 cases of the `window_analysis` golden (8 stock windows × 64, 1 024, 4 096 samples): main lobe at −3 dB and null to null within 0.05 bin; peak side lobe, scalloping loss and side-lobe fall-off within 0.1 dB; the overlap-add verdicts at a quarter and a half frame against `check_NOLA` and `check_COLA`. Debug (`Scripts/xc.sh test-only ZTronDSPAnalysisTests/WindowAnalysisTests`, 4 runs) and Release (1 run) | pass |
| The overlap-add tests for a hop | `overlapAddForAHop()` (Hann at N/4: constant, A = B; at N: zero where frames meet, ripple 1; at hop 700: non-zero, not constant, B/A > 1.5; rectangular at N and at a hop above N) | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** The lines changed (gated mutations, `VerifierB/mutations.py`, `VerifierB/run-gates.sh`, one gate on per run):
  - `WindowAnalysis.swift:594`, the half-power width read where the power falls to a quarter (`m501f`): `theFiguresOfTheStockWindowsEqualTheReference` fails in 24 of 24 cases.
  - `WindowAnalysis.swift:304`, the threshold of `isConstantOverlapAdd` made 10⁶ times larger, 10⁻⁴ instead of 10⁻¹⁰ (`m501f2`): **`WindowAnalysisTests` passes, 14 of 14** (finding 1).
  - COV-3: `WindowAnalysis.swift` 100 % (397 of 397 lines).
  - Deterministic, no sleep. Negative paths: `whatCannotBeAnalysedIsATypedError` (a hop of 0 among them).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T: the threshold of the constant overlap-add verdict is not tested (not part of the row's acceptance statement) | `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift:304`, `:196`; `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift:61-62`, `:206-219` | The verifier's `VerifierB/cola_ripples.py` computes the ripple as the package does: of the 48 golden cases, 24 are at round-off (at most 9.3·10⁻¹⁶) and the other 24 at 9.8·10⁻⁴ or more (Kaiser β 8.6, 64 samples, hop 16, the smallest), so any threshold between them gives the same verdicts: with 10⁻⁴ (`VB_MUT=m501f2`, `VerifierB/run-gates.sh m501f2`) every test passes. Cases between the two: Gaussian σ 0.1 at hop N/8, 1.15·10⁻⁵; Kaiser β 14 at N/8, 4.75·10⁻⁶; Kaiser β 24 at N/8, 1.0·10⁻⁹. One of the first two, expected not constant, would pin the threshold. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
