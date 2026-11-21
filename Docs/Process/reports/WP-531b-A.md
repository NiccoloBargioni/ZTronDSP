# Verifier report — WP-531b, lens N

| Field | Value |
|---|---|
| Package | WP-531b — Centred mode with look-ahead; latency |
| Lens | N (the first lens of the row: N, R) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`35-verifier-a-m5b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed (the stability notes, the currency record and CR-023 were read as deliverables of the packages)

## Acceptance checks run by the verifier (VER-3)

The runs, the gates and the evidence in `VerifierA/` are those of `WP-513-A.md`: simulator `ztdsp-27-vm5ba`; the 17 suites of the batch, 149 of 149 tests, passed twice in Debug and once in Release; every gate passes on the final build; the tree is identical to the pristine copy after every check.

| Check | How it was run | Result |
|---|---|---|
| ≡ offline | `HarmonicPercussiveTests/theCentredStepEqualsTheOfflineSeparation(caseIndex:)` (3 cases: `music` hop 512 kernels 31/31, `speech` hop 256 kernels 17/31, `music` hop 512 kernels 5/3; every component; each frame against the offline separation bit for bit, the left edge included; as many frames as the spectrogram less the look-ahead) | Passed in all three runs |
| Independent reference | `check_refs.py masks`: the fixture of `WP-530-A.md` (`STFT(512, 128)`, kernels 17 and 31), the centred step against the offline function and against the definition computed with `scipy.ndimage.median_filter(mode='reflect')` | 176 frames of 257 bins for each component, equal to the offline frames 0…175 bit for bit (each frame at its own index); interior frames against the definition: harmonic 1.4·10⁻⁷, percussive 3.7·10⁻⁸, residual 1.4·10⁻⁷ of the frame maximum. The stream holds back 8 = (17 − 1)/2 frames, the look-ahead |
| Latency equals the look-ahead | `theLookAheadIsLatencyAndFramesKeepTheirTimes` (kernel 17, hop 256: latency exactly 8 · 256 / 48 000 s, 8 frames fewer, the times of the frames equal to those of the plain framing to the bit; causal latency 0); on samples, `check_refs.py hpss` (`HPSS`, `STFT(512, 128)`, kernels 17 and 31, centred) | Passed; the recipe's output is the input delayed by 1 408 samples, the declared latency: 384 for the round trip plus 8 hops of 128, the look-ahead; SNR 139.81 dB |
| A cold start | `aColdStartRefillsTheHistoryOfTheMedian` (causal and centred, on magnitudes and on a complex spectrum; centred, the second pass waits for its look-ahead again: 2 · (frames − 8)); M7 (`WP-531a-A.md`) | Passed; M7 makes it fail |
| On a complex spectrum, centred | The step as a delay line of the look-ahead, beginning with frames of silence (`HarmonicPercussive.swift:33–44`), through `HPSS(alignment: .centered)` | The delay and the SNR above |
| Parameters at their extremes | `VATraps/t19HarmonicPercussiveExtremes()` (`timeKernel` Int.max, Int.min, 0, −1, 2, 255, 257 with `.centered`); `VAEdges/e10SeparationParameters()` (floors, centred) | No trap; out-of-range kernels refused; floors under the smallest `Float` change the answer: A-20 |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - Definition: §6.10, centred: H the median of frames t − (L_h − 1)/2 … t + (L_h − 1)/2, reflected at the start; frame t is emitted when frame t + (L_h − 1)/2 has arrived and keeps its own time; the latency the step declares is that look-ahead (`HarmonicPercussive.swift:153`, `let ahead = HarmonicPercussive.lookAhead(…)`, and `:167`, `latency: Double(ahead) / featureRate`); the node settles after `timeKernel − 1 − ahead` frames (`:170`).
  - Precision: the step is the offline separation bit for bit, so its precision is that of the offline function (1.4·10⁻⁷ against the double-precision definition).
  - Tolerance: exact equality in the project's test; not loosened.
  - Currency: `harmonic-percussive.md` and row 16 of `currency-2026-11.md`: current.
  - Edge cases (`out/edge-e11-hpss.txt`, `HPSS(256/64, 17/17, centered)`; `out/edge-e10-separation-parameters.txt`; `out/trap-t19.txt`; `out/edge-e16-separation-sqrt-range.txt`):

    | Input | Result |
    |---|---|
    | Empty, length 1 | 0 samples |
    | DC, Nyquist, silence, full-scale square | Finite (DC 0…0.5, Nyquist ±0.5, square −1.0000002…1.0000001); silence gives zeros |
    | `NaN`, `±∞` samples | Replaced by 0 at the source; finite |
    | Subnormal samples | Zeros |
    | An isolated value (H = P = 0) on the centred step, kernels 3 and 3 | Hard 0 at every floor; soft 0 for floors 10⁻¹⁰, 10⁻⁴⁰, 10⁻⁴⁵, 10³⁹; soft 0.5 for 10⁻⁴⁶, 10⁻⁵⁰, 5·10⁻³²⁴, where the definition gives 0: A-20; floor 0 gives 0.5, the equal share the type documents |
    | `timeKernel` 255 on 31 frames | 0 frames: the look-ahead of 127 frames has not arrived |
    | Noise ×3·10¹⁸ | Harmonic and percussive off by 0.106 and 0.189 (peaks 0.34 and 0.33): A-21 |
    | Noise ×10¹⁹, ×10²⁰ | Zeros: A-21 |
    | Noise ×10³⁰, `FLT_MAX` DC | 3 392 of 4 096 samples NaN: A-25 (`WP-532-A.md`) |

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-23 | VIS-2: a public symbol without its threading contract | `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift:66` (`public let alignment: FrameAlignment`: no `///`, and the type's comment states no allocation) | `out/vis2-scan.txt`, `out/vis2-contract.txt`, read in the source | blocking |
| A-20 | A result is wrong (§11.4): floors narrowed to `Float` | `HarmonicPercussive.swift:162` | The centred step, as above; filed in `WP-531a-A.md` | blocking |
| A-21 | NUM-1; a result is wrong (§11.4) | `Nodes/HarmonicPercussiveNode.swift:144` | Centred, the components are zero from ×10¹⁹; filed in `WP-531a-A.md` | blocking |

**A-23, to resolve.** Document `alignment` (which frames the median is taken over, the latency it brings), with the contract, or state on the type that its members do not allocate.

A-20 and A-21 are reproduced and resolved as `WP-531a-A.md` says.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None of its own. CR-VA-1 (`WP-513-A.md`) concerns A-20.
