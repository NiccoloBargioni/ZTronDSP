# ZTronDSP — Package Specification

| | |
|---|---|
| **Status** | Draft 3, for review |
| **Date** | 2026-11-15 |
| **Deployment floor** | iOS 15.0 |
| **Toolchain the facts in §3 were verified on** | Xcode 27.0 (27A266a) · Swift 6.4 · iOS 27.0 SDK · host macOS 27.0, Apple M3 |
| **Design reference** | ZTronSpectrogram (this repository), see §4.1 |
| **Filter catalogue reference** | [staticbeagle/etk4j](https://github.com/staticbeagle/etk4j/) (MIT), see Appendix A |

Every numbered rule (an identifier such as RT-2 or ACT-5), every acceptance statement in §4–§10 and every acceptance cell of §12 is normative, whether or not it uses the word MUST. **MUST**, **MUST NOT**, **SHOULD** and **MAY** mark the places where a rule could be taken for advice. Code blocks are illustrative: type and member *names* are normative, bodies are not.

**Contents** — 1 Scope · 2 Requirements traceability · 3 Evidence base · 4 Architecture · 5 Declarative API · 6 DSP features · 7 Acceleration policy · 8 Visual components · 9 Platform rules · 10 Quality gates · 11 Delivery process · 12 Work packages · 13 Risks, decisions, deferred · Appendices

**Changes in Draft 3.**

- The owner's fifteen additional requirements are in (R-26…R-40): implementation chosen by input size, a package written for extension, immutability, external microphones and views that take any source, results written to SwiftUI bindings, padding / resampling / inverse hooks with an invertibility report, animatable properties, custom windows with a property analysis, pinch scaling, seamless size changes, no configuration objects, approval for `AnyView` and Combine, MATLAB export, analysis off the main thread, and a numerical-stability analysis of every algorithm.
- The activation switch takes a SwiftUI `Binding` (the owner's decision, §5.9). Live values no longer need a package type: a value changes by handing the session a new pipeline (§5.5.4).
- The findings of two independent reviews of Draft 2 are applied. The larger ones: a sink has one writer (ATT-5); FIR filters have one spelling and are stages (§6.3.3); feeds moved to the core target and the layering was reordered (§4.2); a plan change now carries state and pre-rolls what is new (SWAP-1…4); restoring a bypassed stage pre-rolls it (ACT-7); gains are no longer folded into filters (F1); the double-precision biquad is the package's own kernel (REAL-3); transform lengths are admitted by arithmetic only (E-09); roll-off is exact only where it can be (§6.3.4); the process gained an owner role and closed its two exits (§11).
- Work packages were re-split to the 30-minute rule; there are 289, in 286 rows.
- **Not done in this draft, at the owner's request:** the mechanical cross-check of identifiers, dependencies and references that Draft 2 passed has not been re-run on this text, and Draft 3 has not been reviewed.

---

## 1. Scope

### 1.1 What ZTronDSP is

A Swift package that puts one facade in front of real-time audio DSP on iOS: a declarative pipeline of processing and analysis stages that can be attached, unchanged, to any sample source (a microphone, a tap on the app's own playback, a file, a generator, a scripted mock, or the output of another pipeline), plus Metal-backed SwiftUI components that display what a source or a pipeline produces. Everything the package's own stages are built from is public, so a stage written outside the package is the equal of one inside it.

### 1.2 Goals

| ID | Goal |
|---|---|
| G-1 | Declarative / builder API to chain processing dynamically; Strategy pattern throughout; Decorator-style composition; the smallest achievable real-time cost. |
| G-2 | One processing engine, many sources, including mocks; the engine never knows which source it is serving. |
| G-3 | Filters: everything in etk4j's signal package, plus band-boost filters; initialisable by roll-off per octave. |
| G-4 | IIR / FIR system design through a declarative interface, with numerical pole–zero analysis. |
| G-5 | Analysis: decibel conversion and gains, mel-scale conversion, spectral centroid (real time), cepstrum, correlation, autocorrelation, convolution, constant-Q chroma, tempograms, HPSS by median filtering. |
| G-6 | Visual components: spectrogram, waveform, chromagram, tempogram; modular, stable, Metal-rendered; each accepts any source. |
| G-7 | Capture from the built-in or an external microphone, also while the same app is playing audio. |
| G-8 | Accelerate (vDSP, vForce, vImage, BLAS, LAPACK) and Metal wherever they make the real-time path faster; plain loops wherever *they* are faster. The choice follows the input size. |
| G-9 | iOS 15.0 floor, no UIKit, 97.5 % line coverage. |
| G-10 | Delivery in micro work packages (≤ 30 min each), each verified by two independent lenses until zero blocking issues remain. |
| G-11 | Stage orders that mean nothing are rejected by the type structure, at compile time wherever the types are known. |
| G-12 | Every stage can be bypassed or shut down through a SwiftUI `Binding`, without rebuilding the pipeline. |
| G-13 | Written for extension: stages, steps, sinks, sources, windows and strategies defined outside the package lose nothing against the stock ones. |
| G-14 | Immutable values wherever performance does not forbid them; no configuration objects. |
| G-15 | Results reach the app through SwiftUI bindings; values that change what a view shows can be animated from SwiftUI. |
| G-16 | Hooks for zero-padding, subsampling, upsampling and inverse operations, each inverse with a report on whether and how accurately it inverts. |
| G-17 | Analyses and exports (pole–zero, window properties, invertibility, numerical stability, MATLAB scripts) run off the main thread. |
| G-18 | Views scale an axis under a pinch along that axis, and follow size changes without a visible seam. |

### 1.3 Interpretation notes

The request leaves a number of points open. Each is resolved here so the rest of the document is unambiguous. Any of them can be flipped; §13.2 lists the ones where flipping changes the design.

| ID | Requirement as written | Interpretation adopted |
|---|---|---|
| IN-1 | "Can attach the same pipeline to the input" | A `Pipeline` is a source-independent value. The same value attaches to the hardware input exactly as it attaches to a file or a mock; every attachment owns independent state (§4.5). |
| IN-2 | "Can capture audio even when the same app is playing some" | Capture does not stop or interrupt the app's playback and leaves it on the same output. Where the audio session already permits input, nothing is reconfigured at all. Where it does not, one category change is unavoidable, and iOS may answer it with a configuration change that the package cannot suppress (§4.6). In addition a pipeline MAY tap the app's own playback sample-accurately (`EngineNodeTapSource`). |
| IN-3 | "UIKit banned … MetalKit welcome" | `MTKView` is itself a `UIView` subclass and `MTKView.h` imports UIKit (E-12). The ban is therefore a boundary rule (§8.6): no `import UIKit`, no UIKit-declared API, and exactly one bridge file that hosts `MTKView` through SwiftUI's representable protocol. |
| IN-4 | "Metal and GPU computation at every opportunity to optimize real-time performance" | The GPU is used wherever it is *measurably faster end to end* (§7.1). Rendering is always on the GPU. A single 2 048-point frame is cheaper on vDSP than a GPU round trip, so per-frame vector maths stays on the CPU. |
| IN-5 | "The most performant algorithms known in 2027" | This document is dated November 2026. §7.2 registers the best algorithm known at that date; §7.3 makes a dated re-check mandatory when each algorithm is implemented and again before every release. The requirement is claimed only for a release whose register audit (WP-905) is dated 2027-01-01 or later. |
| IN-6 | "Computed each in 30 minutes at most" | A time box on *implementing* one work package (human or agent), excluding verification (§11.2). |
| IN-7 | "Filters can be initialized using roll-off per octave" | Exact for the analog prototype of an all-pole family and for a digital high-pass towards 0 Hz; a stated approximation elsewhere; nominal for families with finite zeros; a transition-slope meaning for FIR (§6.3.4). |
| IN-8 | "All the filters in this repo" | etk4j designs *analog* filters (it is a SciPy port) and offers a bilinear transform. ZTronDSP delivers the digital equivalents for the real-time path and keeps the analog designs for analysis and parity testing (Appendix A). |
| IN-9 | "cromatogram" | Chromagram: the 12 × time heat map of chroma features. |
| IN-10 | (not stated) | Playing the *processed* signal back to the speaker is not requested and is deferred (D-1). A chain of sequence stages could move to the I/O thread without redesign; a chain with analysis steps on its main line could not. |
| IN-11 | "Mel Scale conversion to be one of the available processing steps" | A step, `MelScale`, that turns a linear-frequency spectrum into mel bands (§6.11). It is distinct from *displaying* a linear spectrogram on a mel axis, which is a view modifier. |
| IN-12 | "Have the class structure enforce such constraints" | In Swift the structure that can do this is protocols with associated types on generic value types, not a class hierarchy. Every stage declares the domain it consumes and the one it produces, and a composition only compiles when they agree (§5.8). What types cannot know is checked when the pipeline is attached. |
| IN-13 | "An optional Binding to bypass / programmatically shut it down, defaults to .active / true" | `isActive:` takes a SwiftUI `Binding<Bool>` and defaults to the constant `.active`. A binding can only be read on the main thread and announces no change (E-25), so the session samples bound switches on the main run loop (BIND-1…7). A stage that changes the signal's domain cannot be bypassed; switching it off suspends the rest of its branch (ACT-3). |
| IN-14 | "Fix cycles until 0 blocking issues" | The loop ends only at zero blocking findings on one revision. A cap of three cycles guards against a package that does not converge: at the cap the package is not accepted, it is escalated to the owner (FIX-3). Escalation closes no finding. |
| IN-15 | "97.5 % code coverage" | Line coverage as Xcode reports it over Swift and C production code. Metal shader sources cannot be instrumented and are covered by parity tests instead; branches that run only below iOS 17 are measured on the device run (COV-3, COV-4). |
| IN-16 | "Switch between swift native operators or naive implementation vs Accelerate, vDSP, LAPACK, Metal, based on inputs size" | Every primitive with more than one implementation is bound from a table of measured crossovers (§7.4). Where the size is fixed when the plan is compiled, which is the whole real-time path, the choice costs nothing at run time. "Detect" means a shipped table measured on reference devices, plus a measurement the app can run on the device. |
| IN-17 | "Users outside the package must be able to give their own implementation … without any significant drop of quality" | Parity is structural: no processing stage lives in the core target, and the stock stages use only what the core declares `public` (EXT-1). It is also tested: a package outside this one re-implements three stock stages and must match their output and their speed (EXT-4). |
| IN-18 | "Favor immutability whenever it's not deterrent for performance" | Descriptions, designs, reports and tables are immutable values. Mutable state exists in four named places, each for performance or because it is state by nature (IMM-3). |
| IN-19 | "All rendering views accept any source, whereas the result of a pipeline can be used as a source" | Every view has an initialiser that takes `any SampleSource`. `source.processed(by:)` is itself a source, so raw and processed signals reach the same component. Views also take a feed, for analyses the app composes itself (§8.1). |
| IN-20 | "Components that produce a result should return a pipeline component for chaining and write the result to a SwiftUI.Binding" | A step that reduces the signal to a result has a measuring spelling, `Step(…, to: $binding)`, which passes the signal on unchanged so the chain continues. `Emit(to: $binding)` does the same for any small frame. Bindings are written on the main thread, at a result rate, never at data rate (§5.10). |
| IN-21 | "Inverse operations (ISTFT and wherever available) … analysis of how accurate is the result + if the original signal satisfies theorems for invertibility" | §6.13 lists every operation that has an inverse and delivers it. An `InversionReport` states the conditions (sampling theorem, overlap-add conditions, floors, rank), predicts the error and, given the signal, measures it. |
| IN-22 | "Pipeline modifiers properties that impact view should be animatable from SwiftUI" | Two things. A view's own values (value range, time span, frequency range) are animatable. A pipeline's continuous values (gains, frequencies) are animatable when a view hosts the pipeline: inside `withAnimation` the session receives one interpolated update per display frame (§8.7). |
| IN-23 | "An interface that 1:1s existing vDSP Window functions + allows defining mine: `.custom { t in }`" | vDSP generates three windows, Hann (normalised or not), Hamming and Blackman, each full or half (E-27). The interface has exactly those cases, generated by vDSP, then the windows the package computes itself, then `.custom`. |
| IN-24 | "The engine checks and optionally logs window functions property analysis" | A `WindowAnalysis` answers each question numerically: the limit far outside the frame, normalisation, continuity, smoothness, integrability, plus the spectral figures. Two properties are errors (non-finite, all zero); the rest are reported, and logged when the window is written `.logged()` (§6.4.2). |
| IN-25 | "Pinch gestures vertically and horizontally … a semantic of scale change along the pinch axis" | The line through the two fingers decides the axis. A horizontal pinch scales time; a vertical pinch scales frequency, tempo or amplitude. Axes are off until `.pinchScaling(_:)` turns them on (§8.8). ZTronScrollView was examined and is not used in v1 (E-29, OD-12). |
| IN-26 | "MetalKit views must animate seamlessly between changes of the component's size" | During a size change the drawable follows the layer's *presentation* size on every display frame, so content is never stretched or late (§8.9). |
| IN-27 | "No bags" | No public API takes a configuration, options, style or specification object. Settings are labelled arguments with defaults, one strategy value per decision, or chained modifiers (API-6). |
| IN-28 | "AnyView, Combine usage MUST require approval" | Both are banned by lint. An exception needs a change request approved by the owner; this specification asks for none (§9.5). |
| IN-29 | "Export of plottable data in Matlab language" | Analysis results and feed contents export as a MATLAB script: variable definitions plus the plot commands, core MATLAB only, so it also runs in GNU Octave (§6.14). |
| IN-30 | "Analysis and export efforts are offloaded to background threads" | Every analysis and export is an `async` function that runs on a background executor: never on the main thread, never on the audio threads (BG-1). The signal analysis itself already runs on its own thread (§4.3). |
| IN-31 | "Numerical stability analysis of every algorithm" | §7.5 gives, for every row of the algorithm register, the hazard, the bound or measured behaviour, the mitigation and the test. Every algorithm package delivers a stability note and a stress test (NUMS-2). User-designed systems get the same figures from their analysis (§6.3.8). |

### 1.4 Non-goals for v1

Audio-unit hosting, MIDI, pitch-shifting / time-stretching, source separation beyond HPSS, machine-learning features, macOS / tvOS / watchOS / visionOS support, arbitrary-ratio resampling inside a pipeline (integer factors are in, §6.12; files may be rate-converted when they are opened).

---

## 2. Requirements traceability

| Req | Requirement (from the request) | Specified in | Delivered by |
|---|---|---|---|
| R-01 | Declarative / builder API; dynamic chaining; Strategy; Decorator-style; minimal real-time drawback; source-transparent engine | §4.3–4.5, §5 | WP-201…227, WP-301…341 |
| R-02 | All etk4j filters + band-boost | §6.3, App. A | WP-401…435 |
| R-03 | Spectrogram + waveform components, modular | §8 | WP-333, WP-334, WP-601…608, WP-801…804 |
| R-04 | Chroma CQT, chromagram, tempograms | §6.8, §6.9, §8 | WP-517…527, WP-805, WP-806 |
| R-05 | Decibel conversion, gains | §6.2, §6.4 | WP-102, WP-207, WP-437, WP-506, WP-534 |
| R-06 | Spectral centroid, real time | §6.5 | WP-507 |
| R-07 | Cepstrum analysis | §6.6 | WP-509…512 |
| R-08 | Correlation, autocorrelation, convolution | §6.7 | WP-212, WP-214, WP-215, WP-513…516 |
| R-09 | HPSS median filter | §6.10 | WP-219, WP-528…533, WP-610, WP-612 |
| R-10 | LAPACK, Accelerate, vDSP, Metal, GPU | §7.1 | throughout; WP-611a…d |
| R-11 | Most performant known algorithms | §7.2, §7.3 | WP-905 and every `ALG` package |
| R-12 | Attach the same pipeline to the input | §4.5 | WP-320b, WP-704 |
| R-13 | IIR / FIR system design, pole–zero analysis, declarative | §6.3 | WP-402, WP-428a…431d, WP-439 |
| R-14 | Inject values such as the Nyquist frequency into the environment | §5.4 | WP-108, WP-109, WP-807 |
| R-15 | Filters initialised by roll-off per octave | §6.3.4 | WP-103, WP-419, WP-424 |
| R-16 | iOS 15.0 floor | §9.1 | WP-001, WP-338, WP-904a, WP-904b |
| R-17 | 97.5 % code coverage | §10.2 | WP-003, WP-902 |
| R-18 | Micro work packages, ≤ 30 min | §11.2, §12 | — |
| R-19 | Two lens-independent verifiers, fix cycles to zero blocking | §11.3–11.7 | every package |
| R-20 | UIKit banned; Core Image, Core Foundation, MetalKit welcome | §8.6 | WP-002, WP-609, WP-801 |
| R-21 | Stable visual components, no unnecessary re-rendering | §8.3, §8.4 | WP-606, WP-802, WP-809a, WP-809b |
| R-22 | Capture while the same app is playing | §4.6 | WP-701, WP-704, WP-708 |
| R-23 | Mel-scale conversion as a processing step | §5.2, §6.11 | WP-508, WP-535 |
| R-24 | Stage orders that are not meaningful are rejected by the type structure | §5.2, §5.8 | WP-009, WP-110a, WP-301…303, WP-325…328 |
| R-25 | Every modifier takes an optional binding to bypass or shut it down, active by default | §5.9 | WP-220, WP-221, WP-329…331, WP-811 |
| R-26 | Native loops or Accelerate / LAPACK / Metal, switched by input size | §7.4 | WP-113…115, WP-306c, WP-611a…d, WP-612 |
| R-27 | Written for extension; outside implementations equal to stock ones; deliberate visibility | §5.11 | WP-011, WP-013, WP-339, WP-907, WP-908 |
| R-28 | Immutability favoured | §5.11 | WP-012, WP-909 |
| R-29 | Microphone capture, external microphones included; views accept any source; a pipeline's result is a source; decoupled | §4.4, §4.6, §8.1 | WP-320c, WP-337, WP-704, WP-710…712, WP-814, WP-815 |
| R-30 | Result-producing components chain on and write to a SwiftUI `Binding` | §5.10 | WP-332, WP-335, WP-336, WP-506, WP-507, WP-511 |
| R-31 | Hooks for zero-padding, subsampling, upsampling, inverses; helpers for outside authors; invertibility analysis | §5.11, §6.12, §6.13 | WP-113…119, WP-223, WP-227, WP-438a, WP-438b, WP-505, WP-510, WP-512, WP-537…539 |
| R-32 | Properties that affect a view are animatable from SwiftUI | §8.7 | WP-305, WP-813, WP-816, WP-817 |
| R-33 | Custom window functions; vDSP's set one to one; property analysis | §6.4.2 | WP-501a…g |
| R-34 | Pinch along an axis scales that axis; off by default | §8.8 | WP-818…821 |
| R-35 | Metal views animate seamlessly through size changes | §8.9 | WP-822…824 |
| R-36 | No configuration or options objects | §5.11 | WP-012, WP-812, WP-909 |
| R-37 | `AnyView` and Combine need approval | §9.5 | WP-011 |
| R-38 | Export of plottable data as MATLAB | §6.14 | WP-120, WP-440, WP-501g, WP-540, WP-614, WP-910 |
| R-39 | Analysis and export off the main thread | §9.2 | WP-112, WP-439, WP-501d, WP-537, WP-609, WP-611d |
| R-40 | Numerical stability analysis of every algorithm | §7.5 | WP-016, WP-428b, WP-433, every `ALG` package, WP-905 |

---

## 3. Evidence base

These facts were checked on the toolchain named in the header by reading SDK headers and by compiling and running small probes: E-01…E-25 on 2026-11-11; the corrections to E-05, E-08, E-09, E-12, E-15 and E-18, and E-26…E-32, on 2026-11-15. E-30 and parts of E-09, E-15 and E-31 are findings of the technical review. They drive several decisions below. Anything not listed here is an assumption and is marked as such where it is used.

| ID | Verified fact | Consequence |
|---|---|---|
| E-01 | Local toolchain is Swift 6.4 / Xcode 27.0 / iOS 27.0 SDK. The sibling package uses `swift-tools-version: 6.0`, Swift Testing and `StrictConcurrency=complete`. | Test framework and language mode (§9.2, §10.1). |
| E-02 | The iOS 27 SDK adds real-time-safe block types (`AVAudioSinkNodeReceiverBlockRealtimeSafe`, `AVAudioSourceNodeRenderBlockRealtimeSafe`, `AVAudioIONodeInputBlockRealtimeSafe`). They are annotated `CA_REALTIME_API` (= `[[clang::nonblocking]]`) and are **unavailable in Swift**, with the message "Swift is not supported for use with audio realtime threads". `initWithRealtimeSafeReceiverBlock:` is documented as the preferred initialiser. | Rule RT-1: nothing written in Swift runs on the audio I/O thread. The I/O-thread code lives in a C / Objective-C target (§4.3). |
| E-03 | Clang `-Wfunction-effects` flags a `nonblocking` function that calls `malloc`, `free`, or any function not itself `nonblocking`. vDSP declarations carry no such annotation, but re-declaring a vDSP function with the attribute compiles clean under `-Werror=function-effects`. `fegetenv` and `fesetenv` are rejected by it. | The C target is compiled with function-effect errors on, plus one audited allow-list header for the vDSP entry points it uses (WP-201). The floating-point environment is not touched on the hot path (RT-6). |
| E-04 | `-fsanitize=realtime` is rejected for Apple targets by this toolchain ("unsupported option" for macOS and for the iOS simulator). | RealtimeSanitizer is not available; run-time auditing uses E-06 instead. |
| E-05 | Swift's `@_noAllocation` / `@_noLocks` are enforced (compile errors at `-O` and `-Onone`). They **accept** static calls, `switch`-on-enum dispatch and a call through a non-escaping closure parameter. They **reject** calls to external C functions (so every vDSP call), existential calls, class-method dispatch, stored closures and C-function-pointer calls. `_unsafePerformance { }` suppresses the diagnostic. | Compile-time checking in Swift can only cover pure-Swift leaf loops. It is used there and nowhere else; it is not the primary guard (RT-7). |
| E-06 | A `malloc_logger` hook observes every `malloc` / `free` in the process, and the symbol links against both the iOS simulator and the iOS device SDKs. | Test-only allocation probe `expectNoAllocations { }`. Because the hook is process-wide and tests run in parallel, it counts only the thread under audit (WP-005). |
| E-07 | With setups created beforehand, these calls made zero heap allocations on the host: `vDSP_fft_zrip`, `vDSP_fft_zript`, `vDSP_fft_zip` (N = 65 536), `vDSP_DFT_Execute` (real 4 096, complex 3 072), `vDSP_biquad` (8 sections), `vDSP_biquad_SetCoefficientsDouble`, `vDSP_conv` (255 taps), `vDSP_desamp`, `vDSP_vsmul`, `vDSP_vdbcon`, `vDSP_zvmags`, `vDSP_vsort`, `vDSP_vswmax`, `vvlog10f`. | Initial evidence for the allow-list. It is host-only; WP-005 and WP-324 repeat the audit on simulator and device. |
| E-08 | `vDSP_biquad_SetCoefficientsDouble` and `…Single` (iOS 15.0) both act on the single-precision setup, `vDSP_biquad_Setup`; "Double" names the type of the coefficients passed. `vDSP_biquad_SetupD` has no coefficient setter. For `vDSP_biquadm`, the setters and ramped targets of the single-precision setup are iOS 9; those of the double-precision setup (the `…D` functions) are iOS 16.0. | At the floor, live coefficient changes exist only for single-precision vDSP biquads. The double-precision path is the package's own kernel (REAL-3, WP-211). |
| E-09 | `vDSP.DiscreteFourierTransform` is available from iOS 15.0 and `vDSP.DFT` is deprecated in its favour. `vDSP.h` says of the legacy FFT routines "We suggest you use the DFT routines instead of these", and that setup "should never be done during real-time processing". The documented lengths are: real DFT, 2ⁿ and f·2ⁿ with f ∈ {3, 5, 15}, n ≥ 4; DCT, f·2ⁿ with f ∈ {1, 3, 5, 15}, n ≥ 4. Creating a setup is **not** a safe test of a length: on the host `vDSP_DCT_CreateSetup` crashes for N = 18, 26 and 30 (the technical review found every N ≡ 2 mod 4 from 18 to 598), returns null for 20, 24 and 40, and the DFT setup accepts some lengths outside the documented rule. | Lengths are admitted by arithmetic against the documented rule; a setup is created only for an admitted length (§6.4, §6.6, WP-116). |
| E-10 | The CLAPACK interface is deprecated from iOS 16.4; the replacement symbols exist only from iOS 16.4. | With a 15.0 floor the legacy interface is the only one usable everywhere. All LAPACK calls are confined to one file group so the switch is local when the floor moves (LA-1). |
| E-11 | Accelerate's complex sparse routines are iOS 18.5+. Real `SparseMultiply` is iOS 11+. | The constant-Q kernel uses its own CSR split-complex product (§6.8). |
| E-12 | `MTKView.h` imports `<UIKit/UIKit.h>` and declares `MTKView : UIView`. The header documents `draw()` for the case `paused == true`, `enableSetNeedsDisplay == false`. `framebufferOnly` defaults to true, which makes a drawable unsuitable for sampling. | UIKit boundary rule (§8.6), explicit-draw scheduling (§8.3), snapshots re-rendered off screen (§8.2). |
| E-13 | MPSGraph FFT operations are iOS 17.0+. | Batched GPU STFT is optional and availability-gated (WP-613). |
| E-14 | `AVAudioSinkNode` is iOS 13+, does no format conversion, and is not supported in manual rendering mode. | The sink path is tested by driving its block directly; the tap source is tested with manual rendering (WP-703, WP-706). |
| E-15 | `installTap(onBus:bufferSize:format:block:)` is deprecated in iOS 27 in favour of an error-returning variant that exists only from iOS 27. `AVAudioNode.h` gives the supported tap buffer size as 100 to 400 ms. | Availability gate and a pacing buffer in `EngineNodeTapSource` (WP-706). |
| E-16 | `AVAudioApplication.requestRecordPermission` is iOS 17+; the `AVAudioSession` equivalent is deprecated. | Authorisation seam with two code paths (WP-702). |
| E-17 | iOS 15.x and 16.x simulator runtimes cannot run on a macOS 27 host; the oldest runnable runtime here is iOS 17.5. | The floor is enforced at compile time everywhere and at run time on a physical device (§9.1, WP-338, WP-904a). |
| E-18 | Present in the SDK: `vm_remap`, `vImageConvert_PlanarFtoPlanar16F` (iOS 5), `MTLDevice.supports32BitFloatFiltering` (iOS 14). | Mirrored ring, half-float texture upload (WP-203, WP-604). |
| E-19 | A result builder built on `buildPartialBlock`, with a same-type constraint between the accumulated output domain and the next stage's input domain, type-checks valid pipelines and rejects invalid ones at an iOS 15 deployment target in Swift 6 mode. Eighteen invalid orders were tried, among them a filter after an STFT, decibels before mel, mel on a complex spectrum, mel twice, an inverse STFT after the phase was discarded, chroma folding on a linear-frequency spectrum, an optional domain-changing stage, and a pipeline that does not start from samples. All eighteen fail to compile. Valid pipelines with conditionals, `switch`, loops and nested side branches compile. The review re-ran this and added two limits: `if #available` around a block of sequence stages needs its own builder overload, and an `if … else` whose two branches are the same context-dependent step is rejected. | Tier 1 of §5.8; ORD-3. |
| E-20 | A stage whose domains depend on the stage before it cannot be a generic type inferred from context: each statement of a builder body is type-checked on its own ("generic parameter could not be inferred"). Overloads of `buildPartialBlock` keyed on the accumulated type, and fluent methods constrained on the output domain, both work. | Context-dependent steps are plain values with one typing rule per family (§5.8.2). |
| E-21 | With many builder overloads the compiler's report of a failed match is often "failed to produce diagnostic for expression". Catch-all overloads marked `@available(*, unavailable, message:)` turn 17 of the 18 failures into either a purpose-written sentence or a compiler message that names the two mismatched domains; the same device works per stage for self-typed stages. The exception is `if … else` branches that end in different domains. Constrained fluent methods give precise messages unaided. | ORD-4. |
| E-22 | An 80-stage pipeline type-checks in about 0.3–0.4 s in either spelling, also with 75 extra overloads present. | The typed builder has no compile-time cost worth designing around. |
| E-23 | The same rules, applied at run time to the type-erased description, reject an invalid `append` to a dynamically built pipeline, a hand-forged description and an invalid side branch. The builder and fluent spellings of one pipeline produce equal descriptions. This was probed without activation, sinks or closures in the description. | Tier 2 of §5.8; API-1. WP-304 and WP-329 extend the fixtures. |
| E-24 | A SwiftUI `Binding<Bool>` is accepted where the argument's type is `some ActivationSource`, a protocol adopted by `Bool`, `Activation` and `Binding<Bool>`, also as a defaulted argument, at an iOS 15 deployment target in Swift 6 mode. A stage that stores the binding is `Sendable`. A constant and a binding stay distinguishable in the description; an argument of type `Binding<Bool>` defaulted to `.constant(true)` could not offer that, because a binding cannot be asked whether it is constant. | ACT-1, ACT-2, ACT-12. |
| E-25 | A `Binding` announces no change. In a hosted probe, a `CFRunLoopObserver` on the main run loop (before waiting) saw a write to `@State` made through its binding in the same run-loop turn, and likewise a main-thread write to custom storage behind `Binding(get:set:)`. A write made on a background thread was seen at the loop's next turn. In two idle seconds the observer ran 12 times: it runs when the loop turns, not at a rate. The view that owns the state had its body evaluated once. | BIND-1…BIND-4; the session causes no view updates. |
| E-26 | Native loops against Accelerate on the host, Swift `-O`, nanoseconds per call. Scaling a vector: a Swift loop takes 3 where `vDSP_vsmul` takes 8, up to n = 64; they meet between n = 512 and 1 024. Adding two vectors: they meet at about 512. Dot product: a scalar loop leads up to n = 16, an 8-lane SIMD loop up to about 64, `vDSP_dotpr` beyond; at n = 4 096 a scalar reduction is 15 times slower. One biquad section: a Swift loop leads only below 4 frames per block; at 512 `vDSP_biquad` is 4.8 times faster. The review measured a plain C minimum / maximum loop at 182 ns against 150 ns for vDSP at n = 1 025. | Crossovers exist, they differ by operation, and none is where intuition puts it. §7.4 binds implementations from measured tables. The figures are host-only initial values. |
| E-27 | vDSP generates three windows: `vDSP_hann_window`, `vDSP_hamm_window`, `vDSP_blkman_window` (and their `D` forms), with the flags `vDSP_HANN_NORM`, `vDSP_HANN_DENORM` and `vDSP_HALF_WINDOW`. The Swift overlay's `vDSP.WindowSequence` has four cases: `hanningNormalized`, `hanningDenormalized`, `hamming`, `blackman`. | The one-to-one part of the window interface (WIN-1). |
| E-28 | `import struct SwiftUI.Binding` compiles at the floor and brings in that one name: `Color` and `View` are not in scope in such a file. | The core target can hold a `Binding` without the rest of SwiftUI (BIND-7). |
| E-29 | `MagnificationGesture` is iOS 13 and reports one number. `MagnifyGesture` is iOS 17. `SpatialEventGesture`, which reports each touch, is iOS 18. ZTronScrollView (the owner's package, read locally) offers a uniform zoom scale applied as a render-time transform; its per-touch observer for iOS 15–16 is internal, built on a UIKit gesture recogniser, and the package imports Combine in two files. | Pinch scaling is built in `ZTronDSPUI` behind one seam with a path per OS (§8.8). ZTronScrollView is not a dependency in v1 (OD-12). |
| E-30 | Measured by the technical review on the host (its probes were not kept; the packages named re-measure). Float32 `vDSP_biquad` against a double-precision reference: 2·10⁻⁶ for a 1 kHz high-pass of order 2–8 at 48 kHz, 4·10⁻⁵ for 90 Hz at order 8; its output differs between block sizes 512 and 7 by up to −61 dB for that filter. A −3 dB gain folded into the first section's numerator differs from the gain applied separately by −85 to −96 dB. The Float32 DFT has an error floor of about 8·10⁻⁸ of the frame's largest bin. | REAL-3 selects precision by measurement (WP-433). Gains are not folded into filters (F1). Tolerances on spectra are stated relative to the frame maximum (§6.1). |
| E-31 | AVFAudio headers: the category option is `allowBluetoothHFP` (the name `allowBluetooth` is deprecated); `bluetoothHighQualityRecording` is iOS 26; input ports include built-in, headset, line-in, USB, Bluetooth HFP and LE, and the Continuity microphone (iOS 17). `AVAudioEngine.h` states that the engine stops itself when the hardware's channel count or sample rate changes. | Input selection and hot-plug rules (MIC-1…6); CAP-8 covers the engine's configuration change. |
| E-32 | The installed PackageDescription documentation offers warning control for C targets (`treatWarning`, `enableWarning`) only from tools version 6.2; at 6.0 the flag needs `unsafeFlags`, which bars the package from being used as a dependency. | `swift-tools-version: 6.2` (§9.2). |

---

## 4. Architecture

### 4.1 What carries over from ZTronSpectrogram

ZTronSpectrogram already separates *who produces samples* from *who processes them*: `SamplesProvider` → `SignalChunker` → `FFTCalculator(chunksProvider: any SignalChunker)`. ZTronDSP keeps that decomposition and generalises it. It also removes the things in the current implementation that cost real-time performance.

| ZTronSpectrogram today | ZTronDSP |
|---|---|
| **Kept** | |
| `SamplesProvider`: batches of unspecified size, start / stop, Nyquist frequency | `SampleSource` (§4.4). Nyquist moves into the environment (§5.4). |
| `SignalChunker`: fixed windows with a hop, separate from the provider | `Framer`, owned by the engine, shared between branches (F5). |
| `FFTCalculator` takes `any SignalChunker`, not a microphone | The engine takes `any SampleSource`; rule ATT-2 forbids it from inspecting the concrete type. |
| A protocol for the transform (`FFTStrategyDecorator`), though its one conformer is constructed inside `FFTCalculator` with a fixed 1 024-point window | Strategy protocols for every replaceable algorithm, passed where the stage is declared (§5.3). |
| Examples beside the sources (`Examples/*Mockup.swift`); they drive the real microphone | Examples run on mock sources, `GeneratorSource`, `BufferSource` and `ScriptedSource`, which ship in the core target. |
| **Changed** | |
| Samples travel as `[Float]` through Combine subjects: one array allocation per batch, plus copies | Lock-free SPSC ring, pre-allocated blocks, no allocation in steady state. No Combine (§9.5). |
| `rawAudioData.removeFirst(hopCount)` shifts the whole buffer every hop | Ring-based framer; with the mirrored ring a window is a contiguous view and nothing is copied. |
| `.receive(on: DispatchQueue.main)`: chunking and FFT run on the main thread | Dedicated analysis thread; the main thread only draws. |
| `DispatchSemaphore` used as a lock around every buffer | No locks on the data path. |
| The Hamming window is recomputed inside every `transform` call | Windows, setups and work buffers are created once, when the plan is compiled. |
| `MicrophoneInputChunker` constructs its own `MicrophoneInputReader` | Sources are injected; the same pipeline attaches to any of them. |
| `AVCaptureSession`, which configures the app's audio session implicitly | `AVAudioEngine` input with an explicit `AudioSessionPolicy` (§4.6). |
| Capture assumes 16-bit mono | Format is discovered; samples are Float32, non-interleaved. |
| `fatalError()` when a setup cannot be created | Typed `DSPError`. |

ZTronDSP is a **new, standalone package**. It does not depend on ZTronSpectrogram; the LAPACK-backed maths it needs is specified here and implemented in `ZTronDSPDesign`.

### 4.2 Targets and dependency rule

| Target | Language | May import | Contains |
|---|---|---|---|
| `CZTronDSP` | C11, Objective-C | Accelerate, AVFAudio (sink-node factory only), Mach | Ring buffers, kernel ABI and plan runner, stock kernels, sink-node factory. Everything that may run on the I/O thread. |
| `ZTronDSPCore` | Swift | Foundation, Accelerate, `CZTronDSP`, and the one name `SwiftUI.Binding` | Units, signal domains, environment, stage protocols, pipeline DSL, plan compiler, engine, source and sink protocols, feeds, mock sources, the toolkit (§5.11.4), the background executor, the MATLAB writer. **No processing stage** (EXT-1). |
| `ZTronDSPDesign` | Swift | Core, Accelerate | LTI systems: prototypes, transforms, FIR design, pole–zero analysis. The sequence stages: `Gain`, filters, smoothers, rate changers, `Convolve`. |
| `ZTronDSPMetal` | Swift, Metal SL | Core, Metal, MetalPerformanceShaders(Graph), Core Image, Core Graphics | Textures, renderers, GPU compute kernels, snapshot images. No views. |
| `ZTronDSPAnalysis` | Swift | Core, Design, Metal (the target), Accelerate | Every step and recipe of §6.4–6.13, their strategies (the GPU ones included), the inversion and window analyses. |
| `ZTronDSPIO` | Swift | Core, `CZTronDSP`, AVFAudio | Hardware input and input selection, node tap, file source, audio-session policy. |
| `ZTronDSPUI` | Swift | Core, Analysis, Metal, SwiftUI, MetalKit, QuartzCore | Views, modifiers, gestures, pipeline hosts, the SwiftUI environment bridge. |
| `ZTronDSP` | Swift | re-exports Core, Design, Analysis, IO, Metal | The facade product. |
| `ZTronDSPTesting` | Swift, C | Core | What an author of a stage needs to test it: `expectNoAllocations`, `expectClose`, seeded signals, `ScriptedSource` helpers. A public product (EXT-3). |

Products: `ZTronDSP`, `ZTronDSPUI`, `ZTronDSPTesting`. Test targets: one per target. `Examples/ZTronDSPGallery` is a separate project inside the repository, not a package target: a mock-driven gallery with a hosted test target for the tests that need a real window (§8.4, level 2). It is outside the coverage denominator.

- **DEP-1** A target imports only targets listed above it in the table. `ZTronDSPCore` MUST NOT import AVFAudio or Metal. It names one SwiftUI symbol, `Binding`, through a scoped import in the file group `Bindings/` (BIND-7).
- **DEP-2** Only `ZTronDSPUI` may import MetalKit, declare a view, or name any other SwiftUI symbol.
- **DEP-3** No third-party dependencies (OD-12 records the one considered).
- **DEP-4** `.metal` sources are compiled by the Xcode build system into the target's resource bundle and loaded with `makeDefaultLibrary(bundle: .module)`. The package is built and tested with `xcodebuild`; plain `swift build` is not a supported path. *(Assumption, confirmed by WP-601.)*

### 4.3 Execution contexts

| Context | Thread | Code allowed | Work done there | Rules |
|---|---|---|---|---|
| **I/O** | Core Audio I/O thread | `CZTronDSP` only, every function `nonblocking` | Copy input frames into an SPSC ring. Nothing else in v1. | RT-1 |
| **Analysis** | One dedicated thread per engine | Swift and C | Assemble blocks, run the signal chain (`ztd_plan_run`), run the analysis nodes, write feeds and result slots. | RT-2…RT-9 |
| **Offline** | One utility thread per session whose source is not real time | Swift and C | The same work for an `.asFastAsPossible` source, so that it cannot starve a live session. | RT-2 |
| **Control** | A utility queue | Swift | Design filters, compile plans, allocate, pre-roll, retire old plans. | May allocate and lock. |
| **Background** | The package's background executor | Swift | Analyses and exports (§9.2). | BG-1…BG-3 |
| **Main run loop** | Main thread | Swift | Sample bound switches, deliver results to bindings (§5.9, §5.10). | BIND, OUT |
| **Render** | Main thread, on a display-link tick | Swift, Metal | Upload new texture columns, one or two draw calls. | §8.3 |

The analysis thread wakes by polling the ring at half the I/O buffer duration (minimum 1 ms). The I/O thread therefore performs no system call at all: it does not signal a semaphore. Pull sources need no polling; the engine paces itself.

### 4.4 Sources

```swift
public protocol SampleSource: AnyObject, Sendable {
    var format: SignalFormat { get }                 // sample rate, channel count; valid after prepare()
    var events: AsyncStream<SourceEvent> { get }
    func prepare() async throws(DSPError)            // permission, session, format discovery
    func start() throws(DSPError)
    func stop()
}

/// Clocked by something else (hardware, a reader thread). Writes into a ring the engine hands it.
public protocol PushSampleSource: SampleSource {
    func connect(to ring: RingWriter)
}

/// Clocked by the engine. `render` runs on the analysis thread and is bound by RT-2: memory only.
public protocol PullSampleSource: SampleSource {
    var pacing: Pacing { get }                        // .realTime or .asFastAsPossible
    func render(into block: inout AudioBlock) -> Int  // frames produced; 0 ends the stream
}

public enum SourceEvent: Sendable {
    case formatChanged(SignalFormat), interrupted, resumed, routeChanged(RouteChange), mediaServicesReset
    case overrun(droppedFrames: Int), ended, failed(DSPError)
}
```

| Source | Target | Kind | Purpose |
|---|---|---|---|
| `HardwareInputSource` | IO | push | The built-in microphone or an external one: wired, USB, Bluetooth, Continuity (§4.6). |
| `EngineNodeTapSource` | IO | push | A tap on any `AVAudioNode`: what the app itself is playing. A tap delivers bursts of 100 ms or more (E-15), so the source releases blocks through a pacing buffer, at the block rate, one burst late. |
| `FileSource` | IO | push | `AVAudioFile`, read on a thread of its own, because file reads block and message Objective-C. It writes a lossless ring (the reader waits for space), real-time paced or as fast as the consumer drains; optional rate conversion on open. |
| `GeneratorSource` | Core | pull | Sine, chirp, white and pink noise, impulse, step, silence, closure. Seeded and deterministic. |
| `BufferSource` | Core | pull | Caller-supplied samples. |
| `ScriptedSource` | Core | pull | Test double: irregular batch sizes, injected errors and format changes. |
| `ProcessedSource` | Core | derived | The main-line output of a pipeline attached to another source (SRC-2). |

Internally a `SourceAdapter` turns every kind into the same thing, a stream of fixed-size blocks, which is all the engine ever sees.

- **SRC-1** The three protocols are the whole contract. A source written outside the package is served exactly like a stock one; the stock sources use nothing else.
- **SRC-2** `source.processed(by: pipeline)`, for a `Pipeline<Samples, Samples>`, is a `SampleSource` whose samples are the pipeline's main-line output. Anything that takes a source takes it: a view, or `attach` for a further pipeline. On one engine the hand-over happens inside the analysis thread's turn, with no ring and no added latency.
- **SRC-3** A component that displays or analyses takes `any SampleSource` and nothing more specific. The same `SpectrogramView` shows a microphone, a file, a mock, or a processed signal (§8.1).

### 4.5 Engine, sessions, attachment

```swift
public final class DSPEngine: Sendable {
    public static let shared: DSPEngine
    public init(blockSize: Int = 512, crossovers: CrossoverTable = .shipped)                 // §7.4
    public func attach<Output>(_ pipeline: Pipeline<Samples, Output>, to source: any SampleSource) async throws(DSPError) -> PipelineSession
    public func attach(_ pipeline: DynamicPipeline, to source: any SampleSource) async throws(DSPError) -> PipelineSession
}

public final class PipelineSession: Sendable, Identifiable {
    public var environment: DSPEnvironment { get }             // resolved for this attachment
    public var state: SessionState { get }
    public var events: AsyncStream<SessionEvent> { get }
    public func start() throws(DSPError)
    public func stop()
    public func update<Output>(_ pipeline: Pipeline<Samples, Output>) async throws(DSPError)   // §5.5.4
    public func update(_ pipeline: DynamicPipeline) async throws(DSPError)
    @MainActor public func syncBindings()                      // BIND-3
    public func detach()
}

public enum SessionState: Sendable { case idle, running, interrupted, finished, failed(DSPError), detached }

public enum SessionEvent: Sendable {
    case stateChanged(SessionState), replanned(ReplanReason), outputChanged
    case overrun(droppedFrames: Int), nonFiniteInput(count: Int), memoryPressure(MemoryPressureLevel)
}
```

```swift
func analysis(into feed: HeatmapFeed) -> Pipeline<Samples, Samples> {
    Pipeline {
        HighPass(.butterworth, cutoff: .hertz(90), order: 4)
        MelSpectrogram(frame: 2_048, hop: 512, bands: 128, to: feed)
    }
}

let live = try await engine.attach(analysis(into: micFeed),  to: HardwareInputSource())               // the input
let file = try await engine.attach(analysis(into: fileFeed), to: FileSource(url: recording))          // the same description
let mock = try await engine.attach(analysis(into: mockFeed), to: GeneratorSource(.sine(frequency: .hertz(440))))
let own  = try await engine.attach(analysis(into: ownFeed),  to: EngineNodeTapSource(node: player))   // the app's playback
```

Session states. A cell names the new state; "—" means the event cannot occur there.

| Call or event | `idle` | `running` | `interrupted` | `finished`, `failed` | `detached` |
|---|---|---|---|---|---|
| `start()` | `running` | no effect | no effect; it resumes with the source | the source is prepared again, then `running`; may throw | throws `sessionDetached` |
| `stop()` | no effect | `idle` | `idle` | `idle` | no effect |
| `update(_:)` | plan replaced | §5.5.4 | plan replaced | plan replaced | throws `sessionDetached` |
| `detach()` | `detached` | `detached` | `detached` | `detached` | no effect |
| Source `.interrupted` | — | `interrupted` | — | — | — |
| Source `.resumed` | — | — | `running`; stages start cold (ACT-10) | — | — |
| Source `.formatChanged` | re-plan | re-plan, stays `running` | re-plan | — | — |
| Source `.ended` | — | `finished` | `finished` | — | — |
| Source `.failed` | `failed` | `failed` | `failed` | — | — |

- **ATT-1** A `Pipeline` holds no run-time state. Attaching it N times yields N independent plans, each with its own filter memory, buffers and analysis state.
- **ATT-2** Engine code MUST NOT branch on the concrete source type. The one place that tells push from pull is `SourceAdapter`. (Lint: under `Engine/`, no `is`, `as?` or `as!` towards a type whose name ends in `Source`.)
- **ATT-3** The environment (§5.4) is resolved per attachment from the source's format.
- **ATT-4** On `.formatChanged` the session re-compiles the plan against the new environment and continues. Stage state is reset; the session reports `.replanned(.formatChanged)`.
- **ATT-5** A sink has one writer. Attaching a pipeline that writes a feed, a stream or a callback already claimed by a live attachment, or that names one sink twice, fails with `DSPError.sinkInUse`. `detach()` releases the claim, and so does an `update(_:)` that drops the sink. To run one description on several sources at once, build the pipeline in a function of its sinks, as above. (A binding has no identity and cannot be claimed: OUT-4.)
- **ATT-6** A source may carry several attachments of one engine. It is prepared once, started with the first attachment that starts, stopped with the last that stops, and every attachment sees the same blocks.

Offline use. `try pipeline.process(samples, format:)` runs the same plan synchronously on the caller's thread and returns the main line's output; sinks fill as they do live (WP-323).

### 4.6 Capture: the microphone, external microphones, and the app's own playback

`HardwareInputSource` runs its own `AVAudioEngine` whose only connection is `inputNode → AVAudioSinkNode`. It shares the process's audio session with whatever the app uses for playback; nothing in it is on the output path.

```swift
public struct AudioInput: Sendable, Hashable, Identifiable {
    public let id: String                      // the port's unique identifier
    public let name: String
    public let kind: Kind                      // .builtIn, .wired, .usb, .bluetooth, .continuity, .other
    public let dataSources: [String]           // for a built-in microphone: front, back, bottom
}

extension HardwareInputSource {
    public static func availableInputs(policy: AudioSessionPolicy = .playAndRecord) async throws(DSPError) -> [AudioInput]
    public convenience init(input: AudioInput? = nil, dataSource: String? = nil,
                            policy: AudioSessionPolicy = .playAndRecord, voiceProcessing: Bool = false)
}

public struct AudioSessionPolicy: Sendable {
    public static let playAndRecord: AudioSessionPolicy         // default
    public static let measurement: AudioSessionPolicy           // as above, with .measurement mode
    public static let external: AudioSessionPolicy              // never touches AVAudioSession
    public static func custom(_ configure: @escaping @Sendable (any AudioSessionControlling) throws -> Void) -> AudioSessionPolicy
    public func mixingWithOthers() -> AudioSessionPolicy                 // other apps keep playing
    public func allowingBluetoothHandsFree() -> AudioSessionPolicy       // Bluetooth microphones (MIC-5)
    @available(iOS 26.0, *) public func allowingHighQualityBluetoothRecording() -> AudioSessionPolicy
    public func deactivatingOnStop() -> AudioSessionPolicy               // CAP-4
}
```

**The audio session.**

- **CAP-1** The managed policies use category `.playAndRecord`. `.record` MUST NOT be used; it silences playback.
- **CAP-2** When the package sets the category itself, the options are `.defaultToSpeaker` and `.allowBluetoothA2DP`. Mixing with other apps, Bluetooth hands-free and high-quality Bluetooth recording are added only when the policy asks: a hands-free route degrades playback quality.
- **CAP-3** If the current category already permits input, the session MUST NOT be reconfigured, whatever its options. A redundant category change can disturb audio that is already playing.
- **CAP-4** The source calls `setActive(true)` and never calls `setActive(false)`, unless the policy says `deactivatingOnStop()`; then it passes `.notifyOthersOnDeactivation`.
- **CAP-5** `setAllowHapticsAndSystemSoundsDuringRecording(true)` is applied so recording does not mute the app's haptics and system sounds.
- **CAP-6** Voice processing (echo cancellation) is off by default; it changes the signal and is unsuitable for measurement.
- **CAP-7** With `.external` the source validates that the host's session permits input and otherwise throws `DSPError.sessionConfigurationFailed(reason:)`, naming the category it found.
- **CAP-8** System notifications become source events as follows. After `.resumed` and after any format change the stages start cold.

| Notification | The source | Events |
|---|---|---|
| Interruption began | Stops delivering; keeps its engine. | `.interrupted` |
| Interruption ended with `.shouldResume` | Activates the session again (CAP-4) and restarts its engine. | `.resumed` |
| Interruption ended without it | Stays stopped until the host calls `start()`. | — |
| Route change | Reads the input format again; MIC-4 decides which input is used. | `.routeChanged`, then `.formatChanged` if the format differs |
| The source's engine reports a configuration change (it has stopped itself, E-31) | Reads the format again and restarts its engine. | `.formatChanged` if the format differs |
| Media services were reset | Rebuilds its engine and sink node, applies the policy again, restarts if it was running. | `.mediaServicesReset`, then as for a route change |
| No input is available | Stops. | `.failed(.sourceUnavailable)` |

**Microphones.**

- **MIC-1** With no `input:` the source records from whatever input iOS has selected, which is the last external microphone connected, or the built-in one.
- **MIC-2** With an `input:` the source makes it the preferred input (and `dataSource:` the preferred data source) when it prepares. An input that is not available is `DSPError.sourceUnavailable(reason:)`.
- **MIC-3** `availableInputs` lists what the session offers under the given policy. Bluetooth microphones appear only under a policy that allows hands-free.
- **MIC-4** Hot-plug. If the selected input disappears, the source falls back to the system's choice, reports `.routeChanged(.inputLost)`, and reports `.formatChanged` when the format differs. If it returns while the source is still attached, it is selected again. The session survives both (ATT-4).
- **MIC-5** Bluetooth. Hands-free input is opt-in (CAP-2). High-quality Bluetooth recording is offered on iOS 26 and later.
- **MIC-6** The format is whatever the input delivers: sample rate and channel count are discovered, never assumed. A multichannel interface is reduced, or not, by the `ChannelPolicy` of the framing step (§5.3).

All of this is decided in types driven through seams (`AudioSessionControlling`, `MicrophoneAuthorizing`, an injected notification centre), so it is tested without hardware (COV-5). The host app must declare `NSMicrophoneUsageDescription`. Permission is requested through `AVAudioApplication` from iOS 17 and `AVAudioSession` before (E-16).

**Capture while the app plays** (R-22, WP-708). Two cases, both tested on a device with playback started first:

- **Case A, the host's session already permits input.** Nothing is reconfigured (CAP-3). The test asserts that playback kept rendering, that no interruption, no route change and no configuration change was posted, and that frames arrived.
- **Case B, the host's session does not permit input** (`.playback`, `.ambient`). One category change is unavoidable, and iOS may change the hardware format with it, which stops a playing `AVAudioEngine` (E-31). The package cannot prevent that; it makes the change once and keeps the output where it was. The test asserts no interruption, the same output port, at most one configuration change for the host's player, and that frames arrived. The documentation tells hosts to configure `.playAndRecord` before they start playback.

---

## 5. The declarative API

### 5.1 Two spellings, one description

```swift
// State a SwiftUI view owns
@State private var presence = true              // switches, §5.9
@State private var showMel = true
@State private var centroid: Float = 0          // a result, §5.10
let melFeed = HeatmapFeed()

// Result-builder spelling: one stage per line
let voice = Pipeline {
    Gain(.decibels(-3))
    HighPass(.butterworth, cutoff: .hertz(90), rollOff: .decibelsPerOctave(24))
    BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), isActive: $presence)
    if deEss {
        BandStop(.chebyshev2(stopband: .decibels(40)), from: .hertz(5_000), to: .hertz(9_000), order: 4)
    }
    Tap(isActive: $showMel) {                             // a side branch; the main line continues below it
        STFT(frame: 2_048, hop: 512, window: .hann)       // samples → complex spectrum
        Power()                                           // → power spectrum
        MelScale(bands: 128)                              // → mel power spectrum
        Decibels()                                        // → mel spectrum in decibels
        Emit(to: melFeed)
    }
    Tap {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        SpectralCentroid(to: $centroid)                   // writes its result; the spectrum passes on
    }
}

// Fluent spelling: each call returns a new description
let voice2 = Pipeline()
    .gain(.decibels(-3))
    .highPass(.butterworth, cutoff: .hertz(90), rollOff: .decibelsPerOctave(24))
    .bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), isActive: $presence)
    .tap(isActive: $showMel) {
        $0.stft(frame: 2_048, hop: 512, window: .hann).power().melScale(bands: 128).decibels().emit(to: melFeed)
    }
    .tap { $0.stft(frame: 1_024, hop: 256).magnitude().spectralCentroid(to: $centroid) }
```

- **API-1** Both spellings produce the same value, a `Pipeline<Input, Output>`: an immutable, typed wrapper around an ordered list of type-erased, `Hashable`, `Sendable` stage descriptions. `voice == voice2` when `deEss` is false. Equality is defined for everything a description can hold. A value that carries a closure compares by what it produces: an `EnvironmentReader` after the resolve pass, a custom window by its samples (WIN-2). Bindings compare as ACT-12 and OUT-4 state. Nothing else exists until the pipeline is attached.
- **API-2** `@PipelineBuilder` supports `if`, `if … else`, `switch`, `for … in` and `if #available`, within the limits of ORD-3.
- **API-3** A stage is a value type. Users add stages by conforming their own types (§5.11).
- **API-4** `Input` and `Output` are signal domains (§5.2). The compiler accepts a stage only where the domain before it is the one it consumes (§5.8). Only a `Pipeline<Samples, …>` can be attached to a source.
- **API-5** Every stock stage and every fluent modifier takes a trailing `isActive:` argument that defaults to `.active` (§5.9).
- **API-6** No configuration objects (§5.11.3).

### 5.2 Signal domains and stages

Every stage declares the domain it consumes and the domain it produces. A domain is a type with no values; it exists so that the compiler can check the order of stages.

| Domain | One frame is | Delivered as | Sampled sequence |
|---|---|---|---|
| `Samples` | A block of audio samples per channel | `AudioBlock` | Yes, at the sample rate |
| `Spectrum<Axis, Values>` | One value per frequency bin, once per hop. `Axis` is `LinearFrequency`, `MelFrequency` or `ConstantQFrequency`. `Values` is `ComplexValues`, `MagnitudeValues`, `PowerValues` or `DecibelValues`. | `ComplexFrame` for complex values, `RealFrame` otherwise | No |
| `Quefrency` | A cepstrum | `RealFrame` | No |
| `MelCepstrum` | Mel-frequency cepstral coefficients | `RealFrame` | No |
| `Chroma` | Twelve pitch-class energies | `RealFrame` | No |
| `Lags` | An autocorrelation over lag | `RealFrame` | No |
| `TempoSpectrum` | One column of a tempogram | `RealFrame` | No |
| `Envelope` | (min, max) pairs of a waveform | `EnvelopeFrame` | No |
| `Novelty` | One onset-strength value, once per hop | `ScalarFrame` | Yes, at the feature rate |
| `Scalar` | One value with a confidence, once per hop | `ScalarFrame` | Yes, at the feature rate |

A frame is a borrowed view, valid for the call that delivers it, with its index and its time in seconds since the session started. A stream copies it.

A `ScalarFrame` is a `value` and a `confidence` in 0…1. A step that has no value for a frame (the centroid of silence, a pitch with no peak) repeats its last value, or 0 before the first, with confidence 0. No step emits NaN (NUM-1).

**Scopes.** A *spectral scope* runs from a framing step (`STFT`, `ConstantQ`) to the end of its branch or to `InverseSTFT`. Inside it `sampleRate` is still the rate of the framed signal, and `frameSize`, `hopSize`, `frequencyResolution`, `featureRate` and `frequencyAxis` are set. A step that produces `Novelty` or `Scalar` starts a new sampled sequence: downstream of it `sampleRate` is the feature rate, `nyquistFrequency` is half of that, and the spectral keys are `nil` again. `LowPass(cutoff: .hertz(4))` on a novelty curve therefore means 4 Hz of the novelty signal.

**Sequence stages** run on any sampled sequence and keep its domain: `Gain`, `LowPass`, `HighPass`, `BandPass`, `BandStop` (IIR or FIR, by their first argument, §6.3), `BandBoost`, `LowShelf`, `HighShelf`, `Filter(_:)` (an `IIRSystem` or an `FIRSystem`), `Convolve`, `SavitzkyGolay`, `AlphaBeta`, and the rate changers `Decimate`, `Subsample`, `Upsample`, `Interpolate` (§6.12).

**Domain steps** move the signal from one domain to another:

| Step | Consumes | Produces |
|---|---|---|
| `STFT(frame:hop:window:paddedTo:)` | `Samples` | `Spectrum<LinearFrequency, ComplexValues>` |
| `InverseSTFT()` | `Spectrum<LinearFrequency, ComplexValues>` | `Samples` |
| `ConstantQ(…)` | `Samples` | `Spectrum<ConstantQFrequency, ComplexValues>` |
| `Magnitude()`, `Power()` | A complex spectrum on any axis | The same axis, magnitudes or powers |
| `Decibels(reference:floor:)` | Magnitudes or powers on any axis | The same axis, in decibels |
| `InverseDecibels(_:)` | A spectrum in decibels | The same axis, as `.magnitude` or `.power` |
| `MelScale(bands:…)` | Magnitudes or powers on a linear-frequency axis | The same values on a mel axis (§6.11) |
| `ConstantQScale(…)` | Magnitudes or powers on a linear-frequency axis | The same values on a constant-Q axis (§6.8) |
| `HarmonicPercussive(select:…)` | `Spectrum<LinearFrequency, ComplexValues>`, or magnitudes on any axis | The same domain, one component kept |
| `SpectralCentroid(range:)` | Magnitudes or powers on a linear-frequency axis | `Scalar` |
| `ChromaFold(normalization:)` | `Spectrum<ConstantQFrequency, MagnitudeValues>` | `Chroma` |
| `OnsetStrength(lag:maxSize:floor:)` | A spectrum in decibels on any axis | `Novelty` |
| `Tempogram(_:window:)` | `Novelty` | `TempoSpectrum` |
| `Cepstrum(_:)` | `Spectrum<LinearFrequency, ComplexValues>` | `Quefrency` |
| `InverseCepstrum()` | `Quefrency`, from `Cepstrum(.complex)` | `Spectrum<LinearFrequency, ComplexValues>` |
| `Lifter(_:)` | `Quefrency` | `Quefrency` |
| `CepstralPitch(range:)` | `Quefrency` | `Scalar` |
| `CepstralCoefficients(count:)` | `Spectrum<MelFrequency, DecibelValues>` | `MelCepstrum` |
| `InverseCepstralCoefficients(bands:)` | `MelCepstrum` | `Spectrum<MelFrequency, DecibelValues>` |
| `Autocorrelation(window:hop:maxLag:)` | Any sampled sequence | `Lags` |
| `Level(_:window:hop:)` | `Samples` | `Scalar` |
| `Waveform(resolution:)` | `Samples` | `Envelope` |

**Structure** keeps the domain:

| Construct | Role |
|---|---|
| `Tap { … }` | A side branch. It reads the signal at its position and leaves the main line untouched, so the main line can stay in the time domain while branches analyse it. Branches nest. |
| `Emit(to:)` | Sends the current frames to a sink and passes them on, so several sinks, or more steps, can follow. |
| `Group { … }` | Names a run of stages so that it can be switched or given an environment as one. It has the type of its content. |
| `EnvironmentReader { env in … }` | Builds its content from the environment at that position (§5.4). Its closure is a builder body with one return type, so its domains are known to the compiler whatever the environment holds. |

**Sinks.**

| Sink | Accepts | Delivery | Use |
|---|---|---|---|
| A SwiftUI `Binding` (§5.10) | `Scalar`, `Novelty` into `Binding<Float>` or `Binding<ScalarFrame>`; any real-vector domain into `Binding<[Float]>` | Main thread, at the result rate, only when the value changed | Read-outs and app state |
| `HeatmapFeed` | Any domain whose frame is a vector of reals: real-valued spectra, `Quefrency`, `MelCepstrum`, `Chroma`, `Lags`, `TempoSpectrum` | Lock-free, single writer, many readers | Visual components (§8) |
| `WaveformFeed` | `Envelope` | The same | `WaveformView` |
| `FeatureStream<Domain>` | Any domain | `AsyncSequence`, bounded: when the consumer lags, the oldest frames are dropped and counted | App logic off the main thread |
| `FeatureCallback<Domain>` | Any domain | Called on the analysis thread | Advanced; the closure is bound by RT-2 |

Feeds are created by the app with their history: `HeatmapFeed(history: 940, minimumHistory: 940)`, in columns (MEM-1).

**Recipes** are stages defined entirely by what they expand to. They add no behaviour of their own.

| Recipe | Expands to |
|---|---|
| `Spectrogram(frame:hop:window:to:)` | `Tap { STFT; Power; Decibels; Emit }` |
| `MelSpectrogram(frame:hop:bands:to:)` | `Tap { STFT; Power; MelScale; Decibels; Emit }` |
| `ChromaCQT(…to:)` | `Tap { ConstantQ; Magnitude; ChromaFold; Emit }` |
| `MFCC(count:melBands:to:)` | `Tap { STFT; Power; MelScale; Decibels; CepstralCoefficients; Emit }` |
| `HPSS(select:)` | `STFT; HarmonicPercussive(select:); InverseSTFT`, on the main line: samples in, samples out |
| The measuring spelling of a step that produces a `Scalar`: `Level(_:window:hop:to:)`, `SpectralCentroid(range:to:)`, `CepstralPitch(range:to:)` | `Tap { the step; Emit(to:) }`: the signal that follows is untouched (OUT-1) |

### 5.3 Strategy catalogue

Every algorithm with more than one credible implementation sits behind a public protocol, and the choice is a value passed where the stage is declared. A conformer written outside the package is passed the same way.

| Decision | Strategy | Stock values |
|---|---|---|
| IIR family | `FilterFamily` | `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`, `.elliptic(ripple:stopband:)`, `.bessel(normalization:)` |
| IIR order from a tolerance scheme | `FilterOrderStrategy` (mirrors etk4j's `FilterOrderCalculationStrategy`) | one per family except Bessel |
| Order from a slope | `RollOffRounding` | `.exact(relativeTolerance:)`, `.nearest`, `.up` |
| FIR method | `FIRDesignMethod` | `.windowedSinc(window:)`, `.leastSquares` |
| Window | `Window` | The vDSP set, the package set, `.custom { t in … }` (§6.4.2) |
| Fourier transform | `FFTBackend` | `.vDSP` (default); `.mpsGraph`, batched, iOS 17+ (optional, WP-613) |
| Convolution | `ConvolutionStrategy` | `.direct`, `.fft`, `.partitioned`, `.automatic` |
| Polynomial roots | `PolynomialRootFinder` | `.companionQR` |
| Biquad precision | `BiquadPrecision` | `.single`, `.double`, `.automatic` |
| Constant-Q transform | `ConstantQStrategy` | `.multirateSparseKernel` |
| Mel formula | `MelFormula` | `.slaney`, `.htk` |
| Mel band normalisation | `MelNormalization` | `.slaney`, `.none` |
| Chroma normalisation | `ChromaNormalization` | `.none`, `.l1`, `.l2`, `.max` |
| Tempogram | `TempogramMethod` | `.autocorrelation`, `.fourier` |
| Median | `MedianStrategy` | `.selectionNetwork`; `.incrementalSortedLanes` (optional, WP-533); `.metal`, offline (WP-612) |
| HPSS mask | `MaskStrategy` | `.hard`, `.soft(power:)` |
| Which implementation of a primitive | `Implementation` | `.automatic`, `.native`, `.accelerate`, `.metal` (§7.4) |
| Colour | `ColorMap` | viridis, magma, inferno, turbo, grayscale, custom stops |
| Frequency axis of a view | `FrequencyScale` | `.linear`, `.logarithmic`, `.mel` |
| Audio session | `AudioSessionPolicy` | §4.6 |
| Channels into a framing step | `ChannelPolicy` | `.mixdown`, `.channel(n)`, `.perChannel` |

### 5.4 Environment

The environment is to a pipeline what `EnvironmentValues` is to a SwiftUI view tree: typed, keyed values that the framework fills in and that stages read.

```swift
public protocol DSPEnvironmentKey { associatedtype Value: Sendable; static var defaultValue: Value { get } }

public struct DSPEnvironment: Sendable {
    public subscript<K: DSPEnvironmentKey>(key: K.Type) -> K.Value { get }
    public func setting<K: SettableDSPEnvironmentKey>(_ key: K.Type, to value: K.Value) -> DSPEnvironment
}

Pipeline {
    EnvironmentReader { env in
        LowPass(.butterworth, cutoff: .hertz(env.nyquistFrequency * 0.8), order: 6)
    }
}
```

| Built-in key | Type | Meaning | Set by |
|---|---|---|---|
| `sampleRate` | `Double` | Samples per second of the sequence at this point. | Source, rate-changing stages |
| `nyquistFrequency` | `Double` | `sampleRate / 2`. | Derived |
| `channelCount` | `Int` | Channels in the signal. | Source, channel policy |
| `blockSize` | `Int` | Frames per processing block. | Engine |
| `frameSize`, `hopSize` | `Int?` | Inside a spectral scope (§5.2). | Framing step |
| `frequencyResolution` | `Double?` | `sampleRate / frameSize`. | Derived |
| `featureRate` | `Double?` | `sampleRate / hopSize`, inside a spectral scope. | Derived |
| `frequencyAxis` | `FeedAxis?` | Inside a spectral scope: what the bins are. | Framing and axis steps |
| `latency` | `TimeInterval` | Delay accumulated by all stages upstream of this point. | Stages (REAL-5) |
| `isRealTime` | `Bool` | False for offline processing and `.asFastAsPossible` sources. | Engine |
| `sourceKind` | `SourceKind` | Informational only. Stages MUST NOT change behaviour on it. | Source |
| `implementation` | `Implementation` | Default `.automatic` (§7.4). | **Settable** |
| `biquadPrecision` | `BiquadPrecision` | Default `.automatic` (REAL-3). | **Settable** |
| `resultRate` | `Double` | How often bindings receive results, default 30 per second (OUT-2). | **Settable** |

- **ENV-1** The environment is **positional**. A rate-changing stage rewrites it for everything downstream: after `Decimate(by: 2)` the next stage sees half the sample rate and half the Nyquist frequency, and a cutoff that was legal upstream may be rejected downstream.
- **ENV-2** Every `Frequency` in a stage is resolved against the environment when the plan is compiled. A filter edge at or above Nyquist, or at or below 0 Hz, is rejected then (O-16), with an error that names the stage. It never becomes a silently aliased filter.
- **ENV-3** `.environment(\.key, value)` on a pipeline or a `Group` overrides a settable key for that scope and returns a new value. The settable keys are the three marked above and keys the app defines. Every other built-in key is derived and has no setter.
- **ENV-4** SwiftUI bridge (`ZTronDSPUI`): `.dspEnvironment(session)` publishes the values at the source, `\.dspSampleRate`, `\.dspNyquistFrequency`, `\.dspChannelCount`, and the main line's total `\.dspLatency`, into SwiftUI's `EnvironmentValues`. Positional values (the feature rate, the axis, the latency at a sink) are read from the feed, which records the environment at its `Emit`. The bridge publishes only when the session's format or topology changes, so it cannot cause per-frame view updates.

### 5.5 Describe → compile → run

This section answers the central design question: how to offer a declarative, decorator-style API with the smallest real-time cost.

#### 5.5.1 Options considered

| | Option | Cost on the hot path | Verdict |
|---|---|---|---|
| A | Object decorators called per sample | One dynamic call per stage per *sample*; blocks vectorisation | Rejected. |
| B | Object decorators called per block | One dynamic call per stage per block, plus reference counting; no optimisation across stages; description and live state are the same objects, so re-chaining means rebuilding live objects | Rejected. |
| C | Static generic composition (`Chain<Chain<A, B>, C>`) | None: the compiler inlines the chain | Cannot be re-chained at run time; forces internals to be `@inlinable` across modules; would put Swift on the I/O thread (E-02). Rejected as the run path. |
| D | Reactive operators (Combine, `AsyncSequence`) | Allocation and locking per element; unbounded queues | Rejected. This is what ZTronSpectrogram does today. |
| E | An `AVAudioEngine` graph, one node per stage | Fixed cost and format negotiation per node; analysis steps do not fit; no fusion | Rejected as the core. |
| **F** | **Describe → compile → run** | **One indirect C call per kernel per block. No allocation, no locking, no reference counting.** | **Adopted.** |

#### 5.5.2 Decision

The Decorator pattern is kept where it is free and removed where it costs. Stages decorate an immutable **description**. Attaching compiles the description, on the control context, into an **execution plan**: a flat table of `{function pointer, state pointer}` pairs implemented in C, with every buffer and setup already allocated and every implementation already chosen for its size (§7.4). The analysis thread runs the table with `ztd_plan_run`. Because the plan is built from a description that the plan compiler can see whole, adjacent stages are fused and shared work is done once.

In this document *compile time* always means the Swift compiler. What the plan compiler does happens at *attach time*.

#### 5.5.3 Plan compiler passes

1. **Resolve.** Walk the stages in order, threading the positional environment (ENV-1) and expanding every `EnvironmentReader`.
2. **Validate.** Stage order is re-checked on the erased description (§5.8, tier 2); then each stage checks its parameters against the environment. Errors carry the stage's path in the pipeline.
3. **Lower.** Each stage emits `KernelSpec` values (a closed enum of stock kernels, plus `.custom` and `.analysis`). Each spec is bound to an implementation by its size (SEL-3).
4. **Fuse.**
   - **F1** Adjacent gains multiply into one gain kernel. A gain is never folded into a filter: a later change must be able to ramp, and folding into a single-precision cascade costs accuracy for the price of one `vDSP_vsmul` (E-30).
   - **F2** Adjacent IIR stages of one precision become one cascade: a single setup with all sections. The output is bit-identical to the unfused chain.
   - **F3** Adjacent direct-form FIR stages are convolved into one kernel when the combined length stays under the direct / partitioned crossover. This saves a pass and a history buffer, not arithmetic.
   - **F4** Identities are removed: unity gain, a bypassed stage, an empty cascade.
   - **F5** Framing steps with equal parameters (frame size, hop, window, padding, channel policy) at the same position, in different branches, are computed once. A spectrogram, a centroid and HPSS declared in three taps cost one FFT per hop. The same holds for any equal run of steps that follows, such as `STFT → Power`.
   - Fusion never reorders stages and never crosses a tap point or a stage with a bound activation (ACT-6). Fused and unfused plans MUST agree: bit for bit under F1, F2 and F4, within −100 dB under F3 (tested).
5. **Allocate.** Create every setup, state block and work buffer.
6. **Emit.** Produce the C plan for the signal chain and the ordered list of analysis nodes.

#### 5.5.4 Changing a running pipeline

A pipeline is immutable. A change is a new pipeline handed to `session.update(_:)`, or to the view that hosts it (§8.7); the session works out the smallest thing to do.

| Change | Mechanism | Audible / visible effect |
|---|---|---|
| An equal pipeline | One description comparison. Bindings are captured again. | None. |
| The same topology with different values (a cutoff, a gain) | The changed stages are re-designed on the control context; the new values travel through an SPSC command queue and are applied at the next block boundary. A gain ramps over 10 ms. IIR coefficients are set in place and the filter keeps its memory. FIR taps of equal length are cross-faded over 10 ms. | CLICK-1 holds. |
| A different topology | A new plan is compiled on the control context and exchanged with one atomic pointer swap at a block boundary. What is unchanged keeps running; what is new is pre-rolled, then faded in (SWAP-1…4). | Unchanged feeds continue without a gap; changed branches refill. |
| A bound `isActive` binding flips (§5.9) | Sampled on the main run loop; a run-time switch in the plan, driven through the command queue. Nothing is compiled. | A faded bypass, or a branch suspended or resumed. |
| An animated change in a hosted pipeline (§8.7) | One same-topology update per display frame, with interpolated values. | A glide. |

**Topology.** Two descriptions have the same topology when they have the same stages in the same order, of equal kind, with equal structural values: orders, section counts, tap counts, frame and hop sizes, band counts, windows, strategies, constant activations, sinks. They may differ in what a kernel can take without re-allocation: gain amounts, the design values of an IIR at unchanged order and precision, FIR taps at unchanged length.

- **CLICK-1** Where this document says a change makes no click, the test is this. A full-scale 1 kHz sine at 48 kHz runs through the change. The largest sample-to-sample difference of the output, during the change and for one block after it, does not exceed 1.5 times the largest such difference in steady state on either side of the change.
- **SWAP-1 Unchanged stages keep running.** A kernel or node whose own description and whole upstream path are equal in both plans is moved into the new plan with its state. An unchanged branch does not notice the exchange, and its feed continues.
- **SWAP-2 New stages on the main line are pre-rolled.** For their settling time (declared by each stage, capped at one second) the old plan still produces the output while the new stages run beside it on the same input with their output discarded. Then old and new outputs are cross-faded over 10 ms, provided the domain, rate and latency of the output are unchanged. Otherwise the output changes at a block boundary and the session reports `.outputChanged`.
- **SWAP-3 New branches start cold** (ACT-10). Their sinks receive frames once their histories are full; a feed whose branch changed is cleared at the exchange.
- **SWAP-4 The latest update wins.** An update that arrives while another is still being compiled or pre-rolled replaces it. Value changes that arrive in that window are applied to the plan that ends up running.

```swift
@State private var cutoff = 1_000.0

var voice: Pipeline<Samples, Samples> { Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4) } }

// Imperatively:                 try await session.update(voice)        // after `cutoff` changed
// Declaratively, in a view:     SpectrogramView(source: mic).processing(voice)     // §8.1; animatable, §8.7
```

### 5.6 Real-time rules

- **RT-1** Code that runs on the audio I/O thread is C or Objective-C in `CZTronDSP`, declared `nonblocking`, and compiled with function-effect warnings as errors. No Swift runs there (E-02).
- **RT-2** In steady state the analysis thread performs no heap allocation, takes no lock, sends no Objective-C message that can autorelease, logs nothing, and never `await`s. Dynamic dispatch is allowed once per kernel or node per block, never inside a per-sample loop.
- **RT-3** All memory a plan needs is allocated when the plan is compiled and freed when it is retired, both off the analysis thread.
- **RT-4** State crosses threads only through SPSC rings, the SPSC command queue, the atomic plan slot, single atomic words, a feed's sequence-locked column store, or a result's latest-value slot.
- **RT-5** Hot-path storage is `AlignedBuffer` or raw pointers. `Array` is not used where copy-on-write could trigger.
- **RT-6** No kernel leaves denormal state behind: at the end of each block it sets to zero any state value whose magnitude is below 10⁻²⁰. The floating-point environment is not changed, because the functions that change it are not `nonblocking` and system libraries are not guaranteed to behave under a non-default mode (E-03).
- **RT-7** Verification is layered, because no single mechanism covers everything (E-03…E-06):
  1. C: function-effect errors with the audited vDSP allow-list.
  2. Swift: `@_noAllocation @_noLocks` on pure-Swift leaf loops, behind the build setting `ZTRONDSP_PERF_ANNOTATIONS`, because the attributes are underscored and may change between toolchains.
  3. Run time: every kernel and every analysis node runs 1 000 blocks, and every stock pipeline 10 000 blocks, inside `expectNoAllocations { }`, which counts the audited thread only.
  4. Lint: `DispatchSemaphore`, `NSLock`, `os_unfair_lock`, `objc_sync_enter`, `.sync {`, `Task {`, `await`, `print(` and `Logger` are banned in directories marked hot (`Kernels/`, `Nodes/`, `Engine/Run/`).
- **RT-8** A hardware source that overruns its ring drops the newest frames, counts them, and reports `.overrun`. It never blocks and never grows the ring. A reader thread (`FileSource`) waits for space instead; it is not a real-time thread.
- **RT-9** The analysis thread is created at user-interactive quality of service and asks for a Mach time-constraint policy whose period is the poll interval. If the request is refused it keeps its quality of service and the engine reports it. Rings and their mirrors are touched page by page when they are created, so the I/O thread never takes a first-touch fault.

### 5.7 Overhead budget

These are the acceptance figures for the claim in §5.5. They are targets until WP-324 measures them on the host of §3 and WP-903a on the reference devices; a miss is a change request, not a silent relaxation.

| Quantity | Target |
|---|---|
| Dispatch cost of the plan runner | ≤ 25 ns per kernel per block |
| Reference chain `Gain → 8-section IIR → Gain`, 512 frames, declared through the facade, versus the same three vDSP calls written by hand | ≤ 1.02 × + 75 ns |
| Two adjacent 4-section IIR stages (fused to one cascade) versus two hand-written `vDSP_biquad` calls | Faster |
| Allocations and lock acquisitions on the analysis thread, steady state | 0 |
| Cost of an equal `update(_:)` | No plan work; one description comparison |
| A bound switch on an active stage without latency | ≤ 5 ns per block |
| A bound switch on an active stage with latency | The above plus one copy of the block (ACT-8) |
| Choosing an implementation by size | 0 on the hot path (SEL-3) |
| The binding pump, 16 bound switches | ≤ 2 µs per main-run-loop turn |
| A stage written outside the package against its stock twin | ≤ 5 % slower (EXT-4) |

### 5.8 Stage order

Not every order of stages means something. A low-pass filter after an STFT, a mel conversion after the decibel conversion, an inverse STFT after the phase has been thrown away: each is a mistake, and each should be impossible to write rather than something discovered by listening. This section says which orders are invalid and where each is caught. The mechanism was verified by compiling probes (E-19…E-23) before it was specified.

#### 5.8.1 Catalogue of order rules

| Rule | Example of the wrong order | Why it is wrong | Caught |
|---|---|---|---|
| **O-1** Sequence stages run on sampled sequences | `STFT → LowPass` | In v1 a frame of bins is not a sequence in time; filtering each band along time is deferred (D-11) | Compile time |
| **O-2** Spectral steps need a spectrum | `Gain → MelScale` | There are no bins yet | Compile time |
| **O-3** `Magnitude` and `Power` need complex values | `Power → Power` | Already real | Compile time |
| **O-4** `Decibels` needs magnitudes or powers | `Decibels → Decibels` | The logarithm of a logarithm | Compile time |
| **O-5** `MelScale` needs a linear-frequency axis and magnitudes or powers | `Decibels → MelScale`, `MelScale → MelScale`, `STFT → MelScale` | A mel band sums energy, and decibels do not add; the axis is already mel; the values are still complex | Compile time |
| **O-6** `InverseSTFT` needs the complex linear-frequency spectrum | `Power → InverseSTFT`, `MelScale → InverseSTFT` | Phase, or resolution, is gone | Compile time |
| **O-7** `ChromaFold` needs constant-Q magnitudes | `STFT → Magnitude → ChromaFold` | The bins are not spaced by semitones | Compile time |
| **O-8** `SpectralCentroid` needs magnitudes or powers on a linear-frequency axis | `Decibels → SpectralCentroid`, `MelScale → SpectralCentroid` | The weights must be non-negative energies on evenly spaced bins; over normalised mel bands the result is not the centroid | Compile time |
| **O-9** `OnsetStrength` needs a spectrum in decibels; `Tempogram` needs a novelty curve | `Gain → Tempogram` | Each consumes the other's kind of output | Compile time |
| **O-10** `CepstralCoefficients` needs a mel spectrum in decibels; `Lifter` and `CepstralPitch` need a cepstrum | `MelScale → CepstralCoefficients` | The coefficients are defined on log energies | Compile time |
| **O-11** A sink takes a domain it can represent | A complex spectrum into a `HeatmapFeed`; a spectrum into a `Binding<Float>` | Nothing to draw, or nothing to hold | Compile time |
| **O-12** An attached pipeline starts from samples | `attach(Pipeline { OnsetStrength() … })` | A source delivers samples | Compile time |
| **O-13** A stage that may be absent, or repeated, keeps the domain | `if x { STFT(…) }` | The pipeline must be valid with and without it | Compile time |
| **O-14** Both branches of `if … else` end in the same domain | `if x { STFT(…) } else { ConstantQ() }` | The next stage needs one domain | Compile time |
| **O-15** A side branch starts in the domain of the point it taps | `STFT(…); Tap { STFT(…) }` | The branch receives spectra, not samples | Compile time |
| **O-16** A frequency lies below the Nyquist frequency *at its position* | `Decimate(by: 4) → LowPass(cutoff: .hertz(10_000))` at 48 kHz | It depends on the sample rate | Attach time |
| **O-17** Transform lengths, constant-Q hop divisibility, the overlap-add condition, an FIR slope that would put the stop-band edge past Nyquist | `STFT(frame: 1_000, …)` | They depend on values | Attach time |
| **O-18** Every mel band covers at least one bin; the mel range ends at or below Nyquist | 128 bands on a 256-point frame | It depends on values | Attach time |

#### 5.8.2 Where each rule is enforced

**Tier 1: compile time, by the types.**

- A self-typed stage conforms to `PipelineStage` and names its `Input` and `Output`. `Pipeline<Input, Output>` is itself a stage, so pipelines nest.
- The result builder composes with partial blocks. Appending stage `S` to an accumulated `Pipeline<I, M>` requires `S.Input == M` and yields `Pipeline<I, S.Output>`. The accumulated type is always a `Pipeline`, never a nested generic, so type-checking stays linear in the number of stages (E-22).
- A step whose result depends on what precedes it cannot be a generic type inferred from context (E-20). It is a plain value, and its typing rule is written once per family as a builder overload and as a fluent method constrained on the output domain; for example `melScale(bands:)` exists only `where Output == Spectrum<LinearFrequency, V>, V: LinearValued`. The families are: the sequence stages, `Magnitude`, `Power`, `Decibels`, `InverseDecibels`, `MelScale`, `ConstantQScale`, `SpectralCentroid`, `OnsetStrength`, `HarmonicPercussive`, `Autocorrelation`, `Emit`, and the measuring spellings.
- A block made only of sequence stages is a `SequenceChain`. It has no domain of its own and takes the domain of the place where it is used: samples at the top of a pipeline, a novelty curve after `OnsetStrength`.
- `DSPEngine.attach` and `PipelineSession.update` take `Pipeline<Samples, Output>`.

**Tier 2: attach time, on the type-erased description.**

- Every stage description carries a `DomainRule`: the same rule the types express, as a function from an input `DomainTag` to an output tag, or to nothing.
- The plan compiler's validation pass first walks the description and applies these rules, then checks the value-dependent rules O-16…O-18 against the positional environment. A violation is `DSPError.invalidStageOrder(stage:found:)` or `DSPError.invalidParameter`, carrying the stage's path.
- This tier is what protects a pipeline whose types are not known when the app is compiled (ORD-5).

**Run time.** Nothing. A compiled plan cannot be out of order.

- **ORD-1** Every stage declares its domains, either as `Input` and `Output` or by belonging to a context-dependent family. A family is one constraint on the consumed domain, one builder overload, one fluent method and one `DomainRule` case. Users add families of their own by extending `PipelineBuilder` (§5.11).
- **ORD-2** Tier 1 and tier 2 MUST agree. A generated matrix, every public stage on every domain, is compiled and also run through the `DomainRule`s; acceptance by the compiler must coincide with acceptance by the rule (WP-328).
- **ORD-3** Control flow. A stage inside `if` without `else`, inside `for`, or inside `if #available` keeps the domain (O-13). The branches of `if … else` and `switch` end in the same domain (O-14). A block begins with a self-typed stage, a sequence stage, a `Group` or an `EnvironmentReader`; a branch that must begin with another context-dependent step is written fluently, as `.tap { $0.spectralCentroid() … }` on the stage it follows. Two branches that differ only in the arguments of one context-dependent step are written as one step with a conditional argument, `MelScale(bands: wide ? 64 : 40)` (E-19).
- **ORD-4** Diagnostics. With many overloads the compiler's own report of a failed match is often unusable. Each tier-1 rule therefore has a catch-all overload marked unavailable, one per family and one per self-typed stock stage, whose message names the stage and says what it needs, for example: *"MelScale needs a linear-frequency spectrum of magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it."* Must-not-compile fixtures assert on that sentence (WP-009). Known exception: branches of `if … else` that end in different domains are rejected with the compiler's generic message (E-21).
- **ORD-5** `DynamicPipeline` is the type-erased pipeline for chains assembled from data. `append(_:)` applies the tier-2 rule and throws. It attaches and updates like a typed pipeline, and the same stages give the same plan.
- **ORD-6** Types do not replace validation. Tier 2 runs for every pipeline, typed or not.

#### 5.8.3 Changing the chain, and what stays checked

| You want | Use | Checked by |
|---|---|---|
| A stage present or absent, decided when the pipeline is built | `if` in the builder, for stages that keep the domain; otherwise build two pipelines and `update(_:)` | Tier 1 |
| A stage switched on and off while the pipeline runs | `isActive:` (§5.9). The types do not change and nothing is rebuilt. | Tier 1 |
| A chain assembled from data: a preset file, a rack the user edits | `DynamicPipeline` | Tier 2 |

#### 5.8.4 Limits

- The request asks whether the *class* structure can enforce order. In Swift the tool that does it is protocols with associated types on generic value types, not a class hierarchy (IN-12). A hierarchy could separate "time-domain stage" from "spectral stage", but not `Decibels → MelScale` from `MelScale → Decibels`.
- The types know domains, not numbers. Anything that depends on the sample rate or on a value is a tier-2 rule.
- The purpose-written messages of ORD-4 depend on how the compiler ranks an unavailable overload. If a future compiler changes that, messages degrade; rejection does not. The fluent spelling reports precise messages unaided.

### 5.9 Activation: bypassing and shutting stages down

Every stage can be switched off, and back on, while the pipeline runs, without rebuilding anything. The switch is a SwiftUI `Binding`.

```swift
struct Controls: View {
    @State private var presence = true
    @State private var showMel = true

    var voice: Pipeline<Samples, Samples> {
        Pipeline {
            BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), isActive: $presence)
            MelSpectrogram(frame: 2_048, hop: 512, bands: 128, to: melFeed, isActive: $showMel)
            LowPass(.butterworth, cutoff: .hertz(8_000), order: 4)                    // default: .active
            LowPass(.butterworth, cutoff: .hertz(8_000), order: 4, isActive: false)   // constant: compiled away
        }
    }

    var body: some View {
        Toggle("Presence", isOn: $presence)        // flips the stage at the next block boundary
        Toggle("Mel spectrogram", isOn: $showMel)  // suspends or resumes the branch
    }
}
```

- **ACT-1 API.** Every stock stage initialiser and every fluent modifier takes a trailing `isActive:` argument, defaulting to `.active`. It accepts `true` or `false`, `.active` or `.bypassed`, or a `Binding<Bool>`. Recipes, `Tap`, `Group` and `Emit` take it too. Custom stages get it from the modifier `.active(_:)`. `EnvironmentReader` and `.environment` have nothing to switch. Inside `IIRSystem { }` and `FIRSystem { }` an element with a non-default `isActive` is rejected when the system is resolved: a system is switched whole, through `Filter(_:isActive:)`.
- **ACT-2 The argument's type** is `some ActivationSource`, a protocol adopted by `Bool`, `Activation` and `Binding<Bool>` (E-24). It is not `Binding<Bool>` with a default of `.constant(true)`: a constant binding cannot be told from a live one, so every stage would carry a run-time switch and lose fusion. Write `true`, or leave the argument out; do not write `.constant(true)`.
- **ACT-3 Meaning.** An inactive stage does no work.
  - If the stage keeps both the domain and the rate (gains, filters, smoothers, taps, sinks, groups and recipes that do), the signal passes through unchanged: the stage is **bypassed**.
  - If the stage changes the domain or the rate (`STFT`, `MelScale`, `Decibels`, `Decimate`, …), the signal cannot pass it. The rest of its branch is **suspended**: the branch of the enclosing `Tap`, or everything after the stage when it sits on the main line. Sinks in a suspended branch receive nothing.
- **ACT-4 Constants cost nothing.** A constant activation is resolved when the plan is compiled. `.active` leaves no trace. `.bypassed` removes the stage (F4), or the remainder of its branch.
- **ACT-5 Bound switches do not recompile.** A stage with a bound activation gets a run-time switch in the plan. A change, sampled on the main run loop (BIND-2), travels through the command queue (RT-4) and takes effect at the next block boundary. The active path pays one flag test per switched kernel or node per block.
- **ACT-6 Fusion barrier.** A stage with a bound activation is not fused with its neighbours (F1–F3), because it must be removable on its own. A binding has no identity, so two stages given the same binding are still two switches. To switch several stages as one fused unit, wrap them in `Group(isActive:)`.
- **ACT-7 No clicks.** A switch is a cross-fade of 10 ms, never shorter than one block, between the processed and the unprocessed signal (CLICK-1).
  - Off: fade to the unprocessed signal; then the stage stops running.
  - On: the stage is reset and **pre-rolled**. It runs, with its output discarded, for its latency plus its settling time, and only then is faded in. Restoring therefore takes effect after the pre-roll; before it, nothing changes.
- **ACT-8 Constant latency.** Switching never changes the session's latency or the alignment of anything downstream. A stage with latency L (a linear-phase FIR, `SavitzkyGolay`, `HPSS(select:)`) has an unprocessed path that is a delay line of L samples. The line is fed in both states, because it must already hold the last L inputs when the switch goes off. It exists only when the activation is bound, and costs one copy of the block per block while the stage is active.
- **ACT-9 Shared work follows its consumers.** A shared framing step (F5) runs only while at least one active consumer needs it. A suspended branch costs nothing, including its transform when no other branch uses it.
- **ACT-10 Cold resume.** A branch that resumes starts as it does at session start. Histories (a tempogram window, the median history of HPSS, constant-Q buffers) refill, and frames reappear once the stage has what it needs. No stale frame is emitted.
- **ACT-11 Feeds and views.** A feed whose branch is suspended keeps its contents and is no longer live, so the view's display link pauses (§8.3) and nothing is drawn until the branch resumes.
- **ACT-12 Description equality.** Activation is part of a stage's description. Constants compare by value, so the default, `true` and `.active` are equal. A bound activation differs from every constant, and all bound activations compare equal, because a binding offers no identity; `update(_:)` therefore always captures the bindings of the pipeline it is given. An `update(_:)` that flips a constant is a topology change in which only that stage is new (SWAP-1, SWAP-2). Flipping a binding needs no update at all.

**How the session reads a binding.**

- **BIND-1** A binding is read and written only on the main actor. The session never touches one on the analysis thread or the control context.
- **BIND-2** While a session is running and its pipeline has a bound switch or a bound result, it keeps one observer on the main run loop (before waiting, common modes). On each pass it reads every captured switch and sends a command for each value that changed. A write made on the main thread, by a control or by code, is therefore seen in the same run-loop turn (E-25). Switches need no timer: an idle loop does no work.
- **BIND-3** A write made off the main thread is seen at the main run loop's next turn, which an idle app may delay. `session.syncBindings()` samples at once; hopping to the main actor to call it is what wakes the loop.
- **BIND-4 Capture.** `attach` and `update(_:)` capture the pipeline's bindings and read their current values on the main actor; the plan is then compiled off the main thread with those values.
- **BIND-5 One way.** The session reads switches and writes results (§5.10). It never writes a switch.
- **BIND-6 Lifetime.** Captured bindings are released by the next `update(_:)` and by `detach()`. The host keeps the state behind a binding alive at least that long; what a binding returns after its state is gone is SwiftUI's business and is not relied on.
- **BIND-7** `Binding` is named only in `ZTronDSPCore/Bindings/`, through `import struct SwiftUI.Binding`, which leaves every other SwiftUI name out of scope (E-28). (Lint: no other SwiftUI import outside `ZTronDSPUI`.)

### 5.10 Results and bindings

A step that reduces the signal to a result delivers it into a SwiftUI `Binding` and lets the chain go on.

```swift
@State private var level: Float = -160
@State private var centroid: Float = 0
@State private var smoothed: Float = 0

Pipeline {
    Level(.rms, to: $level)                           // measures; the samples pass on
    HighPass(.butterworth, cutoff: .hertz(90), order: 4)
    Tap {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        SpectralCentroid(to: $centroid)               // measures; the spectrum passes on
        Decibels()
        Emit(to: feed)                                // … so the same branch can still feed a view
    }
    Tap {                                             // the transforming spelling, for results that are processed further
        STFT(frame: 1_024, hop: 256); Magnitude(); SpectralCentroid()
        LowPass(.butterworth, cutoff: .hertz(4), order: 2)
        Emit(to: $smoothed)
    }
}
```

- **OUT-1 Two spellings.** Every step that produces a `Scalar` has a measuring spelling, `Step(…, to: binding)`. It keeps the domain of the signal it measures and passes that signal on unchanged, so it returns a component the chain continues from; it equals `Tap { Step(…); Emit(to: binding) }`. The transforming spelling, without `to:`, moves the chain into the `Scalar` domain for further processing. `Emit(to: binding)` writes any `Scalar`, `Novelty` or real-vector frame.
- **OUT-2 Delivery.** The analysis thread writes each result into a pre-allocated latest-value slot, wait-free. On the main run loop the session copies each slot whose value changed into its binding. A heartbeat timer at the result rate (`resultRate`, default 30 per second) turns the loop while the session runs and has bound results; with none there is no timer.
- **OUT-3 No needless invalidation.** A binding is written on the main actor only, at most once per heartbeat, and never with a value equal to the last one written. Results are for read-outs; the data of a heat map goes through a feed, which no view observes (V-2).
- **OUT-4 No identity.** Two attachments of one pipeline both write its bindings, and the last write wins. Give each attachment its own state, as with sinks (ATT-5).
- **OUT-5** `Binding<[Float]>` receives a new array per delivery, allocated on the main thread; it is meant for small frames such as chroma or cepstral coefficients. When the session stops, a binding keeps its last value.

### 5.11 Extension, visibility, immutability

#### 5.11.1 Written for extension

| To add | Conform to, or use | Runs on | Supplies |
|---|---|---|---|
| A step between domains | `PipelineStage` and an `AnalysisNode` | Analysis thread | `Input`, `Output`; the node; latency and settling time |
| A sample-domain stage in Swift | `SampleProcessor` | Analysis thread | `process(_:)` on a block, `reset()`, latency |
| A sample-domain stage in C | `SequenceStage` with a `ztd_kernel_t` | Analysis thread; the I/O thread too, should D-1 land | The kernel table and its state |
| A context-dependent family | Extensions of `PipelineBuilder` and `Pipeline` | — | One constraint, one overload, one fluent method, one `DomainRule` (ORD-1) |
| A sink | `FeatureSink` | Analysis thread | `write(_:)`; claim and release (ATT-5) |
| A source | `PushSampleSource` or `PullSampleSource` | Its own clock, or the analysis thread | §4.4 |
| A design or a strategy | `FilterFamily`, `FIRDesignMethod`, `MedianStrategy`, `FFTBackend`, `ColorMap`, … (§5.3) | Control context | The protocol's members |
| A window | `Window.custom { t in … }` | Control context | A closure (§6.4.2) |
| An inverse with its report | `InvertibleStage` | Background | The inverse stage and its conditions (§6.13) |
| An export | `MATLABExportable` | Background | Variables and plot commands (§6.14) |
| A display | `HeatmapView(feed:)`, `WaveformView(feed:)` | Main thread | A feed |

```swift
public protocol PipelineStage: Hashable, Sendable {
    associatedtype Input: SignalDomain
    associatedtype Output: SignalDomain
    func lower(_ context: inout LoweringContext) throws(DSPError)    // control context: emit kernels or one node
}

public protocol AnalysisNode: AnyObject {
    var latencyFrames: Int { get }
    var settlingFrames: Int { get }                                   // SWAP-2, ACT-7
    func process(_ input: FrameView, _ output: inout FrameWriter)     // analysis thread, RT-2; may write no frame, or several
    func reset()                                                      // cold start, ACT-10
}

public protocol SampleProcessor: AnyObject {
    var latencyFrames: Int { get }
    var settlingFrames: Int { get }
    func process(_ block: inout AudioBlock)                           // analysis thread, RT-2
    func reset()
}

public protocol FeatureSink: AnyObject, Sendable {
    associatedtype Domain: SignalDomain
    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError)   // control context, ATT-5
    func write(_ frame: FrameView)                                    // analysis thread, RT-2
    func release()
}
```

```c
typedef struct ztd_kernel {
    void (*process)(void *state, const float *const *in, float *const *out, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING;
    void (*command)(void *state, const ztd_command_t *command) ZTD_NONBLOCKING;   /* a value or a switch */
    void (*reset)(void *state) ZTD_NONBLOCKING;
    void (*destroy)(void *state);                                                 /* control context */
    void *state;
    uint32_t latency_frames, settling_frames;
} ztd_kernel_t;
```

These shapes are fixed by WP-204, WP-301, WP-321a and WP-339; after that a change is a change request.

- **EXT-1 Structural parity.** No processing stage lives in `ZTronDSPCore`. `ZTronDSPDesign` and `ZTronDSPAnalysis` reach the core only through its `public` declarations: no `@_spi`, no `package` access, no `@testable import` in production code (lint and API digest). A stock stage therefore has nothing a user's stage lacks.
- **EXT-2 What every stage gets without writing it:** order checking in both tiers; the positional environment; attach-time validation with its path in the error; activation through `.active(_:)`; latency accounting; state carried across plan changes; shared upstream framing (F5); implementation selection through the toolkit. A stage that lowers to stock kernel specs is fused like a stock stage; one with its own kernel is a fusion barrier.
- **EXT-3 The tools are public.** The toolkit (§5.11.4) and the test product `ZTronDSPTesting` are what the stock stages are built and tested with.
- **EXT-4 Tested from outside.** A package that depends only on the three products re-implements `Gain` as a `SampleProcessor`, an IIR low-pass on its own C kernel, and a mel projection as a node. Each gives the output of its stock twin (bit for bit where the kernel is the same, within 10⁻⁶ otherwise), runs within 5 % of its speed, passes the allocation audit, is order-checked by must-not-compile fixtures, and is switched through a binding (WP-907).

#### 5.11.2 Visibility

- **VIS-1** Access level follows the kind of thing:

  | Kind | Declared as | Why |
  |---|---|---|
  | Descriptions, designs, units, reports, tables | `public struct` with `let` stored properties | Values; immutable (IMM-1) |
  | Engine, session, feeds, sources | `public final class` | Identity is the point; never subclassed |
  | Extension points | `public protocol` | Composition instead of inheritance |
  | Toolkit primitives and frame accessors | `public`, `@inlinable`; their internals `@usableFromInline` | A loop in a user's module compiles to the same code as one in ours, with no call per element |
  | Plan compiler, plan, command queue, binding pump | `internal` | Part of no contract |
  | Hooks for the package's own tests | `package` | Never used by production code of Design, Metal, Analysis, IO or UI |

  There is no `open` class: nothing is designed for subclassing. Lint keeps a register of every `open` declaration and every public setter; both registers start empty.
- **VIS-2** Every public symbol is documented with its threading contract: which context may call it, and whether it may allocate.
- **VIS-3** The public surface is recorded in a committed API digest (WP-013). Changing it is a change request.

#### 5.11.3 Immutability and no configuration objects

- **IMM-1** Stages, pipelines, designs, systems, windows, reports and tables are immutable values. What reads like a mutation, a fluent call or a modifier, returns a new value.
- **IMM-2** No public stored property of a value type is `var`, and no reference type has a public setter, except those entered with a reason in `Docs/Process/mutable-by-design.md`.
- **IMM-3** Mutable state exists in four places, each because performance or its nature demands it: the state and work buffers of kernels and nodes (owned by a plan, touched by one thread); rings, feeds and result slots (single writer); the control state of an engine or session (behind its lock); GPU resources of a renderer (main thread).
- **IMM-4** A running plan is changed only by commands that carry values or switches. A structural change is a new plan (SWAP-1…4).
- **IMM-5** The environment is a value. `.environment(_:_:)` returns a new pipeline, and the plan compiler threads copies.
- **API-6 No configuration objects.** No public initialiser, function or modifier takes an object whose job is to carry settings: nothing named or shaped like a configuration, options, settings, style, descriptor or specification. A setting is a labelled argument with a default, a strategy value that answers one question, or a chained modifier. What Draft 2 called `EngineConfiguration`, `SpectrogramStyle` and `FilterSpecification` are now arguments of `DSPEngine.init`, view modifiers (§8.1) and arguments of the filter initialisers (§6.3.2). A report is not such an object: it carries what was found. (Lint: public type names ending in `Configuration`, `Options`, `Settings`, `Style`, `Descriptor`, `Specification`, `Specs` or `Params`.)

#### 5.11.4 The toolkit

What the stock stages are written with, public in `ZTronDSPCore` unless noted:

| Helper | What it gives |
|---|---|
| `AlignedBuffer` | Owned, aligned, fixed-capacity storage without copy-on-write. |
| `HistoryBuffer` | The last N frames as one contiguous window. |
| `OverlapAdder` | Overlap-add with window-sum normalisation. |
| `Vector` | Element-wise operations and reductions, each bound to the fastest implementation for its length (§7.4). |
| `zeroPadded`, `subsampled`, `upsampled` | The padding and rate hooks as functions (§6.12). |
| `isFastLength`, `nextFastLength` | Transform lengths, by arithmetic (E-09). |
| `Ramp` | A value that moves to its target over a fixed time. |
| `flushSmallState` | State hygiene (RT-6). |
| Decibel conversions | Scalar and vector, with floors (§6.2). |
| `StageValidation` | The checks stock stages make, with errors that carry the stage's path: a frequency against Nyquist, a length against the rule, a value against a range. |
| `Window.samples(count:)`, `FFTBackend` plans (Analysis) | A window sampled once; a transform setup with its lifetime. |
| `BackgroundWork` | The executor behind every analysis and export (§9.2). |
| `ZTronDSPTesting` (product) | `expectNoAllocations`, `expectClose`, seeded signals, scripted sources. |

---

## 6. DSP features

### 6.1 Conventions

- **Samples** are `Float` (32-bit), non-interleaved, one buffer per channel. **Design maths** (coefficients, roots, responses) is `Double`.
- **`Frequency`**: `.hertz`, `.normalized` (cycles per sample, 0…0.5), `.fractionOfNyquist` (0…1), `.radiansPerSample`, `.midiNote`, `.mel` (§6.11). Always resolved against the environment (ENV-2).
- **`Amplification`** is the unit of a gain, a ripple or an attenuation: `.linear` or `.decibels`. Amplitude decibels are 20·log₁₀, power decibels 10·log₁₀. Conversions clamp at a floor (default −160 dB) instead of returning −∞. (`Gain` is the stage that applies one.)
- **Spectra** are one-sided: N/2 + 1 bins for a transform of length N. The transform backend returns the mathematically unscaled DFT, X[k] = Σ x[n]·e^(−j2πkn/N); any library scale factor is absorbed inside the backend and pinned by a parity test against a naive DFT.
- **Tolerances on spectra** are relative to the largest value of the frame, not to each bin: the Float32 transform has an error floor of about 8·10⁻⁸ of that maximum (E-30), so a bin 100 dB below the peak is only known to a few per cent.
- **Edges.** A centred framer reflects the signal without repeating the edge sample (x[−k] = x[k]). A median filter reflects with the edge sample repeated (x[−k] = x[k − 1]).
- **NUM-1 No NaN, no infinity.** Every division states its result for a zero or sub-floor denominator, and every logarithm has a floor; the sections below give each case. A non-finite sample arriving from a source is replaced by 0 at the source adapter and counted in `SessionEvent.nonFiniteInput`.
- **Parity references** are SciPy and librosa, at versions pinned in `Tests/Golden/generators/requirements.txt`. A generator passes every argument explicitly and never relies on a library default (STG-2). etk4j is itself a SciPy port, so SciPy vectors are the parity oracle for Appendix A.

### 6.2 Gain and decibel conversion

- `Gain(_ amount: Amplification, ramp: TimeInterval = 0.010)`, optionally per channel. Adjacent gains merge (F1). A changed amount ramps linearly to its new value (`vDSP_vrampmul`), so a change never produces a step.
- `DSP.decibels(fromAmplitude:reference:)`, `DSP.decibels(fromPower:reference:)` and their inverses, scalar and vector (`vDSP_vdbcon`).
- `Level(_ kind:window:hop:)`: peak or RMS in dBFS over its own window and hop, given in seconds (defaults 50 ms and 10 ms), so the values do not depend on the engine's block size. `Level(_:window:hop:to:)` is its measuring spelling (OUT-1).

### 6.3 Linear time-invariant systems

#### 6.3.1 Representations

`ZeroPoleGain`, `TransferFunction` (numerator and denominator coefficients) and `SecondOrderSections`, each tagged with a domain, `.analog` or `.digital`. ZPK is the working form for design; SOS is the only form that is ever run (REAL-1); the coefficient form exists for interchange and for parity with etk4j. All three, and the two system builders of §6.3.7, adopt `LTISystem`, which provides the analysis of §6.3.8.

#### 6.3.2 IIR design

Design path: analog low-pass prototype (ZPK) → frequency transformation in ZPK form (low-pass, high-pass, band-pass, band-stop) → pre-warped bilinear transform → section pairing ("nearest" rule, sections ordered so that the poles closest to the unit circle come last).

| Family | Parameters | Prototype |
|---|---|---|
| Butterworth | order | Poles equally spaced on the left half of the unit circle. |
| Chebyshev I | order, pass-band ripple | Poles on an ellipse; equiripple pass band. |
| Chebyshev II | order, stop-band attenuation | Inverse Chebyshev; finite zeros; equiripple stop band. |
| Elliptic | order, ripple, attenuation | Jacobi elliptic functions computed by Landen transformations; no iterative minimiser. |
| Bessel | order, normalisation `.phase` / `.delay` / `.magnitude` | Roots of the reverse Bessel polynomial: Campos starting values refined by Aberth iteration. |

Order is given in one of three ways, each as plain arguments:

```swift
LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(24))                                  // §6.3.4
LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000),
        maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))                                           // tolerance scheme
```

For a tolerance scheme the family's `FilterOrderStrategy` returns the minimum order and the natural frequency. Bessel has no order estimation, as in etk4j.

#### 6.3.3 FIR design

A response stage takes its design as its first argument: an IIR `FilterFamily` or an FIR `FIRDesignMethod`. FIR filters therefore have the same four stages and the same spelling.

```swift
LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255)
LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401)
```

| Method | Definition |
|---|---|
| `.windowedSinc(window:)` | Ideal response truncated by a window; low-pass, high-pass, band-pass, band-stop. Kaiser length and β are estimated from attenuation and transition width. Even lengths are rejected where the response at Nyquist must be non-zero. |
| `.leastSquares` | Weighted least-squares fit to the ideal response with linear transition bands. The normal equations are solved with LAPACK (`dposv`); when they are not positive definite, or their estimated reciprocal condition (`dpocon`) is below 10⁻¹⁰, the fit is redone with `dgelsd`. |

Inside an `FIRSystem` two further elements exist: `Taps([…])`, caller-supplied coefficients, and `LeastSquares(length:bands:desired:weights:)`, the same fit to any piecewise-linear target. Equiripple (Parks–McClellan) design is deferred (D-3).

#### 6.3.4 Roll-off per octave

`RollOff` is `.decibelsPerOctave`, `.decibelsPerDecade` or `.order`. One order contributes 20·log₁₀2 = 6.0206 dB per octave (20 dB per decade).

| Design | What `rollOff:` means | Mapping |
|---|---|---|
| Butterworth, Chebyshev I, Bessel: the analog prototype | The asymptotic slope of the stop-band skirt. Exact. | n = slope / 6.0206 |
| The same families, digital high-pass | The slope towards 0 Hz. Exact. | n as above |
| The same families, digital low-pass, and the upper skirt of a digital band-pass | The slope well below Nyquist. The bilinear transform puts n zeros at Nyquist, so the skirt steepens as it approaches it: within ±0.5 dB per octave in octaves that end at or below f_s/32, steeper above. | n as above |
| The same families, band-pass | The slope of each skirt, with the remarks above. | Prototype order n; the filter has order 2n. |
| The same families, band-stop | A notch has no asymptotic skirt: the gain falls without bound at the centre. `rollOff:` only sets the prototype order. | Prototype order n; the filter has order 2n. |
| Chebyshev II, elliptic | **Nominal.** The order whose all-pole counterpart has that slope. The real transition is steeper and the stop band is bounded by the stated attenuation, not by a slope. The documentation of both families says so. | n as above |
| `BandBoost` with an order | The slope of each skirt of the underlying order-N prototype, with the remarks above. | N as above |
| FIR | The *average* slope across the transition band, from the pass-band edge down to the stop-band attenuation A. | Transition width = A / slope octaves; stop-band edge = f_p·2^(±A/slope); length from the Kaiser estimate. An edge that falls beyond Nyquist or below 0 Hz is rejected at attach time (O-17), naming the smallest slope that fits. |

`RollOffRounding` decides what happens when the slope is not a whole number of orders: `.exact(relativeTolerance: 0.02)` (default) throws; `.nearest` rounds; `.up` guarantees at least the requested slope. So 12, 24, 48 and 96 dB per octave give orders 2, 4, 8 and 16; 25 dB per octave throws by default and gives order 5 with `.up`.

#### 6.3.5 Band-boost and shelving

- `BandBoost(center:gain:bandwidth:)`: second-order peaking section (Audio EQ Cookbook). A negative gain cuts.
- `BandBoost(center:gain:bandwidth:order:)` or `rollOff:`: high-order, maximally flat band-boost (Orfanidis 2005, Butterworth type): ⌊N/2⌋ fourth-order sections plus one second-order section when N is odd, run as biquads. Order 1 is the second-order section above. The design is carried out and paired in ZPK form; forming the fourth-order sections from the closed-form coefficients loses accuracy for narrow, low bands.
- Bandwidth is measured between the two frequencies where the gain is half the requested gain in decibels. `.hertz(w)` is met exactly on the digital frequency axis (the design pre-warps it). `.octaves(b)` is converted to its width in hertz, f₀·(2^(b/2) − 2^(−b/2)), and then met exactly. `.q(Q)` follows the Cookbook definition, α = sin ω₀ / 2Q. A band whose upper half-gain frequency would reach 0.49·f_s is rejected at attach time.
- `LowShelf`, `HighShelf`: the Cookbook's second-order shelves, with slope or Q. They are included because they share the peaking section's derivation; nothing else depends on them.
- Optional (WP-422): a matched design for the second-order peak, which removes the response cramping near Nyquist.

Acceptance for every band-boost design, for orders 1…8, gains ±1…±24 dB, centres from 20 Hz to 0.45·f_s, bandwidths within the limit above:

1. Gain at the centre equals the requested gain within 0.01 dB.
2. The gain equals half the requested gain (in dB) at exactly two frequencies; for a bandwidth given in hertz their distance is that bandwidth within 0.5 %.
3. Gain at 0 Hz and at Nyquist is 0 dB within 0.01 dB. (The matched design of WP-422 is exempt: it is not 0 dB at Nyquist by construction.)
4. The magnitude is monotonic on each side of the centre.
5. All poles lie strictly inside the unit circle.
6. A boost of +G cascaded with a cut of −G at the same centre, bandwidth and order is the identity within 10⁻⁶, evaluated from the ZPK forms.

#### 6.3.6 Smoothing filters

- `SavitzkyGolay(window:polynomialOrder:derivative:edge:)`: coefficients from a least-squares polynomial fit, solved by QR (LAPACK `dgels`) on an abscissa scaled to [−1, 1], applied as an FIR. Edge modes: `.interpolate` (polynomial fit at the ends), `.mirror`, `.nearest`, `.constant(value)`, `.wrap`; every mode of etk4j's `Mode` is covered.
- `AlphaBeta(alpha:beta:initialPosition:initialVelocity:)`: the two-state tracker; the time step comes from the environment's sample rate. Outputs position; `output: .velocity` selects the velocity instead.

In a real-time chain Savitzky–Golay runs as a centred FIR with latency (window − 1)/2; the edge mode matters only offline and at stream start.

#### 6.3.7 Declarative system design

```swift
let hum = IIRSystem {
    Zero(onUnitCircleAt: .hertz(50))                       // the conjugate is added automatically
    Pole(radius: 0.985, frequency: .hertz(50))
    HighPass(.butterworth, cutoff: .hertz(30), rollOff: .decibelsPerOctave(12))
    Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
}

let antiAlias = FIRSystem {
    LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
    Taps([0.25, 0.5, 0.25])
}

let report = try await hum.analysis(sampleRate: 48_000)    // runs in the background (BG-1)
report.poles; report.zeros; report.gain
report.isStable; report.stabilityMargin; report.isMinimumPhase
report.recommendedPrecision                                // numerical figures, §6.3.8
let script = try await report.matlabScript()               // §6.14

Pipeline { Filter(hum); Filter(antiAlias) }
```

Elements inside one builder are cascaded. `IIRSystem` accepts poles, zeros, sections, difference equations (`DifferenceEquation(b:a:)`, y[n] = Σ bₖ·x[n − k] − Σ aₖ·y[n − k] with a₀ normalised to 1) and the IIR forms of the response and equaliser stages. `FIRSystem` accepts the FIR forms of the response stages, `Taps`, `LeastSquares` and zeros, and rejects anything that would place a pole away from the origin. The response and equaliser stages (`LowPass` … `HighShelf`) are values: each is a pipeline stage and an element of a system builder. The smoothing stages are pipeline stages only.

#### 6.3.8 Numerical analysis

`analysis(sampleRate:)` is asynchronous and returns an immutable `SystemAnalysis`.

| Member | How it is computed |
|---|---|
| `zeros`, `poles`, `gain` | Read from the ZPK form when the system was built from designs, poles, zeros or sections: closed form per section, no polynomial is ever expanded. For a system given as coefficients: eigenvalues of the companion matrix, balanced by scaling only (LAPACK `dgebal` with `JOB = 'S'`, which keeps its Hessenberg form), found with `dhseqr`, then at most two Newton steps on the original polynomial. |
| `isStable`, `stabilityMargin` | Digital: max ‖p‖ < 1, margin 1 − max ‖p‖. Analog: max Re p < 0, margin −max Re p. |
| `isMinimumPhase`, `isLinearPhase` | Zeros inside or on the unit circle (analog: in the closed left half plane); FIR taps symmetric or antisymmetric. |
| `frequencyResponse(at:)`, `magnitudeResponse(at:in:)`, `phaseResponse(at:unwrapped:)` | Product of section responses for IIR; DFT of the zero-padded taps for FIR. |
| `groupDelay(at:)` | Closed form per section; for FIR, Re{DFT(n·h) / DFT(h)}. Where ‖H‖ is below 10⁻¹² of its maximum (a zero on the unit circle) the delay is undefined and reported as `nil`. |
| `impulseResponse(count:)`, `stepResponse(count:)` | By running the realised kernels offline, so analysis and execution cannot disagree. |
| `order`, `kind`, `sections` | Structural. |
| `rootConditions` | For roots found from coefficients: the condition number of each root with respect to the coefficients, κ(r) = Σ ‖aₖ‖·‖r‖ᵏ / (‖r‖·‖p′(r)‖). |
| `roundOffNoiseGain(precision:)` | The power gain from round-off injected at each section to the output, summed over sections, in decibels. |
| `singleVersusDoubleDeviation` | Measured, not estimated: the realised cascade is run in both precisions on an impulse and on seeded noise, 4 096 samples each; the larger deviation in dB relative to the output's peak. |
| `recommendedPrecision` | `.double` when that deviation exceeds −100 dB (REAL-3). |

Limits, stated rather than hidden. Root finding is O(n³) and is capped at degree 512 (`DSPError.unsupportedConfiguration` above; see D-4). The error of a simple root is about κ(r)·ε after polishing: 10⁻¹⁰ for well-conditioned fixtures (κ ≤ 10⁴), but 10⁻³ for the degree-20 Wilkinson polynomial and 10⁻¹ for an expanded order-16 Butterworth denominator at 1 kHz. That is why designs stay in ZPK form. A root of multiplicity m is only recoverable to about ε^(1/m); a fixture with a triple root documents the achieved accuracy.

#### 6.3.9 Realisation rules

- **REAL-1** An IIR system always runs as cascaded second-order sections.
- **REAL-2** Compiling an IIR whose largest pole radius is ≥ 1 fails with `DSPError.unstableDesign(maxPoleRadius:)`.
- **REAL-3 Precision.** `.single` runs on `vDSP_biquad`. `.double` runs on the package's own kernel, a transposed direct form II in C with double state and coefficients, because vDSP's double-precision setup has no coefficient setter at the floor (E-08). `.automatic` decides by measurement when the plan is compiled: the `singleVersusDoubleDeviation` of §6.3.8 is computed on the control context, and the double path is chosen above −100 dB. An update whose new design would choose the other precision replaces the kernel as a topology change (SWAP-2).
- **REAL-4** An FIR runs directly up to the calibrated crossover length (initially 256 taps) and as a partitioned convolution above it.
- **REAL-5** Each stage reports its latency: (K − 1)/2 for a linear-phase FIR, the frame for an STFT round trip, the look-ahead for HPSS, zero for IIR. The sum is the environment's `latency`.

### 6.4 Spectral front-end

#### 6.4.1 Framer, transform, values, inverse

- **Framer.** Frame N, hop H, mode `.causal` (the frame ends at the newest sample) or `.centered` (frame k is centred on sample k·H, with reflection at the start; latency N/2; matches offline tools called with the same arguments).
- **Transform.** `FFTBackend.vDSP` uses the vDSP DFT. The transform length must be a power of two, or f·2ⁿ with f ∈ {3, 5, 15} and n ≥ 4. The rule is applied by arithmetic; a setup is never created to find out (E-09). `DSP.nextFastLength(_:)` returns the smallest such length. Any other length is rejected at attach time (O-17) with an error that suggests the nearest legal ones. Buffers handed to the transform are 16-byte aligned, as the header recommends.
- **Zero-padding.** `STFT(frame:hop:window:paddedTo:)` pads each windowed frame with zeros to a longer transform length. The bins are spaced more finely; no information is added, and the frame still sets the resolution (§6.12).
- **Values.** `STFT` emits complex frames and takes a window normalisation: `.none`, `.amplitude` (a full-scale sine reads 0 dBFS) or `.power`. `Magnitude()` or `Power()`, and then `Decibels()`, convert them (O-3, O-4).
- **Inverse.** `InverseSTFT` is overlap-add with window-sum-of-squares normalisation. The plan compiler checks that the window and hop satisfy the non-zero overlap-add condition and rejects the pair otherwise (O-17). Reconstruction SNR ≥ 100 dB for constant-overlap-add configurations. §6.13 gives its invertibility report.

#### 6.4.2 Windows

```swift
STFT(frame: 2_048, hop: 512, window: .hann)                          // vDSP_hann_window, denormalised
STFT(frame: 2_048, hop: 512, window: .hann(.normalized))
STFT(frame: 2_048, hop: 512, window: .kaiser(beta: 8.6))             // computed by the package
STFT(frame: 2_048, hop: 512, window: .custom { t in                  // t runs from 0 to 1 across the frame
    0.5 - 0.5 * cos(2 * .pi * t)
}.logged())

let report = try await Window.custom { t in exp(-18 * (t - 0.5) * (t - 0.5)) }.analysis(frame: 2_048, hop: 512)
```

| Window | Generated by |
|---|---|
| `.hann`, `.hann(.normalized)` | `vDSP_hann_window` with `vDSP_HANN_DENORM` or `vDSP_HANN_NORM` |
| `.hamming` | `vDSP_hamm_window` |
| `.blackman` | `vDSP_blkman_window` |
| Any of the three with `.half` | The same call with `vDSP_HALF_WINDOW` |
| `.rectangular`, `.blackmanHarris`, `.kaiser(beta:)`, `.flatTop`, `.gaussian(sigma:)` | The package, in double precision |
| `.custom { t in … }` | The caller's closure |

- **WIN-1 One to one with vDSP.** The first four rows are the whole of what vDSP generates (E-27), and each is produced by the vDSP call named, bit for bit. vDSP's windows are periodic, the form a transform wants. `.symmetric` gives the form a filter design wants; for the vDSP windows it is still generated by vDSP, one sample shorter and closed with its first value.
- **WIN-2 A custom window** is a closure `(Double) -> Double` evaluated at t = n / N for n = 0 … N − 1, once, in double precision, when the plan is compiled. A window is zero outside the frame, whatever the closure returns there. Two custom windows are equal when their closures agree at 65 probe points across the frame and they share the periodic or symmetric choice; that is what lets a pipeline that contains one be compared (API-1).
- **WIN-3 Checked, as errors, at attach time:** a sample that is not finite; a window that is zero everywhere; and, with an `InverseSTFT` downstream, a window and hop that fail the non-zero overlap-add condition (O-17).
- **WIN-4 Analysed and reported, never an error.** `window.analysis(frame:hop:)` runs in the background (BG-1) and returns a `WindowAnalysis`:

  | Question | How it is answered | Reported as |
  |---|---|---|
  | Does it tend to 0 as t → ±∞? | The closure is evaluated at 2ᵏ frame lengths on either side of the frame, k = 0 … 20. | `tailLimit`: `.zero`, `.value(c)`, `.unbounded` or `.undefined`. A closure that does not decay is a truncated function, not a window, and the report says so. |
  | Is it normalised? | Sums over the samples. | `peak`, `coherentGain` (the mean), `noiseGain` (the mean square), `equivalentNoiseBandwidth` in bins, and the factors that `.amplitude` and `.power` normalisation apply |
  | Is it continuous? | The largest jump between neighbouring samples on grids of N, 2N and 4N points, the frame edges included, where the outside is 0. A jump that does not shrink as the grid is refined is a discontinuity. | `discontinuities` (position and size), `edgeValues` |
  | How smooth is it? | Finite differences of order 1 to 4 on the same grids, tested the same way. | `smoothness`: the order of the lowest derivative that jumps, 0 … 4 (0 means the window itself jumps), and the side-lobe fall-off it predicts, 6·(smoothness + 1) dB per octave |
  | Is it integrable? | Riemann sums of ‖w‖ and w² on the three grids are finite and agree within 10⁻⁶; outside the frame the tail samples decay faster than 1/‖t‖. | `isAbsolutelyIntegrable`, `isSquareIntegrable`, each for the frame and for the whole line |
  | What does its spectrum look like? | A transform of the window zero-padded 16 times. | `mainLobeWidth` (at −3 dB and null to null, in bins), `peakSideLobe`, `sideLobeFallOff` (measured), `scallopingLoss` |
  | Does it overlap-add? | The sums of w and of w² over shifts by the hop. | `isNonZeroOverlapAdd`, `isConstantOverlapAdd`, `overlapRipple` |
  | What shape is it? | — | `isSymmetric`, `isNonNegative`, `isFinite` |

- **WIN-5 Logging is opt-in.** For a window written `.logged()` the analysis is also run once per attachment, on the control context, and written to `os.Logger` (category `window`), one line per property. Otherwise nothing is logged. The analysis is available for every window, not only custom ones.
- **WIN-6 Limits of the method.** The answers are numerical: a verdict holds at the grids named. Derivative estimates amplify round-off, so the closure is evaluated in double precision, the step is never below 2⁻¹² of the frame, and smoothness is reported only up to order 4. The report exports as a MATLAB script (§6.14).

### 6.5 Spectral centroid

C = Σ f_k·m_k / Σ m_k over the bins of a linear-frequency axis inside an optional `[fmin, fmax]`, with m the magnitude (default) or the power. Implementation: one dot product against a frequency ramp computed once, and one sum, on the shared spectral frame. When Σ m_k is below a floor the frame has confidence 0 and repeats the last value (§5.2); a NaN is never emitted. The step is not offered on a mel or constant-Q axis: over bands of unequal, normalised width the same formula is not the centroid (O-8).

Acceptance, with a Hann window: a sine at f₀ gives f₀ within half a bin; white noise gives f_s/4 within 2 % in the mean over 200 frames; silence gives confidence 0; zero allocations.

### 6.6 Cepstrum

| Kind | Definition |
|---|---|
| Real | IDFT(ln ‖X‖) |
| Power | ‖IDFT(ln ‖X‖²)‖² |
| Complex | IDFT(ln ‖X‖ + j·unwrap(∠X)), linear-phase term removed and reported; invertible |

- Logarithms are floored (default 10⁻¹⁰).
- `InverseCepstrum()` undoes `Cepstrum(.complex)`: DFT, exponential, the linear-phase term restored (§6.13).
- `Lifter`: `.lowTime(cutoff)` for the spectral envelope, `.highTime(cutoff)` for the excitation, `.sinusoidal(length)`.
- `CepstralPitch(range:)`: the peak quefrency inside [1/f_max, 1/f_min] with parabolic interpolation, as f₀ in hertz. Its confidence is 1 − μ/p clamped to 0 … 1, where p is the peak and μ the mean absolute value of the cepstrum inside the range. `CepstralPitch(range:to:)` is its measuring spelling.
- `CepstralCoefficients(count:)`, and the recipe `MFCC` built on it: a mel spectrum in decibels (§6.11) → orthonormal DCT-II. The vDSP DCT is used when the band count is a documented length (64, 80 and 128 are; 26 and 40 are not); a pre-computed basis and `cblas_sgemv` otherwise. The decision is arithmetic (E-09). `InverseCepstralCoefficients(bands:)` applies the transposed basis; it is exact when `count` equals the band count.

### 6.7 Convolution, correlation, autocorrelation

```swift
DSP.convolve(x, h, mode: .full, strategy: .automatic)            // modes: .full, .same, .valid
DSP.correlate(x, y, mode: .full, normalization: .none)           // .none, .biased, .unbiased, .coefficient
DSP.autocorrelate(x, maxLag: 2_048, normalization: .coefficient)
```

- `.direct`: `vDSP_conv`, O(N·K). `.fft`: zero-pad to `nextFastLength(N + K − 1)`, multiply spectra (conjugate one for correlation), invert. `.automatic` uses a cost model whose crossover is calibrated by WP-611c.
- A `.coefficient` normalisation whose denominator is below the floor gives zeros (NUM-1).
- Streaming: `Convolve(kernel:)` is a sequence stage (direct, or partitioned with the partition equal to the block so that no latency is added). `Autocorrelation(window:hop:maxLag:)` is a step using the Wiener–Khinchin relation on the shared framer; the frame is zero-padded to at least window + maxLag, so the result is the linear autocorrelation, not the circular one.

### 6.8 Constant-Q transform and chroma

Parameters and defaults: `fmin` C1 (32.70 Hz), `octaves` 7, `binsPerOctave` 36 (a multiple of 12 for chroma), `tuning` 0 (in fractions of a bin), `filterScale` 1, `gamma` 0, `hop` 512, Hann window, kernel sparsity 0.01.

- Geometry: f_k = f_min·2^((k + tuning)/B); α = 2^(1/B) − 1; Q = filterScale / α; atom length N_k = ⌈Q·f_s / (f_k + γ/α)⌉. Tuning moves the bin centres, so it belongs to the transform, not to the folding. With γ > 0 the transform is variable-Q: low-frequency atoms are shorter, which is the lever for latency in real time.
- **`ConstantQ`**, the transform (strategy `.multirateSparseKernel`). One sparse spectral kernel for the top octave. Each lower octave reuses it on the signal decimated by two through a half-band FIR. The hop halves per octave, so `hop` must be divisible by 2^(octaves − 1); otherwise attaching fails and names the nearest legal hops (O-17). Octaves are time-aligned to the lowest one, whose half-atom length is the stage's latency. The kernel is stored as CSR with split real and imaginary values (E-11).
- **`ConstantQScale`**, the pseudo constant-Q. An axis conversion like `MelScale`: magnitudes are projected through the magnitude of the kernel's response, powers through its square. One FFT, no phase; intended for chroma when `fmin` is high enough that a single frame resolves it.
- **`ChromaFold`**, and the recipe `ChromaCQT` built on it. Bin k belongs to pitch class round(12·k / B) mod 12, so each class collects the B/12 bins nearest to its semitone in every octave. The magnitudes of a class are summed, thresholded, and the twelve values normalised per frame with the chosen `ChromaNormalization`. A frame whose norm is below the floor is twelve zeros (NUM-1).

Acceptance: a tone at a bin centre appears in that bin within 0.5 dB of its amplitude; the strongest pitch class is correct for a fixture covering all 12 classes in every octave; frame-wise cosine similarity ≥ 0.98 against reference chroma on the music fixtures.

### 6.9 Onset strength and tempograms

- **`OnsetStrength(lag:maxSize:floor:)`** consumes a spectrum S in decibels, by custom a mel spectrum (§6.11): o[t] = mean over bands of max(0, S[f, t] − R[f, t − lag]), where R is S itself or S max-filtered along frequency (`vDSP_vswmax`), which suppresses vibrato. Values of S below `floor` (default −80 dB re full scale) are raised to it first; without that, the fluctuation of the noise floor counts as onsets.
- **`Tempogram(.autocorrelation)`**: for each feature frame, the last W onset values (default 384) have their mean removed, are windowed, zero-padded to the next fast length at or above 2W − 1, and autocorrelated by FFT, then normalised by lag 0. A frame whose lag-0 value is below the floor is zeros. Lag ℓ corresponds to 60·featureRate/ℓ BPM.
- **`Tempogram(.fourier)`**: the magnitude spectrum of the same windowed, mean-removed segment, zero-padded four times (`resolution:` changes the factor). Frequency f corresponds to 60·f BPM; the rows are 60·featureRate / length BPM apart.
- Both emit only the rows inside `range:` (default 30 … 300 BPM). The feed's `FeedAxis` gives the tempo of each row, so a view labels them without knowing how they were produced.
- Alignment: `.causal` (no added latency; the estimate describes the last W frames) or `.centered` (matches offline tools; latency W/2 frames).

Acceptance, on a 120 BPM click track at 44.1 and 48 kHz with hop 512: in both tempograms the row nearest to 120 BPM is a local maximum; in the autocorrelation tempogram it is the largest value of the frame; in the Fourier tempogram the largest values lie on the rows nearest to 120 BPM and its multiples. Frame-wise cosine similarity ≥ 0.99 against the reference on fixtures generated with the same arguments.

### 6.10 Harmonic–percussive separation

- H = median of the magnitude spectrogram along **time** (`timeKernel`, default 31 frames); P = median along **frequency** (`frequencyKernel`, default 31 bins). Kernels are odd; 17 and 17 is the low-latency setting. Edges are reflected with the edge value repeated (§6.1).
- Masks: `.soft(power: p)` gives M_H = H^p / (H^p + (m_H·P)^p) and symmetrically M_P; `.hard` is the limit. Margins `harmonicMargin`, `percussiveMargin` > 1 leave a residual R = 1 − M_H − M_P. Where the denominator is below the floor both masks are 0 (NUM-1).
- Time alignment: `.causal` uses frames [t − L_h + 1, t] (no latency, a slight bias toward the past) or `.centered` with a look-ahead of (L_h − 1)/2 frames (equals the offline result).
- `HarmonicPercussive(select:)` is the step. On a complex spectrum it applies the chosen mask and keeps the phase; on magnitudes it returns that component's magnitudes. The recipe `HPSS(select:)` wraps it between `STFT` and `InverseSTFT` and passes the component down the main line; its latency is one frame plus the look-ahead.
- The median is computed by a selection network over lanes (§7.2). In the time direction a lane is one stored frame; in the frequency direction a lane is the current frame shifted by one bin. Both therefore use the same primitive: an element-wise minimum and maximum of two vectors. Offline, on whole spectrograms, `.metal` runs the same network per texel (WP-612).

Acceptance, on interior frames in centred mode: soft masks equal the reference's within 10⁻³ on bins above −60 dB of the frame maximum; hard masks agree on at least 99.9 % of those bins (they flip on ties); harmonic + percussive (+ residual) reconstruct the input with SNR ≥ 100 dB.

### 6.11 Mel scale

**Conversions.** `MelFormula` is `.slaney` (default) or `.htk`.

| Formula | Hertz → mel |
|---|---|
| `.slaney` | m = 3f / 200 below 1 000 Hz; m = 15 + 27·ln(f / 1 000) / ln 6.4 at and above it |
| `.htk` | m = 2 595·log₁₀(1 + f / 700) |

`DSP.mel(fromHertz:formula:)` and `DSP.hertz(fromMel:formula:)` are exact inverses of each other, scalar and vector, in double precision. `Frequency.mel(_:formula:)` states a frequency on the mel scale wherever a `Frequency` is accepted.

**`MelScale(bands:range:formula:normalization:)`** is the processing step. It consumes magnitudes or powers on a linear-frequency axis and produces the same kind of value on a mel axis with `bands` bins (O-5).

- Band edges: `bands + 2` points equally spaced on the mel scale across `range`, which defaults to 0 Hz … the Nyquist frequency of the environment.
- Band m is a triangle that rises linearly in hertz from edge m to edge m + 1 and falls to edge m + 2, evaluated at the bin centres k·f_s / N.
- `MelNormalization.slaney` (default) scales each triangle by 2 / (edge m + 2 − edge m), which gives the continuous triangle unit area; `.none` leaves each peak at 1.
- Order relative to its neighbours: after `Magnitude()` or `Power()`, before `Decibels()`. The reverse orders do not compile.
- Attach-time checks (O-18): the range lies within 0 … Nyquist and is not empty; every band has at least one bin with a non-zero weight. A failure is `DSPError.invalidParameter`, naming the first empty band and the smallest frame size that would fill it.
- Implementation: each bin belongs to at most two bands, so the weights are stored banded (first bin, count, weights) and applied with one dot product per band. A dense `cblas_sgemv` is the other implementation; the crossover table chooses (§7.4).
- Downstream, the feed's `FeedAxis` and the environment describe a mel axis (band centres in hertz), so a view labels the rows correctly without knowing how they were produced.

The recipe `MelSpectrogram` is `STFT → Power → MelScale → Decibels`. `OnsetStrength` and `CepstralCoefficients` consume a mel spectrum in decibels.

Converting to the mel scale is not the same as *displaying* a linear spectrogram on a mel axis. The latter is the `.frequencyScale(.mel)` modifier of `SpectrogramView` (§8.1): it moves pixels and changes no data. Going back from mel bands to linear bins is lossy and is not provided (D-10).

Acceptance: conversions round-trip within 10⁻⁹ relative for both formulas, and 1 000 Hz is 15 mel (Slaney); the weights equal the reference filter bank within 10⁻⁶; under `.slaney` the peak of band m equals 2 / (f₍m+2₎ − f₍m₎) (the sampled weights are not required to sum to one); the mel power spectrogram of the fixtures equals the reference within 10⁻⁴ of the frame maximum; a configuration with an empty band is rejected and the error names the band; the step is allocation-free.

### 6.12 Padding and rate changes

Each hook exists twice: as a stage, for a pipeline, and as a function in the toolkit (§5.11.4), for whoever writes a stage.

| Hook | Stage | Function | What it does |
|---|---|---|---|
| Zero-padding | `STFT(…paddedTo:)`; `Autocorrelation` and the tempograms pad by rule | `zeroPadded(_:to:placement:)` | Adds zeros after the samples, or split around the centre. Finer bins; no new information. |
| Subsampling | `Subsample(by: M, phase:)` | `subsampled(_:by:phase:)` | Keeps every M-th sample. No filter: what aliases, aliases, and the inversion report says how much (§6.13). |
| Decimation | `Decimate(by: M)` | `DSP.decimate` | Low-pass, then subsample (`vDSP_desamp`). The default filter is a Kaiser windowed sinc with at least 80 dB of rejection from the new Nyquist frequency up; latency (K − 1)/2 input samples. |
| Upsampling | `Upsample(by: L)` | `upsampled(_:by:)` | Inserts L − 1 zeros after each sample. No filter: the images remain. |
| Interpolation | `Interpolate(by: L)` | `DSP.interpolate` | Upsample, then low-pass with gain L, as a polyphase filter: L short filters, one per output phase, so no multiplication is spent on an inserted zero. |

The four stages are sequence stages that change the rate; the environment downstream follows (ENV-1). A rational factor is `Interpolate(by: L)` followed by `Decimate(by: M)`; arbitrary ratios are a non-goal (§1.4).

### 6.13 Inverse operations and the inversion report

Every operation that has an inverse comes with it, and with a report on how well it inverts.

| Forward | Inverse | Condition, and the theorem behind it | Tested on | Error when it fails |
|---|---|---|---|---|
| `Subsample`, `Decimate` | `Interpolate` | Sampling theorem: the signal is band-limited below f_s / 2M | The signal: the share of its energy at or above f_s / 2M | That share is aliased and lost |
| `Upsample` | `Subsample` | None | — | None: bit-exact |
| `zeroPadded` | Truncation | None | — | None |
| `STFT` | `InverseSTFT` | Non-zero overlap-add: Σ w²(n − kH) > 0 for every n. Constant overlap-add for a flat response. | The window and hop | Amplified by B/A, the ratio of the greatest to the least value of Σ w² (the frame bounds) |
| `Decibels` | `InverseDecibels` | Values above the floor | The frames: the share of bins at the floor | Bins at the floor return the floor |
| `Cepstrum(.complex)` | `InverseCepstrum` | A finite log spectrum, and a phase unwrapped without ambiguity | The frames: bins at the floor; the largest phase step between bins | Those bins are lost |
| `CepstralCoefficients` | `InverseCepstralCoefficients` | Full rank: `count` equals the band count | The counts | The energy of the dropped coefficients |
| `Magnitude` ↔ `Power` (on real values) | Square root, square | Non-negative values | — | Round-off only |
| `Magnitude` and `Power` of a complex spectrum, `MelScale`, `ConstantQ`, `ConstantQScale`, `ChromaFold`, `OnsetStrength`, the tempograms | None | Phase or resolution is discarded | — | Not offered (D-6, D-10) |

```swift
let report = try await STFT(frame: 2_048, hop: 512, window: .hann)
    .inversionReport(for: samples, sampleRate: 48_000)       // background (BG-1)

report.isExactlyInvertible       // every condition holds
report.conditions                // each: the theorem, whether it holds, its margin
report.predictedError            // from the conditions: a bound on the relative error
report.measuredError             // from a real round trip on these samples: SNR and largest error
```

- **INV-1** Every stage with an inverse conforms to `InvertibleStage`: it names its inverse and states its conditions. The protocol is public, so a stage written outside the package gets the same report.
- **INV-2** A report has three parts: the conditions, each with its theorem, its verdict and its margin; the error the conditions predict; and, when a signal is supplied, the error measured by performing the round trip. A condition about the signal is evaluated on the signal supplied.
- **INV-3** A failed condition is reported, not thrown. Only the attach-time rules (O-17) stop a pipeline.
- **INV-4** Reports are immutable values, computed in the background, and export as MATLAB (the original, the reconstruction and their difference).

### 6.14 MATLAB export

```swift
let script = try await analysis.matlabScript()          // a String; the app decides where it goes
```

| What exports | The script plots |
|---|---|
| `SystemAnalysis` | Pole–zero map with the unit circle; magnitude and phase; group delay; impulse and step responses |
| `WindowAnalysis` | The window; its spectrum with main-lobe and side-lobe markers |
| `InversionReport` | Original, reconstruction and error; the error's spectrum |
| `FeedSnapshot` of a `HeatmapFeed` | The matrix as an image, with axes from its `FeedAxis` and its frame times |
| `FeedSnapshot` of a `WaveformFeed` | The min / max envelope over time |
| A track of `ScalarFrame`s | Value and confidence over time |
| `CrossoverTable` with its measurements | Time per call against size, one curve per implementation, on logarithmic axes |

- **MAT-1** Anything that exports conforms to `MATLABExportable`. The protocol is public.
- **MAT-2** A script defines its data as variables and then plots them, with axis labels and units. It uses core MATLAB only (`plot`, `semilogx`, `loglog`, `stem`, `imagesc`, `subplot`, `xlabel`, `ylabel`, `title`, `grid`, `axis`, `colorbar`, `hold`), so it also runs in GNU Octave.
- **MAT-3** Numbers are written with 17 significant digits from `Double` and 9 from `Float`, so they read back exactly. A value that is undefined (§6.3.8) is written as `NaN`, which a plot skips; that is the only place NaN appears.
- **MAT-4** A script carries no date and no machine name: equal input gives equal text. A matrix of more than four million elements is refused with `DSPError.exportTooLarge`, naming the size.
- **MAT-5** The package writes no file. It returns text.
- **MAT-6** Export runs in the background (BG-1).

---

## 7. Acceleration policy

### 7.1 What each framework is used for

| Framework | Used for |
|---|---|
| Plain Swift and C loops | Every primitive, below the size at which a library call starts to pay (§7.4); the double-precision biquad; state hygiene. |
| vDSP | Gains and ramps, single-precision biquad cascades, FIR and correlation, decimation, DFT and DCT, three windows, magnitude / power / decibels, dot products, sliding maximum, envelope reduction. |
| vForce | Logarithm, exponential and power for decibels, cepstra and masks. |
| vImage | Float32 → Float16 conversion for texture upload. |
| BLAS | Dense products: mel projection, DCT basis (`cblas_sgemv`). |
| LAPACK | Polynomial roots (`dgebal`, `dhseqr`), least-squares FIR (`dposv`, `dpocon`, `dgelsd`), Savitzky–Golay fit (`dgels`). |
| Metal | All rendering; median filtering of whole spectrograms offline; optional batched STFT through MPSGraph (iOS 17+). |
| Core Image | Image export of an off-screen render. Never on the live path. |
| Core Foundation / Core Graphics | Run-loop observer, timing, `CGImage` output, colour data. |

- **GPU-1** `.automatic` picks the GPU only when a measured crossover shows a lower *end-to-end* time, including buffer transfer and command-buffer latency. Operations on a single live frame are CPU by rule (IN-4).
- **GPU-2** The render path never reads GPU results back to the CPU.
- **GPU-3** Every GPU kernel has a CPU implementation that is its parity oracle and its fall-back.
- **GPU-4** GPU kernels live in `ZTronDSPMetal`. `ZTronDSPAnalysis` imports that target and wraps them as strategies (`MedianStrategy.metal`, `FFTBackend.mpsGraph`). With no device, `.automatic` uses the CPU and a forced `.metal` is `DSPError.backendUnavailable`.
- **LA-1** LAPACK is called through the legacy CLAPACK interface (E-10) from one file group, `ZTronDSPDesign/LinearAlgebra/`. Workspace queries are mandatory; a non-zero `info` becomes `DSPError.numericalFailure`.
- **PERF-1** No performance claim is accepted without a benchmark recorded by the harness (WP-006). Every crossover in this document is an initial value that a named package measures.

### 7.2 Algorithm register

Selections as of November 2026 (IN-5). Each row has a twin in the stability register (§7.5).

| # | Operation | Selected algorithm | Cost | Registered alternatives | Source |
|---|---|---|---|---|---|
| 1 | Real FFT | vDSP DFT, lengths 2ⁿ and f·2ⁿ | O(N log N) | MPSGraph FFT for batches | Apple vDSP (E-09) |
| 2 | Framing | Double-mapped ring; a window is a contiguous view | No copy per hop | Copy on wrap | — |
| 3 | IIR filtering | Cascaded biquads: `vDSP_biquad` in single precision, a transposed direct form II in double | O(sections) per sample | `vDSP_biquadm` for many channels | Apple vDSP; Oppenheim & Schafer |
| 4 | IIR design | Analog prototype → ZPK transformation → pre-warped bilinear → nearest-pairing SOS | Design time | Matched-Z | Parks & Burrus; Orfanidis 2006 (elliptic, Landen) |
| 5 | FIR design | Windowed sinc with Kaiser estimates; least squares by normal equations with an SVD fall-back | Design time | Equiripple (D-3) | Kaiser 1974; Parks & Burrus |
| 6 | Savitzky–Golay | Least-squares polynomial fit by QR on a scaled abscissa | Design time | Gram polynomials in closed form | Savitzky & Golay 1964 |
| 7 | FIR, short | `vDSP_conv`, `vDSP_desamp`; a plain loop below the crossover | O(K) per sample | — | Apple vDSP |
| 8 | FIR, long | Uniformly partitioned frequency-domain delay line | O(log B + K/B) per sample | Non-uniform partitioning | Wefers 2015; Gardner 1995 |
| 9 | Rate changes | Filter-and-keep decimation; polyphase interpolation | O(K/L) per output sample | Multistage half-band | Crochiere & Rabiner 1983 |
| 10 | One-shot convolution, correlation | FFT at a fast length; direct below the crossover | O(N log N) | — | — |
| 11 | Autocorrelation | Wiener–Khinchin on a zero-padded frame | O(N log N) | — | — |
| 12 | Polynomial roots | Scaled companion matrix, Hessenberg QR, Newton polish; closed form up to degree 2 | O(n³) | Unitary-plus-rank-one QR, O(n²) | LAPACK; Aurentz, Mach, Vandebril & Watkins 2015 |
| 13 | Constant-Q | Octave-recursive multirate with one sparse spectral kernel | One small FFT per octave per hop | Invertible sliced CQ (NSGT) | Schörkhuber & Klapuri 2010; Brown & Puckette 1992; Holighaus et al. 2013 |
| 14 | Onset envelope | Log-mel spectral flux with frequency max-filter | O(bands) per frame | — | Böck & Widmer 2013 |
| 15 | Tempogram | Windowed autocorrelation by FFT; Fourier tempogram | O(W log W) per frame | Cyclic tempogram | Grosche, Müller & Kurth 2010; Grosche & Müller 2011 |
| 16 | Median filtering | Odd-even-merge selection network, pruned to the median output, applied to whole vectors; per texel on the GPU offline | O(k log² k) branch-free vector operations per frame | Incremental sorted lanes; sort-based sliding median | Fitzgerald 2010; Driedger et al. 2014; Batcher 1968; Suomela 2014 |
| 17 | Spectral centroid | Dot product with a pre-computed ramp | O(N) | — | — |
| 18 | Mel conversion | Banded triangular filter bank; a dense product above the crossover | O(bins) per frame | — | Stevens, Volkmann & Newman 1937; Slaney 1998 |
| 19 | Cepstrum | DFT → log → inverse DFT; DCT-II for the coefficients | O(N log N) | — | Oppenheim & Schafer |
| 20 | Band-boost | Cookbook peaking; high-order Butterworth band-shelving, designed in ZPK | Design time | Matched second-order design | Bristow-Johnson; Orfanidis 2005; Vicanek 2016 |
| 21 | Window analysis | Grid refinement for jumps and smoothness; a zero-padded transform for the spectral figures | O(N log N) | Symbolic analysis, which a closure does not allow | Harris 1978 |
| 22 | Inversion analysis | Frame bounds from Σ w²; band-limit from the signal's spectrum; a measured round trip | O(N log N) | — | Shannon 1949; Griffin & Lim 1984 |
| 23 | Heat-map rendering | Ring texture, one column uploaded per frame, max-reduced levels, colour mapping in the fragment shader | O(new columns) | — | — |
| 24 | Implementation selection | A measured crossover per primitive, bound when the plan is compiled | Nothing at run time | Timing each call at run time | — |

### 7.3 Currency gate

A package tagged `ALG` in §12 starts with a check of at most five minutes: confirm the registered source of its row, look for a superseding method (DAFx, ISMIR, ICASSP, JAES, IEEE/ACM TASLP, ACM TOMS, Apple's Accelerate and Metal release notes), and write the date and the outcome in the package record. A better method is raised as a change request against this register and is never adopted silently. Lens N checks that the record exists, is dated and names what was consulted. WP-905 repeats the check over the whole register before every release, six rows to a package.

### 7.4 Implementation selection by size

A library call is not always the fastest way to do a small thing. On the host, scaling 64 floats takes 3 ns in a Swift loop and 8 ns through `vDSP_vsmul`; at 1 024 they are level; and for a dot product the answer changes twice (E-26). The package therefore keeps more than one implementation of each primitive and chooses by size, from measurements.

| Primitive | Implementations | The size that decides | Initial crossover (host, E-26) |
|---|---|---|---|
| Scale, add, subtract, multiply, clip | Swift loop · vDSP | Length | 512 |
| Sum, dot product, mean square | Swift scalar loop · Swift 8-lane SIMD · vDSP | Length | 16, then 64 |
| Minimum and maximum of two lanes | C loop · vDSP | Length | 1 024 |
| Gain kernel | C loop · `vDSP_vsmul`, `vDSP_vrampmul` | Block size | 512 |
| Biquad cascade, single precision | C loop · `vDSP_biquad` | Block size | 4 |
| FIR | Direct · partitioned | Taps | 256 (REAL-4) |
| One-shot convolution and correlation | Direct · FFT | N·K against (N + K)·log₂(N + K) | Cost model |
| Mel projection | Banded dot products · `cblas_sgemv` | Bands × bins | To be measured |
| DCT for cepstral coefficients | vDSP DCT where the length is documented · a basis with `cblas_sgemv` | Band count | The length rule, then measured |
| Median | Selection network on CPU lanes · the same network on the GPU | Kernel × bins × frames, and whether the work is live | CPU whenever live (GPU-1) |
| Polynomial roots | Closed form · companion QR (LAPACK) | Degree | 2 |

- **SEL-1** Every primitive in the table has two or more implementations with one contract. An implementation is plain Swift or C (*native*), Accelerate, or Metal.
- **SEL-2** `Implementation` is `.automatic` (default), `.native`, `.accelerate` or `.metal`, a settable environment key. A forced choice applies to the primitives that have that implementation; the rest stay automatic.
- **SEL-3 Bound when the plan is compiled.** On the real-time path every size is known then: block size, frame size, tap count, band count. The plan holds the chosen function. The hot path contains no size test and no branch on the choice.
- **SEL-4 Bound per call elsewhere.** A toolkit function called outside a plan compares its length with the crossover: one integer comparison.
- **SEL-5 Crossovers are data.** `CrossoverTable` is an immutable value. `.shipped` holds the figures measured on the reference devices (WP-611b…d), one set per processor family. `Calibration.measure()` measures the running device, in the background, and returns a table that the app may keep and pass to `DSPEngine(crossovers:)`. The initial values above come from one host and are replaced by measurement.
- **SEL-6 The same answer.** Implementations of one primitive agree bit for bit where they perform the same operations in the same order (the element-wise ones), and within 10⁻⁶ relative otherwise (a reduction sums in a different order). Choosing by size never changes what a pipeline computes beyond that.

### 7.5 Numerical stability register

- **NUMS-1** Every row of the algorithm register has a row here: the hazard, what is known about its size, what the code does about it, and the package whose tests show it.
- **NUMS-2** Every `ALG` package delivers a stability note, `Docs/Numerics/<row>.md`: the hazard, the bound or the measured behaviour with the fixture that shows it, the mitigation, and a stress test drawn from the fixture library of WP-016 that fails when the mitigation is removed. Lens N verifies the note against the code.
- **NUMS-3** Precision is a recorded decision: Float32 on the signal path, Double for design. Where the choice is made at run time it is made by measurement (REAL-3). The same figures are available for a system the user designs (§6.3.8).

| # | Operation | Hazard | Bound or measured behaviour | Mitigation | Shown by |
|---|---|---|---|---|---|
| 1 | Real FFT | Round-off grows with log N; a small bin beside a large one | Backward stable; error floor about 8·10⁻⁸ of the frame maximum in Float32 (E-30) | Tolerances relative to the frame maximum; decibel floors | WP-502 |
| 2 | Framing | None in arithmetic; index overflow in long sessions | Exact copies | 64-bit frame counters | WP-503 |
| 3 | IIR filtering | Poles near z = 1 amplify round-off: low cutoffs, high orders | Float32: 2·10⁻⁶ at 1 kHz, 4·10⁻⁵ at 90 Hz and order 8, with block-size dependence up to −61 dB (E-30) | Precision chosen by measurement (REAL-3); second-order sections with the poles nearest the unit circle last; state hygiene (RT-6) | WP-208, WP-211, WP-433 |
| 4 | IIR design | Expanding poles and zeros into coefficients is ill-conditioned for clustered poles | In ZPK form: 10⁻⁹ against the oracle. Expanded order-16 denominator: roots wrong by 10⁻¹ | Never expanded (REAL-1); pre-warp in double precision; elliptic functions by Landen transformation, which converges quadratically without cancellation; Bessel roots refined to a residual of 10⁻¹² | WP-408, WP-410, WP-418a, WP-418b |
| 5 | FIR design | Normal equations square the condition number | `dposv` loses accuracy beyond a condition number of about 10⁸ | Condition estimate, then `dgelsd` (§6.3.3); Kaiser's I₀ from its convergent series | WP-423, WP-425 |
| 6 | Savitzky–Golay | Vandermonde systems are ill-conditioned for high orders and wide windows | The condition number grows roughly as window^order on a raw abscissa | QR on an abscissa scaled to [−1, 1]; an order at or above the window is rejected | WP-426 |
| 7 | FIR, short | A sum of K products | Error ≤ K·ε·Σ‖h‖·max‖x‖; benign | None needed | WP-212 |
| 8 | FIR, long | The transform floor in each partition | −139 dB against the direct kernel; nothing accumulates across blocks | Each block is recomputed from the input history | WP-215 |
| 9 | Rate changes | Aliasing and imaging are filter leakage, not round-off | At least 80 dB of rejection by default; the polyphase gain is exact | The inversion report measures what a given signal loses | WP-213, WP-223, WP-539 |
| 10 | One-shot convolution | The FFT method loses small outputs beside large ones | The transform floor relative to the largest output | The direct method below the crossover | WP-513 |
| 11 | Autocorrelation | Round-off can leave lag 0 below a neighbour, or tiny values with the wrong sign; wrap-around without padding | At the transform floor | Zero-padding by rule (§6.7); normalisation guarded at the floor | WP-515 |
| 12 | Polynomial roots | The conditioning of each root; multiple roots | Error about κ(r)·ε; ε^(1/m) at multiplicity m (§6.3.8) | Avoided by design (ZPK); scaling-only balance; Newton polish; `rootConditions` reported; a degree cap | WP-402 |
| 13 | Constant-Q | Kernel sparsification; aliasing accumulated over octaves; long atoms at low frequencies | At most 0.1 % of kernel energy dropped; at least 80 dB of alias rejection per octave | The threshold is set by the energy criterion; acceptance is by property (§6.8) | WP-518, WP-519, WP-522a |
| 14 | Onset envelope | Differences of logarithms amplify the noise floor | Unbounded without a floor | The explicit floor (§6.9) | WP-525 |
| 15 | Tempogram | 0/0 on silence; a mean term that swamps the tempo rows | — | Mean removed; lag-0 guard; rows limited to the tempo range | WP-526, WP-527 |
| 16 | Median filtering | None in arithmetic: comparisons only. Ties and non-finite values | Exact | NUM-1 keeps non-finite values out; ties resolve the same way on CPU and GPU | WP-529, WP-610 |
| 17 | Spectral centroid | A ratio with a small denominator | Exact to ε·N for non-negative weights | A floor, and confidence 0 below it (§6.5) | WP-507 |
| 18 | Mel conversion | A narrow low band on a short frame covers no bin | Exact to ε·bins: all weights are non-negative | The empty-band check (O-18) | WP-508, WP-535 |
| 19 | Cepstrum | The logarithm of a near-zero magnitude; ambiguous phase unwrapping | Unbounded without a floor | A log floor; the inversion report flags bins at the floor and large phase steps | WP-509, WP-510 |
| 20 | Band-boost | Fourth-order sections formed from closed-form coefficients lose accuracy for narrow, low bands | That way: 0.06 dB at the centre and 2·10⁻² in the boost–cut identity. In ZPK: 10⁻⁹ to 10⁻⁸ | Designed and paired in ZPK (§6.3.5) | WP-421 |
| 21 | Window analysis | Finite differences amplify round-off as ε / hᵏ | Reliable to order 4 at steps of 2⁻¹² of the frame or more | Double precision; a bounded step; verdicts stated per grid (WIN-6) | WP-501e |
| 22 | Inversion analysis | Division by a small Σ w²; the measurement is limited by Float32 | Error amplified by B/A; measurable SNR up to about 140 dB | B/A reported; conditions carry margins (§6.13) | WP-538 |
| 23 | Heat-map rendering | Half-float quantisation | 5·10⁻⁴ relative: under 0.005 dB | Values uploaded in decibels and clamped to the range | WP-604, WP-605 |
| 24 | Implementation selection | Two implementations that differ by round-off | Bit-exact for element-wise primitives; within 10⁻⁶ for reductions | SEL-6, tested per primitive | WP-113, WP-114 |

---

## 8. Visual components

### 8.1 Components

```swift
@State private var mic = HardwareInputSource()                 // or FileSource(url:), GeneratorSource(…), any SampleSource
@State private var span = 10.0
@State private var cutoff = 90.0

VStack {
    SpectrogramView(source: mic)                               // the raw signal …
        .processing { HighPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }   // … or the processed one
        .analysisFrame(2_048, hop: 512, window: .hann)
        .colorMap(.magma)
        .valueRange(-90 ... 0)
        .frequencyScale(.logarithmic)
        .timeSpan($span)
        .pinchScaling(.horizontal)
        .axis(.frequency)
    WaveformView(source: mic)
    ChromagramView(feed: model.chroma)                         // a feed the app's own pipeline writes
    TempogramView(feed: model.tempogram)
}
```

| View | `init(source:)` runs | `init(feed:)` takes | Shows | Renderer |
|---|---|---|---|---|
| `SpectrogramView` | `STFT → Power → Decibels` | A spectrum in decibels on any axis | Frequency × time, colour-mapped | Heat map |
| `ChromagramView` | `ChromaCQT` | A `Chroma` feed | 12 pitch classes × time | Heat map, nearest filtering on the pitch axis |
| `TempogramView` | Mel spectrogram → `OnsetStrength` → `Tempogram` | A `TempoSpectrum` feed | Tempo × time | Heat map |
| `WaveformView` | `Waveform` | A `WaveformFeed` | Min / max envelope: live scrolling, or a static overview of a buffer | Envelope |
| `HeatmapView` | — | Any `HeatmapFeed` | The generic base the first three specialise | Heat map |

- **VC-1** Each component is a plain SwiftUI `View` that fills the size it is offered. It adds no navigation, container or toolbar, reads no app state, and installs no gesture unless one is enabled (PINCH-1).
- **VC-2** Axes, grids and labels are separate views drawn with `Canvas`: `FrequencyAxisView`, `TimeAxisView`, `PitchClassAxisView`, `TempoAxisView`. They are absent unless the host adds them, with `.axis(_:)` on a component or by placing the standalone view, which takes the feed it labels.
- **VC-3 Two ways in.** `init(source:)` takes any `SampleSource`. While the view is in the hierarchy it keeps one attachment of its recipe on that source, on the engine found in the environment (`DSPEngine.shared` unless `.dspEngine(_:)` says otherwise), and detaches when it leaves; the source may serve other attachments at the same time (ATT-6). `init(feed:)` takes a feed that the app's own pipeline writes; one feed can drive several views. A source is something the app keeps, in state or in a model, not something created in `body`.
- **VC-4 Modifiers, not style objects** (API-6). Appearance: `.colorMap`, `.valueRange`, `.frequencyScale`, `.frequencyRange`, `.timeSpan`, `.amplitudeRange`, `.maximumFrameRate`. Analysis of a source-fed view: `.analysisFrame(_:hop:window:)`, `.melBands(_:)`, `.processing(_:)`, which puts a `Pipeline<Samples, Samples>` in front of the recipe. Each sets one value in the SwiftUI environment. `.valueRange`, `.frequencyRange`, `.timeSpan` and `.amplitudeRange` take a value or a `Binding`.
- **VC-5** A feed carries a `FeedAxis` saying what its rows are: linear frequency up to Nyquist, mel band centres, constant-Q bins, pitch classes, lags, quefrency or tempo. Views label from it. `.frequencyScale` warps linear-frequency rows for display only; rows that are already mel or constant-Q are drawn bin for bin (IN-11).

### 8.2 Rendering design

**Heat map.** One `r16Float` data texture, bins × history columns, sized by the *data*, not by the view. Each new frame replaces one column; a head-column uniform turns the texture into a ring, so scrolling moves no texels. Values are uploaded as they arrive (decibels for a spectrogram; plain values for chroma, lags, cepstra and tempograms), converted to half-float with vImage. With each column the renderer stores max-reduced levels along frequency: level k holds the maximum of 2ᵏ neighbouring bins. The fragment shader normalises against the value range, samples a 256-entry colour look-up texture, and warps the frequency axis (linear, logarithmic or mel) in texture coordinates. Where one pixel covers several bins, as at the top of a logarithmic axis, the shader reads the level that matches the pixel's footprint, so a narrow peak cannot fall between samples (V-8). Changing the colour map, the range or the scale is therefore a uniform change and one draw, with nothing re-uploaded.

**Waveform.** One `rg16Float` texture holding (min, max) per column. Live: a ring, one column per reduction bucket (`vDSP_minv` / `vDSP_maxv` on the analysis thread). Static overview: a min / max pyramid built once, a factor of two per level; the view samples the level that matches its zoom. The fragment shader fills between min and max with analytic anti-aliasing. One draw call, no vertex buffers.

**Image export.** `FeedSnapshot.image(size:colorMap:valueRange:frequencyScale:)` renders a snapshot of a feed into an off-screen texture and converts it with Core Image, in the background (BG-1). A presented drawable is never read back: it cannot be sampled (E-12).

### 8.3 Draw scheduling

- The `MTKView` runs in explicit-draw mode: `isPaused = true`, `enableSetNeedsDisplay = false`. Nothing is drawn unless the renderer calls `draw()` (E-12).
- The renderer keeps a dirty set with exactly these causes: **new data**, **appearance changed** (which includes each frame of an animation or a pinch), **drawable size changed** (which includes each frame of a size transition, §8.9), **became visible**, **feed replaced**.
- A `FrameScheduler` (a `CADisplayLink` wrapper) is active only while the feed is live or the dirty set is non-empty. A feed is live while its session is running and its branch is not suspended (ACT-11); both are known on the control side, which tells the scheduler, so the analysis thread never wakes the main thread. Otherwise the display link is paused and the view causes no wake-ups at all.
- On a tick: if the feed's generation counter (one atomic load) has not moved and the dirty set is empty, return without acquiring a drawable. Otherwise upload every column that arrived since the last tick in one pass, call `draw()` once, clear the dirty set.
- Frame rate is capped by `.maximumFrameRate` (default 60).
- When the scene phase is not `.active` the scheduler is paused and no GPU work is submitted.

### 8.4 Stability contract

- **V-1** A component's `body` never depends on per-frame data. The view struct stores a feed or source reference and equatable values, and is itself `Equatable`.
- **V-2** `ZTronDSPUI` contains no observable object, no `@State` write and no `AsyncSequence` loop that fires at data rate. (Combine is not available to it at all, §9.5.)
- **V-3** `updateUIView` compares the incoming appearance and feed identity with the current ones and returns immediately when they are equal.
- **V-4** No draw without a cause from the dirty set.
- **V-5** A draw costs an upload proportional to the columns that are new, and at most two draw calls. The whole texture is uploaded only when it is (re)allocated.
- **V-6** The data texture is reallocated only when the bin count or the history length changes. Resizing the view redraws; it uploads nothing.
- **V-7** The environment bridge publishes only on a format or topology change (ENV-4).
- **V-8** A pixel that covers several bins shows their maximum. A one-bin peak is visible at every scale.

| Scenario (WP-809a, WP-809b) | Required outcome |
|---|---|
| Parent re-evaluates its body 100 times with equal inputs | 0 renderer updates, 0 draws, 0 new attachments |
| Session running, no new data for one second | 0 draws; each tick returns after one atomic load |
| Session stopped, or the branch suspended | Display link paused; 0 wake-ups |
| Data arriving at twice the display rate for one second | Draws ≤ display ticks; every column present in the texture |
| Colour map changed | Exactly 1 draw, 0 column uploads |
| Value range animated over half a second | 1 draw per display frame, 0 uploads |
| View resized without animation | 1 draw per changed size, 0 uploads |
| Feed replaced | Texture cleared once, then normal operation |
| Scene inactive, then active | 0 draws while inactive; 1 draw on return |

Counters come from a `RenderProbe` injected into the coordinator and the renderer (make, update, upload, draw, attach). Level 1 of the suite drives the coordinator and renderer directly with off-screen textures and runs in the package tests. Level 2 repeats the scenarios through real SwiftUI hosting in the Examples project (§4.2) and is part of the release gate.

### 8.5 Rendering correctness

Golden-image tests render off-screen, read the texture back and compare with a committed reference at PSNR ≥ 40 dB (WP-603 supplies the comparison). Fixtures for the heat map: each frequency scale, each colour map, ring wrap-around, range clamping at both ends, a one-bin peak under each scale. For the waveform: sine, impulse, silence, clipped input. A golden image is regenerated only with a written justification in the package record (lens V).

### 8.6 UIKit boundary

- **UB-1** No file under `Sources/` contains `import UIKit` or `import AppKit`.
- **UB-2** No UIKit-declared symbol is named under `Sources/`, with one exception: `Sources/ZTronDSPUI/Bridge/MetalViewRepresentable.swift` names `MTKView` and the associated types that SwiftUI's `UIViewRepresentable` requires. That file imports SwiftUI and MetalKit only.
- **UB-3** In that file only members declared by MetalKit are used on the view: `init(frame:device:)`, `device`, `delegate`, `isPaused`, `enableSetNeedsDisplay`, `preferredFramesPerSecond`, `colorPixelFormat`, `framebufferOnly`, `clearColor`, `drawableSize`, `autoResizeDrawable`, `currentDrawable`, `currentRenderPassDescriptor`, `draw()`. Members inherited from `UIView` are not used; background, opacity and layout are SwiftUI modifiers. The view's `CAMetalLayer` is reached through `CAMetalDrawable.layer`, which is QuartzCore (SZ-5).
- **UB-4** Substitutes:

  | Instead of | Use |
  |---|---|
  | `UIScreen.main.scale` | SwiftUI `\.displayScale` |
  | `UIApplication` life-cycle notifications | SwiftUI `\.scenePhase`; AVFAudio interruption notifications |
  | `UIApplication.didReceiveMemoryWarningNotification` | `DispatchSource.makeMemoryPressureSource` |
  | `UIColor`, `UIImage` | `Color` / `CGColor`, `CGImage` |
  | `UIPinchGestureRecognizer` | The SwiftUI gestures of §8.8 |
  | Device-orientation notifications | The size SwiftUI offers (SZ-6) |

- **UB-5** `Scripts/lint-bans.sh` enforces this mechanically. UB-1: the two imports. UB-2: any identifier of the form `UI` followed by a capital letter, and the UIKit-declared `NS…` names on a committed list, outside the bridge file. UB-3: the bridge file refers to the view only by the name `metalView`, and every `metalView.<member>` must be on the list above.
- **UB-6** Test targets may import UIKit for one purpose only: hosting a SwiftUI view under test.

### 8.7 Animation

- **ANI-1 Appearance animates.** `.valueRange`, `.timeSpan`, `.frequencyRange` and `.amplitudeRange` are animatable: the components conform to `Animatable` over those values. Inside `withAnimation`, or under `.animation(_:value:)`, SwiftUI hands the component one interpolated set per display frame, and each produces one draw with new uniforms and no upload. Colour map and frequency scale are discrete and change at once.
- **ANI-2 A pipeline has animatable values.** `pipeline.parameters` is a `ParameterVector`: every continuous value of every stage, in order. Frequencies are carried as log₂ of hertz, so an animated cutoff glides evenly in pitch; gains are carried in decibels. Orders, sizes, windows and strategies are not in the vector: they are structure.
- **ANI-3 A host animates it.** A pipeline is hosted by a view in one of two ways: `.processing(_:)` on a source-fed component, or `.pipeline(_:on:)` on any view, which attaches the pipeline to a source while the view is in the hierarchy, updates the session when the pipeline value changes, and detaches when the view leaves. Both hosts are `Animatable` over the pipeline's vector. When a state change inside `withAnimation` gives the host a pipeline with the same topology and different values, the host sends the session one same-topology update per display frame with the interpolated vector (§5.5.4).

  ```swift
  SpectrogramView(source: mic).processing { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
  Button("Open up") { withAnimation(.easeInOut(duration: 2)) { cutoff = 8_000 } }     // the cutoff glides for two seconds
  ```
- **ANI-4** A change of topology is not interpolated: it is applied at once, through SWAP-1…4.
- **ANI-5** `session.update(_:)` called directly is not animated; animation is something a host adds. During an animation the newest frame wins: if a design is not finished when the next frame arrives, it is dropped (SWAP-4).

*(Assumption: an `Animatable` whose `animatableData` is a vector of run-time length is interpolated by SwiftUI as fixed-size data is. WP-817 confirms it; the fall-back is a host that interpolates the vector itself on the display link.)*

### 8.8 Pinch scaling

| View | Horizontal pinch scales | Vertical pinch scales |
|---|---|---|
| `SpectrogramView`, and `HeatmapView` on a frequency axis | The time span | The frequency range |
| `TempogramView` | The time span | The tempo range |
| `ChromagramView` | The time span | Nothing: its twelve rows are fixed |
| `WaveformView` | The time span | The amplitude range |

- **PINCH-1 Off by default.** `.pinchScaling(_ axes: Axis.Set)` enables the axes named. A view with none enabled installs no gesture.
- **PINCH-2 It changes what is shown, never what is computed.** A pinch moves the time span or a range. The pipeline, its frame size and its hop are untouched.
- **PINCH-3 Which axis.** The line through the two fingers when the pinch begins decides: within 30° of horizontal, the horizontal axis; within 30° of vertical, the vertical axis; otherwise both. A pinch along an axis that is not enabled does nothing.
- **PINCH-4 How much.** The scale is the ratio of the current distance between the fingers to the initial one. The value under the pinch's centroid stays under it, except on a live time axis, which stays anchored at the present.
- **PINCH-5 Where the value lives.** With a bound modifier, `.timeSpan($span)`, the pinch writes the binding. With a constant, the view keeps the scaled value itself until the constant changes.
- **PINCH-6 Limits.** Time span: from half a second to the feed's history. Frequency or tempo range: no narrower than an eighth of an octave on a logarithmic or mel scale, or 16 rows on a linear one, and no wider than the feed's axis. Amplitude: from 1/1 000 of full scale to full scale. Past a limit the scale resists, and it springs back on release.
- **PINCH-7 Cost.** A pinch is an appearance change: one draw per display frame while it lasts, nothing uploaded.
- **PINCH-8 Where the finger line comes from.** One tracker, one seam, a path per OS:

  | OS | Gestures | The finger line |
  |---|---|---|
  | iOS 18 and later | `SpatialEventGesture` | Both touch locations |
  | iOS 17 | `MagnifyGesture` with a simultaneous `DragGesture` | From the pinch's start location (the centroid) to the first finger's start location |
  | iOS 15 and 16 | `MagnificationGesture` with a simultaneous `DragGesture` | The direction the first finger travels in its first 8 points; nothing scales until then. With one axis enabled, that axis is used at once. |

  *(The rows for iOS 15–17 are assumptions about what those gestures report together. WP-818 confirms or corrects them before the tracker is built.)*

ZTronScrollView was read for this purpose (E-29). Its zoom is one scale for both axes, applied to rendered content as a transform, which magnifies pixels instead of changing a time span or a frequency range; and the per-touch observer that would supply the finger line on iOS 15 and 16 is internal to it. It is therefore not a dependency. Were that observer public, the tracker's seam would take it as a further row of the table (OD-12).

### 8.9 Size transitions

A Metal view whose size is animated, by a `.frame` change inside `withAnimation` or by a rotation of the interface, must not show stretched or late content at any moment of the transition.

- **SZ-1** Rendering does not depend on resolution. The data texture is sampled in normalised coordinates, so any drawable size shows the same content, and a size change uploads nothing (V-6).
- **SZ-2** During a transition the drawable follows the layer's **presentation** size: on every display frame the drawable size is set to the presentation bounds times the display scale, and one draw is made. Automatic drawable resizing is off for the duration, because it would jump to the final size at once and let Core Animation stretch that image through the transition.
- **SZ-3** Draws made during a transition are presented with the layer's transaction, so the content and the bounds change in the same frame. Outside a transition, presentation is asynchronous again.
- **SZ-4 Detecting a transition.** Two signals, either of which starts it: an `Animatable` probe in the SwiftUI wrapper that receives interpolated sizes, and the layer itself (its presentation bounds differ from its model bounds, or it has animation keys). The transition ends when the presentation size equals the model size and neither signal is active; one more draw at the exact size follows. *(Assumption about how SwiftUI moves a hosted view; WP-822 confirms or corrects it before WP-823 builds on it.)*
- **SZ-5** The `CAMetalLayer` is obtained from the first drawable (`CAMetalDrawable.layer`), not from the view, so no `UIView` member is used (UB-3).
- **SZ-6** A rotation is a size transition like any other. Nothing in the package observes the device's orientation.

Acceptance (WP-824), hosted, for a half-second animated change from 200 × 120 to 320 × 300 points and for a rotation: at every display tick of the transition the drawable's size equals the presentation size within one pixel; a frame captured at the midpoint matches the same content rendered directly at that size with PSNR ≥ 35 dB; the number of draws is at least the number of ticks minus one; nothing is uploaded.

---

## 9. Platform rules

### 9.1 Deployment floor

- **PLAT-1** `platforms: [.iOS(.v15)]`. Every API newer than 15.0 sits behind `#available` with a fall-back that keeps the feature working.

  | API | Available from | At the floor |
  |---|---|---|
  | `AVAudioApplication.requestRecordPermission` | 17.0 | `AVAudioSession.requestRecordPermission` |
  | `initWithRealtimeSafeReceiverBlock:` (Objective-C) | 27.0 | `initWithReceiverBlock:` around the same C function |
  | Error-returning `installTap` | 27.0 | Legacy `installTap` |
  | High-quality Bluetooth recording | 26.0 | Hands-free quality (MIC-5) |
  | `SpatialEventGesture` | 18.0 | The paths of PINCH-8 |
  | `MagnifyGesture` | 17.0 | `MagnificationGesture` |
  | MPSGraph FFT | 17.0 | vDSP backend |
  | New LAPACK interface | 16.4 | Legacy CLAPACK everywhere (LA-1) |
  | Double-precision `vDSP_biquadm` setters | 16.0 | The package's own double-precision kernel (REAL-3) |
  | `Duration`, `ContinuousClock` | 16.0 | `TimeInterval`, `mach_absolute_time` |
  | `OSAllocatedUnfairLock` (16.0), `Synchronization` atomics and `Mutex` (18.0), Observation (17.0) | — | C11 atomics in `CZTronDSP`; a private `os_unfair_lock` wrapper on the control context; plain state and bindings in views |

- **PLAT-2** The floor is enforced at compile time: with a 15.0 deployment target, unguarded use of newer API does not build.
- **PLAT-3** Run-time matrix: simulators on iOS 17.5 (the oldest that runs on the current host, E-17), 18.x, 26.x and 27.0, plus a physical device on iOS 15.x after M3 (WP-338) and for the release gate (WP-904a, WP-904b).

### 9.2 Language, concurrency and background work

- `swift-tools-version: 6.2`, so that the manifest can turn function-effect warnings into errors for the C target without unsafe flags (E-32); Swift 6 language mode.
- Public types are `Sendable`. UI types are `@MainActor`. `DSPEngine` and `PipelineSession` are `final class … : Sendable`; their control state is guarded by a private lock that is only ever taken on the control context.
- The data plane uses no actor, no `Task` and no `await` (RT-2).
- `@unchecked Sendable` is allowed only on types whose threading contract is written at the declaration (ring end-points, feeds). Each is listed in `Docs/Process/unchecked-sendable.md` and reviewed under lens A.
- Public throwing API uses typed throws: `throws(DSPError)`.
- **BG-1** Every analysis and every export is an `async` function whose work runs on `BackgroundWork`, the package's executor at utility quality of service: never on the main thread, never on the I/O or analysis thread. This covers `analysis(sampleRate:)`, `Window.analysis`, `inversionReport`, `Calibration.measure()`, `matlabScript()` and `FeedSnapshot.image`. Plan compilation behind `attach` and `update` runs on the control context, which is also off the main thread.
- **BG-2** What comes back is an immutable `Sendable` value.
- **BG-3** The work can be cancelled: it checks between its steps, and a cancelled call throws `DSPError.cancelled`.
- The one-shot functions of the `DSP` namespace (`DSP.convolve`, `DSP.decibels`, …) are synchronous and run where they are called. They are computations, not reports; a caller with a large input calls them off the main thread.

### 9.3 Errors and diagnostics

- `DSPError` cases: `invalidParameter(stage:parameter:reason:)`, `invalidStageOrder(stage:found:)`, `unsupportedConfiguration(reason:)`, `unstableDesign(maxPoleRadius:)`, `numericalFailure(routine:info:)`, `permissionDenied`, `sessionConfigurationFailed(reason:)`, `sourceUnavailable(reason:)`, `backendUnavailable(reason:)`, `resourceAllocationFailed(what:)`, `sinkInUse(sink:)`, `sessionDetached`, `exportTooLarge(elements:limit:)`, `cancelled`. An error raised by a stage carries the stage's path.
- No `fatalError` or `precondition` is reachable from public API through invalid input. `assert` guards internal invariants.
- Logging uses `os.Logger`, subsystem `com.zombietron.ztrondsp`, never on a hot path. Signpost intervals mark plan compilation and plan exchanges. Per-block signposts exist only behind the build setting `ZTRONDSP_SIGNPOSTS`, which is off in every configuration the real-time audit runs in.

### 9.4 Privacy

ZTronDSP writes nothing to disk and transmits nothing. Samples leave the package only through sinks the app declares; exports and images are returned to the app as values.

### 9.5 API that needs approval

- **APR-1** `AnyView` and Combine are not used. That means no `AnyView`, no `import Combine`, and none of the names that rest on Combine: `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `Publisher`, `AnyCancellable`, the subjects, `.sink`, `.onReceive`. Lint enforces it in production targets, tests and the Examples project.
- **APR-2** An exception needs a change request approved by the owner before the code exists. Its number is entered in `Docs/Process/approvals.md`, and the lint's allow-list accepts an entry only with such a number. The register starts empty. This specification asks for no entry.

What takes their place: `some View`, `@ViewBuilder` and generics instead of `AnyView`; `AsyncSequence`, bindings and the SwiftUI environment instead of Combine. The Combine bridge that Draft 2 gave `FeatureStream` is removed (D-12).

### 9.6 Memory pressure

- **MEM-1** The engine owns one memory-pressure source (`DispatchSource.makeMemoryPressureSource`). On a warning it destroys the plans waiting on the retire list, and nothing else. On a critical event it also asks every feed that was created with a `minimumHistory` smaller than its `history` to drop its oldest columns down to that minimum; the feed's generation moves, and its views reallocate their texture once (V-6). A feed that declared no smaller minimum is never trimmed, and a running plan is never altered. Each affected session reports `.memoryPressure`.

---

## 10. Quality gates

### 10.1 Test strategy

| Layer | Content |
|---|---|
| Unit | Every public function and every kernel. Swift Testing, as in the sibling package. |
| Compile fixtures | Must-compile and must-not-compile files for the order rules of §5.8, each invalid one asserting its diagnostic; the generated stage × domain matrix of ORD-2. |
| Parity | Golden vectors from the pinned SciPy / librosa generators, every argument explicit (STG-2); a manifest of SHA-256 hashes detects drift. |
| Property | Block-size invariance to the round-off floor; fused ≡ unfused; offline ≡ engine; identical samples through `BufferSource`, `ScriptedSource` (irregular batches) and `FileSource` give bit-identical output (the source-transparency test for R-01); implementations of one primitive agree (SEL-6). |
| Real-time audit | `expectNoAllocations`: 1 000 blocks for every kernel and node, 10 000 for every stock pipeline (RT-7). |
| Stability | For every `ALG` package, the stress test of its stability note (NUMS-2). |
| Concurrency | Ring, command-queue and plan-exchange stress; a Thread Sanitizer job in CI. |
| Rendering | Golden images (§8.5), stability counters (§8.4), size transitions (§8.9). |
| Extension | The external parity suite (EXT-4). |
| Export | Golden scripts; each runs under GNU Octave in the generator environment (§6.14). |
| Integration | Capture while playing, interruptions, hot-plug, node tap; simulator and device lab. |
| Benchmark | Committed baselines; a regression above 10 % fails. |

### 10.2 Coverage

- **COV-1** Line coverage from Xcode (`xcodebuild test -enableCodeCoverage YES`, read with `xccov`) over all production targets, Swift and C.
- **COV-2** Aggregate ≥ 97.5 %. Each target ≥ 95 %.
- **COV-3** Per package: the files a package adds or changes are at ≥ 97.5 %, or the package is not done. Exception: a branch that can run only on an OS version the simulator matrix cannot host (E-17) is listed in the ledger instead and is measured in the device run, which is merged before COV-2 is evaluated.
- **COV-4** Exclusions. (a) `.metal` sources cannot be instrumented; each shader function is covered by a parity or golden test instead, listed in `Docs/Process/shader-coverage.md`. (b) Lines marked `// coverage:ignore(<reason>)` for unreachable defensive branches; the total stays below 0.5 % of production lines and each is reviewed under lens T.
- **COV-5** Hardware-facing code follows the humble-object rule: decisions live in types driven through seams (`AudioSessionControlling`, `MicrophoneAuthorizing`, an injected notification centre and clock); the adapter that touches `AVAudioEngine` contains no branching logic.
- **COV-6** Tests, the Examples project, benchmarks and `ZTronDSPTesting` are outside the denominator.

### 10.3 Continuous-integration gates

1. Build for simulator and device with warnings as errors in production targets.
2. `Scripts/lint-bans.sh` (all four parts: WP-002, WP-010, WP-011, WP-012).
3. `Scripts/compile-fixtures.sh` and the order matrix.
4. The API digest check.
5. Tests on the simulator matrix; Thread Sanitizer job.
6. `Scripts/coverage-gate.sh`.
7. Golden manifest check.
8. Benchmark regression check on a pinned runner.
9. The external parity suite.

### 10.4 Performance budgets

Reference devices: **Tier-low**, the oldest device available to the team that runs iOS 15; **Tier-mid**, A14-class; **Tier-high**, current. The owner names them (OD-8). The figures are provisional until WP-903a and WP-903b measure them.

| Budget | Target |
|---|---|
| Stock full-analysis pipeline (spectrogram 2 048 / 512, centroid, chroma-CQT over 6 octaves, HPSS 17 / 17, autocorrelation tempogram), mono 48 kHz: processing time ÷ audio time | ≤ 0.10 Tier-mid; ≤ 0.25 Tier-low |
| Signal chain of §5.7 | ≤ 0.5 % of the block duration, Tier-low |
| Main-thread CPU per presented frame, one spectrogram view | ≤ 1.5 ms, Tier-mid |
| Draw calls per presented frame, per view | ≤ 2 |
| Draws while idle | 0 |
| Microphone-to-feature latency (centroid) | ≤ I/O buffer + poll interval + hop + 2 ms |
| Switch to stage: a `Toggle` to the first affected block | ≤ one main-run-loop turn + one block |

---

## 11. Delivery process

### 11.1 Roles

| Role | Does |
|---|---|
| **Owner** | The person who commissioned the package. Approves change requests, splits, and entries in the approvals register. Names the reference devices. Is never the implementer of the package a decision concerns. |
| **Integrator** | Writes each package's brief from its row in §12 (WP-R3). Checks items 1–4 and 6 of the definition of done. Merges, runs the gates, keeps the ledger. |
| **Implementer** | Builds one package inside its time box. |
| **Verifier A, Verifier B** | Each verifies the package through one of its two lenses. |

Implementer, verifiers and integrator may be people or agents; the owner is a person. No actor holds two roles on the same package.

### 11.2 Work-package rules

- **WP-R1 Time box.** 30 minutes of implementation. An implementer who cannot see the path to done at minute 20 stops and asks for a split (§11.7) instead of pushing through.
- **WP-R2 Size guide.** One target; about 150 lines of production code; one new public type or three public functions; tests included in the same package.
- **WP-R3 Self-contained brief.** A row of §12 gives the ID, the goal, the dependencies, the acceptance and the lenses. Before the package becomes ready, the integrator adds the spec sections to read, the files to create, and what is out of scope. An implementer must not need anything else.
- **WP-R4** A package starts only when its dependencies are done. A dependency on a retired ID means all of its parts.
- **WP-R5** `ALG` packages begin with the currency check (§7.3) and end with a stability note (NUMS-2). `OPT` packages are executed only when their trigger, listed in §12, occurs. What only an `OPT` package delivers is marked optional in §5.3, and its absence fails nothing.

### 11.3 Life cycle

`Ready → Implementing → Verifying → (Fixing → Verifying)* → Done`, with three side states: `Paused` (a change request is open, FIX-4), `Escalated` (three cycles without convergence, FIX-3) and `Retired` (replaced by its parts, §11.7).

### 11.4 Two independent verifiers

- **VER-1** Each package is verified through exactly the two lenses listed for it in §12, by two different verifiers.
- **VER-2 Independence.** Neither verifier sees the other's findings or the implementer's reasoning until both reports are filed. Each receives the brief, the spec sections it cites, the revision under review as a checkout it can run and modify, and the test, lint and coverage output.
- **VER-3** Each verifier runs the acceptance checks personally. A statement in the implementer's notes is not evidence.
- **VER-4** A report states a verdict (`pass` or `blocking`) and, per finding: the checklist item, the location, the evidence, the severity.

### 11.5 Lenses

| Lens | Name | The verifier checks |
|---|---|---|
| **N** | Numerical correctness | The result matches the cited definition and the golden vectors within the stated tolerance. Edge cases: empty, length 1, DC, Nyquist, silence, full scale, non-finite input (NUM-1). Precision choice. For `ALG`: the currency record and the stability note, checked against the code. No tolerance was loosened to make a test pass. |
| **R** | Real-time safety and performance | RT-1…RT-9. The allocation audit exists and passes. No hidden copies. Complexity as registered in §7.2. A benchmark is recorded. Setups are created when the plan is compiled only. Implementations bound by size (SEL-3). |
| **A** | API, architecture, platform | Names and shapes per §4–§8. Strategy and Decorator conformance. DEP, EXT and VIS rules. Immutability and no configuration objects (IMM, API-6). Sendable, concurrency and background rules (§9.2). Availability (PLAT-1). UIKit boundary (§8.6). Approval-gated API (§9.5). Typed errors. Public API documented with its threading contract. |
| **T** | Tests and coverage | Every acceptance check exists as a test and fails when the implementation is broken; the verifier changes one line to confirm. COV-3. Tests are seeded and deterministic and do not synchronise with sleeps. Negative paths are covered. |
| **V** | Visual stability and rendering | V-rules. Dirty-set causes. Draw and upload counters asserted. No per-frame SwiftUI invalidation. Animation, pinch and size-transition rules (§8.7–8.9). Golden images changed only with justification. |
| **S** | System integration | CAP and MIC rules. Session ownership. The tables of §4.5 and §4.6. Permission paths. Idempotent start, stop and detach. Behaviour when hardware is absent or changes. |

### 11.6 Severity and fix cycles

**Blocking**: a numbered rule or an acceptance statement of §4–§10 is violated; an acceptance check of §12 is missing, failing, or does not exercise the code; a result is wrong; coverage is below COV-3; public API differs from §4–§8 or Appendix A without a change request. **Non-blocking**: everything else. It goes to the ledger backlog with an owner and does not hold the package.

- **FIX-1** The implementer fixes every blocking finding. Both verifiers then verify the new revision: the lens that raised a finding confirms the fix; the other lens confirms the fix broke nothing in its own domain.
- **FIX-2** A package is done only when both lenses report zero blocking findings **on the same revision**.
- **FIX-3** After three fix cycles without convergence the package stops and is escalated to the owner, who approves a split or a change request. There is no fourth cycle. Neither exit closes a finding: every open blocking finding is carried into a part or into the change request, and is verified there.
- **FIX-4** A verifier who finds this document wrong or ambiguous files a change request. The package is paused, not bent to fit.

### 11.7 Splitting

A package that will not fit the time box is replaced by suffixed packages (`WP-521a`, `WP-521b`, …), each with two lenses. The integrator writes the split and the owner approves it. The parts partition the original acceptance: every check of the original row appears in exactly one part, unchanged; a check is reworded or dropped only by a change request. The split is recorded in the ledger, the original ID is retired, and whatever depended on it depends on all of its parts.

### 11.8 Definition of done

1. The acceptance checks of §12 pass on the simulator matrix, or in the device lab for a package that §12 marks as a device run.
2. Every CI gate of §10.3 that the package can affect passes.
3. COV-3 holds.
4. Public symbols have documentation comments with their threading contract (VIS-2). A package that adds a stage has met STG-1.
5. Zero blocking findings from both lenses on the same revision.
6. The ledger entry is complete: time spent, revision, both reports, fix cycles, currency check and stability note (for `ALG`), backlog items.

### 11.9 Records and change control

- Ledger: `Docs/Process/ledger.md`, one row per package. Reports: `Docs/Process/reports/WP-nnn-{A,B}.md`.
- Any deviation from this document is a change request, `Docs/Process/changes/CR-nnn.md` (what, why, evidence, sections affected), approved by the owner before code that relies on it merges.

---

## 12. Work packages

Every row is one package under the rules of §11: at most 30 minutes to implement, verified through the two lenses in its row, fixed until both report zero blocking findings. "Dep" lists the packages that must be done first. Tags: **ALG** starts with the currency check (§7.3) and ends with a stability note (NUMS-2); **OPT** runs only on its trigger.

- **STG-1 What a stage package delivers.** A package that delivers a stage, a step or a recipe delivers with it: its fluent modifier; its trailing `isActive:` (API-5); for a context-dependent step, its family (ORD-1), with one must-compile and one must-not-compile fixture for every order rule that names it, each invalid one asserting its sentence (ORD-4); the regenerated order matrix (ORD-2); its latency and settling time; and its allocation audit (RT-7). The rows do not repeat this.
- **STG-2 What "Golden" means.** The package adds a generator under `Tests/Golden/generators/` and its vectors to the manifest. The generator passes every library argument explicitly. Oracle, grid and tolerance are those of the table below unless the row says otherwise. A tolerance changes only by change request, with the measured error attached.

| Packages | Oracle | Grid | Tolerance |
|---|---|---|---|
| WP-405…411 | SciPy `buttap`, `cheb1ap`, `cheb2ap`, `ellipap`, `besselap` | Orders 1…12 (Butterworth to 20, Bessel to 25); ripple 0.1, 1, 3 dB; attenuation 40, 60, 80 dB | Poles, zeros and gain within 10⁻⁹ relative |
| WP-412…414 | `lp2lp_zpk`, `lp2hp_zpk`, `lp2bp_zpk`, `lp2bs_zpk`, `bilinear_zpk` | Each prototype at orders 2, 5, 8; edges at 0.05, 0.2 and 0.45 of f_s; bands 0.1 and 1 octave wide | 10⁻⁹ relative |
| WP-415…417, WP-418c | `buttord`, `cheb1ord`, `cheb2ord`, `ellipord` | Three tolerance schemes per response | Order equal; natural frequency within 10⁻⁹ |
| WP-418a, WP-418b, WP-429, WP-430 | `iirfilter`, `freqs`, `sosfreqz`, `group_delay` | Family × response × orders 1, 2, 5, 8; 512 frequencies | Complex response within 10⁻⁹; group delay within 10⁻⁶ samples |
| WP-420 | The Cookbook formulas evaluated in double precision | Gains ±6 and ±12 dB; Q 0.5, 1, 4; centres 100 Hz, 1 kHz, 10 kHz | Coefficients within 10⁻¹² |
| WP-423, WP-425 | `firwin`, `kaiserord`, `firls` | Four responses; lengths 31, 101, 255; Hann and Kaiser windows | Taps within 10⁻⁹ |
| WP-426, WP-427 | `savgol_coeffs`, `savgol_filter` | Windows 5, 11, 31; orders 2, 3, 4; derivatives 0, 1, 2; five modes | Coefficients within 10⁻¹⁰; filtered Float32 output within 10⁻⁵ |
| WP-501b | `scipy.signal.get_window` | Each window; lengths 16, 1 024, 4 096; periodic and symmetric | 10⁻⁶ |
| WP-502, WP-504 | `numpy.fft.rfft`; `librosa.stft` | Lengths 16, 48, 80, 240, 1 024, 4 096; two framings | 10⁻⁵ of the frame maximum |
| WP-509, WP-512 | NumPy from the definitions; `librosa.feature.mfcc` | The speech and music fixtures | 10⁻⁴ of the frame maximum; coefficients within 10⁻³ |
| WP-513, WP-514 | `numpy.convolve`, `scipy.signal.correlate` | Lengths (16, 5), (1 024, 255), (48 000, 4 096); three modes | 10⁻⁵ of the largest output |
| WP-525 | `librosa.onset.onset_strength`, with the same floor and no clipping relative to the maximum | The music fixtures | 10⁻³ of the largest value |

`OPT` triggers. WP-422: the owner's request; no budget depends on it. WP-533: the full-analysis budget of §10.4 is missed and median filtering is its largest share. WP-613: the owner's request; no real-time budget depends on it.

| Milestone | Packages | Exit criterion |
|---|---|---|
| M0 Foundation | WP-001…016 | The empty package builds; every gate runs and fails correctly on a seeded violation. |
| M1 Core values and toolkit | WP-101…121 | Units, environment, errors and toolkit primitives are usable from tests. |
| M2 Real-time C layer | WP-201…227 | A hand-built C plan (gain → biquad → FIR) runs allocation-free and survives a kernel move. |
| M3 Pipeline, compiler, engine | WP-301…342 | Walking skeleton: one `Pipeline` attached to three mock sources gives identical output; a switch bound to `@State` works; the overhead gate is green; the skeleton runs on an iOS 15 device. |
| M4 LTI design and analysis | WP-401…440 | Appendix A parity suite green; a designed filter running in a pipeline measures as its analysis predicts. |
| M5 Spectral front-end and analysis | WP-501a…541 | The stock full-analysis pipeline runs on a mock source inside the real-time audit. |
| M6 Metal and calibration | WP-601…614 | Golden images green off-screen; crossovers measured and committed. |
| M7 Input and output | WP-701…712 | Capture-while-playing green on a device; an external microphone can be selected, unplugged and plugged back. |
| M8 User interface | WP-801…824 | Stability suite green at both levels; a pinch scales its axis; a size transition shows no seam. |
| M9 Hardening | WP-901a…910 | All gates green on the floor device; both registers signed off; the external parity suite green. |

Packages run in dependency order (WP-R4); a milestone is a theme, not a strict phase. All of M0 is done before M1 starts, so a Dep cell names an M0 package only where the link is worth pointing out. Broadly: M0 → M1 → (M2 ∥ the design half of M4, WP-401…431d ∥ the windows, WP-501a…f) → M3 → (the stage half of M4 ∥ M5) → (M6 ∥ M7) → M8 → M9. The places where a package waits for a later milestone:

- In M3, WP-313, WP-322 and WP-324 wait for the first filter and gain stages (WP-432a, WP-432c, WP-437), and WP-310 waits for the STFT step (WP-504).
- In M4, WP-423 waits for the windows (WP-501b), and the stage packages WP-432a…438b wait for the plan compiler and the offline runner (WP-306c, WP-311b, WP-323).
- In M5, WP-519 waits for WP-423 and WP-539 for WP-438b.
- In M6, the calibration packages WP-611c, WP-611d and WP-612 wait for the kernels and steps they measure.

### M0 — Foundation

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-001 | `Package.swift`: targets and products of §4.2, iOS 15, tools 6.2, Swift 6 mode, one placeholder source per target | — | Builds for simulator and device; a script confirms the dependency graph equals §4.2 | A, T | |
| WP-002 | `Scripts/lint-bans.sh`, part 1: the UIKit boundary as UB-5 mechanises it, with its allow-list | 001 | Each seeded violation in a fixture tree is reported; the clean tree passes | A, T | |
| WP-003 | `Scripts/coverage-gate.sh`: reads `xccov` JSON; aggregate, per-target and changed-files modes (COV-2, COV-3) | 001 | Fixture reports give the right exit code in pass and fail cases | T, A | |
| WP-004 | `ZTronDSPTesting`: `expectClose` (absolute, relative, dB), seeded signals, golden loader (JSON and raw little-endian floats) | 001 | Self-tests, including failure messages; malformed files rejected | T, N | |
| WP-005 | `ZTronDSPTesting`: allocation probe, a C hook on `malloc_logger` that counts the registered thread only; `expectNoAllocations { }` | 001 | A control block that allocates is detected; allocations on another thread are not counted; an empty block reports 0; runs in a simulator test | R, T | |
| WP-006 | Benchmark harness: warm-up, iterations, `mach_absolute_time`, JSON result, baseline comparison | 001 | Self-test on a synthetic workload; a seeded regression is detected | R, T | |
| WP-007 | Golden framework: generator runner, pinned requirements, SHA-256 manifest, one sample generator (STG-2) | 004 | Re-running reproduces the committed vectors; the manifest check fails on a changed vector | N, T | |
| WP-008 | Process files: ledger, report, change-request and stability-note templates; the registers of §9.2, §9.5, COV-4 and IMM-2 | — | Templates carry every field of §11; the registers exist and are empty | A, T | |
| WP-009 | Compile-fixture harness: `Scripts/compile-fixtures.sh` type-checks `Tests/CompileFixtures/{valid,invalid}`; an invalid fixture must fail with the sentence named in its header comment | 001 | A valid file filed as invalid fails the run, and the reverse; a wrong sentence fails the run | T, A | |
| WP-010 | Lint, part 2: hot-path bans (RT-7) and the source-type check (ATT-2) | 002 | Seeded violations reported; the clean tree passes | R, T | |
| WP-011 | Lint, part 3: approval-gated API (APR-1, APR-2), the SwiftUI boundary (BIND-7), `@_spi`, `package` and `@testable` in production targets (EXT-1) | 002 | Seeded `AnyView`, `import Combine`, `ObservableObject` and `@_spi` are each reported; an allow-list entry without an approved change request fails | A, T | |
| WP-012 | Lint, part 4: configuration-object names (API-6); `public var` and `open` against their registers (IMM-2, VIS-1) | 002 | A seeded `…Options` type, a public setter and an `open class` are each reported | A, T | |
| WP-013 | API digest: the public symbol graph of each target committed as text; a difference fails; checks over it (stage initialisers end in `isActive:`; Design and Analysis reference only public Core symbols) | 001 | A seeded API change, a stage without `isActive:` and a non-public Core reference each fail | A, T | |
| WP-014 | CI workflow: the gates of §10.3 in order, the simulator matrix (PLAT-3), a Thread Sanitizer job, a pinned benchmark runner | 002, 003, 006, 009 | A seeded violation of each gate fails the workflow; a clean tree passes | T, A | |
| WP-015 | Build setting `ZTRONDSP_PERF_ANNOTATIONS` and the wrapper for `@_noAllocation @_noLocks` (RT-7) | 001 | With the setting on, a leaf loop that allocates fails to build; with it off, the attributes are absent | R, T | |
| WP-016 | Stress-fixture library for stability tests: ill-conditioned polynomials, filters near 0 Hz and near Nyquist, silence, full scale, decaying tails (NUMS-2) | 004 | Each fixture documents its condition number or hazard; loader self-test | N, T | |

### M1 — Core values and toolkit

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-101 | `Frequency` and its resolution against a sample rate | 001 | Linear units round-trip to 1 ulp, logarithmic ones (MIDI, mel) within 10⁻¹⁴ relative; a negative or non-finite value is a typed error | N, A | |
| WP-102 | `Amplification`, decibel conversions (amplitude, power), floor | 001 | Table tests including 0, negative and floor | N, A | |
| WP-103 | `RollOff`, `RollOffRounding`, order mapping (§6.3.4) | 001 | 24 dB/oct → 4; 96 → 16; 25 throws under `.exact`, gives 5 under `.up` | N, A | |
| WP-104 | `SignalFormat`, `ChannelPolicy`, `AudioBlock` | 001 | Layout tests; compiles under strict concurrency | A, R | |
| WP-105 | `AlignedBuffer<Element>`: owned, aligned, fixed capacity, no copy-on-write | 001 | Alignment asserted; reads and writes allocation-free; storage freed | R, T | |
| WP-106 | `DSPError` with the cases of §9.3, stage path and descriptions | 001 | Every case constructed and described | A, T | |
| WP-107 | `Complex` (Double) for design maths | 001 | Field identities; polar round trip ≤ 10⁻¹⁵ | N, T | |
| WP-108 | `DSPEnvironment`, `DSPEnvironmentKey`, built-in keys; derived keys have no setter (ENV-3) | 101, 104, 111 | Derived keys follow `sampleRate`; setting a derived key does not compile (fixture); custom key defaults; value semantics | A, T | |
| WP-109 | Positional environment: rate changes, spectral scope, feature-rate sequences (ENV-1, §5.2) | 108 | A decimator halves Nyquist downstream only; spectral keys are `nil` outside a spectral scope | A, N | |
| WP-110a | Signal domains, `SampledSequence`, the sink-capability protocols, run-time `DomainTag` | 001 | Tags are distinct; conformances equal the tables of §5.2 | A, T | |
| WP-110b | Frame types `RealFrame`, `ComplexFrame`, `ScalarFrame`, `EnvelopeFrame`: borrowed views with index and time | 105, 110a | A view reads its storage without copying; lifetime rules documented and tested | A, R | |
| WP-111 | `FeedAxis`: linear frequency, mel centres, constant-Q bins, pitch classes, lags, quefrency, tempo | 101 | Row-to-unit mapping per case; equality | A, N | |
| WP-112 | `BackgroundWork`: the executor behind every analysis and export (BG-1…BG-3) | 106 | Work runs off the main thread; cancellation stops it between steps and throws `cancelled`; results are `Sendable` values | A, R | |
| WP-113 | Toolkit, element-wise: scale, add, subtract, multiply, clip; Swift-loop and vDSP implementations, `@inlinable` (§7.4) | 105 | The implementations agree bit for bit; allocation-free; from another module no call is made per element (checked in the benchmark's disassembly) | N, R | |
| WP-114 | Toolkit, reductions: sum, dot product, mean square, minimum, maximum; scalar, SIMD and vDSP implementations | 105 | Agreement within 10⁻⁶ relative; lengths 0, 1, 7, 8, 9 | N, R | |
| WP-115 | `Implementation` and `CrossoverTable`: an immutable table with the initial values of §7.4, and its lookup (SEL-2, SEL-4, SEL-5) | 113, 114 | `.automatic` follows the table; a forced choice is honoured; the table is `Codable` and `Equatable` | A, R | |
| WP-116 | Toolkit: `zeroPadded`, `isFastLength`, `nextFastLength`, by arithmetic (E-09) | 105 | Padding ≡ reference for both placements; the rule matches the documented lengths for 1…4 096 and never creates a setup | N, R | |
| WP-117 | Toolkit: `subsampled(by:phase:)` and `upsampled(by:)` | 105 | ≡ reference; up then down by one factor is the identity, bit for bit | N, R | |
| WP-118 | Toolkit: `HistoryBuffer` and `OverlapAdder` | 105 | Window contents ≡ reference for irregular pushes; overlap-add ≡ reference; allocation-free | R, N | |
| WP-119 | Toolkit: `Ramp` and `flushSmallState` (RT-6) | 105 | A ramp reaches its target exactly; a state value below 10⁻²⁰ becomes zero; allocation-free | N, R | |
| WP-120 | `MATLABScript`: variables (real and complex vectors, matrices), plot commands, number formatting, size guard (MAT-2…MAT-4) | 106 | Emitted text equals golden scripts; numbers read back exactly; an oversized matrix is `exportTooLarge` | A, N | |
| WP-121 | `ParameterVector`: ordered continuous values with addition, subtraction and scaling | 001 | Vector-space identities; behaviour for vectors of unequal length as ANI-4 needs it | N, A | |

### M2 — Real-time C layer

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-201 | `CZTronDSP` scaffolding: `ZTD_NONBLOCKING`, the audited vDSP allow-list header, function-effect warnings as errors through the manifest (E-32) | 001 | A fixture that calls `malloc` in a `nonblocking` function fails to build; the target builds clean | R, A | |
| WP-202 | SPSC ring: C11 atomics, planar Float32, power-of-two capacity, overrun counter (RT-8) | 201 | Single-thread semantics; two-thread stress over 10⁷ frames with no loss or duplication; Thread Sanitizer clean | R, T | |
| WP-203 | Mirrored ring storage (`vm_remap`), pre-faulted (RT-9), with automatic fall-back to copy on wrap | 202 | A window spanning the wrap is contiguous and correct; the fall-back is forced and tested | R, T | ALG |
| WP-204 | Kernel ABI (`ztd_kernel_t` of §5.11.1), `ztd_plan_t`, `ztd_plan_run` | 201 | A plan of no-op kernels: dispatch cost recorded; allocation-free | R, A | |
| WP-205 | Plan slot: atomic exchange, retire list drained off-thread (RT-3) | 204 | Exchange-while-running stress; each retired plan destroyed exactly once | R, T | |
| WP-206 | SPSC command queue of fixed-size messages, applied at block boundaries (RT-4) | 204 | Order kept; overflow reported; never blocks | R, T | |
| WP-207 | Gain kernel: constant and ramped, per channel; C-loop and vDSP implementations, bound when created (SEL-3) | 204 | Both implementations bit-exact with a scalar loop; ramp continuous across blocks | N, R | |
| WP-208 | Biquad cascade kernel, single precision (`vDSP_biquad`), state and reset | 204 | Fixture (Butterworth high-pass, 1 kHz, order 4, 48 kHz): impulse response within 10⁻⁵ of a double-precision reference; block sizes 64…512 bit-identical, 1 and 7 within −100 dB | N, R | ALG |
| WP-209 | Live coefficient update on the single path (`vDSP_biquad_SetCoefficientsDouble`, E-08) | 206, 208 | Filter memory preserved; CLICK-1 for a cutoff step of a tenth of an octave | N, R | |
| WP-210 | Multichannel biquad kernel (`vDSP_biquadm`), single precision | 208 | Each channel equals the mono kernel | N, R | |
| WP-211 | Double-precision biquad kernel: the package's own C loop (transposed direct form II); coefficients exchanged at a block boundary (REAL-3) | 204, 206 | 20 Hz, order 8 high-pass at 96 kHz within 0.01 dB of the reference; a live exchange keeps the state; allocation-free | N, R | ALG |
| WP-212 | Direct FIR kernel: history plus `vDSP_conv` | 204 | Equals offline convolution; block-size invariant; latency reported | N, R | ALG |
| WP-213 | Decimator kernel (`vDSP_desamp`), phase carried across blocks | 212 | Equals filter-then-subsample for irregular block sizes | N, R | ALG |
| WP-214 | Partitioned convolution: delay-line structure and kernel spectra | 204 | Spectra equal the DFT of each partition | N, R | ALG |
| WP-215 | Partitioned convolution: processing | 214 | Within −100 dB of the direct kernel; allocation-free | N, R | ALG |
| WP-216 | State hygiene (RT-6): `ztd_flush_state` at the end of each block; the floating-point mode is left alone | 204 | A decaying tail reaches exact zero within one block of falling below 10⁻²⁰; the floating-point environment is unchanged | R, N | |
| WP-217 | Cross-fade helper: fixed duration, spanning blocks | 204 | The two fades sum to one at every sample; the duration does not depend on the block size; allocation-free | N, R | |
| WP-218 | Alpha–beta kernel | 204 | Matches the defining recurrence within 10⁻⁶; allocation-free | N, R | |
| WP-219 | Minimum / maximum exchange of two lanes: C-loop and vDSP implementations | 201 | Both equal scalar; timings over the size grid recorded for WP-611b | R, N | ALG |
| WP-220 | Kernel activation switch through the command queue: fade out and stop; reset, pre-roll, fade in (ACT-5, ACT-7) | 206, 217 | CLICK-1 when toggling under a sine; an inactive kernel is not called; restoring a 2 001-tap FIR under signal shows no transient beyond CLICK-1; allocation-free | R, N | |
| WP-221 | Latency-matched bypass: a delay line fed in both states (ACT-8) | 220, 212 | An impulse through a bypassed linear-phase FIR arrives at the same sample as when the stage is active, also when the switch flips in mid-signal | N, R | |
| WP-222 | Lossless ring mode: the writer waits for space; for reader threads only (RT-8) | 202 | No frame lost or duplicated under a slow consumer; the waiting call cannot be reached from `nonblocking` code (build check) | R, T | |
| WP-223 | Interpolator kernel: polyphase FIR, one `vDSP_conv` per phase with an output stride | 212 | Equals zero-stuff-then-filter; block-size invariant; gain L | N, R | ALG |
| WP-224 | Kernel ownership transfer between plans (SWAP-1) | 204, 205 | A moved kernel continues bit-identically across an exchange; it is destroyed exactly once | R, T | |
| WP-225 | Pre-roll runner: kernels run beside the live plan with their output discarded (SWAP-2, ACT-7) | 204 | After pre-roll a kernel's state equals that of one that ran live; allocation-free | R, N | |
| WP-226 | Scheduling helper: a Mach time-constraint policy for the analysis thread (RT-9) | 201 | The policy reads back as set; a refused request leaves the quality of service in place and is reported | R, S | |
| WP-227 | Subsample and zero-stuff kernels (no filter), phase carried across blocks | 204 | ≡ the toolkit functions for irregular block sizes | N, R | |

### M3 — Pipeline, compiler, engine

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-301 | `PipelineStage` with `Input` and `Output`, `SequenceStage`, the erased `StageDescription` with its `DomainRule` | 106, 108, 110a | Equality and hashing; `Sendable`; each rule maps tags as §5.2 states | A, T | |
| WP-302a | `@PipelineBuilder` on partial blocks with the same-domain constraint; `Pipeline<Input, Output>` | 301, 009 | Builder fixtures give the expected descriptions; a mismatched pair does not compile (fixture) | A, T | |
| WP-302b | `SequenceChain`, its lifting into typed pipelines, control flow including limited availability (API-2, ORD-3) | 302a | The ORD-3 fixtures compile or fail as specified; `if #available` around a sequence-only block compiles | A, T | |
| WP-303 | Fluent spelling: the appending core and its equivalence with the builder | 302a | Fluent ≡ builder for the fixtures that exist (API-1) | A, T | |
| WP-304 | `EnvironmentReader`, `Group`, scoped `.environment` (ENV-3); how a reader compares (API-1) | 302b, 109 | A reader sees positional values; overrides are scoped; a pipeline equals its copy; two readers that produce equal stages resolve to equal descriptions | A, T | |
| WP-305 | `pipeline.parameters` and `replacingParameters(_:)` over `ParameterVector` (ANI-2) | 301, 121 | The round trip is the identity; frequencies are carried as log₂ hertz and gains in decibels; structural values are absent | A, N | |
| WP-306a | Plan compiler, resolve pass: positional environment, readers expanded | 302b, 304 | Resolved descriptions for the fixtures; stage paths recorded | A, T | |
| WP-306b | Plan compiler, validate pass: tier-2 order rules, O-16…O-18, REAL-2 | 306a | One failing fixture for each of O-16, O-17, O-18 and REAL-2, each naming its stage | A, N | |
| WP-306c | Plan compiler, lower pass to `KernelSpec`; the implementation bound by size (SEL-3) | 306b, 115 | Expected IR for the fixtures; the bound implementation follows the table | A, R | |
| WP-307 | Fusion F1 and F4 | 306c | Expected IR; fused ≡ unfused, bit for bit | N, R | |
| WP-308 | Fusion F2 | 306c | One cascade emitted; output bit-identical to the unfused chain | N, R | |
| WP-309 | Fusion F3 | 306c | Within −100 dB of the unfused chain; length bound respected | N, R | |
| WP-310 | Fusion F5: shared framing steps and equal runs; activity follows consumers (ACT-9) | 306c, 326, 330b, 504 | Three taps with one framing cost one FFT per hop, and none when every consumer is inactive (probe) | R, A | |
| WP-311a | Plan emission: IR → C kernels | 306c, 207–213 | The emitted plan runs the fixtures ≡ reference | R, N | |
| WP-311b | `ExecutionPlan` ownership and teardown (RT-3) | 311a | No leak over 10³ create / destroy cycles; nothing is freed on the analysis thread | R, T | |
| WP-312 | Plan difference: equal, values, topology (§5.5.4) | 311b | Fixtures for each class, built from the topology rule | A, T | |
| WP-313 | Value update path (§5.5.4) | 312, 209, 211, 320b, 432a | A cutoff swept one octave in 10 ms steps on a running session: allocation-free, CLICK-1 | R, N | |
| WP-314a | Topology change, part 1: unchanged stages and branches keep their kernels and nodes (SWAP-1) | 312, 205, 224 | A tap added downstream leaves upstream filter state and the other feeds bit-identical to a run without the change | R, N | |
| WP-314b | Topology change, part 2: pre-roll and fade of what is new; the output-changed event; the latest update wins (SWAP-2…SWAP-4) | 314a, 225, 217 | Replacing one filter on the main line under signal meets CLICK-1; a change of output latency is reported; an update during pre-roll supersedes it | R, N | |
| WP-315 | `SampleSource`, the push and pull refinements, `SourceAdapter` | 104, 202 | Fake push and pull sources deliver identical blocks | A, T | |
| WP-316 | `GeneratorSource` | 315 | Analytic check per generator; seeded determinism | N, T | |
| WP-317 | `BufferSource`, `ScriptedSource` | 315 | Batch scripts, injected errors and format changes honoured | T, A | |
| WP-318 | Block assembler: arbitrary batches → fixed blocks | 315 | Any batch pattern yields the same block stream | R, T | |
| WP-319a | Analysis thread: creation, scheduling (RT-9), parked while no session runs | 318, 226 | Idempotent start / stop; no wake-up in one second while parked (probe counter) | R, S | |
| WP-319b | Polling wake against an injected clock (§4.3); a thread of its own for an offline session | 319a | Wake-ups every half I/O buffer and never under 1 ms; an offline session does not run on the analysis thread | R, T | |
| WP-320a | `PipelineSession`: the state table of §4.5, `SessionEvent` | 311b, 319b | Every cell of the table, repeated calls included | A, T | |
| WP-320b | `DSPEngine.attach`; independent state per attachment (ATT-1); sink claims (ATT-5); re-plan on a format change (ATT-4) | 320a | One pipeline on three sources: three independent states; a second live writer of one sink is `sinkInUse` and attaches once the first detaches; a format change is survived | A, T | |
| WP-320c | Source hub: several attachments on one source (ATT-6) | 320b | Two pipelines on one source see identical blocks; the source starts once and stops with the last attachment | A, R | |
| WP-321a | `AnalysisNode`, the node schedule in the plan, `FeatureSink` | 311b | Nodes run in declared order at their tap position; allocation-free | R, A | |
| WP-321b | `FeatureStream` (a bounded `AsyncSequence`) and `FeatureCallback` | 321a, 110b | The oldest frames are dropped and counted when the consumer lags; no unbounded growth; no Combine | A, R | |
| WP-322 | Latency accounting into the environment (REAL-5) | 320b, 432c | Reported latency equals the measured impulse delay | N, A | |
| WP-323 | Offline API: `pipeline.process(_:format:)` | 311b | Offline ≡ engine output | N, T | |
| WP-324 | Overhead gate (§5.7) and the allocation audit of the signal chain | 320b, 005, 006, 308, 330b, 432a, 437 | Budgets of §5.7 met on the host; 0 allocations over 10⁴ blocks | R, T | |
| WP-325 | The step-family mechanism (ORD-1, ORD-4), on two reference families: the sequence stages and `Emit` | 302b, 303 | Valid and invalid fixtures for both; each invalid one reports its sentence | A, T | |
| WP-326 | `Tap`, `Emit`, fluent `.tap`, nested branches | 325, 321a | A branch leaves the main line bit-identical; O-11 and O-15 fixtures | A, N | |
| WP-327a | `DynamicPipeline`: `append` under the tier-2 rules (ORD-5, ORD-6) | 306b, 326 | An invalid append, a forged description and an invalid branch are each rejected with the stage's path | A, T | |
| WP-327b | `attach` and `update` for a `DynamicPipeline` | 327a, 320b | Equal stages give equal plans, typed or dynamic; an update follows §5.5.4 | A, T | |
| WP-328 | Order-matrix generator: every public stage on every domain; tier 1 and tier 2 agree (ORD-2) | 325, 326, 327a | The matrix passes for the stages that exist; a seeded disagreement fails | T, A | |
| WP-329 | Activation API: `ActivationSource`, `Activation`, `.active(_:)`, description equality (ACT-1, ACT-2, ACT-12) | 301 | The default, `true` and `.active` give equal descriptions; a binding gives a different one; two bindings give equal ones | A, T | |
| WP-330a | Activation in the plan compiler: constants resolved, fusion barrier (ACT-4, ACT-6) | 329, 306c | A `.bypassed` constant leaves no kernel; a bound stage is not fused with its neighbours; the content of a `Group(isActive:)` is | R, N | |
| WP-330b | Activation at run time: bypass or suspension by stage kind, for kernels and nodes; cold resume (ACT-3, ACT-10) | 330a, 220, 221, 326 | A suspended branch runs no kernel and no node (probe); flipping a binding compiles nothing; no stale frame after a resume | R, N | |
| WP-331 | Binding pump, switches: capture on attach and update, the main-run-loop observer, `syncBindings()` (BIND-1…BIND-6) | 329, 320b | A hosted write is forwarded within the same run-loop turn; an idle loop does no work; the session never writes a switch | R, A | |
| WP-332 | Binding pump, results: latest-value slots, heartbeat at the result rate, write only on change (OUT-2…OUT-5) | 331 | A binding is written on the main thread, at most once per heartbeat and never with an unchanged value; no timer while nothing is bound | R, A | |
| WP-333 | `HeatmapFeed`: single writer, many readers, generation counter, `FeedAxis`, positional environment, liveness (ACT-11), `history` and `minimumHistory` | 202, 111 | Writer / reader stress; slow readers skip, never block; axis and liveness reported | R, V | |
| WP-334 | `WaveformFeed`: a live ring of (min, max) columns; a pyramid for a static overview | 105, 333 | ≡ naive reduction; level invariants | N, R | |
| WP-335 | `Emit(to:)` for bindings of `Float`, `ScalarFrame` and `[Float]` (OUT-1, O-11) | 332, 326 | Each value type receives its frames; a complex spectrum into a binding does not compile | A, T | |
| WP-336 | The measuring spelling `Step(…, to:)` as a domain-keeping recipe (OUT-1) | 335, 325 | A measuring step leaves the signal that follows bit-identical; it equals its `Tap` expansion | A, N | |
| WP-337 | `ProcessedSource`: `source.processed(by:)` (SRC-2) | 320c | A second pipeline attached to the processed source sees the first one's main-line output; the hand-over adds no latency | A, R | |
| WP-338 | Device run of the walking skeleton on iOS 15 (E-17) | 324 | Recorded run; every floor defect filed | S, A | |
| WP-339 | Extension surface for sample-domain stages: `SampleProcessor`, and a stage backed by the caller's C kernel (§5.11.1) | 311a, 325 | Both run in a pipeline declared outside Core; they are order-checked; activation and latency work with no code in the stage | A, R | |
| WP-340 | Non-finite input guard at the source adapter (NUM-1) | 318, 320a | NaN and infinity become 0 and are counted in a `SessionEvent` | N, R | |
| WP-341 | `FeedSnapshot`: an immutable copy of a feed's history with its axis and frame times | 333, 334 | A snapshot is consistent under a concurrent writer; it is taken off the analysis thread | A, R | |
| WP-342 | `StageValidation`: the public checks of §5.11.4, with errors that carry the stage's path | 306b | Each check passes and fails on its fixtures; the error names the stage | A, N | |

### M4 — LTI design and analysis

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-401 | `Polynomial`: evaluation (real, complex), product, from roots, derivative | 107 | Algebraic identities | N, T | |
| WP-402 | `PolynomialRootFinder.companionQR` (LAPACK, LA-1): scaling-only balance, Newton polish, `rootConditions` | 401 | Well-conditioned fixtures (κ ≤ 10⁴) to 10⁻¹⁰; degree 0–2 in closed form; the Wilkinson, expanded-Butterworth and triple-root fixtures documented at their limit; a LAPACK failure is a typed error | N, T | ALG |
| WP-403 | `ZeroPoleGain`, `TransferFunction`, `SecondOrderSections`, ZPK ↔ coefficients | 401, 402 | Round trips | N, A | |
| WP-404 | ZPK → SOS: nearest pairing and ordering | 403 | Parity with the reference pairing | N, T | ALG |
| WP-405 | Butterworth prototype | 403 | Golden | N, T | ALG |
| WP-406 | Chebyshev I prototype | 403 | Golden | N, T | ALG |
| WP-407 | Chebyshev II prototype | 403 | Golden | N, T | ALG |
| WP-408 | Elliptic helpers: complete integral, degree equation, inverse `sn` and `sc` by Landen | 107 | Tabulated values to 10⁻¹² | N, T | ALG |
| WP-409 | Elliptic prototype | 408, 403 | Golden | N, T | ALG |
| WP-410 | Bessel polynomial roots: Campos start, Aberth refinement | 107 | Residual ≤ 10⁻¹² for orders ≤ 25 | N, T | ALG |
| WP-411 | Bessel prototype, three normalisations | 410, 403 | Golden | N, T | ALG |
| WP-412 | Low-pass → low-pass and → high-pass (ZPK) | 403 | Golden | N, T | |
| WP-413 | Low-pass → band-pass and → band-stop (ZPK) | 403 | Golden | N, T | |
| WP-414 | Pre-warp and bilinear transform (ZPK and coefficient forms) | 403 | Golden | N, T | ALG |
| WP-415 | Order estimation: Butterworth, four responses | 405 | Golden | N, T | |
| WP-416 | Order estimation: Chebyshev I and II | 406, 407 | Golden | N, T | |
| WP-417 | Order estimation: elliptic | 409 | Golden | N, T | |
| WP-418a | `IIRDesign`, analog: family × response × order → ZPK and coefficient forms | 405–413 | Golden over the matrix | N, A | ALG |
| WP-418b | `IIRDesign`, digital: pre-warp, bilinear, section pairing → SOS | 418a, 404, 414 | Golden over the matrix | N, A | ALG |
| WP-418c | Order from a tolerance scheme: the `passband:stopband:maximumLoss:minimumAttenuation:` initialisers (§6.3.2) | 418b, 415–417 | Golden; the resulting filter meets its scheme | N, A | |
| WP-419 | Roll-off semantics per family (§6.3.4) | 418b, 103 | Slope within ±0.5 dB/oct where the table says exact or bounded; nominal cases documented; a band-stop takes the order only | N, A | |
| WP-420 | Cookbook peaking section and shelves | 403 | Centre gain within 0.01 dB; golden | N, T | |
| WP-421 | High-order band-boost, designed and paired in ZPK form | 403 | The six properties of §6.3.5 | N, T | ALG |
| WP-422 | Matched second-order peak | 420 | Properties 1, 2, 4 and 5; smaller shape error near Nyquist than WP-420 on the fixture grid | N, T | OPT |
| WP-423 | Windowed-sinc FIR, four responses, Kaiser estimates | 501b | Golden | N, T | ALG |
| WP-424 | FIR from a roll-off (§6.3.4) | 423, 103 | Measured transition slope ≥ requested; a stop-band edge beyond Nyquist is a typed error naming the smallest slope that fits | N, A | |
| WP-425 | Least-squares FIR (LAPACK): normal equations, condition test, the fall-back | 401 | Golden; an ill-conditioned fixture takes the fall-back and still meets it | N, T | ALG |
| WP-426 | Savitzky–Golay coefficients and derivatives: QR on a scaled abscissa | 401 | Golden | N, T | ALG |
| WP-427 | Savitzky–Golay application, five edge modes | 426 | Golden per mode | N, T | |
| WP-428a | `LTISystem` analysis: zeros, poles, gain, for digital and analog systems | 403, 402 | Fixtures including a pole on the unit circle and an analog system | N, A | |
| WP-428b | Stability, minimum and linear phase; the numerical figures of §6.3.8 | 428a, 208, 211 | Figures for the stress fixtures (WP-016) equal recorded values; analog criteria use the half plane | N, A | |
| WP-429 | Frequency, magnitude and unwrapped phase responses | 428a | Golden | N, T | |
| WP-430 | Group delay with undefined points; impulse and step responses | 429 | Golden; linear-phase delay equals (K − 1)/2; a point on a unit-circle zero is reported undefined | N, T | |
| WP-431a | Response values `LowPass`, `HighPass`, `BandPass`, `BandStop` over an IIR family or an FIR method | 418c, 419, 424, 425 | Each resolves to the design its arguments name; value semantics | A, N | |
| WP-431b | Equaliser values `BandBoost`, `LowShelf`, `HighShelf` | 420, 421, 419 | Each resolves to its design; the bandwidth forms of §6.3.5; a band past the limit is rejected | A, N | |
| WP-431c | `IIRSystem { }`: `Pole`, `Zero`, `Section`, `DifferenceEquation`, the IIR design values | 431a, 431b, 428a | Builder fixtures; conjugates completed; an element with a non-default `isActive` is rejected (ACT-1) | A, N | |
| WP-431d | `FIRSystem { }`: `Taps`, `Zero`, `LeastSquares`, the FIR design values | 431a, 428a | Builder fixtures; a pole away from the origin is rejected | A, N | |
| WP-432a | IIR filter stages: `LowPass` … `BandStop` as sequence stages, lowered to the cascade | 431a, 306c, 311b, 323, 208, 329 | The running pipeline's measured response is within 0.1 dB of the analysis | N, A | |
| WP-432b | `BandBoost`, `LowShelf`, `HighShelf` stages | 431b, 432a | As WP-432a | N, A | |
| WP-432c | `Filter(_:)` for an `IIRSystem` or an `FIRSystem`; the FIR response stages; FIR lowering (REAL-4) and latency | 431c, 431d, 432a, 212, 215 | Measured response within 0.1 dB; the direct and partitioned paths agree within −100 dB; latency reported | N, A | |
| WP-433 | `BiquadPrecision.automatic`, by measurement when the plan is compiled (REAL-3) | 432a, 211, 428b | Over a grid of cutoffs from 10 Hz to 0.45·f_s at 44.1, 48, 96 and 192 kHz and orders 2…8, the chosen path is within −100 dB of the double reference; the measurement runs on the control context | N, R | |
| WP-434 | `SavitzkyGolay` and `AlphaBeta` stages | 427, 218, 306c, 311b, 323 | Stage output ≡ offline function | N, A | |
| WP-435 | etk4j parity suite | 418c, 427, 430, 434 | One passing test per row of Appendix A (the FFT row is WP-502's) | T, N | |
| WP-436 | `Decimate(by:)` stage (§6.12) | 423, 213, 306c, 311b, 323, 109 | ≡ filter-then-subsample; alias rejection ≥ 80 dB; downstream stages see the reduced rate | N, A | |
| WP-437 | `Gain` stage (§6.2) | 306c, 207, 311b, 323 | ≡ scalar reference; a changed amount ramps (CLICK-1); adjacent gains merge (F1) | N, A | |
| WP-438a | `Subsample(by:)` and `Upsample(by:)` stages | 227, 306c, 311b, 323, 109 | ≡ the toolkit functions; the rates in the environment follow | N, A | |
| WP-438b | `Interpolate(by:)` stage | 223, 423, 306c, 311b, 323 | Image rejection ≥ 80 dB; `Interpolate` after `Decimate` restores a band-limited fixture to SNR ≥ 80 dB | N, A | |
| WP-439 | Asynchronous entry points for system analysis on `BackgroundWork` (BG-1) | 428b, 430, 112 | Runs off the main thread; can be cancelled; the result is an immutable value | A, R | |
| WP-440 | MATLAB export of a system analysis (§6.14) | 439, 120 | Golden script; it runs under Octave in the generator environment | A, N | |

### M5 — Spectral front-end and analysis

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-501a | `Window`: the vDSP set, generated by vDSP (WIN-1) | 004 | Each case equals the vDSP output bit for bit, full and half; the symmetric forms | N, T | |
| WP-501b | `Window`: the package set (rectangular, Blackman–Harris, Kaiser, flat-top, Gaussian), periodic and symmetric | 004 | Golden | N, T | |
| WP-501c | `.custom { t in … }`: sampling, equality by probe values, the checks of WIN-3 | 501b | Equal closures give equal descriptions; a non-finite or all-zero window is a typed error | A, N | |
| WP-501d | `WindowAnalysis`, part 1: gains, noise bandwidth, symmetry, edge values, the tail limit (WIN-4) | 501c, 112 | Reference values for the stock windows; the right verdict for closures that do not decay, diverge, or return NaN far out | N, T | ALG |
| WP-501e | `WindowAnalysis`, part 2: continuity, smoothness, integrability, by grid refinement (WIN-6) | 501d | Smoothness 0 for rectangular, 1 for triangular, 2 for Hann; a closure with an interior jump is located within one sample | N, T | ALG |
| WP-501f | `WindowAnalysis`, part 3: main-lobe width, side-lobe level and fall-off, scalloping loss; the overlap-add tests for a hop | 501d, 502 | Reference figures for the stock windows within 0.1 dB and 0.05 bin | N, T | ALG |
| WP-501g | Window diagnostics at attach: `.logged()`; MATLAB export of the analysis | 501e, 501f, 120 | The report is logged once per attachment when asked and never otherwise; golden script | A, T | |
| WP-502 | `FFTBackend`, vDSP real forward and inverse; lengths admitted by arithmetic only | 105, 116 | Parity with a naive DFT (N ≤ 64) and golden; an illegal length is a typed error, and no setup call is made for it | N, R | ALG |
| WP-503 | Framer on the ring, causal and centred | 203 | Frames ≡ offline slicing for irregular batches; no copy on the mirrored ring | R, T | |
| WP-504 | `STFT` step: complex frames, window normalisations, `paddedTo:` | 502, 503, 501a, 321a | Golden; allocation-free | N, R | |
| WP-505 | `InverseSTFT` step, overlap-add check | 504, 118 | Reconstruction SNR ≥ 100 dB | N, R | |
| WP-506 | `Level` step with its own window and hop; its measuring spelling | 102, 321a, 336 | Analytic signals; the values do not depend on the engine's block size | N, R | |
| WP-507 | `SpectralCentroid` step on a linear axis; its measuring spelling | 504, 534, 336 | §6.5 acceptance | N, R | ALG |
| WP-508 | Mel formulas (Slaney, HTK), hertz ↔ mel, `Frequency.mel`, filter-bank weights and normalisations (§6.11) | 101 | Conversions round-trip within 10⁻⁹; weights equal the reference within 10⁻⁶; the peak of band m is 2 / (f₍m+2₎ − f₍m₎) under `.slaney` | N, T | ALG |
| WP-509 | Real and power cepstrum; the `Cepstrum` step | 502, 321a | Golden; an echo appears at its delay | N, R | ALG |
| WP-510 | Complex cepstrum; `InverseCepstrum` | 509 | Round trip ≤ 10⁻⁵ | N, R | ALG |
| WP-511 | `Lifter` and `CepstralPitch` steps; confidence; the measuring spelling | 509, 336 | f₀ of a harmonic fixture within 1 %; mean confidence higher on the harmonic fixture than on white noise | N, R | |
| WP-512 | `CepstralCoefficients`, `InverseCepstralCoefficients`, the `MFCC` recipe | 535 | Golden; the inverse is exact when `count` equals the band count | N, R | |
| WP-513 | One-shot convolution: direct, FFT, automatic; three modes | 502 | Golden | N, R | ALG |
| WP-514 | Correlation and normalisations; the zero-denominator rule | 513 | Golden; silence gives zeros | N, T | |
| WP-515 | Autocorrelation, zero-padded; the streaming `Autocorrelation` step | 514, 503, 321a | Parity with direct; a periodic fixture peaks at its period | N, R | ALG |
| WP-516 | `Convolve` stage with strategy selection | 215, 212, 306c, 311b, 323, 513 | ≡ one-shot convolution | N, R | |
| WP-517 | Constant-Q geometry, with tuning | 101 | Frequencies and atom lengths match the definitions of §6.8 | N, T | |
| WP-518 | One-octave sparse spectral kernel (CSR, split complex) | 517, 502, 501b | ≥ 99.9 % of kernel energy kept; parity with dense | N, R | ALG |
| WP-519 | Half-band decimator and octave schedule | 423, 213 | Alias rejection ≥ 80 dB; illegal hops rejected with suggestions | N, R | ALG |
| WP-520 | Sparse kernel × spectrum product | 518 | ≡ dense product; benchmark recorded | N, R | ALG |
| WP-521 | Top-octave `ConstantQ` step | 520, 503, 321a | Bin-centre tones within 0.5 dB | N, R | ALG |
| WP-522a | Octave recursion | 521, 519 | §6.8 acceptance over all octaves | N, R | ALG |
| WP-522b | Time alignment across octaves; latency | 522a | Octaves aligned to the sample; latency reported | N, R | |
| WP-523 | `ConstantQScale` step | 534, 517 | ≡ the dense projection computed in double precision, within 10⁻⁵ of the frame maximum; a bin-centre tone peaks in its bin; powers use the squared response | N, R | ALG |
| WP-524 | `ChromaFold` step and normalisation; the `ChromaCQT` recipe | 522b, 534 | §6.8 chroma acceptance; silence gives zeros | N, R | |
| WP-525 | `OnsetStrength` step with its floor | 535 | Golden | N, R | ALG |
| WP-526 | Autocorrelation tempogram | 525, 515 | §6.9 acceptance | N, R | ALG |
| WP-527 | Fourier tempogram | 525, 504 | §6.9 acceptance | N, R | ALG |
| WP-528 | Median-network generator, in Core: odd-even merge, pruned to the median wire | — | Exhaustive 0–1 check for k ≤ 15; randomised for k ≤ 63 | N, T | ALG |
| WP-529 | Median kernels, time lanes and frequency lanes, the edge convention of §6.1; a sort-based oracle in `ZTronDSPTesting` | 528, 219 | ≡ oracle on random data; allocation-free | N, R | ALG |
| WP-530 | HPSS masks: hard, soft, margins, the zero-denominator rule | 529 | §6.10 mask acceptance | N, R | ALG |
| WP-531a | Streaming `HarmonicPercussive(select:)`: history ring, causal mode | 530, 504 | ≡ offline on interior frames | N, R | ALG |
| WP-531b | Centred mode with look-ahead; latency | 531a | ≡ offline; latency equals the look-ahead | N, R | |
| WP-532 | HPSS resynthesis and the `HPSS(select:)` recipe, with its bound bypass | 531b, 505, 330b | The components reconstruct the input with SNR ≥ 100 dB; a bound switch meets CLICK-1 and keeps the latency (ACT-7, ACT-8) | N, R | |
| WP-533 | Incremental sorted-lanes median | 529 | ≡ oracle; faster than WP-529 for k ≥ 17 | R, N | OPT |
| WP-534 | `Magnitude`, `Power`, `Decibels`, `InverseDecibels` steps; the `Spectrogram` recipe | 504, 325, 326, 333 | Analytic values; O-3 and O-4 fixtures; allocation-free | N, R | |
| WP-535 | `MelScale` step and the `MelSpectrogram` recipe: banded application, attach-time checks (O-18), mel `FeedAxis` | 508, 534 | §6.11 acceptance | N, R | ALG |
| WP-536 | `Waveform(resolution:)` step | 321a, 334 | ≡ naive reduction for irregular blocks; allocation-free | N, R | |
| WP-537 | `InvertibleStage` and `InversionReport`: conditions, predicted error, measured round trip (INV-1…INV-4) | 112, 301 | A report for an exact pair (`Upsample`, `Subsample` as functions) is exact; it runs on `BackgroundWork` | A, N | ALG |
| WP-538 | Inversion report for `STFT`: the overlap-add conditions and frame bounds | 537, 505, 501f | The predicted bound is at or above the measured error on the fixtures; a failing window is reported, not thrown | N, T | |
| WP-539 | Inversion reports for `Decimate` and `Subsample` (the sampling theorem, tested on the signal), `Decibels`, `Cepstrum`, `CepstralCoefficients` | 537, 438b, 510, 512, 534 | A band-limited fixture passes; an aliasing fixture fails, with the aliased energy within 1 dB of the truth | N, T | |
| WP-540 | MATLAB export of frames: heat-map and waveform snapshots, scalar tracks, inversion reports | 120, 341, 537 | Golden scripts; they run under Octave | A, N | |
| WP-541 | Real-time audit of the stock full-analysis pipeline of §10.4 on a mock source | 310, 507, 524, 526, 532 | 0 allocations over 10⁴ blocks | R, T | |

### M6 — Metal and calibration

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-601 | `MetalContext`: device, queue, library from the module bundle (DEP-4), capability flags | 001 | Works on the simulator; an absent device yields `backendUnavailable` | A, T | |
| WP-602 | Colour maps as 256 × 1 look-up textures | 601 | Bytes equal the reference tables | V, T | |
| WP-603 | Image support for tests: off-screen target, read-back, PSNR, golden-image loader (§8.5) | 601, 004 | Self-tests on synthetic images | V, T | |
| WP-604 | Ring texture, column upload (half-float), max-reduced levels along frequency (V-8) | 601, 333 | Read-back equals input within half-float precision; each level is the maximum of the two entries below it; a sampler test records whether half-float textures filter linearly | V, R | |
| WP-605 | Heat-map shader: range, look-up, axis warp over the reduced levels, scroll offset | 604, 602, 603 | The golden images of §8.5, PSNR ≥ 40 dB; a one-bin peak survives every scale | V, N | ALG |
| WP-606 | `HeatmapRenderer`: the dirty-set state machine (§8.3) | 605 | Draws only on a cause; a resize uploads nothing | V, R | |
| WP-607 | Envelope texture: ring and pyramid levels from a `WaveformFeed` | 601, 334 | Read-back parity | V, R | |
| WP-608 | Waveform shader and renderer | 607, 603 | Golden images | V, N | |
| WP-609 | `FeedSnapshot.image(…)`: off-screen render, Core Image, `CGImage`, on `BackgroundWork` | 606, 341, 112 | Pixel parity with read-back; never on the main thread | V, A | |
| WP-610 | Median on the GPU (the network per texel) | 528, 601 | ≡ the sort-based oracle on random spectrograms | N, R | ALG |
| WP-611a | Calibration harness: a search for the crossover of two implementations over a size grid | 006, 115 | A synthetic pair with a known crossover is found within one grid step | R, T | ALG |
| WP-611b | Crossovers of the toolkit primitives and the lane exchange | 611a, 113, 114, 219 | Measured, recorded, committed as shipped values; forced choices honoured | R, A | |
| WP-611c | Crossovers of the gain and biquad kernels, direct ↔ FFT convolution, direct ↔ partitioned FIR, banded ↔ dense mel projection | 611a, 207, 208, 513, 215, 535 | As WP-611b | R, A | |
| WP-611d | Crossover CPU ↔ GPU median; `Calibration.measure()` on the device, on `BackgroundWork` | 611a, 610, 529, 112 | As WP-611b; a measured table is a value the engine accepts | R, A | |
| WP-612 | `Implementation` resolved for offline HPSS: the `.metal` median with its CPU fall-back (GPU-1, GPU-3, GPU-4) | 610, 611d, 531b | `.automatic` follows the table; `.metal` without a device is `backendUnavailable`; results ≡ CPU | A, N | |
| WP-613 | Batched offline STFT through MPSGraph (iOS 17+) | 504, 601 | Parity with CPU; availability-gated | N, R | OPT |
| WP-614 | MATLAB export of calibration curves | 611a, 120 | Golden script | A, T | |

### M7 — Input and output

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-701 | `AudioSessionPolicy`, the `AudioSessionControlling` seam and its fake (CAP-1…CAP-7) | 106 | Each policy yields the expected category, mode and options; a session that already permits input is left untouched; `.external` never mutates the session | S, T | |
| WP-702 | `MicrophoneAuthorizing` seam, two OS paths (E-16) | 106 | Every state through a fake; denial is `permissionDenied` | S, T | |
| WP-703 | Objective-C sink-node factory writing to a ring: the classic initialiser and the iOS 27 real-time-safe one | 202 | The block, driven with a synthetic buffer list, fills the ring; function-effect clean | R, S | |
| WP-704 | `HardwareInputSource` | 701–703, 315 | Simulator smoke test: format discovered, frames delivered | S, R | |
| WP-705a | Interruptions (the first three rows of CAP-8) | 704, 320b | Injected notifications drive each row; stages start cold after a resume | S, T | |
| WP-705b | Route changes, engine configuration changes, media-services reset, loss of input (the rest of CAP-8) | 705a | Injected notifications drive each row; a format change re-plans | S, T | |
| WP-706 | `EngineNodeTapSource`: the iOS 27 tap API gated; the pacing buffer | 315 | In manual rendering, tapped samples ≡ rendered samples; with an injected clock, blocks are released at the block rate | S, T | |
| WP-707 | `FileSource`: reader thread, lossless ring, pacing, optional rate conversion | 315, 222 | Decoded samples ≡ reference; with an injected clock real-time pacing releases blocks at the block rate ± one block; `BufferSource`, `ScriptedSource` and `FileSource` give bit-identical pipeline output | S, N | |
| WP-708 | Capture-while-playing integration test (R-22), cases A and B of §4.6; a device run | 704, 320b | The assertions of each case; the device-lab run recorded | S, T | |
| WP-709 | Memory-pressure response (MEM-1) | 320b, 333 | A simulated critical event trims only feeds that declared a smaller `minimumHistory`; a warning empties the retire list; no UIKit | S, A | |
| WP-710 | `AudioInput` and input selection (MIC-1…MIC-3, MIC-6) | 701, 704 | Through the fake session: inputs listed; preferred input and data source applied; an absent input is `sourceUnavailable` | S, A | |
| WP-711 | Hot-plug of an external microphone (MIC-4) | 710, 705b | Injected route changes: a lost input falls back and is reported; its return restores the selection; the session survives both | S, T | |
| WP-712 | Bluetooth inputs: hands-free opt-in; high-quality recording on iOS 26 and later (MIC-5) | 710 | The options are present only when asked for and available; availability-gated | S, A | |

### M8 — User interface

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-801 | `MetalViewRepresentable` and its coordinator: the single allow-listed bridge file (§8.6) | 606 | Lint passes; make and update counted by the probe | V, A | |
| WP-802 | `FrameScheduler` (§8.3) | 801 | With a fake clock: a stopped session pauses the link; a suspended feed pauses it (ACT-11); a burst gives at most one draw per tick | V, R | |
| WP-803a | `HeatmapView(feed:)` | 801, 802 | Its scenarios of §8.4 | V, A | |
| WP-803b | `SpectrogramView(feed:)`: frequency scale and range | 803a, 812 | Mel and constant-Q feeds are drawn bin for bin and labelled from `FeedAxis` (VC-5) | V, A | |
| WP-804 | `WaveformView(feed:)` | 608, 801, 802 | Its scenarios of §8.4 | V, A | |
| WP-805 | `ChromagramView(feed:)` | 803a, 524 | Twelve rows, nearest filtering | V, A | |
| WP-806 | `TempogramView(feed:)` | 803a, 526 | Rows follow the feed's `FeedAxis` | V, A | |
| WP-807 | SwiftUI environment bridge (ENV-4); `.dspEngine(_:)` | 320b | Publishes only on a format or topology change | A, V | |
| WP-808a | `FrequencyAxisView` and `TimeAxisView` with `Canvas`; `.axis(_:)` | 807, 812 | Redrawn only on a change of appearance, feed axis or environment | V, A | |
| WP-808b | `PitchClassAxisView` and `TempoAxisView` | 808a | As WP-808a | V, A | |
| WP-809a | Stability suite, level 1 (§8.4) | 803a–808b | Every scenario asserted by counters | V, T | |
| WP-809b | Stability suite, level 2: hosted, in the Examples project | 809a, 810 | Every scenario asserted through real hosting | V, T | |
| WP-810 | Examples project: a mock-driven gallery with a hosted test target (§4.2) | 803a–806, 316 | Builds; every example runs on a mock source | A, T | |
| WP-811 | Hosted activation test (R-25) | 331, 810 | A `Toggle` over `@State` bypasses and restores a stage within one run-loop turn and one block; the session does not cause the owning view's body to be evaluated | A, V | |
| WP-812 | Appearance modifiers in place of style objects: colour map, value range, frequency scale and range, time span, amplitude range, frame-rate cap (VC-4, API-6) | 801 | Each reaches the renderer through the environment; an equal value causes no update; the bound forms read and write their binding | A, V | |
| WP-813 | Animatable appearance (ANI-1) | 812, 803b | An animated change of range or span gives one draw per display frame with interpolated values and no upload | V, A | |
| WP-814 | Source-fed `SpectrogramView(source:)` and `WaveformView(source:)`; `.analysisFrame`, `.processing(_:)` (VC-3, SRC-3) | 803b, 804, 320c, 534, 536 | One view shows a mock, a file and a processed signal; the attachment follows the view's life; re-evaluating the parent attaches nothing new | V, A | |
| WP-815 | Source-fed `ChromagramView(source:)` and `TempogramView(source:)` | 814, 805, 806 | As WP-814 | V, A | |
| WP-816 | `.pipeline(_:on:)` host: attach on appear, update on change, detach on disappear (ANI-3) | 320b, 807 | The life cycle is asserted by a probe; an equal pipeline causes no update | A, V | |
| WP-817 | Animatable pipeline values through both hosts (ANI-2…ANI-5) | 816, 305, 814 | Inside `withAnimation` the session receives one interpolated update per display frame; a topology change is applied at once; the assumption of §8.7 is recorded as confirmed or the fall-back is built | A, V | |
| WP-818 | Spike: what the pinch-related gestures report together on iOS 17.5, 18 and 27 (PINCH-8) | 810 | Findings recorded; the table of PINCH-8 confirmed, or corrected by change request | A, T | |
| WP-819 | Pinch tracker: finger line to axis, scale and centroid, behind one seam (PINCH-3, PINCH-4) | 818 | Scripted touch sequences give the specified axis and scale on each OS path | A, T | |
| WP-820 | `.pinchScaling(_:)` on the heat-map views (PINCH-1, PINCH-2, PINCH-5…PINCH-7) | 819, 812 | A horizontal pinch changes the time span, a vertical one the frequency or tempo range; limits resist and spring back; nothing is uploaded | V, A | |
| WP-821 | `.pinchScaling(_:)` on `WaveformView` | 819, 804 | Horizontal: time span; vertical: amplitude range | V, A | |
| WP-822 | Spike: how a hosted `MTKView` moves through an animated frame change and a rotation (SZ-4) | 801, 810 | Findings recorded; the detection rule of §8.9 confirmed, or corrected by change request | V, A | |
| WP-823 | Size transitions: the drawable follows the presentation size; presentation with the transaction (SZ-1…SZ-5) | 822, 606, 802 | With a scripted transition the drawable size equals the presentation size at every tick, and a final draw is made at the model size | V, R | |
| WP-824 | Size-transition acceptance, hosted (§8.9) | 823, 809b | The acceptance of §8.9 for a frame animation and for a rotation | V, T | |

### M9 — Hardening

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-901a | Facade: umbrella exports; the public API equals §4–§8 by the API digest | all | The digest matches; no unlisted public symbol | A, T | |
| WP-901b | Documentation: landing page; every public symbol documented with its threading contract; the order matrix covers every public stage | 901a | The documentation builds without warnings; the matrix is complete | A, T | |
| WP-902 | Coverage closure: one package per target below its gate (`WP-902a`, `WP-902b`, …) | all | COV-2 holds | T, A | |
| WP-903a | The budgets of §5.7 on the reference devices; baselines committed; a device run | 324 | Budgets met, or a change request per miss | R, T | |
| WP-903b | The budgets of §10.4 on the reference devices; a device run | 541, 809b | As WP-903a | R, V | |
| WP-904a | Floor verification on an iOS 15 device: unit, parity and audit plans (PLAT-3) | all | The plans are green on the device | S, A | |
| WP-904b | Floor verification: rendering, UI and integration plans; the device checks listed in §13.1 | 904a | The plans are green; each device check is recorded | S, V | |
| WP-905a…d | Audit of the algorithm and stability registers, six rows to a package (§7.3, §7.5) | all | Every row carries a dated currency check, its stability note and its stress test | N, A | |
| WP-906 | Release 0.1.0 checklist | all | Every gate of §10.3 green | A, T | |
| WP-907 | External parity suite: a package outside this one re-implements `Gain`, an IIR low-pass on its own C kernel, and a mel projection node, on the public API only (EXT-4) | 339, 437, 432a, 535 | Output equal to the stock twins; speed within 5 %; allocation audit passes; order fixtures and a bound switch work | A, R | |
| WP-908 | Extension guide: one compiled example for each row of §5.11.1 | 907 | Every example builds outside the package and runs in a test | A, T | |
| WP-909 | Audit of the public API against API-6 and IMM-1…IMM-5 | 901a | No configuration object; the registers match the code | A, T | |
| WP-910 | Export completeness: every type of §6.14 exports; all golden scripts run under Octave | 440, 501g, 540, 614 | Complete and green | T, N | |

---

## 13. Risks, decisions, deferred work

### 13.1 Risks

| Risk | Mitigation |
|---|---|
| **Draft 3 has not been cross-checked or reviewed.** It changes most sections of a draft that had been. | Before work starts: re-run the mechanical cross-check of identifiers, dependencies and references, and one review round. Both were skipped for this draft at the owner's request. |
| The Swift performance attributes are underscored and may change or disappear. | They sit behind a build setting and are a secondary check only; the run-time allocation audit is the primary guard (RT-7). |
| `malloc_logger` is not public API. | It is used only in the test product. The probe has a control case, so a hook that stops firing fails the suite loudly instead of passing silently. Fall-back: an Instruments allocation trace in the device-lab plan. |
| vDSP's internal behaviour (E-07, E-09) may differ between OS versions and devices. | The allocation audit runs on every OS in the run-time matrix. Transform lengths are decided by arithmetic, never by calling a setup function. |
| The legacy CLAPACK interface may be removed from a future SDK. | LA-1 confines it to one file group; the switch is local once the floor reaches 16.4. |
| iOS 15 and 16 cannot be simulated on the current host (E-17), so floor defects may surface late. | A device run of the walking skeleton after M3 (WP-338), and the full device runs of WP-904a and WP-904b. |
| Constant-Q conventions differ between implementations, so bit parity with a reference is not attainable. | Acceptance in §6.8 is by defined properties and a similarity threshold. |
| Metal shader compilation in a Swift package (DEP-4) is an assumption. | WP-601 confirms it first in M6. Fall-back: a pre-compiled library shipped as a resource. |
| Three UI mechanisms rest on assumptions about SwiftUI: the pinch paths for iOS 15–17 (PINCH-8), the detection of a size transition (SZ-4), and animation over a vector of run-time length (§8.7). | Each has a spike or a confirming package that runs before anything is built on it (WP-818, WP-822, WP-817), and each has a stated fall-back. With one pinch axis enabled no inference is needed at all. |
| A switch written off the main thread is seen only when the main run loop next turns (BIND-3). | `syncBindings()`; the documentation of `isActive:` says so. |
| The core target names a SwiftUI symbol. | One name, through a scoped import that keeps the rest of SwiftUI out of scope (E-28), enforced by lint (BIND-7). |
| A bound activation prevents fusion around its stage (ACT-6). | Constants are free; a `Group(isActive:)` fuses inside; the documentation of `isActive:` states the cost. |
| A shipped crossover may be wrong for a processor that did not exist when it was measured. | A wrong crossover costs speed, never correctness (SEL-6). `Calibration.measure()` corrects it on the device. |
| The 5 % bound of the external parity suite may be missed where call overhead dominates a tiny kernel. | The toolkit is inlinable (VIS-1); the bound is measured on 512-frame blocks. |
| The Float32 accuracy figures of E-30 come from probes that were not kept. | WP-208, WP-433 and WP-502 re-measure them; the rules built on them (REAL-3, F1) decide by measurement or do not depend on the exact figure. |
| Some packages may still not fit 30 minutes (candidates: WP-306c, WP-314b, WP-319a, WP-331, WP-501e, WP-817, WP-823). | The split protocol of §11.7. |
| 97.5 % coverage with hardware-facing code. | Humble objects behind seams (COV-5); device-lab coverage merged before the gate. |
| `vm_remap` may be refused on some OS versions. | The copy-on-wrap fall-back is mandatory and tested (WP-203). |
| Changing the session category while audio is playing can stop the host's player (case B of §4.6). | CAP-3 avoids the change whenever input is already permitted; the documentation tells hosts to configure the category before starting playback; WP-708 tests both cases. |
| The budgets of §5.7 and §10.4 are unmeasured. | They are marked provisional; WP-324, WP-903a and WP-903b measure them, and a miss is a change request. |
| The purpose-written order messages (ORD-4) depend on how the compiler ranks an unavailable overload. | Fixtures assert the sentences on every toolchain change. A regression degrades messages, never rejection, and the fluent spelling does not depend on it. |
| The compile-time rules and the attach-time rules could drift apart. | The generated matrix of ORD-2 fails the build when they disagree. |

Device checks carried by WP-904b, because the simulator cannot answer them: what the DCT and DFT setup functions do for undocumented lengths on a device (E-09); linear filtering of half-float textures on the floor device's GPU; `vm_remap` mirroring; the allocation audit of E-07; whether the time-constraint policy of RT-9 is granted; case B of §4.6 on speaker, wired and Bluetooth routes.

### 13.2 Decisions taken, for the owner to confirm

| ID | Decision taken | If you prefer otherwise |
|---|---|---|
| OD-1 | A new standalone package that does not depend on ZTronSpectrogram. | Reusing its `Math` layer would shorten WP-401 and WP-402 but couple ZTronDSP to work in progress. |
| OD-2 | The UIKit ban is a boundary rule with one `MTKView` bridge file (IN-3). | A stricter ban leaves no way to host a Metal drawable in SwiftUI on iOS 15. The visual components would then need either an iOS 17 floor (SwiftUI shader effects) or CPU drawing with `Canvas`. |
| OD-3 | Tests may import UIKit to host a view under test (UB-6). | Without it only level 1 of the stability suite, and none of the hosted tests of §8.7–8.9, can run. |
| OD-4 | Playing the processed signal is deferred (D-1). | It adds roughly eight packages: a monitor sink on `AVAudioSourceNode`, or an in-process audio unit that runs `ztd_plan_run` on the I/O thread. Only chains of sequence stages could run there. |
| OD-5 | Shelving filters and MFCC are included as low-cost siblings of what was asked for. | Remove the shelves from WP-420, WP-431b and WP-432b, and drop WP-512; nothing else changes. |
| OD-6 | No third-party dependencies. Python with SciPy and librosa, and GNU Octave, are used only at development time: to generate golden vectors and to run the exported scripts. | — |
| OD-7 | The analysis thread wakes by polling, so the I/O thread makes no system call. | A semaphore wake removes up to one poll interval of latency, at the price of a Mach call per I/O cycle. |
| OD-8 | The reference devices of §10.4 are left for the owner to name. | — |
| OD-9 | Order is enforced with protocols and generic value types, not a class hierarchy (IN-12). | A hierarchy can separate time-domain stages from spectral ones but cannot express rules such as O-4 and O-5. |
| OD-10 | Decided by the owner: the activation switch is a SwiftUI `Binding`. | Consequences, for the record: the core target names one SwiftUI symbol; bound switches are sampled on the main run loop; a switch written off the main thread is seen at the loop's next turn; two stages cannot share one run-time switch by sharing a binding, they share it through `Group(isActive:)`. |
| OD-11 | Switching off a stage that changes the domain suspends the rest of its branch (ACT-3). | The types can instead refuse `isActive:` on such stages, so that only `Tap(isActive:)` can stop a branch. |
| OD-12 | ZTronScrollView is not a dependency (E-29). Pinch scaling is built in `ZTronDSPUI`. | If its per-touch observer were made public, the pinch axis on iOS 15–16 would be read from both fingers instead of inferred from one. The price is a dependency that brings UIKit and Combine along, inside that package, and an exception to DEP-3. |
| OD-13 | A live value changes by handing the session a new pipeline, or by letting a view host the pipeline. There is no package type for a live value and no binding for one. | A `Binding<Frequency>` on each value would let a pipeline owned by a model follow a slider without `update(_:)`. It adds a second kind of binding to the pump and makes every bound value a fusion barrier. |
| OD-14 | A view that takes a source keeps its attachment on `DSPEngine.shared` unless `.dspEngine(_:)` says otherwise. | Requiring an explicit engine removes the shared instance and puts `.dspEngine(_:)` on every hierarchy. |
| OD-15 | Results reach bindings 30 times a second by default (`resultRate`). | A higher default costs main-thread wake-ups for every app; the key changes it per pipeline. |
| OD-16 | A gain is never folded into a filter (F1). | Folding saves one `vDSP_vsmul` per block and costs up to 15 dB of accuracy in single precision (E-30), and a folded gain cannot ramp. |
| OD-17 | A pinch changes what is shown, never what is computed (PINCH-2). | Re-analysing with a shorter hop on a horizontal pinch would add real time resolution when zoomed in, at the price of a plan change per gesture. |
| OD-18 | The MATLAB export is script text. | A binary `.mat` file carries large matrices better, but it is not MATLAB language and cannot carry the plot commands. |

### 13.3 Deferred

| ID | Item | Why it can wait |
|---|---|---|
| D-1 | Rendering the processed signal to the output (monitoring, in-graph effect) | Not requested. The plan runner and the stock kernels of the sequence stages are C and `nonblocking`, so a chain of them could move to the I/O thread without redesign. A chain with analysis steps on its main line (`HPSS`) could not: it would stay on the analysis thread and reach the output through a ring, with latency. |
| D-2 | Parallel and mixing topologies; `Parallel { }` in system builders | The request describes a chain. |
| D-3 | Equiripple FIR design (Parks–McClellan) | Windowed-sinc and least-squares cover the stated needs. |
| D-4 | An O(n²) root finder for polynomials above degree 512 | Audio filter orders are far below the cap. |
| D-5 | Non-uniformly partitioned convolution | Only pays for very long kernels at very small blocks. |
| D-6 | Invertible constant-Q, cyclic tempogram, tuning estimation, beat tracking, phase reconstruction from magnitudes | Beyond the requested features. |
| D-7 | A tap source for `AVPlayer` (`MTAudioProcessingTap`) | `EngineNodeTapSource` covers engine-based playback. |
| D-8 | Pole–zero and frequency-response plot views | Analysis results are plain data, and they export as MATLAB scripts (§6.14). |
| D-9 | A recording sink | Not requested. |
| D-10 | Mel bands back to linear bins | Lossy; not requested. |
| D-11 | Filtering each band of a spectrum along time (RASTA, CENS smoothing) | A restriction of v1 (O-1), not a law of signal processing. |
| D-12 | A Combine publisher over `FeatureStream` | Needs the owner's approval (APR-2). `AsyncSequence` covers the need. |
| D-13 | Arbitrary-ratio resampling inside a pipeline | Integer factors and their cascade cover the stated needs (§6.12). |
| D-14 | Bindings for live values | See OD-13. |

---

## Appendix A — etk4j parity matrix

Source: `com.wildbitsfoundry.etk4j.signal` (`filters`, `smoothing`, `stoz`, `fft`) and the two `control` types the filters return. WP-435 holds one test per row; the last row is held by WP-502.

| etk4j | ZTronDSP | Oracle |
|---|---|---|
| `ButterWorth.buttAp(n)` | `AnalogPrototype.butterworth(order:)` | `scipy.signal.buttap` |
| `Chebyshev1.cheb1Ap(n, rp)` | `AnalogPrototype.chebyshev1(order:ripple:)` | `cheb1ap` |
| `Chebyshev2.cheb2Ap(n, rs)` | `AnalogPrototype.chebyshev2(order:stopband:)` | `cheb2ap` |
| `Elliptic.ellipAp(n, rp, rs)` | `AnalogPrototype.elliptic(order:ripple:stopband:)` | `ellipap` |
| `Bessel.besselAp(n)` and the phase-, delay- and magnitude-normalised variants | `AnalogPrototype.bessel(order:normalization:)` | `besselap(norm=…)` |
| `newLowPass`, `newHighPass`, `newBandpass`, `newBandStop` and their `…ZPK` forms, on `ButterWorth`, `Chebyshev1`, `Chebyshev2`, `Elliptic`, `Bessel` | `IIRDesign(family, response, order:, domain: .analog)`, read as `.transferFunction` or `.zeroPoleGain`; `domain: .digital` for the real-time path | `iirfilter(…, analog=True)` and `analog=False` |
| `buttOrd`, `cheb1Ord`, `cheb2Ord`, `ellipOrd` on `LowPassSpecs`, `HighPassSpecs`, `BandpassSpecs`, `BandStopSpecs` | The `passband:stopband:maximumLoss:minimumAttenuation:` initialisers of the response stages, through the family's `FilterOrderStrategy`. The specification objects become arguments (API-6). | `buttord`, `cheb1ord`, `cheb2ord`, `ellipord` |
| `Filters.lpToLp`, `lpToHp`, `lpToBp`, `lpToBs`, coefficient and ZPK forms | `FrequencyTransformation` on `ZeroPoleGain`; coefficient form by conversion | `lp2lp_zpk`, `lp2hp_zpk`, `lp2bp_zpk`, `lp2bs_zpk` |
| `BilinearTransform.transform(num, den, fs)` | `ZeroPoleGain.bilinear(sampleRate:)`, `TransferFunction.bilinear(sampleRate:)` | `bilinear_zpk`, `bilinear` |
| `SavitzkyGolayFilter` and its `Mode` | `SavitzkyGolay(edge:)`: `.interpolate`, `.mirror`, `.nearest`, `.constant`, `.wrap` | `savgol_coeffs`, `savgol_filter` |
| `AlphaBetaFilter` | `AlphaBeta` | The defining recurrence |
| `ZeroPoleGain`, `TransferFunction`: poles, zeros, evaluation, magnitude, phase | The same-named types and `LTISystem` analysis (§6.3.8) | `freqs`, `freqz`, `sosfreqz`, `group_delay` |
| `signal.fft.FFT` | `FFTBackend` | Naive DFT |

Not carried over, being outside the request: `control.StateSpace`, time-response simulation, stability margins, and etk4j's general mathematics packages.

## Appendix B — References

- R. Bristow-Johnson, *Cookbook formulae for audio EQ biquad filter coefficients* (Audio EQ Cookbook).
- S. J. Orfanidis, "High-Order Digital Parametric Equalizer Design", *J. Audio Eng. Soc.* 53(11), 2005.
- S. J. Orfanidis, *Lecture Notes on Elliptic Filter Design*, 2006.
- M. Vicanek, *Matched Second Order Digital Filters*, 2016.
- T. W. Parks and C. S. Burrus, *Digital Filter Design*, Wiley, 1987.
- A. V. Oppenheim and R. W. Schafer, *Discrete-Time Signal Processing*.
- R. E. Crochiere and L. R. Rabiner, *Multirate Digital Signal Processing*, Prentice-Hall, 1983.
- C. E. Shannon, "Communication in the presence of noise", *Proc. IRE* 37(1), 1949.
- F. J. Harris, "On the use of windows for harmonic analysis with the discrete Fourier transform", *Proc. IEEE* 66(1), 1978.
- D. W. Griffin and J. S. Lim, "Signal estimation from modified short-time Fourier transform", *IEEE Trans. Acoust., Speech, Signal Process.* 32(2), 1984.
- S. S. Stevens, J. Volkmann and E. B. Newman, "A scale for the measurement of the psychological magnitude pitch", *J. Acoust. Soc. Am.* 8(3), 1937.
- M. Slaney, *Auditory Toolbox*, Interval Research Corporation, Technical Report 1998-010, 1998.
- J. F. Kaiser, "Nonrecursive digital filter design using the I₀-sinh window function", ISCAS 1974.
- A. Savitzky and M. J. E. Golay, "Smoothing and differentiation of data by simplified least squares procedures", *Anal. Chem.* 36(8), 1964.
- J. C. Brown and M. S. Puckette, "An efficient algorithm for the calculation of a constant Q transform", *J. Acoust. Soc. Am.* 92(5), 1992.
- C. Schörkhuber and A. Klapuri, "Constant-Q transform toolbox for music processing", SMC 2010.
- N. Holighaus, M. Dörfler, G. A. Velasco and T. Grill, "A framework for invertible, real-time constant-Q transforms", *IEEE Trans. Audio, Speech, Lang. Process.* 21(4), 2013.
- D. Fitzgerald, "Harmonic/percussive separation using median filtering", DAFx-10, 2010.
- J. Driedger, M. Müller and S. Disch, "Extending harmonic-percussive separation of audio signals", ISMIR 2014.
- S. Böck and G. Widmer, "Maximum filter vibrato suppression for onset detection", DAFx-13, 2013.
- P. Grosche, M. Müller and F. Kurth, "Cyclic tempogram — a mid-level tempo representation for music signals", ICASSP 2010.
- P. Grosche and M. Müller, "Extracting predominant local pulse information from music recordings", *IEEE Trans. Audio, Speech, Lang. Process.* 19(6), 2011.
- W. G. Gardner, "Efficient convolution without input-output delay", *J. Audio Eng. Soc.* 43(3), 1995.
- F. Wefers, *Partitioned Convolution Algorithms for Real-Time Auralization*, PhD thesis, RWTH Aachen, 2015.
- J. L. Aurentz, T. Mach, R. Vandebril and D. S. Watkins, "Fast and backward stable computation of roots of polynomials", *SIAM J. Matrix Anal. Appl.* 36(3), 2015.
- K. E. Batcher, "Sorting networks and their applications", AFIPS Spring Joint Computer Conference, 1968.
- J. Suomela, "Median filtering is equivalent to sorting", arXiv, 2014.
- Reference implementations: etk4j (MIT), SciPy, librosa.
- Apple SDK headers quoted in §3: `vDSP.h`, `clapack.h`, `lapack.h`, `Sparse/Solve.h`, `MTKView.h`, `AVAudioSinkNode.h`, `AVAudioSourceNode.h`, `AVAudioIONode.h`, `AVAudioNode.h`, `AVAudioEngine.h`, `AVAudioApplication.h`, `AVAudioSessionTypes.h`, `CoreAudioBaseTypes.h`, `MPSGraphFourierTransformOps.h`, and the Swift interfaces of Accelerate and SwiftUI (iOS 27.0 SDK).
