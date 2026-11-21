# Verifier report — WP-501e, lens T

| Field | Value |
|---|---|
| Package | WP-501e — `WindowAnalysis`, part 2: continuity, smoothness, integrability, by grid refinement (WIN-6) |
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
| Smoothness 0 for rectangular, 1 for triangular, 2 for Hann | `WindowAnalysisTests/smoothnessIsTheOrderOfTheLowestDerivativeThatJumps(frame:)` for frames 16, 64, 1 024, 2 048, 16 384 (also Blackman 2, Hamming 0 with jumps of 0.08, the predicted fall-off 6·(s + 1) dB per octave); `higherOrdersAreToldApart()` (sin³ 3, sin⁴ 4, a smooth bump 4); `aKinkIsNotAJump()`. Debug (`Scripts/xc.sh test-only ZTronDSPAnalysisTests/WindowAnalysisTests`, 4 runs) and Release (1 run) | pass |
| A closure with an interior jump is located within one sample | `anInteriorJumpIsLocatedWithinOneSample(frame:position:)` for (64, 0.3), (1 024, 0.3), (1 024, 0.7183), (4 096, 0.123456), (16 384, 0.6): one interior jump, its size within 10⁻⁹, the edge jumps beside it | pass; the bound is one sample up to 4 096 samples and 2⁻¹² of the frame above (finding 1) |
| Integrability (the row's third property) | `integrabilityOnTheFrame()` (1/\|t − ⅓\| neither, its square root absolutely but not square integrable) | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** Both checks fail when the implementation is broken; the lines changed (gated mutations, `VerifierB/mutations.py`, `VerifierB/run-gates.sh`, one gate on per run):
  - `WindowAnalysis.swift:260`, the smoothness one order higher than the lowest derivative that jumps (`m501e`): `smoothnessIsTheOrderOfTheLowestDerivativeThatJumps` fails for 5 of 5 frames (25 issues), and so do `higherOrdersAreToldApart`, `aKinkIsNotAJump`, `aReportIsAValue`, the background test and the logging test.
  - `WindowAnalysis.swift:458`, a jump placed at the centre of its window of change, without the search for the steepest step (`m501e2`): `anInteriorJumpIsLocatedWithinOneSample` fails for (4 096, 0.123456) and (16 384, 0.6), and the edge of the rectangular window is no longer at 1 (5 of 5 frames).
  - COV-3: `WindowAnalysis.swift` 100 % (397 of 397 lines).
  - Deterministic, no sleep, no random input. Negative paths: `whatCannotBeAnalysedIsATypedError`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T, for the integrator: the acceptance's "within one sample" and WIN-6 do not meet above 8 192 samples | `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift:412-428`, `:471-486`; `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift:178` | By the code, the grids are 2¹⁰, 2¹¹ and 2¹² points whatever the frame (WIN-6: "the step is never below 2⁻¹² of the frame"), and a jump is placed in the middle of the steepest step of the finest grid, so within 2⁻¹³ of the frame: one sample up to 8 192 samples, two at 16 384. The test bounds the position by `1 / min(frame, 4 096)`, four samples at 16 384. The reading follows WIN-6 and is consistent, but no change request records that the acceptance holds per grid step above 4 096 samples. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
