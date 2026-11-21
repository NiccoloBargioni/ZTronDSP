# Verifier report — WP-431b, lens A

| Field | Value |
|---|---|
| Package | WP-431b — Equaliser values `BandBoost`, `LowShelf`, `HighShelf` |
| Lens | A (the first lens of "A, N") |
| Verifier | A, an independent agent session: not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/25-verifier-a-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output: this verifier produced it in the checkout (first rows below); coverage is not part of this lens
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the suite "Equaliser values (WP-431b)": `eachResolvesToItsDesign`, `theThreeBandwidthFormsMeanWhatTheySay`, `aBandPastTheLimitIsRejected`, `theStagesAreValuesWithTheirContinuousValues` and `theFluentSpellingAndTheBuilderGiveEqualPipelines` |
| Each resolves to its design | Probes `p431` and `p431b` at 48 kHz: each value resolved through an `IIRSystem`, compared with `EqualizerDesign` called directly. `VerifierA/run-probe.sh p431 p431b && python3 VerifierA/wp431_builders.py` | `BandBoost(center: .hertz(1_000), gain: .decibels(6), bandwidth: .octaves(1), order: 3)` gives the design's second-order sections exactly. In all 96 band-boost designs of the next row, the zero-pole-gain form equals the design's. Shelves at 200 Hz, 3 kHz and 12 kHz (−4, +6 and −9 dB; Q 0.7, slope 1 and slope 0.5), low and high: the zero-pole-gain form equals the design's in 6 of 6. The sections are equal in 2 of 6: the system pairs the same roots itself, and the two cascades' responses differ by at most 1.31e-13 of the peak |
| The bandwidth forms of §6.3.5 | `p431b`: 96 designs (centres 100 Hz, 1, 10 and 18 kHz; `.hertz(0.3·f₀)`, `.octaves(0.7)` and `.q(1.8)`; orders 1, 2, 3 and 6; gains +9 and −14 dB). The two half-gain frequencies are found on each response here and compared with the definition: the width in hertz; f₀·(2^(b/2) − 2^(−b/2)) for octaves; for Q, the Cookbook's α = sin ω₀/2Q, which puts the half-gain frequencies 2·atan(sin ω₀/2Q) apart | Worst relative error of the width: 1.87e-12 (hertz), 4.46e-12 (octaves) and 1.38e-13 (Q). Gain at the centre within 2.31e-12 dB of the request |
| A band past the limit is rejected | `p431b`: 13 bands near the limit 0.49·f_s = 23 520 Hz, orders 1 and 4. Each is built through the system and lowered as a stage by the plan compiler, which is what `attach` runs. `p431`: four more bands | Rejected by both paths: 21 kHz with 1 octave and 22 kHz with 0.5 octave, whose upper half-gain frequencies would be 23 609.7 and 23 549.2 Hz. Both throw `DSPError.invalidParameter` on `bandwidth`: "the band's upper half-gain frequency would be 23609.72… Hz, at or beyond 0.49 of the sample rate (23520.0 Hz): narrow the band or lower its centre". The system's message also names the element. Accepted by both paths: the other 11. For each of those, the measured upper half-gain frequency is below the limit and equals the relation's, for example 23 519.8 Hz for 23 kHz with 0.1 octave and 23 497.7 Hz for 23 450 Hz with 100 Hz. The four bands of `p431` (20 kHz with 1 octave, 23 kHz with 100 Hz, 23 400 Hz with 20 Hz, 16 kHz with Q 2) are accepted, and all lie within the limit |
| Names and shapes (§6.3.5) | The digest `Docs/API/ZTronDSPDesign.txt` (lines 445–446, 487, 501); `Scripts/api-digest.sh --check`; `Scripts/compile-fixtures.sh --build` | `BandBoost(center:gain:bandwidth:order:isActive:)` with `order: Int = 1`, which covers both spellings of §6.3.5. `BandBoost(center:gain:bandwidth:rollOff:rounding:isActive:)`. `LowShelf` and `HighShelf(midpoint:gain:slope:isActive:)` with `slope: ShelfSlope = .slope(1)`, which takes `.slope(_)` or `.q(_)` ("with slope or Q"; `ShelfSlope` is in CR-018 item 11). `Bandwidth` is `.hertz`, `.octaves` or `.q`. The three are `IIRSystemElement`s and stages, `Hashable` and `Sendable`, and not `FIRSystemElement`s: the fixture `DesignEqualizerInAnFIRSystem` fails with "An FIRSystem holds FIR elements". The digests equal the built modules, and the fixtures behave |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes per §6.3.5, as above.
  - Strategy (§5.3): these values take no strategy argument. The bandwidth and the slope are enum values.
  - DEP, EXT and VIS: the gates pass (lint-bans, digest, dependency graph).
  - IMM and API-6: immutable structs with `let` properties; no options object.
  - Sendable.
  - Availability: iOS 15 floor, no `@available` needed.
  - No UIKit, Combine or `AnyView`.
  - Typed errors: a band past the limit is `DSPError.invalidParameter`, whether it is resolved through the system or lowered as a stage.
  - Threading contract: all 49 public declarations of `Stages/EqualizerStages.swift` state theirs.

## Findings (VER-4)

None.
