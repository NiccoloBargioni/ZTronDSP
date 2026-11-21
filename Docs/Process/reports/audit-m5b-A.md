# Audit of Verifier A, M5b (WP-513 … 516, 525 … 527, 529 … 532, 539, 541, 612)

| Field | Value |
|---|---|
| Audited | Verifier A's 15 reports `WP-<id>-A.md` of the batch, its evidence under `VerifierA/` and its logs under `.build/va-logs/` |
| Auditor | An independent auditor (agent). Not Verifier A, not Verifier B, not the implementer. Nothing that Verifier B wrote was read. |
| Revision | The tree that Verifier A reviewed: the main snapshot of 2026-11-17 22:50, after CR-027 |
| Simulator | `ztdsp-27-vm5ba`; every run was a Debug build |
| Date | 2026-11-18 |
| Read | Brief `35-verifier-a-m5b.md`; `ZTronDSP-SPEC.md` (§4.2, §5.11.2, §6.1, §6.7, §6.9, §6.10, §6.12, §6.13, §9.3, §11.4–§11.8, the §12 rows); `Docs/Process/changes/` CR-001 … CR-027 of this checkout (CR-028 and later exist only in main and were not read); `Docs/Numerics/` notes of the batch; the 15 reports; `VerifierA/` |

## Outcome

- **The 35 blocking findings stand.** I reproduced every one myself, on a tree whose sources are identical to main. All 35 are blocking under §11.6.
  - 35 are confirmed. None is refuted, undetermined or confirmed only in part.
  - A-14 is wider than the report says. Through the public API the Fourier tempogram is already NaN at ×10²⁰ when the novelty curve peaks at 57.
  - Some verdicts rest on a reading of a rule (A-24, A-30, A-31, A-33). The notes after the table say what each one turns on. None of these readings changes a verdict.
- **The verdicts stand.**
  - Blocking: the 14 packages other than WP-541.
  - Pass: WP-541 (lens R). It holds in my own run.
  - I spot-checked five verdicts by running their acceptance checks. All five hold (section 3).
- **One gap (section 2).** The WP-541 report passes lens R without showing the second half of RT-3: memory freed when the plan is retired, off the analysis thread. The report itself says this was not observed.

## 1 The blocking findings (duty 1)

None of the findings is covered by a change request in `Docs/Process/changes/`. CR-VA-1 … CR-VA-6 are proposals written inside the reports and are not filed. CR-023 item 14 covers the precision floor of convolution, not overflow. CR-019 item 10 covers only an infinite prediction for silence. CR-024 items 8 and 10 (Proposed) point the same way as A-7 and A-24.

"Reproduced" means that I ran the reproduction myself, as described in section 4:
- The 32 probe filters: each output was byte for byte the one Verifier A filed.
- `vis2_scan.py` and `vis2_contract.py`: their output was identical to the filed output.
- `check_refs.py inversion` and `predicted_bounds.py`: their output was identical to the filed output.
- My own public-API probe (`AuditAPublicPaths`, imports without `@testable`) for A-10, A-12 and A-14.
- For the reading findings, the reproduction is the source lines, which I read.

| Finding | Package | Rule | Verdict | Severity | Reproduced | Evidence (my runs and reading) |
|---|---|---|---|---|---|---|
| A-1 | WP-513 | NUM-1; wrong result | confirmed | blocking | yes | e01, `FLT_MAX` impulse * [0.5, 0.25], `.full`: `.fft` 64 NaN and 1 ∞ of 65; `.partitioned` 64 NaN; `.direct` and `.automatic` give the truth (1.70·10³⁸, 8.5·10³⁷). e14, `FLT_MAX` then 4 095 zeros * 64 taps of 1/64: `.automatic` 4 159 of 4 159 NaN; `.direct` exact (5.3·10³⁶) |
| A-2 | WP-513 | VIS-2 | confirmed | blocking | yes | `Convolution.swift:15` (`ConvolutionMode`): the context is stated, allocation is not |
| A-3 | WP-514 | NUM-1; wrong result; §6.7 | confirmed | blocking | yes | e02, noise ×10²⁰, `.coefficient`: `.direct` 52 NaN and 18 ±∞ of 71; `.fft` 71 NaN. e14, 4 096 by 64 values: `.automatic` 4 159 of 4 159 NaN; `.direct` 3 180 NaN and 978 ±∞; at ×1 the values are finite, −0.060 … 0.123. The cause is the `Float` sums of `Correlation.swift:60` before the `Double` denominator (`:75–78`) |
| A-4 | WP-514 | VIS-2 | confirmed | blocking | yes | `Correlation.swift:16` (`CorrelationNormalization`): no allocation statement |
| A-5 | WP-515 | wrong result; §6.7 | confirmed | blocking | yes | e03: `[1e20, 1e20]` `.coefficient` gives `[0, 0]` with `.direct` and `.fft` (truth `[1, 0.5]`). e04: the step at ×10²⁰ gives 112 zeros. e14: 4 096 values ×10²⁰, `maxLag` 64, give 65 zeros with `.automatic` and `.direct`, against 1.0 at lag 0 at ×1 |
| A-6 | WP-515 | VIS-2 | confirmed | blocking | yes | `Autocorrelation.swift:35` (no allocation); no `///` at `:42`, `:45`, `:47`, `:49`, `:70`, `:86`, `:117`; `:123`, `:128`, `:135`; `OrderDiagnostics+Correlation.swift:10` |
| A-7 | WP-516 | §9.3 | confirmed | blocking | yes | t13: `Convolve(300 taps, .direct)` at 10¹² Hz ends the process with "Fatal error: Double value cannot be converted to UInt32 because the result would be greater than UInt32.max" (exit 65). The `.automatic` control runs. The unchecked conversion is at `Convolve.swift:118` |
| A-8 | WP-516 | NUM-1; wrong result | confirmed | blocking | yes | e05, `FLT_MAX` DC, 300 taps: `.fft`, `.partitioned` and `.automatic` give 1 024 of 1 024 NaN. `.direct` gives 802 finite values, and ±∞ only where the true sum leaves the range |
| A-9 | WP-516 | VIS-2 | confirmed | blocking | yes | `Convolve.swift:21`, `:62`, `:77`, `:134`: context, no allocation |
| A-10 | WP-525 | wrong result (the step's own contract, `OnsetStrength.swift:27–28`) | confirmed | blocking | yes | t15 and e06: floors 3.5·10³⁸, 10³⁹ and `greatestFiniteMagnitude` give confidences [0, 0, 0] for [0, 1, 1]. Public path (`STFT; Power; MelScale(40); Decibels; OnsetStrength(floor:)`, noise of 16 384): every one of 31 confidences is 0 from 3.5·10³⁸ up, and 1 zero in 31 at −80 and at 3.4·10³⁸. The cause is `Float(floor)` (`:79`) |
| A-11 | WP-525 | VIS-2 | confirmed | blocking | yes | `OnsetStrength.swift:35`, `:42`, `:44`, `:56`, `:69`, `:93`, `:102`; `OrderDiagnostics+Rhythm.swift:9`, `:14`, `:17` |
| A-12 | WP-526 | NUM-1; wrong result | confirmed | blocking | yes | e07: the click track ×10²⁰ gives 107 (causal) and 117 (centred) ±∞, and the largest difference from ×1 is ∞; ×`FLT_MAX` gives zeros. Public path (`…; OnsetStrength(); Gain(.linear(s)); Tempogram(.autocorrelation, window: 64)`): at ×10²⁰ and at ×0.5·`FLT_MAX`/peak, all 30 870 (causal) and all 32 310 (centred) values are 0, against −0.094 … 0.340 (0.548 centred) at ×1. The result should not depend on the scale |
| A-13 | WP-526 | VIS-2 | confirmed | blocking | yes | `Tempogram.swift:50`, `:54`, `:58`; shared with WP-527: `:15`, `:121`, `:122`, `:123`, `:132`, `:133`, `:135`, `:167`, `:197`; `OrderDiagnostics+Rhythm.swift:20` |
| A-14 | WP-527 | NUM-1; wrong result | confirmed (wider than stated) | blocking | yes | e07: ×`FLT_MAX` gives 6 444 of 6 444 NaN. Public path: already at ×10²⁰, a novelty curve that peaks at 57 gives 8 232 of 8 232 NaN (causal) and 8 444 of 8 616 (centred). The truth there is at most 5.8·10²¹. The report's "×10²⁰ is right" holds only for its curve of peak 1, whose bins stay under 4.4·10¹⁸. This is consistent with the squares of `vDSP_zvabs` (`TempogramNodes.swift:199–205`), which overflow above about 1.8·10¹⁹, besides the mean at `:68–71` |
| A-15 | WP-527 | VIS-2 | confirmed | blocking | yes | `Tempogram.swift:70`, `:74`, `:78`, `:93` |
| A-16 | WP-529 | §9.3 (public `ZTronDSPTesting`, CR-023 item 16) | confirmed | blocking | yes | t01 `reflected(5, count: Int.max)`, t03 `filter(…, kernel: Int.max, …)` and t05 `running([[1]], kernel: Int.max)` each end their process (exit 65; the call is the last `START` line). The causes are `MedianOracle.swift:27` (`2 * count`), `:54` and `:83` |
| A-17 | WP-529 | VIS-2 | confirmed | blocking | yes | `MedianStrategy.swift:6`, `:56`, `:111`, `:112`, `:114` |
| A-18 | WP-530 | wrong result | confirmed | blocking | yes | e09: `SoftMask(power: 5e-324)` at floor 10⁻¹⁰ gives (1,0), (0,1) and (1,∞) a share of 0.5 (definition 1, 0, 0). Power 10³⁹ gives (`FLT_MAX`, `FLT_MAX`) 1.0, and (10⁻¹², 10⁻¹²) 1.0 at floor 0 (definition 0.5). `validate()` (`MaskStrategy.swift:65–69`) accepts both, and `:80` narrows them. e10, offline: powers 10⁻⁵⁰ and 5·10⁻³²⁴ give a steady bin 0.5 (definition 1) |
| A-19 | WP-530 | VIS-2 | confirmed | blocking | yes | `MaskStrategy.swift:5`, `:27`, `:45`, `:57`, `:61`, `:65`, `:71`, `:109`, `:110`, `:112`, `:125` |
| A-20 | WP-531a (531b, 532) | wrong result | confirmed | blocking | yes | e10, steady bin, step and offline: mask 1 for margins up to 3.4·10³⁸; 0.5 (soft) and 0 (hard) for 3.5·10³⁸, 10³⁹ and `greatestFiniteMagnitude`. Isolated value: soft 0.5 for floors 10⁻⁴⁶, 10⁻⁵⁰ and 5·10⁻³²⁴ (definition 0). e18, through `HPSS`: DC 0.5 comes back as 0.5 at margin 3.4·10³⁸ and as 0.25 or 0 above it. The cause is `HarmonicPercussive.swift:162` |
| A-21 | WP-531a (531b, 532) | NUM-1; wrong result | confirmed | blocking | yes | e16: the STFT round trip is exact from ×3·10¹⁸ to ×10²⁰ (1.49·10⁻⁷). `HPSS` causal harmonic, scaled back, differs by 0.130 at ×3·10¹⁸ and by 0.351 at ×10¹⁹ (−0.043 … 0.076 against about ±0.36). The cause is `HarmonicPercussiveNode.swift:144` |
| A-22 | WP-531a | VIS-2 | confirmed | blocking | yes | `HarmonicPercussive.swift:53`, `:69`, `:71`, `:99`, `:141`, `:182`, `:189`, `:198`, `:209`; `OrderDiagnostics+Separation.swift:9`, `:14`, `:17` |
| A-23 | WP-531b | VIS-2 | confirmed | blocking | yes | `HarmonicPercussive.swift:66`: `alignment` has no `///`, and the type states no allocation |
| A-24 | WP-532 | §9.3; CR-024 item 8 | confirmed | blocking | yes | t20: `HPSS(select: .harmonic, frame: 1 << 40, hop: 16, …)` on 2 048 samples ends the process after about 108 s. The exit is 65, the call is the last `START` line, and no Swift fatal-error line was printed. 2⁴⁰ passes `StageValidation.transformLength`, which has no upper bound (`STFT.swift:96`). CR-024 item 8 refuses a buffer of more than 2²⁸ samples with `.resourceAllocationFailed` before anything is allocated (`ExecutionPlan.maximumSamples`). I did not determine whether the end is a trap or a process killed for memory, and I did not rerun the case |
| A-25 | WP-532 | NUM-1; wrong result | confirmed | blocking | yes | e11: `HPSS(.harmonic, 256/64, 17/17)` of noise ×10³⁰ and of `FLT_MAX` DC gives 3 904 (causal) and 3 392 (centred) NaN of 4 096. e15: `STFT(256/64); InverseSTFT()` alone gives 3 903 NaN of 4 096, and `STFT; Magnitude()` 7 869 of 7 869 NaN. For noise ×10³⁰ every intermediate value is in range (bins up to 8.6·10³⁰), so this case alone carries the finding. For `FLT_MAX` DC the DC bin itself is out of range, but the components are not |
| A-26 | WP-532 | VIS-2 | confirmed | blocking | yes | `HPSS.swift:42–43` ("An immutable value, usable on any thread"; no allocation); no `///` at `:44`, `:45`, `:47`, `:48`, `:50`; `:73` `hpss(…)` (neither context nor allocation); `OrderDiagnostics+Separation.swift:20` |
| A-27 | WP-539 | §9.3 | confirmed | blocking | yes | t22 (`by: Int.max`), t23 (`Int.max`, phase 1), t24 (`1 << 58`) and t30 (`CepstralCoefficients(count: Int.min)`) each end their process at their call (exit 65). By reading, each traps on an overflow. t22: `RateInversions.swift:50`, `2 * factor` (phase 0 keeps `:44` in range). t23: `:44`, `1 + Int.max`. t24: `:128`, `64 · 2⁵⁸`, reached through `:56`. t30: `StageInversions.swift:179`, `count - bands` |
| A-28 | WP-539 | INV-1; VIS-3; §11.6 | confirmed | blocking | yes | `Subsample` (`RateStages.swift:143`) conforms to `InvertibleStage` nowhere in `Sources/`. The conformances are `STFT`, `Cepstrum`, `CepstralCoefficients`, `DecibelsInversion` and `Decimate`, although §6.13 pairs `Subsample` with `Interpolate`. `DSP.inversionReport(ofSubsampling:by:phase:sampleRate:)` is in the digest (`ZTronDSPAnalysis.txt:991`), and no section or change request names it (grep: none; CR-019 item 15 and CR-023 item 16 do not list it). Its report names `inverse: "Interpolate"` (`:61`), but it reconstructs with the internal `BandlimitedInterpolation` (`:56`, `:116–152`). The §12 row of WP-537 anticipates function reports for the exact pair, not this one |
| A-29 | WP-539 | NUM-1; wrong result | confirmed | blocking | yes | t30: `Cepstrum(.complex, floor: 5e-324)` is accepted, and "a finite log spectrum" is observed as +∞. On the same frames 10⁻⁵⁰ gives 942.99 dB, so the least magnitude is about 1.4·10⁻³ and the true head-room is about 6 400 dB. `StageInversions.swift:120` forms `least / floor` before the logarithm. The margin equals the head-room when no bin is at the floor (`:125`) |
| A-30 | WP-539 | VIS-2 | confirmed | blocking | yes | `StageInversions.swift:71` has no `///`. No allocation statement at `:75`, `:138`, `:152`, `:184`, `:256` (no context either) and `:267`, nor at `RateInversions.swift:36`, `DecimateInversion.swift:35` or `:91` |
| A-31 | WP-539 | §6.13 ("a bound on the relative error"); `inversion-analysis.md` hazard 3 | confirmed | blocking | yes | `predicted-bounds.txt` reproduced. Subsampling: on band-limited signal 2 the prediction is 4.50·10⁻⁸ against a largest error of 1.99·10⁻⁷ (×4.41; RMS ×1.42). Signal 1: 0.0333 against 0.1725 (×5.18; RMS ×5.21). DC and `FLT_MAX` DC: ×4.71·10⁴ (RMS ×2.36·10⁴). A full-scale tone: ×2.89 (RMS ×1.32). The prediction, `RateInversions.swift:53`, has no round-off term. `CepstralCoefficients` below full rank: RMS ×1.00, largest ×1.31 … ×4.21. That prediction is the RMS share at `StageInversions.swift:174` |
| A-32 | WP-612 | wrong result | confirmed | blocking | yes | e10, offline: a steady bin gets mask 1 for margins up to 3.4·10³⁸, and 0.5 (soft) or 0 (hard) for 3.5·10³⁸, 10³⁹ and `greatestFiniteMagnitude`. An isolated value gets soft 0.5 and 0.5 for floors 10⁻⁴⁶, 10⁻⁵⁰ and 5·10⁻³²⁴, where §6.10 and CR-023 item 12 give 0 and 0. `OfflineSeparation.swift:96–98` narrows the values after `HarmonicPercussive.check` has accepted them (`:90–92`) |
| A-33 | WP-612 | VIS-2 | confirmed | blocking | yes | `MedianStrategy.swift:92` has no `///`. `:131` and `:179` say "usable on any thread" and state no allocation. No `///` at `:140`, `:157`, `:164`, `:182`, `:197`, `:203`. `OfflineSeparation.swift:34` and `:55` state the context and not the allocation |
| A-34 | WP-539 | §6.13 (full rank: `count` equals the band count); INV-2; INV-3 with O-17 | confirmed | blocking | yes | e17, after `STFT; Power; MelScale(40); Decibels`: counts 41 and `Int.max` report "full rank" observed 1 and 9.22·10¹⁸, holds, predicted 10⁻⁵, measured `nil` although a signal was given. Count `Int.min + 40` throws when the stage is attached. t30, after a mel power spectrum without `Decibels`: count `Int.max` holds with no error. e13, the same pipeline with count 40: throws "cannot follow a signal of the domain mel power spectrum". The causes are `StageInversions.swift:159` (`count >= bands`) and `:187`; the stage refuses `count > bands` (`CepstralCoefficients.swift:42`) |
| A-35 | WP-539 | wrong result; NUM-1; §6.13 | confirmed | blocking | yes | e19: references 5·10⁻³²⁴ and 10⁻⁵⁰: "values above the floor" holds, predicted 10⁻⁵, measured relative error 1.0 and SNR 0 dB. Floors `greatestFiniteMagnitude` and 10³⁹ dB: predicted ∞, SNR −∞, error ∞. Floor 400 dB on powers: predicted 4.27·10³⁸, measured ∞. References `greatestFiniteMagnitude` and 10³⁹: predicted 7.68·10²⁹⁰ and 4.27·10²¹, measured ∞. The report works in `Double` (`StageInversions.swift:208–210`, `:221`, `:228`); the stage narrows to `Float` (`SpectralValues.swift:106–108`) after accepting the values (`:102–103`) |

Notes on the readings:

- **The VIS-2 findings.** Every symbol listed by A-2, A-4, A-6, A-9, A-11, A-13, A-15, A-17, A-19, A-22, A-23, A-26, A-30 and A-33 was read in the source. VIS-2 (§5.11.2) applies to "every public symbol", and no filed change request narrows it.
  - Some entries are protocol witnesses whose requirement states the contract (`InversionReport.swift:243–244`, `MedianStrategy.swift:57–58` and `:73`). Others are unavailable overloads. Those entries turn on CR-VA-4.
  - Each finding also holds without those entries: types, initialisers, modifiers and free or static functions are among its symbols.
- **A-31.** Part (i), subsampling, exceeds its prediction under both measures. Part (ii), `CepstralCoefficients`, exceeds only `relativeError`. That is the error §6.13 and `InversionReport.swift:127` mean by "the relative error". CR-VA-6 asks the owner to settle it.
- **A-24** is blocking whether the process ended by a trap or for memory. A legal parameter ends the process instead of being refused (CR-024 item 8).

## 2 Gaps in the verification (duty 2)

| Package | Gap |
|---|---|
| WP-541 (lens R) | RT-3 has two halves: memory is allocated when the plan is compiled and freed when it is retired, both off the analysis thread. The report shows the first half (the audit from block 0, e20). It says of the second "The release at retirement was not observed: the audit closes before detach". The verdict `pass` therefore stands without evidence for half of RT-3. |

### Checked and not gaps

- **All 15 reports are present.** Each states the verdict, and each finding gives the checklist item, the location, the evidence and the severity (VER-4).
- **The acceptance checks of every §12 row were run.** The evidence is the filed run summaries: Debug twice and Release once, 149 of 149 tests each time (`debug-run1`, `debug-run2`, `release-run1`), plus the Release audit run.
- **Lens N on the `ALG` rows (WP-513, 515, 525, 526, 527, 529, 530, 531a).** Each report checks the currency record (rows 10, 11, 14, 15, 16 and 22 of `currency-2026-11.md`). Each also checks the stability note against the code by a mutation that makes the named tests fail and is restored with `cmp`: M1, M2, M3, M4 (WP-526 and WP-527), M5, M6 and M7 (`VerifierA/mutations/summary.txt`).
  - M4 does reach the Fourier tempogram. Its log has the Fourier assertion of `silenceAndACurveThatDoesNotMoveGiveZeros` failing ("bins.count == 117 …").
  - M7 is hazard 1 of `harmonic-percussive.md`. M5 is hazard 1 of `median-lanes.md`.
- **Lens N on every N report.** Each shows the definition read against the code, the precision choice, the tolerance (not loosened) and the edge cases: empty, length 1, DC, Nyquist, silence, full scale, non-finite input.
  - WP-529 and WP-530 cover DC, Nyquist, silence and full scale by the stress test and the reference, which the verifier ran. WP-530 shows infinities in its own probe, and NaN through the offline probe e12, which it cites.
- **Lens R, WP-541.**
  - The allocation audit exists and passes in Debug and Release.
  - It would fail with an added allocation (M8: 10 000 and 300 allocations reported).
  - A benchmark is recorded (`benchmark-full-analysis-release.json`, 143 214.5 ns per block).
  - Setups exist from block 0 (e20). SEL-3 and RT-7.4 lint are covered.
  - RT-1, RT-8 and RT-9 are argued out of scope for a pull mock source.
- **Lens A, WP-612.** The report covers names and shapes, Strategy conformance, DEP, EXT, VIS, IMM and API-6, Sendable and BG rules, typed errors and the threading documentation.
  - It gives no artefact for "minos 15.0" (PLAT-1). I read it myself: `LC_BUILD_VERSION` of `ZTronDSPAnalysis.o` shows `minos 15.0`, sdk 27.0.
  - The report records that §4.2's "may import" column does not list Foundation for `ZTronDSPAnalysis`, and that `MedianStrategy.swift` imports it. It judges this not a DEP-1 matter, and it files no CR. The duty was carried out and its outcome recorded, so this is not a gap.

## 3 Spot checks

One `test-only` run on the rebuilt pristine tree, Debug, `ztdsp-27-vm5ba`: 18 tests in 5 suites passed (05:33:06 to 05:33:20).

| Package | Acceptance check | My result |
|---|---|---|
| WP-541 (`pass`) | 0 allocations over 10⁴ blocks | `tenThousandBlocksOfTheStockFullAnalysisAllocateNothing` passed: "10 000 blocks of 512 frames … 0 allocation(s) of 0 byte(s), 0 deallocation(s)", with 10 000 × 512 frames asserted. `pacedAsAMicrophoneTheAnalysisThreadAllocatesNothing` passed (300 blocks, 0 asserted) |
| WP-612 | `.automatic` follows the table; `.metal` without a device is `backendUnavailable` | `automaticFollowsTheTable`, `metalWithoutADeviceIsBackendUnavailable` and `automaticFallsBackToTheCPUWithoutADevice` passed |
| WP-532 | A bound switch meets CLICK-1 and keeps the latency; SNR ≥ 100 dB | `aBoundSwitchMeetsCLICK1AndKeepsTheLatency(alignment:)`, 2 cases, passed: ratio 1.0 for both changes in both alignments, against a limit of 1.5. `theComponentsReconstructTheInput(name:)`, 2 cases, passed: SNR 138.70 to 139.31 dB. The whole of `HPSSTests` passed |
| WP-529 | Allocation-free | `theKernelsRunWithoutAllocating` passed |
| WP-531b | Latency equals the look-ahead | `theLookAheadIsLatencyAndFramesKeepTheirTimes` passed |

## 4 How this was run

- **The tree.** `Sources`, `Tests`, `Scripts` and `Package.swift` are identical to `/Users/admin/Documents/ZTronDSP` (`diff -rq`), before the runs and after the restoration. `VerifierA/tree-check.sh` reports "identical to the pristine copy". Main's `Docs` hold later edits (CR-028 and after), which were not read.
- **Builds.** `ZTD_DEVICE=ztdsp-27-vm5ba Scripts/xc.sh build` was run with two temporary files in `Tests/ZTronDSPAnalysisTests/`:
  - a byte-identical copy of `VerifierA/probes/VAProbes.swift`;
  - my `AuditAProbes.swift`, a suite "Audit A public paths" that imports Foundation, Testing and the four public modules, with nothing `@testable`. It holds the A-10 floor sweep through `STFT(1 024/512); Power; MelScale(40); Decibels; OnsetStrength(floor:)`, and the A-12 and A-14 tempograms of a 120 BPM click track through `…; OnsetStrength(); Gain(.linear(s), ramp: 0); Tempogram(…, window: 64, alignment:)` for s = 1, 10²⁰ and 0.5·`FLT_MAX`/peak. Its output went to `.build/audit/out/`.
- **Probes.** The 32 filters went through `VerifierA/run-probes.sh`, each in a process of its own. They are e01 … e05, e06, e07, e09, e10, e11, e13 … e19, t01 … t06, t13, t15, t20, t21, t22, t23, t24, t30 and r05. Every output file came out byte for byte as filed (`diff -rq` against a copy taken first). The scripts ran as `python3 -I -B`, with output to `.build/audit/`.
- **Restoration.** I removed both temporary files and restored `VerifierA/out/` from the copy, mtimes included. The 788 SHA-256 sums of `VerifierA/` are identical to those taken before the runs. I rebuilt the pristine tree before the spot checks.
- Nothing under another `v-…` folder and no `WP-*-B.md` of these packages was read.
