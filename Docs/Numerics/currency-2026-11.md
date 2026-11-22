# Currency check of the algorithm register, November 2026 (§7.3, WP-905)

The stability notes of the `ALG` packages were written without network access: each confirms the registered source from the specification and says that no literature search was possible. This record adds the search, row by row of §7.2, made on 2026-11-15 by web search (a few minutes a row, as §7.3 asks; search results and abstracts were read, not the papers). Where something newer or better was found it is named here and raised in `Docs/Process/changes/CR-020.md`. Nothing was adopted.

| # | Operation | Searched | Found | Outcome |
|---|---|---|---|---|
| 1 | Real FFT | Accelerate release notes and API changes for iOS 26 and 27 | No release note about the vDSP DFT routines turned up; Apple's pages still document `vDSP_DFT_zrop` and the automatic switch to an FFT for the lengths it supports | Not confirmed either way by search; the routines are in the SDK the package builds with. Current |
| 2 | Framing | Mirrored ("double-mapped") ring buffers and their drawbacks | The technique is in common use; what is held against it is the portability of the mapping and twice the address space, and the alternative is the copy on wrap that the register names and the package falls back to | Current |
| 3 | IIR filtering | Stability of recursive filters whose coefficients move | Laroche 2007 (AES): a filter can be unstable in transition between two stable settings. Trapezoidal state-variable structures (Zavalishin; Simper) are the usual answer for fast modulation | Current for fixed and slowly changing coefficients. An alternative to register for animated cutoffs: CR-020 item 4 |
| 4 | IIR design | Alternatives to the pre-warped bilinear transform near Nyquist | The matched-Z transform (the registered alternative) and impulse invariance, each with aliasing; a 2025 paper proposes a third-order mapping between the bilinear and Schneider transforms. Nothing that replaces the pre-warped bilinear transform in general use turned up | Current |
| 5 | FIR design | The state of FIR design | Windowing (with Kaiser's estimates), least squares and equiripple remain the three methods in use; equiripple is deferred (D-3) | Current |
| 6 | Savitzky–Golay | Replacements of the Savitzky–Golay smoother | Schmid, Rath & Diebold 2022 (ACS Meas. Sci. Au 2, 185–196; correction 2023): the kernel has strong components above its cut-off, which costs noise suppression, above all for derivatives, and it misbehaves at the edges; they propose a modified-sinc kernel, and Savitzky–Golay with fitting weights | The method is kept: it is the one G-3 asks for. A better smoother exists and is raised: CR-020 item 1 |
| 7 | FIR, short | `vDSP_conv` and `vDSP_desamp` against alternatives | Apple documents and recommends both for direct filtering; for long filters the alternative is the frequency domain, which is row 8. No comparison with a hand-written loop for short filters turned up: the package measures that itself (§7.4) | Current |
| 8 | FIR, long | Partitioned convolution after Wefers | Non-uniform partitioning stays the alternative for long responses at low latency (Wefers & Vorländer, DAFx 2011; Stefani, Binelli, Farina & Turchet, JAES 2025, up to 3.7 times) | Current: with the partition equal to the block the uniform scheme adds no latency, which is what REAL-4 wants. The registered alternative stands |
| 9 | Rate changes | Efficient decimation and interpolation | A 2020 survey (Zeineddine et al.) lists the structures in use: filter and resample, polyphase, Farrow, CIC, Newton; half-band stages in cascade are the usual economy for powers of two, which is the registered alternative | Current |
| 10 | One-shot convolution, correlation | — | Classical | Current |
| 11 | Autocorrelation | — | Classical | Current |
| 12 | Polynomial roots | Fast, backward-stable companion methods | Aurentz, Mach, Vandebril & Watkins 2015, and with Robol 2018: the registered alternative, with a sharper error analysis since. Nothing newer turned up | Current: the degree cap keeps O(n³) small |
| 13 | Constant-Q | Real-time constant-Q transforms | The sliding constant-Q transform (Bradford, ffitch & Dobson, DAFx 2008; open implementations exist) updates every bin at every sample; the non-stationary Gabor transform (Holighaus et al. 2013) is the registered alternative. No newer multirate method turned up | Current. One more alternative to register for the lowest latency: CR-020 item 3 |
| 14 | Onset envelope | Spectral-flux onset functions since SuperFlux | SuperFlux (Böck & Widmer 2013) is still what recent work measures itself against; a 2024 preprint (chirp group delay, Joysingh et al.) reports parity with it at lower cost on instruments with a fast attack | Current. The preprint is a candidate to watch: CR-020 item 5 |
| 15 | Tempogram | Tempograms since Grosche & Müller | The Fourier, autocorrelation and cyclic tempograms of 2009–2011 remain the references that toolboxes implement; nothing that replaces them turned up | Current |
| 16 | Median filtering | Vectorised and network-based median filters | Adams 2021 (SIGGRAPH): separable sorting networks for two-dimensional medians of any size, more than ten times faster than earlier work, and patented (US 11,756,175). A 2025 preprint describes a data-oblivious selection network that runs in registers (abstract only). For harmonic–percussive separation, median filtering (Fitzgerald 2010; Driedger et al. 2014) is still what the libraries do; kernel additive modelling (FitzGerald et al. 2014) is an iterative refinement | Current: the package's medians run along one axis at a time. The two-dimensional method is noted with its patent, not registered: CR-020 item 2 |
| 17 | Spectral centroid | — | A definition | Current |
| 18 | Mel conversion | — | A definition, in two published formulas | Current |
| 19 | Cepstrum | Phase unwrapping for the complex cepstrum | Adaptive unwrapping (Tribolet 1977) is the usual baseline and can fail on hard cases; the cepstrum can also be had from the roots of the frame's polynomial, without unwrapping, exactly and at a much higher cost (Steiglitz & Dickinson 1982; Herrera & van der Baan 2011) | Current for real time. An alternative to register for the complex cepstrum offline: CR-020 item 7 |
| 20 | Band-boost | Matched and high-order equaliser designs | Orfanidis 2005 (high-order band-shelving) and Vicanek 2016 (matched second-order sections) are the two the register names; Vicanek published a matched second-order Butterworth shelving design in 2024 | Current. The 2024 shelving design is a candidate alternative for the shelves: CR-020 item 6 |
| 21 | Window analysis | — | The package's own procedure | Current |
| 22 | Inversion analysis | — | The package's own procedure, on classical results | Current |
| 23 | Heat-map rendering | — | The package's own design | Current |
| 24 | Implementation selection | — | The package's own design | Current |

## Supplement of 2026-11-18: the methods that rows 3 and 4 did not name

The verification of WP-404 … WP-411 and WP-418a/b (first lens, finding A-NB8) found that the searches of rows 3 and 4 do not cover the methods their stability notes cite them for: row 4 searched alternatives to the bilinear transform, not the prototypes; row 3 searched moving coefficients, not the pairing of sections. The searches below were made on 2026-11-18 by web search, in the same way (results and abstracts read, not the papers).

| # | Operation | Searched | Found | Outcome |
|---|---|---|---|---|
| 3a | Section pairing and ordering (WP-404) | Pole–zero pairing and ordering of cascaded second-order sections | The rule in use is still the one the register's sources give: begin with the pole nearest the unit circle, pair it with the nearest zero, order by that distance (MATLAB `zp2sos`, SciPy `zpk2sos` with `'nearest'`). What the literature optimises beyond it is fixed-point round-off noise, by dynamic programming and heuristic search over the (N!)² pairings and orders (Higgins & Munson 1984; later heuristic optimisations); nothing from 2020 on turned up | Current: the package designs in double precision and runs the sections in floating point, where the nearest pairing is what the reference libraries do |
| 4a | Analog prototypes: Butterworth, Chebyshev I and II (WP-405 … WP-407) | — | Closed forms | Current |
| 4b | Elliptic functions and the elliptic prototype (WP-408, WP-409) | Evaluation of Jacobian elliptic functions for filter design | Landen's transformation remains the method (Orchard & Willson 1997; Orfanidis's notes of 2006, the registered source; Ochs & Vollmer 2000 tie Darlington's algorithm to the same transformation); series in the nome (theta functions) are the other route seen in implementations. Nothing from 2020 on turned up | Current |
| 4c | Bessel polynomial roots (WP-410, WP-411) | Zeros of Bessel polynomials | Campos & Calderón 2011 (closed-form approximations from the electrostatic interpretation: the registered starting values). Newer: Dunster, Gil, Ruiz-Antolín & Segura, an algorithm for the reverse generalized Bessel polynomials and their zeros with a high-order fixed-point method (Comput. Math. Methods 2021), and uniform asymptotic expansions valid for all the zeros, accurate for moderate and large degree, as starting values (ETNA 65, 2026, pp. 140–155) | Current for the orders the package's row asks for (the residual is 7.8·10⁻¹⁸ up to order 25 against 10⁻¹² asked). The 2021/2026 method is a candidate for high orders, where the coefficients of the polynomial leave double precision: raised as CR-020 item 8 |

## What this record is not

It is not a reading of the papers: titles, abstracts and summaries of search results were read. A row marked "—" (10, 11, 17, 18, 21 to 24) was not searched, because what it registers is a definition, a standard routine with nothing to choose between, or the package's own design. The Accelerate and Metal release notes for iOS 26 and 27 were looked for and not found by search; that the routines the package calls exist and behave is shown by its tests on the iOS 27 SDK.

## Sources

- Schmid, Rath & Diebold, "Why and How Savitzky–Golay Filters Should Be Replaced": https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9026279/ (correction: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10288600/)
- Bradford, ffitch & Dobson, "Sliding with a constant Q" (DAFx 2008): https://dafx.de/paper-archive/details/QMFQa1rIAM7mwu9tMIZAlg
- Adams, "Fast median filters using separable sorting networks" (SIGGRAPH 2021): https://history.siggraph.org/?p=121185 ; patent: https://patents.google.com/patent/US11756175
- Wefers & Vorländer, optimal filter partitions (DAFx 2011): https://www.dafx.de/paper-archive/2011/Papers/74_e.pdf
- Stefani, Binelli, Farina & Turchet, non-uniformly partitioned convolution for dynamic auralisation: https://angelofarina.it/Public/Papers/Improved_Real-Time_Six-Degrees-of-Freedom_Dynamic_Auralization_Through_Nonuniformly_Partitioned_Convolution__doc.pdf
- Fitzgerald, "Harmonic/Percussive Separation using Median Filtering" (DAFx 2010): https://dafx.de/paper-archive/details/DsmIVcydPX66AuaqEmKyTQ
- Böck & Widmer, "Maximum Filter Vibrato Suppression for Onset Detection" (DAFx 2013): https://dafx.de/paper-archive/details/0oee-99Z88WL7pSo749gcA
- Joysingh et al., "Chirp Group Delay based Onset Detection in Instruments with Fast Attack" (preprint, 2024): https://arxiv.org/abs/2408.13734
- Vicanek, matched second-order sections: https://www.vicanek.de/articles/BiquadFits.pdf ; matched shelving (2024): https://www.vicanek.de/articles/2poleShelvingFits.pdf
- Grosche, Müller & Kurth, cyclic tempogram (ICASSP 2010): https://www.audiolabs-erlangen.com/content/05_fau/professor/00_mueller/03_publications/2010_GroscheMuellerKurth_TempogramCyclic_ICASSP.pdf
- Aurentz, Mach, Robol, Vandebril & Watkins, fast and backward stable computation of roots of polynomials, part II: https://arxiv.org/abs/1611.02435
- Zeineddine et al., "Comprehensive Survey of FIR-Based Sample Rate Conversion" (2020): https://www.academia.edu/115672556/Comprehensive_Survey_of_FIR_Based_Sample_Rate_Conversion
- A third-order s-to-z mapping between the bilinear and Schneider transforms (J. Electrical Engineering, 2025): https://reference-global.com/download/article/10.2478/jee-2025-0018.pdf
- Herrera & van der Baan, homomorphic wavelet estimation and phase unwrapping revisited: https://arxiv.org/pdf/1205.3752
- Tribolet, "A New Phase Unwrapping Algorithm" (1977), as cited in: https://www.cs.princeton.edu/~ken/Complex_Cepstrum_77.pdf
- Apple, `vDSP_conv`: https://developer.apple.com/documentation/accelerate/vdsp_conv.md
- A discussion of mirrored ring buffers and their cost: https://www.github.com/mackron/miniaudio/issues/671
- Dunster, Gil, Ruiz-Antolín & Segura, "Uniform asymptotic approximation and numerical evaluation of the reverse generalized Bessel polynomial zeros" (ETNA 65, 2026): https://etna.ricam.oeaw.ac.at/vol.65.2026/pp140-155.dir/pp140-155.pdf ; preprint: https://arxiv.org/abs/2510.14295 ; "Computation of the reverse generalized Bessel polynomials and their zeros" (2021), DOI 10.1002/cmm4.1198
- Orfanidis, "Lecture Notes on Elliptic Filter Design" (2006), course page: https://www.ece.rutgers.edu/~orfanidi/ece521/
- SciPy, `zpk2sos` (the `'nearest'` pairing): https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.zpk2sos.html ; MATLAB, `tf2sos`: https://ch.mathworks.com/help/signal/ref/tf2sos.html
- Higgins & Munson, "Optimal and suboptimal error spectrum shaping for cascade-form digital filters" (1984): https://pure.psu.edu/en/publications/optimal-and-suboptimal-error-spectrum-shaping-for-cascade-form-di/
- Apple, discrete Fourier transforms in vDSP: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/USingDFTFunctions/USingDFTFunctions.html

## Second pass of 2026-11-21 (register audit, WP-905a … WP-905d)

The register audit (`register-audit-2026-11.md`) searched every row again on 2026-11-21, between 20:45 and 22:35 (Europe/Rome), by web search, in the same way as the first pass: results, abstracts and summaries were read, not the papers. This time the rows marked "—" above were searched too. The first pass stands as it was written; what the second pass adds is in the last column, and a better method found is raised in `Docs/Process/changes/CR-020.md`, not adopted.

| # | Operation | Searched | Found | Outcome |
|---|---|---|---|---|
| 1 | Real FFT | Apple's iOS & iPadOS 27 release notes and security content for Accelerate; real-data FFT accuracy in ACM TOMS and arXiv, 2025–2026; MPSGraph FFT | The iOS 27 notes have no Accelerate or vDSP section; the security content of iOS 27 lists two Accelerate entries, out-of-bounds writes when processing crafted images, fixed by bounds checking, and nothing on the DFT. Kawakami & Takahashi (arXiv 2603.29129, 2026) compute FFTs at a target precision from lower-precision transforms, more accurate than FFTW in double precision and 107 to 1 315 times slower; nothing new on MPSGraph's FFT since WWDC 2024 | Current |
| 2 | Framing | Double-mapped (mirrored) ring buffers, 2025 | Libraries still map a buffer twice (Rust crates of 2025–2026 among them); the cost held against it is the same as in the first pass | Current |
| 3 | IIR filtering | Biquad round-off at low cut-offs, DAFx 2025–2026 | A DAFx 2026 paper and its write-up address the cramping of equaliser responses near Nyquist (a design matter, row 4); nothing new on the round-off of the registered structure | Current; CR-020 item 4 stands |
| 4 | IIR design | New s-to-z mappings (2025–2026); elliptic functions | The 2025 interpolation-based third-order mapping of the first pass, the matched-Z transform and phase-invariant mappings; nothing newer. Landen's transformation is still the method for elliptic functions | Current |
| 5 | FIR design | Windowed, least-squares and Kaiser-estimate design, 2025–2026 | Tutorials and tool documentation of the three methods in use; nothing that replaces them | Current |
| 6 | Savitzky–Golay | Replacements, 2025–2026 | The modified-sinc smoother of Schmid, Rath & Diebold (2022) and its implementations (OpenMS); nothing newer | Current; CR-020 item 1 stands |
| 7 | FIR, short | Read with row 1 | No change to `vDSP_conv` or `vDSP_desamp` in the iOS 27 notes | Current |
| 8 | FIR, long | Non-uniform partitioned convolution, DAFx and JAES, 2025–2026 | AES papers on uniform and non-uniform partitioning, the 2025 JAES paper of the first pass among them, and a 2025 preprint that runs uniform partitioning on the GPU; non-uniform partitioning is still the alternative for long responses | Current |
| 9 | Rate changes | Polyphase and half-band resampling, 2025 | Libraries of cascaded half-band stages and polyphase resamplers; no new method | Current |
| 10 | One-shot convolution, correlation | Searched with row 1 | A 2025 preprint (ACM TOMS format) on FFT convolution without index-reversal permutations: a library-level optimisation of the same method | Current |
| 11 | Autocorrelation | Searched with row 10 | Wiener–Khinchin with zero-padding is the method in use | Current |
| 12 | Polynomial roots | Fast backward-stable companion QR, 2025 | Aurentz, Mach, Robol, Vandebril & Watkins (2018), the registered alternative; nothing newer | Current |
| 13 | Constant-Q | Real-time and invertible constant-Q transforms, 2025–2026 | An exact factorisation of the invertible constant-Q transform (Franchino, Moliner & Välimäki, arXiv 2609.29119, 2026) that computes the registered alternative faster; a real-time invertible engine on non-stationary Gabor frames (CiCueTea, 2026) and a 2025 generative model use the registered alternative as it is | Current. The factorisation is raised as CR-020 item 9 |
| 14 | Onset envelope | Spectral-flux onset functions, 2025–2026 | SuperFlux is still the comparison; the 2024 chirp-group-delay preprint of the first pass | Current; CR-020 item 5 stands |
| 15 | Tempogram | Tempograms, 2025–2026 | A differentiable predominant local pulse (Chiu, Schreiber & Müller, ISMIR 2025) built on the Fourier tempogram | Current |
| 16 | Median filtering | Sorting-network medians and medians for separation, 2025–2026 | Adams 2021 (CR-020 item 2) and a 2025 preprint of a register-resident selection network; Fitzgerald's median filters still in the separation libraries | Current |
| 17 | Spectral centroid | The centroid of frames with little energy, 2025–2026 | Patents and a 2026 preprint that leave out or flag frames without energy; nothing that changes the definition | Current |
| 18 | Mel conversion | Mel filter banks: Slaney and HTK, 2025–2026 | Libraries (Rust crates, NVIDIA DALI) offer the same two conventions and normalisations | Current |
| 19 | Cepstrum | Phase unwrapping for the complex cepstrum, 2025–2026 | Nothing from 2025–2026; discontinuity detection and adaptive integration are still the methods in use, with the root-based and differential cepstra as the ways around unwrapping | Current; CR-020 item 7 stands |
| 20 | Band-boost | Peaking and high-order equaliser design, DAFx and JAES, 2025–2026 | Schlecht, Sinjanakhom & Välimäki, "Multi-shelf graphic equalizer" (Signal Processing, 2025): cascaded shelves for graphic equalisers, not a band-boost design; Orfanidis 2005 is still the reference the tools follow (MATLAB `designParamEQ`) | Current |
| 21 | Window analysis | Side-lobe fall-off, scalloping loss and window figures, 2025–2026 | Yamaoka & Oshima (IEEE Access, 2025): side lobes reduced by multiplying cosine-sum windows, a design method; Prabhu's book (2014) for the figures; nothing on computing them | Current |
| 22 | Inversion analysis | STFT invertibility, frame bounds, NOLA and COLA, 2025–2026 | A 2026 preprint on an STFT with data-adaptive windows, which restores reconstruction by normalising its envelope; nothing that sharpens NOLA or the frame bounds | Current |
| 23 | Heat-map rendering | Real-time spectrograms on the GPU, 2025–2026 | Open projects keep a ring of columns, upload only the new ones and colour in the shader, which is the registered design; nothing on half-float textures | Current |
| 24 | Implementation selection | Measured choice between implementations, 2025–2026 | SciPy's `choose_conv_method` (a prediction, or timing with `measure=True`) and the autotuners of FFT libraries (time the candidates after a warm-up, keep the result): the registered approach | Current |

### Sources of the second pass

- Apple, iOS & iPadOS 27 release notes: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes ; security content of iOS 27: https://support.apple.com/149034
- A target-precision FFT (arXiv, 2026): https://arxiv.org/abs/2603.29129 ; FFT convolution without permutations (arXiv, 2025): https://arxiv.org/abs/2506.12718
- MPSGraph FFT (WWDC 2024): https://developer.apple.com/videos/play/wwdc2024/10218/
- Double-mapped ring buffers in current libraries: https://docs.rs/crate/oneringbuf/latest
- Equaliser cramping (DAFx 2026): https://www.dafx.de/paper-archive/2026/papers/DAFx26_paper_45.pdf
- s-to-z mappings: https://reference-global.com/article/10.2478/jee-2025-0018
- FIR design: https://www.mathworks.com/help/signal/ug/fir-filter-design.html
- Modified-sinc smoother (OpenMS): https://abibuilder.cs.uni-tuebingen.de/archive/openms/Documentation/nightly/html/classOpenMS_1_1ModifiedSincSmoother.html
- Partitioned convolution (AES e-library): https://www.aes.org/e-lib/browse.cfm?elib=16530 ; https://iris.unitn.it/handle/11572/466692 ; on the GPU (arXiv, 2025): https://arxiv.org/html/2509.04390v1
- Half-band resampling: https://github.com/Sin-tel/halfband
- Companion QR: https://arxiv.org/abs/1611.02435
- Invertible constant-Q transform, exact factorisation: https://arxiv.org/abs/2609.29119 ; CiCueTea: https://jp.mathworks.com/matlabcentral/fileexchange/184238-cicuetea
- Onset detection: https://arxiv.org/abs/2408.13734 ; https://essentia.upf.edu/reference/std_SuperFluxExtractor.html
- Differentiable predominant local pulse (ISMIR 2025): https://www.audiolabs-erlangen.de/content/05_fau/professor/00_mueller/03_publications/2025_ChiuSM_dPLP_ISMIR_ePrint.pdf
- Selection networks (2025 preprint): https://arxiv.org/html/2507.19926v1 ; Adams 2021: https://history.siggraph.org/?p=121185
- Spectral centroid (2026 preprint): https://arxiv.org/pdf/2605.30339
- Mel filter banks: https://docs.nvidia.com/deeplearning/dali/user-guide/docs/operations/nvidia.dali.fn.mel_filter_bank.html
- Complex cepstrum and phase unwrapping: https://arxiv.org/pdf/1205.3752 ; https://www.cs.princeton.edu/~ken/Complex_Cepstrum_77.pdf
- Schlecht, Sinjanakhom & Välimäki, "Multi-shelf graphic equalizer" (Signal Processing, 2025): https://acris.aalto.fi/ws/portalfiles/portal/154638738/1-s2.0-S0165168424002494-main.pdf ; MATLAB, parametric equalisers: https://www.mathworks.com/help/audio/ug/equalization.html
- Yamaoka & Oshima, sidelobe reduction by multiplying cosine-sum windows (IEEE Access, 2025): https://doaj.org/article/56f2fd88fcc145a0ae183b83dcd8378b ; Prabhu, *Window Functions and Their Applications in Signal Processing*: https://library.oapen.org/bitstream/20.500.12657/41686/1/9781466515840.pdf
- STFT reconstruction: https://ccrma.stanford.edu/~jos/sasp/FBS_Perfect_Reconstruction.html ; an STFT with adaptive windows (2026 preprint): https://arxiv.org/pdf/2610.37795
- GPU spectrograms: https://raw.githubusercontent.com/calebj0seph/spectro/master/docs/making-of.md
- SciPy, `choose_conv_method`: https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.choose_conv_method.html
