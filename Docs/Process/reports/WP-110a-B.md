# Verifier report — WP-110a, lens T

| Field | Value |
|---|---|
| Package | WP-110a — Signal domains, `SampledSequence`, the sink-capability protocols, run-time `DomainTag` |
| Lens | T (tests and coverage): the second lens of the package's row in §12 |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-16 04:05, after CR-022. Compared with the main tree again when filed: the 25 M1 source files are unchanged; of the seven M1 test files only `StorageAndDomainTests.swift` has changed, at 04:39, by one trait on `storageIsFreedWithTheBuffer` (`.disabled(if: AllocationAudit.isUnderThreadSanitizer, …)`), which changes no assertion and moves the lines after :82 down by one. Line numbers here are the snapshot's |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced again by the verifier in that checkout)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs: iOS 27.0 simulator `ztdsp-27-vm1b` (Xcode 27.0, Swift 6.4), `Scripts/xc.sh`, mostly through `VerifierB/run-m1.sh` (the 25 suites of the M1 rows, 142 tests). `Sources/` and `Tests/` were compared with the main tree on arrival, and byte for byte with the copy then taken (`.build/vb2/pristine`) after every change. Baseline from the tree as received: the 142 tests pass in Debug and in Release, five repeats of each without one failure, and again in the last pass (`VerifierB/scripts/final-stage.sh`). Mutations: one line of the implementation changed at a time (`VerifierB/scripts/mutate.py`, four rounds of one line per package; each round restored and compared byte for byte before the next), the 25 suites run, the failures read from the full log (`VerifierB/scripts/failures.py`); a fifth round for this package (`VerifierB/scripts/round5-stage.sh`) also ran the compile fixtures. Coverage: the tree's 46 suites of `ZTronDSPCoreTests` (376 tests; the verifier's left out) under llvm-cov, gated by `.build/covtools/run.sh gate` on the files of the M1 rows. Reproductions: `VerifierB/README.md`.

| Check | How it was run | Result |
|---|---|---|
| Tags are distinct | `SignalDomainTests.tagsAreDistinct` (the 21 domains and a custom tag; values and descriptions); mutation 110a1: `Chroma` takes the tag of `Lags`, SignalDomain.swift:76 | Passes; with 110a1 it fails (2 issues). |
| Conformances equal the tables of §5.2: sampled sequences | `sampledSequencesAreSamplesNoveltyAndScalar` (type and run-time tag); mutation 110a2: `.scalar` is no sampled sequence at run time, :126 | Passes; with 110a2 it fails (1 issue). |
| Conformances equal the tables: "Delivered as" | `framesAreDeliveredAsTheTableSays`; mutation 110a4: a scalar delivered as a real frame, :158 | Passes; with 110a4 it fails (1 issue). |
| Conformances equal the tables: the sinks table | `sinkCapabilitiesFollowTheTable`, `valueKindsFollowTheirProtocols`; mutation 110a3: `Envelope` adopts `RealVectorDomain`, :82; round 5: `Envelope` adopts `ScalarValuedDomain` (:82) and `DomainTag.isScalarValued` is true for `.envelope` (:142); the verifier's fixture `VerifierB/fixtures/invalid/EnvelopeIntoAFloatBinding.swift` | Passes; with 110a3 it fails (1 issue). With round 5 **every test passes** and so do the tree's 99 compile fixtures, while the verifier's fixture compiles: an envelope then goes into a `Binding<Float>`. B-30. |

## Lens checklist (§11.5)

- **T — tests and coverage.** Every acceptance check exists as a test and fails when the implementation is broken; the lines changed to confirm it: SignalDomain.swift:76 (tags: caught), :126 (sampled sequences at run time: caught), :82 (an envelope as a real vector: caught), :158 (delivery: caught), :82 and :142 together (an envelope as a scalar-valued domain, at the type level and at run time: **not caught**, B-30).
  - COV-3: `SignalDomain.swift` 100 % (76 of 76 lines).
  - Deterministic: no randomness, no sleeps.
  - Negative paths: a custom tag is no sampled sequence, no real vector and delivered as a real frame; a complex spectrum is no real vector; decibels are not linear-valued.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| B-30 | T — the acceptance check "conformances equal the tables of §5.2" does not fail when a conformance departs from the sinks table | Tests/ZTronDSPCoreTests/StorageAndDomainTests.swift:249-250, 257; Sources/ZTronDSPCore/Domains/SignalDomain.swift:82, 142 | The sinks table of §5.2 lets `Scalar` and `Novelty` alone into a `Binding<Float>` (O-11). The test asserts "not scalar-valued" for `Samples` and `Chroma` only, at the type level, and for `.chroma` only at run time. With `public enum Envelope: ScalarValuedDomain` (:82) and `self == .novelty \|\| self == .scalar \|\| self == .envelope` (:142), round 5: "Test run with 142 tests in 25 suites passed" (`.build/vb2/mut-r5.out`), the tree's fixtures "6 valid fixtures compile, 93 invalid fixtures fail with their sentences", exit 0 (`.build/vb2/mut-r5-fixtures-tree.out`), and `Pipeline { Envelopes(); Emit(to: level) }` with `level: Binding<Float>` compiles: "FAIL VerifierB/fixtures/invalid/EnvelopeIntoAFloatBinding.swift: it is filed as invalid and compiles", exit 1 (`.build/vb2/mut-r5-fixtures-vb.out`). On the tree as received that fixture fails with "Emit needs a sink that can hold the frames before it" (`.build/vb2/pre-r5-fixtures-vb.out`, exit 0). Reproduction: `python3 VerifierB/scripts/mutate.py round 5`; `ZTD_DEVICE=ztdsp-27-vm1b VerifierB/run-m1.sh test` (passes); `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --valid VerifierB/fixtures/valid --invalid VerifierB/fixtures/invalid` (exit 1); `python3 VerifierB/scripts/mutate.py restore`; `ZTD_DEVICE=ztdsp-27-vm1b VerifierB/run-m1.sh test` (or all of it: `VerifierB/scripts/round5-stage.sh`). Resolution: hold every domain of the table against every column, at the type level and through its tag (21 domains × sampled sequence, real vector, scalar-valued, delivered as), and add the invalid fixture for an envelope into a `Binding<Float>`. | Blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
