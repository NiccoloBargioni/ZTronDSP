# Verifier report — WP-320b, lens A

| Field | Value |
|---|---|
| Package | WP-320b — `DSPEngine.attach`; independent state per attachment (ATT-1); sink claims (ATT-5); re-plan on a format change (ATT-4) |
| Lens | A (the first lens of the row: A, T) |
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
| One pipeline on three sources: three independent states | `EngineTests.onePipelineOnThreeSourcesKeepsThreeStates` (one description built in a function of its sink, three `BufferSource`s, each output equal to the offline run of its input) | Debug ×3 and Release ×1: passed |
| A second live writer of one sink is `sinkInUse` and attaches once the first detaches | `EngineTests.aSinkHasOneLiveWriter` (second attachment, the sink in a tap of another pipeline, the sink named twice), `ExecutionTests.aSinkHasOneWriter`, `aSinkThatRefusesItsClaimFailsTheAttachmentAndReleasesTheOthers`; mutation: `try SinkRegistry.claim(added)` removed from `adoptSinks` | Debug ×3 and Release ×1: passed; the mutation fails `aSinkHasOneLiveWriter` at `EngineTests.swift:129, 132` |
| A format change is survived | `SessionUpdateTests.aFormatChangeIsSurvived` (push), `aPullSourceChangesFormatInTheMiddleOfItsStream` (pull), `aPipelineThatCannotRunAtTheNewFormatFails` | Debug ×3 and Release ×1: passed; the pull case has a race, finding 1 |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Names and shapes: `DSPEngine` is `final`, `Sendable`; `shared`, `init(blockSize:crossovers:)` with the defaults of §4.5 and no configuration object (API-6), the two `attach` overloads with typed throws. `blockSize`, `crossovers` and `analysisScheduling` are read-only additions; `init(blockSize:crossovers:drivenByHand:)` is `package` (VIS-1, test hook).
- ATT-3: the environment is resolved per attachment from the source's format (`theEnvironmentIsResolvedFromTheSource`). BIND-4: bindings are read on the main actor between lowering and plan creation (`EngineCore.swift:70-73`).
- CR-015 items 3 and 8 describe the code (a pull source ends the stream of the old format with 0; a source carries the attachments of one engine).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ATT-4: "re-compiles the plan against the new environment and continues"; acceptance "a format change is survived" | `Sources/ZTronDSPCore/Engine/EngineCore.swift:1132-1136, 962-964`; `Engine/Run/HubRunner.swift:185-189` | A pull source that changes format in mid-stream (CR-015 item 3) is sometimes finished early: 2 of 440 free-running streams in Debug stopped after 130 and 194 of 20 002 blocks, state `finished`. With `usleep(3_000)` before `notify()` at `RunnerThread.swift:189`: 30 of 30, and 58 of 60 paced streams. | blocking |
| 2 | ATT-5: "`detach()` releases the claim, and so does an `update(_:)` that drops the sink" | `Sources/ZTronDSPCore/Engine/EngineCore.swift:672-702, 759-765` | After `update(_:)` has returned on a running session, the sink it dropped is still claimed: another attachment that names it is refused with `sinkInUse`, and stays refused for as long as no block arrives. | blocking |
| 3 | §9.3, no trap from invalid input | `Sources/ZTronDSPCore/Signal/AudioBlock.swift` (`AudioBuffer.init`, WP-104), reached from `EngineCore.swift:231` | `DSPEngine(blockSize: Int.max).attach(Pipeline(), to: BufferSource([0, 0], sampleRate: 48_000))` ends the process (arithmetic overflow in `AudioBuffer.init(channelCount:capacity:)`, crash report `xctest-2026-11-15-184052.ips`). `attach` checks `blockSize >= 1` only. The trap is in a package of M1; it is reported here because this is the public entry that reaches it. | non-blocking |
| 4 | BIND-6 across an `update` that races `detach()` | `Sources/ZTronDSPCore/Engine/EngineCore.swift:621-635, 436-437` | `update` captures bindings on the main actor after `exchange` returned; a `detach()` that runs in between has already queued `pump.release()`, so the capture can land after it and the pump keeps the bindings. Read, not run. | non-blocking |
| 5 | COV-3 (lens T of the row; definition of done, item 3) | `xcrun llvm-cov report` on the profile of the core tests | `Engine/EngineCore.swift` 92.1 % of 1 220 lines, `Engine/DSPEngine.swift` 93.3 %. The coverage gate itself measures nothing in this snapshot (see WP-317, finding 3). | non-blocking |

**Finding 1, to reproduce or resolve.** Probe:

```swift
let second = [Float](repeating: 0.5, count: 64 * 20_000)
let source = ScriptedSource(format: SignalFormat(sampleRate: 48_000), pacing: .asFastAsPossible, [
    .samples([[Float](repeating: 1, count: 128)]), .formatChange(SignalFormat(sampleRate: 44_100)), .samples([second])])
let sink = CountingSink<Samples>()
let session = try await DSPEngine(blockSize: 64).attach(Pipeline().emit(to: sink), to: source)
try session.start(); _ = await session.reaches(.finished, timeout: 20)
#expect(sink.frames == 20_002)
```

Debug: 2 of 440 streams ended early (after 130 and 194 blocks); Release: 0 of 40. With one line of schedule perturbation,
`usleep(3_000)` before `notify()` at `RunnerThread.swift:189`, 30 of 30 streams end early, and 58 of 60 with
`pacing: .realTime`; the package's own `aPullSourceChangesFormatInTheMiddleOfItsStream` still passes then, because its
second stream is over before the stale notice is read. Cause: the stream of the old format ends by returning 0, which sets
the hub runner's `ended` word (`HubRunner.swift:185-189`); when the `.formatChanged` event reaches the control context first
(`EngineCore.swift:962-964`), the hub is re-planned and goes on, and the `service()` that follows reads the stale word, finds
the source's format equal to the hub's and calls `finishStream` (`EngineCore.swift:1132-1136`). To resolve: clear the word when
a re-plan publishes a stage of a new epoch, or carry the epoch in it.

**Finding 2, to reproduce or resolve.** Probe (the same in Debug and Release):

```swift
let engine = DSPEngine(blockSize: 64)
let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000))
let sink = CollectingSink<Samples>()
let session = try await engine.attach(Pipeline().tap { $0.emit(to: sink) }, to: source)
try session.start(); source.write([Float](repeating: 0.5, count: 64))     // wait until sink.samples.count == 64
try await session.update(Pipeline())                                      // drops the sink
_ = try await engine.attach(Pipeline().emit(to: sink), to: BufferSource([0, 0], sampleRate: 48_000))   // sinkInUse
```

The second attachment is refused right after `update` has returned, and still 300 ms later while the source runs without
delivering; it succeeds once another block has been written. Cause: the claims of dropped sinks are released in
`completeExchange` (`EngineCore.swift:759-765`), which happens only after the runner has taken the new plan at a block
boundary; `exchange` (`EngineCore.swift:672-702`) completes at once only for a session that is not live. The package's test
(`aBranchThatGoesTakesItsSinkAlong`) feeds blocks and drains before it attaches again. To resolve: retire the sink in the
running plan and release the claim before `update` returns (as is done for a sink that moves), or state in a change
request that the claim goes with `.replanned(.update)`.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
