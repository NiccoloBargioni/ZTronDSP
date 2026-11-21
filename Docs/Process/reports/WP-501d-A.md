# Verifier report — WP-501d, lens N

| Field | Value |
|---|---|
| Package | WP-501d — `WindowAnalysis`, part 1: gains, noise bandwidth, symmetry, edge values, the tail limit (WIN-4) |
| Lens | N (the first lens of the row: N, T) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

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
| Reference values for the stock windows | `WindowAnalysisTests.theFiguresOfTheStockWindowsEqualTheReference` checks the golden vectors of `window_analysis.py` (frames 64, 1 024 and 4 096) within 10⁻¹² relative. The verifier's `check_window_analysis.py` uses the probe dump of 10 windows at frames of 64, 333, 1 000, 1 024 and 4 096. From the samples the analysis holds, it computes the peak, the mean, the mean square, ENBW = N·Σw²/(Σw)², 2/\|Σw\|, √(2/(N·Σw²)), the symmetry and the edge values, and compares them within 10⁻⁹ relative. It also checks that those samples are the window's own (SciPy) | passed. The script's one failure is a spectral figure of WP-501f (A-4) |
| The right verdict for closures that do not decay, diverge, or return NaN far out | `WindowAnalysisTests.theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven` and `withoutItsFunctionACustomWindowIsNotExaminedOutsideTheFrame`. Probe `theTailVerdictsOfClosuresFollowedOutsideTheFrame` checks nine closures: the Gaussian, 1/(1+t²) and 1/(1+\|t\|) give `.zero`; 1 and 1 + 1/(1+t²) give `.value(1)`; t² and eᵗ give `.unbounded`; NaN beyond \|t\| = 1 000 and sin t give `.undefined`. A stock window gives `.zero` | passed |

## Lens checklist (§11.5)

- **N — numerical correctness.**

- Definitions, against WIN-4's rows "Is it normalised?" and "Does it tend to 0?":
  - the gains (`WindowAnalysis.swift:219–230`);
  - the tail (`:339–381`): the closure at 2ᵏ frame lengths on either side, k = 0 … 20.
- Edge cases:
  - a window whose samples sum to round-off: ENBW and the amplitude normalisation are `nil`, through a threshold relative to N·peak (`:226`);
  - a frame of one sample, and frames up to 2²² (`:205`);
  - NaN and ±∞ far out give `.undefined` and `.unbounded`, not an error (WIN-4: "never an error").
- Precision: double precision throughout.
- `ALG`:
  - Currency: `currency-2026-11.md` row 21 and the first lines of `window-gains.md` record the registered source (Harris 1978). It is a definition, so no successor was searched for. Recorded.
  - Stability note checked against the code. The mutation the note names (`let hasSum = sum != 0`) makes `StabilityTests.theGainsOfEveryStressWindowAreNumbersOrNothing` fail with 5 issues: a noise bandwidth and an amplitude normalisation reported for windows whose sums are round-off, as the note says (`VerifierA/mutations.py` group M1, `.build/vlogs/mutation-M1.log`).
  - The file was restored and compared byte for byte.
- No tolerance was loosened: the golden gains are compared within 10⁻¹² relative.

## Findings (VER-4)

None.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
