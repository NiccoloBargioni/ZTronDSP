# Verifier report — WP-501c, lens N

| Field | Value |
|---|---|
| Package | WP-501c — `.custom { t in … }`: sampling, equality by probe values, the checks of WIN-3 |
| Lens | N — numerical correctness (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`briefs/30-verifier-b-m5a.md` of the hand-over)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: Debug and Release runs, the gated mutations, llvm-cov through `.build/covtools`)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| Equal closures give equal descriptions | `WindowTests/customWindowsCompareByTheirProbeValues()`, Debug 4 runs, Release 1 run. Then equality by the identity of the probe storage, which is what comparing closures as instances gives (`Window.swift:55`, `VB_MUT=m501c`), with `ZTronDSPCoreTests`, `ZTronDSPAnalysisTests` and `ZTronDSPDesignTests` run whole | passes — and **every package test passes with the change** (Core 484, Analysis 424, Design 334; the only failures are the verifier's probes). Finding 2 |
| The same, by the verifier | `VerifierBCoreProbes/vbTwoSeparatelyWrittenEqualClosuresAreOneWindow()`: two closures written apart, `0.5 - 0.5 * cos(2 * .pi * t)` twice | on the code as delivered: equal, equal hashes, one element in a `Set`, equal descriptions, forms and logging compared too. With `m501c`: fails (3 issues). The product is right |
| A non-finite or all-zero window is a typed error | `WindowTests/aWindowThatCannotBeUsedIsATypedError()` (zero everywhere, NaN, an infinity, no sample, a Hann window of one sample) | passes; these are all caught in double precision |
| The same in the precision a step uses | `VerifierBCoreProbes/vbASingleSampleThatIsNotFiniteOrAWindowThatIsZeroInSinglePrecisionIsRefused()` and `VerifierBProbes/vbAnSTFTWhoseSinglePrecisionWindowIsNotFiniteOrZeroIsRefusedAtAttach()` (output `.build/vbprobe/custom-errors.txt`, `stft-window-precision.txt`) | **fails**: `.custom { _ in 1e39 }.samples(count: 64)` returns 64 values of +∞; `.custom { _ in 1e-50 }` returns 64 zeros; a closure of 4·10³⁸ at the centre returns one +∞. `STFT(frame: 256, hop: 64, window: .custom { _ in 1e39 })` attaches and runs: 15 616 of 15 738 output values are not finite; with `1e-50` every value is 0. Finding 1 |
| Sampling at t = n / N and n / (N − 1), once, in double precision (WIN-2) | `aCustomWindowIsSampledOnceAcrossTheFrame()`; the probe `vbWindowSamples()` with `VerifierB/check_windows.py` (custom ramp and custom Hann, 4 forms, counts 1 … 4 096) | pass; the double samples equal the definition exactly, single = double rounded |

## Lens checklist (§11.5)

- **N — numerical correctness.** Result against the definition (WIN-2): exact, as above. Edge cases: one sample (t = 0 for both forms; a custom Hann of one sample is zero and refused, both precisions); NaN probes compare by bit pattern, so a window equals itself; −0 against +0 (finding 3). Non-finite and zero samples (WIN-3, NUM-1): caught before rounding only (finding 1). Precision: the closure is evaluated in double and rounded for the single-precision taper, as WIN-2 asks. No tolerance was loosened (`WindowTests` compares within 10⁻⁶ against the vDSP Hann for a custom Hann, an honest bound for a single-precision comparison). Not an `ALG` row.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | WIN-3 ("Checked, as errors, at attach time: a sample that is not finite; a window that is zero everywhere") and NUM-1 | `Sources/ZTronDSPCore/Toolkit/Window.swift:181`; `Sources/ZTronDSPAnalysis/Steps/FramingSupport.swift:21`, `:30` | `samples(count:)` checks the double samples and rounds them to `Float` with no check after (`doubleSamples(count:).map { Float($0) }`), and `SampledWindow` keeps that array as the taper when the normalisation factor is 1. A closure of 10³⁹ gives a taper of +∞ (64 of 64 samples), one of 10⁻⁵⁰ a taper of zeros; `STFT` attaches with either and emits 15 616 non-finite values of 15 738, or nothing but zeros; `Power(); Decibels()` after it shows −160 dB everywhere, so a spectrogram hides it. With `.amplitude` the taper is computed from the double samples times the factor and is finite. Reproduce: `python3 -I VerifierB/mutations.py apply`, build `.build/xcode-mut`, `VerifierB/run-gates.sh control` (the two probes record issues), then `restore`. Resolve: check the single-precision samples (and every taper) with the same rule, and add both cases to `aWindowThatCannotBeUsedIsATypedError`. | blocking |
| 2 | An acceptance check does not exercise the code ("Equal closures give equal descriptions") | `Tests/ZTronDSPCoreTests/WindowTests.swift:110`, `:112` | The test compares a closure with itself (`a == a`, `Set([a, a])`) and asserts `a == b \|\| a != b`, which is true for any `a` and `b`; no test compares two closures written apart. With equality by storage identity (`m501c`) every suite of the project in Core, Analysis and Design passes; of the 484, 424 and 334 tests run, the only failures are the verifier's probes, among them `vbTwoSeparatelyWrittenEqualClosuresAreOneWindow`. Resolve: assert `a == b`, equal hashes and `Set([a, b]).count == 1` for two separately written equal closures (as the verifier's probe does), and that `a.symmetric == b.symmetric`. | blocking |
| 3 | N, edge case | `Window.swift:53-60` | `.custom { t in t - 0.5 }` and `.custom { t in -(0.5 - t) }` give equal samples at every count (−0 = +0) but compare unequal, because the probes compare by bit pattern (chosen so that NaN equals itself) and differ at t = ½. WIN-2 speaks of closures that "agree": the two do. A pipeline holding one is unequal to one holding the other, so an update rebuilds a node it could keep. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
