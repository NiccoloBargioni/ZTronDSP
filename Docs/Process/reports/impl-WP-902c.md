# WP-902c — implementer's report (coverage closure, part c: `ZTronDSPAnalysis`)

| Field | Value |
|---|---|
| Package | WP-902c, the third part of WP-902 (split by CR-034, §11.7): every file of `ZTronDSPAnalysis` at 97.5 % or more, or named with its reason; lenses T, A |
| Implementer | Implementer M9-coverage (agent), brief 66 with the common rules of brief 60 |
| Date | 2026-11-22; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `74d44f6`; nothing of this part changes a file of the target |
| Ledger | WP-902c `Verifying`, implementer `Implementer M9-coverage (agent)`; its backlog names the file and its finding |
| Change request | CR-034, the split (`Proposed`) |

The measurement (how, the denominator, the table of every file) is in `impl-WP-902a.md`, section 1; the
gates and tests of the package in `impl-WP-902.md`.

## 1. The target

`ZTronDSPAnalysis` is at **99.85 %** (5 418 of 5 426 lines) in run 1 and in run 2, above the 95 % of COV-2.
One of its 63 measured files is below 97.5 %:

| File | Run 2 | Lines not run | What they are | Finding |
|---|---|---|---|---|
| `ConstantQ/ConstantQProjection.swift` | 96.15 % (50 of 52) | 41, 44 | the two guards of `init(geometry:binCount:window:sparsity:squared:)`: a spectrum of fewer than two bins, a sparsity outside [0, 1) | **B-8** of wave 3 (batch m5c, lens B, WP-523), at the same lines 41 and 44 |

Through the stage the guards cannot be reached: `ConstantQScale.lower` refuses both cases first
(`Steps/ConstantQScale.swift` today: `bins >= 2` in the guard of the frequency axis at line 122, and
`sparsity >= 0, sparsity < 1` at lines 131–132), and passes the same `bins` and `sparsity` to the projection
(line 149); no test makes a projection with them (the auditor's reading, which I repeated). The digests name
the file in no other finding.

Five files of the target are not in `xccov`'s report at all: `Order/OrderDiagnostics.swift` and its four
extensions hold 56 functions, every one `@available(*, unavailable, message:)` (ORD-4), never compiled to code
(`impl-WP-902a.md`, the denominator).

## 2. What this part did, and why

Nothing in the target. Brief 66: where a finding of a wave touches the uncovered lines, leave them and name
the finding. B-8 is exactly these two lines, and the draft of fix cycle 1 of M5c
(`ZTronDSP-handoff/briefs/drafts-fix-cycle-1/74-fix-cycle-1-m5c.md`, item 7, "COV-3 of `ConstantQProjection.swift`")
gives them to that cycle: "The suite already makes projections directly: test the two refusals there."

**Tests added**: none, so no line was mutated to see one fail. **Marks added**: none. **Dead code deleted**:
none (the guards are the projection's own contract, documented on the initialiser, whatever the stage checks
first; whether to keep them is the cycle's choice, as B-8's "Resolution asked" offers both).

For the integrator: when fix cycle 1 of M5c has run, this part re-measures the file on a fresh run and is
done when it is at 97.5 % or more.

## 3. Every file of the target, run 2

| File | Executable lines | Covered | Line coverage | Lines not run |
|---|---:|---:|---:|---|
| `Sources/ZTronDSPAnalysis/Calibration/AnalysisCalibration.swift` | 180 | 180 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQGeometry.swift` | 78 | 78 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQKernel.swift` | 219 | 218 | 99.54 % | 114 |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQProjection.swift` | 52 | 50 | 96.15 % **below 97.5 %** | 41, 44 |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQSchedule.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQStrategy.swift` | 45 | 45 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Correlation/Convolution.swift` | 139 | 137 | 98.56 % | 103, 214 |
| `Sources/ZTronDSPAnalysis/Correlation/Correlation.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Export/FrameExports.swift` | 146 | 146 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/DecimateInversion.swift` | 77 | 77 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/InversionReport.swift` | 123 | 123 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/RateInversions.swift` | 102 | 102 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/StageInversions.swift` | 195 | 195 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Mel/MelFilterBank.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/AutocorrelationNode.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/CepstralCoefficientNodes.swift` | 49 | 49 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/CepstrumNodes.swift` | 181 | 181 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ChromaNodes.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ComplexPackingNode.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ConstantQNodes.swift` | 240 | 238 | 99.17 % | 265, 296 |
| `Sources/ZTronDSPAnalysis/Nodes/ConstantQScaleNodes.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/Framer.swift` | 101 | 101 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/HarmonicPercussiveNode.swift` | 118 | 118 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/InverseSTFTNode.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/LevelAndWaveformNodes.swift` | 110 | 110 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/MedianKernels.swift` | 100 | 100 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/MelNodes.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/OnsetStrengthNode.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/STFTNode.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/SpectralCentroidNode.swift` | 36 | 36 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/SpectralValueNode.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/TempogramNodes.swift` | 142 | 142 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/TransformPlans.swift` | 96 | 96 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/WienerKhinchin.swift` | 35 | 35 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/ChromaRecipes.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/HPSS.swift` | 20 | 20 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/Recipes.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/MaskStrategy.swift` | 51 | 51 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/MedianStrategy.swift` | 115 | 115 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/OfflineSeparation.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Autocorrelation.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/CepstralCoefficients.swift` | 59 | 59 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Cepstrum.swift` | 160 | 160 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ChromaFold.swift` | 79 | 79 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ConstantQ.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ConstantQScale.swift` | 80 | 79 | 98.75 % | 99 |
| `Sources/ZTronDSPAnalysis/Steps/FramingSupport.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift` | 88 | 88 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/InverseSTFT.swift` | 67 | 67 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Level.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/MelScale.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/OnsetStrength.swift` | 35 | 35 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/STFT.swift` | 55 | 55 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/SpectralCentroid.swift` | 62 | 62 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/SpectralValues.swift` | 93 | 93 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Tempogram.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Waveform.swift` | 27 | 27 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/DFT.swift` | 30 | 30 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/FFTBackend.swift` | 23 | 23 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/FrameAlignment.swift` | 37 | 37 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift` | 397 | 397 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowAnalysisExport.swift` | 44 | 44 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowDiagnostics.swift` | 47 | 47 | 100.00 % |  |

The other lines not run are in four files above the bar: `ConstantQ/ConstantQKernel.swift` line 114
(99.54 %), `Correlation/Convolution.swift` lines 103 and 214 (98.56 %), `Nodes/ConstantQNodes.swift` lines 265
and 296 (99.17 %), `Steps/ConstantQScale.swift` line 99 (98.75 %, 79 of 80). The lines that marks of COV-4 b
already excuse (in `Nodes/CepstralCoefficientNodes.swift`, `Nodes/LevelAndWaveformNodes.swift`,
`Nodes/TransformPlans.swift`, `Steps/FramingSupport.swift`, `ConstantQ/ConstantQKernel.swift`) are left out of
both counts of the table, as the gate leaves them out.

## 4. Open

`ConstantQ/ConstantQProjection.swift`, until fix cycle 1 of M5c (backlog of WP-902c, owner: that cycle's
implementer).

## 5. Change requests and decisions

CR-034 (the split): the owner's approval is asked (§11.7). Nothing else.
