# Audit of Verifier A, M5c (WP-517 … WP-524), lens N

| Field | Value |
|---|---|
| Audited | Verifier A's nine reports `WP-517-A.md` … `WP-524-A.md` (counting 522a and 522b apart), its 18 blocking findings A-1 … A-18, its evidence under `VerifierA/` and its logs under `.build/logs/` |
| Auditor | An independent auditor (agent). Not Verifier A, not Verifier B, not the implementer, not the integrator. Nothing that Verifier B wrote was read. |
| Revision | The tree that Verifier A reviewed: the main snapshot of 2026-11-17 22:50, after CR-027 (the v-m5c-a checkout, ROOT) |
| Simulator | `ztdsp-27-vm5ca` (iOS 27.0), on every `Scripts/xc.sh` call; Debug, and Release for the benchmark |
| Date | 2026-11-18 |
| Read | Brief `37-verifier-a-m5c.md`, with its seven points from the audits of the first wave (the same text as `lessons-wave-1.md`; "lesson 1" and "lesson 6" below are its points 1 and 6); `ZTronDSP-SPEC.md` (§5.8 O-17, §5.11 VIS-2, §6.1 NUM-1, §6.8, §9.3, §11, the M5 rows of §12); `Docs/Process/changes/` (CR-001 … CR-027; CR-022 in full); the nine reports; `VerifierA/` |

## Outcome

- **All 18 blocking findings stand.** I ran the verifier's 18 reproduction tests myself, each in a process of its own, on a pristine tree, and for the seven VIS-2 findings its doc scan, reading every cited line. All 18 are confirmed and all 18 are blocking under §11.6.
  - A-5 is wider than reported. At the default 7 octaves, a hop just above 2²⁴ is refused with a suggestion that is itself refused.
  - A-6 is confirmed. Its reproduction does not isolate it: `Magnitude` (vDSP_zvabs, WP-534) also turns finite values into NaN from about 2·10¹⁹. See A-6.
- **The verdicts stand.**
  - Blocking: WP-517, 518, 519, 521, 522a, 522b, 523, 524.
  - Pass: WP-520.
- **Gaps in the verification (section 2), five:**
  - The evidence that eight packages cite under `.build/logs/` and `.build/bench.json` is kept nowhere durable, and the cleanup of this audit deletes it. The "flakiness record" that every report cites is in no report.
  - WP-517 and WP-522b do not address the tolerance duty.
  - WP-521/522a: the reproduction of A-6 is not specific to A-6, and one figure in it is two orders of magnitude off.
  - WP-519: the hop probes missed the case that widens A-5.
- **Spot checks (section 3):** I spot-checked five pass verdicts, the thinnest by evidence: WP-520 (both acceptance checks), WP-521, WP-522b and WP-524. All five hold.

## 1 The blocking findings (duty 1)

**Pristine sources.** Every reproduction ran on a pristine tree:

- `Sources/`, `Scripts/` and `Package.swift` in ROOT are identical to the main tree (`diff -rq`, `cmp`). `Tests/` is identical as well, once the probe files were removed.
- The verifier's start-of-work manifest (`.build/logs/pristine.sha256`, 1 195 files: Sources, Tests, Scripts, Package.swift and Docs without the reports) matches with 0 mismatches. `VerifierA/scripts/tree-check.sh` prints "TREE: pristine".
- `Docs/` differs from main only in files that main changed after the snapshot. The ROOT copies are dated 11-15 (the ledger 11-17 22:49), the main copies 11-18 00:45 … 00:56. These files are:
  - nine IIR notes under `Docs/Numerics/`: `bessel-prototype`, `bessel-roots`, `butterworth-prototype`, `chebyshev1-prototype`, `chebyshev2-prototype`, `elliptic-functions`, `elliptic-prototype`, `iir-design-analog`, `section-pairing`;
  - `currency-2026-11.md`, whose difference is a supplement of 2026-11-18 for rows 3 and 4, not row 13;
  - CR-018, CR-020 and `ledger.md`;
  - CR-028 … CR-030, which exist only in main.

  None of them bears on M5c. Under `Docs/Process/reports/` the only differences are the nine new `WP-5xx-A.md` reports and this audit. **The verifier left no difference behind.**

**Change requests.**

- CR-022 (Proposed) is the only CR on these packages. Each finding below says what CR-022 covers and what it does not. Its item 2 (latency), item 5 (hop suggestions) and item 8 (the floor) are the relevant ones.
- CR-026 names `ChromagramView` (a view), not these steps.
- No CR describes integer overflow, saturation, non-finite results of finite input, or VIS-2 for witnesses.
- CR-A1, CR-A2 and CR-A3 are proposals inside the verifier's reports. They are not under `Docs/Process/changes/`, so they cover nothing yet.

**How the reproductions ran.**

- Command: `bash VerifierA/scripts/probes.sh in`, a Debug build, then `ZTD_DEVICE=ztdsp-27-vm5ca Scripts/xc.sh test-only "ZTronDSPAnalysisTests/VA_Repro/<test>()"`, one process per test, through my runner `run-tests.sh` (kept in `VerifierA/audit/`).
- Each crash was read from the result bundle (`xcresulttool get test-results tests`), as "Crash: xctest".
- My own controls (suite `AUD_Controls`, `VerifierA/audit/AuditAProbes.swift`, plain imports) ran the same way.
- The logs are kept in `VerifierA/audit/logs/`: one summary line per test in `batch-r1.txt` … `batch-r4.txt`, and per test its output, its full log and what the result bundle recorded. Every line my probes printed is collected in `VerifierA/audit/printed.txt`.

| Finding | Packages | Rule | Verdict | Severity (§11.6) | Reproduced | Evidence (my runs; details below the table) |
|---|---|---|---|---|---|---|
| A-1 | 517 | §9.3; NUM-1. The doc of `frequency(ofBin:)` says "The formula holds for any index" | confirmed | blocking | yes | `r517_frequencyOfBinIntMaxTraps` (B = 64): Crash: xctest.<br>`r517_atomLengthOfBinMinus1800Traps`: "Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max".<br>`r517_frequencyOfAnAdmittedBinIsFinite`: fails, "frequency(ofBin: 36900) = inf".<br>Controls: for B = 36, `frequency(ofBin: Int.max)` = inf with no trap, and 36 863 → inf; `atomLength(ofBin: −1 700)` = 5 694 499 394 691 857 408 |
| A-2 | 517 | VIS-2 (§5.11); brief, lesson 1 | confirmed | blocking | yes | Doc scan (my run is byte-identical to `VerifierA/out/doc-scan.txt`); lines read. The type says only "creating one allocates nothing" (`ConstantQGeometry.swift:25-26`). `frequencies` (`:125`) and `atomLengths` (`:134`) map into new arrays and say nothing; `:106 … :138` say nothing on allocation |
| A-3 | 518 | VIS-2; lesson 1 | confirmed | blocking | yes | `ConstantQKernel.swift:333, :336, :339, :345`: no word on allocation. `dense()` builds two arrays of rowCount·columnCount values; `applied` (`:357-359`) does say "It allocates". The type's sentence (`:194-195`, "usable on any thread; creating it allocates and transforms") covers creation only. The scan tags these lines "[context alloc]" because it finds that sentence; the grading is the reader's, as `VerifierA/README.md` says of the scan |
| A-4 | 519, 521, 522a, 522b, 524 | §9.3 | confirmed | blocking | yes | Each of these five ends the process ("Restarting after unexpected exit…"; Crash: xctest):<br>• `r519_constantQHopIntMaxTraps`<br>• `r519_constantQHopIntMaxMinusOneTraps`<br>• `r522b_latencyOfHopIntMaxTraps`<br>• `r522a_makeNodeOfHopIntMaxTraps`<br>• `r524_chromaCQTHopIntMaxTraps`<br>Controls, all refused with a message: Int.max − 63, Int.max − 65 ("the nearest are 9223372036854775680 and 9223372036854775744"), Int.max − 127. That fits the arithmetic of `ConstantQSchedule.swift:111`, `above = below + step`, which passes Int.max only for the hops Int.max − 62 … Int.max (7 octaves) |
| A-5 | 519 | O-17 via §6.8 ("names the nearest legal hops"); CR-022 item 5 says "the error names the nearest hops that are" | confirmed (wider than reported) | blocking | yes | `r519_theHopNamedForTwentySixOctavesIsLegal` fails. At hop 512 the error says "…for 26 octaves it is a multiple of 33554432 (2^25); the nearest is 33554432"; hop 33 554 432 is then refused, "above the longest supported, 16777216".<br>Controls: at 25 octaves the named hop 16 777 216 is legal (`latency(of:)` = 2 483 027 943 samples). At 26 octaves 512, 16 777 216 and 33 554 432 are all refused. A geometry of 32 octaves is admitted.<br>Wider: with the default 7 octaves, hop 16 777 217 names "16777216 and 16777280", and 16 777 280 is refused as above the longest |
| A-6 | 521, 522a | NUM-1 | confirmed | blocking | yes | `r521_aLoudClickGivesFiniteBins` fails, "4738 of 20412 magnitudes are not finite".<br>The complex output of `ConstantQ()` on the click of 10²⁵ has 8 526 NaN of 40 824 parts; 10²⁴ has 2 226; 10²² and 10²⁰ have 0.<br>vDSP_DFT_zrop, called directly with no package code, gives NaN at 5 600 of 8 192 positions (4, 5, 12, 13, 20, 21, …) for impulses from 10²³ up, and at none for 10²². The NaN is vDSP's; `VDSPFFTPlan.forward` passes it on.<br>The reproduction is not specific to A-6: see below |
| A-7 | 521 | VIS-2; lesson 1 | confirmed | blocking | yes | Lines read; scan:<br>• `ConstantQ.swift:40, :41, :61, :63, :65, :90` have no comment;<br>• `:39` says nothing of allocation;<br>• `:147` has neither context nor allocation;<br>• `ConstantQStrategy.swift:71, :75, :140, :143` have no allocation, and the last two no context;<br>• `OrderDiagnostics+ConstantQ.swift:30` has no doc comment (the file's `//` comment is not documentation) |
| A-8 | 522a | VIS-2; lesson 1; §11.8 item 4 | confirmed | blocking | yes | `ConstantQStrategy.swift:121`: `makeNode` has no comment of its own (line 120 is blank).<br>The requirement's comment (`:28-34`) gives "Control context: it allocates", and DocC would show it for the witness. But the type's sentence (`:69-70`) does not say that its witnesses follow the requirements, and lesson 1 counts only such a statement |
| A-9 | 522b | VIS-2; lesson 1 | confirmed | blocking | yes | `ConstantQStrategy.swift:88`: `latency(of:…)` has no comment of its own. The requirement (`:21-22`) says "Control context … so it should be arithmetic". The witness builds a `ConstantQSchedule` on every call, which fills six arrays (`ConstantQSchedule.swift:119` and the loop after it), and its `schedule(of:hop:)` says it is arithmetic "but for the half-band filter, which is designed on the first call and kept" (`ConstantQStrategy.swift:82-85`). So even the inherited text misleads about allocation |
| A-10 | 523 | §9.3 | confirmed | blocking | yes | `r523_aLinearAxisOf2To62Plus1BinsTraps` and `r523_aLinearAxisOf2To58Plus1BinsTraps`: both Crash: xctest.<br>By reading (an overflow prints nothing): the first arithmetic on the count is `2 * (bins - 1)` (`ConstantQScale.swift:116`), which is 2⁶³ for 2⁶² + 1. Next is `geometry.binCount * bins` (`:132`): with the probe's 48 bands, 48 · (2⁵⁸ + 1) is above Int.max, once the fast-length check (`:117`) has passed 2⁵⁹ |
| A-11 | 523 | NUM-1 | confirmed | blocking | yes | `r523_aLoudSpectrumGivesFiniteBands` fails, "5 of 72 bands are not finite".<br>Control, flat spectra of 2 049 bins through both nodes (`.native` banded, `.accelerate` dense):<br>• 10³⁶: 0 of 72 non-finite, peak 1.51·10³⁸;<br>• 3·10³⁶: 5 of 72 +∞;<br>• 10³⁷: 26 of 72 +∞.<br>None of them is NaN. The step states no saturation |
| A-12 | 523 | VIS-2; lesson 1 | confirmed | blocking | yes | Lines read; scan:<br>• `ConstantQScale.swift:50, :52, :73, :110, :147` have no comment;<br>• `:33` says nothing of allocation;<br>• `:156` has neither context nor allocation;<br>• `OrderDiagnostics+ConstantQ.swift:15, :22, :25` have no doc comment |
| A-13 | 524 | §9.3 | confirmed | blocking | yes | `r524_aConstantQAxisFromASubnormalFrequencyTraps`: "Fatal error: Double value cannot be converted to Int because it is either infinite or NaN".<br>Controls: axes from 10⁻³⁰⁰ Hz and from 2·10⁻³²¹ Hz attach and run (2·10⁻³²¹ / 440 rounds to the least subnormal, not to 0) |
| A-14 | 524 | §9.3 | confirmed | blocking | yes | `r524_aConstantQAxisOfIntMaxBinsPerOctaveTraps`: Crash: xctest.<br>Controls:<br>• Int.max − 11 is refused, "the nearest are 9223372036854775788 and 9223372036854775800";<br>• Int.max − 7, a multiple of 12, attaches and runs;<br>• Int.min is refused, "the nearest is 12" |
| A-15 | 524 | §9.3 as the verifier reads it; §11.6 "a result is wrong" (attaching neither refuses nor returns) | confirmed | blocking | yes | `r524_aConstantQAxisOfIntMaxBinsIsRefused` fails after 30.013 s, "attaching did not return within 30 s".<br>A watchdog sampled the test process every second: its resident size grew from 12 MB (04:10:27) to 1.73 GB (04:10:57), when the test ended (`logs/r3-memory.txt`). I did not let it run until memory ran out.<br>The verifier's `sample` shows `Collection.map` in `pitchClasses` (`ChromaFold.swift:153`) |
| A-16 | 524 | §6.8 ("A frame whose norm is below the floor is twelve zeros"); a wrong result | confirmed | blocking | yes | `r524_aLoudFrameIsItsChroma` fails: ".max of 24 × 1.5e37" and ".l2 of 24 × 1e19" both give twelve 0.0.<br>Controls, frame by frame:<br>• `.max` at 1.4·10³⁷ gives ones;<br>• `.l2` at 10¹⁸ gives 0.288675 (1/√12);<br>• `.l1` at 10³⁷ gives 1/12, and at 3·10³⁷ zeros;<br>• `.none` at 10³⁷ gives 2·10³⁷, and at 3·10³⁷ zeros, although the exact 6·10³⁷ is representable.<br>CR-022 item 8 makes zeros only of a frame "under the floor" |
| A-17 | 524 | NUM-1 | confirmed | blocking | yes | `r524_theNormsOfFiniteValuesAreFinite` fails, "L1 of twelve greatestFiniteMagnitude: inf" and "L2 of twelve 2e19: inf".<br>Controls:<br>• L2 of twelve 5·10¹⁸ = 1.7320508·10¹⁹;<br>• L2 of twelve 10¹⁹ = inf, although the exact 3.46·10¹⁹ is representable;<br>• L1 of twelve 2.8·10³⁷ = 3.36·10³⁸;<br>• L1 of twelve 2.9·10³⁷ = inf, where the exact 3.48·10³⁸ exceeds `Float` |
| A-18 | 524 | VIS-2; lesson 1 | confirmed | blocking | yes | Lines read; scan:<br>• 19 public declarations have no doc comment: 13 in `ChromaFold.swift` (the four `init()`, the four `norm(of:)`, `Input`, `Output`, `activation`, `init(…)`, `lower`) and 6 in `ChromaRecipes.swift` (`Input`, `Output`, `expansion`, `activation`, two `init`);<br>• the listed others lack context, allocation or both;<br>• `OrderDiagnostics+ConstantQ.swift:33, :36, :41` have no doc comment |

### Notes on the findings

**A-1.**

- The trap for B = 64 is `octave * binsPerOctave`. Here `Double(Int.max)` is 2⁶³, divided by 64 that is 2⁵⁷, and 2⁵⁷ · 64 overflows.
- With B = 36 the quotient rounds to 256 204 778 801 521 536, and times 36 that still fits, so the call returns +∞ instead of trapping. My control shows this.
- Whether an index that the documentation admits counts as "invalid input" does not matter. A trap reachable from public API breaks §9.3 either way, and +∞ breaks NUM-1.
- I did not run the B = 1 and Int.min cases.

**A-4.**

- An integer overflow prints nothing, and no crash log was produced. The location therefore rests on the arithmetic and on the controls: the hops next to the trapping ones return a refusal.
- By the arithmetic, in 7 octaves exactly the hops Int.max − 62 … Int.max trap, which is where `above = below + 64` passes Int.max. I ran Int.max and Int.max − 1 (trap) and Int.max − 63, − 65 and − 127 (refused). Int.max − 63 is a multiple of 64 and is refused as "above the longest supported".

**A-5.**

- The finding says that from 26 octaves on no hop is legal, and that the error names 33 554 432. Both are reproduced.
- The same defect reaches the default transform as well: the divisibility message ignores `longestHop`. So a hop above 2²⁴ that is not a multiple gets a suggestion above 2²⁴. For 7 octaves, 16 777 217 names 16 777 280, which `ConstantQ(hop: 16_777_280)` refuses.
- CR-022 item 5 ("names the nearest hops that are") misdescribes both cases, so it does not cover them.

**A-6.**

- The defect is real and sits where the finding puts it. With no package code involved, `vDSP_DFT_zrop_CreateSetup` / `vDSP_DFT_Execute` on one impulse of amplitude A, placed at each position of the frame in turn, gives the following, while the exact result has magnitude 2A in every bin (the real transform returns twice the DFT):

  | Length | Impulses that give NaN | Positions with NaN |
  |---|---|---|
  | 8 192 points | 10²³, 5·10²³, 10²⁴, 10²⁵, 10³⁰ | 5 600 of 8 192 (at most 2 696 values each) |
  | 2 048 points | the same | 1 184 of 2 048 |

  - These are the same positions that the verifier found through the plan.
  - Impulses of 10²⁰ and 10²² give no NaN.
  - So the onset lies between 10²² and 10²³ when vDSP is called directly. `VDSPFFTPlan.forward` halves the signal first (`TransformPlans.swift:54-57`), so through the plan it lies between 2·10²² and 2·10²³.
- **The reproduction is not specific to A-6.** `r521_aLoudClickGivesFiniteBins` counts the non-finite values after `Magnitude()`. `Magnitude` is `vDSP_zvabs` (`SpectralValueNode.swift:28`, WP-534), and it returns NaN for |z| of 2·10¹⁹ and more, while 10¹⁹ comes back right:
  - 16 × (10¹⁹, 0) gives 9.999999e18;
  - 16 × (2·10¹⁹, 0) gives nan, and so do (10²⁰, 0), (10²⁵, 0) and (10³⁸, 0).
- So at a click of 10²² the transform is finite (largest part 1.22·10²⁰), and `ConstantQ(); Magnitude()` still gives 107 NaN of 20 412.
- The report puts the exact coefficients "of the order of 10²¹". Where the transform is finite, at clicks of 10²⁰ and 10²², the largest part is 1.22·10⁻² of the click (1.22·10¹⁸ and 1.22·10²⁰). For the click of 10²⁵ the largest exact parts are therefore about 1.2·10²³, and the largest finite part I measured there is 1.08·10²³. That is two orders above the report's figure, still well inside `Float`, and far above the limit of `vDSP_zvabs`.
- The resolution proposed for A-6 (scale the frame and scale back) would therefore leave `r521` failing until `Magnitude` is fixed as well. That defect belongs to WP-534 and is outside this batch; it is reported to the integrator here as an observation, not graded.

**A-8 and A-9.**

- Under the reading that DocC inherits a requirement's comment, A-8 would be met in substance, because the requirement states the context and the allocation. A-9 would not, because "should be arithmetic" is not true of the witness.
- Lesson 1 and §11.8 item 4 ask every public symbol for a comment, or for a statement on the type that says it covers its members. Neither is there. Both findings are therefore confirmed as stated, and blocking.
- CR-A1 asks the owner to settle the reading. Until it is filed and decided it covers nothing.

**A-15.**

- The non-return, and memory growing without bound for 30 s, are reproduced.
- That the process "ends when memory runs out" is the verifier's inference. Neither the verifier, who killed its process at 6.3 GB (peak 12.0 GB), nor I ran it that far.
- The severity does not depend on the inference: a refusal is due, and attaching neither refuses nor returns.

**A-16.**

- The zeros are deliberate and pinned by the package's own test. `ChromaTests.swift:170-176` expects zeros for 24 × greatestFiniteMagnitude under three normalisations (`.max`, `.none`, `.l2`), and for 10³⁰ under `.l2` ("squares that overflow have no norm").
- The node's comment and check (`ChromaNodes.swift:60-62`) explain the zeros.
- But §6.8, the step's documentation (`ChromaFold.swift:107-108`) and CR-022 item 8 make zeros only of a frame below the floor.
- The code does more than the CR says, so the finding stays blocking. The fix has to change that test too.

**The seven order overloads.** `OrderDiagnostics+ConstantQ.swift:15 … :41` (split between A-7, A-12 and A-18) are `@available(*, unavailable)` overloads that exist to give a compile-time sentence. No context can call them, so a threading contract says little there, but VIS-2 and §11.8 item 4 name every public symbol and the file has only a `//` comment. None of the three findings depends on them: each has other public declarations without a comment.

**Severity.**

- §9.3, NUM-1, O-17 and VIS-2 are numbered rules of §4–§10, and A-16 is a wrong result. Each is therefore blocking under §11.6.
- No CR in `Docs/Process/changes/` describes any of these deviations accurately.

## 2 Gaps in the verification (duty 2)

| Package | Gap |
|---|---|
| WP-517 … WP-524 (all nine) | **The cited evidence is not kept, and the "flakiness record" is in no report.** Every report says that the package's tests pass "in the runs of the flakiness record", and WP-517 points to "the flakiness record of the final result". No report contains such a record. The runs exist only as `.build/logs/` files (`VerifierA/README.md`: "In `.build/logs`: `run-debug-*.txt`, `run-release.txt`, `bench.txt` …"; `VerifierA/scripts/runs.sh` is "the runs of the flakiness record"). So do the logs that the reports cite for mutations M1 … M9 (`mutation-M*.txt`), the reproduction results (`repro-<test>-result.txt`, for A-1, A-4, A-10, A-13), the `sample` behind A-15 (`sample-T11-bincount.txt`) and the WP-520 benchmark record (`.build/bench.json`). The rsync of this audit excludes `.build`, and its cleanup deletes it, so these citations will point at nothing. I read the files before the cleanup and they say what the reports say:<br>• `run1-debug.txt`: 82 tests in 8 suites passed;<br>• `run-debug-1.txt` and `run-debug-2.txt`: 84 tests in 9 suites passed (02:52, 02:53);<br>• `run-release.txt`: 84 passed (03:00);<br>• M1 … M9: each run fails, with 25, 9, 38, 235, 595, 254, 2 164, 8 and 176 issues;<br>• `bench.json`: sparse 279.4 ns minimum, dense 7 263 ns minimum.<br>The durable evidence is `VerifierA/out/` and the text of the reports |
| WP-517 | **The tolerance duty is not addressed.** The report has no "Tolerances" item: it does not say that no tolerance of `ConstantQGeometryTests` was loosened against a stated figure. All the other reports of this batch but WP-522b have one |
| WP-522b | **The tolerance duty is not addressed.** The tolerances of the alignment tests the report cites (for example "worst <= 2e-4" in `everyOctaveOfAFrameIsCentredOnTheSameSample(octaves:hop:)`) are not compared with any stated figure |
| WP-521, WP-522a | **The reproduction of A-6 is not specific to A-6, and one figure is off.** Part of the NaN that `r521_aLoudClickGivesFiniteBins` counts come from `Magnitude` (vDSP_zvabs, NaN from \|z\| ≈ 2·10¹⁹), not from the transform. At a click of 10²² the transform is finite and all 107 NaN are Magnitude's. The fix proposed for A-6 would not make the reproduction pass. The report also puts the exact coefficients "of the order of 10²¹"; for the click of 10²⁵ they reach about 1.2·10²³ (1.22·10⁻² of the click where the transform is finite; largest finite part measured at 10²⁵: 1.08·10²³). The finding stands on the complex output (A-6 above) |
| WP-519 | **The hop probes missed the case that widens A-5.** The probes are Int.min, −1, 0, 1, 63, 100, 32, 2²⁴, 2²⁴ + 64, Int.max − 63, Int.max, Int.max − 1 and 26 octaves. They have no hop above `longestHop` that is not a multiple of 2^(octaves − 1). At 7 octaves, 2²⁴ + 1 is told that 16 777 280 is a nearest hop, and that hop is refused. So A-5's statement "from 26 octaves on" understates its reach |

### Checked and not gaps

- **Acceptance checks.** Every row's acceptance is listed in its report with how it was run and its result. For WP-517 … WP-524 that is 5, 5, 4, 4, 5, 6, 7, 5 and 4 checks.
- **Golden vectors.** Every report whose package has committed vectors (WP-517, 518, 521, 522a, 523, 524) compares them with the verifier's own definition (`ref.py golden`); WP-517, 522a and 523 also cite `Scripts/golden.sh --check` ("197 files of 27 generators match the manifest"). WP-519, 520 and 522b have no committed vectors: `Tests/ZTronDSPAnalysisTests/Golden` holds no half-band, product or alignment file (I listed it).
- **Edge cases.** Empty, length 1, DC, Nyquist, silence, full scale and non-finite input are shown in every report, or argued not to apply (WP-517 and WP-522b, which take no samples or only time).
- **Precision.** Every report states and argues its precision choice.
- **The six ALG rows** (518, 519, 520, 521, 522a, 523).
  - Each report checks the currency record: lines 1-3 of its note and row 13 of `currency-2026-11.md`, as a record with no network. I read lines 1-3 of the five notes (`constant-q-kernel`, `half-band-decimator`, `sparse-kernel-product`, `constant-q-transform`, `constant-q-scale`: a check of 2026-11-15 against §7.2 row 13, and the search of the same day) and row 13 ("Current. One more alternative to register for the lowest latency: CR-020 item 3"). They say what the reports quote.
  - Each mutates what the stability note names (M1 … M9), sees the named tests fail, and restores the file byte for byte. I read the "Stress test" sections of the five notes: they name exactly these nine changes (two each in the kernel, half-band, transform and scale notes, one in the product note) and the tests the reports saw fail. The mutation logs said the same (gap 1 above).
- **Tolerances.** Stated as not loosened in WP-518, 519, 520, 521, 522a, 523 and 524.
- **Coverage.** COV-3 is lens T's (WP-517's second lens), not lens N's.

## 3 Spot checks

I chose the pass verdicts whose evidence is thinnest:

- the only package-level pass (WP-520), both of its checks resting on the verifier's own Python over dumps and on a benchmark file in `.build`;
- three row-level passes inside blocking packages whose evidence is summary figures: WP-521 tones, WP-522b latency, WP-524 silence and classes.

The suites are `AUD_Spot` in `VerifierA/audit/AuditAProbes.swift` (plain imports) and `AUD_Product` in `VerifierA/audit/AuditAProduct.swift` (`@testable`, because `SparseKernelProduct` is internal).

| Package | Check | What I ran | Result | Agrees with the pass |
|---|---|---|---|---|
| WP-520 | ≡ dense product | `AUD_Product/wp520()` (`@testable`): `SparseKernelProduct.apply`, the node's loop, against `kernel.dense()` multiplied in double. 6 geometries (defaults at 22.05 and 48 kHz and semitones at 44.1 kHz, their lowest and highest octave; γ = 4.45 Hz, every octave; one octave of 24 at 16 kHz; 48 a octave with filterScale 0.6, lowest and highest octave) × sparsity 0, 0.01, 0.3: 51 kernel runs, 48 distinct (the one-octave geometry's octave 0 ran twice), 1 692 rows, each against 3 white-noise spectra at scales 1, 10⁻³⁰ and 10³⁰: 5 076 row products. Also the package's `theSparseProductIsTheDenseProduct(sparsity:)` (3 cases) and `theProductOfEveryStressSpectrumIsWithinTheBoundOfItsTerms()` | Worst \|sparse − dense\| 4.0 ε·T, which is 0.059 of the note's bound (2n + 1)·ε·T, and 8.9·10⁻⁷ of the largest coefficient (10⁻⁵ asked). `applied` (double) is within 5.0·10⁻⁸. Both package tests pass. The verifier's worst is 3.58 ε·T; mine also bears out its B-4 | yes |
| WP-520 | benchmark recorded (PERF-1) | A fresh Release build of my own (`.build/audit-release`, 04:14 … 04:16), then `test-only` with `-configuration Release`, `-parallel-testing-enabled NO`, `TEST_RUNNER_ZTD_BENCHMARK_OUTPUT=…/bench.json`, `ConstantQKernelTests/theProductIsTimedAgainstTheDenseProduct()` | "1 test in 1 suite passed" (products in `Release-iphonesimulator`). The harness wrote both workloads, 11 samples of 200: sparse 215.2 ns minimum and 215.8 ns median; dense 5 143 and 5 196 ns, a factor of 24 (`logs/bench.json`). The verifier had 279.4 and 7 263 ns, the same order | yes |
| WP-521 | bin-centre tones within 0.5 dB | `AUD_Spot/wp521Tones()`: `ConstantQ(); Magnitude()` with the defaults at 22.05 kHz. Sines of amplitude 0.9 at the centres of bins 0, 17, 40, 77, 110, 151, 190, 216, 233 and 251 (every octave), 60 000 samples, frame 58 | Worst \|level\| 0.0069 dB; every tone peaks in its own bin. The verifier had −0.0082 … +0.0077 dB over all 252 | yes |
| WP-522b | latency reported; when a frame leaves | `AUD_Spot/wp522bLatency()`: a client's stage after `ConstantQ(); Magnitude()` reads `context.environment.latency`. Then frame counts on silence of L − 1, L, L + 511 and L + 512 samples | Declared 0.8580045 s = 18 919 samples at 22.05 kHz, and 0.8194792 s = 39 335 at 48 kHz. The frames come out 0, 1, 1, 2 at both rates, that is ⌊(n − L) / hop⌋ + 1 | yes |
| WP-524 | silence gives zeros; strongest pitch class | `AUD_Spot/wp524()`: `ConstantQ(); Magnitude(); ChromaFold()` on 60 000 samples of silence, and `ChromaCQT(to:)` into a feed. Then one sine of amplitude 0.3 per class, spread over all 7 octaves (MIDI 24, 37, 50, 63, 76, 89, 102, 31, 44, 57, 70, 83), frame 58 | Silence: 81 frames, all 972 values exactly 0, and the recipe runs. Tones: the strongest class is right for all 12; it reads 1.0, and the next strongest at most 0.0118 | yes |

## 4 How this was run

Everything ran from ROOT on `ztdsp-27-vm5ca`.

- Verifier A's four probe files and my two (`AuditAProbes.swift` with plain imports, `AuditAProduct.swift` with `@testable`) were copied into `Tests/ZTronDSPAnalysisTests/` for the runs. Afterwards they were removed: `rm` for mine, then `VerifierA/scripts/probes.sh out`.
- `Tests/`, `Sources/`, `Scripts/` and `Package.swift` were then identical to the main tree (`diff -rq`, `cmp`), and the verifier's manifest had 0 mismatches.

| What | Command | Result |
|---|---|---|
| Debug test builds with the probes | `ZTD_DEVICE=ztdsp-27-vm5ca Scripts/xc.sh build`: at 03:47 with the verifier's four probe files, at 04:07 with my two added | "TEST BUILD SUCCEEDED" both times (`logs/build-probes.txt`, `logs/build-aud.txt`) |
| The verifier's other 17 reproductions | `bash .build/audit-logs/run-tests.sh r1 …` and `… r2 VA_Repro/<test> …`, one `test-only` per test | r1 at 03:48 (`r524_theNormsOfFiniteValuesAreFinite`), r2 at 04:08:06 … 04:09:14 (16 tests). 11 end the process ("Crash: xctest" in the bundle; 2 of them first print "Fatal error: Double value cannot be converted to Int …"), 6 fail their expectation, each as its finding says (`logs/batch-r1.txt`, `batch-r2.txt`) |
| A-15 under a memory watchdog | `bash .build/audit-logs/watch-intmax.sh`, which runs `run-tests.sh r3` and kills the process above 4 GiB (it was not needed) | 04:10:24 … 04:10:58: fails after 30.013 s; resident size 1.73 GB at the end (`logs/batch-r3.txt`, `logs/r3-memory.txt`) |
| My controls and the direct vDSP check | `run-tests.sh r4 AUD_Controls/<test> … AUD_VDSP/impulses` | 10 tests, all pass: they print what they find and assert nothing about the defects (`logs/batch-r4.txt`, `printed.txt`) |
| Spot checks | `run-tests.sh r4 AUD_Spot/wp521Tones AUD_Spot/wp524 AUD_Spot/wp522bLatency AUD_Product/wp520 "ConstantQKernelTests/theSparseProductIsTheDenseProduct(sparsity:)" ConstantQStabilityTests/theProductOfEveryStressSpectrumIsWithinTheBoundOfItsTerms` | 6 tests, all pass (`logs/batch-r4.txt`, `printed.txt`) |
| Benchmark | `ZTD_CONFIG=Release ZTD_DERIVED=.build/audit-release Scripts/xc.sh build`, then `test-only` with `ZTD_XCARGS="-parallel-testing-enabled NO"` and `TEST_RUNNER_ZTD_BENCHMARK_OUTPUT` | "TEST BUILD SUCCEEDED" (`logs/release-build.txt`); the test passed and wrote `logs/bench.json` (`logs/bench.txt`, `bench-full.log`) |
| VIS-2 scan | `python3 -I -B VerifierA/scripts/doc-scan.py`, and each cited line printed with the line before it | 39 "NO DOC COMMENT", byte-identical to `VerifierA/out/doc-scan.txt` |

`run-tests.sh` and `watch-intmax.sh` resolve ROOT from their own directory and write to `.build/audit-logs/`. To run them again, copy both into `.build/audit-logs/` first, as they were run.

**Disclosures.**

- **One write outside ROOT.** Early in the audit I redirected a scan's output to `…/scratchpad/audit-doc-scan.txt`, which is outside ROOT. I deleted that file at once and wrote nothing else outside ROOT, apart from the prescribed rsync.
- **Other sessions' processes.** `ps` and `simctl list` also showed other sessions' simulators and test processes. I used them only to tell my own processes apart, by the parent `launchd_sim` of my device (UDID 0CAA5CA6-9A64-4C2C-BAB5-90DCBE6B2EB7), and read nothing of theirs. Nothing that Verifier B wrote was read.
- **What I added to ROOT.**
  - `ROOT/AuditA/`: my two probe sources.
  - `ROOT/VerifierA/audit/`: copies of the two probe sources and of the two scripts, my logs (`logs/`, 148 files) and `printed.txt`.
  - Under `.build/`, which the cleanup deletes: a copy of the verifier's `.build/logs` taken before my runs, my working logs (copied to `VerifierA/audit/logs/` before the cleanup), the Debug build and the Release build (`.build/audit-release`).

## 5 Remarks

- **`Magnitude` and large coefficients (WP-534, not graded here).** `vDSP_zvabs` returns NaN for a coefficient of 2·10¹⁹ and more (A-6 above), and after `ConstantQ` that gives NaN magnitudes where the transform itself is finite. `Magnitude` calls `vDSP_zvabs` whatever spectrum it follows (`SpectralValueNode.swift:23-28`), so by reading the same holds after the STFT; I ran it after `ConstantQ` only. This belongs to the owner of WP-534; it matters for the fix of A-6, because `r521_aLoudClickGivesFiniteBins` reads the magnitudes.
- **B-8 (non-blocking) agrees with what I measured.** The verifier grades the latency, which is the lowest octave's completion and not §6.8's "half-atom length", as non-blocking because CR-022 item 2 describes it ("39 335 samples at 48 kHz"). My spot check of WP-522b reads 39 335 samples at 48 kHz and 18 919 at 22.05 kHz, and frames leave at exactly that delay. The CR describes the code accurately, so the grade follows the rule that such a CR makes a deviation non-blocking.
- **What stays in ROOT.** `ROOT/AuditA/` and `ROOT/VerifierA/audit/` stay; only `ROOT/.build` is removed by the cleanup, as prescribed.
