# Shader coverage (COV-4 a)

`.metal` sources cannot be instrumented. Each shader function is covered by a parity or golden
test instead, listed here. `Scripts/lint-bans.sh --part 4` keeps this register equal to the
code: a shader function without a row fails, a row without a function fails, and a row whose
test is not found under `Tests/` fails.

`Covered by` is the name of the test function or suite, as it is written in the test source.

| Shader function | File | Covered by | Kind |
|---|---|---|---|
| `ztd_screen_vertex` | `Sources/ZTronDSPMetal/Shaders/Common.metal` | `theRenderedPictureMatchesTheGoldenImage` | golden |
| `ztd_heatmap_range_max` | `Sources/ZTronDSPMetal/Shaders/Heatmap.metal` | `aOneBinPeakSurvivesEveryScale` | golden |
| `ztd_heatmap_row` | `Sources/ZTronDSPMetal/Shaders/Heatmap.metal` | `HeatmapGoldenTests` | golden |
| `ztd_heatmap_between` | `Sources/ZTronDSPMetal/Shaders/Heatmap.metal` | `HeatmapGoldenTests` | golden |
| `ztd_heatmap_fragment` | `Sources/ZTronDSPMetal/Shaders/Heatmap.metal` | `HeatmapGoldenTests` | golden |
| `ztd_median_kernel` | `Sources/ZTronDSPMetal/Shaders/Median.metal` | `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms` | parity |
| `ztd_probe_fragment` | `Sources/ZTronDSPMetal/Shaders/Probe.metal` | `aSamplerTestRecordsWhetherHalfFloatTexturesFilterLinearly` | parity |
| `ztd_waveform_range` | `Sources/ZTronDSPMetal/Shaders/Waveform.metal` | `aOnePairPeakSurvivesEveryZoom` | golden |
| `ztd_waveform_fragment` | `Sources/ZTronDSPMetal/Shaders/Waveform.metal` | `WaveformRendererTests` | golden |
