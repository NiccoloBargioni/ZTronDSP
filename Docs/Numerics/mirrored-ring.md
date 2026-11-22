Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 2, "Framing: double-mapped ring; a window is a contiguous view", no external source registered; alternative: copy on wrap). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 2. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Mirrored ring storage (WP-203)

Stability register row 2. Code: `Sources/CZTronDSP/ztd_ring.c`. Tests: `Tests/CZTronDSPTests/RingTests.swift`.

## Hazard

There is no arithmetic in a ring: frames are copied, never computed. What can go wrong is structural.

1. **The mirror is not a mirror.** With mirrored storage every channel is mapped twice in a row (`vm_remap`), and a window that wraps is read and written straight through the second view. If the second view is not the same physical memory as the first, frames written across the wrap are lost and frames read across it are whatever the pages held.
2. **The mirror is refused.** `vm_remap` may fail (§13.1). A ring that then failed, or that behaved differently, would make the engine depend on what the system allowed.
3. **Index overflow in long sessions.** A position counter that wraps at 2³² frames does so after 24.8 hours at 48 kHz. In the ring itself such a wrap would be harmless: a count of frames in the ring is a difference of the two positions taken modulo 2³², and an index is a position masked by a capacity (a power of two, at most 2³⁰) that divides 2³². What a wrap would break is an absolute count: the overrun count (`ztd_ring_overrun_frames`), and the frame index of the framer that reads the ring (`Framer`, a Swift `Int`).
4. **First-touch faults.** An untouched page is mapped on first access, by the kernel, on whichever thread touches it: on the I/O thread that is a stall (RT-9).

## Bound or measured behaviour

Exact: the ring delivers the frames it was given, bit for bit, including NaN, both infinities, subnormal values and a tail decaying to zero. Shown by `RingStorageTests.mirroredAndPlainRingsGiveTheSameResultsBitForBit` on the fixtures `StressFixture.nonFiniteSignal` and the `denormal` and `decaying-tail` signals of `StressFixture.signals` (WP-016): the same seeded sequence of 40 pages of writes (planar and interleaved), overruns and reads on a mirrored and on a plain ring gives the same counts and the same bit patterns.

On the simulator of the toolchain of §3 the mirror is granted, a window of the whole capacity that starts in the middle of the storage is contiguous, and every page of both views is resident as soon as the ring exists (`storageIsResidentAsSoonAsTheRingExists`, by `mincore`). Whether a device grants the mirror is a device check of WP-904b.

## Mitigation

- The second view is mapped with `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`, in one step, so no other allocation can land in the gap; and it is **proved** when the ring is created: every page is written through one view and read through the other, both ways. A mapping that fails the proof is discarded.
- **Automatic fall-back** to plain storage, which copies in two pieces on wrap. An automatic ring takes the capacity a mirrored one would have whether or not the mirror is granted, so its behaviour (when it overruns, what it holds) does not depend on the system's answer. The fall-back can be forced (`ZTD_RING_STORAGE_PLAIN`) and is tested that way (`theFallBackIsForcedAndCopiesOnWrap`); and the automatic path itself is tested by refusing the mapping, and then the mirror of each channel in turn, to a ring that asked for automatic storage (`CreationFailureTests.theRingSurvivesEveryRefusalAndAnAutomaticOneFallsBack`): it comes back plain, with the capacity of a mirrored ring, and works. The same refusals fail a ring that demanded the mirror.
- Positions are **64-bit counts** of frames ever written and ever consumed; an index is the count masked by the power-of-two capacity. 2⁶⁴ frames is twelve million years at 48 kHz. The overrun count is 64-bit too. `RingStorageTests.aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount` takes both positions of a ring of 2²⁰ frames past 2³² (4.297·10⁹ frames, with a lap that is no divisor of 2³²) and checks the laps that straddle it bit for bit on the non-finite fixture of WP-016, on both kinds of storage; then it overruns the full ring by 2·(2³² − 1) frames and finds every one counted (8.590·10⁹).
- The proof above touches both views of every page, writing, when the ring is created; plain storage is zero-filled then.

## Stress test

`RingStorageTests.mirroredAndPlainRingsGiveTheSameResultsBitForBit`, with `aWindowSpanningTheWrapIsContiguousAndCorrect` beside it. With the remap and its proof removed (the second view left as the untouched second half of the allocation) both fail: the window across the wrap no longer holds what was written, and the mirrored ring's output departs from the plain ring's. Checked by making exactly that change, 2026-11-15, and again on 2026-11-21 (register audit, WP-905a): six tests fail, among them both of these, the two-thread tests and the refusal test.

The other mitigations, mutated one at a time on 2026-11-21: refusing the fall-back to an automatic ring fails `CreationFailureTests.theRingSurvivesEveryRefusalAndAnAutomaticOneFallsBack`; rounding an automatic ring's capacity to whole pages only when the mirror is granted fails it and `anAutomaticRingMirrorsWhenTheSystemGrantsItAndHoldsTheSameEitherWay`; leaving the pages untouched at creation fails `storageIsResidentAsSoonAsTheRingExists` for either storage (every page not resident); a 32-bit overrun count fails `aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount` (4 294 967 294 counted). Two mutations survive, and cannot be caught: 32-bit positions, which are equivalent for the reason given under hazard 3 (the test of a session past 2³² passes with them), and the proof's two comparisons removed with the remap kept, which only matter where `vm_remap` reports success for a mapping that is not a mirror, and no test can make it do that.
