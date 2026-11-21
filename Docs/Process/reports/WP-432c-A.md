# Verifier report — WP-432c, lens N

| Field | Value |
|---|---|
| Package | WP-432c — `Filter(_:)` for an `IIRSystem` or an `FIRSystem`; the FIR response stages; FIR lowering (REAL-4) and latency |
| Lens | N (the first lens of "N, A") |
| Verifier | A, an independent agent session: not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` (A-2) |

## What was received (VER-2)

- [x] The brief (`briefs/25-verifier-a-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output: this verifier produced it in the checkout (first row below); coverage is not part of this lens
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the allocation audit `aThousandBlocksOfEachFilterAllocateNothing` |
| Measured response within 0.1 dB | Probe `p432` at 44.1 kHz: windowed-sinc low-pass with 255, 256 and 100 taps; a least-squares band-pass with 1 001 taps; a high-pass from a roll-off (317 taps); `Filter(FIRSystem { Taps(…) })` with 300 even-length symmetric taps, 5 antisymmetric taps, 3 non-symmetric taps, 6 taps with a delayed core, and 2 taps; `Filter(IIRSystem)` for a hum notch. A 16 384-sample impulse went through each compiled plan. `VerifierA/run-probe.sh p432 && python3 VerifierA/wp432_stages.py` compares the measured response with the analysis (with the DFT of the taps for the 1 001-tap filter, whose analysis is refused above 513 taps as CR-018 item 8 says) | FIR stages: worst 0.0009 dB. Each impulse response equals the taps (exactly on the direct path; within 3.0e-8 partitioned). `Filter(IIRSystem)`: 0.0000 dB in `.automatic` and `.double`. Forced single, where the measurement recommends double: 0.236 dB (CR-018 item 2; A-B2 under WP-432a) |
| The direct and partitioned paths agree within −100 dB | The same filters on seeded noise, forced to `.native` (direct) and to `.accelerate` (partitioned) | −123.8 to −132.5 dB |
| Latency reported (REAL-5: "(K − 1)/2 for a linear-phase FIR") | The kernel latency and the downstream environment's `latency` from the probe, set against (K − 1)/2 and the measured group delay of the taps | Odd K: 127 for 255 taps, 500 for 1 001, 158 for 317 and 2 for the 5 antisymmetric taps, each equal to (K − 1)/2. Even K: **256 taps report 127 against (K − 1)/2 = 127.5; 100 taps report 49 against 49.5, and the measured group delay is 49.5000 samples; 300 taps report 149 against 149.5; 2 taps report 0 against 0.5 (A-2)**. A delayed core reports its true delay (4); non-linear-phase taps report 0 |
| REAL-4, direct up to the crossover and partitioned above it | The implementation `.automatic` chose, from the same probe (its output compared bit for bit with both forced paths) | Direct at 255 taps and below; partitioned at 256 taps and above. Running exactly 256 taps partitioned is A-B4 |
| STG-1 | `Scripts/order-matrix.sh --check`, `Scripts/compile-fixtures.sh --build`, `Stages/Fluent.swift`, `Tests/OrderMatrix/stages.txt` | The matrix is current. The fixtures behave, among them `DesignSystemFilterAfterASpectrum`, `DesignIIRSystemInAnFIRSystem`, `DesignTapsInAnIIRSystem` and `DesignStageInAnIIRSystem`. Fluent `filter(_:)` for both systems and the FIR forms of the four response stages, each with a trailing `isActive:`. The FIR settling time is K − 1 (C kernel). Latency: A-2 |

## Lens checklist (§11.5)

- **N — numerical correctness.** Responses and the two convolution paths agree, measured independently. Edge cases: 2 taps, odd and even lengths, antisymmetric, non-symmetric and delayed taps, the crossover length itself, a filter above the analysis cap. **The reported latency is wrong by half a sample for every even-length linear-phase FIR.** No tolerance was loosened.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-2 | REAL-5: "Each stage reports its latency: (K − 1)/2 for a linear-phase FIR". Acceptance: "latency reported" | `Sources/ZTronDSPDesign/Systems/FIRSystem.swift:268-272` (`FIRMath.latency(of:)`, integer division) through `Systems/Realization.swift:240` (`.fir(taps:latency:)`). The public documentation says "(K − 1) / 2" without rounding: `Stages/ResponseStages.swift:37, 234, 433, 637`, `Stages/Filter.swift:23`, `Systems/FIRSystem.swift:64` | For even K the stage reports ⌊(K − 1)/2⌋: `LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 100)` reports 49 samples. Its taps are symmetric and their group delay is 49.5 samples. The same holds for 256 taps (127 against 127.5), 300 taps (149 against 149.5) and 2 taps (0 against 0.5). `DSPEnvironment.latency` is a `TimeInterval` and could carry 49.5/fs, but `KernelSpec.fir(taps:latency:)` takes whole frames. The package's own test asserts the floor (`Tests/ZTronDSPDesignTests/SystemStageTests.swift:273-275`: "K = 100 reports 49"). Only an internal comment says "rounded down" (`FIRSystem.swift:264-266`). No change request covers it, so downstream alignment and the bypass delay line (ACT-8) are half a sample off for even lengths. Reproduce: `VerifierA/run-probe.sh p432 && python3 VerifierA/wp432_stages.py` (rows `fir-lp-100`, `taps-300-even`, `taps-two-even`) | **blocking**. Resolve by reporting (K − 1)/2 exactly; or, by a CR, define the latency as whole samples rounded down for even K and say so in the public documentation; or reject even-length linear-phase FIRs where the half sample matters |
| A-B4 | REAL-4: "directly up to the calibrated crossover length (initially 256 taps) and as a partitioned convolution above it" | `Sources/ZTronDSPCore/Toolkit/Implementation.swift:126` (`size >= firPartitioned`); Core, not this package | A 256-tap FIR runs partitioned. The rule reads as direct up to and including 256. The two paths agree within −129 dB, so this costs speed only (SEL-6) | non-blocking (backlog) |
