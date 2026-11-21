# Verifier report — WP-501f, lens N

| Field | Value |
|---|---|
| Package | WP-501f — `WindowAnalysis`, part 3: main-lobe width, side-lobe level and fall-off, scalloping loss; the overlap-add tests for a hop |
| Lens | N (the first lens of the row: N, T) |
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
- every gate green.

| Check | How it was run | Result |
|---|---|---|
| Reference figures for the stock windows within 0.1 dB and 0.05 bin, as committed | `WindowAnalysisTests.theFiguresOfTheStockWindowsEqualTheReference`, against the golden figures of `window_analysis.py` at frames of 64, 1 024 and 4 096 | passed |
| The same, by the verifier, at other frames | `check_window_analysis.py`, on the probe dump of 10 windows at 64, 333, 1 000, 1 024 and 4 096 samples. It reads the −3 dB width, the null-to-null width, the peak side lobe and the scalloping loss from a transform zero-padded 256 times, finer than the 16 times of WIN-4 | 49 of 50 cases within the tolerance. **Blackman at 1 000 samples: null to null 6.0793 bins against 6.0000 (A-4)** |
| The null-to-null width of the cosine sums at other frames | Probe `nullToNullWidthsOfTheCosineSumsAtOtherFrames(frame:)` at 100, 333, 999, 1 000, 1 001, 1 500, 2 000 and 3 000 samples, against the exact widths. A K-term cosine sum is zero at every whole bin from K on, so the widths are 2, 4, 4 and 6 bins for rectangular, Hann, Hamming and Blackman | **Blackman fails at 7 of the 8 frames (A-4):** 6.0812 (100), 6.0675 (999), 6.0793 (1 000), 6.1061 (1 001), 6.0793 (1 500, 2 000, 3 000); 333 gives 6.037. Rectangular, Hann and Hamming are within 0.05 bin everywhere |
| The overlap-add tests for a hop | `WindowAnalysisTests.overlapAddForAHop`. In `check_window_analysis.py`, for the hop N/4: Σw and Σw² over shifts, the non-zero and constant overlap-add verdicts, the ripple and B/A | passed |

## Lens checklist (§11.5)

- **N — numerical correctness.**

- Definitions, against WIN-4's row "What does its spectrum look like?": a transform of the window zero-padded 16 times. The padded length is the next legal transform length at or above 16N, for example 16 384 for N = 1 000.
- Edge cases: the stress windows (square, DC, Nyquist, denormal) through the stability test. A spectrum without a null or a side lobe gives `nil`, not a number.
- Precision: double precision.
- `ALG`:
  - Currency: `currency-2026-11.md` row 21 and the first lines of `window-spectrum.md` record it.
  - Stability note checked against the code. The mutation the note names (the floor of the powers removed) makes `StabilityTests.theSpectralFiguresOfEveryStressWindowAreNumbersOrNothing` fail with 13 issues: values under −400 dB, as the note says (group M2). Restored, byte for byte.
- No tolerance was loosened, but the golden frames do not exercise the code that fails (A-4).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-4 | A result that is wrong, against the acceptance of the row ("within … 0.05 bin"). The acceptance check does not exercise the code that computes it | `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift:599–620` (the first null, by chord interpolation between the points of the padded transform); `Tests/Golden/generators/window_analysis.py:41` (`for count in (64, 1024, 4096)`) | See the list after this table | blocking |

What the evidence for A-4 shows:

1. **The true width is 6 bins.** The transform of the periodic Blackman window (0.42/0.5/0.08) has its first zero at exactly 3 bins and a second at 3.055 bins, with a lobe of −96 dB between them (computed with NumPy for N = 1 000).
2. **The package does not find that zero.** Where bin 3 is not a point of the padded transform, the chord between the points around this near-double zero does not find the zero at 3. The width comes out as 6.0793 at 1 000 samples, 6.1061 at 1 001, and so on.
3. **The golden frames never reach this case.** At the committed frames (64, 1 024, 4 096) the padded length is 16N, so every whole bin is a point, and the interpolation that fails is never used.

Reproduction: the two probes named above (`VerifierA/README.md`) and `python3 VerifierA/python/check_window_analysis.py`.

Resolution of A-4:

- Refine the first null on the window's transform itself, for example by bisection on the DTFT evaluated directly between the two points that bracket the minimum.
- Add frames that are not powers of two (for example 333 and 1 000) to the golden grid.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
