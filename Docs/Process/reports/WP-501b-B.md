# Verifier report — WP-501b, lens T

| Field | Value |
|---|---|
| Package | WP-501b — `Window`: the package set (rectangular, Blackman–Harris, Kaiser, flat-top, Gaussian), periodic and symmetric |
| Lens | T — tests and coverage (the second lens of the row in §12) |
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
| Golden (STG-2; the oracle table: `scipy.signal.get_window`, each window, lengths 16, 1 024, 4 096, periodic and symmetric, 10⁻⁶) | `WindowTests/thePackageWindowsMatchTheirOracle()`: the 120 cases of `Tests/Golden/generators/windows.py` (rectangular, Blackman–Harris, flat-top, Kaiser β 0, 2.5, 8.6, 14, Gaussian σ 0.1, 0.25, 0.4; lengths 2, 5, 16, 63, 64, 1 024; both forms), double within 10⁻¹², single equal to the double rounded, half equal to the prefix. Debug (`Scripts/xc.sh test-only ZTronDSPCoreTests/WindowTests`, 4 runs) and Release (1 run); `Scripts/golden.sh --check` | passes. **Length 4 096 of the grid is not in the golden** (finding 1) |
| The same on the whole grid, by the verifier | probe `VerifierBCoreProbes/vbWindowSamples()` (every package window, 4 forms, counts 1, 2, 3, 7, 8, 16, 64, 1 001, 1 024, 4 096, as bit patterns), then `python3 -I -B VerifierB/check_scipy_windows.py` (`scipy.signal.get_window`, loaded through the project's `_oracle.py`) and `python3 -I VerifierB/check_windows.py` (NumPy, from the definitions) | 60 grid cases against `get_window`: largest deviation 4.7·10⁻¹⁵. Every form and count within 2.5·10⁻¹⁵ of the definition, single = double rounded: 0 problems. The product is right on the grid, 4 096 included |

## Lens checklist (§11.5)

- **T — tests and coverage.** The golden fails when the implementation is broken; the lines changed (gated mutations, `VerifierB/mutations.py`, `VerifierB/run-gates.sh`, one gate on per run):
  - `Window.swift:232`, a Blackman–Harris coefficient 0.14128 → 0.14129 (`m501b`): `thePackageWindowsMatchTheirOracle` fails (12 issues).
  - `Window.swift:248`, the Gaussian's σ × 1.001 (`m501b2`): fails (36 issues), and `packageWindowsHaveTheirShape` (1).
  - `Window.swift:199`, the spans of the periodic and the symmetric form swapped (`m501b3`): 4 tests fail (107 issues).
  - `Window.swift:200`, a half window keeps `count / 2` samples (`m501b4`): fails (40 issues).
  - COV-3: `Window.swift` 99.36 % (155 of 156 lines; shared with WP-501a and WP-501c).
  - Deterministic, no sleep. Negative paths: `aWindowThatCannotBeUsedIsATypedError` (Kaiser β −1 and ∞, Gaussian σ 0 and NaN, a count of −3).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T: an acceptance check of the row is missing in part (STG-2: "Oracle, grid and tolerance are those of the table below unless the row says otherwise") | `Tests/Golden/generators/windows.py:14`; `Tests/ZTronDSPCoreTests/WindowTests.swift:60` | The grid of the oracle table for WP-501b is lengths 16, 1 024, 4 096; the generator writes lengths 2, 5, 16, 63, 64, 1 024 and the test asserts that count (`6 * 2 * (3 + 4 + 3)` cases). No change request names the narrower grid. The verifier's run shows the windows equal `get_window` at 4 096 (deviation below 5·10⁻¹⁵), so only the test is short. Resolve: add 4 096 to the lengths of `windows.py`, regenerate, update the case count. | blocking |
| 2 | N, edge case (for the integrator) | `Window.swift:196-203`; `Window.swift:219` | A package window of one sample is w(0): Blackman–Harris 6.0·10⁻⁵, flat-top −4.2·10⁻⁴, Kaiser β 5 0.037, Gaussian σ 0.1 3.7·10⁻⁶, in both forms, where `get_window` returns 1 (verifier's run) and where the vDSP set's symmetric form of one sample is `[1]`. Outside the grid, and no golden case has one sample. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
