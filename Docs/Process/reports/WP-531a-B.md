# Verifier report — WP-531a, lens R

| Field | Value |
|---|---|
| Package | WP-531a — Streaming `HarmonicPercussive(select:)`: history ring, causal mode |
| Lens | R (real-time safety and performance): the second lens of the package's row in §12 |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced again by the verifier in that checkout)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs, all on the simulator `ztdsp-27-vm5bb` through `Scripts/xc.sh` (commands and outputs in `VerifierB/README.md`): (1) the tree as received, Debug, `ZTronDSPAnalysisTests` and `ZTronDSPTestingTests`: 420 tests in 41 suites and 52 in 7, pass; (2) the same in Release: pass; (3) the instrumented build for COV-3: pass; (4) the 17 suites of the batch, each test three times (`-test-iterations 3`), Debug, on the restored tree: no failure; (5) the mutation build (`VerifierB/mutants.diff`): the control passes, every row killed. Gates (api-digest, dependency graph, compile fixtures, golden, ledger, lint, order matrix): all pass. Rule 6 probes in `VerifierB/Probes/VerifierBTrapProbes.swift` and `VerifierB/Probes/VerifierBSeparationProbes.swift`, each in a process of its own.

| Check | How it was run | Result |
|---|---|---|
| ≡ offline on interior frames | `HarmonicPercussiveTests.theCausalStepEqualsTheOfflineMediansOnInteriorFrames(caseIndex:)`: the causal step on the music fixture (hop 512, kernels 31 and 31) and the speech fixture (hop 256, kernels 17 and 17), every component, against the time medians of the offline separation shifted by (k − 1)/2 frames with the frequency median and the mask of the frame itself | Pass in every run; 56 (music) and 69 (speech) interior frames of 513 bins equal exactly, for each component; every frame, the first ones included, also equals the running median of the oracle (`MedianOracle.running`) |
| The history ring, causal: no latency, a frame for every frame, at its own time | `theLookAheadIsLatencyAndFramesKeepTheirTimes` (causal: latency 0, as many frames as the framing gives, the same times) | Pass in every run |
| The step: a complex spectrum with its phase, the three components, magnitudes on any axis, the order rule, spelling and activation, GPU-1, refusals, cold start | `onAComplexSpectrumTheMaskIsAppliedAndThePhaseKept`, `theThreeComponentsAddUpToTheSpectrum`, `itFollowsMagnitudesOnAnyAxis`, `theRuleOfTheDescriptionIsTheRuleOfTheTypes`, `descriptionsSpellingsAndActivation`, `aLiveFrameIsFilteredOnCPULanesWhateverTheStrategy`, `nonsenseIsRefusedWhenThePipelineIsAttached`, `aColdStartRefillsTheHistoryOfTheMedian`; the order-matrix and compile-fixture gates | Pass |
| §7.5 stability | `RhythmSeparationStabilityTests.theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold` | Pass; 261 frames of 513 bins: the three components add up within 8.0·10⁻⁸ of each bin, the harmonic part within 1.37·10⁻⁷ of the frame maximum of its definition |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - RT-2 (read: `Nodes/HarmonicPercussiveNode.swift`, `HarmonicPercussiveNode.process` `:135-186`): `vDSP_zvabs` of a complex frame into the ring (or a `memcpy` of magnitudes) and two `memcpy` of its parts, the time median of the arriving frame (`:154`), the frequency median of the centre frame (`:173`), the masks of WP-530 (`:174`), `vDSP_vmul` of the frame by the mask, `emit`; wrapping arithmetic for the slot. No allocation, lock, log or `await`. Dynamic dispatch: the two filters (`any MedianFilter`) and the mask strategy, once per frame each (backlog BL-3, the change request in `WP-530-B.md`).
  - The allocation audit exists and passes: `HarmonicPercussiveTests.theNodeRunsWithoutAllocating`, Debug and Release (a causal harmonic step on the complex spectrum, kernels 31 and 31; a causal residual on magnitudes, soft mask of power 1.5, margins of 2; two centred steps; then 500 blocks with the `.accelerate` lane exchange forced), and `HPSSTests.theRecipeRunsWithoutAllocating`. It would fail: a `malloc`/`free` planted at the top of `process`, taken by a causal node only (after `:135`, `lookAhead == 0`, mutant 5311), makes both fail; restored, `diff -r` clean.
  - RT-3, RT-5: the history ring (`lookAhead + 1` frames of magnitudes, and of real and imaginary parts on a complex spectrum), its times, the outputs of the two medians and the mask are `AlignedBuffer`s made in `init` (`:121-129`); the plan's `create` closure runs it, and makes the two filters, when the plan is compiled (`Steps/HarmonicPercussive.swift:168-174`). Causal, the ring holds one frame. RT-6: no recursive state; the ring holds input frames.
  - RT-7, layer 2: `process` calls vDSP, `memcpy` and the filters through existentials (E-05): nothing to annotate here. The leaf loop of the hard mask is WP-530's finding 2.
  - Complexity: per frame the two medians of §7.2 row 16 (WP-529) and O(bins) for the masks and the product. SEL-3: the lane exchange is bound when the filter is made, and the node's key carries it (`Steps/HarmonicPercussive.swift:163`). GPU-1: a live frame is filtered on CPU lanes whatever the strategy, and `.metal` is refused when the pipeline is attached (`aLiveFrameIsFilteredOnCPULanesWhateverTheStrategy`). A benchmark is recorded: none for this package (backlog BL-5).
  - Rule 6: `timeKernel` and `frequencyKernel` at Int.max, Int.min, 0, −1, 2 and 257, causal and centred: refused (`t531TimeKernel`, `t531FrequencyKernel`); the margins at −gFM, a subnormal, ±0, NaN and ±∞: refused, at +gFM and 10³⁹: accepted, 125 frames of finite values (`t531HarmonicMargin`, `t531PercussiveMargin`); the floor at −gFM, NaN and ±∞: refused, at +gFM, a subnormal and ±0: accepted, finite values (`t531Floor`). No trap, nothing non-finite out. The accepted values that `Float` does not hold give wrong shares: finding 2.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | VIS-2 | `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift:53, :71, :182, :189, :198, :209` | `struct HarmonicPercussive` ("An immutable value, usable on any thread; `lower(_:)` runs on the control context": nothing on allocation); its `init(select:…)` (no comment of its own, none on allocation); the two `PipelineBuilder.buildPartialBlock(accumulated:next:)` (nothing on context or allocation); the two `Pipeline.harmonicPercussive(select:…)` (nothing on allocation). `python3 -I VerifierB/vis2_decide.py`: 6 of 19 public symbols | Blocking |
| 2 | A wrong result (§6.10; the step's documentation, `Steps/HarmonicPercussive.swift:19-23`: "A bin where neither median reaches `floor` goes to neither side"); rule 6 of the brief | `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift:162` (`Float(harmonicMargin)`, `Float(percussiveMargin)`, `Float(floor)`) | `check` accepts, as `Double`, any finite margin of at least 1 and any finite floor that is not negative (`:114-121`); the lowering narrows them to `Float` for the node. A margin of 10³⁹ or gFM becomes +∞, and where the competitor's median is 0 the product ∞ · 0 is NaN. On a click (`vb531aLiveMarginAboveTheFloatRange`: bin 100 of frames 90–93, where the time median is 0) the percussive share is 1.0 with a percussive margin of 1 or 3.4·10³⁸, and 0.5 (soft) or 0.0 (hard) with 10³⁹ and gFM; the definition gives 1 for every finite margin. A floor of 5·10⁻³²⁴, 10⁻⁴⁶ or 7·10⁻⁴⁶ becomes 0, and the rule of a floor of 0 applies instead: a bin alone in time and frequency (`vb531aLiveFloorBelowTheFloatRange`: bin 16, magnitude 32.0, both medians 0) goes half to the harmonic part under a soft mask (harmonic 16, residual 0), where floors of 10⁻¹⁰ and 10⁻⁴⁵ send it to the residual (harmonic 0, residual 32), as the documentation says for every floor above 0. No non-finite value comes out. The centred step (WP-531b) and `HPSS` (WP-532) share this lowering and inherit the defect; it is filed here once | Blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
