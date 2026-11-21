# Verifier report — WP-501b, lens N

| Field | Value |
|---|---|
| Package | WP-501b — `Window`: the package set (rectangular, Blackman–Harris, Kaiser, flat-top, Gaussian), periodic and symmetric |
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
- the 19 suites of the batch, 211 of 211 passed in each of four Debug runs and one Release run;
- every gate green;
- probes in `VerifierA/probes/`, references in `VerifierA/python/`.

The row's acceptance is "Golden". STG-2 gives its oracle, grid and tolerance: `scipy.signal.get_window`; each window; lengths 16, 1 024 and 4 096; periodic and symmetric; 10⁻⁶.

| Check | How it was run | Result |
|---|---|---|
| Golden, as committed | `WindowTests.thePackageWindowsMatchTheirOracle` compares with `Tests/ZTronDSPCoreTests/Golden/windows.json`, within 10⁻¹² in double precision. The single-precision samples must be the double ones rounded. The generator (`windows.py`) uses `boxcar`, `blackmanharris`, `flattop`, Kaiser β 0, 2.5, 8.6 and 14, and Gaussian σ 0.1, 0.25 and 0.4, each with `sym` False and True | passed. **The vectors hold the lengths 2, 5, 16, 63, 64 and 1 024 only: no case of 4 096 (A-1)** |
| Golden on the STG-2 grid, by the verifier | `check_windows.py` on the probe dump `dumpWindows`: every window of the package set at 7, 16, 64, 1 000, 1 024 and 4 096 samples, periodic and symmetric, against `scipy.signal.windows`. These are the functions `get_window` dispatches to; `fftbins=True` is `sym=False`. σ is scaled by N or N − 1, as the generator does | 360 cases, 0 failures. Largest deviation 2.98·10⁻⁸ in single precision (tolerance 10⁻⁶) and 2.4·10⁻¹⁵ in double. The values at 4 096 are right |
| The generator passes every library argument explicitly (STG-2) | Read `windows.py`: it passes `M`, `sym`, `beta` and `std` | yes |

## Lens checklist (§11.5)

- **N — numerical correctness.**

- Definitions (computed in double precision, `Window.swift`):
  - the four-term Blackman–Harris;
  - the five-term flat-top;
  - Kaiser through a series for I₀ (`besselI0`, checked at 0, 1 and 20 within 10⁻¹⁴ by `WindowTests.swift:93`);
  - the Gaussian, with σ a fraction of the frame.

  All agree with SciPy at every length checked.
- Precision: the single-precision samples are the double-precision values rounded (`WindowTests.swift:75`).
- Edge cases:
  - β = 0 is the rectangular window exactly;
  - 2 samples, and odd lengths (5, 7, 63);
  - parameters that cannot be used are typed errors (`WindowTests.swift:131`): β < 0, β = ∞, σ = 0, σ = NaN.
- Not `ALG`. No tolerance was loosened: the committed test is tighter than STG-2 (10⁻¹² against 10⁻⁶).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-1 | An acceptance check of the row is missing. STG-2 grid: "lengths 16, 1 024, 4 096" | `Tests/Golden/generators/windows.py:14`; `Tests/ZTronDSPCoreTests/Golden/windows.json`; `Tests/ZTronDSPCoreTests/WindowTests.swift:60` | The generator iterates `for count in (2, 5, 16, 63, 64, 1024)`, and the committed vectors hold no case of 4 096. The test expects exactly `6 * 2 * (3 + 4 + 3)` cases. Reproduction: `python3 -c "import json; print(sorted({c['parameters']['count'] for c in json.load(open('Tests/ZTronDSPCoreTests/Golden/windows.json'))['cases']}))"`. The verifier's own check at 4 096 passes (`VerifierA/python/check_windows.py`), so the defect is in the evidence, not the values | blocking |

Resolution of A-1:

1. Add 4 096 to the generator's grid.
2. Regenerate the vectors and the manifest (`Scripts/golden.sh`).
3. Update the case count at `WindowTests.swift:60`.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
