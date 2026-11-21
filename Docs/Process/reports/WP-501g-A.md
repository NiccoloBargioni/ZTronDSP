# Verifier report — WP-501g, lens A

| Field | Value |
|---|---|
| Package | WP-501g — Window diagnostics at attach: `.logged()`; MATLAB export of the analysis |
| Lens | A (the first lens of the row: A, T) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs, gates, probes and references are as in `WP-501a-A.md`:

- simulator `ztdsp-27-vm5aa`;
- 211 of 211 passed in each of four Debug runs and one Release run;
- every gate green.

The reports are heard through the package's task-local recorder (`WindowDiagnostics.$recorder`). The lines also appear in the log under the category `window` (`.build/vlogs/probe-run4.log`).

| Check | How it was run | Result |
|---|---|---|
| The report is logged once per attachment when asked | `WindowAnalysisTests.aLoggedWindowIsReportedOncePerAttachmentAndNeverOtherwise`: `Spectrogram`, `MelSpectrogram` and `STFT` taps; one report of 18 lines; one report for a framing step that two taps share. Probe `aLoggedWindowIsReportedOncePerAttachmentAndNeverOtherwise`: the same pipeline attached twice gives 2 reports of 18 lines | passed for the framing steps |
| … also when the logged window is the synthesis window | Probe `findingALoggedWindowGivenToAnInverseSTFTIsNeverReported`. Control: `STFT(frame: 1_024, hop: 256, window: .hann.logged()); InverseSTFT()` gives 1 report. Finding: `STFT(frame: 1_024, hop: 256); InverseSTFT(window: .hann.logged())`, attached and run | **failed (A-6): 0 reports** |
| Never otherwise | The package test (a `Spectrogram` with `.hann`). The probe: `STFT(…); InverseSTFT()` gives 0 reports | passed |
| Golden script | `ExportTests` compare `WindowAnalysis.matlabScript()` with the golden text of `matlab_scripts.py`; `golden.sh --check` passes. The script was not run (GNU Octave is not installed; CR-019) | passed, as text |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Names and shapes, against §6.4.2 and the digests:
  - `Window.logged()` and `isLogged`, in the core;
  - `WindowAnalysis : MATLABExportable, CustomStringConvertible`;
  - `matlabScript() async throws(DSPError) -> String` (MAT-1).
- Threading:
  - the analysis runs once when the step's node is made, on the control context (`STFT.swift:115–116`);
  - the export runs on `BackgroundWork` (BG-1, MAT-6; `WindowAnalysisExport.swift:9–12`).
- Concurrency: `WindowAnalysis` is an immutable `Sendable` value. The recorder is task-local, so parallel tests do not hear one another.
- Typed errors throughout. No configuration object, no approval-gated API, no UIKit.
- WIN-5 is honoured by `STFT` only: see A-6. `WindowDiagnostics.swift:5–7` narrows WIN-5 to "when its framing step is made", which the rule does not say.
- VIS-2: see A-8.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-6 | WIN-5, a numbered rule ("For a window written `.logged()` the analysis is also run once per attachment"), and the acceptance of the row ("logged once per attachment when asked") | `Sources/ZTronDSPAnalysis/Steps/InverseSTFT.swift:103–122`: `window.isLogged` is never consulted. Only `STFT.swift:108,116` consult it. The rule is narrowed at `Sources/ZTronDSPAnalysis/Windows/WindowDiagnostics.swift:5–7` | `InverseSTFT(window: .hann.logged())` is attached and run, and nothing is logged: 0 reports against 1 for the control. Nothing says the request is ignored, and `Window.logged()` (`Window.swift:134–136`) promises the log "once per attachment" with no exception. Reproduction: `cp VerifierA/probes/VerifierAProbeTests.swift Tests/ZTronDSPAnalysisTests/ && ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh test "ZTronDSPAnalysisTests/VerifierAProbes/findingALoggedWindowGivenToAnInverseSTFTIsNeverReported()"`, then remove the copy | blocking |
| A-8 | VIS-2: every public symbol documented with its threading contract | `Sources/ZTronDSPAnalysis/Windows/WindowDiagnostics.swift:28` (`WindowAnalysis.lines`), `:67` (`description`) | `lines` documents what it holds, but not its contract. `description` has no comment at all. The type's comment ("an immutable value, usable on any thread") covers both, as earlier reports accepted (the VIS-2 pass of M9) | non-blocking |

Resolution of A-6, one of:

- `InverseSTFT` logs its window when its node is made, as `STFT` does, with the flag in its key. Test it.
- Or a change request restricts WIN-5 to framing steps, and `Window.logged()` says so.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
