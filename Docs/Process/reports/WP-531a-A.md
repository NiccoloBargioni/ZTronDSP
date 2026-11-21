# Verifier report — WP-531a, lens N

| Field | Value |
|---|---|
| Package | WP-531a — Streaming `HarmonicPercussive(select:)`: history ring, causal mode (`ALG`) |
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
| ≡ offline on interior frames (causal) | `HarmonicPercussiveTests/theCausalStepEqualsTheOfflineMediansOnInteriorFrames(caseIndex:)` (2 cases), `theThreeComponentsAddUpToTheSpectrum`, `onAComplexSpectrumTheMaskIsAppliedAndThePhaseKept`, `theSeparationIsTheSameOnEitherSide` | Passed in all three runs |
| Independent reference | `check_refs.py masks`: the fixture of `WP-530-A.md` (24 000 samples, `STFT(512, 128)`, kernels 17 and 31), the causal step against masks computed from the running median of the frames so far (frames t − L + 1…t, reflected at the start) and the median along frequency of the same frame | 184 frames; harmonic 1.5·10⁻⁷, percussive 5.3·10⁻⁸, residual 1.3·10⁻⁷ of the frame maximum |
| `ALG` stability note `harmonic-percussive.md` (a cold start must refill the history ring) | M7: `Nodes/HarmonicPercussiveNode.swift:189`, `timeMedian.reset()` removed | `aColdStartRefillsTheHistoryOfTheMedian` fails (4 issues), `theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold` fails (4); restored, `cmp` identical |
| STG-1 | Modifiers `harmonicPercussive(…)` with trailing `isActive:` (`HarmonicPercussive.swift:198`, `:209`); the family in the compile fixtures (`O-02-HarmonicPercussiveAfterComplexConstantQ`, `…AfterDecibels`, `…AfterPower`, `…AfterPowerFluent`, `…AfterSamples`, `…BeginsABranch`, `…InsideIf`, `O-15-HPSSInABranchOfSpectra`); order matrix current; `theNodeRunsWithoutAllocating` (`HarmonicPercussiveTests.swift:356`); `aColdStartRefillsTheHistoryOfTheMedian`; `whatMakesNoSeparationIsRefused`; `theLaneExchangeFollowsTheTableAndAForcedChoice` | Present and passing; causal latency 0, settling of `timeKernel − 1` frames |
| Parameters at their extremes | `VATraps/t19HarmonicPercussiveExtremes()` (kernels, margins, floor, mask power: Int.max, Int.min, 0, −1, even and over-long kernels; ±`greatestFiniteMagnitude`, subnormal, ±0, NaN, ±∞, 10³⁹, 10⁻⁵⁰) | No trap, no NaN; 44 calls refused with `invalidParameter`; margins and floors outside the range of `Float` change the answer: A-20 |
| Large finite values | `VAFollowUps/e16SeparationAboveTheSquareRootOfTheRange()` | Wrong components above 1.8·10¹⁹: A-21 |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - Definition: §6.10, causal mode, H the median of frames t − L_h + 1…t, P the median along frequency of frame t, masks by WP-530; on a complex spectrum the mask multiplies both parts, on magnitudes it returns the component's magnitudes. Read against `HarmonicPercussive.swift:141–180` and `HarmonicPercussiveNode.swift`.
  - Precision: `Float` magnitudes and masks; 1.5·10⁻⁷ against the double-precision definition.
  - Tolerance: 10⁻⁶ in `HarmonicPercussiveTests`; not loosened.
  - Currency: the first lines of `harmonic-percussive.md` and row 16 of `currency-2026-11.md` (row 22 for the inversion of the components): current.
  - Edge cases. The step on spectra (`out/edge-e10-separation-parameters.txt`, `out/trap-t19.txt`) and through the recipe (`out/edge-e11-hpss.txt`, `WP-532-A.md`):

    | Input | Result |
    |---|---|
    | Empty, length 1 (through `HPSS`) | 0 samples |
    | DC, Nyquist, silence, full-scale square (through `HPSS`) | Finite; silence gives zeros |
    | `NaN`, `±∞` samples | Replaced by 0 at the source |
    | Subnormal samples | Zeros |
    | A steady bin (H > 0, P = 0), the causal step (kernels 3 and 3) and the offline function | Harmonic mask 1 for margins 1, 2, 10³⁰, 3.4·10³⁸; 0.5 (soft) and 0 (hard) for 3.5·10³⁸, 10³⁹, `greatestFiniteMagnitude`, where the definition gives 1: A-20 |
    | An isolated value (H = P = 0), the centred step and the offline function | Both masks 0 for floors 10⁻¹⁰, 10⁻⁴⁰, 10⁻⁴⁵ and 10³⁹ (both medians under the floor); soft 0.5 for floors 10⁻⁴⁶, 10⁻⁵⁰, 5·10⁻³²⁴, where the definition gives 0: A-20. The causal step takes its masks from the same `Key` (`HarmonicPercussive.swift:160–163`, read) |
    | Soft power 10⁻⁵⁰, 5·10⁻³²⁴ at the steady bin, the offline function | 0.5, definition 1 (A-18, `WP-530-A.md`); through the step on noise these powers are accepted and the output is finite (`out/trap-t19.txt`) |
    | `timeKernel` 255, `frequencyKernel` 255, on 31 frames of 33 bins | Finite (`out/trap-t19.txt`) |
    | Margins 10³⁹, `greatestFiniteMagnitude` on noise | Harmonic output 0 (P > 0 at every bin, so the definition gives shares under the smallest `Float`); `.residual` with those percussive margins finite |
    | `STFT(frame: 256, hop: 64)` framed causally (its default), the causal step, `InverseSTFT()`, on noise within ±0.5 | Largest sample 70.4 (`out/edge-e15-separation-large.txt`): hazard 5 of `harmonic-percussive.md`, stated on the type (`HarmonicPercussive.swift:39–44`: a causal separation is best framed centred); `HPSS` frames it so and is exact (`WP-532-A.md`) |
    | Noise ×3·10¹⁸ and above, through `HPSS` | Wrong components: A-21 |

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-20 | A result is wrong (§11.4): accepted margins and floors are narrowed to `Float` | `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift:162` (`Float(harmonicMargin)`, `Float(percussiveMargin)`, `Float(floor)`); the same in the offline function, `Separation/OfflineSeparation.swift:96–98` (A-32, `WP-612-A.md`) | Margins are accepted as "a finite factor of at least 1" and floors as finite and not negative. A margin from 3.5·10³⁸ becomes +∞, and ∞·0 at a bin where P = 0 gives the harmonic mask 0.5 (soft) or 0 (hard) instead of 1, on the causal step and offline. A floor of 10⁻⁴⁶, 10⁻⁵⁰ or 5·10⁻³²⁴ becomes 0, so two medians under it are no longer "under the floor" and share 0.5 (soft) instead of 0, on the centred step and offline. | blocking |
| A-21 | NUM-1; a result is wrong (§11.4) | `Sources/ZTronDSPAnalysis/Nodes/HarmonicPercussiveNode.swift:144` (`vDSP_zvabs` forms √(re² + im²) in `Float`: the squares overflow for \|z\| above 1.8·10¹⁹) | `VAFollowUps/e16…`: noise ×s through `HPSS(256/64, 17/17)`, divided by s, against ×1 (peaks 0.36 harmonic, 0.33 percussive). The STFT and its inverse alone are exact at every scale (1.5·10⁻⁷). Up to ×2·10¹⁸ the components agree to 1.2·10⁻⁷; at ×3·10¹⁸ they differ by 0.130 (harmonic, causal), 0.144 (percussive, causal), 0.106 and 0.189 (harmonic and percussive, centred); scaled back, the causal output is −0.043…0.076 at ×10¹⁹ and −0.0011…0.0015 at ×10²⁰ instead of about ±0.36, and the centred output is zero at both. The spectra themselves (bins up to 8.6·10²⁰) are representable. | blocking |
| A-22 | VIS-2: public symbols without their threading contract | `HarmonicPercussive.swift:53` (the type: context stated, allocation not); no `///`: `:69` `activation`, `:71` `init`, `:99` `stageDescription`, `:141` `lower(_:)`; neither context nor allocation: `:182`, `:189` (`buildPartialBlock`), `:198`, `:209` (`harmonicPercussive(…)`); `Order/OrderDiagnostics+Separation.swift:9`, `:14`, `:17` (unavailable overloads, no `///`; CR-VA-4) | `out/vis2-scan.txt`, `out/vis2-contract.txt`, read in the source | blocking |

**A-20, to reproduce.** After the setup of the README: `VerifierA/run-probes.sh 'VAEdges/e10SeparationParameters()'` (`out/edge-e10-separation-parameters.txt`: each line names the input, the definition and the value); on samples, through `HPSS`, `'VAFollowUps/e18HPSSMarginsAtExactZeros()'` (DC 0.5 comes back as 0.25 or 0, an impulse likewise: `WP-532-A.md`). **To resolve:** refuse margins and floors that do not round to a normal `Float` (a margin above `Float.greatestFiniteMagnitude`, a positive floor under `Float.leastNormalMagnitude`), or compute the comparison and the product with the margin in `Double` (CR-VA-1).

**A-21, to reproduce.** `VerifierA/run-probes.sh 'VAFollowUps/e16SeparationAboveTheSquareRootOfTheRange()'` (`out/edge-e16-separation-sqrt-range.txt`). **To resolve:** form the magnitudes with a scaled hypotenuse (scale each frame by a power of two near its largest part, or use a `hypot` that does not square), or scale the frame before `vDSP_zvabs` and back after it. Add a test at ×10²⁰.

**A-22, to resolve.** Document the listed symbols, or state on the type that its members do not allocate.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None of its own. CR-VA-1 (`WP-513-A.md`) and CR-VA-4 (`WP-515-A.md`) concern this package too.
