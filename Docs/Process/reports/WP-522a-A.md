# Verifier report — WP-522a, lens N

| Field | Value |
|---|---|
| Package | WP-522a — Octave recursion |
| Lens | N (the first lens of the row: N, R) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`briefs/37-verifier-a-m5c.md`)
- [x] The specification sections it cites (§6.8, §6.12, §7.2–§7.5 row 13, NUM-1, §9.3, VIS-2, STG-1, §11, the M5 table)
- [x] The revision under review, as a checkout that can be run and modified (scratch copy, Debug and Release, simulator `ztdsp-27-vm5ca`)
- [x] The test and lint output: produced by this verifier. No coverage output exists (CR-022, "Not done")
- [x] Nothing of the other verifier's findings before this report was filed (see the disclosure in `WP-517-A.md`)

## Acceptance checks run by the verifier (VER-3)

Row: "§6.8 acceptance over all octaves" (ALG). §6.8 has three acceptance statements; each was checked over every octave of multi-octave transforms, the octaves below the highest being the recursion this package adds (decimated signal, the kernel reused or one per octave with γ > 0, the octaves laid on one frame).

| Check | How it was run | Result |
|---|---|---|
| "A tone at a bin centre appears in that bin within 0.5 dB of its amplitude", every octave | `VA_Dumps`: a sine of amplitude 0.9 at the centre of every bin, one at a time, through `ConstantQ`; `python3 -I -B VerifierA/scripts/ref.py tones`, broken down by octave | defaults at 22.05 kHz (7 octaves of 36): every octave within −0.0082 … +0.0077 dB, the lowest −0.0082 … +0.0070; variable-Q (7 octaves of 24, γ = 5 Hz, a kernel per octave): −0.0080 … +0.0098 dB, every octave; tuned quarter tones at 16 kHz (5 octaves of 24, tuning 0.1, filterScale 1.2): −0.0087 … +0.0084 dB. All 540 tones peak in their own bin. **pass** |
| "The strongest pitch class is correct for a fixture covering all 12 classes in every octave" | `VA_Dumps`: `ConstantQ(fmin: .hertz(110), octaves: 6, binsPerOctave: 36, hop: 256); Magnitude(); ChromaFold()` on a sine of every MIDI note 45 … 116 (72 tones, every class in each of the 6 octaves, starting on an A so that the class of bin 0 is not 0); `ref.py chroma` | the strongest class is `note mod 12` for all 72 tones; the next class reads at most 0.0153 of it (`chroma_classes_from_a.json`). The repository's `ChromaTests/theStrongestPitchClassIsRightForEveryClassInEveryOctave()` (from C1, 7 octaves) passes in every run. **pass** |
| "Frame-wise cosine similarity ≥ 0.98 against reference chroma on the music fixtures" | `VA_Dumps`: `ConstantQ; Magnitude; ChromaFold` on the music and speech fixtures; `ref.py chroma` folds my own transform of the definition (each atom against the signal, in double, every octave at the input rate) by the rule of §6.8 | least frame-wise cosine: music, defaults (7 octaves) 0.99999; music, variable-Q (7 octaves) 0.99998; speech, 6 octaves of semitones, tuned 0.25: 0.99990; music from A2 (5 octaves): 0.99999. **pass** |
| The transform over all octaves against the definition | `VA_Dumps` (blocks of 441 samples) and `ref.py transforms`: every coefficient of every octave against §6.8 evaluated directly at the input rate, in double | as a share of the frame's maximum (worst frame, mean) and of the excerpt's: music, defaults 0.0213, 0.0064, 0.0046 (at sparsity 0: 0.0041, 0.0019, 0.0018); speech, semitones 0.0149, 0.0067, 0.0086; music, variable-Q 0.0241, 0.0070, 0.0069; noise at 16 kHz (5 octaves of 24, tuning 0.1, filterScale 1.2) 0.0094, 0.0059, 0.0047; noise at 48 kHz, defaults 0.0100, 0.0059, 0.0055, and with γ = 4.45 Hz 0.0122, 0.0059, 0.0062; a linear chirp 30 … 2 000 Hz at 32 kHz (5 octaves of 60, tuning −0.73, filterScale 1.3, γ = 3.1 Hz): 0.0047 of the excerpt, mean 0.0074 over the 83 frames whose maximum exceeds 1 % of the excerpt's, worst 0.19 there. **pass** (the chirp's worst frames below) |
| Golden vectors | `ref.py golden` on the committed `constant_q_*` transforms (music defaults, speech semitones, variable-Q, top octave) | within 6.2·10⁻¹⁷ … 4.7·10⁻¹⁵ of my definition. `Scripts/golden.sh --check`: 197 files of 27 generators match the manifest. **pass** |
| The package's tests | `ConstantQTests` (17 tests), `ConstantQScheduleTests` (9), `ConstantQStabilityTests` (7) in the runs of the flakiness record | pass in every run; the stress tests fail under the mutations of the note (M6, M7 below) |

The chirp's worst frames (per-frame figure 9.53) are frames 105 … 112, where the chirp (1 685 … 1 795 Hz) lies above the top bin (1 255 Hz): the definition's maximum there is 5·10⁻⁶ … 1·10⁻⁵ of the excerpt's, and the difference 4·10⁻⁵ … 7·10⁻⁵ of it (−83 … −87 dB). The top octave is not decimated, and 1.8 kHz is in the pass band of every decimator below it, so this is not aliasing: it is the energy a thinned row reads from outside its band, bounded relative to the spectrum's norm (`constant-q-kernel.md`, hazard 1), as for frame 82 of the top-octave fixture in `WP-521-A.md`.

## Lens N

- **Definition.** Independent: `ref.py` evaluates §6.8 at the input rate for every bin of every octave, so the recursion (decimation, the per-octave rounding of the atom lengths, the lag of each octave) is compared with what it replaces, not with itself.
- **Precision.** `Float` on the signal path (the decimators are the C kernel of WP-519, the transform and the product WP-502/520's), kernels in `Double` rounded once. Right for the package: the recursion's own errors (hazard 4 of `constant-q-transform.md`, a sample of the octave's rate in an atom length, and the decimators' 0.001 dB) are 10⁻³ … 10⁻⁴ of a coefficient, three orders above `Float`'s rounding; the tones read within 0.01 dB in every octave.
- **Edge cases** (seven octaves of the defaults unless stated; `VA_Edges`, `VA_NaN`, `VA_T06`, `VA_T08`; trap probes each in a process of its own):
  - *empty, length 1*: 0 frames, no trap.
  - *silence, ±0, subnormals*: 81 frames, every one of 40 824 values exactly 0 (the decimators flush values below 10⁻²⁰, hazard 6).
  - *DC and Nyquist*: a constant of 1 and a ±1 alternation: largest \|X\| 1.307·10⁻² against the definition's 1.308·10⁻², and 8.64·10⁻³ against 8.66·10⁻³; behind their onsets 60 dB and 80 dB down in the stress test.
  - *full scale*: a ±1 square, finite, peak 1.226.
  - *non-finite input*: NaN, +∞, −∞ samples give exactly the transform of the signal with them zeroed (source adapter, NUM-1).
  - *finite input above full scale*: one sample of 10¹⁰ … 10²⁰ in silence: finite in every octave; one of 10²⁵ (also 10³⁰, 10³⁵): 8 526 … 9 216 of 40 824 values NaN, more than the 5 832 values the highest octave holds in 81 frames, so the lower octaves have them too, although the decimated signal is finite (one decimator on the click of 10²⁵: 30 000 finite samples, peak 5·10²⁴); noise of 10³⁰ … ±greatestFiniteMagnitude: 23 616 … 23 712 NaN. **A-6.**
  - *state across blocks*: block sizes 1, 37, 512, 1 024, 1 025, 4 096 give the frames of 441-sample blocks bit for bit (values 0.0 apart, times within 2.2·10⁻¹⁶ s, indices equal); two passes with a reset between them are equal (50 frames each); two channels under `.mixdown` equal the transform of their mean exactly.
  - *Int arguments of `makeNode`* (`VA_T08`): `hop` Int.min, −1, 0, 100 refused with the nearest legal hop, Int.max − 63 refused ("above the longest supported"), **Int.max traps (A-4)**; `channel`, `channelCount`, `maximumBlockFrames` at Int.max, Int.min, 0, −1: a node is made every time, except `maximumBlockFrames` Int.max with two channels ("Could not allocate a buffer of 9223372036854775807 elements"): B-7. *Double* (`sparsity` ±greatestFiniteMagnitude, NaN, ±∞): refused; subnormal and ±0: a node.
  - *many octaves*: the stress test reads the corners of `StressFixture.filtersNearZero` (7, 10, 12 and 10 octaves, atoms up to 987 622 samples) within 0.5 dB; the geometry admits up to 32 octaves, but no hop is legal from 26 on (A-5, WP-519).
- **ALG — currency.** `Docs/Numerics/constant-q-transform.md` lines 1-3 (the check of 2026-11-15 against §7.2 row 13: Schörkhuber & Klapuri 2010, Brown & Puckette 1992; alternative Holighaus et al. 2013) and `currency-2026-11.md` row 13: "Current". Checked as a record (no network).
- **ALG — stability note, mutated.** The note covers WP-521 and WP-522a; its two changes were made in this checkout (`VerifierA/scripts/mutate.sh`), the named tests run, each file restored and compared byte for byte:
  - M6 — `Nodes/ConstantQNodes.swift`: `let first = (octaves &- 1 &- depth) &* rowCount` → `let first = depth &* rowCount` (the octaves written highest first). `theTransformOfEveryStressSignalIsFiniteAndThatOfTheDefinition()` (7 issues, "worst <= 0.03 * peak") and `theLongestAtomsOfTheLibraryAreReadFromSignalsHalvedAThousandTimesOver(index:)` (all 4 cases, 12 issues) fail, and with them `aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude()` (217 issues), `aToneBetweenTwoBinsIsSharedByThem()` (9) and `theTransformOfTheFixturesIsThatOfTheDefinition(name:)` (4 cases, 9 issues), as the note says. Restored, `cmp` identical.
  - M7 — `ConstantQ/ConstantQSchedule.swift`: `let firstEnd = delay + span - span / 2` → `let firstEnd = span - span / 2` (`firstEnds` without `delays`). `everyOctaveOfAFrameIsCentredOnTheSameSample(octaves:hop:)` (4 cases, 2 155 issues) and the golden comparison (4 cases, 9 issues) fail, as the note says. Restored, `cmp` identical. Logs: `.build/logs/mutation-M6.txt`, `mutation-M7.txt`.
- **Tolerances.** None loosened against the stated figures (the snapshot has no history to compare with): 0.5 dB for the tones (§6.8), 1 % of the excerpt and per frame on average for the fixtures at sparsity 0.01, 3 % of the definition's largest magnitude in the stress test, 0.98 for the cosine.
- **STG-1.** The package adds no step: the recursion is inside `ConstantQ` (WP-521), whose STG-1 items are graded in `WP-521-A.md`. What belongs to the recursion, the node, is audited: `ConstantQTests/theNodeRunsWithoutAllocating()` and the full-analysis audit `FullAnalysisAuditTests` pass in every run.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-8 | VIS-2 (brief, lesson 1) | `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQStrategy.swift:121` `MultirateSparseKernelStrategy.makeNode(of:hop:window:sparsity:channel:channelCount:maximumBlockFrames:)` | A public function with no documentation comment of its own. The requirement it witnesses (`:28-47`) says "Control context: it allocates, designs and transforms", but the conforming type's statement (`:69-70`, "An immutable value, usable on any thread") does not say that its witnesses follow the requirements, and says nothing of allocation. Scan: `python3 -I -B VerifierA/scripts/doc-scan.py` ("NO DOC COMMENT", `VerifierA/out/doc-scan.txt`). The type, its initialiser and its static members are graded under WP-521 (A-7). Resolve: a comment on the witness that states the context and that it allocates, or the sentence of CR-A1 on the type | blocking |
| A-6 | NUM-1 | `Nodes/TransformPlans.swift:52-60`, reached through the node of this package for every octave | Finite samples in, NaN out, in the lower octaves as in the highest: see `WP-521-A.md`. One finding with WP-521; one fix | blocking |
| A-4 | §9.3 | `ConstantQ/ConstantQSchedule.swift:108-112` (WP-519's code), reached through `makeNode(…hop: Int.max…)` | `makeNode` with hop Int.max ends the process (`trap-T08.log`; `VA_Repro/r522a_makeNodeOfHopIntMaxTraps()`: "Crash: xctest"). One finding with WP-519, 521, 522b and 524; evidence and resolution in `WP-519-A.md` | blocking |

Backlog (non-blocking):

- B-7. `makeNode` checks neither `channel` against `channelCount` nor either of them nor `maximumBlockFrames` against 1 (`ConstantQStrategy.swift:130`, `ChannelMixer(channel:channelCount:maximumFrames:)`): Int.max, Int.min, 0 and −1 all give a node (`trap-T08.log`). `ConstantQ` itself is always given valid values by the engine, so only a client that calls the strategy directly can do this, and running such a node was not probed. The requirement says the node is for "blocks of samples" with those channels; a refusal with a reason would match `sparsity`, which is refused.

## Change requests filed (FIX-4)

None for this package (the VIS-2 reading for protocol witnesses is CR-A1, in `WP-521-A.md`).
