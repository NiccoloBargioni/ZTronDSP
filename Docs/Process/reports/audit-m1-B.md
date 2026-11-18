# Audit of Verifier B — milestone M1 (WP-101 … WP-121)

| Field | Value |
|---|---|
| Audited | Verifier B's verification of M1, core values and toolkit: 22 packages, 15 blocking findings (B-1 … B-14, B-30) |
| Auditor | An independent agent that took no part in the verification. It fixed nothing in the package |
| Checkout | The verifier's checkout `wt/v-m1-b/ZTronDSP`. The verifier gives it as the main tree snapshot of 2026-11-16 04:05, after CR-022 |
| Runs | Simulator `ztdsp-27-vm1b` (C7333B82-4E50-4E90-B981-044F93C76E68), iOS 27.0, Xcode 27.0, Swift 6.4. Every `Scripts/xc.sh` call used `ZTD_DEVICE=ztdsp-27-vm1b`; gate scripts used `TMPDIR=$PWD/.build/tmp` |
| Result | 14 findings confirmed, 1 confirmed in part (B-5). All 15 are blocking by §11.6. One gap in the verification (WP-101). Five spot checks: four agree with the report; the fifth (WP-101) produced the gap |

Nothing written by Verifier A was read. That means nothing under another `v-…` folder and no `WP-1xx-A.md` report. Timings are not used as evidence anywhere in this audit.

## 1. Method

- **Pristine tree.**
  - Before changing anything, I took a SHA-256 list of 992 files: `Sources` 275, `Tests` 577, `Scripts` 46, `Docs` 93 (without `Docs/Process/reports/`) and `Package.swift`.
  - At the end, after removing my probe file, I took the same list again. It is identical: no file changed, added or removed.
- **Comparison with the main tree** (`/Users/admin/Documents/ZTronDSP`, read only).
  - Of the 21 files the findings cite, 17 are byte-identical to the main tree.
  - Four differ, but only by later work in the main tree, after the snapshot:
    - `Compiler/KernelSpec.swift` (2026-11-16 04:18): `isIdentityByValue` and `commandPayload()` were added;
    - `Compiler/LoweringContext.swift` (04:19): an overflow-checked frame count at :116-117;
    - `Tests/ZTronDSPCoreTests/StorageAndDomainTests.swift` (04:39): the `.disabled(if: AllocationAudit.isUnderThreadSanitizer, …)` trait on `storageIsFreedWithTheBuffer`;
    - `Scripts/ci/benchmark-filters.txt` (2026-11-17 19:16): two analysis suites were added. The main tree's copy still has no line naming Vector or Toolkit.
  - None of these touches a line the findings cite.
  - The verifier touched 21 package source files while it mutated and restored them (modification times 2026-11-17 21:19–22:37). Every one of them is byte-identical to the main tree. The verifier left no mutation behind.
  - What the verifier did leave is its three test files, `Tests/ZTronDSPCoreTests/VerifierBProbes.swift`, `VerifierBDumps.swift` and `VerifierBDisassemblyProbes.swift`.
    - They are not in the main tree.
    - They are byte for byte the files of `VerifierB/tests/`, as `VerifierB/README.md:12-13` states.
    - Its reproductions need them ("as left"). They add tests and change no package file.
    - They were already in the list taken before, and I left them in place.
- **Change requests.** I searched CR-001 … CR-022 for the subject of each finding.
  - Some CRs match a keyword, but each match is about a different matter: CR-002, 004, 010, 014, 015, 016, 018, 019, 020.
  - None of them describes a deviation of these findings or of the WP-101 gap.
- **Probes.** I added `Tests/ZTronDSPCoreTests/AuditBProbes.swift` for the runs and removed it at the end.
  - It uses a plain `import ZTronDSPCore`, so nothing internal is reachable from it.
  - Each crash probe ran in a test process of its own and left a marker file. A marker that stays at "started" means the process stopped.
  - The calls and their outputs are listed in §6.
- **Mutations.** My script applied the verifier's mutations 105c, 108b, 110a5 and 110a6 together. Each is an exact replacement that occurs once.
  - Then the three files were restored from copies taken before.
  - They were compared byte for byte with those copies and with the main tree: `PRISTINE`.
- **Configurations.**
  - Debug: build-for-testing (exit 0); probes and the verifier's reproductions; crash probes; the mutated build and run; fixtures on the pristine and on the mutated tree; spot-check suites.
  - Release (`ZTD_CONFIG=Release`): build-for-testing (exit 0); probes, the verifier's reproductions and crash probes.

## 2. Duty 1 — the blocking findings

| ID | Package | Rule as read · CR | Verdict | Severity | Evidence (what I ran and read) |
|---|---|---|---|---|---|
| B-1 | WP-103 | §9.3 (spec:1684) says what the finding claims. No CR. | confirmed | blocking | **Code:** RollOff.swift:87-88 builds the reason from `\(self)`; :121 describes it as `"order \(Int(value))"`.<br>**Crash probes:** `try RollOff.order(.max).order()` and `RollOff.order(.max).description` each left the marker at "started", exit 65, "Restarting after unexpected exit, crash, or test timeout", in Debug and in Release. The Debug log reads: "Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max".<br>**Control:** `RollOff.order(9223372036854774784)` (the Double just below 2⁶³) describes itself, and `order()` throws "Invalid parameter rollOff: order 9223372036854774784 asks for an order above 4 096". The documented typed error is never raised for `.max`. |
| B-2 | WP-105 | Lens T (spec:1799). §11.6: "an acceptance check … does not exercise the code". The row's "storage freed" (spec:1905). No CR. | confirmed | blocking | **Mutation:** 105c (`deinit { free(base) }` → `deinit { }`, AlignedBuffer.swift:61-63). With it (applied together with the other three mutations), in Debug, the 25 M1 suites and my probe pass: "143 tests in 26 suites passed", `storageIsFreedWithTheBuffer` among them.<br>**Probe:** a buffer of 1 000 000 `Double` is released under `countAllocations`. Pristine: "deallocations 2" (Debug and Release). Mutated: "deallocations 1". So `counts.deallocations >= 1` (StorageAndDomainTests.swift:89) holds even though the 8 000 000 bytes are never freed.<br>**Main tree:** its copy of the test changed only by a trait; the assertion is the same. |
| B-3 | WP-107 | §9.3. No CR. | confirmed | blocking | **Code:** Complex.swift:113 computes `pow(z, -exponent)`.<br>**Crash probe:** `Complex.pow(Complex(1, 1), Int.min)` left the marker at "started", exit 65, in Debug and in Release.<br>**Control:** `Complex.pow(1 + 0j, Int.min + 1)` = 1.0 + 0.0j. |
| B-4 | WP-108 | The row says "setting a derived key does not compile (fixture)" (spec:1908); ENV-3 (spec:630). No CR. | confirmed | blocking | **Tree:** no file under `Tests/CompileFixtures` calls `setting(` or names `SettableKeys` or `SampleRateKey` (0 files, here and in the main tree). The only fixture that sets a key is `valid/DesignStagesOnSampledSequences.swift:70`, `.environment(\.biquadPrecision, .double)`, and that key is settable.<br>**Mutation:** 108b (`SampleRateKey: BuiltInDSPEnvironmentKey, SettableDSPEnvironmentKey`, DSPEnvironment.swift:242). With it (applied together with the other three), the M1 suites pass (143 in 26). The tree's fixtures give "6 valid fixtures compile, 93 invalid fixtures fail with their sentences", exit 0. The verifier's fixtures give "FAIL VerifierB/fixtures/invalid/SettingADerivedKey.swift: it is filed as invalid and compiles", exit 1.<br>**Pristine:** the verifier's fixtures give "2 valid fixtures compile, 7 invalid fixtures fail with their sentences". The acceptance check is missing from the tree. |
| B-5 | WP-109 | NUM-1 (spec:1005) says what the finding claims. No CR. | confirmed in part | blocking | **Probe:** a stage of my own (public API only) emits `AnalysisStep(… scope: .spectral(frameSize:hopSize:axis:))` or `.featureSequence(rate:)`. It runs through `Pipeline.run(on:format:)` at 48 kHz, and the next stage reads its `context.environment`. In Debug and in Release:<br>• frame 0 / hop 0 → `featureRate inf`, `frequencyResolution inf`;<br>• frame 2048 / hop 0 → `featureRate inf`;<br>• frame 0 / hop 512 → `frequencyResolution inf`;<br>• rate ∞ → `sampleRate inf`, `nyquist inf`;<br>• rate NaN → `sampleRate nan`, `nyquist nan`.<br>The verifier's three probes record 1, 4 and 2 issues in both configurations.<br>**Stands:** DSPEnvironment.swift:92 and :94 state no result for a zero frame or hop, and :205-212 store any rate. Public API reaches both.<br>**Does not stand as stated:** see §2.1. |
| B-6 | WP-113 | The row: "from another module no call is made per element (checked in the benchmark's disassembly)" (spec:1914); PERF-1 (spec:1387). No CR. CR-010 is about the fused cascade. | confirmed | blocking | **The finding's greps:**<br>• `Scripts/ci/benchmark-filters.txt` has 0 lines naming Vector or Toolkit;<br>• 0 `Benchmark.record`/`measure` calls on `Vector.` outside the verifier's files;<br>• the only `otool\|objdump\|disassembl` match is SimulatorTests.swift:15, the word "AudioToolbox".<br>The acceptance check is missing.<br>**Not re-run:** `VerifierB/scripts/disassemble.py`. The verifier's statement that the property itself holds rests on the verifier alone. |
| B-7 | WP-113 | The row: "The implementations agree bit for bit" (spec:1914); SEL-6 (spec:1447). No CR. | confirmed | blocking | **Probe:** `Vector.Native.clip` against `Vector.Accelerated.clip`, n = 1 and n = 64, Debug and Release. 5 of the 8 cases differ in the bits of every element (native / vDSP):<br>• (−0.0; 0, 1): −0.0 / 0.0<br>• (0.0; −1, −0.0): 0.0 / −0.0<br>• (−0.0; 0, ∞): −0.0 / 0.0<br>• (−5; 1, −1): 1.0 / −1.0<br>• (−1; 1, −1): 1.0 / −1.0<br>The documented `min(max(x, low), high)` (Vector.swift:60), evaluated with Swift's `min` and `max`, gives vDSP's value in four of these five cases. In (0.0; −1, −0.0) it gives the native value.<br>**Automatic form:** `Vector.clip` of −0.0 into [0, 1] gives −0.0 for 511 elements and +0.0 for 512, so the result depends on the length.<br>**Verifier's probe:** records 1 issue in both configurations. |
| B-8 | WP-115 | SEL-2 (spec:1443); the row's "a forced choice is honoured" (spec:1916). The median has no Accelerate implementation (§7.4, spec:1439). No CR. CR-015 and CR-016 name the median for other matters. | confirmed | blocking | **Probe:** `CrossoverTable.shipped`, Debug and Release.<br>• At 16 777 216 elements and at 2³⁰, the median is `metal` under automatic and `native` under a forced `.accelerate`.<br>• At 4 and at 16 777 215 it is `native` both ways.<br>• A forced `.metal` on the element-wise primitive stays automatic (`accelerate`).<br>**Code:** Implementation.swift:137 contradicts its own documentation (:5-6, :108-109: "ignored otherwise"). The tree's test asserts the departure (ToolkitTests.swift:262-264).<br>**Verifier's probe:** records 2 issues. |
| B-9 | WP-117 | §11.6 "a result is wrong". RateChange.swift:2 and :6 wrap the phase; :33-37 say "the pointer form of"; :44 clamps it. No CR. CR-004 is about kernels. | confirmed | blocking | **Probe:** samples 0…9, factors 2, 3 and 4, phases −5, −1, 0, 1, f−1, f, f+1, 9 and 12, Debug and Release. 16 of the 27 calls give different samples. For example:<br>• factor 2, phase −1: the array form keeps 1,3,5,7,9 and the pointer form 0,2,4,6,8;<br>• factor 3, phase 4: 1,4,7 against 2,5,8.<br>**Verifier's probe:** records 1 issue. |
| B-10 | WP-117 | §9.3, and the memory safety of a function documented as callable on the analysis thread. No CR. | confirmed | blocking | **Array form:** `subsampled(0…9, by: .max, phase: 1)` left the marker at "started", exit 65, in Debug and in Release. The control with phase 0 gives [0.0].<br>**Pointer form:** `subsample(source + 1, count: 10, by: .max, phase: 5, into:)`, with a sentinel 99 placed just before the source, gives "written 7: [5.0, 4.0, 3.0, 2.0, 1.0, 0.0, 99.0], nextPhase 9223372036854775796". It read `source[-1]`. It wrote 7 samples where the documented room `(count + factor − 1) / factor` (:37) is 1, and that formula itself overflows at this factor.<br>**Verifier's probe:** records 1 issue. |
| B-11 | WP-118 | §9.3. HistoryBuffer.swift:19-20 promise `resourceAllocationFailed`. No CR. | confirmed | blocking | **Code:** HistoryBuffer.swift:24 computes `2 * count`.<br>**Crash probe:** `HistoryBuffer(count: .max)` left the marker at "started", exit 65, in Debug and in Release.<br>**Control:** `HistoryBuffer(count: Int.max / 2)` throws "Could not allocate a buffer of 9223372036854775806 elements". |
| B-12 | WP-120 | MAT-2 (spec:1358), MAT-3 (spec:1359). No CR. CR-007 only records that Octave is absent from this host. | confirmed | blocking | **Probe:** `MATLABScript().vector("z", real: [1, 1, 1, .nan, .infinity, -2], imaginary: [.nan, .infinity, -.infinity, 1, -1, -0.5])` emits `z = [1+NaNi 1+Infi 1-Infi NaN+1i Inf-1i -2-0.5i];` in Debug and in Release. The cause is MATLABScript.swift:120-123.<br>**Verifier's probe:** records 1 issue in both configurations.<br>**Grammar:** in both grammars `NaNi` and `Infi` are identifiers, not imaginary literals, so the script stops there.<br>**Not run:** MATLAB and Octave (not installed; nothing was installed). |
| B-13 | WP-120 | §9.3; MAT-4 (spec:1360). No CR. | confirmed | blocking | **Code:** the guard at MATLABScript.swift:142 computes `rows * columns`.<br>**Crash probe:** `matrix("m", values: [], rows: .max, columns: 2)` left the marker at "started", exit 65, in Debug and in Release.<br>**Control:** with columns 1 it throws "Invalid parameter m: 0 values do not fill 9223372036854775807 × 1". The substance is §9.3: the trap comes before any typed error, `exportTooLarge` included. |
| B-14 | WP-117, WP-119 | RT-7 layer 2 (spec:706-708) says what the finding claims. No CR. CR-002 adds RT-10 (`while` loops), not the attributes. | confirmed | blocking | **Grep:** `grep -c ZTRONDSP_PERF_ANNOTATIONS` gives RateChange.swift 0, Ramp.swift 0, Vector.swift 15.<br>**Standalone compile:** I put copies of the two files in `.build`, with `@_noAllocation @_noLocks` behind the setting on the five functions the finding names; the sources were not touched. Compiled alone with `swiftc -frontend -c -O` for `arm64-apple-ios15.0-simulator`, both files exit 0 with `-D ZTRONDSP_PERF_ANNOTATIONS` and exit 0 without it.<br>**Controls show the check bites:**<br>• the tree's `AllocatingLeaf.swift` fails ("performs reference counting operations which can cause locking");<br>• `CleanLeaf.swift` passes;<br>• a copy of RateChange with an array allocated inside `subsample` fails.<br>**Not run:** the whole-package build of `Scripts/check-perf-annotations.sh` with the annotated sources. |
| B-30 | WP-110a | The row: "conformances equal the tables of §5.2" (spec:1910). The sinks table lets only `Scalar` and `Novelty` into `Binding<Float>` (spec:545); O-11 (spec:749). No CR. | confirmed | blocking | **Test:** StorageAndDomainTests.swift:250 holds only Samples and Chroma to "not scalar-valued", and :257 holds only `.chroma` at run time.<br>**Mutations:** 110a5 + 110a6 (SignalDomain.swift:82 and :142). With them (applied together with 105c and 108b), the M1 suites pass (143 in 26) and the tree's fixtures exit 0 (6 valid, 93 invalid). The verifier's fixtures report "FAIL VerifierB/fixtures/invalid/EnvelopeIntoAFloatBinding.swift: it is filed as invalid and compiles", exit 1.<br>**Pristine:** the verifier's 9 fixtures behave. |

### 2.1 Notes on the verdicts

- **B-5, the part that does not stand as stated.**
  - `changingRate(interpolation:decimation:)` (DSPEnvironment.swift:170-174) is `package`. Every public path into it clamps both factors to at least 1: KernelSpec.swift:112-113 for a custom kernel, and :204-205 for the decimator, subsample, interpolator and zero-stuff specs. So the zero decimation (:172) that gives ∞ or NaN is not reachable from public API.
  - `DSPEnvironment(sampleRate: .nan)` (the public init, :44) is a NaN Nyquist only as a value. A run with such a format is refused at OfflineRunner.swift:21 (`guard format.isValid`).
  - "The plan compiler raises nothing" was seen only up to the next stage's lowering, because my probe stage throws there to report the environment.
  - The rest stands: through public API alone, a zero frame or hop and a non-finite feature-sequence rate put ∞ and NaN into the environment that the next stage reads. That violates NUM-1, a numbered rule of §6.
- **B-6, B-12 and B-14** each rest on one part I did not run: the verifier's disassembly, MATLAB/Octave, and the whole-package annotation build. In each case the blocking substance was run and seen:
  - B-6: the check is absent from the tree.
  - B-12: the text emitted.
  - B-14: the attributes are absent, and they compile on these functions.
- **Overflow traps.** For B-3, B-10, B-11 and B-13 the process stops on an arithmetic overflow trap. That stops the process the same way a `precondition` does, which is what §9.3 rules out. For B-1 the stop is the precondition of `Int(_: Double)`.

## 3. Duty 2 — gaps in the verification

I read the §12 row and the report `WP-<id>-B.md` of each of the 22 packages. I did not verify the packages again.

| Package | Gap |
|---|---|
| WP-101 | The `pass` for "Linear units round-trip to 1 ulp" has no evidence behind it for `.radiansPerSample`. The report names `FrequencyTests.linearUnitsRoundTripToOneUlp` ("Pass in every run"), but that test holds the radians round trip to `<= 2 * ulp(hertz)` (UnitsTests.swift:23), and the report does not say so. The row (spec:1901) sets the linear units against the logarithmic ones, MIDI and mel. Of the units of §6.1 (spec:1000) that leaves hertz, normalized, fraction of Nyquist and radians per sample, which is also how the code groups them (Frequency.swift:139-142). The row holds the linear units to 1 ulp. I ran the check as the row states it (see Spot checks): 12 of the test's own 1 000 inputs (seed 101) come back at 2 ulp, and 898 of 100 000 more (seed 7). Hertz → normalized and hertz → fraction of Nyquist are exact (0 ulp). Run as stated, the acceptance check fails for one linear unit. As a finding, that would be blocking under §11.6 (an acceptance check failing). No CR changes the tolerance. |

Nothing else is missing:

- **Reports.** All 22 report files exist. Each has an acceptance table that covers every check of its row and says how each check was run and with what result.
- **Lens T** (WP-105, 106, 107, 108, 110a). Each report names the lines changed and the test that then failed or did not. Each gives the coverage of the package's files, for example AlignedBuffer.swift 98.18 % (54 of 55 lines), Complex.swift 100 %, DSPEnvironment.swift 100 % with the target's tests (88.89 % with the M1 suites alone, B-21).
- **Lens N.** No M1 row is tagged ALG, so no currency record or stability note is due. The lens N reports (WP-109, 111, 118, 120) state edge cases and tolerances.
- **Lens R** (WP-104, 110b, 112, 113, 114, 115, 116, 117, 119). Each report states the RT rules, SEL-3 and its benchmark position.
- **Lens A** (WP-101, 102, 103, 121). Each report states names and shapes against the digest, immutability, concurrency, platform and VIS-2.

Remarks that are not gaps:

- **WP-112.** "Results are `Sendable` values" rests on the verifier's own fixtures, as the report says. The tree holds no such fixture. The generic constraint `run<Result: Sendable>` enforces it.
- **WP-110b.** The lifetime rule is "tested as far as a run can show it", which the report argues.
- **WP-121.** The report does not discuss typed errors. `ParameterVector.swift` has no `throw`, no precondition and no subscript, so nothing applies.

## 4. Spot checks

I chose the five `pass` verdicts whose evidence looks thinnest, resting mostly on the tree's own suites: WP-101, WP-102, WP-110b, WP-112, WP-121.

- **The suites.** In Debug, on the pristine tree, `FrequencyTests`, `MelFormulaTests`, `AmplificationTests`, `FrameTests`, `BackgroundWorkTests` and `ParameterVectorTests` ran: "Test run with 39 tests in 6 suites passed", exit 0. `FrequencyTests` passed again in Release.
- **WP-101.** I added a probe that counts round-trip errors in ulps on the test's own inputs, plus 100 000 more, run in Release. The result is the gap in §3: radians per sample at 2 ulp, the other linear units exact. The logarithmic units (10⁻¹⁴ relative) and the typed errors pass.
- **WP-102.** The tables (UnitsTests.swift:188-213) include 0, negative amplitudes and powers, and the floor, with a reference that is not positive and NaN. The suite passes. This agrees with the report.
- **WP-110b.** `FrameTests` passes. The lifetime rule is documented at Frames.swift:22, :40, :60 and :108. This agrees with the report.
- **WP-112.** `BackgroundWorkTests` passes. The verifier's fixtures, against the Debug build, give "2 valid fixtures compile, 7 invalid fixtures fail with their sentences", `BackgroundResultThatIsNotSendable.swift` among the invalid ones. This agrees with the report.
- **WP-121.** `ParameterVectorTests` passes: the vector-space identities and the unequal-length replacement. This agrees with the report.

## 5. Not run, disclosures, restoration

- **Not run:**
  - MATLAB and GNU Octave (B-12);
  - `VerifierB/scripts/disassemble.py` (B-6);
  - `Scripts/check-perf-annotations.sh` on annotated sources (B-14);
  - the verifier's own `crash-probes.sh` and `mutate.py` (I ran my own probes and mutation script with the same calls and the same replacements);
  - no coverage run.
- **Disclosure.** At the start I wrote the task text to the session scratchpad, outside this checkout, against the rule to write only inside it. I moved it into the checkout's `.build/auditb/` at once. Apart from that, I wrote nothing outside the checkout before the rsync the task names.
- **Restoration.**
  - The three mutated files were restored and compared byte for byte (`PRISTINE`).
  - `AuditBProbes.swift` was removed.
  - The 992-file checksum list matches the one taken before.
  - The working logs and probe outputs were under `.build/`, which is removed at the end of the audit, as the task says. The outputs that matter are quoted in §6.
- **Stale paths.** The verifier's own outputs, which its findings cite under `.build/vb2/` and `.build/vb-out/`, went with `.build` as well. Its scripts and fixtures remain under `VerifierB/`.

## 6. Probe calls and outputs

The probes used a plain `import ZTronDSPCore` (and `ZTronDSPTesting`).

| Probe | Call | Output (identical in Debug and Release unless stated) |
|---|---|---|
| b5 | A public `PipelineStage` emitting `AnalysisStep(name:key:output:scope:)` with `.spectral(frameSize:hopSize:axis: .linearFrequency(binCount: 3, nyquist: 24_000))` or `.featureSequence(rate:)`, then a stage that throws its `context.environment`; `Pipeline { … }.run(on: 2 048 zeros, format: 48 kHz mono)` | 2048/512: featureRate 93.75, frequencyResolution 23.4375 · 0/0: inf, inf · 2048/0: featureRate inf · 0/512: frequencyResolution inf · rate 93.75: sampleRate 93.75 · rate inf: sampleRate inf, nyquist inf · rate nan: sampleRate nan, nyquist nan |
| b7 | `Vector.Native.clip` / `Vector.Accelerated.clip`, n = 1, 64; automatic `Vector.clip` at 511 and 512 | 10 case-lengths disagree (5 cases × 2 lengths); automatic: 511 → −0.0, 512 → 0.0 |
| b8 | `CrossoverTable.shipped.implementation(for: .median, size:, requested: .accelerate)` | 16777216 and 1073741824: automatic metal, forced .accelerate native |
| b9 | `subsampled(_:by:phase:)` against `subsample(_:count:by:phase:into:)` | "16 of 27 calls disagree" |
| b10 | `subsample(padded + 1, count: 10, by: .max, phase: 5, into:)` | "written 7: [5.0, 4.0, 3.0, 2.0, 1.0, 0.0, 99.0], nextPhase 9223372036854775796" |
| b12 | `MATLABScript().vector("z", real:imaginary:)` with non-finite parts | `z = [1+NaNi 1+Infi 1-Infi NaN+1i Inf-1i -2-0.5i];` |
| b2 | `countAllocations { buffer = nil }` for `AlignedBuffer<Double>(count: 1_000_000)` | pristine Debug: deallocations 2, allocations 0 · Release: deallocations 2, allocations 0 · with 105c (Debug): deallocations 1, allocations 2 |
| spot101 | Hertz → unit → hertz for normalized, fractionOfNyquist, radiansPerSample at 8, 44.1, 48, 96, 192 kHz (Release) | Seed 101, 1 000 values: radians 12 above 1 ulp, worst 2.0, e.g. 1857.4804670501026 Hz at 44.1 kHz → 0.26464612197148024 rad → 1857.480467050102 Hz · Seed 7, 100 000 values: 898 above 1 ulp, worst 2.0 · Normalized and fraction of Nyquist: 0 above 1 ulp, worst 0.0 |
| controls | The neighbours of each crash | Listed with B-1, B-3, B-10, B-11 and B-13 above; none stopped the process |
| crash probes | `RollOff.order(.max).order()`, `RollOff.order(.max).description`, `Complex.pow(Complex(1, 1), Int.min)`, `subsampled(…, by: .max, phase: 1)`, `HistoryBuffer(count: .max)`, `matrix("m", values: [], rows: .max, columns: 2)`, each alone in a test process | Every marker stayed at "started", exit 65, in Debug and in Release |
