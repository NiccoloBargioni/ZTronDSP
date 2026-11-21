# Verifier report — WP-438b, lens A

| Field | Value |
|---|---|
| Package | WP-438b — `Interpolate(by:)` stage |
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
| Image rejection ≥ 80 dB | `RateStageTests/theImagesOfAnInterpolatedToneAreEightyDecibelsDown()`: the worst image is 94.3 dB below the tone | pass |
| `Interpolate` after `Decimate` restores a band-limited fixture to SNR ≥ 80 dB | `interpolationAfterDecimationRestoresABandLimitedSignal()`: the worst SNR is 88.0 dB, 7.96 dB above the bound, with the delay checked to be the filter length − 1 | pass |
| (§6.12) Upsample, then low-pass with gain L, as a polyphase filter | `interpolationIsZeroStuffingThenTheFilterWithGainTheFactor()`: −135.5 dB against zero-stuffing and then filtering (bound −100 dB) | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.12).**
    - `Interpolate(by:)`, with a trailing `isActive:` (digest 492).
    - The fluent twin is `interpolate(by:…)` (digest 641).
    - The toolkit function is `DSP.interpolate` (digest 973).
    - Latency (K − 1)/2 at the output rate: the probe reads 26 input samples for `Interpolate(by: 2)` at 48 kHz, that is 52 output samples.
    - Settling time: the taps of one phase − 1 (`ztd_rate.c:193`).
  - **STG-1.**
    - Fluent modifier and `isActive:`: present.
    - The order matrix is current.
    - `DesignRateChangerAfterASpectrum` fails with its sentence.
    - Allocation audits: `aThousandBlocksOfTheRateChangersAllocateNothing()` and `StockPipelineAuditTests`, in Debug and Release.
  - **Typed errors.**
    - A factor of 0 is rejected (`factor`), and so is −2 "at Interpolate[0]" (probe).
    - A passband of 1.5 is rejected (`passband`).
  - **VIS-2.** `Stages/RateStages.swift` is fully documented with threading contexts.
  - **Public additions** named in neither §6.12 nor a change request: `rejection:` and `passband:` on `Interpolate`, its fluent twin and `DSP.interpolate` (finding 1). The same finding is raised for `Decimate` in WP-436-B.
  - **Gates.** `Scripts/api-digest.sh --check`, `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (BL-2) | Public API per §4–§8 | `Docs/API/ZTronDSPDesign.txt:492, 641, 973` | `rejection:` (default 80 dB) and `passband:` (default 0.8) are public and unnamed in §6.12 and in every change request. `Interpolate(by: L)` still works as specified. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
