# Audit of Verifier B: M4, second half (WP-418c, WP-422 … WP-427, WP-428b, WP-431a … WP-440)

| Field | Value |
|---|---|
| Audited | The 24 reports `Docs/Process/reports/WP-<id>-B.md`, the seven blocking findings B-1 … B-7, and `VerifierB/` |
| Auditor | An agent that took no part in the verification. Nothing Verifier A wrote was read. |
| Revision | main tree snapshot 2026-11-17 22:50, after CR-027 (the verifier's checkout, ROOT) |
| Simulator | `ztdsp-27-vm4bb` only |
| Date | 2026-11-18 |

## In brief

- **The findings.** All seven blocking findings stand, and each reproduced in my own runs:
  - B-1 … B-6 are confirmed.
  - B-7 is confirmed for WP-431d. Its hold on WP-432c rests on an attribution recorded nowhere.
  - All seven are blocking under §11.6.
- **The gaps.** There are five, and none hides a defect that I could find:
  - WP-440 is passed with an acceptance check not run.
  - PLAT-1 is passed over in all eleven lens-A reports.
  - The lens-N edge cases of WP-431a and WP-431c are only partly reported.
  - The MatchedPeak stage is missing from WP-422's COV-3 and STG-1.
  - WP-437's settling time is not stated.
- **The spot checks.** Five checks of thin `pass` verdicts found nothing wrong.
- **For the integrator.** Four `pass` verdicts rest on non-blocking gradings that the letter of §11.6, or of the brief, would make blocking.

## What I ran

- **Pristine sources.** `diff -rq` shows that every file a finding names is identical in ROOT and in `/Users/admin/Documents/ZTronDSP`.
  - The main tree has moved on since the snapshot, through the core fix cycle and the integrator's records of 18 Nov:
    - 10 files of `Sources/ZTronDSPCore` and 2 of `Tests/ZTronDSPCoreTests` differ. `Support/FrameCount.swift` and `CountableValueRegressionTests.swift` exist only in main.
    - 10 files of `Docs/Numerics`, CR-018, CR-020, CR-024, the ledger and `fix-cycle-1-WP-315-342.md` differ. CR-028 … CR-030, and earlier reports and audits, exist only in main.
    - Only ROOT has the 24 B reports, `VerifierB/` and this audit.
  - Two of the changed core files, `Compiler/StockKernels.swift` and `Engine/ExecutionPlan.swift`, are ones I cite for B-1. Their changes leave the AlphaBeta lowering alone and still pre-roll for latency plus settling. By reading, B-1 holds on the main tree too.
  - `shasum -a 256 -c .build/vb/pristine.sha256` checks the verifier's record of the snapshot (1 314 files). It passed before my runs and passes after them.
- **Probes.** `ZTD_DEVICE=ztdsp-27-vm4bb VerifierB/run-probes.sh`: the 10 probes passed in 29.4 s, and the script removed its copy of the probe file. Every output is byte-identical to the verifier's except `p439.json`, which holds timings.
- **Oracles.** `VerifierB/oracles/o434_alphabeta.py` and `o431d.py` on my output, plus `pLensA.json` read directly.
- **Coverage.**
  - `VerifierB/coverage.sh gate`. Its output is byte-identical to the verifier's.
  - My own instrumented build and run, with the integrator's llvm-cov tools: `.build/covtools/run.sh build`, then `run.sh test audit1 ZTronDSPDesignTests`. 334 tests in 40 suites passed.
  - `Scripts/lib/coverage_gate.py --mode changed-files` on that run alone.
- **Independent computations.** They are given in full in the appendix:
  - a model of a cold-started α-β tracker, compared with the probe;
  - the WP-428b stability margins, recomputed from SciPy 1.15.3.
- **Reading.** `VerifierB/vis2.py` over the batch's files; the verifier's mutation and Release logs; the cited rules, change requests and code.

## Duty 1: the blocking findings

| ID | Packages | Verdict | Severity | Evidence |
|---|---|---|---|---|
| B-1 | WP-434 | confirmed | blocking | **Code.** `ztd_alpha_beta.c:107` declares `.settling_frames = 0`. `AlphaBeta.lower` (`SmoothingStages.swift:138` → `StockKernels.swift:67–69`) passes no other figure. The pre-roll is latency plus settling (`ExecutionPlan.swift:412, 730`). **Run.** My probe run fails `o434_alphabeta.py` on 2 of 4 checks. After the topology change, the output falls to 0.3468 at sample 9 929 (a deviation of 0.1532) and stays more than 10⁻³ off until sample 15 844. After the restore, it falls to 0.3463 (a deviation of 0.1537). The `LowPass(10 Hz)` control stays within 10⁻⁴ in both, and CLICK-1 gives a ratio of 1.0 for both. **Model.** I modelled a tracker started cold at sample 9 600 and faded in over 480 samples, with no pre-roll. It reaches 0.3463 at sample 9 928, and its largest difference from the probe is 1.04·10⁻³. A 100 dB decay takes 11 502 frames for this fixture (radius 0.998999499), and 1 950 for the test fixture α 0.85, β 0.005. **CR.** No change request mentions AlphaBeta. **Tests.** Every other stateful stock kernel declares its settling time (FIR, partitioned FIR, rate changers, biquads). No test asserts AlphaBeta's. |
| B-2 | WP-431d | confirmed | blocking | **Run.** My `p431d.json` is identical to the verifier's, and it fails `o431d.py` on 2 of 18 checks. `FIRSystem { Taps([1, 2]); Pole(at: 0) }` has the taps [0, 1, 2]. `IIRSystem { Section(b: [1, 2]); Pole(at: 0) }` is zero −2, pole 0, gain 1. `IIRSystem { Pole(at: 0) }` on its own is empty, the identity. The responses differ (FIR against IIR): 2.606−1.425j against 2.911−0.591j at 0.3 rad/sample, and −0.723−2.508j against 1.907−1.782j at 1.1 rad/sample. **Code.** `zeroPoleGain` pairs each pole with a zero at the origin (`SystemElements.swift:173–176`), while `taps` returns `[0, 1]` (178–186). **Tests.** The tests asserting the two readings (`SystemBuilderTests.swift:151–152` and `:350`) both pass in my run. **CR.** None covers it. |
| B-3 | WP-432c | confirmed | blocking | **Run.** My `pLensA.json` gives `fir100` 48.99999999999999 and `fir100designDelay` 49.5 (`FIRDesign.delay`, `FIRDesign.swift:40`). It gives `fir101` 50.0 and `filterFIR100` 48.99999999999999. **Code.** `FIRSystem.swift:271` divides as integers, and its comment (264–267) says "rounded down for an even `K`". `Realization.swift:240` emits the result. **Tests.** `FilterStageTests/theLatencyOfALinearPhaseFilterIsReported()` asserts 49 (`SystemStageTests.swift:273–275`) and passes in my run. **CR.** The only change request about latency, CR-019 item 3, concerns the STFT. |
| B-4 | WP-422 | confirmed | blocking | `MatchedPeakDesign.swift` is at 95.02 % (191 of 201) in my own run, with the same 10 lines missed. The design target has no COV-4(b) markers, and no change request defers this coverage (CR-022's deferral is M5c's). |
| B-5 | WP-431a, WP-432a, WP-432c | confirmed | blocking | In my run, `ResponseCore.swift` is at 97.33 % (146 of 150) and `ResponseStages.swift` at 97.25 % (177 of 182), with the same lines missed. The integrator's brief attributes both files to 431a, 432a and 432c. |
| B-6 | WP-431c | confirmed | blocking | In my run, `IIRSystem.swift` is at 96.88 % (155 of 160), with the same 5 lines missed. |
| B-7 | WP-431d (WP-432c) | confirmed in part | blocking | In my run, `FIRSystem.swift` is at 91.94 % (114 of 124), with the same 10 lines missed. The brief attributes the Systems files to 431a–431d, so the file is WP-431d's, as the finding holds. The verifier also infers that WP-432c changed the file (`latency(of:)`, line 268). That inference is recorded nowhere, so this half is undetermined. WP-432c is blocking anyway, through B-3 and B-5. |

### Notes on the rules and the severities

- **§11.6.** Its blocking criteria (line 1805) are:
  - a numbered rule or an acceptance statement of §4–§10 violated;
  - an acceptance check of §12 missing, failing or not exercising the code;
  - a wrong result;
  - coverage below COV-3;
  - public API differing from §4–§8 or Appendix A without a change request.
- **B-1.** The cited rules say what the finding claims:
  - STG-1 (§12, line 1836) makes the stage package deliver its latency and settling time, and §11.8 item 4 makes STG-1 part of done.
  - SWAP-2 (§5.5.4, line 685) and ACT-7 (§5.9, lines 830–832) pre-roll a new or restored kernel for its declared figure.
  - `ztd_kernel.h:65–67` defines that figure: the frames a kernel needs, after a reset, before its output is what it would have been had it always run.

  A recursive tracker that declares 0 gives a wrong result, and SWAP-2 and ACT-7 do not hold for it. Both are §11.6 criteria. As the finding says, the defect lies in the C layer (WP-218's kernel) and is reached through WP-434's stage.
- **B-2.** §6.3.7 (line 1125) gives no factor for `Pole` and does not list it among the elements of an `FIRSystem`; it only rejects a pole away from the origin.
  - The finding therefore measures the result against the element's own definition, "the factor `1/(1 − p·z⁻¹)`" (`SystemElements.swift:141`), together with "Elements inside one builder are cascaded".
  - That factor is 1 at p = 0. So the FIR result is wrong, and the FIR note (lines 153–154 and 178) contradicts the definition.
  - The specification is silent, so the finding's second resolution is as valid as a code change: a change request under FIX-4 that fixes one meaning.
- **B-3.** REAL-5 (§6.3.9, line 1153) states (K − 1)/2 with no rounding, and the environment's `latency` is a `TimeInterval` (line 621). REAL-5 is a numbered rule of §6, and the code departs from it without a change request. The integer shapes of §5.11.1 (`latencyFrames: Int`, `uint32_t latency_frames`) cannot carry half a frame, so a change request under FIX-4 is the likely way out.
- **B-4 … B-7.**
  - COV-3 (§10.2, line 1727) applies per package, and COV-4(b) (line 1728) is the only exclusion. The rows of B-5 … B-7 have no lens T, so there COV-3 is also the integrator's check under §11.8 item 3. The findings are still blocking under §11.6.
  - The measurement is the integrator's llvm-cov work-around (`.build/covtools`, identical to the handoff copy), not xccov. `ResponseStages.swift` is one line short, and the lines it misses are whole public members, which any line rule counts.
  - By reading the code, these lines are reachable, each with a one-line test:
    - `MatchedPeakDesign.swift:84`, `:159` and `:217–219`, for example through a quality that is not finite, from an extreme bandwidth;
    - `IIRSystem.swift:128`, through an analog `ZeroPoleGain` element, and `:143`, through gains that overflow;
    - `FIRSystem.swift:117` (an element whose taps are not finite), `:120` (more than `maximumLength` taps), `:125` (taps that overflow) and `:232–235` (taps that are all zero);
    - `ResponseStages.swift:396, 789–791 and 804`, which are public members.
  - These lines are defensive and want COV-4(b) markers: `ResponseCore.swift:103, 108, 124 and 140`; `IIRSystem.swift:118 and 232–233`; `FIRSystem.swift:107 and 149–150`.

## Duty 2: gaps in the verification

All 24 reports exist. Each has the second lens of its row, the stated revision and the verdict I was given. The mutation and Release claims match the verifier's logs:

- **M1.** 31 tests in 4 suites failed with 210 issues: WP-422 166, WP-423 15, WP-425 2 and WP-427 27.
- **M2.** 13 tests in 3 suites failed with 34 issues:
  - WP-426's suite: 32 issues in 3 tests;
  - under WP-433's mutation, its control-context test and the sequence-stage allocation audit: 1 issue each.
- **Release, with `wp433-alloc` applied.** The same two tests fail (9 tests in 2 suites, 2 issues). The restore check then reports 0 files that differ from the pristine copy.
- **Release, pristine.** 344 tests in 41 suites passed, the probes included.
- **Debug, final.** 334 tests in 40 suites passed. `iter10`: 50 tests in 7 suites passed.

| Package | Gap | What I checked |
|---|---|---|
| WP-440 (N) | The verdict is `pass`, yet the second acceptance check, "it runs under Octave in the generator environment", was not run (Octave is not installed). The report says "not verified" but records no finding. By §11.6 a missing acceptance check is blocking. CR-018 "Not done" describes the omission accurately, so under the brief it waits for the owner. It belongs in the report as a finding that waits for the owner, not under a `pass`. | Nothing can be run here. The report discloses the omission. |
| WP-422 (T) | COV-3 is reported for `MatchedPeakDesign.swift` alone. CR-018 item 4 says WP-422 delivered the `MatchedPeak` stage (`Stages/EqualizerStages.swift:344`, fluent `Stages/Fluent.swift:245`), but the report does not cover it. Nor does it cover STG-1 for that stage, which appears only under WP-432b. | Both files are at 100 % in my run. `MatchedPeak` is in the equaliser allocation audit (`SystemStageTests.swift:138`) and in the order matrix. Nothing is hidden. |
| WP-418c, 424, 428b, 432a, 432b, 432c, 434, 436, 437, 438a, 438b (A) | "Availability (PLAT-1)" is an item of the lens-A checklist (the lens table of §11, line 1798), and none of the eleven reports names it. "Platform" appears in the lens heading of each. WP-418c also has the bullet "DEP, EXT, VIS and the platform", but its items are the API digest, the dependency graph and lint-bans, and none of these checks availability. | **PLAT-1.** `Package.swift:31` declares `platforms: [.iOS(.v15)]`. `Sources/ZTronDSPDesign` has no `#available` or `@available(iOS …)` in code; its two mentions are doc comments saying that the builders accept `if #available`. The compiler rejects an API newer than the deployment target when it is used without `#available`, so nothing is hidden. **Other lens-A items.** `lint-bans.sh` covers the mechanical ones, and the gate log shows it clean (parts 1–4, 560 files): the UIKit boundary (part 1), the approval-gated API (part 3), and API-6, IMM-2, VIS-1 and `@unchecked Sendable` (part 4). |
| WP-431a, WP-431c (N) | The lens-N edge cases are only partly reported. Neither report states non-finite parameters (NUM-1). WP-431a reports the Nyquist check and an unmeetable least-squares scheme, but no DC edge and no length 1. WP-431c reports roots at 0 Hz and at Nyquist, and a zero above Nyquist. | Not verified again, since Duty 2 forbids it. |
| WP-437 (A) | STG-1's settling time is not stated; only the latency (0) is. | `ztd_gain.c:188` declares 0, which is right for a memoryless gain. |

### Gradings behind `pass` verdicts

These are for the integrator and are not gaps. Four verdicts rest on items graded non-blocking where the letter of §11.6, or of the brief, says blocking:

- **WP-428b.**
  - **BL-1.** The doc of `SystemKind` (`SystemAnalysis.swift:5`) names no threading context. VIS-2 (§5.11.2, line 961) is a numbered rule of §5.
  - **BL-2.** `sampleRate`, `taps` and two `[Double]` overloads (digest lines 672, 674, 874 and 878) are public, and are named neither in §6.3.8 nor in CR-018 item 11. §11.6 makes public API that differs from §4–§8 without a change request blocking, and VIS-3 (line 962) says that changing the public surface is a change request.
- **WP-436 and WP-438b, BL-2.** These public additions are in no change request:
  - `rejection:` and `passband:`, on `Decimate`, `Interpolate`, their fluent twins, `DSP.decimate` and `DSP.interpolate`;
  - `DSP.rateChangeTaps` and `DSP.maximumRateChangeFactor`.

  The WP-436 report itself notes that `rejection: .decibels(10)` is accepted, which is below the 80 dB of §6.12. The parameter's check (`AnalogPrototype.decibels`, `AnalogPrototype.swift:218–224`) accepts any finite value above 0 dB, up to 1 000 dB.
- **WP-437, BL-5.**
  - CR-018 item 10 says that moving a gain through 0 dB is a change of topology, but the code keeps the kernel and ramps.
  - CR-024 item 4 describes the code accurately, but it names only CR-015 item 5 as what it amends.
  - The brief makes a change request that misdescribes the code blocking.
- **WP-434.** BL-1 (`AlphaBeta.Output` has no threading contract) and BL-2 (`DSP.alphaBeta` is in no change request) are of the same kind. The package is blocking anyway, through B-1.

The verifier's reasons are "the contract can be inferred" (WP-428b BL-1) and "an addition; nothing is missing" (WP-434 BL-2, and likewise WP-428b BL-2). §11.6 grants no such exemptions. In practice, though, the integrator has treated items of the same kind as backlog. On 18 Nov, CR-018 item 11 was extended in the main tree after the second lens of WP-403, WP-414, WP-420 and WP-421 found the list incomplete (B-BL-2, B-BL-4). So the gradings follow precedent but not the letter. I change no verdict; the integrator decides.

### Not gaps

- **WP-425.** The verifier's single mutation left the golden ill-conditioned test passing. The stress test, which also takes the fall-back, failed, and the report explains both ways into the fall-back.
- **WP-433 and WP-439, BL-3.** The missing benchmarks are non-blocking under PERF-1 (line 1387), because neither row makes a performance claim.
- **WP-439, BL-4.** It meets BG-3 (line 1678) as worded.

## Spot checks: the `pass` verdicts with the thinnest evidence

I ran each test below in my instrumented run of the whole design target (334 tests, all passed).

| Package | What I ran | What I found |
|---|---|---|
| WP-428b | `theFiguresOfTheStressFixturesEqualTheirRecordedValues()`, `theAnalogCriteriaUseTheHalfPlane()` and `aPoleOnTheUnitCircleIsNotStableInEveryForm()`: all passed. I also recomputed the seven recorded stability margins as 1 − max\|p\| of SciPy's digital Butterworth designs (`margins_428b.py`). | All seven margins agree within 1.7·10⁻¹² relative, against the test's bound of 10⁻⁹. The analog test tells the half-plane criterion from the unit-circle one: −10 ± 50j is stable, with margin 10; 0.1 and ±j are not stable; a zero at 0.5 is not minimum phase. Nothing wrong. |
| WP-439 | `theAnalysisRunsOffTheMainThread()`, `aCancelledCallThrowsCancelled()` and `theResultIsAnImmutableValue()`: all passed. | The first test is `@MainActor`. Through a witness element, it asserts `!onMainThread && onBackgroundExecutor`. Nothing wrong. |
| WP-425 | `anIllConditionedFitTakesTheFallBackAndStillMeetsTheOracle()` and `stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack()`: both passed. | The first test asserts `fit.usedFallback`, and the oracle's band error within 10⁻⁶. The M1 log shows the second test failing under the verifier's mutation. Nothing wrong. |
| WP-438a | `subsampleAndUpsampleAreTheToolkitFunctions()`: passed. | It compares the output bit for bit with `subsampled` and `upsampled`: over the factors 1, 2, 3 and 7, the block sizes 1, 64, 100 and 512, and five phases. It also checks the rates 16, 192 and 72 kHz in the environment. Nothing wrong. |
| WP-433 | `overTheGridTheChosenPathIsWithinMinus100DecibelsOfTheDoubleReference()` and `theMeasurementRunsOnTheControlContextNotOnTheMainThread()`: both passed. | The witness wraps the filter family, so it shows that the lowering runs off the main thread. The measurement follows in the same lowering (`Realization.swift:220–222`), but the witness does not observe it directly. Nothing wrong. |

## Housekeeping

- **Written inside ROOT.**
  - This file.
  - `.build/audit/`: my scripts, my logs, and backups of the verifier's probe outputs and merged gate files.
  - My coverage run's files: `.build/cov-audit1.xcresult`, `.build/covtools/lines-audit1.json` and `export-audit1.json`.
  - The instrumented products under `.build/xcode-cov`, which I rebuilt.
- **Changed and restored.**
  - `run-probes.sh` copied `VerifierBProbes.swift` into `Tests/ZTronDSPDesignTests/` and removed it again. It is absent now.
  - My probe run rewrote `.build/vb/probe-out/*`, and `coverage.sh gate` rewrote `.build/vb/cov-merged-gate.txt` and `cov-merged-fails.txt`. I copied the verifier's files back from my backups, and `diff -r` and `cmp` show them byte-identical to the verifier's.
- **Not restorable.** `run.sh test` cleared `.build/xcode-cov/Build/ProfileData`, the raw profiles of the verifier's coverage runs. Their results (`.build/vb/cov*`, `.build/covtools/lines-design1.json` and `lines-all2.json`) were left in place, and I had already reproduced the gate from them.
- **Final check.** `shasum -a 256 -c .build/vb/pristine.sha256` reports all 1 314 files OK.
- **Deviation from the rules.** During the pristine check, I wrote two temporary file lists outside ROOT, in the session scratchpad:
  - `/private/tmp/claude-501/-Users-admin-Documents-ZTronDSP/0a25c87a-503c-4e3f-99b7-72b2d1d73489/scratchpad/audit_pristine_list.txt`
  - `/private/tmp/claude-501/-Users-admin-Documents-ZTronDSP/0a25c87a-503c-4e3f-99b7-72b2d1d73489/scratchpad/audit_root_list.txt`

  I have left them in place, because the chore deletes nothing else.
- **After this audit.** The chore copies the reports and `VerifierB/` to the hand-over folder, shuts the simulator down and removes `ROOT/.build`. That removes my scripts and the verifier's logs, so the appendix keeps the scripts.

## Appendix: the two computations

The scripts lived in `.build/audit/scripts/`, which the chore removes, so they are given here in full. Run them from ROOT.

### `ab_check.py`, for B-1

The script needs the probe output, so run `VerifierB/run-probes.sh` first. Then run `python3 ab_check.py "$PWD"`.

My output:

- **Settling.**
  - This fixture: radius 0.998999499, 11 502 frames.
  - α 0.85, β 0.005: radius 0.994111, 1 950 frames.
  - α 0.1, β 0.01: radius 0.948683, 219 frames.
- **Minima.** The probe reaches 0.3468 at sample 9 929, and the model 0.3463 at 9 928.
- **Largest difference.** The model and the probe differ by at most 1.04·10⁻³.
- **Transient.** The probe is more than 10⁻³ off until sample 15 844, 6 244 samples after the change.

```python
# Auditor's independent check of B-1: is the probe's output a cold-started tracker faded in with no pre-roll?
import json, math, sys
import numpy as np
root = sys.argv[1]
d = json.load(open(root + "/.build/vb/probe-out/pAlphaBeta.json"))
x = np.array([float(v) for v in d["alphaBeta"]])
a, b, dt = 0.002, 0.000002, 1/48000
# 1) settling by 100 dB from the characteristic polynomial z^2 - (2-a-b) z + (1-a)
A = np.array([[1-a, (1-a)*dt], [-b/dt, 1-b]])   # state matrix of the error dynamics
r = max(abs(np.linalg.eigvals(A)))
print("eigenvalue radius %.9f, 100 dB settling %d frames" % (r, math.ceil(math.log(1e-5)/math.log(r))))
for (aa, bb) in [(0.85, 0.005), (0.1, 0.01)]:
    rr = max(abs(np.roots([1, -(2-aa-bb), 1-aa])))
    print("alpha %g beta %g: radius %.6f, settling %d frames" % (aa, bb, rr, math.ceil(math.log(1e-5)/math.log(rr))))
# 2) model: tracker reset at sample 9600 (position 0, velocity 0), its output faded in over 480 samples
n0, fade = 9600, 480
pos, vel = 0.0, 0.0
model = np.full(len(x), 0.5)
for n in range(n0, len(x)):
    p = pos + dt*vel; res = 0.5 - p; pos = p + a*res; vel = vel + (b/dt)*res
    w = min(1.0, (n - n0 + 1) / fade)
    model[n] = (1-w)*0.5 + w*pos
print("probe min %.4f at %d; model min %.4f at %d" % (x[n0:].min(), n0+int(np.argmin(x[n0:])), model[n0:].min(), n0+int(np.argmin(model[n0:]))))
print("largest |probe - model| after the change: %.2e" % np.max(np.abs(x[n0:] - model[n0:])))
out = np.where(np.abs(x - 0.5) > 1e-3)[0]; out = out[out >= n0]
print("probe more than 1e-3 off until sample %d (%d after the change)" % (out.max(), out.max()-n0))
```

### `margins_428b.py`, for WP-428b

Run `PYTHONPATH=VerifierB/pyshim TMPDIR=$PWD/.build/tmp python3 margins_428b.py`.

My output: the relative differences are 4.84·10⁻¹⁴, 4.35·10⁻¹³, 1.74·10⁻¹², 0, 1.90·10⁻¹⁵, 1.98·10⁻¹⁵ and 2.55·10⁻¹⁵. The worst, 1.74·10⁻¹², is well within the test's bound of 10⁻⁹.

```python
# Auditor's spot check of WP-428b: the recorded stability margins of the stress fixtures,
# recomputed in closed form (1 - max|p|) from SciPy 1.15.3's digital Butterworth designs.
import numpy, scipy
from scipy import signal
assert scipy.__version__ == "1.15.3" and numpy.__version__ == "2.2.6"
recorded = {
    "hp-90Hz-48k-order8": ("highpass", 48_000, 90, 8, 0.0022956655111259217),
    "hp-20Hz-96k-order8": ("highpass", 96_000, 20, 8, 0.00025533996217064203),
    "lp-10Hz-192k-order8": ("lowpass", 192_000, 10, 8, 6.384111960278105e-05),
    "hp-10Hz-44k1-order2": ("highpass", 44_100, 10, 2, 0.001006949134693902),
    "lp-0.45fs-48k-order8": ("lowpass", 48_000, 21_600, 8, 0.05857389455836004),
    "hp-0.45fs-44k1-order4": ("highpass", 44_100, 19_845, 4, 0.11202492162488153),
    "lp-0.49fs-48k-order2": ("lowpass", 48_000, 23_520, 2, 0.04345630794958788),
}
worst = 0.0
for name, (btype, fs, fc, order, margin) in recorded.items():
    z, p, k = signal.butter(order, fc, btype=btype, analog=False, output="zpk", fs=fs)
    mine = 1 - numpy.max(numpy.abs(p))
    rel = abs(mine - margin) / margin
    worst = max(worst, rel)
    print("%-24s recorded %.17g  scipy %.17g  relative %.2e" % (name, margin, mine, rel))
print("worst relative difference %.2e (the test's bound: 1e-9)" % worst)
```
