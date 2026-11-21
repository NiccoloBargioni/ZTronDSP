# Verifier report — WP-522a, lens R

| Field | Value |
|---|---|
| Package | WP-522a — Octave recursion |
| Lens | R (real-time safety and performance): the second lens of the package's row in §12 ("N, R") |
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

Runs of the batch, cited by all nine reports (commands in `VerifierB/README.md`, logs in `VerifierB/logs/`), on the simulator `ztdsp-27-vm5cb` through `Scripts/xc.sh`: (1) the tree as received, Debug, the batch's eight suites (`ConstantQGeometryTests`, `ConstantQKernelTests`, `ConstantQScheduleTests`, `ConstantQTests`, `ConstantQScaleTests`, `ChromaTests`, `ConstantQOrderTests`, `ConstantQStabilityTests`): 82 tests pass (`debug-run1.txt`); (2) the same with `-test-iterations 3`: every test three times, no failure (`debug-iter3.txt`); (3) the instrumented runs for COV-3, B1 (the whole `ZTronDSPAnalysisTests` target, 420 tests in 41 suites) and B2 (the eight suites): both pass (`cov-B1.txt`, `cov-B2.txt`; per file `cov-gate-B1B2-files.txt`); (4) Release, in a derived-data folder of its own, `-test-iterations 3`: the 82 tests, no failure (`release-iter3.txt`), and the benchmark of WP-520 (`release-benchmark.txt`); (5) the mutations and allocation injections: one Debug build in which each is a single changed line switched on at run time by `ZTD_VB_MUTATION` (`VerifierB/mutate.sh`, `VerifierB/run-mutations.sh`, the diff `VerifierB/mutations/gated.diff`); first a control with none switched on, the eight suites: 82 tests pass (`mut-0.log`); then each in a run of its own (`mutations.txt`, `mut-<id>.log`); (6) the probes of the public entries (audit demand 6): `VerifierB/Probes/VerifierBProbeTests.swift`, public API only, each probe in a test process of its own, in Debug and, for every probe that failed or trapped, again in Release (`probes-Debug.txt`, `probes-Release.txt`); (7) the tree restored (`VerifierB/mutate.sh check`: `Sources` and `Tests` byte for byte the pristine copy), rebuilt, and the eight suites run again in Debug: 82 tests pass (`final-run.txt`); after the last probe (the SEL-6 probe of WP-523) the same once more, on the build the checkout is left with: 82 tests pass (`final-build-2.summary`, `final-run-2.txt`). Gates on the tree as received: `Scripts/lint-bans.sh` (clean, 563 files), `Scripts/api-digest.sh --check` (10 digests equal the build), `Scripts/golden.sh --check` (197 files of 27 generators), `Scripts/check-dependency-graph.sh` (equals §4.2), `Scripts/ledger.sh --check` (289 rows), `Scripts/compile-fixtures.sh --build` (7 valid fixtures compile, 133 invalid ones fail with their sentences), `Scripts/order-matrix.sh --check` (52 stages on 21 domains, 110 cells, the committed matrix current), `Scripts/check-perf-annotations.sh` (all checks pass): all pass (`gates-1.txt`, `gates-2.txt`, `perf-annotations.txt`). No test of the tree as received failed in any run: the flakiness record is empty.

| Check | How it was run | Result |
|---|---|---|
| §6.8 acceptance over all octaves: a tone at a bin centre reads its amplitude within 0.5 dB | `ConstantQTests.aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude` (every bin of every octave, amplitudes 0.02 + 0.005 per octave), `theTransformOfTheFixturesIsThatOfTheDefinition(name:)` (golden `constant_q` transforms, every octave), `theFramesDoNotDependOnTheBlockSize(gamma:)`; `ConstantQStabilityTests.theTransformOfEveryStressSignalIsFiniteAndThatOfTheDefinition`, `theLongestAtomsOfTheLibraryAreReadFromSignalsHalvedAThousandTimesOver(index:)` (7 to 12 octaves, the lowest and the highest bin within 0.5 dB), `noStressSignalAliasesThroughTheDecimators`, `aToneThatWouldFoldOntoABinOfALowerOctaveIsNotSeen` | Pass in runs 1–4 (Debug once and three times, instrumented, Release three times) |
| §6.8, the chroma part (strongest pitch class in every octave; cosine ≥ 0.98) | `ChromaTests.theStrongestPitchClassIsRightForEveryClassInEveryOctave`, `theChromaOfTheFixturesIsThatOfTheReference(name:)` — the transform of this package under the fold of WP-524 | Pass in runs 1–4 (reported in full in WP-524-B.md) |
| Allocation audit (RT-7 layer 3) with the recursion running | `ConstantQTests/theNodeRunsWithoutAllocating()` (7 octaves; 6 octaves with `gamma` 4; 1 000 blocks of 512 after 8 warm-up blocks) | Pass in Debug and Release. Fails with an allocation added in the decimator between two octaves (`ConstantQNodes.swift:143`, injection 12: `ConstantQTests.swift:383`, `ChromaTests.swift:301`), where an octave frame is transformed (`:393`, injection 14) and where a frame is sent on (`:360`, injection 13) (`mut-12.log`, `mut-13.log`, `mut-14.log`) |
| The public entries with extreme arguments (audit demand 6) | `p521_step_extremeSamples(octaves:)` with 3 octaves (16 384 samples of ±greatestFiniteMagnitude, the least subnormal, ±0, constant and alternating), alone, Debug and Release; the counts and numbers of the step as in WP-521-B.md | Subnormal and ±0 samples give zeros in every octave. ±greatestFiniteMagnitude: 99 frames, 3 564 non-finite values of 3 564, every octave (B-7) |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - What the package adds on the analysis thread: the loop over the octaves in `ConstantQNode.process` (`Nodes/ConstantQNodes.swift:328-346`): each octave takes the samples of its rate into its history (`take`, `:371-384`), transforms each frame that becomes complete (`transform`, `:388-398`), and halves the signal for the octave below (`HalfBandDecimator.process`, WP-519) into its own `halved` buffer; the coefficients wait in a ring per octave (`pendingReal`, `pendingImaginary`).
  - RT-2: no allocation, lock, log or `await` (read, and the audit with injections 12–14). One FFT plan serves every octave (`plan.forward` through `any FFTPlan` once per octave frame: see change request A in WP-521-B.md). RT-3: every octave, its history, its ring (`capacity` frames, `:299-304`, from the schedule's lags when the node is made), its decimator and its product are made in `ConstantQNode.init` (`:259-314`); nothing grows while it runs. RT-5: `AlignedBuffer`s and a `let` array of octaves (never mutated: no copy-on-write). RT-6: the decimators flush a sample below 10⁻²⁰ as it enters them (WP-519), so no octave below the highest holds sub-floor state; the rings hold finished coefficients and feed nothing back. RT-1, RT-4, RT-8, RT-9: not applicable.
  - No hidden copies: the signal passes from octave to octave as a pointer (`samples = UnsafePointer(halved)`, `:342`); the frames go out by `memcpy` from the rings (`:355-356`).
  - Complexity (§7.2 row 13): one transform of one length per octave per hop, measured with the counting backend (`r13_oneTransformPerOctavePerHop`): 7 octaves, 0.977 per octave per hop; 4 octaves, 0.998; 6 octaves with `gamma` 5 (a kernel per octave, one transform length), 0.996 (WP-521-B.md). The decimators together cost less than twice the first one (each runs at half the rate of the one above).
  - Setups when the plan is compiled only; SEL-3: one transform length for every octave, chosen when the node is made (`ConstantQStrategy.swift:125`); no size test on the hot path. Benchmark: not asked by this row.
  - Currency (ALG): `Docs/Numerics/constant-q-transform.md` (WP-521, WP-522a) opens with the currency check of 2026-11-15 and points to `currency-2026-11.md` row 13 ("Current", CR-020 item 3). The record is consistent; no network was available to check the literature itself.
  - COV-3 (measured for the T lens of the batch): `ConstantQNodes.swift` 97.92 % (235 of 240), `ConstantQStrategy.swift` 100 %, `Steps/ConstantQ.swift` 100 %.
  - VIS-2: the public symbols of `Steps/ConstantQ.swift` and `ConstantQStrategy.swift` are shared by WP-521, 522a and 522b; their omissions are recorded once, as B-6 in WP-521-B.md.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| B-7 | NUM-1: "No NaN, no infinity" (audit demand 6) | `Sources/ZTronDSPAnalysis/Nodes/ConstantQNodes.swift:390-397`; shared with WP-521, written up in full in WP-521-B.md | Through 3 octaves from 110 Hz, 16 384 samples of ±greatestFiniteMagnitude (constant or alternating): 99 frames, all 3 564 coefficients non-finite, the lower octaves as the highest; Debug and Release. Reproduction: `VerifierB/run-probe.sh repro "p521_step_extremeSamples(octaves:)"`. Resolution: as in WP-521-B.md (or change request B there). | Blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report (change requests A and B are in WP-521-B.md).
