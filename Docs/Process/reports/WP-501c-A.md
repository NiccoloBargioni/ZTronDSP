# Verifier report — WP-501c, lens A

| Field | Value |
|---|---|
| Package | WP-501c — `.custom { t in … }`: sampling, equality by probe values, the checks of WIN-3 |
| Lens | A (the first lens of the row: A, N) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs, gates, probes and references are as in `WP-501a-A.md`:

- simulator `ztdsp-27-vm5aa`;
- 211 of 211 passed in each of four Debug runs and one Release run;
- every gate green;
- probes in `VerifierA/probes/`, run and then removed.

| Check | How it was run | Result |
|---|---|---|
| Equal closures give equal descriptions | `WindowTests.customWindowsCompareByTheirProbeValues` compares a window with itself and `Set([a, a])`, and shows that a different closure differs. Probe `equalClosuresWrittenApartGiveEqualDescriptions` uses two closures written apart with the same body: `==`, equal hash and equal text. Pipelines holding them are equal; a different closure gives a different pipeline; the symmetric choice is part of the description | passed |
| A non-finite or all-zero window is a typed error | `WindowTests.aWindowThatCannotBeUsedIsATypedError`: a NaN, 1/(t − 0.25) and zero | passed: these are non-finite or zero in double precision |
| The same, for a window that is finite and not zero in double precision but not in single | Probe `findingWIN3ASingleSampleThatIsNotFiniteIsNotAnError` with `.custom { _ in 1e300 }`. Probe `findingWIN3AWindowThatIsZeroInSinglePrecisionIsNotAnError` with `.custom { _ in 1e-50 }`. Each samples the window, then attaches `STFT(frame: 64, hop: 16, window:)` | **failed (A-2)**. `samples(count: 16)` returns `[inf, …]`; the STFT attaches and emits 16 192 non-finite values of 16 698. The second closure samples to zeros without an error; the STFT attaches and every frame is 0 |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- Names and shapes, against §6.4.2 and `Docs/API/ZTronDSPCore.txt`:
  - `Window.custom(_:)` takes an `@escaping @Sendable (Double) -> Double`;
  - `.symmetric`, `.periodic` and `.logged()`.
- Sampling (WIN-2):
  - at t = n/N, or n/(N − 1) in the symmetric form (`WindowTests.swift:100–101`);
  - once, in double precision.
- Equality: by the 65 probe values, compared by bit pattern, with an equal hash (`Window.swift:41–61`).
- Immutability: `Window` is an immutable `Hashable, Sendable` value. There is no configuration object.
- Typed errors: `samples(count:)` and `doubleSamples(count:)` are `throws(DSPError)`.
- Architecture:
  - DEP: the type lives in `ZTronDSPCore`, as CR-012 records;
  - PLAT-1: only Accelerate calls available on iOS 15;
  - no approval-gated API and no UIKit.
- VIS-2: the type states its contract ("an immutable value, usable on any thread … Sampling allocates; it is not for the analysis thread"), and so does `custom(_:)`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-2 | WIN-3, a numbered rule: "a sample that is not finite; a window that is zero everywhere" are errors at attach time. Also NUM-1 and the acceptance of the row | `Sources/ZTronDSPCore/Toolkit/Window.swift:181` | `return try doubleSamples(count: count).map { Float($0) }`: `Window.checked` (`:277–283`) runs on the double-precision samples only. A closure whose values overflow to ±∞ or underflow to 0 in `Float` passes. Every framing step applies those single-precision samples (`SampledWindow`, `FramingSupport.swift:16–21`), and with `normalization: .none` the taper is those samples. Reproduction: the two `findingWIN3…` probes (see `VerifierA/README.md`). The first fails with 16 192 non-finite values of 16 698 out of an attached STFT; the second with an attached STFT whose every frame is 0 | blocking |
| A-7 | Test quality. Outside this lens; noted because it carries a claim of WIN-2 | `Tests/ZTronDSPCoreTests/WindowTests.swift:112` | `#expect(a == b || a != b, "closures that agree at the 65 probe points are the same window, whatever their text")` is always true, so it checks nothing | non-blocking |

Resolution of A-2:

- Check the single-precision samples as well, for example `return try Window.checked(doubleSamples(count: count).map { Float($0) })`.
- Add the two closures to `aWindowThatCannotBeUsedIsATypedError`.

Resolution of A-7: assert what is meant, or remove the line.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
