# Audit of Verifier B — milestone M5, constant-Q and chroma (WP-517 … WP-524)

| Field | Value |
|---|---|
| Audited | Verifier B's verification of the nine packages: `Docs/Process/reports/WP-<id>-B.md`, `VerifierB/` (probes, scripts, logs), the run outputs it left under `.build/` |
| Auditor | Claude (agent). Took no part in the verification. Read nothing Verifier A wrote (no other `v-…` folder, no `WP-5*-A.md`) |
| Revision | The verifier's checkout: main tree snapshot 2026-11-17 22:50, after CR-027 |
| Simulator | `ztdsp-27-vm5cb` only (`ZTD_DEVICE=ztdsp-27-vm5cb` on every `Scripts/xc.sh` call) |
| Date | 2026-11-18 |
| Result | Of the 15 blocking findings, 14 are **confirmed** and B-12 is **confirmed in part**; all 15 are blocking. I reproduced every one myself: 10 by running them, 5 (the VIS-2 findings) by reading the lines. B-12's third part is a non-returning attach, and nobody has seen how it ends. One gap, in the VIS-2 record (§2); it changes no verdict. Five spot checks of `pass` verdicts, and all five hold (§3) |

The verdicts the verifier returned: WP-517 (T) blocking; WP-518 (R) blocking; WP-519 (R) blocking; WP-520 (R) pass; WP-521 (R) blocking; WP-522a (R) blocking; WP-522b (R) pass; WP-523 (R) blocking; WP-524 (R) blocking.

**The state of the checkout.**
- Before I changed anything, `Sources`, `Tests`, `Scripts` and `Package.swift` were identical to the main tree (`diff -rq`) and to the verifier's `.build/pristine`.
- `Docs` differed from the main tree only by the nine `WP-5xx-B.md`.
- The verifier left nothing behind in the sources. Every probe and mutation it made had been removed.

## 1. Blocking findings (duty 1)

How I ran each reproduction:
- Each probe ran alone, in a test process of its own: one `Scripts/xc.sh test-only "ZTronDSPAnalysisTests/<Suite>/<test>()"` call per test.
- The verifier's probes come from `VerifierB/Probes/VerifierBProbeTests.swift`. My controls are in a probe file of my own, `AuditorBProbeTests.swift` (public API only, Appendix A).
- I used my own runner, not `VerifierB/run-probe.sh`, because that script writes into `VerifierB/logs/` and would have overwritten the verifier's evidence.
- Debug ran on a build I made with both probe files installed. Release ran test-only on the verifier's Release build `.build/xcode-release`, which already holds its probes.
- A trap shows as follows. The probe prints its "start" marker and no outcome. xcodebuild then prints "Restarting after unexpected exit, crash, or test timeout" and exits 65.
  - Double → Int conversions also print a `Fatal error:` line in Debug.
  - Integer overflow prints nothing.
  - The Release result bundles still on disk record "Crash: xctest", or "Exceeded max restart count of 2. (Underlying Error: Crash: xctest)".

| Finding | Packages | Rule as read · change request | Verdict | Severity (§11.6) | Reproduced by me | Evidence (my runs) |
|---|---|---|---|---|---|---|
| B-1 — traps in `frequency(ofBin:)`, `atomLength(ofBin:)` | WP-517 | §9.3 (spec:1684): "No `fatalError` or `precondition` is reachable from public API through invalid input". An overflow trap counts, as `audit-m1-B.md` held. No CR describes it (CR-001 … CR-027) | **confirmed** | **blocking**: a rule of §9 violated | yes, Debug and Release | **Debug traps.**<br>• B1, `frequency(ofBin: .max)`: "Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max" (:119).<br>• B1200, `.max` and `.min`: the process ends with no message after 2 restarts. That is the overflow at :120: `Double(Int.max)/1200` rounds to 7 686 143 364 045 647, and times 1 200 that exceeds Int.max.<br>• B36, `atomLength(ofBin: .min)`: "Fatal error: … either infinite or NaN" (:170).<br>• B36, `atomLength(ofBin: -2_160)`: "… greater than Int.max" (:170).<br>**Release:** the same five crash. The bundle of B1 records "Crash: xctest"; that of B1200 with `.min` records "Exceeded max restart count of 2 (Crash: xctest)".<br>**Controls, which return:**<br>• `frequency(ofBin: -2_160)` = 2.8365500627665723e-17.<br>• `atomLength(ofBin: -1)` = 76 967.<br>• `atomLength(ofBin: .min)` with `gamma` 5 = 9 600.<br>The traps lie where the finding says. The comment of `frequency(ofBin:)` (:115-117) says the formula "holds for any index" |
| B-2 — `frequency(ofBin: .max)` = +∞; the division of :130 | WP-517 | NUM-1 (spec:1005): "No NaN, no infinity. Every division states its result for a zero or sub-floor denominator …". No CR. Change request B of WP-521-B.md exists only as text in that report, not under `changes/` | **confirmed** | **blocking**: NUM-1 | yes, Debug and Release | • B36: `frequency(ofBin: .max)` → `inf`. The test fails `value.isFinite` with 3 issues, in Debug and in Release (Release bundle: "frequency(ofBin: Int.max) = inf").<br>• Line 130, `q * sampleRate / (frequency(ofBin: bin) + gamma / alpha)`, has no stated result for a zero denominator. With `gamma` 0 and a centre that underflows, the denominator is 0; that is the "infinite or NaN" trap of B-1 |
| B-3 — two geometry functions without an allocation statement | WP-517 | VIS-2 (spec:961) and audit demand 1 of the brief: a type's statement counts only "that says it covers the members". No CR | **confirmed** | **blocking**: VIS-2 | yes, by reading | • `ConstantQGeometry.swift:115-118` and `:127-129`: neither comment says whether the function allocates.<br>• The type's statement (:25-26), "An immutable value, usable on any thread; creating one allocates nothing", gives the context for every member but covers allocation on creation only. The scan's pass is overruled by hand, as the README says |
| B-4 — `ConstantQKernel.dense()` | WP-518 | VIS-2. No CR | **confirmed** | **blocking**: VIS-2 | yes, by reading | • `ConstantQKernel.swift:343-345`: the comment says what `dense()` returns and nothing on context or allocation.<br>• The function allocates two arrays of `rowCount · columnCount` floats.<br>• The type's statement covers creation only ("creating it allocates and transforms, and is not for the analysis thread"). Its sibling `applied(toReal:imaginary:)` states its own contract |
| B-5 — `hop: .max` traps in the hop check | WP-519 | §9.3. The row's acceptance (spec:2096): "illegal hops rejected with suggestions". CR-022 item 5 says "the error names the nearest hops that are", and the code throws no error for such a hop, so the CR does not cover it | **confirmed** | **blocking**: §9.3 and the row's acceptance | yes, Debug and Release | **The four entries all end the process, in Debug and in Release:**<br>• `p519_latency_hop_IntMax`<br>• `p519_makeNode_hop_IntMax`<br>• `p521_step_hop_IntMax`<br>• `p524_recipe_hop_IntMax`<br>The Release bundle of the first records "Crash: xctest".<br>**My controls** (7 octaves, so step 64):<br>• `Int.max − 64` and `Int.max − 65` are refused, naming "the nearest are 9223372036854775680 and 9223372036854775744".<br>• `Int.max − 63`, a multiple of 64, is refused as "above the longest supported, 16777216".<br>• `Int.max − 62` traps.<br>• With one octave, `Int.max` is refused (`invalidParameter(hop)`), and Int.min, 0 and −1 are refused.<br>So the trap is `above = below + step` (`ConstantQSchedule.swift:111`) for every hop above `Int.max − 63` that is no multiple of the step |
| B-6 — 13 public symbols of the step and its strategy | WP-521 | VIS-2 and audit demand 1. No CR | **confirmed** | **blocking**: VIS-2 | yes, by reading | • I read the 13 lines: `Steps/ConstantQ.swift:37-41`, `:61`, `:63`, `:65`, `:90`, `:146-147`, and `ConstantQStrategy.swift:70-75`, `:88`, `:121`, `:142-143`.<br>• The omissions are as listed: 8 symbols with no comment, 3 comments without an allocation statement, and 2 comments with neither context nor allocation.<br>• Two of the 13 are protocol witnesses, `latency(of:…)` (:88) and `makeNode(…)` (:121), which could be read as documented by the requirements at :16-26 and :28-47.<br>• On the brief's wording they have no comment of their own, and the verifier counts them that way throughout. Even on the other reading the latency requirement says only that it "should be arithmetic", while the witness designs the half-band filter on its first call (:82-85).<br>• The other 11 symbols stand on any reading |
| B-7 — finite samples give non-finite coefficients | WP-521, WP-522a | NUM-1, "No NaN, no infinity", with audit demand 6 (±greatestFiniteMagnitude at every public entry that takes numbers). No CR. Change request B is not filed. The stability note `sparse-kernel-product.md:38` says "the transform of finite samples is finite" | **confirmed** | **blocking**: NUM-1 | yes, Debug and Release | **The verifier's probe `p521_step_extremeSamples(octaves:)`, Debug and Release:**<br>• ±greatestFiniteMagnitude, constant or alternating: 1 octave gives 121 frames with 1 452 of 1 452 values non-finite; 3 octaves give 99 frames with 3 564 of 3 564.<br>• Subnormal and ±0 samples give zeros.<br>**My controls**, reading the step's own complex output before any `Magnitude`:<br>• Every coefficient is non-finite from constant samples of 1e25 up. They are finite at 1.5e19, 2e19, 5e19, 1e20 and 1e22 (1 octave from 440 Hz, 12 bins, hop 128).<br>• The vDSP plan alone, through the public `FFTBackend` API, gives non-finite bins for finite frames:<br>&nbsp;&nbsp;– 2 048 points, constant greatestFiniteMagnitude: 512 of 2 050.<br>&nbsp;&nbsp;– 2 048 points, half zeros then 1e35: 16, while its largest finite bin is 1.024e38.<br>&nbsp;&nbsp;– 1 920 points, half zeros then 1e30: 128.<br>• The note's claim is therefore false.<br>• I did not find which operation at `ConstantQNodes.swift:390-397` (the transform or the product) overflows first at 1e25 |
| B-8 — `ConstantQProjection.swift` below COV-3 | WP-523 | COV-3 (spec:1727): "the files a package adds or changes are at ≥ 97.5 %". No E-17 case, no `coverage:ignore` on the lines, no CR | **confirmed** | **blocking**: coverage below COV-3 | yes | **My instrumented run** on the verifier's coverage build `.build/xcode-cov` (built before any probe was installed), tag AUD, the eight suites: 82 tests pass.<br>• The gate with `COV_FILES=VerifierB/cov-files.txt`: "Sources/ZTronDSPAnalysis/ConstantQ/ConstantQProjection.swift 96.15 % (50 of 52 lines), needs 97.50 %: FAIL". No other file of the list fails.<br>• The missed lines are 41 and 44: the refusals of fewer than two bins and of a sparsity outside [0, 1).<br>**Statically:**<br>• Every construction in `Tests/` uses 1 025, 2 049 or `frame / 2 + 1` bins and a sparsity of 0 or 0.01.<br>• The step refuses both cases first (`ConstantQScale.swift:112`, `:121`) before it calls the projection (:139).<br>• So the whole target cannot cover them either, which agrees with the verifier's B1 run |
| B-9 — linear axes of extreme bin counts trap in `ConstantQScale.lower` | WP-523 | §9.3. No CR | **confirmed** | **blocking**: §9.3 | yes, Debug and Release | **Both probes end the process, in Debug and in Release:**<br>• `p523_scale_axisBins_IntMax`: `2 * (bins - 1)` at :116.<br>• `p523_scale_axisBins_2pow61plus1`: the length 2⁶² passes `isFastLength`, then `geometry.binCount * bins` at :132 overflows.<br>**Controls:**<br>• 2⁶¹ bins and 2⁶² bins (the largest without overflow at :116) are refused with `unsupportedConfiguration` ("… which is none").<br>• Int.min, 0, −1 bins and bad Nyquist frequencies are refused (`p523_scale_axis_otherExtremes`) |
| B-10 — magnitudes at greatestFiniteMagnitude give non-finite bands | WP-523 | NUM-1. No CR (change request B not filed) | **confirmed** | **blocking**: NUM-1 | yes, Debug and Release | **`p523_scale_extremeSpectra`:**<br>• ±greatestFiniteMagnitude gives 36 of 36 non-finite bands with `.native` and with `.accelerate`, in Debug and in Release.<br>• Subnormal gives a largest band of 1.06e-43; ±0 gives 0.<br>**My flat spectra** (2 049 bins, 1 000 Hz, 3 octaves):<br>• 1e36: all finite, the largest 7.90e37.<br>• 1e37: 15 of 36 non-finite.<br>• 1e38: 36 of 36.<br>That is consistent with overflow where a band's value leaves Float's range: nothing saturates and nothing guards |
| B-11 — 7 public symbols of `ConstantQScale` | WP-523 | VIS-2. No CR | **confirmed** | **blocking**: VIS-2 | yes, by reading | • `Steps/ConstantQScale.swift:31-33`, `:50`, `:52`, `:73`, `:110`, `:147`, `:155-156`, read line by line.<br>• No comment on `activation`, `init`, `stageDescription`, `lower(_:)` or the family's builder overload.<br>• The type's statement gives no allocation statement. The modifier's comment has neither context nor allocation |
| B-12 — traps in `ChromaFold.lower` on extreme constant-Q axes | WP-524 | §9.3. No CR | **confirmed in part**: parts (1) and (2) stand; part (3) is a non-returning attach whose end, and so whether §9.3 applies, is undetermined | **blocking** (parts 1-2) | (1), (2) yes, Debug and Release; (3) reproduced as a non-return only | **(1)** `p524_fold_axisBinsPerOctave_IntMax` ends the process in Debug and in Release.<br>Controls: `Int.max − 11` is refused, naming 9223372036854775788 and 9223372036854775800; `Int.max − 19` and `Int.max − 7` attach; 13 is refused. So the trap is `(binsPerOctave / 12 + 1) * 12` (:164) for values above `Int.max − 7` that are no multiple of 12.<br>**(2)** `p524_fold_axisMinimum`, Debug: "Fatal error: Double value cannot be converted to Int because it is either infinite or NaN" at the least subnormal (:151). In Release the process ends.<br>Controls: 1e-300, 1e-320 and `leastNormalMagnitude` attach and give twelve 1s.<br>**(3)** `p524_fold_axisBinCount_IntMax`, Debug, stopped by hand with SIGINT after 58 s:<br>• no outcome; the runner at about 100 % CPU;<br>• resident memory 0.85 GB at 14 s, 1.65 GB at 29 s and 0.64 GB at 44 s (memory pressure);<br>• the log ends "TEST EXECUTE INTERRUPTED".<br>Line 153 maps `0 ..< Int.max`, which cannot complete. Whether it would end in an allocation trap or exhaust the host is not established, and the finding says so itself. I did not run it in Release, where it would grow memory far faster on a loaded host |
| B-13 — L1/L2 norms overflow; loud frames become zeros | WP-524 | NUM-1, and a wrong result against §6.8 (spec:1245): "The magnitudes of a class are summed, thresholded, and the twelve values normalised …". CR-022 item 8 covers "a frame under the floor is twelve zeros" only | **confirmed** | **blocking**: NUM-1 and a wrong result | yes, Debug and Release | **(a) The public `norm(of:)`**, `p524_norms_extremeValues` (8 issues, Debug and Release), and my control:<br>• `.l2` of 12 × 6e18 = inf, though the exact 2.08e19 fits a Float; 12 × 5e18 = 1.7320508e19.<br>• `.l2` of 12 × 2e19 = inf (exact 6.93e19).<br>• `.l2` of 12 × 1e30 = inf (exact 3.46e30).<br>• `.l1` of 12 × ±greatestFiniteMagnitude = inf (exact 4.08e39, beyond Float).<br>• `.max` and `.none` stay finite.<br>**(b) Through the step** (24 bins, 12 per octave):<br>• `.l2` of 24 × 3e18, 2e19 and 1e30 gives twelve zeros. 24 × 2e18 gives 0.28867513, as 24 × 1 does.<br>• 24 × greatestFiniteMagnitude gives twelve zeros under `.max`, `.l1`, `.l2` and `.none`: the class sums overflow at `ChromaNodes.swift:48`, and the guard at :62 zeros the frame.<br>• `ChromaTests.swift:170-176` asserts those zeros |
| B-14 — no RT-7 layer-2 attributes on the chroma norms | WP-524 | RT-7 layer 2 (spec:708): "`@_noAllocation @_noLocks` on pure-Swift leaf loops, behind the build setting `ZTRONDSP_PERF_ANNOTATIONS`". No CR. The same reading as `audit-m1-B.md` B-14 | **confirmed** | **blocking**: RT-7 | yes | • `grep -c ZTRONDSP_PERF_ANNOTATIONS` gives 0 for `ChromaFold.swift` and for `ChromaNodes.swift`.<br>• L1, L2 and Max `norm(of:)` (:28, :44, :60) are leaf loops on the analysis thread (`ChromaNodes.swift:59`).<br>• The verifier's copy differs from `ChromaFold.swift:9-69` only by a header comment and three attribute blocks (`diff`).<br>**Compiled alone with the fixture command line of `Scripts/check-perf-annotations.sh`:**<br>• setting on: exit 1, one diagnostic, `ChromaNormsAnnotated.swift:54:20` "called function is not available in this module and can have unpredictable performance" (L2's `squareRoot()`);<br>• setting off: exit 0;<br>• my variant, with L2's loop in an annotated `static func` and the root outside: exit 0 with the setting on and off.<br>**The package's fixtures, setting on:** `AllocatingLeaf.swift` exits 1; `CleanLeaf.swift` exits 0. The attributes fit, and the check bites |
| B-15 — 28 public symbols of the fold and the recipe | WP-524 | VIS-2 and audit demand 1. No CR | **confirmed** | **blocking**: VIS-2 | yes, by reading | • `ChromaFold.swift:15-60`, `:114-127`, `:158`, `:184-185` and `ChromaRecipes.swift:21-76`, read line by line. The 28 omissions are as listed.<br>• The four `norm(of:)` witnesses (:20, :28, :44, :60) could be read as covered by the protocol's statement at :7-8 ("`norm(of:)` is called on the analysis thread, once per frame: it must not allocate"). On the brief's wording, and the verifier's reading throughout, they are public functions with no documentation comment.<br>• The other 24 stand on any reading: the four initialisers, the step's and the recipe's members, and the types and modifiers without an allocation statement |

**Notes on the verdicts.**
- **B-12 is the only finding I could not confirm entire.** The first two traps are as the finding says. The third case is a defect that is reproduced: an axis of `Int.max` bins is accepted, and the attach never returns. But it is reproduced only as a hang. §9.3 is about traps, and neither the verifier nor I saw how that case ends.
- **B-7 and B-10:** the input is finite, so NUM-1's replacement at the source adapter does not apply. No filed CR bounds finite input.
- **B-13 (a)** includes values where the exact norm fits a Float and the function still returns +∞. That is a wrong result as well as an infinity.
- **The VIS-2 findings (B-3, B-4, B-6, B-11, B-15)** follow audit demand 1 literally. Section 2 records the one VIS-2 judgement that is missing from the reports.

## 2. Gaps in the verification (duty 2)

All nine reports exist. Each states, for every acceptance check of its row, the tests run, how they were run (Debug once and three times, instrumented, Release three times) and the result.

The lens duties are carried out as follows:
- **Lens T (WP-517).** Four single-line mutations of `ConstantQGeometry.swift` (:121, :109, :130, :170), each with the tests that then failed and their issue counts. COV-3 per file (100 %). Determinism and the absence of sleeps. Negative paths.
- **Lens R (518 … 524).** RT-1 … RT-9 by name, applicable or not. Each allocation audit is run in Debug and Release, and is shown to fail with an injected allocation (injections 11 … 17, logs `mut-<id>.log`). Also: hidden copies, complexity against §7.2 (with a counting backend for row 13), setups at compile time, SEL-3, and the benchmark position of each row. WP-520's benchmark is recorded, and so are STG-1 for each step and SEL-6 for WP-523.
- The three mutation checks the brief carries over from the implementer were made: mutations 5, 6 and 7.
- **Lens N** is not Verifier B's in this batch. The currency and stability-note duties for the ALG rows belong to the other verifier. B nevertheless checked each currency record.

| # | Package | Gap |
|---|---|---|
| G-1 | WP-521, WP-523, WP-524 (VIS-2, audit demand 1) | `Order/OrderDiagnostics+ConstantQ.swift` declares seven `public static func buildPartialBlock` catch-alls marked `@available(*, unavailable, message:)`, with no documentation comment (:15, :22, :25, :30, :33, :36, :41).<br>• The verifier's scan lists all seven (`VerifierB/logs/vis2-scan.txt`), and its decision not to count them is written only in `VerifierB/README.md:161-165`.<br>• No report says how these public symbols were judged under audit demand 1.<br>• The reading is defensible and changes no verdict: an unavailable overload cannot be called, its `message:` is the documentation ORD-4 asks for, and no ORD-4 catch-all elsewhere in the package carries a `///` comment.<br>• But the judgement belongs in the reports of the packages that declare the overloads. As things stand they are silent on that file. |

## 3. Spot checks: five `pass` verdicts, where the evidence was thinnest

The two package-level passes are WP-520 and WP-522b; I checked both of their checks. I also checked WP-519's numeric acceptance check.

| # | Package · check (verifier's result) | What I ran | What I found |
|---|---|---|---|
| 1 | WP-520 · ≡ dense product (pass) | Debug, test-only: `ConstantQKernelTests/theSparseProductIsTheDenseProduct(sparsity:)`. I read the test (`ConstantQKernelTests.swift:288-308`) | 3 cases pass (sparsity 0, 0.01, 0.3). The test compares the sparse product with the dense `vDSP_mmul` product and with the double-precision product, within 10⁻⁵ of the largest coefficient, for three geometries and three seeds. **Holds.** |
| 2 | WP-520 · benchmark recorded (pass) | Release, `.build/xcode-release`, `-parallel-testing-enabled NO`, `TEST_RUNNER_ZTD_BENCHMARK_OUTPUT` pointed at a file of my own: `theProductIsTimedAgainstTheDenseProduct()` | Passes, and the JSON is written: 11 samples of 200 products each. Sparse: least 207.7 ns, median 209.0 ns. Dense: least 5 294 ns, median 5 352 ns. The verifier recorded 263.3 / 263.75 ns and 6.90 / 11.77 µs; the note says 0.24 µs and 6.1 µs. Same order, on a loaded host. **Holds.** |
| 3 | WP-522b · octaves aligned to the sample (pass) | Debug: `ConstantQScheduleTests/everyOctaveOfAFrameIsCentredOnTheSameSample(octaves:hop:)` and `everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples(filterLength:)`. I read the tests (`:150-207`) | 4 and 7 cases pass. The test is sensitive to the defect it is for: it asserts that a one-sample lag would show (`sharpest >= 0.01`). **Holds.** |
| 4 | WP-522b · latency reported (pass) | Debug: `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore(octaves:bins:hop:gamma:)`. I read the test (`:211-244`) | 4 cases pass. They check `latency − 1` → 0 frames and `latency` → 1, the time stamps, and that the strategy, the node and the downstream environment agree. **Holds.** |
| 5 | WP-519 · alias rejection ≥ 80 dB (pass) | Debug: `theHalfBandFilterPassesTheLowerBandAndRejectsWhatWouldFoldOntoItByEightyDecibels()` and `aToneThatWouldAliasLeavesTheDecimatorEightyDecibelsDown()`. I read the tests (`:25-79`) | Both pass. They assert the designed stop band at ≤ −80 dB (:49), and a full-scale tone at 0.6 … 1.0 of the input Nyquist frequency at ≤ −80 dB at the decimator's output (:63). **Holds.** |

The same Debug run also included `ChromaTests/silenceGivesZeros()` (WP-524), which passes. I do not count it as one of the five.

## 4. Observations for the integrator (not gaps)

- **Wording of the Release crash evidence (B-1, B-5).** The verifier writes "Test crashed with signal trap". The Release result bundles I could still read say "Crash: xctest", or "Exceeded max restart count of 2. (Underlying Error: Crash: xctest)". Xcode had already pruned the bundle of `p521_step_hop_IntMax` the verifier cites. Either way the process crashed; no verdict depends on the wording.
- **B-7's threshold.** The step's coefficients turn non-finite from constant samples of 1e25 up in the probed geometry, far below greatestFiniteMagnitude. Any fix that only guards the extremes would be incomplete.
- **B-12 (3), memory figures.** The verifier saw 180 … 630 MB over 6 min 18 s. I saw resident memory reach 1.65 GB within 30 s. Both runs show a non-returning, growing attach.

## 5. Method, disclosures, restoration

**What I ran** (all with `TMPDIR=$ROOT/.build/tmp`):
- a Debug `build-for-testing` with both probe files installed in `Tests/ZTronDSPAnalysisTests/`;
- the Debug reproductions, each test alone;
- the Release reproductions, test-only on `.build/xcode-release`;
- one instrumented test-only run of the eight suites on `.build/xcode-cov`, then the coverage gate;
- the standalone compiles of B-14, with the fixture command line of `Scripts/check-perf-annotations.sh`, output under `.build/`;
- the spot checks above;
- a bounded run of B-12 (3), stopped by a SIGINT to the one xcodebuild whose filter named that test. Its test runner, under this simulator's `launchd_sim` only, ended with it.

**What I did not run:**
- B-12 (3) in Release, or to its end.
- The whole-target instrumented run of B-8. It is not needed, as shown statically.
- The verifier's `VerifierB/run-probe.sh` and `trial.sh`, which write into `VerifierB/logs/`; I ran the same tests and compiles myself.
- I did not read `~/Library/Logs/DiagnosticReports`, which holds other sessions' reports.

**Restoration.**
- The two probe files were removed after the runs.
- Afterwards the checksums of all 1 439 files of `Sources`, `Tests`, `Scripts`, `Docs` (reports aside), `VerifierB` and `Package.swift` were identical to the list I took before the first change.
- `Sources`, `Tests`, `Scripts` and `Package.swift` are again identical to the main tree.
- Nothing in `Docs/Process/reports/` changed except this file.
- `.build/`, with my probe file, logs and coverage data, is deleted after this report as the brief says; this report therefore carries the probes (Appendix A) and their outputs (Appendix B).

## Appendix A — the auditor's probes (public API only)

They live in `Tests/ZTronDSPAnalysisTests/AuditorBProbeTests.swift` while they run, and are removed afterwards. The helpers:
- `AuditFrames<Output>` is a custom `PipelineStage`. It declares a scope (`.spectral(frameSize:hopSize:axis:)`) and emits one frame of given values per block, through `AnalysisStep(name:key:output:scope:)` and a node that copies the values into `output.real`.
- `ComplexFiniteness` follows `ConstantQ` (`Spectrum<ConstantQFrequency, ComplexValues>` → `Spectrum<ConstantQFrequency, MagnitudeValues>`). It writes 1 per coefficient whose real or imaginary part is not finite.
- `outcome { … }` turns a thrown `DSPError` into text.
- `amark` prints the `AUDIT-PROBE` markers.

| Test | Calls |
|---|---|
| `a519_hopsBesideTheOverflow` | `MultirateSparseKernelStrategy().latency(of: ConstantQGeometry(minimumFrequency: 32.70…, octaves: 7, binsPerOctave: 36, sampleRate: 48_000), hop: h, window: .hann, sparsity: 0.01)`, with h = `Int.max − 64`, `− 63`, `− 65` |
| `a519_hop_IntMaxMinus62` | the same with `Int.max − 62` (traps) |
| `a523_axisBinsBesideTheOverflow` | `Pipeline { AuditFrames(64 × 1, .linearFrequency(binCount: 2^61 or 2^62, nyquist: 24_000)); ConstantQScale(fmin: .hertz(1_000), octaves: 3, binsPerOctave: 12) }.run(on: silence(512))` |
| `a524_axisBeside` | `Pipeline { AuditFrames(24 × 1, .constantQ(minimumFrequency: 65.41, binsPerOctave: Int.max − 11 / Int.max − 19 / 13, binCount: 24)); ChromaFold() }`, and the same with `minimumFrequency` 1e-300, 1e-320 and `Double.leastNormalMagnitude` |
| `a524_l2Threshold` | `L2/L1/MaximumChromaNormalization().norm(of:)` on 12 × {1, 5e18, 6e18, 2e19, 1e30, greatestFiniteMagnitude}; `ChromaFold(normalization: .l2/.l1/.max)` after `AuditFrames(24 × v)`, v ∈ {1, 2e18, 3e18, 2e19, 1e30, greatestFiniteMagnitude} |
| `a521_complexOutputFiniteness` | `Pipeline { ConstantQ(fmin: 440 / 2^(octaves−1) Hz, octaves: 1 or 3, binsPerOctave: 12, hop: 128); ComplexFiniteness }` and the same with `Magnitude()`, on 16 384 samples of v (constant or alternating), v ∈ {1, 1e19, 1e30, 1e36, 1e38, ±greatestFiniteMagnitude} |
| `a521_complexThreshold` | the 1-octave pipeline with `ComplexFiniteness`, constant v ∈ {1.5e19, 2e19, 5e19, 1e20, 1e22, 1e25, 1e28, 1e33, 1e35} |
| `a521_planAlone` | `VDSPFFTBackend().makePlan(length: 1_920 or 2_048).forward(…)` on constant frames and on frames whose first half is zero, v ∈ {1e22, 1e23, 1e24, 1e25, 1e30, 1e35, greatestFiniteMagnitude} |
| `a521_a523_scaleOfOverflow` | the 1-octave `ConstantQ` + `Magnitude` on constant v, and `AuditFrames(2 049 × v, .linearFrequency(2_049, 24_000))` + `ConstantQScale(fmin: .hertz(1_000), octaves: 3, binsPerOctave: 12)`, v ∈ {1e30, 1e34, 1e36, 1e37, 1e38, greatestFiniteMagnitude} |

## Appendix B — outputs (Debug unless marked)

```
a519  hop Int.max − 64 → invalidParameter(hop): … multiple of 64 (2^6); the nearest are 9223372036854775680 and 9223372036854775744
a519  hop Int.max − 65 → the same nearest hops
a519  hop Int.max − 63 → invalidParameter(hop): … above the longest supported, 16777216
a519  hop Int.max − 62 → process ends (start marker only; 1 restart; exit 65)
a523  bins 2^61 → unsupportedConfiguration: … 2305843009213693952 bins are those of a transform of 4611686018427387902 points, which is none
a523  bins 2^62 → unsupportedConfiguration: … 4611686018427387904 bins … 9223372036854775806 points, which is none
a524  binsPerOctave Int.max − 11 → invalidParameter(binsPerOctave): … the nearest are 9223372036854775788 and 9223372036854775800
a524  binsPerOctave Int.max − 19 → attached, 1 frame;  binsPerOctave 13 → invalidParameter, nearest 12 and 24
a524  minimumFrequency 1e-300 / 1e-320 / leastNormalMagnitude → attached, twelve 1.0
a524  norms 12 × 5e18: l2 1.7320508e19, l1 5.9999993e19, max 5e18
a524  norms 12 × 6e18: l2 inf (exact 2.078e19), l1 7.1999997e19
a524  norms 12 × 2e19: l2 inf (exact 6.928e19), l1 2.3999997e20
a524  norms 12 × 1e30: l2 inf (exact 3.464e30), l1 1.2e31
a524  norms 12 × 3.4028235e38: l2 inf, l1 inf (exact 4.08e39), max 3.4028235e38
a524  fold l2 of 24 × 1 / 2e18 → 0.28867513 each;  24 × 3e18 / 2e19 / 1e30 / 3.4e38 → twelve 0.0
a524  fold l1 of 24 × 1e30 → 0.083333336 each;  24 × 3.4e38 → twelve 0.0
a524  fold max of 24 × 1e30 → 1.0 each;  24 × 3.4e38 → twelve 0.0
a521  complex output, 1 octave, constant or alternating: 1, 1e19 → 0 of 1452 non-finite; 1e30, 1e36, 1e38, ±3.4e38 → 1452 of 1452
a521  complex output, 3 octaves: 1, 1e19 → 0 of 3564; 1e30 … ±3.4e38 → 3564 of 3564
a521  threshold, constant: 1.5e19, 2e19, 5e19, 1e20, 1e22 → 0 non-finite; 1e25, 1e28, 1e33, 1e35 → 1452 of 1452 (from frame 0)
a521  plan 2048 constant 1e22 … 1e35 → 0 non-finite; constant 3.4e38 → 512 of 2050
a521  plan 2048 half zeros then 1e30 → 0; then 1e35 → 16 (largest finite 1.024e38; bin 1 nan, inf); then 3.4e38 → 1280
a521  plan 1920 constant 1e22 … 1e35 → 0; constant 3.4e38 → 640 of 1922
a521  plan 1920 half zeros then 1e25 → 0; then 1e30 → 128 (largest finite 9.6e32); then 1e35 → 128; then 3.4e38 → 1920
a523  flat spectrum 1e30 / 1e34 / 1e36 → 0 of 36 non-finite (largest 7.90e31 / 7.90e35 / 7.90e37); 1e37 → 15 of 36; 1e38, 3.4e38 → 36 of 36
B-12(3) p524_fold_axisBinCount_IntMax: no outcome in 58 s; RSS 853 424 KB (14 s), 1 650 432 KB (29 s), 642 288 KB (44 s); SIGINT → "** TEST EXECUTE INTERRUPTED **"
Release (verifier's probes, each alone): p517 B1 Int.max, B1200 Int.max, B1200 Int.min, atomLength Int.min, atomLength −2160 → crash;
  p517 B36 Int.max → inf (3 issues); p519 latency/makeNode, p521 step, p524 recipe hop Int.max → crash;
  p521 extreme samples → 1452/1452 and 3564/3564 at ±gFM (10 issues); p523 axis Int.max, 2^61+1 → crash;
  p523 extreme spectra → 36/36 at ±gFM (6 issues); p524 binsPerOctave Int.max, minimum subnormal → crash;
  p524 norms → 8 issues (l2 inf at 2e19, 1e30, ±gFM; l1 inf at ±gFM); p524 fold extreme magnitudes → passes, zeros recorded as in Debug
Coverage AUD (eight suites, 82 tests pass): ConstantQProjection.swift 96.15 % (50 of 52), missed 41, 44;
  ConstantQScale.swift 98.75 % (79 of 80); ConstantQNodes.swift 97.92 % (235 of 240)
```
