# Verifier report — WP-522b, lens R

| Field | Value |
|---|---|
| Package | WP-522b — Time alignment across octaves; latency |
| Lens | R (real-time safety and performance): the second lens of the package's row in §12 ("N, R") |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

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
| Octaves aligned to the sample | `ConstantQScheduleTests.everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples(filterLength:)` (7 filter lengths), `everyOctaveOfAFrameIsCentredOnTheSameSample(octaves:hop:)` (4 cases), `ConstantQTests.theFramesDoNotDependOnTheBlockSize(gamma:)` | Pass in runs 1–4 (Debug once and three times, instrumented, Release three times) |
| Latency reported | `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore(octaves:bins:hop:gamma:)` (4 cases at 22.05 kHz: with `latency − 1` samples in no frame leaves, with `latency` one does, and so on, each frame stamped with the time of its centre; the strategy, the node and the environment downstream state the same latency, REAL-5), `gammaIsTheLeverOnLatency`; the strategy's latency for the defaults at 48 kHz read through the public API (`p519_latency_sparsity`): 39 335 samples, 0.82 s, as CR-022 item 2 states | Pass in runs 1–4 |
| Cold start and settling (ACT-10) | `ConstantQTests.afterAColdStartTheFramesAreThoseOfAFreshStream(gamma:)`, `whatCameBeforeNoLongerShowsOnceTheSettlingTimeHasPassed` | Pass in runs 1–4 |
| CR-022's planned checks that were not run (two of the three are in this package) | Mutation 5, `ConstantQSchedule.swift:131`, the latency one sample late: `latencies.append(((firstEnd - 1) << depth) - primed + 1)` → `… + 1 + 1`. Mutation 6, `ConstantQNodes.swift:406`, a reset that leaves the frame counter: `emitted = 0` left out. Each switched on alone; `ConstantQScheduleTests` and `ConstantQTests` run | Mutation 5: `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore` fails in all 4 cases (`ConstantQScheduleTests.swift:239`: the frame count at `latency` samples) and `everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples` in all 7 (`:171`); 71 issues (`mut-5.log`). Mutation 6: `afterAColdStartTheFramesAreThoseOfAFreshStream` fails in both cases (`ConstantQTests.swift:346`, `:347`, `:349`: the second pass is not a fresh stream); 6 issues (`mut-6.log`). The third (O-17 removed) is in WP-519-B.md: killed |
| The public entries with extreme arguments (audit demand 6) | The counts and numbers of `ConstantQ` and of the strategy (WP-519-B.md, WP-521-B.md); the alignment adds no public entry | As reported there |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - What the package adds on the analysis thread: the priming of each decimator with its zeros once after a reset (`Nodes/ConstantQNodes.swift:337-340`), the ring of coefficients per octave, the release of a frame when its lowest octave is complete (`while emitted < ready`, `:348-362`) with the time of its centre (`:360`), and `reset` (`:400-408`).
  - RT-2: no allocation, lock, log or `await`; with an allocation added where a frame is released (`:360`, injection 13) the node audit fails in both pipelines (`ConstantQTests.swift:383`, `:388`) and so does the chroma audit (`ChromaTests.swift:301`) (`mut-13.log`). The time is computed with wrapping arithmetic (`emitted &* hop &- origin`), so a long run cannot trap. RT-3: the lags, primes, latencies and the settling time are computed by `ConstantQSchedule` when the node is made, and the capacity of each ring from them (`:299-304`); nothing grows. RT-5: `AlignedBuffer`s. RT-6: no recursive state. RT-1, RT-4, RT-8, RT-9: not applicable.
  - The allocation audit (`ConstantQTests/theNodeRunsWithoutAllocating()`) runs past the latency, so frames are released inside it (> 900 frames for the defaults): passes in Debug and Release.
  - Complexity: the release costs two `memcpy` of a row per octave per frame; the schedule is arithmetic, once per node.
  - Setups when the plan is compiled only: yes; SEL-3: nothing is chosen by size. Benchmark: not asked by this row.
  - The latency is half the longest atom of the lowest octave plus what the decimators above it delay the signal by; the specification says "whose half-atom length is the stage's latency", and CR-022 item 2 describes the difference ("The latency is the moment the lowest octave completes, and is declared: 39 335 samples at 48 kHz with the defaults"). The code does what the change request says: not a finding by itself.
  - COV-3 (measured for the T lens of the batch): `ConstantQSchedule.swift` 100 % (56 of 56), `ConstantQNodes.swift` 97.92 %.
  - VIS-2: `ConstantQSchedule` is internal; the public symbols of the step and the strategy, shared with WP-521 and 522a, are recorded once, as B-6 in WP-521-B.md — among them the witness the latency is read through, `MultirateSparseKernelStrategy.latency(of:hop:window:sparsity:)` (`ConstantQStrategy.swift:88`), which has no comment of its own. It belongs to the strategy of the step, which WP-521 delivers together with the step's latency (STG-1: a step package delivers its latency and settling time; the top octave alone has one), and WP-521-B.md carries the finding. What this package adds, the schedule and the alignment inside the node, is internal (`ConstantQSchedule.swift` and `ConstantQNodes.swift` declare nothing public), so it carries no VIS-2 finding of its own. The trap in the schedule's hop check is recorded under WP-519 (B-5), whose acceptance it concerns.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No blocking finding of this package's own. | — |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
