# Fix cycle 1 — WP-201 … WP-227 (the real-time C layer)

What the implementer changed after the first verification, finding by finding (FIX-1). The
verifiers re-verify this revision: the lens that raised a finding confirms its fix, the other
lens confirms the fix broke nothing in its own domain.

Revision: main tree, 2026-11-17, after both parts of this cycle. `CZTronDSPTests`: 225 tests in 30
suites, Debug and Release (208 in 28 after the first part, 2026-11-15).

## Blocking findings of the first lens (reports `WP-2*-A.md`)

| Finding | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| WP-210 (RT-6) | A channel of the multichannel biquad that fell silent while others carried signal kept subnormal values in `vDSP_biquadm`'s memory for ever | A channel that has been quiet for as long as the cascade has memory, and stays quiet, is parked: it runs on coefficients of zero, which empty its memory within two frames, and its output is exact zeros; it gets its coefficients back before the first block with signal (`ztd_biquad.c`) | `MultichannelBiquadKernelTests.aChannelThatFallsSilentAloneLeavesNothingBehind` (2, 3, 4 and 8 channels), `aParkedChannelWakesOnTheCoefficientsOfTheDay` |
| WP-210 | CR-013 item 1 named a bound the test does not hold | The change request states the bounds the tests hold and the figure measured | — (CR-013 items 1, 2, 6, and new items 9 to 11) |
| WP-220 | The row's check "restoring a 2 001-tap FIR under signal" was missing | The test, with the direct and the partitioned kernel | `SwitchTests.restoringALongLinearPhaseFilterUnderSignalShowsNoTransient` |
| WP-208, 211, 212, 213, 214, 215, 223 (§7.3) | The currency checks confirmed the register against itself | The search was made with network access and is recorded row by row (`Docs/Numerics/currency-2026-11.md`); every note says whether its row was searched; what the search found is CR-020 | — |

## Blocking findings of the second lens (reports `WP-2*-B.md`)

| Finding | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| WP-202, WP-203 ("Thread Sanitizer clean") | The sanitizer reported races between two rings that had lived at one address in turn: it does not follow Mach mappings | The ring tells the sanitizer, when it is in the process, that a new mapping starts afresh (`ztd_ring_announce_new_memory`) | The ring suites, ten times under the sanitizer |
| WP-202 | A seeded race on the frames was not reported: they were moved by a checked `memcpy` the sanitizer cannot see into | The frames are moved with the compiler's own `memcpy`, which the sanitizer instruments (`ztd_ring_copy`) | The seeded race, under the sanitizer |
| WP-202, cross-cutting | Allocation audits failed at random under the sanitizer, whose allocator hides the heap from the probe | `expectNoAllocations` runs its body and audits nothing there; the suites that test the probe itself are disabled there (`AllocationAudit.isUnderThreadSanitizer`) | The whole C target under the sanitizer |
| WP-220 | The check passed with the fade removed: the toggles sat on zero crossings of the probe | The toggles sit where the sine is above 0.8 | `SwitchTests.togglingUnderASineMakesNoClick` |
| WP-221 (ACT-8) | No test noticed an active stage that stopped feeding its delay line | A test that switches a real linear-phase filter off under signal and compares what follows with the delayed input, bit for bit | `LatencyMatchedBypassTests.aLinearPhaseFilterSwitchedOffUnderSignalLeavesTheDelayedInput` |
| WP-226 (RT-9) | `ztd_thread_clear_time_constraint` took a thread without a policy out of its quality-of-service class | A clear without a policy does nothing; a clear after a grant gives the thread the priority it had before; the engine asks for a computation the scheduler grants (50 µs to 50 ms) and ends an older policy when a new request is refused (`ztd_thread.c`, `RunnerThread.applyPolicy`) | `ThreadTests.aClearWithoutAPolicyLeavesTheThreadExactlyAsItIs`, `aClearAfterAGrantGivesTheThreadItsPriorityBack` |
| WP-205, 206, 224 (COV-3) | `ztd_queue.c` and `ztd_plan.c` below 97.5 % | Tests of the plan runner's identity, nested plans and refusals, and of every creation that the system refuses, now that every constructor asks the seam (see the second part below): `ztd_queue.c` 100 %, `ztd_plan.c` 98.73 % (311 of 315 lines), `ztd_engine.c`, `ztd_atomic.c`, `ztd_base.c`, `ztd_ring.c` 100 % | `CoveragePlanTests`, `CreationFailureTests.cellsQueuesSlotsPlansAndParkersSurviveEveryRefusal`, `aSwitchSurvivesEveryRefusal` |

## Non-blocking findings acted on

- `ztd_gain_create` refuses a gain that is not a number, as its header says (`GainKernelTests.creationFailsWithoutChannelsOrWithAnUnknownImplementation`).
- The queues' storage is written once when it is made, so neither end takes a first-touch fault (RT-9).
- `ztd_support.c` and `ztd_fir.c` round a product and a sum one after the other, as the other kernels do: the same floats on every architecture.
- The claim that `mach_absolute_time` does not block stands in the one audited allow-list (`ztd_vdsp.h`).
- The plan runner takes no more channels than the plan was made for, as it takes no more frames.
- The 25 ns dispatch budget is held in a benchmark run only (`PlanTests`).
- CR-013 states what the verifiers measured: the block-size figures of `vDSP_biquad` on other seeds, the partitioned kernel against the exact convolution, the two blocks a cascade needs to reach zero, what the host does to a computation time.

## Second part of the cycle (2026-11-16 and 2026-11-17, before any re-verification)

The coverage closure and the fixes it led to, made by one implementer for this layer and for the engine
(the engine's half is in `fix-cycle-1-WP-315-342.md`). `CZTronDSPTests`: 225 tests in 30 suites, Debug and
Release.

| Subject | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| WP-204, 205, 206 (verifier finding A-10: "every constructor of this target asks") | The constructors of the plan, the queues, the plan slot, the atomic cells, the gain cascade and the parker allocated without asking the seam, so no test could reach their failure branches | Each asks `ztd_may_allocate()`; the seam's counter moved from a thread-local to a pthread key, because the first touch of the thread-local allocated inside audits | `CreationFailureTests.cellsQueuesSlotsPlansAndParkersSurviveEveryRefusal`, `aSwitchSurvivesEveryRefusal`, `theGainCascadeSurvivesEveryRefusalAndAPlanAsAKernelAsksForNothing`, `askingTheSeamAllocatesNothingOnAThreadThatNeverAsked` |
| WP-202, 203 ("Thread Sanitizer clean"), again | The first part's remedy did nothing: the sanitizer does not follow Mach mappings, and the annotation that was to tell it of new memory has no effect, so two mirrored rings that lived at one address in turn still read as a race | The mirror is mapped with `mmap` and unmapped with `munmap`, which the sanitizer follows (`ztd_ring.c`) | `RingStorageTests.aMirroredRingMadeWhereAnotherLivedIsNewMemory`, with two threads that nothing orders: a data race is reported with the old source, none with the new |
| WP-204 (§9.3) | A plan of a size no machine can hold was asked of the system, and zeroed, before anything refused it | `ztd_plan_create` refuses more than 2²⁴ kernels or channels, a channel table more than 2²⁸ samples, before asking for memory | `CoveragePlanTests.aPlanWhoseScratchNoMachineCanHoldIsNotCreated`, `aSwitchWhoseDelayLineCannotBeHadIsRefused`; in the core `PlanSizeRegressionTests` |
| WP-207 (gain cascade; engine finding F8) | A factor that reached 1 was still applied, and a cascade could not hold a factor at rest on 1 and ramp away from it | A factor at rest on 1 is skipped and ramps away again when it is sent another value | `GainCascadeTests` (3 tests) |
| WP-220, 221 (engine findings F3 to F5) | A plan behind the kernel ABI cannot switch a stage inside itself, is sized by the block at its input and sums latencies as if at one rate | The core no longer nests a plan for a group that changes the rate or holds a switch of its own (see the engine's record); the C plan is unchanged in this respect | In the core: `SwitchedGroupRegressionTests` |

Under the Thread Sanitizer the whole C target, the test product's tests and the core's tests pass with no
report (225, 52 and 480 tests; 30 tests of 3 suites are skipped there because the sanitizer's allocator
hides the heap from the allocation probe).

## Not acted on in this cycle

- Benchmarks for the slot, the command queue, the flush, the switch and the pre-roll (lens R asks for one each), and the cost of blocks that are not whole cells in the FIR, decimator and interpolator kernels: to be recorded with the benchmark baseline on a quiet host.
- Notes filed per package rather than per register row.
- `ztd_thread.c` is at 96.88 % (two lines that run only when `thread_info` fails).
