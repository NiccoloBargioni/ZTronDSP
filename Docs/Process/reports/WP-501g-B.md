# Verifier report — WP-501g, lens T

| Field | Value |
|---|---|
| Package | WP-501g — Window diagnostics at attach: `.logged()`; MATLAB export of the analysis |
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
| The report is logged once per attachment when asked and never otherwise | `WindowAnalysisTests/aLoggedWindowIsReportedOncePerAttachmentAndNeverOtherwise()`: what `WindowDiagnostics.logAttachment` writes is heard through the task-local `WindowDiagnostics.$recorder` beside the `os.Logger` lines (`WindowDiagnostics.swift:20-22`). An unlogged window: nothing; `.hann.logged()`: one report of 18 lines; two taps sharing one logged framing step (F5): one; two different logged windows beside an unlogged twin: two. Debug (4 runs), Release (1 run) | pass |
| Golden script | `ExportTests/aWindowAnalysisIsTheWindowAndItsSpectrumWithMarkers()`: the script of a Hann analysis (64 samples, hop 16) against `window-analysis` of `Tests/Golden/generators/matlab_scripts.py`, statement by statement, numbers within 10⁻⁹; 33 lines; equal input gives equal text (MAT-4); an undefined figure written `NaN` (MAT-3). `Scripts/golden.sh --check` | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** Both checks fail when the implementation is broken; the lines changed (gated mutations, `VerifierB/mutations.py`, `VerifierB/run-gates.sh`, one gate on per run):
  - `Steps/STFT.swift:116`, the analysis logged although the window is not `.logged()` (`m501g`): the logging test fails (2 issues: the unlogged pipeline at `:266`, the unlogged twin at `:286`).
  - The same line, the report logged twice per attachment (`m501g3`): fails (3 issues, at `:269`, `:279`, `:286`).
  - `Windows/WindowAnalysisExport.swift:39`, the x label `"samples"` instead of `"sample"` (`m501g2`): `aWindowAnalysisIsTheWindowAndItsSpectrumWithMarkers` fails (1 issue).
  - COV-3: `WindowDiagnostics.swift` 100 % (47 of 47 lines), `WindowAnalysisExport.swift` 100 % (44 of 44).
  - Deterministic: the hook is task-local, so parallel tests do not hear each other; no sleep. The logging runs where the node is made, `ExecutionPlan.swift:458`, on the control context.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding through this lens. | — |

## Change requests filed (FIX-4)

None by this verifier.
