# Implementation report — brief 76: DEP-4 as specified, the shaders compiled by the build (WP-601)

| Field | Value |
|---|---|
| Implementer | `metal-offline` (agent) |
| Brief | `ZTronDSP-handoff/briefs/76-offline-metal-shaders.md`, with `60-common-rules-main-tree.md` |
| Date | 2026-11-28, 14:43 to 17:25 (Europe/Rome). A first run on 2026-11-22 read and measured, and stopped at 18:57 on the usage limit before any edit. A second, on 2026-11-28 from 14:36 to 14:42, was stopped by the integrator; it edited nothing. |
| Tree | The main tree, branch `handover-chain`, HEAD `96567f3`. The work of this brief is `git diff 96567f3` plus eight untracked files, this report among them (section 1). Nothing is committed, staged or stashed. |
| Toolchain | Xcode 27.0 (27A266a). Metal Toolchain component 27.1.266.1 (`metal` 32023.921, installed by the owner's decision of 2026-11-21; this brief installed nothing). Simulators `ztdsp-27` (iOS 27.0), `ztdsp-18-m8b` (18.6), `ztdsp-175-m8b` (17.5). |

**What the brief got done.**

- **The build compiles the shaders.**
  - The build compiles each of the five `.metal` files of `Sources/ZTronDSPMetal/Shaders/` and links them into `default.metallib` in `ZTronDSP_ZTronDSPMetal.bundle`.
  - No shader source travels in the bundle any more (before: `Shaders/*.metal` and `README.txt`, and no library).
  - The one declaration two files shared through concatenation, `ZTDScreenVertex`, is in the new header `Shaders/Common.h`.
- **The context loads that library.**
  - `MetalContext` loads it with `makeDefaultLibrary(bundle: .module)`.
  - A bundle without a library that loads, or a library without a function a pipeline asks for, is `backendUnavailable` and names what is missing. Neither traps.
  - No `makeLibrary(source:` is left under `Sources/`. Part 4 of `Scripts/lint-bans.sh` reports one under the rule DEP-4, with its self-test.
  - The public API is unchanged (`Scripts/api-digest.sh --check`).
- **The compile options.**
  - Math mode, precision of the single-precision functions, macros, invariance and debug information are the same in both paths.
  - The language version differs: MSL 4.0 at run time against 2.4 in the build. It cannot follow the run-time path, because MSL 4.0 links only for a deployment target of iOS 26 (measured, section 2.3), and the package's floor is iOS 15. The shaders use nothing that depends on it.
  - The 32 numerical lines of the GPU tests are identical before and after, in Debug and in Release. No pragma was needed, and no tolerance was touched.
- **Creating the context.**
  - With warm caches it costs what it did, about 20 ms in Release.
  - With empty Metal caches it takes about half as long: medians of three launches, 392.5 ms after against 722.4 ms before, in Release. The first launch of the run-time path also rebuilt the front end's module cache, and took 6.9 s.
  - The first call in the run of every test target: 157.6 ms before, 83.7 ms after (Debug).
- **Tests.**
  - Three tests added and two removed (both depended on run-time compilation). The totals are equal before and after except for those.
  - The regression test of each restored behaviour fails when that behaviour is broken on purpose (section 2.7).
- **A machine without the toolchain.**
  - `Scripts/xc.sh build` and `test` stop with one line that names `xcodebuild -downloadComponent MetalToolchain`, status 64.
  - Every job of `.github/workflows/ci.yml` that builds downloads the component before its first gate. I could not run that workflow here.
  - Gate 1 now fails on a warning of the Metal compiler.
- **Records.** CR-011 is `Withdrawn`, with the outcome. No new change request.

## 1. Files

The paths are relative to the package.

**Added**

- `Sources/ZTronDSPMetal/Shaders/Common.h`: `ZTDScreenVertex`, which `Common.metal`, `Heatmap.metal`, `Probe.metal` and `Waveform.metal` include.
- `Scripts/tests/test-xc.sh`: the self-test of the toolchain check of `Scripts/xc.sh` (27 checks, stand-ins on the path).
- `Tests/Fixtures/Lint/part4/Sources/ZTronDSPMetal/Context/RuntimeShaders.swift`
- `Tests/Fixtures/Lint/part4/Sources/CZTronDSP/runtime_shaders.m`
- `Tests/Fixtures/Lint/part4/Tests/ZTronDSPMetalTests/StubLibraryTests.swift`
- `Tests/Fixtures/Lint/clean/Sources/ZTronDSPMetal/Context/ShaderLibrary.swift`
- `Tests/Fixtures/Lint/clean/Tests/ZTronDSPMetalTests/StubLibraryTests.swift`
- `Docs/Process/reports/impl-WP-601-offline-shaders.md`: this report.

The five fixtures are the lint rule's cases (section 2.2).

**Changed**

- `Package.swift`: the Metal target has no `resources: [.copy("Shaders")]`. The comment that cited CR-011 now says that the build compiles the shaders (DEP-4) and needs the Metal Toolchain component.
- `Sources/ZTronDSPMetal/Shaders/Common.metal`: the struct moved to `Common.h`, which it includes. The header comment describes the build, not the concatenation.
- `Sources/ZTronDSPMetal/Shaders/Heatmap.metal`, `Probe.metal`, `Waveform.metal`: `#include "Common.h"`.
- `Sources/ZTronDSPMetal/Context/MetalContext.swift`:
  - `ShaderLibrary` replaces `ShaderSources`. Its `load(from:on:)` calls `makeDefaultLibrary(bundle:)` and maps a failure to `backendUnavailable`.
  - `ShaderFunction` is the one list of the functions the pipelines take.
  - `PipelineStates` asks for every function through `ShaderFunction` and names the one that is missing.
  - The internal seam `init(device:shaderSource:textureLimit:)` becomes `init(device:library:textureLimit:)`.
  - The documentation of the type, `init(device:)`, `library`, `shared()` and `sharedBlocking()` says what creation does now, in its threading contract and its errors too.
- `Sources/ZTronDSPAnalysis/Separation/MedianStrategy.swift`: one documentation sentence ("blocks while the shared context is made", not "while the shaders compile").
- `Sources/ZTronDSP/ZTronDSP.docc/ZTronDSP.md`: a "Requirements" section with the Metal Toolchain.
- `Sources/ZTronDSPMetal/ZTronDSPMetal.docc/ZTronDSPMetal.md`: the build compiles the shaders, and a context loads them.
- `Tests/ZTronDSPMetalTests/MetalContextTests.swift`: three tests added, two removed, two adapted, and two helpers (section 2.4).
- `Tests/ZTronDSPMetalTests/WaveformRendererTests.swift`: the seam's new argument.
- `Tests/ZTronDSPAnalysisTests/OfflineSeparationTests.swift`: one comment.
- `Scripts/lib/lint_bans.py`, `Scripts/lint-bans.sh`: the rule DEP-4 of part 4.
- `Scripts/tests/test-lint-bans.sh`: its checks.
- `Scripts/xc.sh`: the toolchain check of `build` and `test`, and its paragraph in the header.
- `Scripts/tests/run-all.sh`: the suite `xc` (18 suites).
- `Scripts/ci.sh`: gate 1 builds with `MTL_TREAT_WARNINGS_AS_ERRORS=YES` besides the two settings it had, and its header says so.
- `Scripts/tests/test-ci.sh`: the check of the three settings. Its `--slow` part also seeds a `#warning` in `Common.metal`, which gate 1 must fail on as an error.
- `.github/workflows/ci.yml`: the step `xcodebuild -downloadComponent MetalToolchain` in the six jobs that build, and a paragraph in the header.
- `Scripts/tests/test-workflow.sh`: two checks of those steps.
- `Docs/Process/changes/CR-011.md`: `Withdrawn`, and the section "Owner's decision / outcome (2026-11-28)".
- `Docs/Process/ledger.md`: the note of WP-601, written with `tools/ledger_set.py`. Its status stays `Verifying`.
- `Docs/Release/0.1.0-checklist.md`: the Metal Toolchain requirement, and "18 suites".
- `CHANGELOG.md`: the requirement in the 0.1.0 entry.

**Deleted**

- `Sources/ZTronDSPMetal/Shaders/README.txt`: it said the sources are copied and compiled when a context is made. The build ignores the file, and copies it nowhere.

## 2. The items of the brief

### 2.1 Build (design item 1)

**What the code does now.**

- The Metal target declares no resources.
- SwiftPM under `xcodebuild` treats the `.metal` files of a target as Metal sources. A probe package confirmed this first (`.build/tmp/metal-offline/probe-pkg`, a target with `.metal` files, a `.h` and a `README.txt`); then the build of the package did. Per configuration it runs one `CompileMetalFile` per file and one `MetalLink`:

  ```
  metal -c -target air64-apple-ios15.0-simulator -I<Products>/include -F<Products> -isysroot <SDKs>/iPhoneSimulator27.0.sdk
        -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast -serialize-diagnostics <f>.dia -o <f>.air -MMD -MT dependencies -MF <f>.dat <f>.metal
  metal -target air64-apple-ios15.0-simulator -o <Products>/ZTronDSP_ZTronDSPMetal.bundle/default.metallib Common.air Heatmap.air Median.air Probe.air Waveform.air
  ```

  This is from the build logs of 2026-11-28 15:50–15:54 (`.build/logs/metal-offline/after/{debug,release}-build.build-for-testing.full.log`), Debug and Release alike.
- `Bundle.module` is still generated for the target.
- The header and the README give no warning and are not copied.
- What the bundle holds:
  - Debug and Release: `Info.plist`, `_CodeSignature/…` and `default.metallib` (26 433 bytes). `xcrun metal-nm` lists exactly `ztd_heatmap_fragment`, `ztd_median_kernel`, `ztd_probe_fragment`, `ztd_screen_vertex` and `ztd_waveform_fragment`.
  - Before (`.build/xcode-before`): `Info.plist`, `_CodeSignature/…`, `Shaders/{Common,Heatmap,Median,Probe,Waveform}.metal` and `Shaders/README.txt`, and no library.
  - The gallery application built after the change embeds `ZTronDSP_ZTronDSPMetal.bundle` with `default.metallib` and `Info.plist` only, also inside `GalleryTests.xctest`.
- **The shared declaration.** Under CR-011 the files were concatenated in name order, `Common.metal` first. Three files used its `ZTDScreenVertex` without declaring it. Each file is now its own translation unit:
  - the struct is in `Common.h`, with an include guard;
  - the four files that use it include the header;
  - `ztd_screen_vertex` is defined once, in `Common.metal`.
- **No Metal warnings.**
  - The builds show no warning of the Metal compiler. Their other `warning:` lines are the four of a test target's `.nan` comparison (`BindingTests.swift:259`, also before) and notices of `appintentsmetadataprocessor`.
  - The five files also compile with the build's flags plus `-Wall -Werror` (`.build/tmp/metal-offline/offline-check/`).
  - Gate 1 now passes `MTL_TREAT_WARNINGS_AS_ERRORS=YES` (Xcode's `-Werror` for the Metal compiler) besides `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `GCC_TREAT_WARNINGS_AS_ERRORS=YES`. "Free of warnings, the Metal compiler's included" is thus a rule the gate holds, not a reading of a log.

**Tests.**

- `theModuleBundleHoldsTheCompiledLibraryAndNoShaderSource()` (new): the bundle holds `default.metallib`, and no file ending in `.metal`, `.h` or `.air`, and nothing under `Shaders/`.
- `test-ci.sh`: the part-1 check "… with the three settings, the Metal compiler's among them (DEP-4)".
- `test-ci.sh --slow`: gate 1 of a copy with a seeded `#warning` in `Common.metal` must fail, with `error: "a seeded warning of the Metal compiler" [-Werror,-W#warnings]` (the string as corrected in 2.7).

**Without the change.** See section 2.7: the `.copy("Shaders")` rule put back, and the seeded warning. Without the flag in `ci.sh`, the part-1 check fails: "FAIL … with the three settings, the Metal compiler's among them (DEP-4) (the log lacks: SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES MTL_TREAT_WARNINGS_AS_ERRORS=YES)", 189 checks, 2 failed (log `.build/logs/metal-offline/regression/ci-part1-without-flag.log`). The other failure there came from my rewrap of gate 1's header in `ci.sh`: a check reads `ci.sh --list` and wants a line break after "the gallery". The header was wrapped again so that the break is back, and the check is unchanged. In `run-all.sh`, `test-ci.sh` then counted 189 checks, 0 failed (section 3.2).

### 2.2 Load (design item 2)

**What the code does now.**

- `MetalContext.init(device:)` checks the device. It then loads `ShaderLibrary.bundled(on:)`, which is `makeDefaultLibrary(bundle: .module)` on that device.
- It delegates to the internal seam `init(device:library:textureLimit:)`, which:
  - makes the command queue;
  - builds `PipelineStates`;
  - measures the capabilities.
- A failure of `makeDefaultLibrary(bundle:)` becomes `backendUnavailable(reason: "no shader library default.metallib in <bundle> that loads on <device>: …")`.
- `PipelineStates` takes every function through `ShaderFunction.function(_:of:)`. A missing one is `backendUnavailable(reason: "the shader library has no function <name>")`, by the name of the function that is missing.
  - Before, a render pipeline asked for the vertex and the fragment function in one guard. A missing `ztd_screen_vertex` was then reported under the name of the fragment.
  - A compute pipeline that cannot be made is `backendUnavailable(reason: "no compute pipeline for ztd_median_kernel on <device>")`.
- No path traps.
- **Public signatures.** None changed: `init(device: (any MTLDevice)?) throws(DSPError)`, `shared() async throws(DSPError)`, `sharedBlocking() throws(DSPError)`, `device`, `commandQueue`, `library: any MTLLibrary` and `capabilities`. `Scripts/api-digest.sh --check` passes (section 3).
- **The threading contract**, made true for what creation does now:
  - "Creating one allocates, loads the shader library, builds the pipeline states and draws once: not for the main thread, never for the analysis thread."
  - `shared()`: "the caller suspends while the context is made the first time".
  - `sharedBlocking()`: "the first call blocks while the context is made".
  - The errors now include a bundle without a usable library and a library that lacks a function.
  - What a context is (immutable, `Sendable`, usable from any thread) is unchanged.
- **The lint line.** Part 4 of `Scripts/lint-bans.sh` reports, under the rule DEP-4, any `.makeLibrary(source:` (also split over lines) and any Objective-C `newLibraryWithSource:` in a file under `Sources/`.
  - It reads the masked text, so a comment or a string does not count.
  - `Tests/` may compile from source: the tests of a library that lacks a function or has one too many do, with `stubLibrary(on:with:extra:)`.

**Tests.**

- `theLibraryHoldsExactlyTheFunctionsThePipelinesAskFor()` and `aBundleWithoutTheLibraryIsBackendUnavailable()` (section 2.4).
- `pipelinesForOtherFormatsAreBuiltOnDemand()`: a library without the fragment gives the error that names `ztd_heatmap_fragment`.
- `anAbsentDeviceIsBackendUnavailable()`.
- `test-lint-bans.sh` (51 checks):
  - `--part 4` on the fixture tree `part4` fails;
  - it reports `RuntimeShaders.swift:9`, with the whole message, `:18` (a call split over two lines) and `runtime_shaders.m:5`;
  - it does not report the comment (`:4`), the string (`:6`) or the file under `Tests/`;
  - the `clean` tree, which has `makeDefaultLibrary(bundle: .module)`, a mention in a comment and one in a string, stays clean.

**Without the change.**

- Without the rule: "51 checks, 4 failed", the first "FAIL part 4 reports every seeded configuration name, setter, open, Sendable and shader violation" (`.build/logs/metal-offline/regression/lint-without-rule.log`).
- With the rule, on HEAD's `MetalContext.swift` copied into a scratch tree: `MetalContext.swift:85: [DEP-4]`.
- For the Swift tests, see section 2.7.

### 2.3 The compile options (design item 3)

The run-time path was measured before any change:

- a probe spawned in `ztdsp-27` read `MTLCompileOptions()` back, and compiled a kernel that reports the macros it sees;
- `options: nil` is `MTLCompileOptions()`.

The build's options are from its log (2.1) and Xcode's `MetalCompiler.xcspec`.

| Option | Run time, before (`makeLibrary(source:options: nil)`) | Build, after | What was done |
|---|---|---|---|
| Math mode | fast (`__FAST_MATH__`, `__FINITE_MATH_ONLY__ 1`) | `-fmetal-math-mode=fast` (`MTL_FAST_MATH` YES) | Equal |
| Single-precision functions | fast (`__METAL_MATH_FP32_FUNCTIONS_FAST__`) | `-fmetal-math-fp32-functions=fast` | Equal |
| Preprocessor macros | none | no `-D` | Equal |
| Invariance | not preserved | no `-fpreserve-invariance` | Equal |
| Debug information, optimisation | none; the default level | no `-g`, no `-O` (`MTL_ENABLE_DEBUG_INFO` NO) | Equal settings |
| Language version | MSL 4.0, the newest the OS offers a binary with deployment target iOS 15.0 (4.1 for 27.0); `__METAL_VERSION__` 400 | MSL 2.4, from the deployment target (`MTL_LANGUAGE_REVISION` UseDeploymentTarget, no `-std`); `__METAL_VERSION__` 240 | Not matched (below) |
| `__METAL_IOS__` | not defined | defined | The shaders do not use it |
| Translation units | one, every file concatenated in name order | five, linked | `Common.h` (2.1) |

The results of the subnormal and NaN cases the probe computes are the same in both paths:

- `1e-40 * 1 + 0` is kept, not flushed (`0x116c2`);
- `max(NaN, 1)` is 1;
- `clamp(NaN, 0, 1)` is 0.

**The language version.**

- **It cannot follow the run-time path.**
  - The manifest has no Metal compiler setting.
  - A pragma does not choose a language version: `metal --help`, and the headers of the installed toolchain, show only `#pragma METAL fp math_mode(…)`; the toolchain ships no specification.
  - MSL 4.0 cannot serve the floor of the package, whatever the setting. `report.metal` compiled with `-std=metal4.0 -target air64-apple-ios15.0-simulator` gives AIR 2.8. Linking that for iOS 15.0 says "air-lld: warning: ignoring file 'report-msl40.air', file AIR version (2.8) is bigger than the one of the target being linked (2.4)", and gives an empty 118-byte library. For iOS 18.0 the limit is AIR 2.7. For iOS 26.0 it links (4 344 bytes). Files: `.build/tmp/metal-offline/options-probe/`.
  - MSL 4.0 therefore needs a deployment target of iOS 26, and the package's is 15.0 (PLAT-1).
- **It does not need to.**
  - The shaders use no feature newer than MSL 2.4: they build with the build's flags plus `-Wall -Werror`.
  - They contain no `#if`, and none of the macros that differ (`__METAL_VERSION__`, `__METAL_IOS__`).
  - The numbers are the same (below).

No pragma or attribute was added: nothing that the numbers depend on differs.

**The numbers of the numerical tests.** `.build/tmp/metal-offline/numbers.sh` takes the numerical lines the GPU tests print from the full log of the run of every test target, 32 lines in all:

- the warp tables of the frequency scales (linear, logarithmic, mel, HTK mel, square root);
- the heat-map texture's largest relative error and its largest error in decibels;
- the `r16Float` sampler probe;
- the GPU median against its oracle;
- PSNR and largest difference of the 17 golden heat-map and 6 waveform images, which cover the colour maps, the scales, the range and the peak paths;
- the WP-612 medians.

Before and after, in Debug and in Release, the four files are the same 32 lines, character for character (`diff` empty). Debug equals Release. Two of the lines as they read after the change:

```
heat-map texture: largest relative error of a texel against its input 0.0004070251598022878 (bound 2^-11 = 0.00048828125); largest error of a level in decibels 0.0308074951171875 (bound 2^-5 = 0.03125)
golden heatmap-turbo: PSNR 75.1 dB, largest difference 1
```

The calibration tests print timings, which vary from run to run. They passed before and after, with their bounds unchanged. No tolerance, bound or expectation was changed.

**Creating the context.** The time is `MetalContext.shared()` as `theSharedContextWorksOnTheSimulator()` prints it. The test ran alone, one launch each, on the iOS 27.0 simulator.

| Case | Before (run-time compilation), ms | After (`default.metallib`), ms |
|---|---|---|
| Release, warm caches | 27.9, 20.4, 25.0, 21.6, 18.5 (median 21.6) | 437.2 (the first launch after the build), 19.3, 19.0, 24.9, 24.1 (median 24.1; of the last four 21.7) |
| Debug, warm caches | 22.3, 23.9, 26.4 (median 23.9) | 22.7, 22.7, 20.4 (median 22.7) |
| Release, both Metal caches of the test process emptied before the launch | 6891.3, 722.4, 715.8 (median 722.4) | 851.3, 259.3, 392.5 (median 392.5) |
| Release, the launch right after each of those | 28.8, 20.5, 624.9 | 22.0, 18.9, 22.7 |
| First call in the run of every test target, among the other tests | 157.6 (Debug), 61.5 (Release) | 83.7 (Debug), 57.2 (Release) |

- **The two caches.** They are those of the xctest tool in the simulator (`data/Library/Caches/com.apple.dt.xctest.tool/`):
  - `com.apple.metalfe` is the front end's, with the precompiled `metal_stdlib` module (11 MB). Only compilation from source needs it.
  - `com.apple.metal` holds the GPU code made from AIR.
- **Warm.** With both caches warm the two paths take the same time within the noise. Before the change, that cache already held what the same source had given for days.
- **The first launch after the build.** It took 437.2 ms because the GPU-code cache had not seen the new library.
- **Empty caches.**
  - `.build/tmp/metal-offline/cold.sh` copied both caches aside, emptied them before each "cold" launch, and put them back at the end (`.build/logs/metal-offline/cold/summary.txt`).
  - The run-time path then compiles the source and makes the GPU code. The library built by the build only needs the GPU code.
  - One warm launch before the change took 624.9 ms, the one after the third cold launch. I have no explanation for it, and report it as measured.

### 2.4 Tests (design item 4)

`Tests/ZTronDSPMetalTests/MetalContextTests.swift`, from 118 to 119 test functions (141 to 142 cases):

- **Added.**
  - `theModuleBundleHoldsTheCompiledLibraryAndNoShaderSource()`: as in 2.1.
  - `theLibraryHoldsExactlyTheFunctionsThePipelinesAskFor()`: one list, `ShaderFunction.allCases`, compared both ways with `context.library.functionNames`:
    - no function asked for is missing, and no function compiled goes unused, and their counts are equal;
    - the comparison sees each kind of difference, on stub libraries compiled in the test: one without `ztd_probe_fragment`, and one with an extra `ztd_unused_kernel`;
    - for every function of the list, a library without it makes no context, and the error names that function.
  - `aBundleWithoutTheLibraryIsBackendUnavailable()`:
    - `ShaderLibrary.load(from:on:)` on the test bundle, which holds no `default.metallib`, is `backendUnavailable`, naming that bundle;
    - a library with none of the functions names `ztd_screen_vertex`.
- **Removed**, because the behaviour they held is gone:
  - `shadersThatDoNotCompileAreBackendUnavailable()`, a source that does not compile. Its cases of a library that lacks a function are in the new tests.
  - `theBundledSourcesAreEveryShaderFileInOrder()`, the order of concatenation.
- **Adapted.**
  - `theSharedContextWorksOnTheSimulator()` checks the functions through `ShaderFunction`.
  - `pipelinesForOtherFormatsAreBuiltOnDemand()` uses a library without the fragment instead of a name that does not exist.
  - `aContextCanBeHeldToSmallerTextures()` uses the new seam with the shared context's library, as does one line of `WaveformRendererTests.swift`.
  - `anAbsentDeviceIsBackendUnavailable()` calls the public initialiser where it called the old seam, which took an optional device and a source. The new seam takes a device that is there.

The runs of every target, the simulators and the gallery are in section 3. The regression runs are in 2.7.

### 2.5 A machine without the toolchain (design item 5)

- **`Scripts/xc.sh`.** `build` and `test` call `require_metal_toolchain` before anything else.
  - It runs what `xcrun -f metal` finds, with `--version`. Finding a compiler is not enough: Xcode 27 ships a stand-in (`XcodeDefault.xctoolchain/usr/bin/metal`) that `xcrun` finds when the component is missing (`TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcrun -f metal`). That stand-in prints "error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain" and exits 1.
  - Without the component, the script writes one line to standard error and exits 64, the status of its other refused run (an unknown command): "xc.sh: building compiles the Metal shaders, and Xcode's Metal Toolchain component is not installed: run \`xcodebuild -downloadComponent MetalToolchain\`, then build again".
  - `test-only`, `products` and `device` build nothing and do not check.
  - The header of the script says all this.
- **`Scripts/tests/test-xc.sh`** (new, in `run-all.sh`; 27 checks). Stand-ins for `xcrun`, `metal` and `xcodebuild` are on the `PATH`, and the derived data is in a scratch folder. It checks:
  - `build` refuses with status 64 and the one line, before `xcodebuild` is called, both when `xcrun` finds no compiler and when it finds only the stand-in;
  - `test` refuses the same way;
  - an unknown command gets the same status;
  - with the component, `build` runs `build-for-testing`, and `test` runs `build-for-testing` and then `test-without-building` with its filter, into the derived data it is given;
  - `test-only`, `products` and `device` answer without the component.
  - Without the check: "27 checks, 11 failed". With a check that only finds the compiler and does not run it: "27 checks, 4 failed", the stand-in's cases. Logs: `.build/logs/metal-offline/regression/xc-*.log`.
  - Against the real stand-in, `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault Scripts/xc.sh build` exited 64 with that line and made no derived data.
- **`.github/workflows/ci.yml`.**
  - The step "Xcode's Metal Toolchain component, which the build of the shaders needs (DEP-4)", `xcodebuild -downloadComponent MetalToolchain`, comes before the first gate of every job that builds: `gates-1-4` (after the self-tests, before gate 1), `gate-5-tests`, `gate-5-thread-sanitizer`, `gate-8-benchmarks`, `gate-9-external-parity` and `gallery-ui-nightly`. `gate-7` builds nothing.
  - `Scripts/tests/test-workflow.sh` (26 checks) lists the jobs that build (those that run `Scripts/ci.sh` for a gate other than 7, and the nightly job) and requires each to download the component in a step before its first step that runs `Scripts/ci.sh`. Without the steps: "26 checks, 1 failed", "(output lacks: jobs that build before the metal toolchain is downloaded: none)".
  - **I could not run the workflow here**, so the step itself is not exercised: whether a hosted runner's Xcode needs it, and how long the download takes.
- **Where the requirement is stated.** There is no README.
  - The landing page of the documentation (`ZTronDSP.docc/ZTronDSP.md`) has a "Requirements" section: iOS 15, Swift 6, `xcodebuild` only, and the Metal Toolchain with its command.
  - `CHANGELOG.md` (0.1.0) states it.
  - `Docs/Release/0.1.0-checklist.md` has a bullet: `xc.sh` builds nothing without the component and says so in one line, with status 64, and every gate that builds fails.

### 2.6 Records (design item 6)

- **`Docs/Process/changes/CR-011.md`.** Status `Withdrawn`; What, Why, Evidence and Sections affected as they were. The section "Owner's decision / outcome (2026-11-28)" holds:
  - the owner's approval of the toolchain on 2026-11-21;
  - what brief 76 changed;
  - what was measured: the options, the language version, the numbers, the creation times before and after (warm, cold, and in the full run), and the tests.

  `Scripts/release-check.sh` counts `Withdrawn` as decided.
- **`Package.swift`.** The comment that cited CR-011 is gone (2.1).
- **The ledger.** The note of WP-601 (status unchanged, `Verifying`) was set with `tools/ledger_set.py`: "2026-11-28: DEP-4 as specified (brief 76; CR-011 withdrawn): the build compiles Shaders/*.metal into default.metallib in the module bundle, which MetalContext loads with makeDefaultLibrary(bundle: .module); a missing library or function is backendUnavailable; building needs Xcode's Metal Toolchain component, which Scripts/xc.sh checks and every CI job that builds downloads (impl-WP-601-offline-shaders.md)". `Scripts/ledger.sh --check` then passed (section 3).
- **The documents.**
  - Every text that described compilation at run time was corrected: the documentation of `MetalContext` and `MedianStrategy`, both landing pages, the header comment of `Common.metal`, the README of the shaders (deleted), and two test comments.
  - `grep -rn -i "makeLibrary\|compiled when\|CR-011" Docs Sources` now finds, outside `Docs/Process/reports/`:
    - the ledger note above;
    - `CR-011.md` itself: its title and "What" record the withdrawn deviation, and its outcome says that no `makeLibrary(source:` remains;
    - nothing under `Sources/`.
  - Under `reports/`, the only hit is `impl-WP-906.md`: a record of 2026-11-22 that lists CR-011 among the open change requests then, and is left as written.
  - The specification is not edited. DEP-4 calls itself "Assumption, confirmed by WP-601", and the risk table of §13.1 calls it an assumption that WP-601 confirms first. With the component installed, it holds as written.

### 2.7 The regression runs: each restored behaviour broken on purpose

- **The Swift tests.** `.build/tmp/metal-offline/mut.sh` ran from 16:47 to 16:49, after the measurements, in derived data of its own (`.build/xcode-mut`, Debug, `ztdsp-27`). For each trial it:
  - applied one change to the delivered tree;
  - built;
  - ran the named tests;
  - put the files back from a copy taken at the start.

  After every trial the hash of `git diff` was the one of the start ("restored: identical"). Logs: `.build/logs/metal-offline/mutations/`.

| Trial | What was broken | What failed |
|---|---|---|
| control | nothing | "✔ Test run with 10 tests in 1 suite passed" (`MetalContextTests`) |
| copy-shaders | `resources: [.copy("Shaders")]` back in `Package.swift` (CR-011's bundle) | `theModuleBundleHoldsTheCompiledLibraryAndNoShaderSource()`: "Expectation failed: files.contains("default.metallib")" (`:49`) and "sources.isEmpty" (`:53`). Also `theSharedContextWorksOnTheSimulator()`: "Caught error: The backend is unavailable: no shader library default.metallib in ZTronDSP_ZTronDSPMetal.bundle that loads on Apple iOS simulator GPU: no default library was found". This is the typed error, not a trap, for a bundle without the library. |
| unused-function | a kernel `ztd_seeded_unused_kernel` added to `Median.metal`, asked for by no pipeline | `theLibraryHoldsExactlyTheFunctionsThePipelinesAskFor()`: "Expectation failed: mismatch.unused.isEmpty" (`:62`), and the count (`:63`) |
| combined-guard | the old guard of a render pipeline, one `guard` for the vertex and the fragment function | `aBundleWithoutTheLibraryIsBackendUnavailable()` (`:100`): expected "… has no function ztd_screen_vertex", but "… has no function ztd_heatmap_fragment … was thrown instead". Also `theLibraryHoldsExactlyTheFunctionsThePipelinesAskFor()` (`:80`) |
| trap | `try!` instead of `try` in `ShaderLibrary.load(from:on:)` | "MetalContext.swift:154: Fatal error: 'try!' expression unexpectedly raised an error: … no default library was found", "Restarting after unexpected exit, crash, or test timeout", "Failing tests: MetalContextTests.aBundleWithoutTheLibraryIsBackendUnavailable()" |
| metal-warning | `#warning "a seeded warning of the Metal compiler"` appended to `Common.metal` | `Scripts/xc.sh build` only warns ("Common.metal:21:2: warning: "a seeded warning of the Metal compiler" [-W#warnings]", "** TEST BUILD SUCCEEDED **"). `Scripts/ci.sh --gate 1` fails: "Common.metal:21:2: error: "a seeded warning of the Metal compiler" [-Werror,-W#warnings]", "** BUILD FAILED **", "ci: gate 1  build  FAILED — build ZTronDSP for the simulator, warnings as errors" |

- **The scripts.** Each was run once without the change and once with it:
  - the lint rule (2.2);
  - the toolchain check of `xc.sh` (2.5);
  - the download steps of the workflow (2.5);
  - the third setting of gate 1 (2.1).

  The logs are in `.build/logs/metal-offline/regression/`.
- **A defect of mine, found by the metal-warning trial.** The `--slow` check I had added to `test-ci.sh` looked for "error: a seeded warning of the Metal compiler". The compiler quotes the text of a `#warning`, so the check would have failed on a correct gate.
  - It now expects `error: "a seeded warning of the Metal compiler" [-Werror,-W#warnings]`.
  - `grep -F` on the real output of gate 1 finds the new string once and the old one never.
  - The real `--slow` run is in section 3.

## 3. Gates and test totals

### 3.1 How the runs were made

- **Before.** `.build/tmp/metal-offline/before.sh` ran on the tree as found: HEAD `96567f3`, `git status --short` empty. It used derived data of its own, `.build/xcode-before` and `-gallery`.
  - The builds ran from 14:54 to 14:59, before any edit.
  - The tests then ran from those products only, until 15:50.
- **After.** `.build/tmp/metal-offline/after.sh` ran on the changed tree, from 15:50 to 16:45.
  - It built Debug and Release in `.build/xcode`.
  - It then ran the same tests, and the gallery's hosted suites as `Scripts/ci.sh` runs them: `gallery.sh hosted`, failing on "recorded a known issue".
- **The rest, one after another** (`.build/tmp/metal-offline/post.sh`), from 16:45:
  - the options probe;
  - the cold-cache times;
  - the regression trials;
  - the gates;
  - the external parity suite.
- **The tree.** Since the after-run's builds, only three files changed: `Scripts/tests/test-ci.sh` (the fix of section 2.7, which only its `--slow` part reads), `CR-011.md` and this report (`find -newer`). The mutated files were put back byte for byte (SHA-256 equal to the copies).
- **Simulators.** One was booted at a time, and each was shut down after its runs.
- **Logs.** They are in `.build/logs/metal-offline/{before,after,mutations,cold,gates,regression}/`, each with a `summary.txt`, with the result bundles of the test runs. Beside them are `options-probe.log`, `external-parity.log`, `test-ci-slow.log` and `post-summary.txt`. The scripts that made them are in `.build/tmp/metal-offline/`.
- **Clean-up.**
  - At the end I deleted the derived data I had made: `.build/xcode-before`, `xcode-before-gallery`, `xcode-after-gallery`, `xcode-mut`, `ci`, `ci-strict`, `ci-gallery-release`, `docs` and `xcode-effects`, all created today by these runs.
  - `.build/xcode` holds the after-run's Debug and Release builds. It and `.build/external-parity` existed before, and are kept.
  - No simulator is left booted.

### 3.2 The gates of brief 60

Each ran on the delivered tree, from 16:49 (`.build/logs/metal-offline/gates/`). Every one exited 0.

| Gate | Final line |
|---|---|
| `Scripts/ci.sh --gate 1` (simulator and device builds of `ZTronDSP` and `ZTronDSPUI` with the three warnings-as-errors settings, the gallery in Release, the build for testing with coverage) | `ci: no gate failed` |
| `Scripts/lint-bans.sh` | `lint-bans: clean (parts 1, 2, 3, 4; 610 files)` |
| `Scripts/check-dependency-graph.sh` | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | `api-digest: 10 digests equal the built modules` … `api-digest: ZTronDSPUI references public symbols only` |
| `Scripts/docs.sh --audit` (gate 4) | `docs: every public symbol is documented with its threading contract (VIS-2)` |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | `golden: 207 files of 29 generators match the manifest` … `golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)` |
| `Scripts/check-function-effects.sh` | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | `ledger: 293 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | `run-all: every self-test passed (1303 checks in 18 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | `external-parity: passed` (17:07:57–17:09:26) |
| `Scripts/docs.sh --build` (no gate; both landing pages changed) | `docs: 8 archives, 16037 pages, no warning for the package's sources` |

- **The two checks `run-all.sh` skips.** They are the `--slow` parts of `test-ci.sh` (a real gate 1 with seeded warnings) and of `test-external-parity.sh`. I ran `test-ci.sh --slow` on its own after the gates, from 17:11 to 17:17, with `TMPDIR=.build/tmp` (log `.build/logs/metal-offline/test-ci-slow.log`). It ended with `194 checks, 0 failed`. Among those checks: "ok gate 1 (real build): a clean copy builds for simulator and device with warnings as errors", "ok gate 1 (real build): a seeded warning of the Metal compiler fails (DEP-4: the build compiles the shaders)", and its "ok … as an error". I did not run the `--slow` part of `test-external-parity.sh`, because this brief did not change that script.
- **The self-tests I added or changed.** `test-lint-bans.sh` has 51 checks (seven new), `test-workflow.sh` 26 (two new), and `test-xc.sh` 27, a new suite. The check of the librosa checkpoint counted 1267 checks in 17 suites; 1303 is 1267 + 7 + 2 + 27. In `test-ci.sh` (189 checks) one part-1 check now asks for the third setting, and `--slow` has two more.
- **Coverage (COV-3).** These figures are from the run of every test target with coverage, on gate 1's build (`.build/ci`; result bundle `.build/logs/metal-offline/gates/coverage.xcresult`), through `Scripts/coverage-gate.sh --mode changed-files`:
  - `Sources/ZTronDSPMetal/Context/MetalContext.swift 100.00 % (133 of 133 lines)`;
  - `Sources/ZTronDSPAnalysis/Separation/MedianStrategy.swift 100.00 % (115 of 115 lines)`;
  - `coverage-gate: pass (changed-files)`.

  Inside lines that ran, three regions never run (xccov's per-line ranges):
  - the `else` of `guard let queue = device.makeCommandQueue()` (`:86`);
  - the `else` of the compute pipeline (`:239`);
  - the `catch` of a render pipeline (`:264`).

  They need a device without a queue, a kernel the device cannot build, or a pixel format no target can have. Under Metal's validation, which a test run has on, the process stops before that last error is reported. The `.metal` files cannot be instrumented. Their register, `Docs/Process/shader-coverage.md`, is unchanged and holds (part 4 of the lint), because `Common.h` holds no function.

### 3.3 The test targets, before and after

The test cases come from the result bundles (`.build/tmp/metal-offline/xcresult_totals.py`; a parameterised test counts each argument).

| Run | Before | After |
|---|---|---|
| Every target, Debug, iOS 27.0 | 2839 cases: 2836 passed, 3 expected failures | 2840 cases: 2837 passed, 3 expected failures |
| Every target, Release, iOS 27.0 | 2839 cases: 2836 passed, 3 expected failures | 2840 cases: 2837 passed, 3 expected failures |
| Metal and UI targets, iOS 27.0, two more runs in each configuration | 512 passed, four times | 513 passed, four times |
| Metal and UI targets, iOS 18.6, Debug and Release | 512: 509 passed, 3 failed (UI) | 513: 510 passed, 3 failed (UI), the same three |
| Metal and UI targets, iOS 17.5, Debug and Release | 512: 506 passed, 6 failed (UI) | 513: 507 passed, 6 failed (UI), the same six |
| The gallery's hosted suites, iOS 27.0 | `✔ Test run with 24 tests in 8 suites passed after 80.933 seconds.` | `✔ Test run with 24 tests in 8 suites passed after 80.479 seconds.` |
| The gallery's hosted suites, iOS 18.6 | `✔ Test run with 24 tests in 8 suites passed after 79.907 seconds.` | `✔ Test run with 24 tests in 8 suites passed after 80.854 seconds.` |
| The gallery's hosted suites, iOS 17.5 | `✘ Test run with 24 tests in 8 suites failed after 82.819 seconds with 1 issue.` | `✘ Test run with 24 tests in 8 suites failed after 83.367 seconds with 1 issue.` |

By target, on iOS 27.0, Debug and Release alike. The only difference is the Metal target's one test function more (three added, two removed). Every one of these targets passed, apart from the three expected failures of `ZTronDSPTestingTests` (`expectNoAllocationsRecordsAnIssueWhenTheBlockAllocates()`, `expectCloseRecordsAnIssueOnFailureOnly()`, `aNodeThatAllocatesIsCaughtOnTheTestsOwnThread()`), before and after:

| Target | Before: cases (test functions) | After |
|---|---|---|
| CZTronDSPTests | 422 (232) | 422 (232) |
| ZTronDSPAnalysisTests | 685 (433) | 685 (433) |
| ZTronDSPCoreTests | 603 (511) | 603 (511) |
| ZTronDSPDesignTests | 339 (339) | 339 (339) |
| ZTronDSPIOTests | 143 (134) | 143 (134) |
| ZTronDSPMetalTests | 141 (118) | 142 (119) |
| ZTronDSPTestingTests | 73 (55) | 73 (55) |
| ZTronDSPTests | 62 (20) | 62 (20) |
| ZTronDSPUITests | 371 (278) | 371 (278) |

The final lines of the Metal target's runs after the change:

- on 27.0: `✔ Test run with 119 tests in 12 suites passed after 3.854 seconds.` (Debug), `… after 0.690 seconds.` (Release);
- on 18.6 and 17.5: `✔ Test run with 119 tests in 12 suites passed …`, in each configuration.

The library, built for a deployment target of iOS 15.0, loads on every runtime installed here, the oldest being 17.5.

**What failed, before and after alike.** These are findings of the tree as found, not of this change. They were not repaired, and no expectation was touched. The result bundles' lists of tests that did not pass are identical before and after, run by run (`diff` empty).

- **On 18.6** (the UI target: `✘ Test run with 278 tests in 19 suites failed … with 12 issues.` in all four runs):
  - `AxisTests/theAxesOfAComponentLineUpWithItsPicture()`;
  - `HostedSourceFedTests/aViewInATabHiddenAndShownWhileAttachingEndsWithOneAttachment()`;
  - `HostedSourceFedTests/aViewInATabDetachesWhenItIsHiddenAndStartsAnEmptyPictureWhenItComesBack()`.

  `impl-WP-906.md` lists the two tab tests on 18.6, and the axis test only on 17.5.
- **On 17.5** (`… with 15 issues.` in all four runs): those three, and `HostedPinchTests/everyPathInstallsItsGesturesAndHearsAPinch(path:)` for `.legacy`, `.magnify` and `.touches`, as `impl-WP-906.md` lists them.
- **The gallery on 17.5.** `SizeTransitionAcceptanceTests` `aRotationThereAndBack()` fails at `SizeTransitionAcceptanceTests.swift:173`, "Expectation failed: verdict.worstCommitted <= 1".
  - Before, the rotation measured 1.29 px (frame 17).
  - After, the rotation back measured 1.05 px (frame 17), and the rotation 0.96 px.

  No report or note names it. It measures the drawable's size against the presentation's during a rotation, and no shader is involved. `Scripts/ci.sh`'s gate 5 runs the gallery on each simulator of its matrix, and `ci.yml`'s matrix holds iOS 17.5. Its hosted run there fails on the tree as found, as it does here.

**The process incident.** At 15:14–15:20 I edited `Scripts/xc.sh`, while one step of the before-run (Release on 18.6) was executing it. Bash read the changed file and ended that step with "Scripts/xc.sh: line 163: syntax error: unexpected end of file", exit 2 instead of 65. Its result bundle is complete, and its totals are the ones above. From then on no script was edited while a run used it.

### 3.4 The external parity suite

`Scripts/external-parity.sh` builds `ExternalParity/`, a package that depends on this one by path and on its three products only, as an app does. It ran from 17:07:57 to 17:09:26, exit 0, log `.build/logs/metal-offline/external-parity.log`:

```
external-parity: [build] built for testing, Debug
external-parity: [test] 116 tests passed; 1 expectations are known to fail and did:
external-parity: [release] built for testing, Release
external-parity: [audits] 19 tests passed; 1 expectations are known to fail and did:
external-parity: [audits] 1 tests passed
external-parity: [speed] launch 1 of 3:
external-parity: [speed] 3 tests passed; 1 expectations are known to fail and did:
external-parity: passed
```

- **The two known issues** are the ones the script names:
  - the control case of the audits;
  - the gain written as a `SampleProcessor` in the speed check (CR-025 item 1).
- **The counts** are those of the librosa check on `96567f3`: test 116 + 1, audits 19 + 1 + 1, speed 3.
- **The shaders.** Built from outside, the package's Metal target was compiled by the build too. The external build's log has five `CompileMetalFile` lines and one `MetalLink` into `.build/external-parity/Build/Products/Debug-iphonesimulator/ZTronDSP_ZTronDSPMetal.bundle/default.metallib`. That bundle, the Release one, and the copy inside `ExternalStagesTests.xctest` hold `default.metallib` and `Info.plist` only.

## 4. What is open, and what could not be done here

- **The CI workflow.** I could not run `.github/workflows/ci.yml`. Its download step, `xcodebuild -downloadComponent MetalToolchain`, is unexercised, since this brief installs nothing: on this host the component was already there. Whether a hosted runner's Xcode already has the component, and how long the download takes there, is not known. `test-workflow.sh` checks the step's place only.
- **A machine without the component.** The refusal of `Scripts/xc.sh` is exercised with stand-ins, and with Xcode's own stand-in through `TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault`. It was not exercised on a host where the component is really absent.
- **iOS 15 and 16.** No runtime older than 17.5 is installed. The library is AIR 2.4 for iOS 15.0 and loaded on 17.5, 18.6 and 27.0. iOS 26.5, which is in CI's matrix, is not among the simulators the brief names, and was not run.
- **Findings of the tree as found** (section 3.3), outside this brief and not repaired:
  - the UI tests on 18.6 and 17.5;
  - the gallery's rotation test on 17.5.
- **For anyone who builds the package.** DEP-4 has a consequence for every build of the package, an app's included: the Metal Toolchain component of Xcode must be installed. The landing page, the CHANGELOG and the checklist say so.
- **The first launch after an update.** It loads a library whose GPU code the device's cache does not hold yet. Here that took 0.26–0.85 s with emptied caches, against 0.72–6.9 s for the source path (section 2.3).
- **The 2026-11-22 run** of this brief left no files. The measurements of the run-time path were made again today, before any edit.

## 5. Change requests and decisions

- **Change requests.**
  - No new change request.
  - CR-011 is `Withdrawn`, as the brief decided on the owner's approval of the toolchain of 2026-11-21.
  - The specification is not touched. DEP-4 holds as written.
- **Decisions I made, and recorded in the notes.**
  - `xc.sh`'s refusal is status 64. It is checked by `build` and `test` only, and it runs the compiler `xcrun` finds, because the stand-in resolves too.
  - Gate 1 treats the Metal compiler's warnings as errors, so the brief's "free of warnings, the Metal compiler's included" is held by the gate.
  - The new self-test is a suite of its own (`xc`, 18 suites), and the checklist's "17 suites" follows it.
  - The download step goes into the six jobs that build. `gate-7` builds nothing.
  - The README of the shaders is deleted.
  - The language version stays the deployment target's (MSL 2.4), for the reasons of 2.3.
  - The external parity suite was not run before the change: it builds from the tree, which would have stopped all editing while it ran. Its state before is the check of the librosa checkpoint on `96567f3` (`agent-states/check-librosa-round0.md`): "`external-parity: passed` (rules, guide, build, test 116 + 1 known issue, fixtures, release, audits 19 + 1 + 1, speed 3)".
- **Decisions asked of the owner.** None.
