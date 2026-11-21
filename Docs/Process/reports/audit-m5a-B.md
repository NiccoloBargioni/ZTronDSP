# Audit of Verifier B — M5a, the spectral front-end

| Field | Value |
|---|---|
| Audited | Verifier B's verification of WP-501a … WP-501g, WP-502 … WP-512, WP-528, WP-534 … WP-538, WP-540 (25 packages): the reports `WP-<id>-B.md` and the tooling under `VerifierB/` |
| Auditor | an agent that took no part in the verification; nothing of Verifier A was read |
| Checkout | the verifier's checkout. Before any change, `Sources/` and `Tests/` equalled `.build/pristine`. Every file named in the six findings equals the main tree (`/Users/admin/Documents/ZTronDSP`) by SHA-256, before and after the audit |
| Date | 2026-11-18 |
| Changed in the package | nothing. Probe files were added to the test targets for the runs and removed again; the gated mutations were applied and restored (see "Restoration") |

## Summary

All six blocking findings stand. B-1, B-3, B-4, B-5 and B-6 are **confirmed**. B-2 is **confirmed in part**: the package's own check is vacuous, but one of the finding's claims is wrong, because a test outside the package's targets does compare two closures written apart. I judge all six blocking by §11.6. I reproduced every finding myself: on the untouched sources and, where the reproduction names it, on the gated build.

Five gaps in the verification:

- WP-508: no COV-3 figure for `Units/Frequency.swift`, which holds the `Frequency.mel` the row names (it passes, at 99.09 %);
- WP-501g: none for `Steps/STFT.swift`, which holds the logging hook (100 %);
- lens R: none of the twelve reports addresses RT-1, RT-8 or RT-9, and only some address RT-4 and layers 1, 2 and 4 of RT-7;
- WP-540: the Octave half of the acceptance passed without being run (CR-007 and CR-019, both still proposed, record it);
- WP-501e: "within one sample" supported only up to 4 096 samples, with no change request for the conflict with WIN-6.

I spot-checked five `pass` verdicts by running their acceptance checks: WP-505, WP-507, WP-511, WP-501f and WP-534. All five hold.

## How the audit was run

Every `Scripts/xc.sh` call ran with `ZTD_DEVICE=ztdsp-27-vm5ab TMPDIR=$PWD/.build/tmp`; `VerifierB/run-gates.sh` exports the same. One fixture run, the harness self-test of WP-534, had `TMPDIR` alone: `Scripts/compile-fixtures.sh` then calls only `Scripts/xc.sh products`, which prints a path and touches no simulator. Builds and test runs ran in the background, apart from that self-test, which takes seconds. Nothing was edited while a job was running. `uptime` showed load averages between 154 and 1 018, so no timing below is evidence.

1. **Untouched sources, default build (`.build/xcode`).** Copied in:
   - the verifier's `VerifierBProbes.swift` and `VerifierBCoreProbes.swift`;
   - my `AuditBProbes.swift` and `AuditBCoreProbes.swift` (Appendix A).

   Then I ran `Scripts/xc.sh build` and the following:
   - **B-6, as its reproduction states:** `TEST_RUNNER_VB_OUT=… Scripts/xc.sh test-only 'ZTronDSPAnalysisTests/VerifierBProbes/vbTheLevelOfAFiniteSignalIsFinite()'`.
   - **One run of the four probe suites and five spot-check suites:** `CepstrumTests`, `InverseSTFTTests`, `SpectralCentroidTests`, `WindowAnalysisTests` and `ValueStepTests`. It used `TEST_RUNNER_VB_OUT` and `TEST_RUNNER_AUDIT_OUT`.
   - **The compile fixtures of WP-534:** `Scripts/compile-fixtures.sh --valid … --invalid …` on copies in `.build/audit/fixtures/`, then the harness self-test in `.build/audit/fixtures-neg/`.

   Then I removed the four files, and `Tests/` equalled the pristine copy again.
2. **Gated build (`.build/xcode-mut`).** I ran `python3 -I -B VerifierB/mutations.py apply`, which refuses unless the touched files are pristine. It printed "applied 28 mutations and 16 allocations to 18 files; added 2 gate files and 2 probe files" (the probe files are the verifier's). I copied my two probe files in and ran `ZTD_DERIVED=$PWD/.build/xcode-mut Scripts/xc.sh build`. Then:
   - `VerifierB/run-gates.sh control m501a m501c`, with `TEST_RUNNER_AUDIT_OUT` exported so that my probes also wrote their output under m501c;
   - my B-4 probe and the verifier's vDSP-set probe, under `TEST_RUNNER_VB_MUT=m501a`.

   Then I removed my two files and ran `python3 -I -B VerifierB/mutations.py restore`, followed by my own comparison (see "Restoration").
3. **Read-backs in Python (`python3 -I -B`).**
   - `VerifierB/check_scipy_windows.py` on the `windows.txt` that my own run wrote;
   - my `spot_501f.py` (Appendix A);
   - the COV-3 figure for `Units/Frequency.swift`, read from the verifier's `.build/covtools/lines-vbA.json`.

The verifier's stored outputs were copied to `.build/audit/verifier-orig/` before `run-gates.sh control` emptied `.build/vbprobe/`. The files its probes wrote on my untouched build, and again in my control run, are byte-identical to the stored ones: `stft-window-precision.txt`, `custom-errors.txt`, `custom-equality.txt`, `measurement-silent-frame.txt`, `vdsp-set.txt` and `level-range.txt`, and `windows.txt` to `.build/vbprobe4096/windows.txt`. My own probes ran on the untouched build and, gated, under m501c (the whole targets) and m501a (the B-4 probe alone). What they wrote under m501c is byte-identical to the untouched build wherever equality plays no part (`audit-b1-core.txt`, `audit-b1-stft.txt`, `audit-b3.txt`, `audit-b6.txt` and the three spot-check files).

The verifier's probe files changed after some of its stored runs, which shows in two places:

- `VerifierBCoreProbes.swift` is one line longer. In my runs its issues are reported at `:101–103` and `:121`, where the findings cite `:100–102` and `:120`. They are the same assertions.
- `VerifierBProbes.swift` gained the B-6 probe after the stored m501c run. That run shows 424 Analysis tests in 42 suites and 3 issues in "Verifier B probes". Mine shows 432 tests in 43 suites and 7 issues: the B-6 probe adds one test and 4 issues, and my own suite adds 7 tests. In Core the stored run has 484 tests, and mine has 487, with my suite of 3.

## Duty 1 — the blocking findings

| ID | Package | Verdict | Severity | Reproduced | Evidence, in short |
|---|---|---|---|---|---|
| B-1 | WP-501c | confirmed | blocking | yes | `samples(count:)` returns 64 × +∞ for `.custom { _ in 1e39 }` and 64 zeros for `1e-50`, without the error its own documentation promises. `STFT` attaches with either: 15 616 of 15 738 values not finite, or only zeros. Same figures on the untouched build and in the control |
| B-2 | WP-501c | confirmed in part | blocking | yes | `WindowTests.swift:110`, `:112` are vacuous. Under m501c, every suite of Core (487 tests), Analysis (432) and Design (334) passes but the probe suites. Not right: "no test compares two closures written separately". `ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift:89–91` does, and my replicas of its expressions fail under m501c |
| B-3 | WP-537 | confirmed | blocking | yes | Frames of 2, original `[10, 0, 1, 0, 0, 0]`: relative error 0.5, then 0.10000002 once one frame gets worse; 0.5 as samples. My own case `[1, 0 \| 0, 0]` gives 1.0, then 0.10000002 |
| B-4 | WP-501a | confirmed | blocking | yes | m501a: `WindowTests` 6 of 6 pass; the only failure is `WindowAnalysisTests.swift:75`. A full comparison fails: my probe with 6 issues, the verifier's with 1 issue that lists 26 mismatches |
| B-5 | WP-501b | confirmed | blocking | yes | `windows.py:14` lengths 2, 5, 16, 63, 64, 1 024. `windows.json` has 120 cases, none at 4 096. No change request. The product matches `get_window` at 4 096 too (60 cases, at most 4.66·10⁻¹⁵) |
| B-6 | WP-506 | confirmed | blocking | yes | As documented: 4 issues at `VerifierBProbes.swift:107`. `Level(.rms)` of a constant 10¹⁸ … `Float.greatestFiniteMagnitude` is +∞ with confidence 1; 10¹⁷ is 340 dB. My sine of amplitude 2·10¹⁸ gives +∞ in 9 of 9 values |

### B-1 — the single-precision window is not checked (WP-501c)

- **Rule.**
  - WIN-2 (spec line 1188) evaluates the closure "once, in double precision". WIN-3 (line 1189) makes "a sample that is not finite; a window that is zero everywhere" errors at attach time. NUM-1 (line 1005) is "No NaN, no infinity".
  - The row (line 2074) asks that "a non-finite or all-zero window is a typed error". The finding's `rule` field quotes WIN-3's wording as "the row's acceptance". The substance is the same.
  - The code's own contract settles which samples the rule covers. `Window.swift:168–169` documents that `samples(count:)`, "the window sampled once, in single precision", throws for "a sample that is not finite, and a window that is zero everywhere (WIN-3)". The step multiplies by those samples (`FramingSupport.swift:21`, and `:30` when the factor is 1).
- **Change request.** None. CR-012 places `Window` in the core and says nothing of the rounding to single precision.
- **Pristine; reproduction.** `Window.swift` and `FramingSupport.swift` equal the main tree.
  - *Control on the gated build* (`run-gates.sh control`): 3 issues at `VerifierBCoreProbes.swift:121` and 2 at `VerifierBProbes.swift:33`.
  - *The same probes on the untouched build:*
    - `.custom { _ in 1e39 }` → 64 of 64 single samples +∞, while the double samples are finite;
    - `1e-50` → 64 zeros, while the double samples are non-zero;
    - 4·10³⁸ at the centre → 1 non-finite sample;
    - `STFT(frame: 256, hop: 64)` with `1e39` attaches: 61 frames, 15 616 of 15 738 values not finite;
    - with `1e-50` it attaches and emits only zeros;
    - `Power(); Decibels()` after it gives no non-finite value of 7 869, the first −160 dB (the verifier reports −160 dB everywhere);
    - with `.amplitude` the output is finite and non-zero.

    These are the finding's figures exactly. `stft-window-precision.txt` is byte-identical to the verifier's.
  - *My own probe:*
    - `3.5e38` (finite in double, beyond `Float`) gives 64 of 64 +∞;
    - `1e39.symmetric` gives 64 of 64 +∞;
    - `1e-46` gives 64 zeros;
    - `STFT(frame: 256, hop: 128, window: .custom { _ in 1e-46 }); Magnitude()` attaches and yields 3 999 zeros out of 3 999.

    My intended control, `.custom { _ in 1e30 }` through `Magnitude()`, also came out non-finite. The cause is that `Magnitude` squares values near 10³² in single precision. That is unrelated to WIN-3, and I do not rely on that line.
- **Verdict.** Confirmed. Blocking: the row's acceptance statement is not met in the precision the step uses, a documented error is not thrown, and the step emits non-finite values for a finite input.

### B-2 — "Equal closures give equal descriptions" is not exercised (WP-501c)

- **Rule.**
  - The row (line 2074) states "Equal closures give equal descriptions".
  - WIN-2 (line 1188): "Two custom windows are equal when their closures agree at 65 probe points … that is what lets a pipeline that contains one be compared (API-1)".
- **Change request.** None.
- **Pristine; reproduction.** `WindowTests.swift` and `Window.swift` equal the main tree.
  - *The test.* `customWindowsCompareByTheirProbeValues` asserts `a == a && Set([a, a]).count == 1` at `:110` and `a == b || a != b` at `:112`, which holds for any equality.
  - *Gate m501c* (`run-gates.sh m501c`; `Window.swift:55` also requires the same probe storage):
    - `ZTronDSPDesignTests` passed, 334 tests in 40 suites;
    - `ZTronDSPCoreTests`: 487 tests in 57 suites. The 13 issues are all in "Audit B core probes" and "Verifier B core probes";
    - `ZTronDSPAnalysisTests`: 432 tests in 43 suites. The 14 issues are all in "Audit B probes" and "Verifier B probes".

    No suite of the project failed. The verifier's `vbTwoSeparatelyWrittenEqualClosuresAreOneWindow` failed with 3 issues. On the untouched build it passes (`custom-equality.txt`: `a == b: true, hash equal: true`).
  - *What the finding misses.* `ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift:88–91` is the extension guide's test (WP-907/908, run by `Scripts/external-parity.sh`, CI gate 9). It compares `Window.sine`, a computed `static var` that returns `.custom { t in sin(.pi * t) }` (`ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift:14–16`), with a separately written `Window.custom({ t in sin(.pi * t) })`. It also compares two calls of `sineWindowRoundTrip(frame: 1_024)`, each a pipeline of `STFT` and `InverseSTFT` that reads `.sine` anew.

    My probes repeat those expressions in the main targets.
    - On the untouched build: equal, and the pipelines are equal.
    - Under m501c: `sine == same` is false, two accesses of `sine` are unequal and the pipelines are unequal (`AuditBCoreProbes.swift:60`, `:61`; `AuditBProbes.swift:57`). Hashes stay equal.

    So, going by these replicas, that external test would catch m501c. I did not build or run the ExternalParity package, gated or not.
- **Verdict.** Confirmed in part.
  - *What stands:* the check WP-501c delivers for its own acceptance statement is vacuous, and m501c survives the Core, Analysis and Design targets.
  - *What does not stand:* "No test compares two closures written separately". The repository's external parity suite does, and, going by my replicas, it would fail under m501c.
  - *Severity:* blocking for WP-501c. The row's own check does not exercise the code (§11.6). A test in a separate package, built by its own manifest under another CI gate, does not make WP-501c's check exercise it. The owner may weigh that suite.

### B-3 — the measured relative error ignores a silent frame's error (WP-537)

- **Rule.**
  - INV-2 (line 1337) asks for "the error measured by performing the round trip".
  - The measure itself is defined by the package: `InversionReport.swift:75–77` ("the largest error relative to the largest value it is held against … the maximum of its own frame for frames"), and the comment at `:112`, "an error where the original holds nothing is held against the whole signal's peak".
  - The code applies that comment only when no other frame has a relative error (`:109`, `:113`). A worse reconstruction can therefore measure better, which no reading of "the largest error" allows.
- **Change request.** None. CR-019 item 10 covers the uncapped predicted error and the all-silent signal (relative error ∞), not this mixed case.
- **Pristine; reproduction.** `InversionReport.swift` equals the main tree.
  - *Control on the gated build:* 1 issue at `VerifierBProbes.swift:71`.
  - *Untouched build:*
    - original `[10, 0, 1, 0, 0, 0]`, frames of 2: `[10, 0, 1, 0, 0, 5]` measures 0.5, and `[10, 0, 1.1, 0, 0, 5]` measures 0.10000002384185791;
    - as samples it measures 0.5;
    - my own case, original `[1, 0 | 0, 0]`: `[1, 0 | 0, 1]` measures 1.0, `[1.1, 0 | 0, 1]` measures 0.10000002384185791, and as samples 1.0 (`AuditBProbes.swift:72`).
  - *Reach in this batch.* The STFT report measures samples (`StageInversions.swift:63–64`), so WP-538 is unaffected. The frame-wise measurements are the reports of `Cepstrum(.complex)`, `CepstralCoefficients` and `Decibels` (`:142`, `:189`, `:248`, WP-539). `InversionMeasurement` and `InversionRoundTrip(…, frameLength:)` are public, and INV-1 gives stages outside the package the same report.
- **Verdict.** Confirmed. Blocking: a result is wrong.

### B-4 — the symmetric vDSP forms are not compared (WP-501a)

- **Rule.**
  - The row (line 2072) asks that "Each case equals the vDSP output bit for bit, full and half; the symmetric forms".
  - WIN-1 (line 1187): `.symmetric` is "still generated by vDSP, one sample shorter and closed with its first value".
- **Change request.** None. CR-012 only describes the tests.
- **Pristine; reproduction.** `WindowTests.swift` and `Window.swift` equal the main tree.
  - *What the test compares.* `theVDSPWindowsAreTheVDSPCallsBitForBit` (`WindowTests.swift:13–54`):
    - the symmetric form for `.hann` alone, in single precision (`:44–51`), whose closing value is 0;
    - the half form for `.hann`, `.hamming` and `.blackman` in single precision only (`:37–42`);
    - double precision for the full form only.
  - *Other tests.* A search of `Tests/` and `ExternalParity/` finds no other sampling of a symmetric Hamming or Blackman window. The only use is `Window.hamming.symmetric.analysis(frame: 257)`, at `WindowAnalysisTests.swift:74`.
  - *Gate m501a* (`run-gates.sh m501a`): `WindowTests` passed, 6 of 6. The one failure is `WindowAnalysisTests.swift:75` (`shapeAndEdgesOfTheStockWindows`, WP-501d). This is what the finding states.
  - *Untouched build.* My probe finds `.symmetric` of `.hamming`, `.blackman`, `.hann(.normalized)` and `.hann` at 8, 64 and 1 001 samples equal to vDSP of `count − 1` closed with its first value, bit for bit, in both precisions. The verifier's probe finds 135 cases with no mismatch.
  - *Under m501a,* both probes fail:
    - mine with 6 issues: Hamming in both precisions, and Blackman in double. vDSP's single-precision Blackman starts at exactly 0, so closing it with 0 changes nothing there;
    - the verifier's with 1 issue whose `vdsp-set.txt` lists 26 mismatches, all in the same forms.
- **Verdict.** Confirmed. Blocking: the acceptance check does not exercise the code.

### B-5 — the golden grid lacks 4 096 (WP-501b)

- **Rule.**
  - STG-2 (line 1837): "Oracle, grid and tolerance are those of the table below unless the row says otherwise".
  - The table (line 1848) gives `scipy.signal.get_window`, each window, lengths 16, 1 024 and 4 096, periodic and symmetric, within 10⁻⁶.
  - The row (line 2073) says "Golden" and nothing otherwise.
- **Change request.** None narrows the grid. CR-012 (line 23) names the golden test at 10⁻¹². CR-007 (line 32) names `get_window` only among the SciPy functions the host's loader could call. No other change request mentions the package set's golden test.
- **Pristine; reproduction.** `windows.py`, `windows.json` and `WindowTests.swift` equal the main tree.
  - `sed -n 14p Tests/Golden/generators/windows.py` prints `for count in (2, 5, 16, 63, 64, 1024):`.
  - `WindowTests.swift:60` asserts `golden.cases.count == 6 * 2 * (3 + 4 + 3)`.
  - `windows.json` holds 120 cases, 20 at each of 2, 5, 16, 63, 64 and 1 024.
  - My run of `vbWindowSamples()` on the untouched build wrote a `windows.txt` byte-identical to the verifier's `.build/vbprobe4096/windows.txt`.
  - `check_scipy_windows.py` on mine: 60 cases (16, 1 024 and 4 096; both forms), largest deviation 4.66·10⁻¹⁵, 0 problems.
- **Verdict.** Confirmed. Blocking: an acceptance check of the row is missing in part. The product is right.

### B-6 — `Level(.rms)` emits +∞ for a finite signal (WP-506)

- **Rule.**
  - NUM-1 (line 1005) is headed "No NaN, no infinity". Its body speaks of divisions, logarithm floors and non-finite source samples, but the heading is general.
  - §6.2 (line 1012) defines `Level` as peak or RMS in dBFS. The RMS of a constant 10¹⁸ is 360 dBFS, which a `Float` holds.
  - The cause is in the code:
    - the mean square is computed in single precision (`LevelAndWaveformNodes.swift:45`); for a constant 10¹⁸ over 480 samples its sum of squares, 4.8·10³⁸, exceeds `Float.greatestFiniteMagnitude`;
    - `DSP.decibels(fromPower: +∞)` returns `Double.greatestFiniteMagnitude` (`Amplification.swift:105`);
    - `Float(decibels)` at `:52` makes that +∞, emitted with confidence 1.
  - The vector conversion clamps to the `Float` range (`Amplification.swift:159–166`).
  - The finding lies in lens N's domain, raised by the lens-R verifier. §11.6 does not grade by lens.
- **Change request.** None.
- **Pristine; reproduction.** `LevelAndWaveformNodes.swift` and `Amplification.swift` equal the main tree.
  - *The documented route,* on the untouched build: copy `VerifierBProbes.swift`, build, then `test-only 'ZTronDSPAnalysisTests/VerifierBProbes/vbTheLevelOfAFiniteSignalIsFinite()'`. Two differences: three other probe files were in the targets as well, and I did not rebuild afterwards, because `.build/` is removed.
  - *Result:* 4 issues at `VerifierBProbes.swift:107`. The `level-range.txt` figures:
    - RMS: 10¹⁷ is 340 dB; 10¹⁸, 10¹⁹, 10²⁰ and `Float.greatestFiniteMagnitude` are `inf`, with confidence 1;
    - peak: 360, 380, 400 and 770.6368 dB;
    - `STFT; Power(); Decibels()` of 10²⁰ stays finite, with 385.31842 the largest value.

    The control and the m501c run show the same 4 issues.
  - *My own probe*, `Level(…, window: 0.02, hop: 0.01)`:
    - a sine of amplitude 2·10¹⁸ gives RMS `inf` in 9 of 9 values (confidence 1) and peak 366.0206 dB;
    - a constant 10¹⁹ gives RMS `inf`;
    - a constant 10¹⁷ gives 340 dB for both kinds.
  - *Reach.* At 10 ms the reach starts near 8.4·10¹⁷ (480 samples), and lower for longer windows: about 358 dB above full scale.
- **Verdict.** Confirmed. Blocking: a result is wrong, the step emits infinity for a finite input, and §11.6 has no threshold of materiality. The reach is narrow.

## Duty 2 — gaps in the verification

| Package | Gap |
|---|---|
| WP-508 (T) | **COV-3 of a changed file not reported.** The row names `Frequency.mel`, which lives in `Sources/ZTronDSPCore/Units/Frequency.swift`. The report gives COV-3 for `MelFormula.swift` and `MelFilterBank.swift` only, and the file is not in `VerifierB/cov-files.txt`. From the verifier's own coverage data (`lines-vbA.json`) it is 109 of 110 lines, 99.09 %. The one line not reached, `:86`, is the error for a mel value without a formula. The figure passes; the report is silent on it |
| WP-501g (T) | **The same, minor.** The attach-time logging hook is `Steps/STFT.swift:116`, the line the verifier's gate m501g mutates. The report's COV-3 line lists `WindowDiagnostics.swift` and `WindowAnalysisExport.swift` only. The verifier's per-file gate gives `STFT.swift` 100 % (55 of 55) |
| WP-502, 504, 505, 506, 507, 509, 510, 511, 512, 534, 535, 536 (R) | **Lens R duties passed over in silence** (§11.5: lens R checks "RT-1…RT-9"). No report mentions RT-1, RT-8 or RT-9, not even as not applicable. RT-7 layer 1 (C function-effect errors) is cited by none. Layer 4 (the lint bans in hot directories) appears only in the received-material line "The test, lint and coverage output", although the verifier ran `Scripts/lint-bans.sh` (`lint-bans: clean (parts 1, 2, 3, 4; 562 files)`, `.build/vb-gate-lint-bans.sh.out`). Layer 2 is addressed in WP-510 (its finding 2) and WP-535 only; layer 3, the allocation audit, in all twelve. RT-4 is addressed in WP-506, 507 and 511 only, though WP-512 (`MFCC`), 534 (`Spectrogram`), 535 (`MelSpectrogram`) and 536 (`Waveform`) write feeds, one of the channels RT-4 names. Most of these rules do not reach an analysis step, but the reports should say so |
| WP-540 (N) | **An acceptance check passed without evidence.** "They run under Octave" was not run, because Octave is not installed. The report says so, and the verdict is "`pass` (the Octave run not verified: CR-007, CR-019)". The change requests record it, so it waits for the owner. Until then the second half of the row's acceptance is unverified |
| WP-501e (T) | **A pass supported only in part, and FIX-4 not applied.** The test asserts "located within one sample" only up to 4 096 samples: at 16 384 it allows four (`WindowAnalysisTests.swift:178`, `1 / min(frame, 4 096)`). The verifier's finding 1 shows that, with WIN-6's step of at least 2⁻¹² of the frame, the code places a jump within one sample only up to 8 192 samples, and within two at 16 384. It records this as non-blocking "for the integrator" and files no change request, although FIX-4 asks for one when the document is wrong or ambiguous |

No package lacks a report: all 25 are present, each with the second lens of its row. Every lens-T report gives a COV-3 line and names the gated changes it made; I found the COV-3 line incomplete only for WP-508 and WP-501g. WP-537 is the one `ALG` row among the lens-N reports. Its currency record is checked (`Docs/Numerics/inversion-analysis.md`, `currency-2026-11.md` row 22), and so is its stability note against the code, with gate m538.

## Spot checks (five `pass` verdicts whose reports give no figures)

For each check below, the report's result column says only `pass`. Where the row also asks for zero allocations, I did not re-check that part.

| Package | Acceptance check | What I ran | What I found |
|---|---|---|---|
| WP-505 (R) | Reconstruction SNR ≥ 100 dB | `InverseSTFTTests` on the untouched build. Also my probe `spotRoundTripFigures()`, with the test's signal, alignment and delay | The suite passed; `theRoundTripReconstructsTheSignal(stft:)`, 11 cases, passed. SNR by configuration: Hann 2 048/512 → 139.1 dB; Hamming 1 024/256 → 138.7; Blackman 240/80 → 138.1; rectangular 1 024/1 024 → 135.5; Kaiser β 6 1 024/128 `.power` → 138.9; centred Hann 2 048/512 → 139.1. All hold, with 35 dB of margin |
| WP-507 (R) | §6.5 acceptance, apart from zero allocations | `SpectralCentroidTests`, and `spotCentroidFigures()` | The suite passed. White noise over 200 frames: 12 035.9 Hz on magnitudes (+0.30 % from f_s/4) and 12 072.1 Hz on powers (+0.60 %); the limit is 2 %. Sines at 440, 1 234.5 and 20 003.7 Hz: largest deviations 0.38, 0.80 and 1.12 Hz, against half a bin of 23.44 Hz. Silence: confidence 0 and value 0 in all 13 frames |
| WP-511 (R) | f₀ within 1 %; mean confidence higher on the harmonic fixture than on noise | `CepstrumTests`, and `spotPitchFigures()` | The suite passed. Worst relative error over 25 frames: 110 Hz 0.974 %, 220 Hz 0.542 %, 329.63 Hz 0.254 %, 440 Hz 0.084 %. Confidence 0.888 … 0.967. Mean confidence 0.940 (harmonic, 196 Hz) against 0.760 (noise). 110 Hz holds by 0.026 percentage points, as CR-019 item 13 records |
| WP-501f (T) | Reference figures within 0.1 dB and 0.05 bin | `WindowAnalysisTests`. Then `spot_501f.py`: the golden figures recomputed without SciPy, from the window definitions and a 256-times zero-padded transform, for rectangular, Hann, Hamming, Blackman and Blackman–Harris at 64, 1 024 and 4 096 | The suite passed; `theFiguresOfTheStockWindowsEqualTheReference(name:)`, 24 cases, passed. The golden figures equal my recomputation: the largest differences print as 0.0000 bin and 0.0001 dB. Against Harris (1978), Table 1, they agree to his printed precision except in four places. In each, the recomputation from the definition gives the golden value: the Hann side lobe (−31.47 dB; he prints −32), the Hamming side lobe at 64 samples (−42.45 dB; −43), the Hamming scalloping loss (1.75 dB; 1.78) and the Blackman 3 dB width (1.64 bins; 1.68) |
| WP-534 (R) | Analytic values; the O-3 and O-4 fixtures (not the allocation audit) | `ValueStepTests`. `Scripts/compile-fixtures.sh` on copies of the 7 must-not-compile fixtures `O-03-*` and `O-04-*` and the must-compile `OrderRulesOfTheSpectralFrontEnd.swift`. A self-test of the harness: the valid fixture filed as invalid, and `O-04-DecibelsAfterSTFT.swift` filed as valid | The suite ("Value steps") passed, including `magnitudeAndPowerAreWhatTheirNamesSay()`, `aFullScaleSineReadsZeroDecibelsWithEitherValue()`, `silenceIsTheFloorAndNeverMinusInfinity()` and `inverseDecibelsUndoesDecibelsAboveTheFloor()`. Fixtures: "1 valid fixtures compile, 7 invalid fixtures fail with their sentences". The self-test reported "2 of 2 fixtures misbehave (1 valid, 1 invalid)", so the harness really type-checks |

## Restoration and clean-up

- My four probe files were removed from `Tests/` after the untouched-build runs. `diff -rq Tests .build/pristine/Tests` was then clean, and `mutations.py apply` ran on a pristine tree.
- After the gated runs I removed my two files, and `mutations.py restore` printed: "restored 18 files; Sources, Tests, Scripts, Package.swift, Docs/Numerics and Docs/API equal the pristine copy byte for byte".
- I compared again myself, with `diff -rq` and `cmp`:
  - `Sources/`, `Tests/`, `Scripts/`, `Docs/Numerics/`, `Docs/API/`, `Package.swift` and `ExternalParity/` equal the pristine copy;
  - `Docs/` differs from it only by the verifier's 25 reports (this file was written afterwards);
  - the files named in the findings, and `DesignExampleTests.swift`, equal the main tree by SHA-256.
- Modification times were put back from the pristine copy with the README's `touch -r` loop. Apart from this report, no file outside `.build/` is newer than the start of the audit (checked with `find -newermt`), and no `__pycache__` exists outside it.
- After this report: the rsync to the hand-over named in the brief, `xcrun simctl shutdown ztdsp-27-vm5ab`, and `rm -rf …/ZTronDSP/.build`. That removes my probes and outputs, which is why they are reproduced below.

## Appendix A — the audit's probes and script

The probes were kept in `.build/audit/probes/` and copied into the test targets only for the runs. Each writes what it measured to `$AUDIT_OUT` (`TEST_RUNNER_AUDIT_OUT`). The three files are reproduced here byte for byte, because `.build/` is removed after this report.

`AuditBCoreProbes.swift` (into `Tests/ZTronDSPCoreTests/`):

```swift
import Accelerate
import Foundation
import Testing
@testable import ZTronDSPCore

// Auditor of Verifier B (M5a), temporary: copied into Tests/ZTronDSPCoreTests for a run and
// removed afterwards. Not part of the package. Writes what it measured to $AUDIT_OUT/<name>
// (TEST_RUNNER_AUDIT_OUT) and records an issue where it sees the defect a finding claims.
@Suite("Audit B core probes")
struct AuditBCoreProbes {
    static func output(_ name: String, _ text: String) {
        guard let directory = ProcessInfo.processInfo.environment["AUDIT_OUT"] else { return }
        try? text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
    }

    static var gate: String { ProcessInfo.processInfo.environment["VB_MUT"] ?? "none" }

    // B-1: single-precision samples of custom windows whose double-precision samples pass WIN-3.
    @Test func auditSinglePrecisionSamplesOfACustomWindow() {
        var lines: [String] = []
        let cases: [(String, Window)] = [
            ("3.5e38 everywhere", .custom { _ in 3.5e38 }),
            ("1e39 everywhere", .custom { _ in 1e39 }),
            ("1e39 everywhere, symmetric", Window.custom { _ in 1e39 }.symmetric),
            ("1e-46 everywhere", .custom { _ in 1e-46 }),
            ("1e-50 everywhere", .custom { _ in 1e-50 }),
            ("1e30 everywhere (control)", .custom { _ in 1e30 }),
        ]
        for (name, window) in cases {
            let double: [Double]
            do { double = try window.doubleSamples(count: 64) } catch {
                lines.append("\(name): doubleSamples(count: 64) refused: \(error)")
                continue
            }
            do {
                let single = try window.samples(count: 64)
                let nonFinite = single.filter { !$0.isFinite }.count
                let nonZero = single.filter { $0 != 0 }.count
                lines.append("\(name): doubleSamples all finite \(double.allSatisfy(\.isFinite)), \(double.filter { $0 != 0 }.count) non-zero; samples(count: 64) returned \(single.count) values, \(nonFinite) not finite, \(nonZero) not zero, first \(single[0])")
                if nonFinite > 0 || nonZero == 0 {
                    Issue.record("B-1 \(name): samples(count:) returned \(nonFinite) non-finite and \(nonZero) non-zero samples without an error")
                }
            } catch {
                lines.append("\(name): samples(count: 64) refused: \(error)")
            }
        }
        Self.output("audit-b1-core.txt", lines.joined(separator: "\n") + "\n")
    }

    // B-2: two separately written equal closures, as ExternalParity's
    // Tests/ExtensionGuideTests/DesignExampleTests.swift:89-90 compares them.
    static var sine: Window { .custom { t in sin(.pi * t) } }

    @Test func auditSeparatelyWrittenEqualClosuresAreEqual() {
        let same = Window.custom({ t in sin(.pi * t) })
        let equal = Self.sine == same
        let twice = Self.sine == Self.sine
        Self.output("audit-b2-core-\(Self.gate).txt",
                    "VB_MUT=\(Self.gate): sine == same \(equal); sine == sine (two accesses) \(twice); equal hashes \(Self.sine.hashValue == same.hashValue)\n")
        #expect(equal, "two separately written equal closures are one window (WIN-2)")
        #expect(twice, "two instances of one closure are one window (WIN-2)")
    }

    // B-4: the symmetric vDSP windows against the vDSP call of count - 1 samples closed with its
    // first value (WIN-1), in both precisions.
    @Test func auditSymmetricVDSPWindowsAreTheVDSPCall() {
        typealias Single = (UnsafeMutablePointer<Float>, vDSP_Length, Int32) -> Void
        typealias Double_ = (UnsafeMutablePointer<Double>, vDSP_Length, Int32) -> Void
        let set: [(String, Window, Single, Double_, Int32)] = [
            ("hamming", .hamming, vDSP_hamm_window, vDSP_hamm_windowD, 0),
            ("blackman", .blackman, vDSP_blkman_window, vDSP_blkman_windowD, 0),
            ("hann(.normalized)", .hann(.normalized), vDSP_hann_window, vDSP_hann_windowD, Int32(vDSP_HANN_NORM)),
            ("hann", .hann, vDSP_hann_window, vDSP_hann_windowD, Int32(vDSP_HANN_DENORM)),
        ]
        var lines: [String] = []
        for count in [8, 64, 1_001] {
            for (name, window, single, double, flags) in set {
                var expected = [Float](repeating: 0, count: count)
                single(&expected, vDSP_Length(count - 1), flags)
                expected[count - 1] = expected[0]
                var expectedD = [Double](repeating: 0, count: count)
                double(&expectedD, vDSP_Length(count - 1), flags)
                expectedD[count - 1] = expectedD[0]
                let got = (try? window.symmetric.samples(count: count)) ?? []
                let gotD = (try? window.symmetric.doubleSamples(count: count)) ?? []
                let same = got.map(\.bitPattern) == expected.map(\.bitPattern)
                let sameD = gotD.map(\.bitPattern) == expectedD.map(\.bitPattern)
                lines.append("\(name).symmetric, \(count): single bit for bit \(same) (last \(got.last ?? .nan), vDSP closed \(expected[count - 1])); double bit for bit \(sameD)")
                #expect(same && sameD, "\(name).symmetric, \(count) samples")
            }
        }
        Self.output("audit-b4-\(Self.gate).txt", lines.joined(separator: "\n") + "\n")
    }
}
```

`AuditBProbes.swift` (into `Tests/ZTronDSPAnalysisTests/`; it uses that target's `Support.swift`):

```swift
import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

// Auditor of Verifier B (M5a), temporary: copied into Tests/ZTronDSPAnalysisTests for a run and
// removed afterwards. Not part of the package. Writes what it measured to $AUDIT_OUT/<name>
// (TEST_RUNNER_AUDIT_OUT) and records an issue where it sees the defect a finding claims.
@Suite("Audit B probes")
struct AuditBProbes {
    static func output(_ name: String, _ text: String) {
        guard let directory = ProcessInfo.processInfo.environment["AUDIT_OUT"] else { return }
        try? text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
    }

    static var gate: String { ProcessInfo.processInfo.environment["VB_MUT"] ?? "none" }

    // B-1 in a step: an STFT whose window passes the double-precision check of WIN-3.
    @Test func auditAnSTFTWithAWindowOutsideTheSingleRange() {
        let signal = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 4_096, amplitude: 0.5)
        var lines: [String] = []
        let cases: [(String, Window)] = [
            ("custom { _ in 3.5e38 }", .custom { _ in 3.5e38 }),
            ("custom { _ in 1e-46 }", .custom { _ in 1e-46 }),
            ("custom { _ in 1e30 } (control)", .custom { _ in 1e30 }),
        ]
        for (name, window) in cases {
            do {
                let frames: [[Float]] = try Pipeline { STFT(frame: 256, hop: 128, window: window); Magnitude() }.process(signal, format: mono48)
                let values = frames.flatMap { $0 }
                let nonFinite = values.filter { !$0.isFinite }.count
                let nonZero = values.filter { $0 != 0 }.count
                lines.append("STFT(frame: 256, hop: 128, window: .\(name)); Magnitude(): attached; \(frames.count) frames, \(nonFinite) of \(values.count) values not finite, \(nonZero) not zero")
                if nonFinite > 0 || nonZero == 0 {
                    Issue.record("B-1: \(name) attached and gave \(nonFinite) non-finite and \(nonZero) non-zero magnitudes")
                }
            } catch {
                lines.append("STFT(frame: 256, hop: 128, window: .\(name)): refused at attach: \(error)")
            }
        }
        Self.output("audit-b1-stft.txt", lines.joined(separator: "\n") + "\n")
    }

    // B-2 through pipelines, as ExternalParity's DesignExampleTests.swift:91 compares them.
    static func roundTrip(frame: Int) -> Pipeline<Samples, Samples> {
        Pipeline {
            STFT(frame: frame, hop: frame / 2, window: .custom { t in sin(.pi * t) })
            InverseSTFT(window: .custom { t in sin(.pi * t) })
        }
    }

    @Test func auditTwoPipelinesWithEqualCustomWindowsAreEqual() {
        let equal = Self.roundTrip(frame: 1_024) == Self.roundTrip(frame: 1_024)
        let differ = Self.roundTrip(frame: 1_024) != Self.roundTrip(frame: 2_048)
        Self.output("audit-b2-pipelines-\(Self.gate).txt", "VB_MUT=\(Self.gate): two equal pipelines compare equal \(equal); different frames differ \(differ)\n")
        #expect(equal && differ, "pipelines holding equal custom windows are equal (WIN-2, API-1)")
    }

    // B-3: the error of a silent frame beside a smaller error elsewhere.
    @Test func auditTheErrorOfASilentFrameCounts() {
        let alone = InversionMeasurement(InversionRoundTrip(original: [1, 0, 0, 0], reconstruction: [1, 0, 0, 1], frameLength: 2))
        let beside = InversionMeasurement(InversionRoundTrip(original: [1, 0, 0, 0], reconstruction: [1.1, 0, 0, 1], frameLength: 2))
        let samples = InversionMeasurement(InversionRoundTrip(original: [1, 0, 0, 0], reconstruction: [1.1, 0, 0, 1]))
        Self.output("audit-b3.txt", """
            frames of 2, original [1, 0 | 0, 0]
            reconstruction [1, 0 | 0, 1]:   largestError \(alone.largestError), relativeError \(alone.relativeError), SNR \(alone.signalToNoiseRatio)
            reconstruction [1.1, 0 | 0, 1]: largestError \(beside.largestError), relativeError \(beside.relativeError), SNR \(beside.signalToNoiseRatio)
            the same as samples:            largestError \(samples.largestError), relativeError \(samples.relativeError)

            """)
        #expect(beside.relativeError >= alone.relativeError,
                "an added error of 0.1 in the first frame lowers the measured relative error from \(alone.relativeError) to \(beside.relativeError)")
    }

    // B-6: the level of a finite signal whose sum of squares over a window leaves the Float range.
    @Test func auditTheLevelOfALoudFiniteSignal() throws {
        var lines: [String] = []
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 4_800, amplitude: 2e18)
        let constant = TestSignal.constant(1e19, count: 4_800)
        let control = TestSignal.constant(1e17, count: 4_800)
        for (name, signal) in [("sine of amplitude 2e18", sine), ("constant 1e19", constant), ("constant 1e17 (control)", control)] {
            for kind in [LevelKind.rms, .peak] {
                let values: [ScalarFrame] = try Pipeline { Level(kind, window: 0.02, hop: 0.01) }.process(signal, format: mono48)
                let bad = values.filter { !$0.value.isFinite }.count
                lines.append("Level(.\(kind), window: 0.02, hop: 0.01) of a \(name): \(values.count) values, \(bad) not finite; values \(values.map(\.value)); confidences \(Set(values.map(\.confidence)))")
                #expect(bad == 0, "Level(.\(kind)) of a \(name): \(values.map(\.value))")
            }
        }
        Self.output("audit-b6.txt", lines.joined(separator: "\n") + "\n")
    }

    // Spot checks: the figures behind three acceptance checks the verifier passed.

    // WP-511: f0 of a harmonic fixture within 1 % (the fixture and pipeline of CepstrumTests).
    @Test func spotPitchFigures() throws {
        var lines: [String] = []
        for fundamental in [110.0, 220, 329.63, 440] {
            let fixture = TestSignal.harmonic(fundamental: fundamental, amplitudes: (1 ... 20).map { 1 / Double($0) }, sampleRate: 48_000, count: 16_384).map { $0 * 0.3 }
            let pitches: [ScalarFrame] = try Pipeline { STFT(frame: 4_096, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(80 ... 600)) }.process(fixture, format: mono48)
            let worst = pitches.map { abs(Double($0.value) - fundamental) / fundamental }.max() ?? .nan
            lines.append("f0 \(fundamental) Hz: \(pitches.count) frames, worst relative error \(worst * 100) %, confidence \(pitches.map(\.confidence).min() ?? .nan) ... \(pitches.map(\.confidence).max() ?? .nan)")
        }
        let harmonic = TestSignal.harmonic(fundamental: 196, amplitudes: (1 ... 24).map { 1 / Double($0) }, sampleRate: 48_000, count: 32_768).map { $0 * 0.3 }
        let pipeline = Pipeline { STFT(frame: 2_048, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(60 ... 500)) }
        let voiced: [ScalarFrame] = try pipeline.process(harmonic, format: mono48)
        let unvoiced: [ScalarFrame] = try pipeline.process(TestSignal.gaussianNoise(count: 32_768, seed: 511, standardDeviation: 0.2), format: mono48)
        let voicedMean = voiced.reduce(0) { $0 + Double($1.confidence) } / Double(voiced.count)
        let unvoicedMean = unvoiced.reduce(0) { $0 + Double($1.confidence) } / Double(unvoiced.count)
        lines.append("mean confidence: harmonic 196 Hz \(voicedMean) over \(voiced.count) frames, white noise \(unvoicedMean) over \(unvoiced.count) frames")
        Self.output("spot-511.txt", lines.joined(separator: "\n") + "\n")
    }

    // WP-505: reconstruction SNR >= 100 dB (the signal and alignment of InverseSTFTTests).
    @Test func spotRoundTripFigures() throws {
        let signal = TestSignal.sum(TestSignal.whiteNoise(count: 30_000, seed: 505, amplitude: 0.4),
                                    TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 30_000, amplitude: 0.5))
        var lines: [String] = []
        for stft in [STFT(frame: 2_048, hop: 512), STFT(frame: 1_024, hop: 256, window: .hamming), STFT(frame: 240, hop: 80, window: .blackman),
                     STFT(frame: 1_024, hop: 1_024, window: .rectangular), STFT(frame: 1_024, hop: 128, window: .kaiser(beta: 6), normalization: .power),
                     STFT(frame: 2_048, hop: 512, alignment: .centered)] {
            let output = try Pipeline { stft; stft.inverse }.process(signal, format: mono48)
            let delay = InverseSTFT.delay(frame: stft.frame, hop: stft.hop, alignment: stft.alignment).total
            let first = stft.alignment == .centered ? 0 : stft.frame
            let reconstructed = Array(output[(delay + first)...])
            let reference = Array(signal[first ..< first + reconstructed.count])
            lines.append("\(stft.window), frame \(stft.frame), hop \(stft.hop), \(stft.alignment): delay \(delay), \(reconstructed.count) samples compared, SNR \(signalToNoise(reconstructed, reference)) dB")
        }
        Self.output("spot-505.txt", lines.joined(separator: "\n") + "\n")
    }

    // WP-507: the acceptance of §6.5 (the STFT and signals of SpectralCentroidTests).
    @Test func spotCentroidFigures() throws {
        let stft = STFT(frame: 1_024, hop: 256, window: .hann)
        var lines: [String] = []
        let noise = TestSignal.gaussianNoise(count: 256 * 203 + 1_024, seed: 507, standardDeviation: 0.2)
        let magnitudes: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(noise, format: mono48)
        let powers: [ScalarFrame] = try Pipeline { stft; Power(); SpectralCentroid() }.process(noise, format: mono48)
        for (name, values) in [("magnitudes", magnitudes), ("powers", powers)] {
            let mean = values.prefix(200).reduce(0) { $0 + Double($1.value) } / 200
            lines.append("white noise, \(name): \(values.count) frames, mean of the first 200 \(mean) Hz, \((mean - 12_000) / 12_000 * 100) % from fs/4")
        }
        for frequency in [440.0, 1_234.5, 20_003.7] {
            let sine = TestSignal.sine(frequency: frequency, sampleRate: 48_000, count: 16_384, amplitude: 0.7)
            let values: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(sine, format: mono48)
            let worst = values.map { abs(Double($0.value) - frequency) }.max() ?? .nan
            lines.append("sine \(frequency) Hz, magnitudes: \(values.count) frames, largest deviation \(worst) Hz (half a bin is \(48_000.0 / 1_024 / 2) Hz)")
        }
        let silence: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(TestSignal.silence(count: 4_096), format: mono48)
        lines.append("silence: \(silence.count) frames, confidences \(Set(silence.map(\.confidence))), values \(Set(silence.map(\.value)))")
        Self.output("spot-507.txt", lines.joined(separator: "\n") + "\n")
    }
}
```

`spot_501f.py`:

```python
"""Auditor of Verifier B (M5a), spot check of WP-501f: the reference figures of the golden file
window_analysis.json, recomputed here without SciPy, from the window definitions and a transform
zero-padded 256 times, and set beside Harris (1978), Table 1.

    python3 -I -B .build/audit/spot_501f.py Tests/ZTronDSPAnalysisTests/Golden/window_analysis.json
"""
import json
import sys

import numpy as np

path = sys.argv[1]
golden = {c["name"]: c for c in json.load(open(path))["cases"]}


def window(name, n):
    k = np.arange(n)
    x = 2 * np.pi * k / n  # periodic
    if name == "rectangular":
        return np.ones(n)
    if name == "hann":
        return 0.5 - 0.5 * np.cos(x)
    if name == "hamming":
        return 0.54 - 0.46 * np.cos(x)
    if name == "blackman":
        return 0.42 - 0.5 * np.cos(x) + 0.08 * np.cos(2 * x)
    if name == "blackmanHarris":
        return 0.35875 - 0.48829 * np.cos(x) + 0.14128 * np.cos(2 * x) - 0.01168 * np.cos(3 * x)
    raise KeyError(name)


def figures(w, pad=256):
    n = len(w)
    m = n * pad
    spectrum = np.abs(np.fft.rfft(w, m))
    db = 20 * np.log10(np.maximum(spectrum / spectrum[0], 1e-300))
    bins = np.arange(len(db)) / pad
    # -3 dB half width, linear interpolation between grid points.
    i = np.argmax(db < -3.0103)
    half = bins[i - 1] + (bins[i] - bins[i - 1]) * (-3.0103 - db[i - 1]) / (db[i] - db[i - 1])
    # First null: first local minimum.
    j = 1
    while db[j + 1] < db[j]:
        j += 1
    null = bins[j]
    side = db[j:].max()
    scalloping = -db[pad // 2]
    return 2 * half, 2 * null, side, scalloping


harris = {  # 3 dB bandwidth (bins), highest side lobe (dB), scalloping loss (dB): Harris 1978, Table 1
    "rectangular": (0.89, -13, 3.92),
    "hann": (1.44, -32, 1.42),
    "hamming": (1.30, -43, 1.78),
    "blackman": (1.68, -58, 1.10),
    "blackmanHarris": (1.90, -92, 0.83),
}

print("window, N: golden (3 dB width, null to null, side lobe, scalloping) | recomputed | Harris (3 dB, side lobe, scalloping)")
worst_db = worst_bin = 0.0
for name in harris:
    for n in (64, 1024, 4096):
        g = golden["%s-%d" % (name, n)]["values"]["spectrum"]
        r = figures(window(name, n))
        worst_bin = max(worst_bin, abs(g[0] - r[0]), abs(g[1] - r[1]))
        worst_db = max(worst_db, abs(g[2] - r[2]), abs(g[3] - r[3]))
        print("%-15s %5d: %.4f %.4f %8.3f %.4f | %.4f %.4f %8.3f %.4f | %.2f %d %.2f" % ((name, n) + tuple(g[:4]) + r + harris[name]))
print("largest difference golden - recomputed: %.4f bin, %.4f dB (the package is held to 0.05 bin and 0.1 dB of golden)" % (worst_bin, worst_db))
```

## Appendix B — outputs, verbatim

Every block below is the text of the file named, or the lines of it that the caption names, as written by the runs described above. The test runner puts zero-width spaces before some lines; they are left out.

B-1, from the untouched build: my `audit-b1-core.txt`, then my `audit-b1-stft.txt` (its third line is the ill-chosen control discussed in B-1):

```
3.5e38 everywhere: doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 64 not finite, 64 not zero, first inf
1e39 everywhere: doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 64 not finite, 64 not zero, first inf
1e39 everywhere, symmetric: doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 64 not finite, 64 not zero, first inf
1e-46 everywhere: doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 0 not finite, 0 not zero, first 0.0
1e-50 everywhere: doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 0 not finite, 0 not zero, first 0.0
1e30 everywhere (control): doubleSamples all finite true, 64 non-zero; samples(count: 64) returned 64 values, 0 not finite, 64 not zero, first 1e+30
```

```
STFT(frame: 256, hop: 128, window: .custom { _ in 3.5e38 }); Magnitude(): attached; 31 frames, 3999 of 3999 values not finite, 3999 not zero
STFT(frame: 256, hop: 128, window: .custom { _ in 1e-46 }); Magnitude(): attached; 31 frames, 0 of 3999 values not finite, 0 not zero
STFT(frame: 256, hop: 128, window: .custom { _ in 1e30 } (control)); Magnitude(): attached; 31 frames, 3999 of 3999 values not finite, 3999 not zero
```

B-1, from the untouched build: the verifier's `stft-window-precision.txt`, then its `custom-errors.txt`:

```
STFT(frame: 256, hop: 64, window: .custom { _ in 1e39 }): attached and ran: 61 frames, 15616 of 15738 values not finite, 15616 not zero
  with normalization: .amplitude: 61 frames, finite true, non-zero true
STFT(frame: 256, hop: 64, window: .custom { _ in 1e-50 }): attached and ran: 61 frames, 0 of 15738 values not finite, 0 not zero
  with normalization: .amplitude: 61 frames, finite true, non-zero true
STFT(window: .custom { _ in 1e39 }); Power(); Decibels(): 0 of 7869 values not finite; first -160.0
```

```
1e39: samples(count: 64) returned 64 values, 64 not finite, 64 not zero; first inf; double samples finite true and non-zero true
1e-50: samples(count: 64) returned 64 values, 0 not finite, 0 not zero; first 0.0; double samples finite true and non-zero true
4e38 at the centre: samples(count: 64) returned 64 values, 1 not finite, 64 not zero; first 1.0; double samples finite true and non-zero true
```

B-2: my two files without the gate, then under m501c; then the verifier's `custom-equality.txt` from the untouched build:

```
VB_MUT=none: sine == same true; sine == sine (two accesses) true; equal hashes true
VB_MUT=none: two equal pipelines compare equal true; different frames differ true
VB_MUT=m501c: sine == same false; sine == sine (two accesses) false; equal hashes true
VB_MUT=m501c: two equal pipelines compare equal false; different frames differ true
```

```
a == b: true, hash equal: true
t - 0.5 against -(0.5 - t): equal windows false, equal samples true
```

B-2: the lines of `.build/vbmut/m501c.out` that close a test run or a failed suite:

```
✔ Test run with 334 tests in 40 suites passed after 58.319 seconds.
✘ Suite "Audit B core probes" failed after 16.057 seconds with 7 issues.
✘ Suite "Verifier B core probes" failed after 16.238 seconds with 6 issues.
✘ Test run with 487 tests in 57 suites failed after 29.551 seconds with 13 issues.
✘ Suite "Audit B probes" failed after 73.923 seconds with 7 issues.
✘ Suite "Verifier B probes" failed after 104.532 seconds with 7 issues.
✘ Test run with 432 tests in 43 suites failed after 222.882 seconds with 14 issues.
```

B-3, from the untouched build: my `audit-b3.txt`, then the verifier's `measurement-silent-frame.txt`:

```
frames of 2, original [1, 0 | 0, 0]
reconstruction [1, 0 | 0, 1]:   largestError 1.0, relativeError 1.0, SNR 0.0
reconstruction [1.1, 0 | 0, 1]: largestError 1.0, relativeError 0.10000002384185791, SNR -0.04321375833016519
the same as samples:            largestError 1.0, relativeError 1.0
```

```
frames of 2, original [10, 0, 1, 0, 0, 0]
reconstruction [10, 0, 1, 0, 0, 5]:   largestError 5.0, relativeError 0.5, SNR 6.063813651106049
reconstruction [10, 0, 1.1, 0, 0, 5]: largestError 5.0, relativeError 0.10000002384185791, SNR 6.062076819693381
as samples (frameLength 1), reconstruction [10, 0, 1.1, 0, 0, 5]: relativeError 0.5
```

B-4: the lines of `.build/vbmut/m501a.out` that close a test run or a suite, and its one issue:

```
✔ Test run with 6 tests in 1 suite passed after 0.047 seconds.
✘ Test shapeAndEdgesOfTheStockWindows() recorded an issue at WindowAnalysisTests.swift:75:9: Expectation failed: hamming.isSymmetric && abs(hamming.leadingEdgeValue - 0.08) < 1e-6 && abs(hamming.trailingEdgeValue - 0.08) < 1e-6
✘ Suite "Window analysis" failed after 1.642 seconds with 1 issue.
✘ Test run with 14 tests in 1 suite failed after 1.642 seconds with 1 issue.
```

B-4: my `audit-b4-none.txt` (untouched build), then `audit-b4-m501a.txt`:

```
hamming.symmetric, 8: single bit for bit true (last 0.08000001, vDSP closed 0.08000001); double bit for bit true
blackman.symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann(.normalized).symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hamming.symmetric, 64: single bit for bit true (last 0.08000001, vDSP closed 0.08000001); double bit for bit true
blackman.symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann(.normalized).symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hamming.symmetric, 1001: single bit for bit true (last 0.08000001, vDSP closed 0.08000001); double bit for bit true
blackman.symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann(.normalized).symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
```

```
hamming.symmetric, 8: single bit for bit false (last 0.0, vDSP closed 0.08000001); double bit for bit false
blackman.symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit false
hann(.normalized).symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 8: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hamming.symmetric, 64: single bit for bit false (last 0.0, vDSP closed 0.08000001); double bit for bit false
blackman.symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit false
hann(.normalized).symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 64: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hamming.symmetric, 1001: single bit for bit false (last 0.0, vDSP closed 0.08000001); double bit for bit false
blackman.symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit false
hann(.normalized).symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
hann.symmetric, 1001: single bit for bit true (last 0.0, vDSP closed 0.0); double bit for bit true
```

B-4: the verifier's `vdsp-set.txt`, untouched, then under m501a; then the summary lines of that m501a run (`run-b4-m501a.out`):

```
compared 135 cases; mismatches: []
```

```
compared 135 cases; mismatches: ["hamming symmetric 2 single", "hamming symmetric 2 double", "hamming symmetric 3 single", "hamming symmetric 3 double", "blackman symmetric 3 double", "hamming symmetric 4 single", "hamming symmetric 4 double", "blackman symmetric 4 double", "hamming symmetric 7 single", "hamming symmetric 7 double", "blackman symmetric 7 double", "hamming symmetric 8 single", "hamming symmetric 8 double", "blackman symmetric 8 double", "hamming symmetric 63 single", "hamming symmetric 63 double", "blackman symmetric 63 double", "hamming symmetric 64 single", "hamming symmetric 64 double", "blackman symmetric 64 double", "hamming symmetric 1001 single", "hamming symmetric 1001 double", "blackman symmetric 1001 double", "hamming symmetric 2048 single", "hamming symmetric 2048 double", "blackman symmetric 2048 double"]
```

```
✘ Test auditSymmetricVDSPWindowsAreTheVDSPCall() recorded an issue at AuditBCoreProbes.swift:89:17: Expectation failed: same && sameD
✘ Test auditSymmetricVDSPWindowsAreTheVDSPCall() failed after 0.013 seconds with 6 issues.
✘ Suite "Audit B core probes" failed after 0.014 seconds with 6 issues.
✘ Test vbTheVDSPSetInEveryFormIsTheVDSPCall() recorded an issue at VerifierBCoreProbes.swift:93:9: Expectation failed: mismatches.isEmpty
✘ Test vbTheVDSPSetInEveryFormIsTheVDSPCall() failed after 0.042 seconds with 1 issue.
✘ Suite "Verifier B core probes" failed after 0.044 seconds with 1 issue.
✘ Test run with 2 tests in 2 suites failed after 0.045 seconds with 7 issues.
```

B-5: `check_scipy_windows.py` on the `windows.txt` of my untouched run. The lines under "one sample" are the verifier's non-blocking finding 2 on WP-501b; a length of one is outside the oracle grid, and the script does not count them as problems:

```
compared 60 cases (lengths 16, 1024, 4096; periodic and symmetric) with scipy.signal.get_window; largest deviation 4.66e-15
one sample:
  rectangular periodic 1: package 1.0, get_window 1.0
  rectangular symmetric 1: package 1.0, get_window 1.0
  blackmanHarris periodic 1: package 6.0000000000001025e-05, get_window 1.0
  blackmanHarris symmetric 1: package 6.0000000000001025e-05, get_window 1.0
  flatTop periodic 1: package -0.0004210510000000013, get_window 1.0
  flatTop symmetric 1: package -0.0004210510000000013, get_window 1.0
  kaiser0 periodic 1: package 1.0, get_window 1.0
  kaiser0 symmetric 1: package 1.0, get_window 1.0
  kaiser5 periodic 1: package 0.03671089227128667, get_window 1.0
  kaiser5 symmetric 1: package 0.03671089227128667, get_window 1.0
  kaiser8.6 periodic 1: package 0.0013325139979024193, get_window 1.0
  kaiser8.6 symmetric 1: package 0.0013325139979024193, get_window 1.0
  kaiser24 periodic 1: package 4.611229355225043e-10, get_window 1.0
  kaiser24 symmetric 1: package 4.611229355225043e-10, get_window 1.0
  gauss0.1 periodic 1: package 3.726653172078671e-06, get_window 1.0
  gauss0.1 symmetric 1: package 3.726653172078671e-06, get_window 1.0
  gauss0.25 periodic 1: package 0.1353352832366127, get_window 1.0
  gauss0.25 symmetric 1: package 0.1353352832366127, get_window 1.0
  gauss0.5 periodic 1: package 0.6065306597126334, get_window 1.0
  gauss0.5 symmetric 1: package 0.6065306597126334, get_window 1.0
problems: 0
```

B-6, the documented route: `run-b6.out`, then the verifier's `level-range.txt` it wrote; then my `audit-b6.txt` from the untouched build:

```
✘ Test vbTheLevelOfAFiniteSignalIsFinite() recorded an issue at VerifierBProbes.swift:107:17: Expectation failed: values.count == 2 && values.allSatisfy { $0.value.isFinite }
✘ Test vbTheLevelOfAFiniteSignalIsFinite() failed after 0.057 seconds with 4 issues.
✘ Suite "Verifier B probes" failed after 0.060 seconds with 4 issues.
✘ Test run with 1 test in 1 suite failed after 0.062 seconds with 4 issues.
** TEST EXECUTE FAILED **
exit 65
```

```
Level(.rms, window: 0.01, hop: 0.01) of a constant 1.0: values [0.0, 0.0], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 1.0: values [0.0, 0.0], confidence [1.0, 1.0]
Level(.rms, window: 0.01, hop: 0.01) of a constant 1e+17: values [340.0, 340.0], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 1e+17: values [340.0, 340.0], confidence [1.0, 1.0]
Level(.rms, window: 0.01, hop: 0.01) of a constant 1e+18: values [inf, inf], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 1e+18: values [360.0, 360.0], confidence [1.0, 1.0]
Level(.rms, window: 0.01, hop: 0.01) of a constant 1e+19: values [inf, inf], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 1e+19: values [380.0, 380.0], confidence [1.0, 1.0]
Level(.rms, window: 0.01, hop: 0.01) of a constant 1e+20: values [inf, inf], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 1e+20: values [400.0, 400.0], confidence [1.0, 1.0]
Level(.rms, window: 0.01, hop: 0.01) of a constant 3.4028235e+38: values [inf, inf], confidence [1.0, 1.0]
Level(.peak, window: 0.01, hop: 0.01) of a constant 3.4028235e+38: values [770.6368, 770.6368], confidence [1.0, 1.0]
STFT(frame: 256, hop: 256); Power(); Decibels() of a constant 1e20: 516 values, all finite true, largest 385.31842
```

```
Level(.rms, window: 0.02, hop: 0.01) of a sine of amplitude 2e18: 9 values, 9 not finite; values [inf, inf, inf, inf, inf, inf, inf, inf, inf]; confidences [1.0]
Level(.peak, window: 0.02, hop: 0.01) of a sine of amplitude 2e18: 9 values, 0 not finite; values [366.0206, 366.0206, 366.0206, 366.0206, 366.0206, 366.0206, 366.0206, 366.0206, 366.0206]; confidences [1.0]
Level(.rms, window: 0.02, hop: 0.01) of a constant 1e19: 9 values, 9 not finite; values [inf, inf, inf, inf, inf, inf, inf, inf, inf]; confidences [1.0]
Level(.peak, window: 0.02, hop: 0.01) of a constant 1e19: 9 values, 0 not finite; values [380.0, 380.0, 380.0, 380.0, 380.0, 380.0, 380.0, 380.0, 380.0]; confidences [1.0]
Level(.rms, window: 0.02, hop: 0.01) of a constant 1e17 (control): 9 values, 0 not finite; values [340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0]; confidences [1.0]
Level(.peak, window: 0.02, hop: 0.01) of a constant 1e17 (control): 9 values, 0 not finite; values [340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0, 340.0]; confidences [1.0]
```

The spot checks, from the untouched build: `spot-505.txt`, `spot-507.txt`, `spot-511.txt`:

```
hann, frame 2048, hop 512, causal: delay 1536, 26112 samples compared, SNR 139.12625527956072 dB
hamming, frame 1024, hop 256, causal: delay 768, 28160 samples compared, SNR 138.65496386459301 dB
blackman, frame 240, hop 80, causal: delay 160, 29600 samples compared, SNR 138.05163342904143 dB
rectangular, frame 1024, hop 1024, causal: delay 0, 28672 samples compared, SNR 135.54409113472727 dB
kaiser(beta: 6.0), frame 1024, hop 128, causal: delay 896, 28032 samples compared, SNR 138.88881254541582 dB
hann, frame 2048, hop 512, centered: delay 1536, 28160 samples compared, SNR 139.11737826101665 dB
```

```
white noise, magnitudes: 204 frames, mean of the first 200 12035.880551757813 Hz, 0.29900459798177503 % from fs/4
white noise, powers: 204 frames, mean of the first 200 12072.131782226563 Hz, 0.6010981852213566 % from fs/4
sine 440.0 Hz, magnitudes: 61 frames, largest deviation 0.384613037109375 Hz (half a bin is 23.4375 Hz)
sine 1234.5 Hz, magnitudes: 61 frames, largest deviation 0.795654296875 Hz (half a bin is 23.4375 Hz)
sine 20003.7 Hz, magnitudes: 61 frames, largest deviation 1.1164062499992724 Hz (half a bin is 23.4375 Hz)
silence: 13 frames, confidences [0.0], values [0.0]
```

```
f0 110.0 Hz: 25 frames, worst relative error 0.9743638472123579 %, confidence 0.88812995 ... 0.90732753
f0 220.0 Hz: 25 frames, worst relative error 0.5417355624112217 %, confidence 0.93668175 ... 0.9428956
f0 329.63 Hz: 25 frames, worst relative error 0.2537946339693382 %, confidence 0.9520616 ... 0.95748097
f0 440.0 Hz: 25 frames, worst relative error 0.08370832963423296 %, confidence 0.96351856 ... 0.96745545
mean confidence: harmonic 196 Hz 0.9404105290037686 over 61 frames, white noise 0.7600755007540594 over 61 frames
```

`spot-501f.txt`:

```
window, N: golden (3 dB width, null to null, side lobe, scalloping) | recomputed | Harris (3 dB, side lobe, scalloping)
rectangular        64: 0.8860 2.0000  -13.254 3.9215 | 0.8860 2.0000  -13.254 3.9215 | 0.89 -13 3.92
rectangular      1024: 0.8859 2.0000  -13.261 3.9224 | 0.8859 2.0000  -13.261 3.9224 | 0.89 -13 3.92
rectangular      4096: 0.8859 2.0000  -13.261 3.9224 | 0.8859 2.0000  -13.261 3.9224 | 0.89 -13 3.92
hann               64: 1.4406 4.0000  -31.467 1.4236 | 1.4406 4.0000  -31.467 1.4236 | 1.44 -32 1.42
hann             1024: 1.4406 4.0000  -31.467 1.4236 | 1.4406 4.0000  -31.467 1.4236 | 1.44 -32 1.42
hann             4096: 1.4406 4.0000  -31.467 1.4236 | 1.4406 4.0000  -31.467 1.4236 | 1.44 -32 1.42
hamming            64: 1.3029 4.0000  -42.449 1.7516 | 1.3029 4.0000  -42.449 1.7516 | 1.30 -43 1.78
hamming          1024: 1.3030 4.0000  -42.674 1.7514 | 1.3030 4.0000  -42.674 1.7514 | 1.30 -43 1.78
hamming          4096: 1.3030 4.0000  -42.675 1.7514 | 1.3030 4.0000  -42.675 1.7514 | 1.30 -43 1.78
blackman           64: 1.6437 6.0000  -58.110 1.0989 | 1.6437 6.0000  -58.110 1.0989 | 1.68 -58 1.10
blackman         1024: 1.6437 6.0000  -58.109 1.0989 | 1.6437 6.0000  -58.109 1.0989 | 1.68 -58 1.10
blackman         4096: 1.6437 6.0000  -58.109 1.0989 | 1.6437 6.0000  -58.109 1.0989 | 1.68 -58 1.10
blackmanHarris     64: 1.8994 8.0000  -92.014 0.8256 | 1.8994 8.0000  -92.014 0.8256 | 1.90 -92 0.83
blackmanHarris   1024: 1.8994 8.0000  -92.010 0.8256 | 1.8994 8.0000  -92.010 0.8256 | 1.90 -92 0.83
blackmanHarris   4096: 1.8994 8.0000  -92.010 0.8256 | 1.8994 8.0000  -92.010 0.8256 | 1.90 -92 0.83
largest difference golden - recomputed: 0.0000 bin, 0.0001 dB (the package is held to 0.05 bin and 0.1 dB of golden)
```

`spot-534-fixtures.out`, then the summary lines the harness self-test printed (that run kept no file; the lines are copied from its output):

```
compile-fixtures: 1 valid fixtures compile, 7 invalid fixtures fail with their sentences
exit 0 seconds 2
```

```
compile-fixtures: FAIL .build/audit/fixtures-neg/valid/InvalidFiledAsValid.swift: it is filed as valid and does not compile
compile-fixtures: FAIL .build/audit/fixtures-neg/invalid/ValidFiledAsInvalid.swift: it is filed as invalid and compiles
compile-fixtures: 2 of 2 fixtures misbehave (1 valid, 1 invalid)
```
