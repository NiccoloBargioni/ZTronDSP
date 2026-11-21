# Verifier report — WP-501e, lens N

| Field | Value |
|---|---|
| Package | WP-501e — `WindowAnalysis`, part 2: continuity, smoothness, integrability, by grid refinement (WIN-6) |
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
| Smoothness 0 for rectangular, 1 for triangular, 2 for Hann | `WindowAnalysisTests.smoothnessIsTheOrderOfTheLowestDerivativeThatJumps`, at 16, 64, 1 024, 2 048 and 16 384 samples. Probe `smoothnessAtOtherFrames(frame:)` repeats it at 3, 333, 4 097 and 100 000 samples | passed |
| A closure with an interior jump is located within one sample | Probe `findingAnInteriorJumpIsLocatedWithinOneSample(frame:position:)` uses `Window.custom { $0 < p ? 0.5 : 1 }` and measures \|found − p\|·N in samples | **failed (A-3)** at 16 384 samples (p = 2 457.01/4 096: 1.96 samples away) and at 65 536 (p = 1 000.02/4 096: 7.68 samples). Passed at 1 000 and 8 192 samples, and at 16 384 with p = 0.6 |
| Integrability (the row's third question) | `WindowAnalysisTests.integrabilityOnTheFrame`. The probe `theTailVerdictsOfClosuresFollowedOutsideTheFrame` checks integrability on the line: 1/(1+t²) is absolutely integrable, 1/(1+\|t\|) is not but is square integrable, a constant is not. These follow the WIN-4 rule "decay faster than 1/\|t\|" | passed |

## Lens checklist (§11.5)

- **N — numerical correctness.**

- Definitions: WIN-4 (jumps and finite differences of order 1 to 4 on three grids, refined; Riemann sums), within the limits of WIN-6.
- Implementation: `WindowAnalysis.swift:412–` (grids) and `:435–` (jumps).
- Edge cases: the stress windows of `StressFixture` (square, DC, impulse, Nyquist, denormal) through the stability test; frames of 3 to 100 000; a kink is not a jump.
- Precision: the grids are sampled in double precision.
- `ALG`:
  - Currency: `currency-2026-11.md` row 21 and the first lines of `window-smoothness.md` record it.
  - Stability note checked against the code. The mutation the note names (the noise threshold made absolute, without the peak) makes `StabilityTests.theJumpsOfEveryStressWindowAreFoundWhereTheyAre` fail with 9 issues, as the note says (group M2, `.build/vlogs/mutation-M2.log`). Restored, byte for byte.
  - One sentence of the note is not true; see A-3.
- **A tolerance was loosened** to make a test pass: see A-3.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-3 | The acceptance of the row ("a closure with an interior jump is located within one sample"), a result that is wrong, and a tolerance loosened. Also WIN-4 ("grids of N, 2N and 4N points"), deviated from without a change request (FIX-4) | `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift:189` (`finestGrid = 4_096`) and `:412–`; `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift:178`; `Docs/Numerics/window-smoothness.md:19` | See the list after this table | blocking |

What the evidence for A-3 shows:

1. **The grids are fixed.** The analysis uses the same grids of 2¹⁰, 2¹¹ and 2¹² points whatever the frame (`window-smoothness.md:40`). A jump is placed in the middle of a step of the finest grid. Above 8 192 samples it can therefore lie up to N/8 192 samples away: 1.96 samples at 16 384 and 7.68 at 65 536 (probe above).
2. **The test's tolerance was widened.** The package's test bounds the error by `1.0 / Double(Swift.min(frame, 4_096))` of the frame. That is 4 samples at 16 384, not one. Its only case above 4 096 puts the jump at 0.6, where the middle of the step happens to lie 0.4 samples away.
3. **The note's claim is false.** It says "an interior jump is located within one sample at frames of 64 to 16 384".
4. **The specification conflicts with itself.** WIN-4 asks for grids of N, 2N and 4N. For N > 1 024 that is a step below 2⁻¹² of the frame, which WIN-6 forbids. The code follows WIN-6 and departs from WIN-4 for every N ≠ 1 024 without a change request.

Reproduction:

```sh
cp VerifierA/probes/VerifierAProbeTests.swift Tests/ZTronDSPAnalysisTests/
ZTD_DEVICE=ztdsp-27-vm5aa Scripts/xc.sh test "ZTronDSPAnalysisTests/VerifierAProbes/findingAnInteriorJumpIsLocatedWithinOneSample(frame:position:)"
rm Tests/ZTronDSPAnalysisTests/VerifierAProbeTests.swift
```

Resolution of A-3:

- Locate a jump of order 0 found on the finest grid by bisection on the closure. Order 0 involves no finite difference, so WIN-6's round-off limit does not apply to it.
- Or record, through the change request below, the precision the method has.
- In either case, make the test assert one sample at every frame it uses (with a frame above 8 192 and a position off the grid), and correct the note.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

**Proposed** (the verifier cannot file one; for the integrator): WIN-4 and WIN-6 disagree for frames above 1 024 samples:

- WIN-4 asks for grids of N, 2N and 4N points;
- WIN-6 caps the step at 2⁻¹² of the frame.

Over 8 192 samples, the acceptance of WP-501e ("located within one sample") cannot be met by grid refinement alone. The change request should say:

- which grids are meant (the code uses 2¹⁰, 2¹¹, 2¹² for every N);
- whether a jump's position may be refined on the closure beyond the grids;
- the precision of the position for large frames.
