# Audit of Verifier B — milestone M5b (WP-513 … WP-516, WP-525 … WP-527, WP-529 … WP-532, WP-539, WP-541, WP-612)

| Field | Value |
|---|---|
| Audited | Verifier B's verification of the 15 packages: `Docs/Process/reports/WP-<id>-B.md`, `VerifierB/`, and the run outputs it left under `.build/` |
| Auditor | Claude (agent). Took no part in the verification. Read nothing Verifier A wrote: no other `v-…` folder, no `WP-5*-A.md` and no `WP-612-A.md` |
| Revision | The verifier's checkout: main tree snapshot 2026-11-17 22:50, after CR-027 |
| Simulator | `ztdsp-27-vm5bb` only |
| Date | 2026-11-18 |
| Result | Of the 29 blocking findings, 28 are **confirmed, blocking**. **B-24 is confirmed in part and non-blocking**: its facts stand, but the rule it cites does not cover them (§1.4). I reproduced every finding myself. For B-2, B-4, B-6, B-8, B-17, B-18, B-20, B-24, B-27 and B-28 I also ran inputs of my own (§0). There are two gaps in the verification, neither of which changes a verdict (§2). Five spot checks of `pass` verdicts all hold (§3) |

## 0. How I worked

- **Pristine sources.** I compared the tree before I started and again at the end, after removing the probe files. `diff -r` of `Sources`, `Tests` and `Scripts`, and `cmp Package.swift`, against both `.build/pristine` and `/Users/admin/Documents/ZTronDSP` found no difference.
- **Nothing else changed.** The verifier's last file is `VerifierB/README.md`, written at 04:35. Since then, `find -newermt` finds no changed file in `Sources`, `Tests`, `Scripts`, `Docs` or `VerifierB` apart from this one. The directory `Tests/ZTronDSPAnalysisTests` has a newer time because I added and removed the probe files; its contents are pristine.
- **Runs.**
  - I copied the verifier's two probe files (`VerifierB/Probes/*.swift`, three suites) and a probe file of my own (`AuditM5bProbes.swift`, Appendix A, inputs I chose) into `Tests/ZTronDSPAnalysisTests/`.
  - I built in Debug and in Release; each build ended `** TEST BUILD SUCCEEDED **`.
  - I ran **every test in a process of its own**: one `Scripts/xc.sh test-only` call each, with `ZTD_DEVICE=ztdsp-27-vm5bb`, through a runner of my own (Appendix B). Results went to `.build/audit-probes` (Debug), `.build/audit-probes-release` and `.build/audit-spot`.
  - The data probes wrote to `.build/audit/vbout` (`TEST_RUNNER_ZTD_VB_OUT`), not to `VerifierB/out`.
  - At the end I removed the three probe files and compared the tree as above.
- **Agreement with the verifier's records.**
  - Every non-trap verifier probe I ran prints the same lines as the verifier's log, line for line. In Debug, with the number of probe lines:
    - `t513ConvolveLargeKernel` (9), `t513ConvolveSingleValues` (80), `t514CorrelateFullRange` (192)
    - `t515AutocorrelateFullRange` (256), `t515StepFullRange` (24)
    - `t516ConvolveLargeKernel` (8), `t516ConvolveKernelTaps` (72)
    - `t539UpsamplingSampleRate` (16), `t539SubsamplingSampleRate` (16), `t539FullRangeSignal` (18)
    - `vb612EdgeCasesOfTheData` (121), `vb612EdgeCasesWriteTheData` (1), `vb612NonFiniteData` (36), `vb612TrapHarmonicMargin` (24), `vb612TrapFloor` (30)
    - `vb612LargestBinCount` (12), `vb612TrapBinCount` (18), `vb612TrapStrategyFilter` (72)
    - `vb530SoftMaskOnSubnormalMedians` (14), `vb531aLiveMarginAboveTheFloatRange` (9), `vb531aLiveFloorBelowTheFloatRange` (13)
  - In Release I ran `t513ConvolveLargeKernel`, `t515StepFullRange` and `t516ConvolveLargeKernel`; they match the verifier's Release logs. My Release run of `t539FullRangeSignal` matches its Debug log; the verifier ran that probe in Debug only.
  - The seven trap probes print the same `VBT call` line as the verifier's logs. It appears one to three times, according to how often xctest relaunched the test; the verifier's logs vary the same way.
  - The 136 data files my run wrote equal their counterparts in `VerifierB/out` byte for byte. That folder also holds the 240 files of the reference-data probe, which I did not re-run.
  - `edge_wp612.py` prints the same output on my data and on the verifier's, and that output equals `VerifierB/out-edge-wp612.txt`.
- **VIS-2.**
  - I re-ran `vis2_decide.py`. Its output equals `VerifierB/out-vis2/decisions.txt` byte for byte.
  - That script reads symbol graphs the verifier extracted. So I also printed the documentation comment above every flagged declaration with a script of my own (`doc_above.py`), and read each one.
- **Change requests.** None of CR-001 … CR-027 in `Docs/Process/changes/` describes any of these deviations. The ones close to them are CR-023 items 10, 12, 14 and 16, and CR-024 items 8, 10 and 15; the CR-024 items concern plans and sessions. Where one matters it is named below. The main tree holds later CRs, from CR-028 on. They post-date the revision under review, and I did not read them.

## 1. Blocking findings (duty 1)

| Finding | Packages | Verdict | Severity (§11.6) | Reproduced by the auditor | Evidence |
|---|---|---|---|---|---|
| B-1 VIS-2, `ConvolutionMode` | WP-513 | **confirmed** | **blocking**: VIS-2 (line 961), a numbered rule; brief rule 1 | yes | **Script:** `vis2_decide.py` prints "=== WP-513: 5 public symbols, 1 failing (V1 0, V2 0, V3 1)".<br>**Reading:** the comment of `Convolution.swift:15` ends "An immutable value, usable on any thread." and says nothing on allocation.<br>**CR:** CR-023 item 16 lists the enum as an addition and says nothing of its contract |
| B-2 transform overflow, `DSP.convolve` | WP-513 | **confirmed** | **blocking**: NUM-1 (line 1005), SEL-6 (line 1447), a wrong result | yes, Debug and Release | **Verifier's probe `t513ConvolveLargeKernel`** (512 taps of gFM/1024 on a full-scale sine of 4 096 samples):<br>- `.direct`: 4 607 finite values, largest 5.070025e+36<br>- `.fft`: 4 607 NaN<br>- `.partitioned`: 4 096 NaN<br>- `.automatic`: 4 607 NaN<br>- Release is the same<br>**Verifier's probe `t513ConvolveSingleValues`:** `[+gFM]` with `[1]` by `.fft` gives one +inf.<br>**My input:** `[1e38, 1e38] * [1, 1]`, whose exact result is `[1e38, 2e38, 1e38]`. `.fft` gives `[nan, inf, nan]`; `.direct`, `.partitioned` and `.automatic` give the exact result.<br>**Documentation:** `Convolution.swift:41-47` promises the methods agree within 10⁻⁶ of the largest value the inputs can give. CR-023 item 14 restates that accuracy floor and says nothing of overflow |
| B-3 VIS-2, `CorrelationNormalization` | WP-514 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** "=== WP-514: 7 public symbols, 1 failing (V1 0, V2 0, V3 1)".<br>**Reading:** the comment of `Correlation.swift:16` ends "An immutable value, usable on any thread." and says nothing on allocation |
| B-4 transform overflow, `DSP.correlate` | WP-514 | **confirmed** | **blocking**: NUM-1, SEL-6, a wrong result (the documented range of `.coefficient`) | yes | **Verifier's probe `t514CorrelateFullRange`:**<br>- `[+gFM]` with `[1]`: `.fft` gives `[inf]` for `none`, `biased`, `unbiased` and `coefficient`. The other strategies give `[3.4028235e+38]`, and `[1.0]` for `coefficient`.<br>- The full-scale sine with `[+gFM]`: `.fft` and `.partitioned` give 4 096 NaN for every normalisation. `.direct` and `.automatic` are finite (`coefficient` 0.022090241).<br>**My input:** `[1e38, 1e38]` with `[1, 1]`. `.fft` gives `[nan, nan, inf]` for `none` and for `coefficient`, which `Correlation.swift:13` documents as "Between −1 and 1". `.direct` gives `coefficient` `[0.5, 1.0, 0.5]`.<br>**The lens-T part:** no test in `CorrelationTests.swift`, `ConvolutionTests.swift`, `ConvolveStageTests.swift` or `AutocorrelationStepTests.swift` uses a value near the top of the range. A grep for `greatestFiniteMagnitude`, `1e3x` and `0x1p6x` finds none |
| B-5 VIS-2, `Autocorrelation` | WP-515 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 6 of 18 public symbols fail.<br>**Reading:**<br>- `:35` says "usable on any thread; `lower(_:)` runs on the control context" and nothing on allocation.<br>- `:49` (`init`) and `:117` have no comment.<br>- The comments of `:123` and `:128` state neither a context nor allocation.<br>- `:135` says "see ``Autocorrelation``" and nothing on allocation |
| B-6 overflow before the division, autocorrelation | WP-515 | **confirmed** | **blocking**: NUM-1, SEL-6, a wrong result (`.coefficient` "reads 1 at lag 0") | yes, Debug and Release | **Verifier's probes `t515AutocorrelateFullRange` and `t515StepFullRange`:**<br>- `[2⁶³, 0, 0, 0]`: `.fft` and `.partitioned` give `[inf, 0, 0, 0]` for `none`, `biased` and `unbiased`, and `[0, 0, 0, 0]` for `coefficient`, where `.direct` gives `[1, 0, 0, 0]`.<br>- 2⁶³ × sine, `.biased`, `.direct`: 35 +inf and 27 −inf of 65 values.<br>- The step on 2⁶³ × noise: 32 576 of 32 576 values are NaN for `none`, `biased` and `unbiased`, and `coefficient` is all 0.<br>**My input:** four values of 10¹⁹. Exactly, `biased` is `[1e38, 7.5e37, 5e37, 2.5e37]`, `unbiased` is `[1e38]×4` and `coefficient` is `[1, 0.75, 0.5, 0.25]`, all inside the range.<br>- `.direct` (and `.automatic`) gives `biased` `[inf, 7.5e+37, 5e+37, 2.5e+37]` and `unbiased` `[inf, 1e+38, 1e+38, 1e+38]`.<br>- `.fft` and `.partitioned` give `[nan, inf, nan, nan]`.<br>- `coefficient` is `[0, 0, 0, 0]` on every strategy.<br>- The step on a constant of 10¹⁹ (window 8, hop 8; exact `biased` lag 0 = 10³⁸) gives 24 NaN and 8 inf of 32 values for `biased`, and `coefficient` all 0.<br>- Release is the same.<br>(My `none` lag 0 is 4·10³⁸, outside `Float`, so I do not count that value against the code) |
| B-7 VIS-2, `Convolve` | WP-516 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 4 of 12 public symbols fail.<br>**Reading:** `Convolve.swift:21`, `:62`, `:77` and `:134` each say "usable on any thread", and `:62` adds that `lower(_:)` runs on the control context. None says whether it allocates; only `lower` (`:92`) says "Control context; allocates." |
| B-8 overflow in the stage | WP-516 | **confirmed** | **blocking**: NUM-1, SEL-6, a wrong result | yes, Debug and Release | **Verifier's probe `t516ConvolveLargeKernel`:** `.automatic`, `.fft` and `.partitioned` give 4 096 NaN; `.direct` is finite, largest 5.070025e+36.<br>**Verifier's probe `t516ConvolveKernelTaps`:** a kernel of `[±gFM]` gives 4 096 NaN by `.fft` and by `.partitioned`; `.direct` and `.automatic` are finite.<br>**My input:** `Convolve(kernel: [1e38, 1e38])` on 1 024 ones, whose exact output is 1e38 and then 2e38. `.fft` and `.partitioned` give 1 024 of 1 024 NaN; `.direct` and `.automatic` give the exact values. Release is the same |
| B-9 VIS-2, `OnsetStrength` | WP-525 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 4 of 11 public symbols fail.<br>**Reading:** `OnsetStrength.swift:35` has no allocation statement. `:44` (`init`) and `:93` (`buildPartialBlock`) have no comment at all. `:102` says "see ``OnsetStrength``" |
| B-10 VIS-2, the tempogram types | WP-526 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 8 of 22 public symbols fail.<br>**Reading:**<br>- `Tempogram.swift:15` says "A method is a description: an immutable value, usable on any thread". Only its requirement `makeTransform` (`:22`; "Control context: it allocates", `:18`) says anything on allocation.<br>- `:50` and `:121` say nothing on allocation.<br>- `:54` and `:135` (the initialisers) and `:122`/`:123` (`Input`, `Output`) have no comment.<br>- `:197` says "see ``Tempogram``" |
| B-11 VIS-2, `FourierTempogram` | WP-527 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 3 of 6 public symbols fail.<br>**Reading:** `Tempogram.swift:70` says "An immutable value, usable on any thread." `:74` has no comment. `:93` says "The Fourier tempogram, zero-padded `resolution` times." None of the three says anything on allocation |
| B-12 VIS-2, the median strategy | WP-529 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 4 of 20 public symbols fail.<br>**Reading:** `MedianStrategy.swift:6` says only "The direction a median is taken along (§6.10)." `:56` and `:111` say "usable on any thread" and nothing on allocation. `:112` (`init() {}`) has no comment |
| B-13 traps in `MedianOracle` | WP-529 | **confirmed** | **blocking**: §9.3 (line 1684), a numbered rule; brief rule 6 | yes, Debug and Release | **Probes:** `t529OracleReflectedOverflowingSum`, `…ReflectedLargestCount`, `…FilterLargestKernel` and `…RunningLargestKernel` each ended with status 65 in Debug and in Release.<br>- In every log the test's output stops at its `VBT call` line, for example "VBT call WP-529 MedianOracle.reflected(Int.max - 2, count: Int.max / 2)". Then comes "Restarting after unexpected exit, crash, or test timeout".<br>- Where a relaunch ran the test again, it died on the same call. The runs that died on three launches end "Exceeded max restart count of 2. (Underlying Error: Crash: xctest)": ReflectedLargestCount and FilterLargestKernel in Debug, all four in Release. The other two Debug runs list the test under "Failing tests": ReflectedOverflowingSum died on one launch and RunningLargestKernel on two, and their last launch ran no test.<br>- Each launch ended within 3 s of its start (the longest took 2.9 s), and neither the probes nor `xc.sh` set a time limit, so these are crashes, not timeouts.<br>**Reading `MedianOracle.swift`:**<br>- `:27` `2 * count` overflows for `count: Int.max`.<br>- `:28` `(index % period) + period` overflows for `reflected(Int.max − 2, count: Int.max / 2)`, where the period is Int.max − 1.<br>- `:54` and `:83` allocate `kernel` values for `kernel: Int.max`, which the guards at `:50` and `:81` accept as "odd, at least 1" (`:46`).<br>All these inputs are ones the documentation accepts.<br>**Scope:** `MedianOracle` is public in a public product (`Package.swift:35`; EXT-3, line 944; §4.2, line 226).<br>**CR:** none applies. CR-023 item 16 lists `MedianOracle` as an addition only; CR-024 items 8 and 10 bound plans |
| B-14 VIS-2, the mask strategy | WP-530 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 10 of 18 public symbols fail.<br>**Reading:**<br>- `MaskStrategy.swift:5` gives neither a context nor allocation.<br>- `:27`, `:32` (which says "Control context"), `:57`, `:109` and `:125` have no allocation statement.<br>- `:45` and `:65`, the `validate()` witnesses, have no comment of their own. They inherit that of `:32`, which says nothing on allocation.<br>- `:61` and `:110` (the initialisers) have no comment |
| B-15 RT-7 layer 2, `HardMask.mask` | WP-530 | **confirmed** | **blocking**: RT-7 (§5.6, lines 706-708), a numbered rule; precedent: B-14 of WP-117/WP-119 in `audit-m1-B.md` | yes | **Grep:** `grep -c ZTRONDSP_PERF_ANNOTATIONS MaskStrategy.swift` gives 0. In `Sources`, only `ConstantQNodes.swift` (1) and `Vector.swift` (15) use the setting.<br>**Reading:** `HardMask.mask` (`:112-119`) is a `while` loop that calls nothing, and it runs on the analysis thread.<br>**Trial:** I ran `VerifierB/rt7-trial.sh`, which works in `.build/rt7` only. It prints "ok    the package builds with the setting on: its annotated leaf loops are clean" and "check-perf-annotations.sh exit 0". The output equals `VerifierB/rt7-trial.out` except for the `+++` header line of the diff (its time) and a trailing `exit 0` line in the recorded copy |
| B-16 the mask strategy runs on the analysis thread | WP-530 | **confirmed** | **blocking**: public API differs from §5.11.1 (line 894), and the change request misdescribes it (§11.6; the brief's CR rule) | yes (by reading, the commands of the reproduction) | **The specification:** §5.11.1's table header (line 886) is "To add \| Conform to, or use \| Runs on \| Supplies". Its row reads "A design or a strategy \| … (§5.3) \| Control context \| The protocol's members", and §5.3 (line 585) names `MaskStrategy`.<br>**The code:** `MaskStrategy.swift:25-26` says "`mask` runs on the analysis thread", and the requirement at `:39-41` says "Analysis thread: it allocates nothing and takes no lock (RT-2)". The node's `process` (`HarmonicPercussiveNode.swift:135`) calls it through `masks.mask` (`:174`), which calls `strategy.mask` at `:34` and `:41`.<br>**The CR:** CR-023 item 10 (line 24) says only that a conformer written outside the package works. Item 16 (line 30) lists `MaskStrategy` among additions "the specification does not name", although §5.3 names it. The sections affected (line 48) omit §5.11.<br>**The sibling strategies of the batch keep the rule:** `TempogramMethod.makeTransform` (`Tempogram.swift:18`) and `MedianStrategy.makeFilter` (`MedianStrategy.swift:57-58`) run on the control context |
| B-17 margin × median overflows | WP-530, WP-612 | **confirmed** | **blocking**: a wrong result (§6.10, line 1262) | yes, Debug and Release | **Verifier's probe `vb612EdgeCasesOfTheData`:** output identical to the record. `edge_wp612.py` on my own data gives:<br>- case `gfm-m2`: "mask.harmonic: differs at 64 of 64 values … got 0.0, the definition 0.2", and residual 1.0 against 0.6<br>- case `half-gfm-m3`: harmonic 0.0 against 0.1, and residual 0.5 against 0.4<br>**My input:** 10³⁸ everywhere, soft power 2.<br>- Margins of 3 (product 3·10³⁸, inside the range) give 0.1 and 0.1, as the definition does.<br>- Margins of 4 (4·10³⁸) give 0.0 and 0.0, where the definition gives 1/17 = 0.0588.<br>**Cause:** `vDSP_vsmul` in `Float` at `HarmonicPercussiveNode.swift:33` and `:40`. The offline path shares it (`OfflineSeparation.swift:109`, `SeparationMasks`) |
| B-18 `vDSP_vdiv` on subnormal medians | WP-530, WP-612 | **confirmed** | **blocking**: a wrong result (§6.10; `SoftMask`'s own documentation, "whatever the level of the spectrum", `MaskStrategy.swift:53-54`) | yes, Debug and Release | **Verifier's probe `vb530SoftMaskOnSubnormalMedians`:** output identical to the record.<br>**My input:**<br>- `vDSP_vdiv` of x by x gives −inf for 1e-40, 1e-39 and 2.5e-39, and 1.0 from 3e-39 on.<br>- `SoftMask().mask` on equal medians of 1e-40 … 2.5e-39, under a floor of 0, gives 0.0 where the definition gives 0.5. From 3e-39 on it gives 0.5.<br>**Validity:** a floor of 0 is valid input (`HarmonicPercussive.check`, `Steps/HarmonicPercussive.swift:119`) |
| B-19 VIS-2, `HarmonicPercussive` | WP-531a | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 6 of 19 public symbols fail.<br>**Reading:**<br>- `:53` has no allocation statement.<br>- `:71` (`init`) has no comment.<br>- The comments of `:182` ("On the complex spectrum of an STFT…") and `:189` ("On magnitudes, on any axis…") state neither a context nor allocation.<br>- `:198` and `:209` say "see ``HarmonicPercussive``" |
| B-20 margins and floor narrowed to `Float`, live | WP-531a (shared by 531b and 532) | **confirmed** | **blocking**: a wrong result against the documented rule (`Steps/HarmonicPercussive.swift:19-23`) | yes | **Verifier's probes `vb531aLiveMarginAboveTheFloatRange` and `vb531aLiveFloorBelowTheFloatRange`:** output identical to the record.<br>- Margins of 1e39 and of the largest `Double` become `Float` inf. They give a percussive share of 0.5 (soft) or 0.0 (hard), where the finite margins tried, 1 and 3.4e38, give 1.0.<br>- Floors of 5e-324, 1e-46 and 7e-46 become `Float` 0. With the soft mask they give the floor-0 rule (harmonic 16, residual 0), where 1e-45 and 1e-10 give harmonic 0 and residual 32.<br>**My input:** a burst alone in time and frequency, through `STFT(64, 64, rectangular); Magnitude(); HarmonicPercussive(.harmonic, 3, 3)`. A floor of 1e-300 gives `[16.0]` at bin 16; a floor of 1e-45 gives nothing.<br>**Cause:** `check` (`:108-123`) accepts both floors, and the lowering narrows them at `:162` |
| B-21 VIS-2, `HPSS` | WP-532 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 5 of 7 public symbols fail.<br>**Reading:** `HPSS.swift:43` says "An immutable value, usable on any thread." `:44` and `:45` (the typealiases) and `:50` (`init`) have no comment. `:73` says "see ``HPSS``" |
| B-22 VIS-2, the inversion functions | WP-539 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 4 of 12 public symbols fail (V3).<br>**Reading:** `RateInversions.swift:14` and `:36`, and `StageInversions.swift:267` (its comment at `:264`), state BG-1 and nothing on allocation.<br>**One inaccuracy in the evidence:** `Decibels.inverse(of:)` (`StageInversions.swift:256`) does not state BG-1. Its context comes from its type's comment ("usable on any thread", `SpectralValues.swift:78-79`). The allocation statement is missing all the same, so the finding stands |
| B-23 traps in the rate reports | WP-539 | **confirmed** | **blocking**: §9.3; brief rule 6 | yes, Debug and Release | **Probes:** `t539SubsamplingFactorLargest`, `t539SubsamplingPhaseWithLargestFactor` and `t539UpsamplingFactorLargest` each ended with status 65 in Debug and in Release. Each log stops at the probe's `VBT call` line, followed by "Restarting after unexpected exit, crash, or test timeout". `t539UpsamplingFactorLargest` died on three launches and ends "Crash: xctest" in both configurations; the two subsampling probes list the test under "Failing tests".<br>**Reading `RateInversions.swift`:**<br>- Phase 0: `:44` gives `0 + Int.max` without overflow, and then `:50` traps on `2 * factor`.<br>- Phase 1: `:44` traps on `(1 % Int.max) + Int.max`.<br>- Upsampling: `RateChange.swift:24` traps on `samples.count * factor`.<br>Both entries document only "a factor is at least 1" (`:15`, `:39`) |
| B-24 the upsampling report's sample rate | WP-539 | **confirmed in part** | **non-blocking** (§1.4) | yes | **Verifier's probes `t539UpsamplingSampleRate` and `t539SubsamplingSampleRate`:** output identical to the record.<br>**My input:** `inversionReport(ofUpsampling:)` with a sample rate of NaN, +inf, −1 or 0 returns a report whose `sampleRate` is that value. `ofSubsampling` throws `invalidParameter(sampleRate)` for each.<br>**Verdict:** the behaviour stands; the rule cited does not cover it. No number is computed from the rate, and the only non-finite values are the caller's own, stored. See §1.4 |
| B-25 a full-range signal through the rate reports | WP-539 | **confirmed** | **blocking**: NUM-1 and a wrong result (`InversionReport.swift:70-71`: infinite means "exact bit for bit") | yes, Debug and Release | **Verifier's probe `t539FullRangeSignal`:** identical to the record in Debug. My Release run equals my Debug run; the verifier ran it in Debug only.<br>- On gFM × noise, `ofSubsampling` reports "SNR -inf … non-finite numbers other than the SNR: 2".<br>- `Decimate(by: 2).inversionReport` reports "SNR inf … non-finite numbers other than the SNR: 2". That claims an exact round trip whose largest error and relative error are not finite.<br>- 2⁶³ × noise and subnormal × noise give finite reports.<br>**Reading:** `InversionReport.swift:114` maps a NaN error sum to `.infinity` (`noise > 0 ? … : .infinity`), and `RateInversions.swift:148` narrows the interpolation with `Float(sum)`.<br>**Note:** the "BL-13" the evidence cites is not defined anywhere in the checkout (§4) |
| B-26 VIS-2, the GPU median and the offline entries | WP-612 | **confirmed** | **blocking**: VIS-2 | yes | **Script:** 6 of 14 public symbols fail.<br>**Reading:**<br>- `MedianStrategy.swift:131` and `:179` say "usable on any thread" and nothing on allocation.<br>- `:140` and `:182` (`init()`) have no comment.<br>- `OfflineSeparation.swift:34` states BG-1 (`:18`). `:55` takes "the threading" from it. Neither says anything on allocation |
| B-27 non-finite magnitudes: GPU ≠ CPU | WP-612 | **confirmed** | **blocking**: the row's acceptance "results ≡ CPU" (line 2140) and GPU-3 (line 1384) fail on input that both entries accept (§1.4) | yes, Debug and Release | **Verifier's probe `vb612NonFiniteData`:** output identical to the record.<br>- One NaN among 192 values: the time and frequency medians differ between GPU and CPU at 5 places each. The masks differ at 9, 9 and 3 values, the components at 8, 8 and 2. `.automatic` below and above its crossover differs at 8 of 192 values.<br>- −NaN: 5, 5; 6, 6, 3; 5, 5, 2; and 5.<br>- ±inf: the two sides agree. ±inf comes out in the harmonic and percussive components and NaN in the residual.<br>**My input:** one NaN among 200 values (20 frames of 10 bins, kernels 5 and 5). The harmonic masks of `.selectionNetwork` and `.metal` differ at 8 of 200 values, and the percussive masks at 8. Neither side's masks hold a NaN |
| B-28 margins and floor narrowed, offline | WP-612 | **confirmed** | **blocking**: a wrong result against the documented rule (`Steps/HarmonicPercussive.swift:21-22`, to which `OfflineSeparation.swift:29` refers) | yes, Debug and Release | **Verifier's probes `vb612TrapHarmonicMargin` and `vb612TrapFloor`:** output identical to the record.<br>- A harmonic margin of the largest `Double` or of 1e39 gives a soft harmonic mask of 0.5 at the lit bin (hard: 0.0), where 3.4e38 gives 1.0.<br>- Floors of 5e-324, 1e-46 and 7e-46 give soft masks of 0.5 and 0.5 at the spike, where 1e-45 gives 0 and 0.<br>**My input:**<br>- A floor of 1e-300 (`Float` 0.0) gives masks of 0.5 and 0.5 at a spike. The documented result for any positive floor is 0 and 0, and a floor of 1e-45 gives that.<br>- A harmonic margin of 1e300 (`Float` inf) gives 0.5 at a lit bin, where a margin of 1e30 gives 1.0.<br>**Cause:** the narrowing at `OfflineSeparation.swift:96-98` |
| B-29 more than 2²⁴ bins: no CPU fall-back | WP-612 | **confirmed** | **blocking**: GPU-3 (line 1384), SEL-6 (line 1447), the row's acceptance "results ≡ CPU" | yes (by reading for the crossover part) | **Verifier's probes `vb612LargestBinCount`, `vb612TrapBinCount` and `vb612TrapStrategyFilter`:** output identical to the record.<br>- At 2²⁴ + 1 bins, `.metal` and `.automatic` return 16 777 217 values. `.selectionNetwork`, and `.automatic` without a device, throw "invalidParameter(length): a lane holds between 1 and 2²⁴ values, not 16777217".<br>- At 2²⁴ bins all four return the same values bit for bit.<br>- With no values and a bin count of Int.max, `MetalMedian` returns empty masks; the other two throw.<br>**Reading:**<br>- The CPU bound is at `MedianKernels.swift:45-46`, and `MetalMedianFilter.swift:64-72` has none.<br>- `AutomaticMedian.filter` (`MedianStrategy.swift:207-219`) falls back only on `backendUnavailable` and `resourceAllocationFailed`. A crossover above the size therefore takes the CPU call that throws, against line 2232: "A wrong crossover costs speed, never correctness".<br>- Neither entry documents the bound in its Throws (`OfflineSeparation.swift:31-33`) |

### 1.1 The VIS-2 findings (B-1, 3, 5, 7, 9, 10, 11, 12, 14, 19, 21, 22, 26)

VIS-2 (line 961) asks that every public symbol be "documented with its threading contract: which context may call it, and whether it may allocate". Brief rule 1 makes a missing statement blocking in every package alike. It counts a statement on the type that says it covers its members.

For every flagged symbol I printed its comment (`doc_above.py`) and read it:

- None of these symbols says whether it allocates.
- None of their types carries a statement that covers its members. "An immutable value, usable on any thread" gives a context, and nothing on allocation.
- CR-023 item 16 lists most of these symbols as additions to the surface. It says nothing of their contracts.

All thirteen findings stand as filed.

One point for whoever writes the fix. For three protocols the allocation contract is given only by their requirements: `TempogramMethod` (`Tempogram.swift:15`, whose `makeTransform` allocates), `MedianStrategy` (`MedianStrategy.swift:56`) and `MaskStrategy` (`MaskStrategy.swift:27`). The script still flags the protocol type itself (V3), which reads brief rule 1 to the letter. B-10, B-12 and B-14 stand on their other symbols whatever is made of that.

### 1.2 The overflow findings (B-2, B-4, B-6, B-8, B-17, B-25)

NUM-1 (line 1005) is "No NaN, no infinity". SEL-6 (line 1447) says that implementations of one primitive agree within 10⁻⁶ relative, and that "Choosing by size never changes what a pipeline computes beyond that".

In each of these cases every input is finite, and the exact result lies inside the range of `Float` (for B-25, the signal). With inputs of my own below gFM (`[1e38, 1e38]`, `4 × 1e19`, margins of 4 on 1e38), the strategies still disagree. One of three things fails: the transform paths, the `Float` sums before the division, or the `Float` margin product. The result is NaN, ±inf, or a share of 0. These are wrong results under §11.6, and no CR describes them.

### 1.3 The trap findings (B-13, B-23)

Each trap probe ran in a process of its own, as brief rule 6 asks. All seven ended with status 65 in both configurations. The process exited right after the probe's own `VBT call` line. Every relaunch that ran the test again exited at the same line, and a relaunch that ran no test ended the run. No launch lasted more than 3 s.

§9.3 allows no trap that is reachable from public API through invalid input. These inputs are not even invalid: they lie inside what the functions document (a count above 0, a factor of at least 1, an odd kernel of at least 1).

### 1.4 Where I depart from the verifier: B-24, and the reading behind B-27

**B-24 is confirmed in part, and non-blocking.** I reproduced every fact:

- `inversionReport(ofUpsampling:by:sampleRate:)` accepts any sample rate and stores it as the report's `sampleRate`. The verifier's probe used NaN, ±inf, ±0, −gFM and a subnormal; mine used −1.
- Its sibling refuses such rates (`RateInversions.swift:40-42`), and so does every `InvertibleStage` report (`InversionReport.swift:285-287`).
- The MATLAB export writes the rate (`Export/FrameExports.swift:175`) and divides an axis by it (`:180`).

What does not stand is the rule. NUM-1 (line 1005) concerns what the library computes: "Every division states its result for a zero or sub-floor denominator, and every logarithm has a floor", and a non-finite sample from a source is replaced at the source adapter. Brief rule 6 reads NUM-1 as "no NaN and no infinity out". Even under that reading the finding does not stand:

- For the values rule 6 has the verifier probe (±gFM, a subnormal, ±0), the report holds no non-finite number other than its documented SNR: "non-finite numbers other than the SNR: 0".
- −gFM, ±0 and −1 are finite numbers.
- A NaN or an infinity comes back only when the caller passes one in. It comes back unchanged, and nothing is computed from it.

No numbered rule of §4–§10 requires a toolkit function to refuse a parameter that it only stores. The acceptance this function touches is WP-537's (line 2116: "A report for an exact pair … is exact; it runs on `BackgroundWork`"), and it holds. §9.3 asks for no trap, and there is none.

It is an inconsistency worth fixing: validate the rate as the sibling does. It belongs in the backlog, and it does not hold the package.

**B-27 is confirmed and blocking. I weighed the counter-reading.**

The counter-reading: the entries' parameter documentation says the magnitudes come "as a `FeedSnapshot` holds them; not negative" (`OfflineSeparation.swift:22-23`). That could be read as excluding NaN. The GPU filter also documents unspecified results for NaN (`MetalMedianFilter.swift:52-53`).

I do not take that reading:

- The entries refuse nothing, and their Throws lists no such case.
- They promise "The result is the same value for value (GPU-3)" without condition (`:28`).
- The row's acceptance, "results ≡ CPU", is also without condition.
- §7.5 row 16 (line 1472) names non-finite values as the hazard of median filtering, and gives "NUM-1 keeps non-finite values out" as the mitigation. This public path has no source adapter, so the mitigation is absent.

So an acceptance statement of the row fails on input that the public API accepts. That is blocking under §11.6.

## 2. Gaps in the verification (duty 2)

What the reports do cover:

- **All 15 reports exist.**
- **Every report:** each acceptance check of each row says how it was run and what came back.
- **The lens-T reports** (WP-514, WP-539, WP-541): for every check, the line changed and the tests that then failed. They also give COV-3 per file, seeding and determinism, and the negative paths.
- **The lens-N report** (WP-612): every edge case of the brief at both entries, the precision choice, and an independent reference.
- **The lens-R reports:** the allocation audit in Debug and Release, with a mutant that makes it fail; the RT rules that apply; complexity; SEL-3 or SEL-4; and the benchmark (none recorded, filed for the backlog as BL-5).

Two things are missing:

1. **STG-1's "latency and settling time" is not reported for the steps.** WP-515, WP-516, WP-525, WP-526 and WP-527 report neither; WP-531a and WP-532 report only the latency.
   - **The duty:** STG-1 (line 1836) has every package that delivers a stage, a step or a recipe deliver "its latency and settling time". The brief tells the verifier to "check it for each step".
   - **What the reports say:** the STG-1 rows of WP-515 and WP-525 name the spelling, `isActive:`, the order rule, cold start and the gates. The reports of WP-516, WP-526 and WP-527 do not mention latency or settling at all.
   - **WP-515, WP-525, WP-526, WP-527 and WP-531a:** the tests the reports cite do assert both. They are `aColdStartFramesTheSequenceAgainFromNothing` (`AutocorrelationStepTests.swift:211`), `aColdStartForgetsTheFramesItComparedWith` (`OnsetStrengthTests.swift:206`), `aCentredColumnIsTheCausalOneOfHalfAWindowLater` (`TempogramTests.swift:214-223`, both methods) and `theLookAheadIsLatencyAndFramesKeepTheirTimes` (`HarmonicPercussiveTests.swift:100`). For these packages the statement is missing, not the evidence.
   - **WP-516 and WP-532:** neither the report nor any test states the settling time of the `Convolve` stage or of the `HPSS` recipe. I grepped every `settlingFrames` assertion in `Tests`. Latency 0 of the stage is asserted (`ConvolveStageTests.swift:61-66`, `:82`, `:96`, `:105`, `:115`), and so is the latency of the recipe (`theLatencyIsOneFrameLessAHopPlusTheLookAhead`).
2. **WP-612, lens N: "no tolerance was loosened to make a test pass" is passed over in silence.** §11.5 N (line 1796) and the brief's lens N both list it. The report never mentions a tolerance, and the duty is not empty: the package's tests hold tolerances, for example `OfflineSeparationTests.swift:198` (`worst <= 1e-6` of the frame maximum).

Neither gap changes a verdict. Every package concerned is already blocking, and WP-531b, which passes, reports both latency and settling time.

## 3. Spot checks: five `pass` verdicts, where the evidence was thinnest

I ran each check myself after the probe build: Debug, one test per process, results in `.build/audit-spot`. All five hold.

1. **WP-539, "an aliasing fixture fails, the aliased energy within 1 dB of the truth: subsampling".** The report says "the test prints no figure".
   - `InversionTests.anAliasingFixtureFailsWithTheAliasedEnergyWithinOneDecibel(inBand:above:)` passes all 4 cases.
   - My own probe (`audSpot539AliasingSubsampling`) builds the same four fixtures. It computes the true share both from the amplitudes and from the signal's own DFT at 1 kHz and 9 kHz, and compares the report against it.
   - The condition fails in each case. The observed share lies 2.3·10⁻⁸, 3.4·10⁻⁷, 3.0·10⁻⁹ and 1.2·10⁻⁶ dB from the truth.
   - The predicted error lies within 1.5·10⁻⁷ relative of √(2·truth), for example 0.14071951 against 0.14071951.
   - The measured SNRs are −1.5·10⁻⁵, 17.03, −2.75 and 43.01 dB. Each is within 0.001 dB of −20·log₁₀ of the predicted error.
2. **WP-541 (`pass`), "0 allocations over 10⁴ blocks".** `FullAnalysisAuditTests` ran with both tests passing.
   - The output reads "10 000 blocks of 512 frames (106.66666666666667 s of signal) … processing time ÷ audio time 0.011433775003124999 … 0 allocation(s) of 0 byte(s), 0 deallocation(s)". The paced test also passed.
   - The time figure, 0.0114, is below the verifier's Debug figures of 0.0214 to 0.0226. It is printed and recorded, not asserted.
3. **WP-531b (`pass`), "≡ offline; latency equals the look-ahead".**
   - `theCentredStepEqualsTheOfflineSeparation(caseIndex:)` passed its 3 cases. It printed: "music, kernels 5 and 3: 84 frames of 513 bins equal the offline separation exactly, for each component", 77 frames for speech with kernels 17 and 31, and 71 frames for music with kernels 31 and 31. These are the verifier's figures.
   - `theLookAheadIsLatencyAndFramesKeepTheirTimes` and `HPSSTests.theLatencyIsOneFrameLessAHopPlusTheLookAhead` passed.
4. **WP-532, "a bound switch meets CLICK-1 and keeps the latency".** `aBoundSwitchMeetsCLICK1AndKeepsTheLatency(alignment:)` passed both cases. It printed "(ratio 1.0; the limit is 1.5)" for off and for on, causal and centred, as the report says.
5. **WP-612, "`.metal` without a device is `backendUnavailable`".** `metalWithoutADeviceIsBackendUnavailable` and `automaticFallsBackToTheCPUWithoutADevice` passed.

## 4. Observations for the integrator (not gaps)

- **WP-531b passes while sharing WP-531a's finding 2.** The narrowing of the margins and the floor (B-20) happens in the lowering, which the centred step also uses. The verifier says so, and files the finding once, under WP-531a, because the line belongs to WP-531a. That is defensible. Once B-20 is fixed, the fix should also be re-verified on the centred path (FIX-1).
- **Backlog identifiers.** The reports cite backlog items that no file in the checkout defines: BL-1, BL-3, BL-5, BL-9, BL-10, BL-12 and BL-13. The ledger's Backlog cells for all 15 rows are empty. The brief has the verifier put its non-blocking findings in its final result as a backlog list. These ids presumably number that list, which I was not given; the integrator should file them from there.
- **The B-16 pattern outside the batch.** `ChromaNormalization` (WP-524) is a §5.3 strategy. Its documentation says `norm(of:)` "is called on the analysis thread" (`Steps/ChromaFold.swift:7-8`), and the chroma node calls it there (`Nodes/ChromaNodes.swift:59`). CR-022 item 8 says nothing about this. I did not audit WP-524; this is for whoever does.
- **The verifier's reproductions write into its own evidence.** `VerifierB/run-probes.sh` points the data probes at `VerifierB/out` (`TEST_RUNNER_ZTD_VB_OUT`). Running the reproductions as written therefore rewrites the verifier's recorded data files. I used the runner of Appendix B instead. It wrote the same 136 files elsewhere, byte for byte equal.

## Appendix A — the auditor's probes (`AuditM5bProbes.swift`, as last built; removed from `Tests` after the runs)

```swift
import Accelerate
import Foundation
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPMetal
import ZTronDSPTesting

// Auditor of Verifier B, M5b: independent probes with inputs of the auditor's own choosing,
// beside the verifier's. Not part of the delivery: copied into Tests/ZTronDSPAnalysisTests/
// for one build, removed afterwards, the tree compared byte for byte with .build/pristine.
// Every line printed begins with "AUD ".

private func aud(_ text: String) {
    FileHandle.standardOutput.write(Data(("AUD " + text + "\n").utf8))
}

private func tally(_ values: [Float]) -> String {
    let nan = values.filter { $0.isNaN }.count
    let inf = values.filter { $0.isInfinite }.count
    let largest = values.filter { $0.isFinite }.map { abs($0) }.max() ?? 0
    return "n=\(values.count) NaN=\(nan) inf=\(inf) maxFinite=\(largest)"
}

@Suite("Auditor probes, M5b", .serialized)
struct AuditM5bProbes {
    /// B-2, B-4: [1e38, 1e38] with [1, 1]. Exact full convolution [1e38, 2e38, 1e38], all inside
    /// the Float range (gFM = 3.40282e38); the correlation is the same here; the coefficient
    /// normalisation gives [0.5, 1, 0.5].
    @Test func audB2B4TransformOverflowBelowGFM() throws {
        let x: [Float] = [1e38, 1e38], h: [Float] = [1, 1]
        for strategy in ConvolutionStrategy.allCases {
            aud("B-2 convolve [1e38,1e38]*[1,1] \(strategy): \(try DSP.convolve(x, h, strategy: strategy))")
            aud("B-4 correlate [1e38,1e38],[1,1] none \(strategy): \(try DSP.correlate(x, h, strategy: strategy))")
            aud("B-4 correlate [1e38,1e38],[1,1] coefficient \(strategy): \(try DSP.correlate(x, h, normalization: .coefficient, strategy: strategy))")
        }
    }

    /// B-6: four values of 1e19. r[l] = (4 - l)·1e38: lag 0 (4e38) is past the range as a sum,
    /// but biased [1e38, 7.5e37, 5e37, 2.5e37], unbiased [1e38 x4] and coefficient
    /// [1, 0.75, 0.5, 0.25] are all inside it.
    @Test func audB6SumsOverflowBeforeTheDivision() throws {
        let x = [Float](repeating: 1e19, count: 4)
        for strategy in ConvolutionStrategy.allCases {
            for normalization in CorrelationNormalization.allCases {
                aud("B-6 autocorrelate 4x1e19 \(normalization) \(strategy): \(try DSP.autocorrelate(x, maxLag: 3, normalization: normalization, strategy: strategy))")
            }
        }
        // The step on a constant of 1e19 (window 8, hop 8): biased lag 0 is exactly 1e38.
        let constant = [Float](repeating: 1e19, count: 64)
        for normalization in CorrelationNormalization.allCases {
            let frames: [[Float]] = try Pipeline { Autocorrelation(window: 8, hop: 8, maxLag: 3, normalization: normalization) }
                .process(constant, format: SignalFormat(sampleRate: 48_000))
            aud("B-6 step 1e19 constant \(normalization): \(frames.count) frames; last \(frames.last ?? []); \(tally(frames.flatMap { $0 }))")
        }
    }

    /// B-8: the stage with a kernel [1e38, 1e38] on a signal of ones: exact output 1e38, then 2e38.
    @Test func audB8StageOverflowBelowGFM() throws {
        let ones = [Float](repeating: 1, count: 1_024)
        for strategy in ConvolutionStrategy.allCases {
            let out: [Float] = try Pipeline { Convolve(kernel: [1e38, 1e38], strategy: strategy) }.process(ones, format: SignalFormat(sampleRate: 48_000))
            aud("B-8 Convolve [1e38,1e38] on ones \(strategy): first \(Array(out.prefix(3))); \(tally(out))")
        }
    }

    /// B-17: a constant spectrogram of 1e38 with margins 3 (3e38, inside the range) and 4
    /// (4e38, past it). Soft power 2: the definition gives 1/(1 + m²) for each mask.
    @Test func audB17MarginProductOverflow() async throws {
        let values = [Float](repeating: 1e38, count: 64)
        for margin in [3.0, 4.0] {
            let masks = try await DSP.harmonicPercussiveMasks(of: values, binCount: 8, timeKernel: 3, frequencyKernel: 3, mask: .soft(power: 2),
                                                              harmonicMargin: margin, percussiveMargin: margin, median: .selectionNetwork)
            aud("B-17 1e38 everywhere, margins \(margin): harmonic \(masks.harmonic[27]) percussive \(masks.percussive[27]); definition \(1 / (1 + margin * margin)) each")
        }
    }

    /// B-18: vDSP_vdiv on equal subnormal values, and the soft mask on them under a floor of 0.
    @Test func audB18SubnormalDivision() {
        let a: [Float] = [1e-40, 1e-39, 2.5e-39, 3e-39, 1e-38, 1.2e-38]
        var ratio = [Float](repeating: -7, count: a.count)
        vDSP_vdiv(a, 1, a, 1, &ratio, 1, vDSP_Length(a.count))
        aud("B-18 vDSP_vdiv x/x for \(a): \(ratio)")
        var mask = [Float](repeating: -7, count: a.count)
        SoftMask().mask(a, against: a, floor: 0, into: &mask, count: a.count)
        aud("B-18 SoftMask equal medians \(a), floor 0: \(mask) (definition 0.5 each)")
    }

    /// B-20, B-28: Double parameters that are normal Doubles but not Floats: a floor of 1e-300
    /// and a harmonic margin of 1e300.
    @Test func audB20B28NarrowedParameters() async throws {
        var spike = [Float](repeating: 0, count: 81)
        spike[40] = 0.5
        for floor in [1e-300, 1e-45] {
            let masks = try await DSP.harmonicPercussiveMasks(of: spike, binCount: 9, timeKernel: 3, frequencyKernel: 3, floor: floor, median: .selectionNetwork)
            aud("B-28 spike, floor \(floor) (Float \(Float(floor))): masks at the spike \(masks.harmonic[40]) \(masks.percussive[40]); documented 0 and 0 for a floor above 0")
        }
        let lit = (0 ..< 9).flatMap { _ in (0 ..< 9).map { $0 == 4 ? Float(0.5) : 0 } }
        for margin in [1e300, 1e30] {
            let masks = try await DSP.harmonicPercussiveMasks(of: lit, binCount: 9, timeKernel: 3, frequencyKernel: 3, harmonicMargin: margin, median: .selectionNetwork)
            aud("B-28 lit bin, harmonicMargin \(margin) (Float \(Float(margin))): harmonic \(masks.harmonic[40]); definition 1 for any finite margin")
        }
        // The live step with the same floor, on magnitudes of a burst alone in time and frequency.
        var signal = [Float](repeating: 0, count: 64 * 20)
        let pattern: [Float] = [1, 0, -1, 0]
        for n in 0 ..< 64 { signal[64 * 10 + n] = pattern[n % 4] }
        for floor in [1e-300, 1e-45] {
            let out: [[Float]] = try Pipeline {
                STFT(frame: 64, hop: 64, window: .rectangular); Magnitude()
                HarmonicPercussive(select: .harmonic, timeKernel: 3, frequencyKernel: 3, floor: floor)
            }.process(signal, format: SignalFormat(sampleRate: 48_000))
            aud("B-20 live burst, floor \(floor): harmonic at bin 16 of each frame \(out.map { $0[16] }.filter { $0 != 0 })")
        }
    }

    /// B-27: one NaN in a spectrogram of 20 frames of 10 bins, CPU lanes against the GPU.
    @Test func audB27NaNOnBothSides() async throws {
        _ = try await MetalContext.shared()
        var values = (0 ..< 200).map { Float(0.2) + Float($0 % 37) * 0.01 }
        values[7 * 10 + 3] = .nan
        let cpu = try await DSP.harmonicPercussiveMasks(of: values, binCount: 10, timeKernel: 5, frequencyKernel: 5, median: .selectionNetwork)
        let gpu = try await DSP.harmonicPercussiveMasks(of: values, binCount: 10, timeKernel: 5, frequencyKernel: 5, median: .metal)
        let h = zip(cpu.harmonic, gpu.harmonic).filter { $0.bitPattern != $1.bitPattern }.count
        let p = zip(cpu.percussive, gpu.percussive).filter { $0.bitPattern != $1.bitPattern }.count
        aud("B-27 one NaN: harmonic masks differ at \(h) of 200, percussive at \(p); cpu \(tally(cpu.harmonic + cpu.percussive)); gpu \(tally(gpu.harmonic + gpu.percussive))")
    }

    /// Spot check of WP-539 (pass, "the test prints no figure"): the subsampling report on the four
    /// aliasing fixtures of InversionTests, the deviation from the true aliased share in decibels.
    /// The tones are whole cycles over 48 000 samples, so the true share is a²/(b² + a²).
    @Test func audSpot539AliasingSubsampling() async throws {
        for (inBand, above) in [(0.3, 0.3), (0.5, 0.05), (0.1, 0.4), (0.4, 0.002)] {
            let signal = (0 ..< 48_000).map { n -> Float in
                let t = Double(n) / 48_000
                return Float(inBand * sin(2 * .pi * 1_000 * t)) + Float(above * sin(2 * .pi * 9_000 * t + 0.7))
            }
            // The energies of the two tones in the Float signal itself, by a DFT at the two frequencies.
            func energy(at frequency: Double) -> Double {
                var re = 0.0, im = 0.0
                for (n, value) in signal.enumerated() {
                    let phase = 2 * Double.pi * frequency * Double(n) / 48_000
                    re += Double(value) * cos(phase); im -= Double(value) * sin(phase)
                }
                return re * re + im * im
            }
            let low = energy(at: 1_000), high = energy(at: 9_000)
            let truth = above * above / (inBand * inBand + above * above)
            let report = try await DSP.inversionReport(ofSubsampling: signal, by: 4, sampleRate: 48_000)
            let condition = report.conditions[0]
            let deviation = abs(10 * log10(condition.observed / truth))
            aud("spot WP-539 subsampling (\(inBand), \(above)): holds \(condition.holds); observed share \(condition.observed); truth \(truth) (from the signal's own DFT \(high / (low + high))); \(deviation) dB apart; predicted \(report.predictedError) vs sqrt(2·truth) \(sqrt(2 * truth)); measured SNR \(report.measuredError?.signalToNoiseRatio ?? .nan) dB")
        }
    }

    /// B-24: the sample rate of the upsampling report.
    @Test func audB24UpsamplingSampleRate() async throws {
        for rate in [Double.nan, .infinity, -1, 0] {
            do {
                let report = try await DSP.inversionReport(ofUpsampling: [1, 2, 3, 4], by: 2, sampleRate: rate)
                aud("B-24 ofUpsampling sampleRate \(rate): returned, report.sampleRate \(report.sampleRate)")
            } catch {
                aud("B-24 ofUpsampling sampleRate \(rate): threw \(error)")
            }
            do {
                let report = try await DSP.inversionReport(ofSubsampling: [1, 2, 3, 4, 5, 6, 7, 8], by: 2, sampleRate: rate)
                aud("B-24 ofSubsampling sampleRate \(rate): returned, report.sampleRate \(report.sampleRate)")
            } catch {
                aud("B-24 ofSubsampling sampleRate \(rate): threw \(error)")
            }
        }
    }
}
```

`audSpot539AliasingSubsampling` was added last, for the spot checks, and ran from the second Debug build (05:35). The other tests ran from the first Debug build (05:14). All of them except `audB24UpsamplingSampleRate` ran again from the Release build (05:24), for which the build and the runner set `ZTD_CONFIG=Release`.

## Appendix B — the runner (`.build/audit/run.sh`, each test in a process of its own)

```bash
#!/bin/bash
# Auditor's runner: each named test in a process of its own (one Scripts/xc.sh test-only call),
# the summary and the full log kept under $AUD_RESULTS, and the data probes writing to
# .build/audit/vbout instead of VerifierB/out (so the verifier's files are left as they are).
#
#   AUD_RESULTS=<folder> AUD_SUITE=<suite> AUD_TESTS="a b c" .build/audit/run.sh
#   (a name ending in "/" is run as a whole suite: AUD_TESTS="AuditM5bProbes/")
ROOT="/private/tmp/claude-501/-Users-admin-Documents-ZTronDSP/0a25c87a-503c-4e3f-99b7-72b2d1d73489/scratchpad/wt/v-m5b-b/ZTronDSP"
cd "$ROOT" || exit 1
out="${AUD_RESULTS:?}"
mkdir -p "$out" "$ROOT/.build/audit/vbout"
summary="$out/summary.tsv"
[ -f "$summary" ] || printf 'test\tstatus\tprobe lines\n' > "$summary"
for test in ${AUD_TESTS:?}; do
    case "$test" in
        */) filter="ZTronDSPAnalysisTests/${test%/}"; name="${test%/}" ;;
        *\(*) filter="ZTronDSPAnalysisTests/${AUD_SUITE:?}/$test"; name="${test%%(*}" ;;
        *) filter="ZTronDSPAnalysisTests/${AUD_SUITE:?}/$test()"; name="$test" ;;
    esac
    TEST_RUNNER_ZTD_VB_OUT="$ROOT/.build/audit/vbout" ZTD_DEVICE=ztdsp-27-vm5bb Scripts/xc.sh test-only "$filter" > "$out/$name.out" 2>&1 < /dev/null
    status=$?
    cp "$ROOT/.build/xcode/last-test-without-building.log" "$out/$name.log"
    lines=$(grep -cE "^(VB612|VB530|VB531a|VBT|AUD) " "$out/$name.log")
    printf '%s\t%s\t%s\n' "$name" "$status" "$lines" >> "$summary"
done
```

`.build` is deleted at the end of the audit, so these two appendices are the record of what I ran.
