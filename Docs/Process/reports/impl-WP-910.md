# WP-910 — implementer's report

| Field | Value |
|---|---|
| Package | WP-910: export completeness: every type of §6.14 exports; all golden scripts run under Octave (dependencies 440, 501g, 540, 614; lenses T, N) |
| Implementer | Implementer M9-export (agent), brief 65 with the common rules of brief 60 |
| Date | 2026-11-22, 01:09 to 03:12; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `8f3b9c6` ("Checkpoint: m9-registers — check passed (round 0)"), clean when this work began. Everything below is unstaged or untracked. This work committed nothing and added nothing to the index |
| GNU Octave | **11.3.0**, `/opt/homebrew/bin/octave` (graphics toolkit qt). The "Update of 2026-11-21 17:30" of brief 65 applies: the Octave run is made, and the acceptance "all golden scripts run under Octave" is met on this machine: 11 of 11 |
| Ledger | WP-910 `Verifying`, implementer `Implementer M9-export (agent)`. The backlog entry "Octave run not made" is not written (the update of 17:30) |
| Change request | None written. Decisions asked of the owner are in section 5 |

In one paragraph: a test enforces the table of §6.14 row by row (`Tests/ZTronDSPTests/ExportCompletenessTests.swift`: 9 tests, 51 cases); every row has its conformer and every plot the row lists, and one omission of MAT-2 was found and fixed (the axes of the pole–zero map of an analog system had no unit). A static checker (`Scripts/lib/matlab_check.py`, with its self-test in `run-all.sh`) holds every golden MATLAB script to MAT-2 from `Scripts/golden.sh --check`, and `Scripts/golden.sh --octave` runs every golden script under GNU Octave for real, comparing the figure Octave draws with the one the script says it draws. Two golden scripts that lived inline in Swift tests became generated golden files (STG-2): the writer's own (WP-120), which did not run under Octave and was replaced by a valid one, and the calibration report's (WP-614), byte for byte the same. Gate 7 of `Scripts/ci.sh` runs the Octave part, and the workflow installs Octave for it.

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/Process/reports/impl-WP-910.md` | This report |
| `Tests/ZTronDSPTests/ExportCompletenessTests.swift` | The completeness table (item 1): one case per row of §6.14, MAT-1…MAT-6 |
| `Scripts/lib/matlab_check.py` | The static check of a MATLAB script (item 2) and the figure it expects, which the Octave run compares with Octave's |
| `Scripts/tests/test-matlab-check.sh` | Its self-test, 94 checks, a suite of `Scripts/tests/run-all.sh` |
| `Tests/Fixtures/MATLAB/README.md`, `Tests/Fixtures/MATLAB/valid/every-statement.m`, `Tests/Fixtures/MATLAB/invalid/*.m` (35 files) | The fixtures of both self-tests: one valid script with every kind of statement; 35 scripts with one problem each, whose first line `% expect: …` says what the check reports and, for the 9 that stop or warn Octave too, a line `% octave: …` says what Octave prints. The 35: `axis-decreasing`, `axis-word`, `block-comment`, `bracket-mismatched`, `bracket-not-closed`, `complex-plotted`, `continued`, `data-after-plots`, `double-quoted`, `empty-statement`, `hides-a-command`, `hold-word`, `imagesc-two`, `index-out-of-bounds`, `indexed-assignment`, `label-number`, `lengths-differ`, `line-style`, `log-axis-at-zero`, `log-axis-under-hold`, `matrix-division`, `matrix-power`, `no-labels`, `no-line-feed`, `no-semicolon`, `no-ylabel`, `not-a-command`, `not-a-function`, `quote-not-closed`, `rows-differ`, `side-by-side`, `subplot-outside`, `text-arithmetic`, `two-statements`, `used-before-defined` |
| `Tests/Golden/generators/matlab_writer.py` | Generator of the writer's golden script (WP-120) |
| `Tests/Golden/generators/calibration_matlab.py` | Generator of the calibration report's golden script (WP-614) |
| `Tests/ZTronDSPCoreTests/Golden/script_writer.m` | Generated: the writer's golden script, every kind of variable and every command, valid |
| `Tests/ZTronDSPMetalTests/Golden/calibration_report.m` | Generated: byte for byte the golden text that `CalibrationTests.swift` held inline |

### Changed

| File | What changed |
|---|---|
| `Sources/ZTronDSPDesign/Systems/SystemAnalysis+MATLAB.swift` | The pole–zero map of an analog system labels its axes `Real part (rad/s)` and `Imaginary part (rad/s)` (the z-plane keeps `Real part`, `Imaginary part`: it has no unit); the documentation comment of `matlabScript()` says so |
| `Tests/ZTronDSPDesignTests/SystemAnalysisTests.swift` | Regression test `theAxesOfThePoleZeroMapCarryTheUnitOfThePlane` |
| `Tests/ZTronDSPCoreTests/MATLABScriptTests.swift` | `emittedTextEqualsTheGoldenScript` compares with `Golden/script_writer.m` from the test bundle instead of an inline string; `build()` makes the valid script (below) |
| `Tests/ZTronDSPMetalTests/CalibrationTests.swift` | The golden comparison reads `Golden/calibration_report.m` from the test bundle instead of an inline string |
| `Scripts/lib/golden_runner.py` | `--check`: a `*.m` in a Golden folder must be listed in the manifest (a generator writes it) and pass the static check; new mode `--octave` |
| `Scripts/golden.sh` | Header: `--octave`, the static check of `--check`, exit status 3 for `--octave` without Octave |
| `Scripts/ci.sh` | Gate 7 runs `Scripts/golden.sh --octave` after the manifest check: 0 passed, 3 skipped loudly, anything else failed |
| `.github/workflows/ci.yml` | The job of gate 7 installs Octave (`brew install octave`) before the step that runs the gate; its timeout 30 → 60 minutes |
| `Scripts/tests/run-all.sh` | The suite `matlab-check` |
| `Scripts/tests/test-golden.sh` | The static check of `--check` and the Octave run: stand-ins, an empty PATH, and the real Octave |
| `Scripts/tests/test-ci.sh` | The golden stand-in answers `--octave` on its own; gate 7's Octave part passed, failed, skipped, and strict |
| `Scripts/tests/test-workflow.sh` | Octave is installed before gate 7 runs |
| `Tests/Golden/generators/_matlab.py` | Helpers the new generators share: optional and complex vectors, matrices by rows, `axis` words, and `lint()` (the static check, loaded by path) |
| `Tests/Golden/generators/matlab_scripts.py`, `Tests/Golden/generators/system_analysis_matlab.py` | Docstrings made current (the scripts are run under Octave, by gate 7). The optional Octave step of `system_analysis_matlab.py`, written on a machine without Octave, now runs Octave headless as the runner does (`octave` before `octave-cli`, `QT_QPA_PLATFORM=offscreen`, `--norc --no-history` instead of `--no-init-file`). Both run again with `--only`: their outputs are byte for byte as before |
| `Tests/Golden/manifest.json` | The two new generators and their outputs, and the new source hashes of the two changed ones, each by `Scripts/golden.sh --only <name>`: 197 files of 27 generators → 199 files of 29 |
| `Docs/Process/ledger.md` | Row WP-910 |

### Deleted

None in the tree. Temporary products deleted: a temporary test `Tests/ZTronDSPTests/ExportVariantsDump.swift` (it wrote the 47 variant scripts of item 3, never tracked), the folder `.build/m9-export/variants` and the coverage result bundle `.build/m9-export/cov/Debug.xcresult`.

## 2. The items of the brief

### Item 1 — a completeness table that a test enforces

**What the code does now.** `Tests/ZTronDSPTests/ExportCompletenessTests.swift`, suite "Export completeness: every type of §6.14 exports as MAT-1…MAT-6 say (WP-910)", in the facade's test target. `ExportRow` holds the seven rows of the table in its order. Each row makes its value with the package, the way an app makes it, seeded:

| Row | The value | Its panels, and the plots asserted one by one |
|---|---|---|
| `SystemAnalysis` | `IIRSystem { LowPass(.butterworth, cutoff: .hertz(8_000), order: 2) }.analysis(sampleRate: 48_000)`; its zeros at z = −1 make the group delay undefined at Nyquist, so the script holds a `NaN` | `subplot(3, 2, 1…6)`: the pole–zero map (`plot(real(z), imag(z), 'o')`, `plot(real(p), imag(p), 'x')`) with the unit circle (`plot(cos(linspace(0, 2 * pi, 361)), sin(…), 'k:')`); the magnitude, the phase, the group delay (`semilogx(f, …)`); the impulse and the step responses (`stem(n, impulse)`, `stem(n, step)`) |
| `WindowAnalysis` | `Window.hann.analysis(frame: 64, hop: 16)` | the window (`plot(0:frame-1, samples)`); its spectrum, clamped at the decibel floor, with the two main-lobe markers and the side-lobe marker, `axis([0 32 -160 5])` |
| `InversionReport` | `DSP.inversionReport(ofSubsampling:by: 2, sampleRate: 48_000)` of 4 096 samples of 1 kHz + 15 kHz, so there is an error to draw | original and reconstruction; the error; the error's spectrum (`fft`); the conditions and their margins in the comments, read back |
| `FeedSnapshot` of a `HeatmapFeed` | the feed of `MelSpectrogram(frame: 1_024, hop: 512, bands: 12, to:)` over seeded white noise | `imagesc(times, 1:numel(row_values), values)`, `axis xy`, `colorbar`; the mel band centres in `row_values`, named in the y label |
| `FeedSnapshot` of a `WaveformFeed` | the feed of `Waveform(resolution: 0.005); Emit(to:)` over seeded white noise | the maximum and the minimum over time |
| A track of `ScalarFrame`s | `ScalarTrack` of the frames of `STFT(frame: 2_048, hop: 512); Cepstrum(); CepstralPitch(range: .hertz(100 ... 500))` over a 220 Hz harmonic signal, rate 93.75 | the value over time; the confidence over time |
| `CrossoverTable` with its measurements | `CalibrationReport` (the type that holds the table and the measurements, WP-614) of two entries: two curves with a crossover, and one curve whose times are `1_500_000.0 / 3` and `0.1 + 0.2` (the second reads back only with all 17 digits) | `loglog` of each curve, one panel per entry, `subplot(1, 2, k)` |

The tests (seven of them parameterised over the seven rows):

- `theTableHasTheRowsOfTheSpecification`: the seven rows of §6.14, by name and in order.
- `theReadingSeesWhatBreaksTheRules`: the test's own reader of a script (`ScriptReading`) is shown to find each of 13 broken scripts (a command MAT-2 does not have, a function outside the allowed ones, a variable used before it is defined, data after the plots, a variable that hides `pi`, a missing semicolon, an unclosed and a mismatched bracket, an unclosed quote, two statements on a line, a wrong command word, no final line feed, a carriage return), to pass a valid one, and to find the wrong numbers of MAT-3 (a `Float` written with 17 digits, a `Double` with 9, `NaN` for a defined value, a number for an undefined one, a zero of the wrong sign, a matrix of the wrong shape), so a pass of the tests below means something.
- `theTypeOfTheRowExports` (MAT-1): the value is held as `any Sendable` and asked at run time whether it is `any MATLABExportable`, so a conformance taken away fails the test, not the build.
- `theScriptDrawsEveryPlotTheRowLists`: the script is cut into panels at its `subplot` statements; for each panel, one `#expect` per listed plot on the exact plot statement (command and variable names), then the panel draws nothing else, its `xlabel` and `ylabel` are the expected ones with their unit in parentheses where the quantity has one, and its statements are exactly the expected ones.
- `theScriptIsCoreMATLABWithItsDataFirst` (MAT-2): a tokenizer over the whole script: every identifier followed by `(` or used as a command is one of the 13 commands of MAT-2, one of the functions the exporters use inside expressions (`real`, `imag`, `abs`, `cos`, `sin`, `log10`, `fft`, `linspace`, `numel`; constants `pi`, `NaN`, `Inf`; section 5), or a variable the script defined before; no assignment after the first plot; command words only from their known sets; every statement ends with `;`; comments start `% `; lines end with a line feed, and there is no carriage return.
- `theNumbersReadBackExactly` (MAT-3): the variables, by name and in order, each with its data: every numeric literal of the script is parsed and compared bit for bit with the value the package holds (`Double` with at most 17 significant digits, `Float` with at most 9, complex values as `a+bi`/`a-bi`); the comments exactly, with the numbers in them read back (the margins of the inversion conditions); `NaN` occurs exactly as many times as there are undefined values.
- `equalInputGivesEqualTextWithoutADateOrAMachineName` (MAT-4): two calls on one value, and a value made again, give equal text; no word of the comments, labels and titles is this year, the year before or after, a month or a weekday, and the text does not contain the host name.
- `aVariableOfMoreThanFourMillionElementsIsRefusedWithItsSize` (MAT-4): for six rows a value of the row's type whose export holds more than 4 000 000 elements (a Hann analysis of a 500 000-sample frame; a round trip, a waveform and a track of 4 000 001; a 2 001 × 2 000 heat map; a calibration entry of 4 000 001 sizes) is refused with exactly `DSPError.exportTooLarge(elements: n, limit: 4_000_000)`, whose text names n. A `SystemAnalysis` cannot hold such a variable: it exports 512 frequencies and 256 samples (asserted against the limit), and a system whose roots would exceed degree 512 is refused when it is analysed (asserted: an FIR of length 601 throws `unsupportedConfiguration`).
- `theExportRunsOnTheBackgroundExecutor` (MAT-6), `.serialized` and `@MainActor`: called on the main thread, the export hands its text back there; while `BackgroundWork`'s queue is suspended (`BackgroundWork.queue.suspend()`, through `@testable import ZTronDSPCore`) an export started then has not returned when the queue is let go, and once it is let go it returns the same text; an export from a task cancelled before the call throws `DSPError.cancelled` (BG-3), as `SnapshotImageTests` asserts it. The pause while the queue is held decides nothing for an export whose work runs on the queue (section 5).

MAT-5 is held by review, as the brief says: no exporting type has a member that takes a path, a URL or a file handle, and `matlabScript()` returns text. `grep -rn -E "FileManager|FileHandle|URL|write\(to|fopen|contentsOf|atomically"` over `Sources/ZTronDSPCore/Export`, `SystemAnalysis+MATLAB.swift`, `WindowAnalysisExport.swift`, `Sources/ZTronDSPAnalysis/Export` and `Sources/ZTronDSPMetal/Calibration` finds nothing (exit 1).

**Omissions found.** Every row of §6.14 has its conformer (`SystemAnalysis`, `WindowAnalysis`, `InversionReport`, `FeedSnapshot` for both feeds, `ScalarTrack`, `CalibrationReport`), and every script draws every plot its row lists. One omission of MAT-2 ("with axis labels and units"): the pole–zero map of an **analog** system labelled its axes `Real part` and `Imaginary part`, but the s-plane is in radians per second. Fixed in `SystemAnalysis+MATLAB.swift`; the regression test `theAxesOfThePoleZeroMapCarryTheUnitOfThePlane` (suite "System analysis: MATLAB export (WP-440)") asserts both planes. Without the fix it printed `✘ Test theAxesOfThePoleZeroMapCarryTheUnitOfThePlane() recorded an issue at SystemAnalysisTests.swift:614:9: Expectation failed: analog.contains("hold off;\naxis equal;\ngrid on;\nxlabel('Real part (rad/s)');\nylabel('Imaginary part (rad/s)');\ntitle('Poles (x) and zeros (o)');\n")` and `✘ Test run with 1 test in 1 suite failed after 0.044 seconds with 1 issue.`; with it, it passes. The golden `system_analysis.m` (a digital system) is unchanged. No conformer was missing, so `Scripts/api-digest.sh --update` was not run: no public symbol was added, changed or removed (`api-digest: 10 digests equal the built modules`). The one public symbol touched, `SystemAnalysis.matlabScript()`, keeps its threading contract in its comment ("may be made from any context; the work runs on `BackgroundWork` … It allocates, in the background").

**What failed without it (the undo-checks of "Done means": one conformance and one listed plot taken away, in one build, the failures attributable by row).** The conformance of `ScalarTrack` to `MATLABExportable` removed (`Sources/ZTronDSPAnalysis/Export/FrameExports.swift`), and the step response (`.stem("n", "step")`) removed from the system analysis script (`SystemAnalysis+MATLAB.swift`). With the final test file (03:05–03:08, `.build/logs/m9-export/undo-checks-2.log`):

```
✘ Test run with 9 tests in 1 suite failed after 6.721 seconds with 10 issues.
```

- 7 × `ScalarTrack conforms to MATLABExportable (MAT-1)`, once in each parameterised test, on the track's row (`theTypeOfTheRowExports`, `theScriptDrawsEveryPlotTheRowLists`, `theScriptIsCoreMATLABWithItsDataFirst`, `theNumbersReadBackExactly`, `equalInputGivesEqualTextWithoutADateOrAMachineName`, `aVariableOfMoreThanFourMillionElementsIsRefusedWithItsSize`, `theExportRunsOnTheBackgroundExecutor`);
- 3 on the `SystemAnalysis` row: `the SystemAnalysis script draws the step response: stem(n, step);`, `panel 6 of the SystemAnalysis script draws what the row lists and nothing else: []`, and `panel 6 of the SystemAnalysis script holds these statements and no others` (it held `grid on;`, `xlabel('Sample');`, `ylabel('Amplitude');`, `title('Step response');`).

Both restored at 03:09; `git diff --stat -- Sources` is again the label fix alone, and the suite passes again (`✔ Test run with 9 tests in 1 suite passed after 3.529 seconds.`, 03:10, `.build/logs/m9-export/completeness-5.log`). The same check, made once before with an earlier form of the test (02:29–02:32), gave `✘ Test run with 9 tests in 1 suite failed after 168.832 seconds with 11 issues.` (8 for the track: the MAT-1 test then asked twice). That earlier run showed that a failing `#require` on a conversion describes the value it converts: the 4 000 001-frame track wrote a 517 MB log, which was deleted. The test now requires a Boolean and then converts, so a failure never prints the value; hence 6.7 s instead of 169 s.

**Passing.** Alone, in Debug: `✔ Test run with 9 tests in 1 suite passed after 3.747 seconds.`; and in the full runs of section 3, Debug and Release.

### Item 2 — every golden script checked statically

**What the code does now.** `Scripts/lib/matlab_check.py FILE…` reads the language that `MATLABScript` writes (one statement per line: a comment, an assignment or a command), evaluates the values the script gives without NumPy (a length such as that of `0:frame-1` depends on them), and reports `FILE:LINE: problem`: quotes and brackets balanced; every statement on its own line, ended by `;`; every variable defined before use, and the data before the plots (MAT-2); rows of a matrix of equal length, and what stands side by side of as many rows; only the 13 commands of MAT-2, each with the arguments the writer gives it, and inside expressions only the functions and constants above; what is drawn can be drawn (x and y of one length, nothing at or below zero on a logarithmic axis, a subplot inside its grid, a line style MATLAB knows, increasing axis limits); every panel that shows data has both axis labels. An operation the checker does not model is a problem too, so a script stays inside what is checked. `--model FILE` prints the figure the script draws (per axes: lines, stems, images, scales, grid, hold state, labels, title; the colorbars), which the Octave run compares with Octave's.

`Scripts/golden.sh --check` applies it to every `*.m` in a Golden folder and also requires each to be listed in the manifest (STG-2: a generator writes it): `golden: 199 files of 29 generators match the manifest` and `golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)`.

**Tests.** `Scripts/tests/test-matlab-check.sh` (in `run-all.sh`, 94 checks): the valid fixture passes and its figure is spelled out panel by panel; each of the 35 invalid fixtures fails with the problem its first line names; every committed golden script passes; several files in one call, an empty script, a carriage return, a missing file, and the usage errors. `test-golden.sh`: a golden script with a wrong command fails `--check` with `Tests/ZTronDSPDesignTests/Golden/stray.m:4: semilogz is not one of the commands of MAT-2`, and a script no generator wrote is named.

**What failed without the change.** The writer's golden script as `MATLABScriptTests.swift` held it inline fails the check with 6 problems (run today on the text of `HEAD`): line 10 `plot: x has 4 values and y 3 (Octave stops: vector lengths must match)`; lines 12, 13, 14 a zero or a negative value on a logarithmic axis (`semilogx`, `loglog`, and `stem` under the log axes they left); line 22 `axis: a limit at or below zero on a logarithmic axis`; line 24 `subplot(2, 1, 2) shows data and has no xlabel and no ylabel`. The other ten golden scripts passed as they were.

### Item 3 — the Octave run, made

**What the code does now.** `Scripts/golden.sh --octave` (mode of `Scripts/lib/golden_runner.py`) runs every golden MATLAB script of the tree, one Octave process per script, in a scratch folder:

```
QT_QPA_PLATFORM=offscreen octave --no-gui --quiet --norc --no-history --eval "addpath(<scratch>); ztd_run(<script>); ztd_figure_report (); printf ('ZTD-OCTAVE-DONE\n');"
```

`ztd_run` sets `set (0, 'defaultfigurevisible', 'off')` and then `source`s the script, unchanged, so its own plot commands execute and draw into an invisible figure; `ztd_figure_report` prints what the figures hold. A script passes when Octave exits 0, prints no line on standard error that starts with `error` or `warning` (any warning: stricter than the brief, section 5), reaches the end marker, and the figure Octave drew equals the one `matlab_check.py` says the script draws. Without `octave` on the PATH it prints `golden: SKIPPED: GNU Octave is not installed (no octave on the PATH): the N golden MATLAB scripts were not run under Octave (brew install octave)` and exits 3.

In `Scripts/ci.sh`, gate 7 runs it after the manifest check: 0 → `ok`, 3 → `skipped` loudly (`…: Octave is not installed (brew install octave)`; the gate then shows `PASSED IN PART`, and `--strict` fails the run), anything else → `FAILED`. `.github/workflows/ci.yml` installs Octave (`brew install octave`) in the job of gate 7 before the step that runs the gate, and that job's timeout went from 30 to 60 minutes, for the time the installation adds on a runner without Octave. **I cannot run the workflow here: it has not been run.** `test-workflow.sh` checks that the installation comes before the gate.

**The run on this machine** (`Scripts/golden.sh --octave`, gate step at 02:38:50–02:39:06, GNU Octave 11.3.0), each script `exit 0, no error and no warning`, and drawn as the script says:

| Script | Package | Octave drew |
|---|---|---|
| `Tests/ZTronDSPDesignTests/Golden/system_analysis.m` | WP-440 | 1 figure: 6 axes (6 lines, 2 stems) |
| `Tests/ZTronDSPAnalysisTests/Golden/script_window-analysis.m` | WP-501g | 1 figure: 2 axes (5 lines) |
| `Tests/ZTronDSPAnalysisTests/Golden/script_heatmap-linear.m` | WP-540 | 1 figure: 1 axes (1 image), 1 colorbar |
| `Tests/ZTronDSPAnalysisTests/Golden/script_heatmap-mel.m` | WP-540 | 1 figure: 1 axes (1 image), 1 colorbar |
| `Tests/ZTronDSPAnalysisTests/Golden/script_inversion.m` | WP-540 | 1 figure: 3 axes (4 lines) |
| `Tests/ZTronDSPAnalysisTests/Golden/script_inversion-frames.m` | WP-540 | 1 figure: 3 axes (4 lines) |
| `Tests/ZTronDSPAnalysisTests/Golden/script_inversion-conditions.m` | WP-540 | no figure: a report without a signal has nothing to plot (INV-2), only its conditions |
| `Tests/ZTronDSPAnalysisTests/Golden/script_scalar-track.m` | WP-540 | 1 figure: 2 axes (2 lines) |
| `Tests/ZTronDSPAnalysisTests/Golden/script_waveform.m` | WP-540 | 1 figure: 1 axes (2 lines) |
| `Tests/ZTronDSPMetalTests/Golden/calibration_report.m` | WP-614 | 1 figure: 3 axes (5 lines) |
| `Tests/ZTronDSPCoreTests/Golden/script_writer.m` | WP-120 | 1 figure: 4 axes (3 lines, 1 stem, 1 image), 1 colorbar |

Final line: `golden: 11 of 11 golden MATLAB scripts ran under GNU Octave as they draw`.

Beyond the golden scripts, a temporary test wrote 47 variant exports (analog low- and high-pass, FIR, unstable, gain only, taps with a zero at Nyquist, order 8; rectangular, lobeless, Kaiser, flat-top, two-sample and one-sample windows; exact, decimated, conditions-only, one-sample and framed inversions; heat maps of every `FeedAxis`, constant, 1 × 1, one row, one column, `NaN`, −∞, silence in dB; waveforms of one pair, flat, noise; tracks of one frame, `NaN`, rate 0; calibration reports with no entry, one size, one curve, three entries of five curves). `matlab_check.py`: `matlab-check: 47 scripts, 0 problems`; under Octave: `golden: 47 of 47 golden MATLAB scripts ran under GNU Octave as they draw`. Nothing found there beyond the analog labels (item 1), except that the comment of a count of one says "1 samples", "1 pairs", "1 frames" (section 4).

**Tests.** `Scripts/tests/test-golden.sh`, with a stand-in `octave` on the PATH: a run that exits 0, warns of nothing and reports the right figure passes, and names the script and the Octave it ran; the stand-in's log shows the invocation (`QT_QPA_PLATFORM=offscreen --no-gui --quiet --norc --no-history --eval addpath (…`), the script sourced through `ztd_run`, and `ztd_run` setting the visibility off before it sources; a run that warns fails (with Octave's words on stderr), one that stops with an error fails (status and error), one that does not reach its end fails; a run that does not draw what the script draws fails (`the figure Octave drew is not the one the script draws`, with the expected and the drawn figure), so the plot commands must execute. With `PATH=""` and with `PATH=/usr/bin:/bin` the run is skipped with exit 3 and says how many scripts were not run; a tree without scripts runs nothing. With the real Octave: the package's golden scripts pass; `valid/every-statement.m` passes with `1 figure: 5 axes (9 lines, 1 stem, 1 image), 1 colorbar`; and the 9 fixtures marked `% octave:` fail with Octave's words, among them the wrong plot command (`invalid/not-a-command.m`, `semilogz`: `'semilogz' undefined`), `vector lengths must match`, `omitting non-positive data in log plot` (twice), `out of bound 3`, `vertical dimensions mismatch`, `horizontal dimensions mismatch`, `'t' undefined`, `subplot: INDEX value must be >= 1 and <= ROWS*COLS`. `Scripts/tests/test-ci.sh`: gate 7 calls `golden --octave` after `golden --check`; a failure under Octave fails gate 7 and is reported; exit 3 is a loud skip and `PASSED IN PART`; `--strict` turns that skip into a failure.

**What failed without the change.** The writer's golden script of `HEAD`, run today through the same runner: `golden: FAILED under Octave: …/script_writer_old.m: Octave exited with status 1; Octave reported 2 errors or warnings; the run did not reach its end (ZTD-OCTAVE-DONE was not printed)`, `stderr: error: __plt2vv__: vector lengths must match` at line 10. With only its matrix widened, it went on to `warning: axis: omitting non-positive data in log plot` and `error: set: cameratarget must be finite` (`axis equal` on logarithmic axes, line 21). So the writer's golden test now builds a valid script that still uses every kind of variable and every command the writer has: `w = [0.125 0.25 0.5 1]`, `H` of 2 × 4, four panels (`subplot(2, 2, k)`): the linear plot with the stem, `axis equal` and the axis limits; `semilogx`; `loglog`; `imagesc` with its `colorbar`, each with its labels. `matlab_writer.py` writes it with the formatting rules of MAT-3 written out in Python, and the Swift test compares the writer's text with the file, as before with the string. The writer's code is unchanged: it writes what its caller asks for, and the invalid script was the test's input. The calibration golden of WP-614 was already valid; it moved from the test into a generated file unchanged.

### The ledger

Row WP-910: `Verifying`, implementer `Implementer M9-export (agent)`, backlog: "Owner, non-blocking: CR-007, CR-016, CR-018 and CR-019 still say the Octave runs were not made, and WP-910 made them; a scalar track's values carry no unit, so its ylabel is "value"; the comment of a count of one says "1 samples", "1 pairs", "1 frames" (impl-WP-910.md)". `Scripts/ledger.sh --check`: `ledger: 289 rows, consistent with §12 and §11` (exit 0), at 02:40:54 in the chain and again at 03:12 with this report in place.

## 3. Gates and tests

The gates of brief 60 in order, then the tests, then coverage, by `.build/m9-export/gates.sh` (logs `.build/logs/m9-export/gate-<name>.log`), from 02:35:07:

| Gate | Time | Exit | Final line |
|---|---|---|---|
| `Scripts/lint-bans.sh` | 02:35:07–02:35:14 | 0 | `lint-bans: clean (parts 1, 2, 3, 4; 609 files)` |
| `Scripts/check-dependency-graph.sh` | 02:35:14–02:35:22 | 0 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 02:35:22–02:36:22 | 0 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `Scripts/api-digest.sh --check` | 02:36:22–02:38:35 | 0 | `api-digest: 10 digests equal the built modules` … `api-digest: ZTronDSPUI references public symbols only` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 02:38:35–02:38:49 | 0 | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | 02:38:49–02:38:50 | 0 | `golden: 199 files of 29 generators match the manifest`, `golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)` |
| `Scripts/golden.sh --octave` | 02:38:50–02:39:06 | 0 | `golden: 11 of 11 golden MATLAB scripts ran under GNU Octave as they draw` |
| `Scripts/check-function-effects.sh` | 02:39:06–02:40:53 | 0 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | 02:40:53–02:40:54 | 0 | `ledger: 289 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | 02:40:54–02:49:18 | 0 | `run-all: every self-test passed (1033 checks in 16 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | 02:49:18–02:50:46 | 0 | `external-parity: passed` (fixtures, release, audits, speed) |

The suites of `run-all.sh`: spec-crosscheck 29, process-files 45, check-registers 45, lint-bans 44, check-dependency-graph 32, coverage-gate 44, **matlab-check 94** (new), **golden 129** (with the Octave part, run against the real Octave), compile-fixtures 22, order-matrix 36, api-digest 68, docs 56, benchmarks 37, **ci 176**, **workflow 24**, external-parity 152, each `0 failed`. The two skips are the `--slow` cases of `test-ci.sh` and `test-external-parity.sh`, as before this package.

**Tests, every test target.** `Scripts/xc.sh test` (Debug, 02:50:46–02:54:09, exit 0, `** TEST EXECUTE SUCCEEDED **`), nine runs, 2,118 tests:

```
✔ Test run with 278 tests in 19 suites passed after 3.068 seconds.
✔ Test run with 20 tests in 5 suites passed after 3.025 seconds.
━ Test run with 55 tests in 8 suites passed after 0.193 seconds with 3 known issues.
✔ Test run with 118 tests in 12 suites passed after 6.946 seconds.
✔ Test run with 134 tests in 13 suites passed after 4.222 seconds.
✔ Test run with 339 tests in 41 suites passed after 57.288 seconds.
✔ Test run with 511 tests in 60 suites passed after 9.167 seconds.
✔ Test run with 431 tests in 41 suites passed after 95.570 seconds.
✔ Test run with 232 tests in 31 suites passed after 7.075 seconds.
```

`ZTD_CONFIG=Release Scripts/xc.sh test` (02:54:09–02:56:48, exit 0, `** TEST EXECUTE SUCCEEDED **`), the same nine runs and counts:

```
✔ Test run with 278 tests in 19 suites passed after 2.512 seconds.
✔ Test run with 20 tests in 5 suites passed after 0.821 seconds.
━ Test run with 55 tests in 8 suites passed after 0.046 seconds with 3 known issues.
✔ Test run with 118 tests in 12 suites passed after 0.763 seconds.
✔ Test run with 134 tests in 13 suites passed after 4.373 seconds.
✔ Test run with 339 tests in 41 suites passed after 1.612 seconds.
✔ Test run with 511 tests in 60 suites passed after 4.965 seconds.
✔ Test run with 431 tests in 41 suites passed after 11.896 seconds.
✔ Test run with 232 tests in 31 suites passed after 1.172 seconds.
```

The run of 20 tests in 5 suites is the facade's target, which holds the new suite: `✔ Suite "Export completeness: every type of §6.14 exports as MAT-1…MAT-6 say (WP-910)" passed after 3.025 seconds.` (Debug) and `… after 0.821 seconds.` (Release). The regression test passed in both (`✔ Test theAxesOfThePoleZeroMapCarryTheUnitOfThePlane() passed`). The 3 known issues are the test support's own tests that a failure is recorded (`expectCloseRecordsAnIssueOnFailureOnly`, `expectNoAllocationsRecordsAnIssueWhenTheBlockAllocates`, `aNodeThatAllocatesIsCaughtOnTheTestsOwnThread`), as before this package. No test failed, so none was run again.

**Simulators.** Only `ztdsp-27` was used, as `Scripts/xc.sh` uses it, and it is left booted as the standard device; no other `ztdsp-*` simulator was booted. The other booted simulators on this Mac (`ztron-*`) belong to another project and were not touched.

**COV-3.** A Debug build and test run with coverage on (`ZTD_XCARGS="-enableCodeCoverage YES"`, 02:56:48–03:03:35; the same nine runs, 2,118 tests, passed) into a result bundle of its own, then `Scripts/coverage-gate.sh --mode changed-files` on `git diff --name-only --diff-filter=AMR -- Sources`, which is one file (`.build/m9-export/coverage-run.sh`; logs `.build/logs/m9-export/cov-*.log`):

```
coverage-gate: Sources/ZTronDSPDesign/Systems/SystemAnalysis+MATLAB.swift 100.00 % (82 of 82 lines), needs 97.50 %: ok
coverage-gate: pass (changed-files)
```

COV-2 holds too: `coverage-gate: aggregate      99.54 % (25715 of 25833 lines), needs 97.50 %: ok`, per target CZTronDSP 99.70 %, Core 99.69 %, Design 98.70 %, Metal 100.00 %, Analysis 99.83 %, IO 99.48 %, UI 99.64 %, with 15 lines marked `coverage:ignore` (0.06 %); `coverage-gate: pass (aggregate, per-target)`. The other files this package adds or changes are tests and scripts, outside the denominator of COV-1 and COV-6: the Python of `matlab_check.py` and of the runner's Octave mode is exercised by `test-matlab-check.sh` (94 checks) and `test-golden.sh` (129), and run on every golden script by the gates. The result bundle was deleted afterwards.

## 4. Open

- **The CI workflow has not been run.** I cannot run GitHub Actions here. The step `brew install octave` and the 60-minute timeout of the job of gate 7 are untested; on a runner without Octave gate 7 still passes in part, loudly, and fails under `--strict`.
- **Stale statements in four change requests.** CR-007 (item 2: "the Octave runs are not done"), CR-016 (WP-614), CR-018 (WP-440) and CR-019 (WP-540) say the scripts were not run under GNU Octave because it is not installed. WP-910 ran them (section 2, item 3). Those CRs are not this package's; I left them as they are and put the note in the ledger's backlog for the owner.
- **A scalar track has no unit.** `ScalarFrame` carries a value without its unit (a pitch track's values are hertz, a loudness track's are not), so the script of a `ScalarTrack` labels its y axis `value`. MAT-2's "units" cannot be met for a value whose unit the package does not know; giving `ScalarTrack` a unit would be a public change, outside this package. In the backlog.
- **Counts of one.** The comments of the exports write "1 samples", "1 pairs", "1 frames" for a count of one. No MAT rule is broken (a comment is not read back as data); left as it is, in the backlog.
- **`script_inversion-conditions.m` plots nothing.** An inversion report without a signal has only its conditions (INV-2), so its script defines them and draws no figure. That is the WP-540 design, unchanged; the completeness test's specimen has a signal, so all three panels are asserted.
- The brief names `AnalysisCalibration.swift`; the calibration's code is in `Sources/ZTronDSPMetal/Calibration/Calibration.swift` and the conformer in `CrossoverMeasurement.swift`. Nothing depends on it.

## 5. Change requests and decisions

No change request was written. Decisions I took, which the owner may overrule:

1. **The functions inside an expression.** MAT-2 names the 13 plot commands as core MATLAB. The exporters also use, inside expressions, `real`, `imag`, `abs`, `cos`, `sin`, `log10`, `fft`, `linspace` and `numel`, and the constants `pi`, `NaN` and `Inf`: core MATLAB, and Octave runs them. I read MAT-2's list as the plotting vocabulary and "core MATLAB only" as the rule, so the checker and the test allow exactly these nine functions and three constants and nothing else. If the owner wants the specification to name them, that is a one-line CR.
2. **Any warning fails the Octave run.** The update of 17:30 asks for nothing on standard error "that Octave calls an error or a warning about an unknown function or an unimplemented property". The runner fails on any line that starts with `error` or `warning`: a warning such as "omitting non-positive data in log plot" means the figure is not what the script says it draws. All 11 golden scripts pass under the stricter rule.
3. **The writer's golden script (WP-120) changed content.** It was a string in a test that did not run under Octave; it is now a generated file with a valid script (item 3). The comparison is exact text equality as before, and the script still uses every kind of variable and every command; only the test's input changed. Asked of the owner and the integrator: accept the new golden as WP-120's.
4. **MAT-6, how it is shown.** The test holds `BackgroundWork`'s queue and asserts that an export started then has not come back when the queue is let go. The pause while it is held (four times what one export took, at least 50 ms, at most 1 s) is no synchronisation: for an export whose work runs on the queue the outcome is the same however long the pause; the pause only gives an export that does not wait for the queue the time to show it by returning. Brief 60 says tests "do not synchronise with sleeps"; I hold this to be within that rule and say so for the integrator to judge. The other two parts (back on the main actor; cancelled before it starts → `DSPError.cancelled`) are deterministic.
5. **Units.** Labels must carry a unit where the quantity has one; a count (a sample number; the product kernel × bins × frames of the GPU median's sizes), a ratio (an amplitude, a confidence, a window's value) and the z-plane have none, and the test asserts those labels without one. The checker requires both labels on every panel that shows data.
6. **The facade's test target imports `@testable ZTronDSPCore` and `@testable ZTronDSPDesign`** (for `BackgroundWork.queue`, `Locked` and the internal `SystemAnalysis.exportedFrequencies()`, the frequencies `f` holds). `OrderMatrixTests` in the same target already imports Core so; Design so is new there. Both build in Debug and in Release (section 3).
7. **MAT-4's size guard and `SystemAnalysis`.** No `SystemAnalysis` can hold a variable over the limit (512 frequencies, 256 samples, roots up to degree 512), so its case asserts those bounds and the refusal of a system of degree 600, instead of a refusal of the export.
8. **Golden MATLAB scripts are listed in the manifest.** `--check` now fails on a `*.m` in a Golden folder that no generator wrote (STG-2), as it already did for vectors; the two scripts that lived inline in tests are therefore generated files now.
