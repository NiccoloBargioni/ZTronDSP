# WP-902b — implementer's report (coverage closure, part b: `ZTronDSPDesign`)

| Field | Value |
|---|---|
| Package | WP-902b, the second part of WP-902 (split by CR-034, §11.7): every file of `ZTronDSPDesign` at 97.5 % or more, or named with its reason; lenses T, A |
| Implementer | Implementer M9-coverage (agent), brief 66 with the common rules of brief 60 |
| Date | 2026-11-22; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `74d44f6`; nothing of this part changes a file of the target |
| Ledger | WP-902b `Verifying`, implementer `Implementer M9-coverage (agent)`; its backlog names the five files and their findings |
| Change request | CR-034, the split (`Proposed`) |

The measurement (how, the denominator, the table of every file) is in `impl-WP-902a.md`, section 1; the
gates and tests of the package in `impl-WP-902.md`.

## 1. The target

`ZTronDSPDesign` is at **98.70 %** (4 703 of 4 765 lines) in run 1 and in run 2, above the 95 % of COV-2.
Five of its 44 files are below 97.5 %. Every line they do not run is named by a confirmed blocking
finding of verification wave 2 (batch m4b, lens B), each of which asks exactly for these lines to be
covered or marked (COV-3):

| File | Run 2 | Lines not run (today's numbering) | What they are | Finding |
|---|---|---|---|---|
| `Equalizers/MatchedPeakDesign.swift` | 95.02 % (191 of 201) | 84, 105, 113, 133–135, 159, 217–219 | the three `throw Self.noSection(bandwidth)`, the function `noSection`, the refusal "the band is too wide or too narrow to design for", a closure of the band-edge search | **B-4** (WP-422), at 84, 105, 113, 133–135, 159, 217–219 |
| `Stages/ResponseCore.swift` | 97.33 % (146 of 150) | 104, 109, 125, 141 | the four refusals of `resolve` and of the IIR and FIR resolutions: no FIR method, no family, a length for an IIR filter, an order for an FIR filter | **B-5** (WP-431a, 432a, 432c), at 103, 108, 124, 140 |
| `Stages/ResponseStages.swift` | 97.25 % (177 of 182) | 410, 821–823, 836 | `HighPass.dependsOnSampleRate`, `BandStop.zeroPoleGain(sampleRate:)`, `BandStop.dependsOnSampleRate` | **B-5**, at 396, 789–791, 804 |
| `Systems/IIRSystem.swift` | 96.88 % (155 of 160) | 126, 136, 151, 242–243 | the refusals "not an element of an IIR system", "not a finite digital system", "the gains … multiply to a number that is not finite"; the nested element in `replacingParameters` | **B-6** (WP-431c), at 118, 128, 143, 232–233 |
| `Systems/FIRSystem.swift` | 91.94 % (114 of 124) | 115, 125, 128, 133, 159–160, 242–245 | the refusals "not an element of an FIR system", "has no finite taps", "convolve to more than `maximumLength` taps", "a number that is not finite"; the nested element in `replacingParameters`; the zeros of taps that are all zero | **B-7** (WP-431d, 432c), at 107, 117, 120, 125, 149–150, 232–235 |

The findings' line numbers are those of the revision they verified (2026-11-17 22:50); the documentation
comments added since (WP-901b) moved the lines of four of the files down by 1 to 32 (those of
`MatchedPeakDesign.swift` did not move). I compared line by line: the same code, the same count of lines per
file, nothing else not run. The digests name these files in no other finding that touches these lines
(`FIRSystem.swift` is also in A-2 and B-3 of the same batch, the latency of an even-length FIR,
`FIRMath.latency(of:)`, at lines 264–272 then and 276–282 today, which run: 85 calls in run 2).

## 2. What this part did, and why

Nothing in the target. Brief 66, "Rules for this brief": the findings of the waves change code in Design
(M4) soon after this package; "where a finding touches the uncovered lines, leave them, name the finding in
the report, and move on — the fix cycle covers what it rewrites". All the lines above are what B-4 … B-7
are about, and the draft of fix cycle 1 of M4b (`ZTronDSP-handoff/briefs/drafts-fix-cycle-1/71-fix-cycle-1-m4b.md`,
"B-4 … B-7 — COV-3 below 97.5 % in five files") gives each line to that cycle: a test of what the line is for
where an input reaches it (the auditors name the inputs), and for a branch no input reaches ("not an element
of an … system", the nested element in `replacingParameters`) first an unrepresentable state, a mark only
if that is more than a few lines. Tests written here would be written twice, and could pin
lines that cycle reshapes (B-2 and B-3 change `FIRSystem.swift` too).

**Tests added**: none, so no line was mutated to see one fail. **Marks added**: none. **Dead code deleted**:
none (the auditors call 118 and 232–233 of `IIRSystem.swift` and 107 and 149–150 of `FIRSystem.swift`, today
126, 242–243, 115, 159–160, "defensive"; whether they become unrepresentable is the fix cycle's decision).

For the integrator: when fix cycle 1 of M4b has run, this part re-measures the five files on a fresh run
(`Scripts/coverage-gate.sh --xcresult … --mode changed-files` with the five paths) and is done when each is at
97.5 % or more or names a mark the cycle wrote.

## 3. Every file of the target, run 2

| File | Executable lines | Covered | Line coverage | Lines not run |
|---|---:|---:|---:|---|
| `Sources/ZTronDSPDesign/Equalizers/EqualizerDesign.swift` | 148 | 147 | 99.32 % | 90 |
| `Sources/ZTronDSPDesign/Equalizers/MatchedPeakDesign.swift` | 201 | 191 | 95.02 % **below 97.5 %** | 84, 105, 113, 133–135, 159, 217–219 |
| `Sources/ZTronDSPDesign/FIR/FIRDesign.swift` | 188 | 186 | 98.94 % | 165, 248 |
| `Sources/ZTronDSPDesign/FIR/FIRDesignMethod.swift` | 144 | 143 | 99.31 % | 153 |
| `Sources/ZTronDSPDesign/FIR/FIRMath.swift` | 97 | 95 | 97.94 % | 86, 101 |
| `Sources/ZTronDSPDesign/FIR/LeastSquaresFIR.swift` | 106 | 105 | 99.06 % | 135 |
| `Sources/ZTronDSPDesign/IIR/FilterFamily.swift` | 53 | 53 | 100.00 % |  |
| `Sources/ZTronDSPDesign/IIR/FilterOrderStrategy.swift` | 205 | 203 | 99.02 % | 126, 135 |
| `Sources/ZTronDSPDesign/IIR/FilterResponse.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPDesign/IIR/IIRDesign.swift` | 70 | 70 | 100.00 % |  |
| `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK+LeastSquares.swift` | 97 | 97 | 100.00 % |  |
| `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/BoundedMinimizer.swift` | 77 | 77 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/ConjugatePairs.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/DoubleDouble.swift` | 76 | 76 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/Polynomial.swift` | 71 | 71 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift` | 114 | 114 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/QuadraticRoots.swift` | 31 | 31 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift` | 189 | 187 | 98.94 % | 137, 228 |
| `Sources/ZTronDSPDesign/Prototypes/BesselPolynomial.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Prototypes/EllipticFunctions.swift` | 110 | 110 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Smoothing/SavitzkyGolayDesign.swift` | 129 | 127 | 98.45 % | 203, 214 |
| `Sources/ZTronDSPDesign/Stages/Convolve.swift` | 41 | 41 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/EqualizerStages.swift` | 150 | 150 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Filter.swift` | 31 | 31 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Fluent.swift` | 117 | 117 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Gain.swift` | 45 | 45 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/RateStages.swift` | 71 | 71 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/ResponseCore.swift` | 150 | 146 | 97.33 % **below 97.5 %** | 104, 109, 125, 141 |
| `Sources/ZTronDSPDesign/Stages/ResponseStages.swift` | 182 | 177 | 97.25 % **below 97.5 %** | 410, 821–823, 836 |
| `Sources/ZTronDSPDesign/Stages/SmoothingStages.swift` | 49 | 49 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/FIRSystem.swift` | 124 | 114 | 91.94 % **below 97.5 %** | 115, 125, 128, 133, 159–160, 242–245 |
| `Sources/ZTronDSPDesign/Systems/IIRSystem.swift` | 160 | 155 | 96.88 % **below 97.5 %** | 126, 136, 151, 242–243 |
| `Sources/ZTronDSPDesign/Systems/LTISystem.swift` | 115 | 115 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/Realization.swift` | 165 | 162 | 98.18 % | 191, 245, 271 |
| `Sources/ZTronDSPDesign/Systems/SecondOrderSections.swift` | 130 | 130 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/SectionPairing.swift` | 83 | 82 | 98.80 % | 120 |
| `Sources/ZTronDSPDesign/Systems/SystemAnalysis+MATLAB.swift` | 82 | 82 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/SystemAnalysis.swift` | 234 | 230 | 98.29 % | 306, 323, 326, 475 |
| `Sources/ZTronDSPDesign/Systems/SystemElements.swift` | 217 | 212 | 97.70 % | 34, 358, 393, 510, 526 |
| `Sources/ZTronDSPDesign/Systems/TransferFunction.swift` | 72 | 71 | 98.61 % | 74 |
| `Sources/ZTronDSPDesign/Systems/ZeroPoleGain.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Transformations/Bilinear.swift` | 93 | 92 | 98.92 % | 130 |
| `Sources/ZTronDSPDesign/Transformations/FrequencyTransformation.swift` | 74 | 74 | 100.00 % |  |

## 4. Open

The five files above, until fix cycle 1 of M4b (backlog of WP-902b, owner: that cycle's implementer).

## 5. Change requests and decisions

CR-034 (the split): the owner's approval is asked (§11.7). Nothing else.
