# Verifier report — WP-432a, lens N

| Field | Value |
|---|---|
| Package | WP-432a — IIR filter stages: `LowPass` … `BandStop` as sequence stages, lowered to the cascade |
| Lens | N (the first lens of "N, A") |
| Verifier | A, an independent agent session: not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/25-verifier-a-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output: this verifier produced it in the checkout (first row below); coverage is not part of this lens
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the allocation audit `aThousandBlocksOfEachResponseAllocateNothing` |
| The running pipeline's measured response is within 0.1 dB of the analysis | Probe `p432` at 44.1 kHz ran seven stages through the compiled plan, each in `.automatic`, `.single` and `.double`: Butterworth low-pass order 4; Chebyshev I high-pass order 5; Chebyshev II band-pass order 3; elliptic band-stop order 3; elliptic low-pass order 7 at 18 kHz; Butterworth high-pass order 8 at 20 Hz; Bessel low-pass order 6. A 16 384-sample impulse went through each. `VerifierA/run-probe.sh p432 && python3 VerifierA/wp432_stages.py` takes the measured response (DFT of the output) and compares it with the package's `analysis` and with SciPy's own design of the same filter, at 1 025 frequencies from 0 to Nyquist wherever the response is within 60 dB of its peak | `.automatic`: worst 0.0024 dB. `.double`: worst 0.0019 dB. `.single`: within 0.0024 dB wherever the measurement recommends single. Where it recommends double, forcing single gives 0.167 dB (Chebyshev I, 300 Hz) and 1.418 dB (Butterworth order 8, 20 Hz); CR-018 item 2 covers this (A-B2). The analysis agrees with SciPy within 1.2e-10 dB |
| STG-1 | `Scripts/order-matrix.sh --check` and `Scripts/compile-fixtures.sh --build` (with `TMPDIR=$PWD/.build/tmp`); reading `Stages/Fluent.swift` and `Tests/OrderMatrix/stages.txt`; latency from the probe | Matrix current (52 stages on 21 domains). The fixtures behave (7 valid, 133 invalid with their sentences, among them `DesignFilterAfterASpectrum` and its fluent form). Six fluent forms per stage, each with a trailing `isActive:`. Latency 0 for every IIR stage (REAL-5). The biquad settling time comes from the C kernel |

## Lens checklist (§11.5)

- **N — numerical correctness.** The measured response agrees with the analysis and with an independent SciPy design. Edge cases: a 20 Hz corner of order 8 (the hardest single-precision case), a corner at 18 kHz near Nyquist, band forms, and the Bessel family. The precision choice is that of WP-433. No tolerance was loosened.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-B2 | Change request evidence (CR-018 item 2) | `Docs/Process/changes/CR-018.md`, item 2 | The CR gives 0.133 dB, for a band boost of order 8, as its example of a forced-single deviation. Forcing single on a Butterworth high-pass of order 8 at 20 Hz (44.1 kHz) deviates 1.418 dB from the analysis, more than ten times that. The owner should decide on the larger figure | non-blocking (backlog) |
