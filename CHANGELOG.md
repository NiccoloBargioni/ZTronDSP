# Changelog

Every release of ZTronDSP, newest first. A Swift package is versioned by its git tag:
`Package.swift` carries no version. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

<!-- Drafted by WP-906 from milestones M0 to M9 of the specification. The owner dates this entry
     (YYYY-MM-DD) in the commit that is tagged 0.1.0: see Docs/Release/0.1.0-checklist.md. -->

The first release: one facade in front of real-time audio DSP on iOS. A declarative pipeline of
processing and analysis stages attaches, unchanged, to any sample source, and Metal-rendered SwiftUI
views show what a source or a pipeline produces.

- iOS 15.0 and later; Swift 6 language mode (tools 6.2). Built and tested with xcodebuild; plain
  `swift build` is not a supported path.
- Products: `ZTronDSP` (the facade), `ZTronDSPUI` (the SwiftUI views) and `ZTronDSPTesting`
  (mock sources and the allocation audit, for the tests of an app or of an extension).
- No UIKit outside one bridge file, no `AnyView`, no Combine, no configuration objects.

### Added

- **Foundation (M0).** The package layout of ten targets under a checked dependency rule
  (DEP-1…DEP-3); the lint bans, the API digest, the compile fixtures, the golden-vector manifest,
  the coverage gate and the benchmark harness, each run by `Scripts/ci.sh` as a CI gate (§10.3).
- **Core values and toolkit (M1).** Units (`Frequency`, `Amplification`, `RollOff`), signal
  formats and audio blocks, typed errors (`DSPError`), the signal environment, `BackgroundWork` for
  every analysis and export, and the toolkit primitives (element-wise operations, reductions,
  padding, rate changes, history and overlap-add buffers), each with a plain loop and an Accelerate
  implementation where both exist.
- **Real-time C layer (M2).** The ring, the plan slot and the command queue, and the kernels that run
  on the analysis thread without allocating, locking or messaging (RT-1…RT-9): gain, biquad cascades
  in single and double precision, direct and partitioned FIR, decimation and interpolation, the lane
  exchange; the mirrored ring with its copy-on-wrap fall-back; stage activation with fades and
  pre-roll, and latency-matched bypass.
- **Pipeline, compiler and engine (M3).** The declarative pipeline in its two spellings (§5.1),
  compiled into a plan and run by `DSPEngine` on any `SampleSource`, including mock, file and
  generator sources; stage orders that mean nothing rejected at compile time (§5.8); every stage
  bypassed or shut down through a SwiftUI `Binding` without a rebuild (§5.9); results written to
  bindings (§5.10).
- **LTI design and analysis (M4).** IIR design from Butterworth, Chebyshev I and II, elliptic and
  Bessel prototypes, by order or by roll-off per octave; band-boost filters; FIR design; pole–zero
  analysis with the numerical stability report of each algorithm; parity with the signal package
  of etk4j (Appendix A).
- **Spectral front-end and analysis (M5).** The real FFT and the short-time transform, power and
  decibels, the mel scale and mel filter banks, spectral centroid, cepstrum, convolution,
  correlation and autocorrelation, the constant-Q transform and chroma, onset strength and
  tempograms, harmonic–percussive separation by median filtering; zero-padding and rate changes,
  and inverse operations with a report on how accurately each inverts (§6.12, §6.13).
- **Metal and calibration (M6).** Metal renderers and the GPU median, with CPU fall-backs; the
  implementation of each primitive chosen by input size from a table of measured crossovers
  (`CrossoverTable`, §7.4), and `Calibration.measure()` to measure the running device.
- **Input and output (M7).** Capture from the built-in and from external microphones, also while
  the same app plays audio (§4.6); route changes, interruptions and media-server resets reported
  as source events.
- **User interface (M8).** `SpectrogramView`, `WaveformView`, `ChromagramView`, `TempogramView` and
  `HeatmapView`, each fed by a source or by a feed; axes as separate views; animatable display
  values; pinch scaling along an axis (§8.8); size transitions without a visible seam (§8.9).
- **Hardening (M9).** The public API held to its digest and documented, symbol by symbol, with its
  threading contract; coverage at 97.5 % or above; the audit of the algorithm and stability
  registers; an external parity suite, in which a package outside this one re-implements stock
  stages on the public API alone (EXT-4); the extension guide; MATLAB export of every analysis,
  each golden script run under GNU Octave; the release checklist (`Scripts/release-check.sh`).
