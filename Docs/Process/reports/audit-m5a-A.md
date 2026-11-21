# Audit of Verifier A — milestone M5a

| Field | Value |
|---|---|
| Audited | Verifier A's verification of M5a: the reports `WP-<id>-A.md` of WP-501a…WP-501g, WP-502…WP-512, WP-528, WP-534…WP-538 and WP-540 (25 packages), and its probes and references in `VerifierA/` |
| Auditor | Agent. Not the implementer, not Verifier A, not Verifier B, not the integrator. Nothing that Verifier B wrote was read |
| Checkout | Verifier A's checkout, `/private/tmp/claude-501/-Users-admin-Documents-ZTronDSP/0a25c87a-503c-4e3f-99b7-72b2d1d73489/scratchpad/wt/v-m5a-a/ZTronDSP` (the package root below), as Verifier A left it. The main tree was read and not written |
| Simulator | `ztdsp-27-vm5aa`, on every `Scripts/xc.sh` call |
| Date | 2026-11-18 |
| Result | **The seven blocking findings stand.** A-1 to A-6 and A-15 are confirmed, the auditor reproduced each of them, and each is blocking under §11.6. **One pass verdict does not hold.** Of the five pass verdicts spot-checked, four hold. WP-511's fails: its f₀ clause fails on a harmonic fixture outside the verifier's set (§4, spot check 4) |

## 1. Method

1. **Rules read:**
   - §11.6 and FIX-4;
   - STG-2, the WP-501b row of its table;
   - §6.4.2 (WIN-3 to WIN-6);
   - §6.11 and its acceptance;
   - §9.3, NUM-1 and PERF-1;
   - the M5 rows of §12, from WP-501a to WP-540.
2. **Change requests searched.**
   - First the titles of CR-001 to CR-030 (main tree).
   - Then the text of CR-007, CR-012, CR-019, CR-020, CR-022 and CR-023, for: windows, golden lengths, WIN-3 to WIN-6, single precision, grids, nulls, mel, round trips, `logged`, `FeedSnapshot`, heat maps and §9.3.
   - What they cover:
     - CR-019 (M5a, Proposed): NumPy/SciPy references in place of librosa, Octave not run (WP-540), and WP-511's narrow margin at 110 Hz.
     - CR-012: where `Window` lives.
   - **None of them describes any of the seven deviations.**
3. **Sources pristine.** Every file that the findings name is byte-identical to the main tree (`cmp`):
   - Sources: `Window.swift`, `FramingSupport.swift`, `WindowAnalysis.swift`, `WindowDiagnostics.swift`, `STFT.swift`, `InverseSTFT.swift`, `MelFormula.swift`, `FrameExports.swift`, `FeedSnapshot.swift`, `InversionReport.swift`.
   - Tests: `WindowTests.swift`, `WindowAnalysisTests.swift`, `MelTests.swift`.
   - Golden files and generators: `windows.py`, `windows.json`, `window_analysis.py`, `window_analysis.json`, `Tests/Golden/manifest.json`.
   - Notes: `window-smoothness.md`, `mel-filter-bank.md`.

   Further checks:
   - `python3 -B VerifierA/mutations.py check` prints "every file equals its backup".
   - No file under `Sources`, `Tests`, `Scripts` or `Docs` (reports aside) is newer than 2026-11-17 23:00.
   - Where the checkout differs from the main tree, it is only in files outside this batch, which the main tree changed later: M4 work (`FrameCount.swift`, `CountableValueRegressionTests.swift`, CR-028 to CR-030), some core compiler and engine files, CR-018, CR-020, CR-024, the ledger and `currency-2026-11.md`.
4. **Reproductions, run by the auditor:**
   - **The verifier's probe file.** `VerifierA/probes/VerifierAProbeTests.swift` was copied into the test target; at removal it was still `cmp`-equal to the original.
     - Build at 01:42: `** TEST BUILD SUCCEEDED **`.
     - Run with `test-only ZTronDSPAnalysisTests/VerifierAProbes`, with `TEST_RUNNER_VA_OUT` set to the auditor's folder: 26 tests, 17 issues, exit 65 (01:44).
     - Every issue comes from a `finding…` test, or from `nullToNullWidthsOfTheCosineSumsAtOtherFrames` (A-4).
     - The dumps of the run are byte-identical to the verifier's `VerifierA/out`.
   - **A-15's probe**, run alone with `TEST_RUNNER_VA_CRASH=1` (01:45).
   - **The verifier's references**, re-run with `python3 -B`: `check_windows.py`, `check_window_analysis.py`, `htk_round_trip.py` and `check_matlab.py`.
   - **The auditor's own NumPy computation** of the Blackman null (Appendix D).

## 2. The blocking findings

| Finding | Package | Verdict | Severity (§11.6) | Reproduced by the auditor | Evidence |
|---|---|---|---|---|---|
| A-1 | WP-501b | confirmed | blocking | yes | **Rule.** The STG-2 row of WP-501b asks for `scipy.signal.get_window`: each window, lengths 16, 1 024 and 4 096, periodic and symmetric, within 10⁻⁶. The §12 row's acceptance is "Golden". §11.6 makes a missing acceptance check blocking. **No CR.** CR-012 cites `windows.py` and 1e-12, but not the lengths. **Run.** `windows.json` holds 120 cases, at lengths [2, 5, 16, 63, 64, 1024], periodic and symmetric. `windows.py:14` iterates over `(2, 5, 16, 63, 64, 1024)`, and `WindowTests.swift:60` pins the count at `6 * 2 * (3 + 4 + 3)`. There is no case of 4 096. The values are right at 4 096 (`check_windows.py`: 360 cases, 0 failures), so the defect lies in the evidence |
| A-2 | WP-501c | confirmed | blocking | yes | **Rule.** WIN-3, the row ("a non-finite or all-zero window is a typed error") and NUM-1. **No CR.** **Run.** `Window.custom { _ in 1e300 }.samples(count: 16)` returned `[inf, inf, inf, inf]` without an error. An STFT with that window attached and emitted 16 192 non-finite values of 16 698. `{ _ in 1e-50 }` returned zeros without an error. An STFT attached with it, and the largest value of its frames was 0.0. **Read.** `Window.swift:181` converts to `Float` after `checked` (`:277–284`) has run on the doubles |
| A-3 | WP-501e | confirmed | blocking | yes | **Rule.** The row ("a closure with an interior jump is located within one sample"), WIN-4 (grids of N, 2N and 4N points) and WIN-6. **No CR.** **Run.** At a frame of 16 384 samples, a jump at 0.59985595703125 is reported at 0.5999755859375, 1.96 samples away. At 65 536 samples it is 7.68 samples away. The probe's other three cases pass. **Read.** `finestGrid = 4_096` (`WindowAnalysis.swift:189`). The grids have 1 024, 2 048 and 4 096 points for every frame (`:408–430`). The test bounds the error by `1/min(frame, 4 096)` of the frame, which is 4 samples at 16 384. The note claims one sample up to 16 384 (`window-smoothness.md:19`) |
| A-4 | WP-501f | confirmed | blocking | yes | **Rule.** The row ("within 0.1 dB and 0.05 bin"). **No CR.** **Run.** The Blackman null-to-null width is 6.0793 bins at 1 000 samples. It is 6.0812 at 100, 6.0675 at 999, 6.1061 at 1 001, and 6.0793 at 1 500, 2 000 and 3 000; the probe's case of 333 passes. `check_window_analysis.py`: 50 cases, 1 failure ("blackman\|1000 … 6.0793 against 6.0000"). **The auditor's own NumPy (Appendix D).** The transform has zeros at 3.00000 and 3.05505 bins, with a lobe of −96.2 dB between them. The chord method, re-written, on the transform padded to 16N reproduces the package's figures: 6.0793 at 1 000, 6.0812 at 100, 6.0372 at 333 and 6.0000 at 1 024. One clause of the finding is overstated (§3, gap 4); the wrong result alone makes it blocking |
| A-5 | WP-508, WP-535 | confirmed | blocking | yes | **Rule.** §6.11's acceptance: "conversions round-trip within 10⁻⁹ relative for both formulas". WP-508's row says "within 10⁻⁹"; §6.11 is the precise statement. WP-535's row is "§6.11 acceptance". **No CR.** **Run.** The HTK round trip `hertz(mel(1e-06))` returns 1.00000003833145e-06, 3.83·10⁻⁸ relative. At 10⁻⁵ Hz the error is 7.25·10⁻⁹. `htk_round_trip.py`: 4.45·10⁻⁵ at 10⁻⁹ Hz and 5.26·10⁻¹⁰ at 10⁻⁴ Hz; with `log1p`/`expm1`, at most 1.69·10⁻¹⁶. **Read.** `MelFormula.swift:44, 49`. The test (`MelTests.swift:22–24`) holds HTK to `1e-9·max(f, 1)` absolute below 1 Hz, and steps by 37.3 Hz from 0 |
| A-6 | WP-501g | confirmed | blocking | yes | **Rule.** WIN-5 and the row ("logged once per attachment when asked and never otherwise"). **No CR.** **Run.** The control, a logged window on `STFT`, logs 1 report. With `STFT(…); InverseSTFT(window: .hann.logged())`, attached and run, 0 reports are logged. **Read.** `InverseSTFT.swift` (`lower()`, `:85–122`) never reads `window.isLogged`; only `STFT.swift:108, 116` do. `WindowDiagnostics.swift:5–7` narrows the rule to "framing step" |
| A-15 | WP-540 | confirmed | blocking | yes | **Rule.** §9.3 ("No `fatalError` or `precondition` is reachable from public API through invalid input"). The precedent is `WP-321b-A.md`, finding 2. **No CR.** **Run.** With `TEST_RUNNER_VA_CRASH=1`, the snapshot `FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: 3, values: [1, 2], times: [0])`, which the public initialiser accepts, has a `matlabScript()` that ends the process. The log shows `Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range`, then "Restarting after unexpected exit, crash, or test timeout", and exit 65. **Read.** `FrameExports.swift:48–53` indexes `values[column * rows + row]` with no size check. `MATLABScript.matrix` (`MATLABScript.swift:140–145`) does check the size, but only after that loop. **Also run.** `check_matlab.py` on the auditor's dumps: "export uneven-waveform: refused … plot(times, maxima) draws 2 values against 1". **Not run.** The overflow of `rows * columns` (read only, as the report says) |

Notes on the findings:

- **A-2, the scope.**
  - `SampledWindow` keeps both the double and the single samples.
  - `STFT` applies the single samples when the normalisation is `.none` (the default); `InverseSTFT` always applies them.
  - With another normalisation, the taper is computed from the doubles (`taper(factor:)`).
  - The report's "every framing step applies those single-precision samples" is therefore slightly broad. The finding is not affected.
- **A-3, a change request is needed.**
  - WIN-4 (grids of N, 2N and 4N points) and WIN-6 (a step not below 2⁻¹² of the frame) conflict for frames above 1 024 samples.
  - Under FIX-4 this needs a change request. The report proposes one, but none is filed (§3, gap 2).
  - Until one is, the code departs from WIN-4 without a CR, and the row's acceptance fails at 16 384 samples.
- **A-5, practical effect.**
  - In practice the effect is nil: no mel band edge lies below 1 Hz.
  - A change request that limits the statement is an alternative to `log1p`/`expm1`. As written, the acceptance statement of §6.11 is violated.
  - WP-535 has no code of its own to change.
  - A small wording slip: `htk_round_trip.py` uses Python's `math` (double precision), not NumPy as the report says. The figures are unaffected.
- **A-6, outside this batch.** `ConstantQ` and `ConstantQScale` (M5c, outside this batch) also take `window:` and never read `isLogged`. A fix confined to `InverseSTFT` would leave them.
- **A-15, a related defect.** Point 3 of the report is confirmed: a waveform snapshot whose values do not fill it exports a script that MATLAB refuses.

## 3. Gaps in the verification (Duty 2)

**What holds:**
- All 25 reports exist. Each states its checks, its lens checklist, its findings and its verdict, and every passed check names how it was run.
- Every `ALG` row on lens N records the currency check and a mutation run. The mutation logs (`mutation-M1`, `mutation-M2`) show the failures the reports claim, for example:
  - WP-501d: 5;
  - WP-501e: 9;
  - WP-501f: 13;
  - WP-502: 15;
  - WP-508: 18;
  - WP-509: 18;
  - WP-528: 13;
  - WP-535: 1.
- The run summaries (`debug-run1`, `debug-run2`, `final-run`, `final-run2`, `release-run1`) show 211 of 211 tests passed each time.
- The gates pass in `gates2.out`. The first run, `gates.out`, failed with exit 127 because of zsh quoting, and was re-run.
- No pass verdict lacks its evidence.

**The gaps:**

1. **WP-511: the pass verdict does not stand.**
   - Spot check 4 (§4) finds a harmonic fixture whose f₀ is off by more than the row's 1 %, where the definition evaluated in double precision is within it.
   - The verifier's A-12 names the mechanism: round-off bins under an absolute floor of 10⁻¹⁰. A-12 is rated non-blocking because the six fixtures the verifier tried passed, one of them by 0.026 %.
   - On this evidence the result is wrong against the row's acceptance, which §11.6 makes blocking.
   - The only way out is a CR that defines "a harmonic fixture" narrowly (FIX-4). The specification does not define the phrase.
2. **WP-501e (FIX-4): the change request is not filed.** The WIN-4/WIN-6 conflict behind A-3 is only proposed in the report; no CR exists (CR-001 to CR-030 searched). The integrator has to file it.
3. **WP-540: "they run under Octave" was not exercised.**
   - GNU Octave is not installed. The report discloses this, and CR-019 records it under "Not done" (Proposed, no owner's decision).
   - `check_matlab.py` is a substitute, not the acceptance check. The clause stays open whatever becomes of A-15.
4. **WP-501f: a clause of A-4 is worded too broadly.**
   - The table says "the acceptance check does not exercise the code that computes it". It does run the chord interpolation, for Kaiser (5.83 bins) and Gaussian (8.24–8.26 bins), whose nulls fall between points at the golden frames.
   - What no golden frame reaches is Blackman's near-double zero between points. Point 3 of the report's list says this correctly.
   - The finding stands on the wrong result.

Not gaps, for the record:
- **WP-503: A-14, no benchmark of the framer.** Rated non-blocking. This is consistent with PERF-1, since no budget names the framer and nothing is claimed.
- **The other non-blocking findings** (A-7 to A-11 and A-13) were read. Their severities are consistent with §11.6, as the reports argue them. A-12 is the subject of gap 1.

## 4. Spot checks

Five pass verdicts were chosen where the evidence was thinnest, that is, the package's own test plus a probe at a few values: WP-503, WP-506, WP-509, WP-511 and WP-537.

The auditor wrote its own probe (`AuditorSpotChecks`, Appendix A), at values that neither the package's tests nor the verifier's probes use:
- **Build.** The probe was copied into `Tests/ZTronDSPAnalysisTests/` and built at 02:05: `** TEST BUILD SUCCEEDED **`.
- **Run.** It was run with the package's own suites of these packages: `✔ Test run with 60 tests in 5 suites passed after 46.125 seconds` (Auditor spot checks, Framer, Level, Cepstrum, Inversion reports).
- **Removal.** The probe was then removed.
- **WP-511 recomputed.** The probe dumped the WP-511 signals with the package's values. The definition was then recomputed from them in NumPy (Appendices B and C).

| # | Package | Acceptance of the row | The auditor's check | Result |
|---|---|---|---|---|
| 1 | WP-503 | Frames ≡ offline slicing for irregular batches | 5 frame/hop pairs (64/16, 1 000/333, 4 097/512, 5/5, 2/1), causal and centred. Batches of random size 1…700 (SplitMix64). The reference is the definition, with x[−n] = x[n] when centred | **Holds.** Bit for bit, with every frame position equal. Only 1 000/333 (20 batches) and 4 097/512 (66 batches) are new evidence: the three small signals arrived in one or two batches. "No copy on the mirrored ring" was not re-checked; `FramerTests` passed |
| 2 | WP-506 | Analytic signals; the values do not depend on the block size | **Tones.** 1 102.5 Hz at 44.1 kHz (a period of 40 samples), window 1 600, hop 147, amplitudes 0.7 and 0.05, against RMS 20·log₁₀(a/√2) and peak 20·log₁₀(a). **Noise and chirp.** 30 001 samples, window 800, hop 147, against a reduction in double precision. **Block sizes.** 1, 13, 97, 441, 2 049 and 30 001, against 256 | **Holds.** RMS within 1.1·10⁻⁶ dB and peak within 5.5·10⁻⁷ dB (140 values each). The reduction within 8.6·10⁻⁷ dB (RMS) and 1.2·10⁻⁷ dB (peak), over 199 values. Bit for bit at every block size |
| 3 | WP-509 | An echo appears at its delay | An echo of 0.4 at 97, 333 and 777 samples, on uniform noise (40 000 samples). `STFT(frame: 4_096, hop: 1_024, window: .hann)`, real and power cepstra | **Holds.** The largest quefrency in 40…999 is the delay in each of the 35 frames after the first, for every delay and both kinds. The real cepstrum at the delay is 0.115…0.238 |
| 4 | WP-511 | f₀ of a harmonic fixture within 1 %; mean confidence higher on the harmonic fixture than on white noise | **Pipeline.** `STFT(frame: 4_096, hop: 512)` → `Cepstrum(.real)` → `CepstralPitch(range: .hertz(80 ... 600))` at 48 kHz, the configuration of the package's own pitch test. **Harmonic fixtures.** `TestSignal.harmonic` at 97, 233 and 415.3 Hz: 16 partials of amplitude 1/k, ×0.3, 32 768 samples. **Noise.** Uniform (seeds 11 and 12, amplitude 0.5) and Gaussian (seeds 111 and 112, σ 0.2) | **Confidence clause: holds.** The harmonic means are 0.876, 0.931 and 0.954; the noise means are 0.730…0.742. On noise, the package equals the definition within 3·10⁻⁷. **f₀ clause: fails at 97 Hz.** 18 of 57 frames are off by more than 1 %, the worst by 3.351 %. 15 of them read 93.75 Hz, that is f_s/512 exactly (frames 3, 5, 7, 8, 9, 10, 12, 16, 25, 32, 37, 38, 39, 46, 47). The definition in double precision, on the same samples, is within 0.924 % on every frame. A single-precision transform in NumPy (complex64) puts 2 frames off, the worst by 1.403 %. 1 815 to 1 875 of the 2 049 bins of a frame lie below 10⁻⁷ of its largest bin. At 233 and 415.3 Hz the package stays within 0.839 % and 0.299 % |
| 5 | WP-537 | A report for an exact pair is exact | `DSP.inversionReport(ofUpsampling:by:sampleRate: 44_100)` at factors 1, 4 and 16, on noise plus a 9 kHz sine (3 001 samples) | **Holds.** `isExactlyInvertible`, predicted error 0, measured relative and largest error 0, SNR ∞, count 3 001, and the round trip equal to the input. "It runs on `BackgroundWork`" was not re-checked; `InversionTests` passed |

On spot check 4:
- **Scope of the fixture.** The verifier's own 97 Hz fixture has 20 partials and 16 384 samples, and passed (0.748 %). The auditor's has 16 partials, which leaves more of the spectrum to round-off. 8 of the 18 failing frames lie among the first 25 frames, so the length of the signal is not the cause.
- **The fixture is ordinary.** It lies inside the step's range, and in the configuration of the package's own test.
- **A likely remedy.** The verifier's suggested resolution of A-12, a floor relative to the frame's largest bin at the transform's own floor, addresses this mechanism. It was not tried here.

## 5. Restoration and clean-up

- **Probe copies removed.**
  - `Tests/ZTronDSPAnalysisTests/VerifierAProbeTests.swift`, `cmp`-equal to `VerifierA/probes/VerifierAProbeTests.swift` before removal.
  - `Tests/ZTronDSPAnalysisTests/AuditorSpotChecks.swift`.
- **The test folder is restored.** `Tests/ZTronDSPAnalysisTests` was checked against a sha256 of each of its 188 files, taken before any change: every file is identical. `diff -rq` against the main tree's folder shows no difference.
- **Nothing else changed.** No file outside `.build` changed after that first checksum, except this report (`find -newer`). No `__pycache__` folder exists under `VerifierA/python` or `Tests/Golden/generators`.
- **The working files are removed with `.build`.** The auditor's logs, dumps, probe and scripts live in `.build/audit/`. `.build` is removed after the hand-over copy is made. The figures are quoted above, and the probe and scripts follow as Appendices A to D, exactly as they ran.
- **Hand-over.** The reports folder and `VerifierA/` are copied to the hand-over folder with the rsync the brief names.

## 6. Commands

The commands are run from the package root. Appendix A goes to `Tests/ZTronDSPAnalysisTests/AuditorSpotChecks.swift`, and Appendices B to D to any folder.

```sh
# The findings: the verifier's probes, then its references
cp VerifierA/probes/VerifierAProbeTests.swift Tests/ZTronDSPAnalysisTests/
ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh build
TEST_RUNNER_VA_OUT="$PWD/.build/audit/out" ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh test-only ZTronDSPAnalysisTests/VerifierAProbes
TEST_RUNNER_VA_CRASH=1 ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh test-only "ZTronDSPAnalysisTests/VerifierAProbes/findingAHeatMapSnapshotWhoseValuesDoNotFillItEndsTheProcess()"
rm Tests/ZTronDSPAnalysisTests/VerifierAProbeTests.swift
(cd VerifierA/python && python3 -B check_windows.py; python3 -B check_window_analysis.py; python3 -B htk_round_trip.py; python3 -B check_matlab.py)
python3 -B a4_blackman.py                       # Appendix D
python3 -c "import json; d = json.load(open('Tests/ZTronDSPCoreTests/Golden/windows.json')); print(len(d['cases']), sorted({c['parameters']['count'] for c in d['cases']}))"

# The spot checks
cp AuditorSpotChecks.swift Tests/ZTronDSPAnalysisTests/       # Appendix A
ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh build
TEST_RUNNER_AUD_OUT="$PWD/.build/audit/spot" ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh test-only ZTronDSPAnalysisTests/AuditorSpotChecks ZTronDSPAnalysisTests/FramerTests ZTronDSPAnalysisTests/LevelTests ZTronDSPAnalysisTests/CepstrumTests ZTronDSPAnalysisTests/InversionTests
rm Tests/ZTronDSPAnalysisTests/AuditorSpotChecks.swift
python3 -B wp511_confidence.py .build/audit/spot/confidence.json                                                 # Appendix B
python3 -B wp511_precision.py .build/audit/spot/confidence.json "harmonic|97.0" "harmonic|233.0" "harmonic|415.3"  # Appendix C
```

The outputs of Appendices B and C on the run of 02:08:

```
harmonic|233.0   frames  57  mean confidence package 0.931442 reference 0.936609  largest |dconf| 1.12e-02  largest relative |dpitch| 1.24e-02
harmonic|415.3   frames  57  mean confidence package 0.954246 reference 0.956342  largest |dconf| 4.94e-03  largest relative |dpitch| 3.51e-03
harmonic|97.0    frames  57  mean confidence package 0.876349 reference 0.876687  largest |dconf| 3.68e-02  largest relative |dpitch| 4.09e-02
noise|gaussian11 frames  57  mean confidence package 0.742157 reference 0.742157  largest |dconf| 2.72e-07  largest relative |dpitch| 5.70e-08
noise|gaussian12 frames  57  mean confidence package 0.730099 reference 0.730099  largest |dconf| 9.61e-08  largest relative |dpitch| 4.55e-08
noise|uniform11  frames  57  mean confidence package 0.731456 reference 0.731456  largest |dconf| 2.71e-07  largest relative |dpitch| 4.78e-08
noise|uniform12  frames  57  mean confidence package 0.735144 reference 0.735144  largest |dconf| 9.91e-08  largest relative |dpitch| 4.90e-08
reference: smallest harmonic mean 0.8767, largest noise mean 0.7422

harmonic|97.0: 57 frames; transform dtype complex64; bins below 1e-7 of the frame maximum 1815...1875 of 2049
   frames off by more than 1 %, and the largest error in %: package (18, 3.351), double (0, 0.924), single-precision transform (2, 1.403)
   package frames at 93.75 Hz (quefrency 512): [3, 5, 7, 8, 9, 10, 12, 16, 25, 32, 37, 38, 39, 46, 47]
harmonic|233.0: ... package (0, 0.839), double (0, 0.399), single-precision transform (0, 0.431)
harmonic|415.3: ... package (0, 0.299), double (0, 0.312), single-precision transform (0, 0.326)
```

(The names `gaussian11` and `gaussian12` are those of the dump; their seeds are 111 and 112.)

The output of Appendix D:

```
N=1000: minima of |W| near bin 3: 3.00000 bins (-334.5 dB), 3.05505 bins (-186.2 dB); peak between first two: -96.2 dB; ...; padded length 16384; chord method width 6.0793
N=1024: ... padded length 16384; chord method width 6.0000
N=333:  ... padded length 6144; chord method width 6.0372
N=100:  ... padded length 1920; chord method width 6.0812
```

## Appendix A — `AuditorSpotChecks.swift`, as run

```swift
import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

// Auditor of Verifier A (M5a): spot checks of five `pass` verdicts, at values the package's own
// tests do not use. Not part of the package: copied into Tests/ZTronDSPAnalysisTests/ for one
// run, then removed. What passes is written to $AUD_OUT (set TEST_RUNNER_AUD_OUT).

struct AuditorOut {
    private var parts: [String] = []
    mutating func add(_ key: String, _ values: [Double]) {
        parts.append("\"\(key)\":[" + values.map { $0.isFinite ? "\($0)" : "null" }.joined(separator: ",") + "]")
    }
    mutating func add(_ key: String, _ values: [Float]) { add(key, values.map(Double.init)) }
    func write(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["AUD_OUT"] else { return }
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(("{" + parts.joined(separator: ",") + "}\n").utf8).write(to: folder.appendingPathComponent(name + ".json"))
    }
}

/// SplitMix64, for batch sizes.
struct AuditorMix {
    var state: UInt64
    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}

@Suite("Auditor spot checks")
struct AuditorSpotChecks {
    // MARK: WP-503 — frames of random, irregular batches equal offline slicing

    @Test(arguments: [(64, 16), (1_000, 333), (4_097, 512), (5, 5), (2, 1)])
    func framesOfRandomBatchesEqualOfflineSlicing(frame: Int, hop: Int) throws {
        let signal = TestSignal.whiteNoise(count: 5 * frame + 3 * hop + 17, seed: UInt64(7_000 + frame + hop), amplitude: 0.9)
        for alignment in [FrameAlignment.causal, .centered] {
            // The definition (§6.4.1, §6.1): causal frame k is samples k·hop … k·hop + frame − 1,
            // aligned to its last sample; centred frame k is centred on sample k·hop, the start
            // reflected without repeating the edge sample (x[−n] = x[n]).
            let lead = alignment == .centered ? frame / 2 : 0
            var expected: [[Float]] = [], positions: [Int] = []
            var k = 0
            while k * hop - lead + frame <= signal.count {
                let start = k * hop - lead
                expected.append((start ..< start + frame).map { signal[abs($0)] })
                positions.append(alignment == .centered ? k * hop : start + frame - 1)
                k += 1
            }
            let framer = try Framer(frameSize: frame, hopSize: hop, alignment: alignment)
            var mix = AuditorMix(state: UInt64(frame * 1_000 + hop))
            var frames: [[Float]] = [], got: [Int] = [], batches = 0
            signal.withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < signal.count {
                    let count = Swift.min(1 + mix.below(700), signal.count - offset)
                    batches += 1
                    var taken = 0
                    while taken < count {
                        taken += framer.append(buffer.baseAddress! + offset + taken, count: count - taken)
                        while let view = framer.frame {
                            frames.append(Array(UnsafeBufferPointer(start: view, count: framer.frameSize)))
                            got.append(framer.framePosition)
                            framer.advance()
                        }
                    }
                    offset += count
                }
            }
            #expect(frames.count == expected.count && !expected.isEmpty, "\(alignment) \(frame)/\(hop): \(frames.count) frames, \(expected.count) expected")
            #expect(frames == expected, "\(alignment) \(frame)/\(hop), \(batches) random batches: not bit for bit")
            #expect(got == positions, "\(alignment) \(frame)/\(hop): positions differ")
            var out = AuditorOut()
            out.add("frames", [Double(frames.count)])
            out.add("batches", [Double(batches)])
            out.write("framer-\(frame)-\(hop)-\(alignment == .centered ? "centred" : "causal")")
        }
    }

    // MARK: WP-506 — analytic values; the values do not depend on the block size

    @Test func levelReadsAnalyticValuesAndDoesNotDependOnTheBlockSize() throws {
        let format = SignalFormat(sampleRate: 44_100)
        // 1 102.5 Hz at 44.1 kHz: a period of 40 samples. A window of 1 600 samples holds 40
        // whole periods (mean square a²/2) and a sample at the crest (peak a).
        let window = 1_600.0 / 44_100, hop = 147.0 / 44_100
        var out = AuditorOut()
        for amplitude in [0.7, 0.05] {
            let tone = TestSignal.sine(frequency: 1_102.5, sampleRate: 44_100, count: 22_050, amplitude: amplitude)
            let rms: [ScalarFrame] = try Pipeline { Level(.rms, window: window, hop: hop) }.process(tone, format: format)
            let peak: [ScalarFrame] = try Pipeline { Level(.peak, window: window, hop: hop) }.process(tone, format: format)
            let rmsError = rms.map { abs(Double($0.value) - 20 * log10(amplitude / 2.0.squareRoot())) }.max() ?? .infinity
            let peakError = peak.map { abs(Double($0.value) - 20 * log10(amplitude)) }.max() ?? .infinity
            #expect(rms.count == (22_050 - 1_600) / 147 + 1 && peak.count == rms.count, "\(rms.count) values")
            #expect(rmsError <= 1e-3 && peakError <= 1e-3, "amplitude \(amplitude): RMS off by \(rmsError) dB, peak by \(peakError) dB")
            out.add("tone|\(amplitude)|rmsError", [rmsError])
            out.add("tone|\(amplitude)|peakError", [peakError])
            out.add("tone|\(amplitude)|count", [Double(rms.count)])
        }
        // Noise and a chirp: every value against a reduction written here, and the same values at
        // every block size.
        let signal = TestSignal.sum(TestSignal.whiteNoise(count: 30_001, seed: 9_506, amplitude: 0.4),
                                    TestSignal.chirp(from: 60, to: 9_000, sampleRate: 44_100, count: 30_001, amplitude: 0.4))
        let w = 800, h = 147
        for kind in [LevelKind.rms, .peak] {
            let pipeline = Pipeline { Level(kind, window: Double(w) / 44_100, hop: Double(h) / 44_100) }
            let reference: [ScalarFrame] = try pipeline.process(signal, format: format, blockSize: 256)
            #expect(reference.count == (30_001 - w) / h + 1, "\(reference.count) values")
            var worst = 0.0
            for (index, frame) in reference.enumerated() where index * h + w <= signal.count {
                let part = signal[index * h ..< index * h + w].map { Double($0) }
                let expected = kind == .rms
                    ? 10 * log10(Swift.max(part.map { $0 * $0 }.reduce(0, +) / Double(w), 1e-16))
                    : 20 * log10(Swift.max(part.map { abs($0) }.max() ?? 0, 1e-8))
                worst = Swift.max(worst, abs(Double(frame.value) - expected))
            }
            #expect(worst <= 1e-4, "\(kind): \(worst) dB from the reduction")
            var sizes: [Double] = []
            for blockSize in [1, 13, 97, 441, 2_049, 30_001] {
                let values: [ScalarFrame] = try pipeline.process(signal, format: format, blockSize: blockSize)
                #expect(values == reference, "\(kind), blocks of \(blockSize): \(values.count) values, not bit for bit")
                if values == reference { sizes.append(Double(blockSize)) }
            }
            out.add("\(kind == .rms ? "rms" : "peak")|worst", [worst])
            out.add("\(kind == .rms ? "rms" : "peak")|count", [Double(reference.count)])
            out.add("\(kind == .rms ? "rms" : "peak")|equalAtBlockSizes", sizes)
        }
        out.write("level")
    }

    // MARK: WP-509 — an echo appears at its delay

    @Test(arguments: [97, 333, 777])
    func anEchoAppearsAtItsDelay(delay: Int) throws {
        let noise = TestSignal.whiteNoise(count: 40_000, seed: UInt64(509 + delay), amplitude: 0.3)
        var echoed = noise
        for index in delay ..< noise.count { echoed[index] += 0.4 * noise[index - delay] }
        var out = AuditorOut()
        for kind in [CepstrumKind.real, .power] {
            let frames: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 1_024, window: .hann); Cepstrum(kind) }.process(echoed, format: mono48)
            var peaks: [Double] = [], atDelay: [Double] = []
            for values in frames.dropFirst() {
                let peak = (40 ..< 1_000).max { values[$0] < values[$1] } ?? -1
                peaks.append(Double(peak))
                atDelay.append(Double(values[delay]))
            }
            #expect(frames.count > 8 && peaks.allSatisfy { Int($0) == delay }, "\(kind), delay \(delay): largest quefrencies \(peaks)")
            let name = kind == .real ? "real" : "power"
            out.add("\(name)|peaks", peaks)
            out.add("\(name)|atDelay", atDelay)
            out.add("\(name)|frames", [Double(frames.count)])
        }
        out.write("echo-\(delay)")
    }

    // MARK: WP-511 — the mean confidence is higher on harmonic fixtures than on noise

    @Test func theMeanConfidenceIsHigherOnHarmonicFixturesThanOnNoise() throws {
        let pipeline = Pipeline { STFT(frame: 4_096, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(80 ... 600)) }
        var out = AuditorOut()
        var harmonicMeans: [Double] = [], noiseMeans: [Double] = []
        for fundamental in [97.0, 233.0, 415.3] {
            let fixture = TestSignal.harmonic(fundamental: fundamental, amplitudes: (1 ... 16).map { 1 / Double($0) }, sampleRate: 48_000, count: 32_768).map { $0 * 0.3 }
            let frames: [ScalarFrame] = try pipeline.process(fixture, format: mono48)
            harmonicMeans.append(frames.reduce(0) { $0 + Double($1.confidence) } / Double(frames.count))
            out.add("harmonic|\(fundamental)|signal", fixture)
            out.add("harmonic|\(fundamental)|value", frames.map { $0.value })
            out.add("harmonic|\(fundamental)|confidence", frames.map { $0.confidence })
        }
        for seed in [11, 12] as [UInt64] {
            let noises: [(String, [Float])] = [("uniform", TestSignal.whiteNoise(count: 32_768, seed: seed, amplitude: 0.5)),
                                               ("gaussian", TestSignal.gaussianNoise(count: 32_768, seed: seed + 100, standardDeviation: 0.2))]
            for (name, noise) in noises {
                let frames: [ScalarFrame] = try pipeline.process(noise, format: mono48)
                noiseMeans.append(frames.reduce(0) { $0 + Double($1.confidence) } / Double(frames.count))
                out.add("noise|\(name)\(seed)|signal", noise)
                out.add("noise|\(name)\(seed)|value", frames.map { $0.value })
                out.add("noise|\(name)\(seed)|confidence", frames.map { $0.confidence })
            }
        }
        out.add("harmonicMeans", harmonicMeans)
        out.add("noiseMeans", noiseMeans)
        out.write("confidence")
        #expect((harmonicMeans.min() ?? 0) > (noiseMeans.max() ?? 1), "harmonic means \(harmonicMeans), noise means \(noiseMeans)")
    }

    // MARK: WP-537 — the report of an exact pair is exact

    @Test(arguments: [1, 4, 16])
    func theReportOfUpsamplingIsExact(factor: Int) async throws {
        let signal = TestSignal.sum(TestSignal.whiteNoise(count: 3_001, seed: UInt64(537 + factor), amplitude: 0.8),
                                    TestSignal.sine(frequency: 9_000, sampleRate: 44_100, count: 3_001, amplitude: 0.1))
        let report = try await DSP.inversionReport(ofUpsampling: signal, by: factor, sampleRate: 44_100)
        #expect(report.isExactlyInvertible, "factor \(factor)")
        #expect(report.predictedError == 0, "factor \(factor): predicted \(report.predictedError)")
        let measured = try #require(report.measuredError)
        #expect(measured.relativeError == 0 && measured.largestError == 0 && measured.signalToNoiseRatio == .infinity && measured.count == 3_001,
                "factor \(factor): measured \(measured)")
        #expect(report.roundTrip?.original == signal && report.roundTrip?.reconstruction == signal, "factor \(factor): the round trip is not the input")
        var out = AuditorOut()
        out.add("predicted", [report.predictedError])
        out.add("measured", [measured.relativeError, measured.largestError, Double(measured.count)])
        out.add("exact", [Double(report.isExactlyInvertible ? 1 : 0)])
        out.write("upsampling-\(factor)")
    }
}
```

## Appendix B — `wp511_confidence.py`

```python
"""Auditor: WP-511 confidence recomputed from its definition, in double precision.

Reads spot/confidence.json (the auditor probe's dump: each signal, and the value and the
confidence the package gave per frame). Pipeline: STFT(frame 4096, hop 512, periodic Hann,
no normalisation, causal) -> Cepstrum(.real, floor 1e-10) -> CepstralPitch(80...600 Hz) at 48 kHz.
The confidence is 1 - mean|c| / max c over quefrencies ceil(fs/600) ... floor(fs/80); the pitch
is fs / (peak + parabolic shift). Both are scale invariant, so the scale of the inverse
transform does not matter.
"""
import json
import math
import sys

import numpy as np

path = sys.argv[1]
data = json.load(open(path))
fs, N, H = 48_000.0, 4096, 512
first, last = math.ceil(fs / 600), math.floor(fs / 80)
w = 0.5 * (1 - np.cos(2 * np.pi * np.arange(N) / N))


def reference(signal):
    values, confidences = [], []
    k = 0
    while k * H + N <= len(signal):
        frame = signal[k * H:k * H + N] * w
        X = np.fft.rfft(frame)
        L = 0.5 * np.log(np.maximum(np.abs(X) ** 2, 1e-20))
        c = np.fft.irfft(L, n=N)
        r = c[first:last + 1]
        i = int(np.argmax(r))
        peak = r[i]
        if not peak > 0:
            values.append(values[-1] if values else 0.0)
            confidences.append(0.0)
        else:
            q = first + i
            b, a, f = c[q - 1], c[q], c[q + 1]
            curvature = b - 2 * a + f
            shift = 0.0
            if curvature < 0:
                shift = min(max(0.5 * (b - f) / curvature, -0.5), 0.5)
            values.append(fs / (q + shift))
            confidences.append(min(max(1 - np.mean(np.abs(r)) / peak, 0.0), 1.0))
        k += 1
    return np.array(values), np.array(confidences)


names = sorted({key.rsplit("|", 1)[0] for key in data if key.endswith("|signal")})
worst_c = worst_v = 0.0
means = {}
for name in names:
    signal = np.array(data[name + "|signal"], dtype=np.float64)
    got_v = np.array(data[name + "|value"])
    got_c = np.array(data[name + "|confidence"])
    ref_v, ref_c = reference(signal)
    assert len(ref_c) == len(got_c), f"{name}: {len(got_c)} frames, {len(ref_c)} expected"
    dc = float(np.max(np.abs(ref_c - got_c)))
    dv = float(np.max(np.abs(ref_v - got_v) / np.maximum(ref_v, 1)))
    worst_c, worst_v = max(worst_c, dc), max(worst_v, dv)
    means[name] = (float(np.mean(got_c)), float(np.mean(ref_c)))
    print(f"{name:28s} frames {len(got_c):3d}  mean confidence package {means[name][0]:.6f} reference {means[name][1]:.6f}"
          f"  largest |dconf| {dc:.2e}  largest relative |dpitch| {dv:.2e}")
harmonic = [m[1] for n, m in means.items() if n.startswith("harmonic")]
noise = [m[1] for n, m in means.items() if n.startswith("noise")]
print(f"reference: smallest harmonic mean {min(harmonic):.4f}, largest noise mean {max(noise):.4f}")
print(f"largest |dconf| {worst_c:.2e}; largest relative |dpitch| {worst_v:.2e}")
print("PASS" if min(harmonic) > max(noise) else "FAIL")
```

## Appendix C — `wp511_precision.py`

```python
"""Auditor: the f0 of WP-511 on the 97 Hz fixture of the auditor probe, three ways.

The package (dumped), the definition in double precision, and the definition from a
single-precision transform (NumPy 2 computes an FFT of float32 input in single precision).
"""
import json, math, sys
import numpy as np
data = json.load(open(sys.argv[1]))
fs, N, H = 48000.0, 4096, 512
first, last = math.ceil(fs / 600), math.floor(fs / 80)
w64 = 0.5 * (1 - np.cos(2 * np.pi * np.arange(N) / N))
def pitch(c):
    r = c[first:last + 1]; i = int(np.argmax(r)); q = first + i
    b, a, f = c[q - 1], c[q], c[q + 1]; cur = b - 2 * a + f
    s = min(max(0.5 * (b - f) / cur, -.5), .5) if cur < 0 else 0.0
    return fs / (q + s), q
for name in sys.argv[2:]:
    f0 = float(name.split("|")[1])
    sig = np.array(data[name + "|signal"], dtype=np.float32)
    pv = np.array(data[name + "|value"])
    below, p32, p64 = [], [], []
    for k in range((len(sig) - N) // H + 1):
        fr = sig[k * H:k * H + N]
        X32 = np.fft.rfft(fr * w64.astype(np.float32))
        X64 = np.fft.rfft(fr.astype(np.float64) * w64)
        m = np.abs(X64); below.append(int(np.sum(m < 1e-7 * m.max())))
        for X, out in ((X32, p32), (X64, p64)):
            L = 0.5 * np.log(np.maximum(np.abs(X.astype(np.complex128)) ** 2, 1e-20))
            out.append(pitch(np.fft.irfft(L, n=N))[0])
    p32, p64 = np.array(p32), np.array(p64)
    off = lambda p: (int(np.sum(np.abs(p - f0) > 0.01 * f0)), round(float(np.max(np.abs(p - f0)) / f0 * 100), 3))
    print(f"{name}: {len(pv)} frames; transform dtype {X32.dtype}; bins below 1e-7 of the frame maximum {min(below)}...{max(below)} of {N // 2 + 1}")
    print(f"   frames off by more than 1 %, and the largest error in %: package {off(pv)}, double {off(p64)}, single-precision transform {off(p32)}")
    print(f"   package frames at 93.75 Hz (quefrency 512): {[k for k, v in enumerate(pv) if abs(v - 93.75) < 0.01]}")
```

## Appendix D — `a4_blackman.py`

```python
# Auditor (A-4): the first null of the periodic Blackman window, independently of the package.
import numpy as np

def blackman(N):  # vDSP_blkman_window, periodic: denominator N
    n = np.arange(N)
    return 0.42 - 0.5 * np.cos(2 * np.pi * n / N) + 0.08 * np.cos(4 * np.pi * n / N)

def dtft(w, bins):  # W at frequencies given in bins of the frame (omega = 2*pi*b/N)
    N = len(w); n = np.arange(N)
    return np.array([np.sum(w * np.exp(-2j * np.pi * b * n / N)) for b in bins])

def next_fast(n):  # powers of two, or f*2^k with f in {3,5,15}, k >= 4 (spec 6.4.1)
    best = None
    for f in (1, 3, 5, 15):
        k = 0 if f == 1 else 4
        while f * 2 ** k < n: k += 1
        v = f * 2 ** k
        best = v if best is None or v < best else best
    return best

def package_method(w):  # the chord method of WindowAnalysis.swift:600-622, re-written
    N = len(w); L = next_fast(16 * N)
    X = np.fft.rfft(np.concatenate([w, np.zeros(L - N)]))
    p = np.abs(X) ** 2 / np.abs(X[0]) ** 2
    p = np.maximum(p, 1e-40)
    i = 1
    while not (p[i] < p[i - 1] and p[i] <= p[i + 1]): i += 1
    best = (float(i), np.inf)
    for s in (i - 1, i):
        d = X[s + 1] - X[s]; ln = abs(d) ** 2
        fr = min(max(-(X[s].real * d.real + X[s].imag * d.imag) / ln, 0), 1) if ln > 0 else 0
        r = abs(X[s] + fr * d) ** 2
        if r < best[1]: best = (s + fr, r)
    return L, 2 * best[0] * N / L

for N in (1000, 1024, 333, 100):
    w = blackman(N)
    b = np.linspace(2.9, 3.15, 25001)
    W = np.abs(dtft(w, b)) / np.sum(w)
    # local minima of |W| in the scan
    mins = [i for i in range(1, len(b) - 1) if W[i] < W[i - 1] and W[i] <= W[i + 1]]
    desc = ", ".join(f"{b[i]:.5f} bins ({20*np.log10(max(W[i],1e-300)):.1f} dB)" for i in mins)
    between = W[(b > b[mins[0]]) & (b < b[mins[1]])].max() if len(mins) > 1 else float('nan')
    L, width = package_method(w)
    print(f"N={N}: minima of |W| near bin 3: {desc}; peak between first two: {20*np.log10(between):.1f} dB;"
          f" |W(3 bins)|/W(0) = {abs(dtft(w,[3.0])[0])/np.sum(w):.2e}; padded length {L}; chord method width {width:.4f}")
```
