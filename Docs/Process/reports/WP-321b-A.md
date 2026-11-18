# Verifier report — WP-321b, lens A

| Field | Value |
|---|---|
| Package | WP-321b — `FeatureStream` (a bounded `AsyncSequence`) and `FeatureCallback` |
| Lens | A (the first lens of the row: A, R) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Simulator `ztdsp-27-va` (iOS 27.0, arm64) on the host of §3. `ZTD_DEVICE=ztdsp-27-va Scripts/xc.sh test ZTronDSPCoreTests` four times in Debug (three runs: 325 of 325 passed; the first run failed one test, `AnalysisThreadTests.aRealTimePullSourceTakesAsLongAsItsSignal`, see WP-319b) and once with `ZTD_CONFIG=Release` (325 of 325 passed). `Scripts/lint-bans.sh`: clean. A "probe" is a test the verifier wrote in the checkout with the package's own test doubles (`TestStages.swift`, `EngineSupport.swift`); its body is given under the finding it supports.

| Check | How it was run | Result |
|---|---|---|
| The oldest frames are dropped and counted when the consumer lags | `FeedTests.aStreamDropsTheOldestAndCountsThemWhenItsConsumerLags` (capacity 4, ten frames: 6, 7, 8, 9 delivered, 6 counted), `aStreamDeliversEveryFrameToAConsumerThatKeepsUp`, `aStreamKeepsVectorsAndComplexFramesWhole` | Debug ×3 and Release ×1: passed |
| No unbounded growth | the same test: 10⁵ more frames with no consumer, the count follows; 1 000 writes inside `expectNoAllocations` | Debug ×3 and Release ×1: passed |
| No Combine | `Scripts/lint-bans.sh` (part 3); `grep -rn Combine Sources/ZTronDSPCore` | Clean; no match |
| `FeatureCallback` runs on the thread that runs the plan | `FeedTests.aCallbackRunsOnTheThreadThatRunsThePlan`, `AnalysisThreadTests.anOfflineSessionDoesNotRunOnTheAnalysisThread` | Debug ×3 and Release ×1: passed |
| A cancelled consumer stops waiting (the type's documentation) | `FeedTests.aCancelledConsumerStopsWaiting` (cancels 20 ms after the start); probe with the cancellation close to the start | The package's test: Debug ×3 and Release ×1: passed. Probe: 283 of 400 consumers never returned (Debug), 49 of 200 (Release) |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Names and shapes: `FeatureStream<Domain>` is an `AsyncSequence` of `FeatureFrame` (CR-015 item 11), `final`, with `capacity` and `droppedFrames` read-only and `finish()`; `FeatureCallback<Domain>` wraps a `@Sendable` closure. Both adopt the public `FeatureSink` as §5.11.1 writes it. No public setter; `FeatureFrame` is an immutable value.
- `@unchecked Sendable` on `FeatureStream` is registered with its contract. One consumer at a time is stated; a second one spins (its wait is resumed at once, `FeatureStream.swift:193`).
- Documentation: both types state their threading contract; `FeatureCallback.init(_:)` and `FeatureStream.Iterator` have no comment of their own.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | The type's contract ("it ends when the consuming task is cancelled"); §9.2 concurrency | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:182-204` | A consumer that is cancelled between its cancellation check and the installation of its waiter is never resumed: 283 of 400 in Debug and 49 of 200 in Release with the cancellation close to the start of the loop. After `stop()` or `detach()` nothing else resumes it, so the task and what it holds stay for ever. | blocking |
| 2 | §9.3: no trap reachable from public API through invalid input | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:55` | `DSPEngine(blockSize: 64).attach(Pipeline().emit(to: FeatureStream<Samples>(capacity: Int.max)), to: …)` ends the process on the control queue (arithmetic overflow in `Storage.init`, crash report `xctest-2026-11-15-184047.ips`). `claim` can throw; the sizes are multiplied unchecked. | blocking |
| 3 | RT-4 (the other lens of this package) | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:123-159, 213-238` | The ring is validated like the feeds' column store, by counters loaded after the copy with no barrier; see WP-333, finding 1. Not stressed separately. | non-blocking |
| 4 | Counting of drops | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:271-284` | When a stream is claimed for frames of another shape, the frames the consumer had not taken are discarded with the old storage and are not counted in `droppedFrames`. | non-blocking |
| 5 | G-13 for sinks | `Sources/ZTronDSPCore/Feeds/FeatureStream.swift:266-299` | The stream is woken through the internal `PlanSink`; see WP-321a, finding 1. | non-blocking |
| 6 | COV-3 (lens T of the row; definition of done, item 3) | `xcrun llvm-cov report` on the profile of the core tests | `Feeds/FeatureFrame.swift` 46.0 % of 37 lines, `Feeds/FeatureStream.swift` 93.0 % of 287; `FeatureCallback.swift` 100 %. The coverage gate itself measures nothing in this snapshot (see WP-317, finding 3). | non-blocking |

**Finding 1, to reproduce or resolve.** Probe (`Flag` is one `ztd_atomic` word in a class):

```swift
var hangs = 0
for round in 0 ..< 200 {
    let stream = FeatureStream<Scalar>()
    try stream.claim(axis: nil, environment: DSPEnvironment(), domain: .scalar, format: .scalar)
    let started = Flag(), done = Flag()
    let consumer = Task.detached { started.value = 1; for await _ in stream {}; done.value = 1 }
    while started.value == 0 {}
    var spin = (round &* 7_919) % 600; while spin > 0 { spin -= 1 }   // lands the cancellation at varying points
    consumer.cancel()
    if !(await eventually(timeout: 0.5) { done.value == 1 }) { hangs += 1; stream.finish(); _ = await consumer.value }
}
#expect(hangs == 0)     // 283 of 400 in Debug, 49 of 200 in Release
```

Cause: `next()` checks `Task.isCancelled` at `FeatureStream.swift:183` and installs its waiter at `:190-197` without looking
again; a cancellation in between runs `onCancel` (`:199-201`) before there is a waiter to resume. The consumer then waits
until a frame is written or `finish()` is called, which after `stop()` or `detach()` is never. To resolve: check
`Task.isCancelled` inside the locked section that installs the waiter and resume at once.

**Finding 2, to reproduce or resolve.** To resolve: checked multiplication and `DSPError.invalidParameter` (or `resourceAllocationFailed`) from `claim`.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
