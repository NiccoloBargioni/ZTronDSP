# Verifier report — WP-110b, lens A

| Field | Value |
|---|---|
| Package | WP-110b — Frame types `RealFrame`, `ComplexFrame`, `ScalarFrame`, `EnvelopeFrame`: borrowed views with index and time |
| Lens | A |
| Verifier | A (agent); not the implementer, not the other verifier, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-16 04:05, after CR-022 (the files of these packages have not changed since) |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`briefs/21-verifier-a-m1.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified: `Domains/Frames.swift` is byte-identical with the main tree. `StorageAndDomainTests.swift` differs from the main tree's copy (16 Nov 04:39, after the snapshot) by one trait on a WP-105 test only; the `FrameTests` suite is the same. The main tree's `Tests/CompileFixtures/invalid` (133 files) has no fixture on frames either
- [ ] The test, lint and coverage output: not handed over; tests and gates were run by the verifier, coverage was not measured (lens T)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning beyond what the tree holds (see `VerifierA/README.md` for its disclosures)

## Acceptance checks run by the verifier (VER-3)

Runs (simulator `ztdsp-27-vm1a`, iOS 27.0; logs in `.build/logs/`; scripts in `VerifierA/`, see its README):

- **[D]** `VerifierA/run-m1.sh a2-debug-1 test`: the 25 M1 suites, Debug, 142 tests, all pass. **[D3]** `ZTD_XCARGS="-test-iterations 3" VerifierA/run-m1.sh a2-debug-x3 test` after every seeded change was restored: Debug, 142 tests × 3 repetitions, all pass (27.6 s); this is the build left in `.build/xcode`.
- **[R]** `ZTD_CONFIG=Release VerifierA/run-m1.sh a2-release-1 test`: Release, 142 tests, all pass.
- **[P]** `VerifierA/run-probes.sh` (Debug, and `ZTD_CONFIG=Release`): `VerifierA_Values/confirmFramesAreBorrowedViews()` (`VerifierA/Tests/VerifierAProbesArchitecture.swift`), passes in both.
- **[F]** `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --valid VerifierA/fixtures/valid --invalid VerifierA/fixtures/invalid`: "3 valid fixtures compile, 4 invalid fixtures fail with their sentences" (`.build/logs/a2/fixtures-verifierA.txt`).
- **[G]** `Scripts/lint-bans.sh`: clean (parts 1–4, 448 files). `Scripts/api-digest.sh --check`: 10 digests equal the built modules.
- **[C]** `VerifierA/doc-coverage.sh` on the Debug build (`.build/logs/a2-doc-coverage.txt`).

| Check | How it was run | Result |
|---|---|---|
| A view reads its storage without copying | tree `FrameTests` (`aViewReadsItsStorageWithoutCopying`, `complexFramesAreSplit`, `sampleFramesWrapABlock`, `envelopeFramesHoldPairs`, `readingAFrameAllocatesNothing`, …; `StorageAndDomainTests.swift:284–372`) [D][R]; [P] a real, a complex and an envelope frame over one `AlignedBuffer`: each view's base addresses are the storage's own, a write to the storage after the views were made is seen through all three, and 1 000 rounds of making three views and reading them allocate nothing. Sizes: `RealFrame` 32 bytes, `ComplexFrame` 48, `EnvelopeFrame` 48, `FrameView` 72 (pointers and scalars, no reference); `ScalarFrame` 8 | pass |
| Lifetime rules documented | `Frames.swift:22`, `:40–41`, `:60–61`, `:108`: "a borrowed view, valid for the call that delivers it; copy what must outlive it" | pass |
| Lifetime rules tested | No test of the tree and no compile fixture checks them: the frame suite has no test that a view cannot be kept or sent (`grep -n -i -E 'lifetime\|outlive\|Sendable\|valid for' ` over `StorageAndDomainTests.swift:284–372` finds nothing), and no fixture of `Tests/CompileFixtures/invalid` names a frame type. [F] what such a test would check, run by the verifier: `WP-110b-BorrowedViewsAreNotSendable.swift` fails with its six sentences (`RealFrame`, `ComplexFrame`, `EnvelopeFrame`, `FrameView` and `AudioBlock` "does not conform to the 'Sendable' protocol"; "capture of 'frame' with non-Sendable type 'RealFrame' in a '@Sendable' closure"), while `ScalarFrame` is `Sendable` (CR-005); `WP-110b-ABorrowedViewCanStillBeSentToAnotherTask.swift` compiles (A-24) | **missing** (A-23) |

## Lens checklist (§11.5)

- **A — API, architecture, platform.** Names and shapes per §4–§8. Strategy and Decorator conformance. DEP, EXT and VIS rules. Immutability and no configuration objects (IMM, API-6). Sendable, concurrency and background rules (§9.2). Availability (PLAT-1). UIKit boundary (§8.6). Approval-gated API (§9.5). Typed errors. Public API documented with its threading contract.

- Names and shapes per §5.2 and §5.11.1: `RealFrame` (values, index, time), `ComplexFrame` (split real and imaginary), `EnvelopeFrame` (minima, maxima), `FrameView` with its typed accessors, and `FrameFormat`. `ScalarFrame` is a plain `Hashable`, `Sendable` value of `value` and `confidence`, its index and time on the carrying `FrameView`: CR-005 describes the code accurately (probe: `ScalarFrame(value: 3).confidence == 1`, `ScalarFrame.none` is 0 with confidence 0). The digest is unchanged [G].
- VIS-1: the frame accessors are `public` and `@inlinable` and `FrameView`'s storage is `@usableFromInline` internal (`Frames.swift:121–142`), as the table of §5.11.2 sets for frame accessors. IMM: `let` properties only; no configuration object, no Combine, `AnyView` or UIKit.
- Concurrency: the views are not `Sendable`, so a `@Sendable` closure cannot take one ([F]); a detached task still can (A-24).
- Documentation: the four view types state the lifetime rule and `FrameView` that reading allocates nothing (`:110`); gaps are A-25.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-23 | §12 acceptance "lifetime rules documented and tested": the test is missing (§11.6) | `Tests/ZTronDSPCoreTests/StorageAndDomainTests.swift:284–372`; `Tests/CompileFixtures/invalid/` | The rules are written (`Frames.swift:22`, `:40–41`, `:60–61`, `:108`) but nothing tests them: no test, no must-not-compile fixture. The behaviour that can be checked by the compiler is right ([F]). Reproduce: [F], and the search above. Resolve: add a must-not-compile fixture such as `VerifierA/fixtures/invalid/WP-110b-BorrowedViewsAreNotSendable.swift`; for what the compiler cannot check (A-24), say so in the documentation. | blocking |
| A-24 | Concurrency (§9.2), lifetime of borrowed views; also WP-104 (`AudioBlock`) | `Frames.swift:23`, `:42`, `:62`, `:111`; `Signal/AudioBlock.swift:3–10` | Under Swift 6 a `Task.detached` closure is `sending`, not `@Sendable`, so it can take a `RealFrame`, an `AudioBlock` or a `FrameView` and use it after the call returned: `WP-110b-ABorrowedViewCanStillBeSentToAnotherTask.swift` compiles. Only the documentation keeps a view inside its call (`AudioBlock.swift:5–6` says "Blocks are not `Sendable`", which is true and does not prevent this). Reproduce: [F]. Resolve: say in the lifetime comments that a task must not be given a view. | non-blocking |
| A-25 | VIS-2 | `Frames.swift:8–12`, `:24`, `:31`, `:37`, `:43–46`, `:49`, `:63–66`, `:69`, `:112` | 17 of 48 public symbols have no documentation comment: `ScalarFrame.value`, `.confidence`, `init(value:confidence:)`; `RealFrame.values`, `init`, `count`; `ComplexFrame`'s four properties and `init`; `EnvelopeFrame`'s four properties and `init`; `FrameView.kind`. `ScalarFrame` states no threading contract; the views state their lifetime, which is the context rule. Reproduce: [C]. | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None.
