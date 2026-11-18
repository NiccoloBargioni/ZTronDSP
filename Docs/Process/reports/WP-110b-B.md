# Verifier report — WP-110b, lens R

| Field | Value |
|---|---|
| Package | WP-110b — Frame types `RealFrame`, `ComplexFrame`, `ScalarFrame`, `EnvelopeFrame`: borrowed views with index and time |
| Lens | R (real-time safety and performance): the second lens of the package's row in §12 |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-16 04:05, after CR-022. Compared with the main tree again when filed: the 25 M1 source files are unchanged; of the seven M1 test files only `StorageAndDomainTests.swift` has changed, at 04:39, by one trait on `storageIsFreedWithTheBuffer` (`.disabled(if: AllocationAudit.isUnderThreadSanitizer, …)`), which changes no assertion and moves the lines after :82 down by one. Line numbers here are the snapshot's |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced again by the verifier in that checkout)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs: iOS 27.0 simulator `ztdsp-27-vm1b` (Xcode 27.0, Swift 6.4), `Scripts/xc.sh`, mostly through `VerifierB/run-m1.sh` (the 25 suites of the M1 rows, 142 tests). `Sources/` and `Tests/` were compared with the main tree on arrival, and byte for byte with the copy then taken (`.build/vb2/pristine`) after every change. Baseline from the tree as received: the 142 tests pass in Debug and in Release, five repeats of each without one failure, and again in the last pass (`VerifierB/scripts/final-stage.sh`, Debug and Release, with the verifier's tests). Allocation audits were made to bite: `VerifierB/scripts/bites.py` puts one call to `_vbBite()`, an `@inline(never)` function in a file of its own that mallocs and frees 32 bytes, into the path each audit of the M1 rows covers; all nine audits failed in Debug and in Release (`.build/vb2/bites-{debug,release}.out`) and pass again after the restore. The verifier's own audits are the suite `VerifierBAllocationAudits` of `VerifierB/tests/VerifierBProbes.swift`. Disassembly: out-of-line functions in the test module, a client of `ZTronDSPCore` (`VerifierB/tests/VerifierBDisassemblyProbes.swift`), read in the Release test binary by `VerifierB/scripts/disassemble.py` (`.build/vb2/final-disassembly-release.out`). Mutations: one line changed at a time (`VerifierB/scripts/mutate.py`), the 25 suites run, failures read from the full log. Reproductions: `VerifierB/README.md`.

| Check | How it was run | Result |
|---|---|---|
| A view reads its storage without copying | `FrameTests.aViewReadsItsStorageWithoutCopying` (the view's base address is the storage's; a write to the storage is read through the view), `complexFramesAreSplit`, `sampleFramesWrapABlock`, `envelopeFramesHoldPairs`; mutation 110b1 (a real frame views memory one element further on, Frames.swift:154) | Pass. With 110b1 the first test fails (2 issues). |
| Lifetime rules documented and tested | The documentation of each view: `RealFrame` (Frames.swift:21-22: "A borrowed view, valid for the call that delivers it; copy what must outlive it"), and the same rule for `ComplexFrame` (:40-41), `EnvelopeFrame` (:60-61) and `FrameView` (:105-110); `ScalarFrame` is a plain `Sendable` value, and says why (:1-6, CR-005). The tests above show the borrowing; the views hold `UnsafeBufferPointer`s and are not `Sendable` | Documented and tested as far as a run can show it: what a view may not outlive cannot be observed without undefined behaviour. |
| Allocation audit | `readingAFrameAllocatesNothing` (1 000 reads through `FrameView.real`), Debug and Release; the bite in `FrameView.real` (mutation 110b2 is the same change) | Passes. With the bite it fails in both configurations: "found 1000 allocation(s) of 32000 byte(s), 1000 deallocation(s)". |
| Every initialiser and accessor (the verifier's audit) | `VerifierBAllocationAudits.wp110b_everyKindOfFrame`: 1 000 rounds of the four `FrameView` initialisers and the typed accessors that do and do not match, `count`, `channelCount`, `kind`, and the three typed views constructed directly; `wp104_everyAccessorOfABlock` for `FrameView(samples:)` and `.samples` | No allocation, Debug and Release. |
| Hot loops from another module | `vbProbeFrameViewLoop` (a loop over `frame.real`), `vbProbeFrameViewPerElementAccessor` (`frame.real` asked for on every element) | No call in either function; the first loop is vectorised. Reading a frame costs no call per element. |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**
  - RT-2: the views and `FrameView` are structs of pointers, counts, an index and a time; every initialiser and accessor is `@inlinable`; nothing allocates, locks or dispatches dynamically (the audits and the disassembly above).
  - RT-5: hot-path storage is raw pointers; no `Array` in the file.
  - No hidden copies: every accessor wraps the same memory (the address checks above, and 110b1 caught).
  - RT-7(2): the file has no loop.
  - Complexity, benchmark, setups, SEL-3: no row of §7.2 applies, the row asks for no benchmark, the package creates no setup and has one implementation.
  - COV-3: `Frames.swift` 100 % (89 of 89 lines) under the tree's 46 suites.

## Findings (VER-4)

None.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
