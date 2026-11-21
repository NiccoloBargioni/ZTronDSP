# Audit of Verifier A — M4, second half (WP-418c … WP-440)

| Field | Value |
|---|---|
| Audited | Verifier A's 24 reports `WP-418c-A.md` … `WP-440-A.md`, with its probes and scripts under `VerifierA/` |
| Revision | the verifier's checkout (main tree snapshot 2026-11-17 22:50, after CR-027). `Sources/`, `Tests/`, `Scripts/` and `Package.swift` are equal to the verifier's `.build/pristine` copy. `Docs/` differs from it only by the 24 reports |
| Auditor | an independent agent session. Nothing that Verifier B wrote was read |
| Simulator | `ztdsp-27-vm4ba` (7695F6F1-6D29-467A-A24D-9D9642AE104D), Debug |
| Date | 2026-11-18 |

## 1. Result

**Blocking findings.** All four are confirmed and reproduced on this revision:

| Finding | Package |
|---|---|
| A-1 | WP-425 |
| A-2 | WP-432c |
| A-3 | WP-434 |
| A-4 | WP-437 |

Each one is blocking by §11.6, and no change request covers any of them.

- **Where the defects are.** A-3 lies in the C layer and A-4 lies in the core. Both show through the stages of these packages.
- **Resolution needs a change request.** A-1 and A-2 each need a change request to be resolved (FIX-4):
  - A-1: no solver can meet the golden tolerance on this fixture as written.
  - A-2: whole-frame kernel latencies cannot carry the half sample that REAL-5 gives for an even K.

**Spot checks.** I checked five passes: WP-422, WP-428b, WP-431c, WP-433 and WP-440. Each reproduces the figures in its report.

**Gaps.**
- Most lens-N reports leave out the edge cases that §11.5 lists: non-finite input (NUM-1), silence, DC and full scale.
- The Octave clause of WP-440 was not run.
- A few figures are thinly supported.

**Severity.** Some non-blocking findings are rated more leniently than §11.6 reads. They are listed apart, in §4, because they could turn passes into blocking verdicts.

## 2. Blocking findings (duty 1)

| Finding | Package | Rule and acceptance | Change request | Reproduced | Verdict | Severity |
|---|---|---|---|---|---|---|
| A-1 | WP-425 | STG-2 ("A tolerance changes only by change request, with the measured error attached"). The oracle table gives "Taps within 10⁻⁹" for WP-423 and WP-425. Row: "Golden; an ill-conditioned fixture takes the fall-back and still meets it" | none | yes | confirmed | blocking |
| A-2 | WP-432c | REAL-5: "(K − 1)/2 for a linear-phase FIR … The sum is the environment's `latency`". Row: "latency reported" | none | yes | confirmed | blocking |
| A-3 | WP-434 | ACT-7 On: "It runs, with its output discarded, for its latency plus its settling time, and only then is faded in". SWAP-2 (settling "declared by each stage"). STG-1 ("its latency and settling time") | none | yes | confirmed | blocking |
| A-4 | WP-437 | F1, and §5.5 step 4: "Fused and unfused plans MUST agree: bit for bit under F1, F2 and F4". Row: "adjacent gains merge (F1)" | none | yes | confirmed | blocking |

**Change requests searched.** I searched all of `Docs/Process/changes/CR-001.md` … `CR-027.md` for these terms: "ill-conditioned", "firls-gap", "relativeToMaximum", "settl", "alpha-beta", "AlphaBeta", "half a sample", "even length", "(K − 1)", "gainCascade" and "ramp".

- Only CR-006 and CR-024 match.
- CR-006 introduces `gainCascade(factors:ramp:)` and says nothing about ramps.
- CR-024 item 4 is about unity gains.
- CR-018 items 5 and 6 concern tolerance schemes and the 4 095-tap cap.
- `Docs/Numerics/fir-design.md` records the 9.9e-6 figure, but it is a stability note, not a change request.

**Sources are pristine.** After my runs, `diff -r Sources .build/pristine/Sources` and `diff -r Tests .build/pristine/Tests` print nothing. Every file the findings name is byte-identical to the main tree `/Users/admin/Documents/ZTronDSP`, with one exception:

- **Exception: `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift`.** The main tree has received a later version since the snapshot.
- **A-4 is still present there.** That version still fuses with `ramp: max(rampA, rampB)` (lines 319–326). It only adds a refusal to fuse ramps that are no count of frames.

### A-1 — WP-425: the ill-conditioned golden fixture is held to 1e-4 of the largest tap, not 1e-9

**What the code does.**
- `Tests/ZTronDSPDesignTests/FIRDesignTests.swift:477-511` asserts three things:
  - the fall-back is taken (`fit.usedFallback`, and a reciprocal condition below the floor);
  - the weighted error is within 1e-6 of the oracle's;
  - the response over the bands is within 1e-7.
- It then holds the taps to `expectClose(fit.taps, oracle, .relativeToMaximum(1e-4))` (line 510).
- The fall-back is `dgelsd` (`Sources/ZTronDSPDesign/FIR/LeastSquaresFIR.swift:~122-133`).

**My run.** Suite `LeastSquaresFIRTests` together with probe `p425`; every test passed. The package records these figures:

| Figure | Value | Bound |
|---|---|---|
| Taps against the oracle's, relative to the largest tap (1 755.19) | 9.949e-6 (about 1.75e-2 absolute) | 1e-4 |
| Weighted error | 1.36e-11 | 1e-6 |
| Response over the bands | 1.51e-8 | 1e-7 |

The bound of STG-2 is 1e-9 absolute, which is 5.7e-13 of the largest tap.

**`python3 -B VerifierA/wp425_ill_conditioned.py` on my output.**
- SciPy's normal matrix has s₃/s₀ = 2.31e-12 and s₅₀/s₀ = 2.14e-19, and Cholesky fails (info 5).
- `gelsd` on SciPy's own matrix lands 6.5e-8 (of the largest tap) away from SciPy's `gelsy`.
- A relative perturbation of 1e-16 moves the taps by 6.3e-6; one of 2e-16 moves them by 1.0e-5.
- The package is 9.947e-6 away from `gelsd` on SciPy's matrix.

**My independent check.** Earlier in this audit I ran a check of my own: normal equations built separately in NumPy.
- Singular values: s₃/s₀ = 2.31e-12, s₄/s₀ = 1.05e-16 and s_min/s₀ = 8.6e-20.
- A perturbation of 1e-16 moves the taps by 7.8e-6; one of 4e-16 moves them by 1.65e-5.

**Judgement.**
- The acceptance as written, with the golden at 1e-9, fails by seven orders of magnitude.
- The test replaces the tolerance without a change request, which STG-2 forbids.
- The taps of this fixture are not determined to 1e-9 by any backward-stable solver. So the fix is a change request (FIX-4), in one of two forms:
  - the tolerance for this fixture, with the measured 9.95e-6 attached;
  - another fixture that still takes the fall-back but whose taps are determined.

**Severity: blocking.** The fixture is accepted by the verifier's evidence. The test is not.

### A-2 — WP-432c: an even-length linear-phase FIR reports ⌊(K − 1)/2⌋

**What the code does.**
- `FIRMath.latency(of:)` uses integer division (`Sources/ZTronDSPDesign/Systems/FIRSystem.swift:268-272`) and reaches the kernel through `Realization.swift:~240`.
- Only the internal comment at lines 264–266 says "rounded down for an even `K`".
- The public documentation says "`(K − 1) / 2` samples":
  - `Stages/ResponseStages.swift:37, 234, 433, 637`;
  - `Stages/Filter.swift:23`;
  - `Systems/FIRSystem.swift:64`.
- The package's own test asserts the floor: `SystemStageTests.swift:273-275`, "K = 100 reports 49".
- Even lengths are in scope. §6.3.3 rejects them only "where the response at Nyquist must be non-zero" (spec line 1055).

**My run.** Suite `FilterStageTests` together with probe `p432`, then `python3 -B VerifierA/wp432_stages.py`.

| Taps (K) | Reported latency | (K − 1)/2 | Group delay of the taps |
|---|---|---|---|
| 100 | 49 (kernel and environment) | 49.5 | 49.5 |
| 256 | 127 | 127.5 | |
| 300 | 149 | 149.5 | 149.5 |
| 2 | 0 | 0.5 | 0.5 |

Odd lengths are exact: 255 gives 127, 1 001 gives 500, 317 gives 158, and the 5 antisymmetric taps give 2.

**Effect on the bypass delay line (read in the code, not measured).** `Sources/CZTronDSP/ztd_plan.c:124-125` builds it from the kernel's integer `latency_frames`. So ACT-8's unprocessed path is 49 frames for K = 100.

**Severity: blocking.** REAL-5 is violated, and the public documentation contradicts the code.

**Nuance.**
- The kernel interface (`uint32_t latency_frames`, spec line 936) and ACT-8's "delay line of L samples" cannot carry a half sample. Only `DSPEnvironment.latency`, a `TimeInterval`, could carry 49.5/f_s.
- So, unless even linear-phase lengths are rejected, the resolution needs a change request (FIX-4), as the verifier's second option says.

### A-3 — WP-434: the alpha–beta tracker declares no settling time, so a re-activated tracker is faded in unsettled

**What the code does.**
- `Sources/CZTronDSP/ztd_alpha_beta.c:107` sets `.latency_frames = 0, .settling_frames = 0`.
- `Sources/ZTronDSPDesign/Stages/SmoothingStages.swift:133-140` emits `.alphaBeta(…)` without a settling time.
- The pre-roll is latency plus settling (`ztd_plan.c:124`). On re-activation the switch goes straight to the fade when that is 0 (`ztd_plan.c:326-338`).
- In the same C layer, biquads declare their settling from the pole radius: 100 dB, capped (`ztd_biquad.c:16-35`).

**My run: probe `p434switch`, then `python3 -B VerifierA/wp434_switch.py`.**

The poles of z² − (2 − α − β)z + (1 − α), for α = 0.02 and β = 0.0002, are 0.989900 ± 0.009899j, radius 0.989949. By the biquad rule that is 1 140 frames (23.8 ms); the declared figure is 0.

The tracker against the same stage run without a switch:

| Signal | Interval | Largest difference from the unswitched tracker |
|---|---|---|
| Slow | 10 ms after the fade | 6.68e-3 (1.52 % of the peak) |
| Slow | the next 30 ms | 3.7e-5 |
| Sine | 10 ms after the fade | 2.4e-4 |

- **Slow signal.** The output comes within 1e-6 of the unswitched tracker only 811 frames after the fade ends.
- **Sine.**
  - The gain solved from the output during the fade spans −0.070 … 0.9998, with a backward step of 0.186.
  - CLICK-1 still holds: step ratios 1.000 at switch-off and 0.964 at switch-on, against a bound of 1.5.
- **`SavitzkyGolay` under the same switch.** It is identical to the unswitched stage from the first frame after its fade.

**The verifier's suggested fix (M6).** I analysed the verifier's own M6 output (`.build/va-out-m6`) with `python3 -B VerifierA/wp434_switch.py .build/va-out-m6 1140`; I did not re-run M6 myself. With 1 140 frames declared:
- the pre-roll is 18 blocks;
- after the fade the output is within 5.96e-8 (slow) and 1.49e-8 (sine) of the unswitched tracker;
- the gain during the fade is monotone, from 0.0021 to 1.0000.

**Severity: blocking.** The declared settling time of a recursive stage is wrong, so the ACT-7 pre-roll does not happen. The STG-1 deliverable "its latency and settling time" is therefore not met.

**Nuance.**
- The specification sets no threshold for "settling time", and 1 140 frames is the C layer's own 100 dB convention.
- But any threshold gives a non-zero figure for this recursion.
- The row's own check ("Stage output ≡ offline function") passes. The defect lies in the C layer (`ztd_alpha_beta.c`).

### A-4 — WP-437: fused gains share one ramp, the longest, so fused and unfused differ through a change

**What the code does.**
- `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift:283-290` fuses each pair with `ramp: max(rampA, rampB)`.
- `KernelSpec.gainCascade(factors:ramp:)` (`KernelSpec.swift:175`) has one ramp, yet is documented as "bit-identical to that of the separate gains" (lines 173–174).
- The gain's documentation says of `ramp`: "0 jumps" (`Stages/Gain.swift:45`).
- The package's test asserts the merged ramp of 0.02 and compares fused with unfused at rest only (`SequenceStageTests.swift:51-61`).

**My run.** Suite `GainStageTests` (passed) together with probes `p437`, `p437merge` and `p437unfused`, then `python3 -B VerifierA/wp437_gain.py`. The update arrives after 4 800 samples.

| Pair of adjacent gains | How the changed gain moves | Expected | Fused against unfused |
|---|---|---|---|
| A `ramp: 0` gain beside a default gain | over 478 samples (9.96 ms) | 1 sample | up to 0.1722 of full scale, on 479 samples |
| A default gain beside a 50 ms gain | over 2 398 samples (49.96 ms) | 478 samples | up to 0.1406 of full scale, on 2 399 samples |

Outputs are identical before and after the change. The scalar reference holds bit for bit for all six amounts.

**Severity: blocking.** F1 is a MUST, and the result is wrong. The defect lies in the core: `PlanCompiler.swift`, and the single `ramp_frames` of the cascade kernel in `ztd_engine.c`.

## 3. Gaps (duty 2)

Here a gap is an acceptance check or a lens duty that the report does not show was carried out. Every package has a report. Every report cites runs of the package's tests: Debug, 334 tests in 40 suites, three iterations; and Release. Every report also adds a probe of its own, except two:
- WP-435 uses one mutation per row instead;
- WP-440 uses the golden check and a reading of the golden file.

| Package | Gap |
|---|---|
| WP-418c | Lens N, §11.5: non-finite or degenerate arguments (NUM-1) and schemes with edges at DC or Nyquist are not addressed. The edge cases named are analog/digital, band forms and transition widths |
| WP-422 | Lens N: non-finite arguments (NUM-1) and a 0 dB gain are not addressed |
| WP-423 | Lens N: non-finite arguments (a NaN or infinite cutoff or transition) are not addressed. The all-zero window, the zero-denominator case, is covered |
| WP-424 | Lens N: non-finite arguments (NUM-1) are not addressed |
| WP-425 | Lens N: non-finite or zero band weights and edges (NUM-1) are not addressed |
| WP-428b | Lens N: NUM-1 is not addressed: the floors of the dB figures (a zero deviation or round-off) and an empty system. The figure "single against double" of §6.3.8 is checked only for equality with the values recorded in `SystemAnalysisTests.swift:20-28`. The verifier's own float32 model is a different kernel and was not used as evidence, as the report says. So "matches the cited definition" rests on WP-433 |
| WP-432a | Lens N: silence, DC, full-scale and non-finite input (NUM-1) are not addressed |
| WP-432b | Lens N: silence, DC, full-scale and non-finite input are not addressed |
| WP-432c | Lens N: silence, DC, full-scale and non-finite input are not addressed |
| WP-433 | Lens N: silence, full-scale and non-finite input are not addressed. The pass rests on CR-018 item 1's reading, −100 dB on the measurement's own signals. The report asserts that without a figure. The package test's figure is −100.21 dB against −100 in my run, a margin of 0.2 dB |
| WP-434 | Lens N: silence and non-finite input are not addressed. Full scale is covered, by the 1 kHz sine of `p434switch` |
| WP-436 | Lens N: silence, DC, full-scale and non-finite input are not addressed |
| WP-437 | Lens N: non-finite amounts or input (NUM-1) and silence are not addressed. Factor 0, a negative factor, +20 dB and full scale are covered |
| WP-438a | Lens N: silence, DC, full-scale and non-finite input are not addressed |
| WP-438b | Lens N: silence, DC, full-scale and non-finite input are not addressed |
| WP-439 | Lens A: the checklist does not mention EXT, the UIKit boundary (§8.6), or Strategy and Decorator conformance (§5.3) |
| WP-440 | The acceptance "it runs under Octave in the generator environment" was not carried out. Octave is not installed (`which octave octave-cli`: not found), and CR-018, still Proposed, records it as not done (A-B7). Lens A: EXT, the UIKit boundary and Strategy/Decorator are not mentioned. The context `matlabScript()` runs on was read in the code, not witnessed, as the report says |

No gap was found in WP-426, WP-427, WP-431a, WP-431b, WP-431c, WP-431d or WP-435, apart from the severity questions in §4.

On WP-435 in particular, the T table is supported by the verifier's logs (`.build/mut-b2.out` … `mut-b4.out`):
- every row's mutation fails its row;
- every restore compares byte-identical to the pristine copy.

## 4. Severity observations: non-blocking findings that §11.6 may make blocking

These are not gaps in what was run. They are ratings that, read against §11.6, would change a pass.

- **A-B8: WP-431c, WP-431d, WP-439, WP-440.**
  - §11.6 makes blocking "public API differs from §4–§8 or Appendix A without a change request", and VIS-3 says "Changing it is a change request".
  - These members appear nowhere in the specification or in any change request (0 hits each): `IIRSystem.secondOrderSections(sampleRate:)`, `elementCount`, `exportedFrequencyCount` and `exportedSampleCount`. CR-018 item 11 lists types only.
  - By the letter, these four passes hold only once a change request names the members.
- **A-B3: WP-422.**
  - For `MatchedPeak`, `.q(Q)` is the analog prototype's Q. §6.3.5 (spec line 1081) says "`.q(Q)` follows the Cookbook definition, α = sin ω₀ / 2Q".
  - My `p422` run shows the effect: on all 6 `.q(2)` fixtures near Nyquist the matched shape error is not smaller (ratio up to 1.269), while all 42 hertz/octave fixtures are smaller.
  - No change request covers this. FIX-4 says a package that meets a wrong or ambiguous specification is paused, not passed.
- **A-B1 (WP-433) and A-B2 (WP-432a, WP-432b, WP-432c).**
  - The change request's attached figures understate the deviation I measured:
    - A-B1: −97.2 dB on unseen noise, against −90.51 dB on a step and −94.15 dB on a chirp;
    - A-B2: 0.133 dB, against 1.418 dB for a forced-single Butterworth high-pass of order 8 at 20 Hz.
  - STG-2 asks for "the measured error attached", and the brief makes a change request that misdescribes its deviation blocking. The verifier reads the figures as examples.
- **A-B6: WP-439.**
  - The package's cancellation test waits a fixed 30 ms. On a loaded host it may not exercise the mid-way check of BG-3, which §11.6 would call "does not exercise the code".
  - The verifier's probe exercises that check, so the acceptance itself is shown.

## 5. Spot checks of pass verdicts

| Package | What I ran | Result | Judgement |
|---|---|---|---|
| WP-433 | Suite `PrecisionTests`, probes `p433` and `p433control`, then `python3 -B VerifierA/wp433_precision.py` | Every test passes. Figures recorded by the package: −100.21 dB on the measurement's own signals (bound −100) and −97.22 dB on unseen noise (−95). Over 448 designs, 180 of them single, the worst gaps from the double path are: noise −98.28 and −96.65 dB; chirp −94.15 dB (20 designs above −100); step −90.51 dB (11 above). Against SciPy in float64: single paths −94.15 dB, double path −144.69 dB. `p433control`: the design and the measurement run on the control context, once at attach and once more at the update, never on main | The report's figures are reproduced exactly. The pass holds only under CR-018 item 1's proposed reading, with a 0.2 dB margin |
| WP-422 | Suite `MatchedPeakTests`, probe `p422`, then `python3 -B VerifierA/wp422_matched_peak.py` | Every test passes. The package's largest shape-error ratio, matched over Cookbook, is 0.534 over 200 fixtures. On my grid: 160 designs, plus 64 rejected at 0.49·f_s, each with its message. Properties: (1) 8.3e-12 dB, (2) 4.8e-13 relative, (4) 0.0 dB, (5) largest pole radius 0.99987. Near Nyquist the matched shape error is smaller on 42 of 42 hertz/octave fixtures, and not on the 6 `.q(2)` fixtures | Reproduced. The pass holds on the package's fixture grid. A-B3 stands (§4) |
| WP-440 | Suite `SystemAnalysisExportTests`; `Scripts/golden.sh --check`; `TMPDIR=$ROOT/.build/tmp Scripts/golden.sh --reproduce --only system_analysis_matlab --only fir_design` | 6 of 6 tests pass. Each variable deviates from the oracle's script by at most 1.9e-11 relative. The check finds 197 files of 27 generators matching the manifest. Both generators reproduce bit for bit with NumPy 2.2.6 and SciPy 1.15.3. Octave is absent | Golden part confirmed. The Octave clause is unrun (§3) |
| WP-428b | Suite `SystemAnalysisFigureTests`, probe `p428b`, then `python3 -B VerifierA/wp428b_figures.py` | Every test passes. On all 7 stress fixtures: the margins equal SciPy `butter` to 11 digits; the round-off levels equal the node-injection sums; single against double equals the recorded values; the precisions are as recorded. All 6 analog designs get the half-plane verdicts: the poles on the axis give margin 0 and "not stable"; the right-half-plane zero gives "not minimum phase" | Reproduced. Single against double is checked only against recorded values (§3) |
| WP-431c | Suite `IIRSystemTests`; probe `p431`; `TMPDIR=$ROOT/.build/tmp Scripts/compile-fixtures.sh` on the six fixtures that use `IIRSystem` | Every test passes. Conjugates are completed: zeros 0.3 ± 0.4j and −0.5; poles 0.5 ∓ 0.2j, plus one at the origin. `isActive: false` and a bound `isActive` are rejected with the ACT-1 message; `isActive: true` is accepted. Fixtures: 1 valid compiles, and 5 invalid fail with their sentences | Supported. A-B8 stands (§4) |

## 6. State left behind

**Clean-up of the probe and its outputs.**
- The verifier's probe file was copied into `Tests/ZTronDSPDesignTests/` for one build and run, then removed.
- `Tests/`, `Sources/`, `Scripts/` and `Package.swift` then compare equal to `.build/pristine`.
- No `__pycache__` was created: Python ran with `-B`.
- All my outputs were under `ROOT/.build/` and are removed with it.
- This audit and the verifier's reports and scripts are copied to `ZTronDSP-handoff/worktrees/v-m4b-a/`.

**Mutation restores.** The verifier's mutation logs show every mutated file restored byte-identical: batches b1–b4 and M6.

## 7. Commands run (from ROOT; every `xc.sh` call with `ZTD_DEVICE=ztdsp-27-vm4ba`)

1. `cp VerifierA/Probes/VerifierAProbeTests.swift Tests/ZTronDSPDesignTests/`, then `Scripts/xc.sh build`. The output was "TEST BUILD SUCCEEDED".
2. `TEST_RUNNER_VA_OUT=$ROOT/.build/va-out Scripts/xc.sh test-only` with these filters:
   - the probes `p425()`, `p432()`, `p434switch()`, `p437()`, `p437merge()`, `p437unfused()`, `p433()`, `p433control()`, `p422()`, `p428b()` and `p431()`;
   - the suites `LeastSquaresFIRTests`, `FilterStageTests`, `GainStageTests`, `SmoothingStageTests`, `PrecisionTests`, `MatchedPeakTests`, `SystemAnalysisFigureTests`, `SystemAnalysisExportTests` and `IIRSystemTests`.

   Result: 80 tests in 10 suites passed.
3. `rm Tests/ZTronDSPDesignTests/VerifierAProbeTests.swift`, then `diff -r Tests .build/pristine/Tests`, `diff -r Sources .build/pristine/Sources` and `cmp` against the main tree for each file the findings name.
4. `python3 -B VerifierA/<script>.py` for `wp425_ill_conditioned`, `wp432_stages`, `wp434_switch`, `wp437_gain`, `wp433_precision`, `wp422_matched_peak` and `wp428b_figures`. Also `wp434_switch.py .build/va-out-m6 1140` on the verifier's M6 output.
5. `Scripts/golden.sh --check`, and `Scripts/golden.sh --reproduce --only system_analysis_matlab --only fir_design` with `TMPDIR=$ROOT/.build/tmp`.
6. `Scripts/compile-fixtures.sh --valid .build/audit/fixtures/valid --invalid .build/audit/fixtures/invalid` with `TMPDIR=$ROOT/.build/tmp`. The fixtures were copies of the 6 compile fixtures that use `IIRSystem`.
7. My own check of the A-1 normal equations in NumPy, run with the pinned oracle.
