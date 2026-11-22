# Audit of the algorithm and stability registers, November 2026 (WP-905a … WP-905d)

Made on 2026-11-21 on the main tree (branch `handover-chain`, from commit 53a095d), six rows of §7.2 to a package: WP-905a rows 1–6, WP-905b rows 7–12, WP-905c rows 13–18, WP-905d rows 19–24. Each row was put through four checks (brief 64):

1. **Currency** (§7.3): a dated web search of the venues of §7.3 for a method that supersedes the selected one. What was searched and read is in the second pass of `currency-2026-11.md`; a better method becomes a numbered item of `Docs/Process/changes/CR-020.md` and is never adopted.
2. **The notes against the code** (NUMS-2): the hazard is the one §7.5 names; every figure of the note is reproduced by a passing test, and the measured figure is quoted beside the note's; the files and symbols of the mitigation exist. A note that was wrong while the code was right was corrected; code that is wrong is a finding.
3. **Mutations**: each mitigation removed or weakened, one at a time, in a copy that was restored byte for byte afterwards (`cmp` against the saved copy, never git), with the tests of the row run against it. A mutation that no test caught led to a stronger test drawn from the fixture library of WP-016, or is recorded as equivalent with the reason.
4. **NUMS-1 and NUMS-3**: the row has its twin in §7.5 and at least one note; the precision of the hot loop and the place where it is chosen.

`Scripts/check-registers.sh` checks the table mechanically: one row per row of §7.2, named as there and with its twin in §7.5; no empty cell; a dated currency check; every file named exists and every test named is declared in the file it is named with; every `ALG` package of §12 in exactly one row; every note of `Docs/Numerics` named by a row or listed as supplementary.

Figures are from the iOS 27.0 simulator (`ztdsp-27`) on the host of §3, Debug unless a row says otherwise. "Killed" means that at least one test failed with the mutation in place; the failing tests and their messages are in the row's section below and, in full, in `.build/logs/m9-registers/` of the run.

| # | Operation | Packages | Notes | Currency | Notes against the code | Stress tests | Mutations | Precision | Open |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Real FFT | WP-502 | `real-fft.md` | 2026-11-21: current (Apple's iOS 27 notes change nothing in the vDSP DFT; a 2026 target-precision FFT is 107–1 315 times slower) | true: every figure reproduced (forward floor 4.98e-8 … 1.668e-7 of the frame maximum, round trip ≤ 6.56e-7, dB within 7.3e-4); `Sources/ZTronDSPAnalysis/Nodes/TransformPlans.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `theErrorOfASinglePrecisionTransformIsAFloorUnderTheFrameMaximum`, `aBinFarBelowTheFrameMaximumIsKnownToAFloorOnly`, `decibelsOfEveryStressSignalAreNumbersAtOrAboveTheirFloor`; `Tests/ZTronDSPAnalysisTests/TransformTests.swift`: `theForwardTransformIsTheUnscaledDFT`, `aConstantAndTheNyquistSignalLandInTheirBins`, `anIllegalLengthIsATypedErrorAndNoSetupIsCreatedForIt` | 4 run, 4 killed (floor, halving, Nyquist bin, admission) | Float32 in the hot loop (`VDSPFFTPlan`); Double (`DoubleDFT`) for the cepstral steps, window and inversion analysis and the CQ kernel; chosen per node when the plan is built | open: A-24, A-NB20 (wave 3, m5b: no upper bound on transform lengths) |
| 2 | Framing | WP-203 | `mirrored-ring.md` | 2026-11-21: current (double mapping in current use; the copy on wrap stays the alternative) | corrected: hazard 3 qualified (the ring's arithmetic is modular; what 64 bits protect is the absolute counts), stress section extended; `Sources/CZTronDSP/ztd_ring.c` | `Tests/CZTronDSPTests/RingTests.swift`: `mirroredAndPlainRingsGiveTheSameResultsBitForBit`, `aWindowSpanningTheWrapIsContiguousAndCorrect`, `aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount`, `storageIsResidentAsSoonAsTheRingExists`, `anAutomaticRingMirrorsWhenTheSystemGrantsItAndHoldsTheSameEitherWay`; `Tests/CZTronDSPTests/CreationFailureTests.swift`: `theRingSurvivesEveryRefusalAndAnAutomaticOneFallsBack` | 8 run: 6 killed (one by the new test), 2 equivalent (32-bit positions; the proof's comparisons with the remap kept) | none in arithmetic: Float32 frames copied bit for bit; positions and the overrun count are 64-bit | open: F-905a-1 (the proof of the mirror cannot be exercised by a test) |
| 3 | IIR filtering | WP-208, WP-211 | `biquad-single.md`, `biquad-double.md`, `biquad-precision.md` | 2026-11-21: current (nothing peer-reviewed on biquad round-off since 2025; state-variable filters stay CR-020 item 4) | true: every figure reproduced (impulse 1.5482e-6 and 2.4192e-7, noise orders 2–8, blocks −115.05 … −99.2 dB, −59.42 dB, single against double −98.352 … −120.79 dB, 3.4033e-5 dB, the grid −100.2053 dB); `Sources/CZTronDSP/ztd_biquad.c`, `Sources/CZTronDSP/ztd_biquad_double.c`, `Sources/ZTronDSPDesign/Systems/Realization.swift` | `Tests/CZTronDSPTests/BiquadKernelTests.swift`: `aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind`, `theOutputDoesNotDependOnWhereTheCallersBufferLies`; `Tests/CZTronDSPTests/DoubleBiquadKernelTests.swift`: `theTwentyHertzHighPassIsWithinAHundredthOfADecibelOfTheReference`, `singlePrecisionMissesThatMarkOnTheSameFixture`, `theDeviationOfSingleFromDoubleSaysWhichFiltersNeedIt`, `theKernelIsItsDefinitionBitForBitForAnyBlockSizes`, `stateHygieneNeedsEverySectionToWorkNearTheLevelOfTheSignal`; `Tests/ZTronDSPDesignTests/PrecisionTests.swift`: `stressALowCutoffAtAHighRateRunsBecauseItsGainIsSpread`, `aCascadeBeyondSinglePrecisionIsMeasuredAsSuchAndRunsInDouble`, `overTheGridTheChosenPathIsWithinMinus100DecibelsOfTheDoubleReference`; `Tests/ZTronDSPDesignTests/SystemAnalysisTests.swift`: `theFiguresOfTheStressFixturesEqualTheirRecordedValues` | 9 run, 9 killed | Float32 (`vDSP_biquad`, C loop, `vDSP_biquadm`) or Double state and coefficients (`ztd_biquad_double.c`); chosen by measurement when the plan is compiled (`FilterLowering.emit`, REAL-3) | open: A-B1 (wave 2: CR-018 item 1 understates the miss on unseen noise), CR-013 items 4 and 5 (Proposed) |
| 4 | IIR design | WP-404, WP-405, WP-406, WP-407, WP-408, WP-409, WP-410, WP-411, WP-414, WP-418a, WP-418b | `section-pairing.md`, `butterworth-prototype.md`, `chebyshev1-prototype.md`, `chebyshev2-prototype.md`, `elliptic-functions.md`, `elliptic-prototype.md`, `bessel-roots.md`, `bessel-prototype.md`, `bilinear-transform.md`, `iir-design-analog.md`, `iir-design-digital.md` | 2026-11-21: current (s-to-z mappings, elliptic functions, Bessel zeros: nothing beyond what the first pass and CR-020 item 8 hold) | true: every figure reproduced (e.g. 1.651e-13 against 0.01683 expanded, Bessel residual 7.76e-18, bilinear 9.45e-13 against 0.01755, 5.22e-13 at the band edges); `Sources/ZTronDSPDesign/Systems/SectionPairing.swift`, `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift`, `Sources/ZTronDSPDesign/Prototypes/EllipticFunctions.swift`, `Sources/ZTronDSPDesign/Prototypes/BesselPolynomial.swift`, `Sources/ZTronDSPDesign/Transformations/Bilinear.swift`, `Sources/ZTronDSPDesign/Transformations/FrequencyTransformation.swift`, `Sources/ZTronDSPDesign/IIR/IIRDesign.swift` | `Tests/ZTronDSPDesignTests/SectionPairingTests.swift`: `stressSectionsKeepThePolesThatAnExpandedPolynomialLoses`, `stressTheOrderingKeepsPartialCascadesBelowThePeak`, `thePairingMatchesTheReferenceSectionForSection`, `theGainGoesIntoTheFirstSection`; `Tests/ZTronDSPDesignTests/AnalogPrototypeTests.swift`: `stressButterworthPolesAreClosedFormNotRootsOfAPolynomial`, `stressASmallRippleKeepsItsDigits`, `stressTheHighestOrderIsStillRepresentable`, `invalidOrdersAreTypedErrors`, `stressAHighOrderEllipticPrototypeStaysEquiripple`, `anEllipticOrderBeyondWhatADoubleResolvesIsRejected`, `stressBesselOrderTwentyFiveMeetsItsDefinitions`; `Tests/ZTronDSPDesignTests/EllipticFunctionTests.swift`: `stressTheLandenSequenceCarriesTheComplement`, `stressTheDegreeEquationKeepsTheComplement`, `stressTheInverseSineOfASmallArgumentKeepsItsDigits`; `Tests/ZTronDSPDesignTests/BesselPolynomialTests.swift`: `stressTheRootsAreFarMoreAccurateThanTheirConditioningAllowsInDoublePrecision`, `theResidualIsBelowTenToTheMinusTwelveUpToOrderTwentyFive`; `Tests/ZTronDSPDesignTests/FrequencyTransformationTests.swift`: `stressTheBilinearTransformOfRootsKeepsWhatTheCoefficientFormLoses`, `stressAWideBandKeepsItsAccuracy`; `Tests/ZTronDSPDesignTests/IIRDesignTests.swift`: `stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles` | 15 run, 15 killed | Double throughout (zeros, poles and gains as `Complex` of Double; Bessel polynomial values in double-double); design time only (NUMS-3) | open: A-2, A-3, A-NB2, A-NB4, A-NB5 (wave 1, m4a) |
| 5 | FIR design | WP-423, WP-425 | `fir-design.md` | 2026-11-21: current (windowing, least squares and equiripple are still the methods in use) | corrected: the figures the tests print are reproduced (firwin 1.11e-15, firls 5.55e-16, 3.47e-18 and 2.74e-14, the 31-tap gap fit 2.39 times the norm without the condition test, 1.71e-14 at the band edges); four rows no test prints are now marked so; `Sources/ZTronDSPDesign/FIR/LeastSquaresFIR.swift`, `Sources/ZTronDSPDesign/FIR/FIRDesign.swift`, `Sources/ZTronDSPDesign/FIR/FIRDesignMethod.swift` | `Tests/ZTronDSPDesignTests/FIRDesignTests.swift`: `stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack`, `anIllConditionedFitTakesTheFallBackAndStillMeetsTheOracle`, `stressFiltersAtTheEdgesOfTheBandAreLinearPhaseToTheBitAndReachTheirAttenuation` | 4 run, 4 killed | Double design (LAPACK in double); Float32 taps from `FilterLowering.emit(taps:)` | open: A-1 (wave 2, m4b: the ill-conditioned fixture is held to 1e-4, measured 9.95e-6); F-905a-2 (four rows of the note's second table are reproduced by no test) |
| 6 | Savitzky–Golay | WP-426 | `savitzky-golay.md` | 2026-11-21: current (nothing newer than CR-020 item 1) | corrected: the stress section now says what the scaling is for (range, not accuracy) and names the new test; `Sources/ZTronDSPDesign/Smoothing/SavitzkyGolayDesign.swift` | `Tests/ZTronDSPDesignTests/SavitzkyGolayTests.swift`: `stressAWideWindowAndAHighOrderNeedTheOrthogonalFactorisation`, `stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa` | 2 run, 2 killed (the scaling only by the new test) | Double design (`dgels`); Float32 weights where the stage emits them (`SmoothingStages.swift`) | none |
| 7 | FIR, short | WP-212 | `fir-direct.md` | 2026-11-21: current (Apple's iOS 27 notes change nothing in `vDSP_conv` or `vDSP_desamp`; read with row 1) | true: every figure reproduced (largest error 0.46603 … 0.00032499 of the register's bound from 1 to 1 500 taps); `Sources/CZTronDSP/ztd_fir.c`, `Sources/CZTronDSP/ztd_history.c` | `Tests/CZTronDSPTests/FIRKernelTests.swift`: `theErrorStaysWithinTheRegistersBoundOnTheStressSignals`, `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`; `Tests/CZTronDSPTests/RateKernelTests.swift`: `subnormalInputGivesExactZeros` | 2 run, 2 killed | Float32 sums in `vDSP_conv`, one call shape (cells of 64 frames); taps rounded once to Float32 by `FilterLowering.emit(taps:)`; fixed per kernel | none |
| 8 | FIR, long | WP-214, WP-215 | `partitioned-structure.md`, `partitioned-processing.md` | 2026-11-21: current (GPU and JAES 2025 work on uniform partitioning; non-uniform partitioning stays the registered alternative) | true: every figure reproduced (spectra within 1.3154e-7 of the largest bin; −120.77 … −134.08 dB against the direct kernel, the note's table); `Sources/CZTronDSP/ztd_partitioned.c` | `Tests/CZTronDSPTests/PartitionedKernelTests.swift`: `theSpectraOfTheStressSignalsAreExactWhereTheirEnergyIs`, `theSpectraEqualTheTransformOfEachPartition`, `thePartitionMustBeAPowerOfTwoFromEightUp`, `theStressSignalsStayWithinMinus100dBAndSilenceStaysSilent`, `theOutputIsWithinMinus100dBOfTheDirectKernel`, `subnormalInputGivesExactZerosOnBothPaths`, `aResetIsAColdStart` | 6 run: 5 killed (one by the new test), 1 equivalent (the flush of the delay line's spectra) | Float32 transforms (`vDSP_DFT`) and spectral products; the kernel spectra computed once, at creation; fixed | open: CR-013 item 6 (Proposed: −120.5 dB against the direct kernel, not §7.5's −139 dB) |
| 9 | Rate changes | WP-213, WP-223 | `decimator.md`, `interpolator.md` | 2026-11-21: current (nothing new on filter-and-keep or polyphase interpolation; multistage half-band stays the alternative) | true: every figure reproduced (alias −99.543 dB; images −99.584, −95.889, −98.189 dB); `Sources/CZTronDSP/ztd_rate.c` | `Tests/CZTronDSPTests/RateKernelTests.swift`: `aFullScaleToneAtNyquistDoesNotAliasIntoTheBand`, `theOutputEqualsFilterThenSubsampleForIrregularBlockSizes`, `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`, `theGainIsTheFactor`, `theOutputEqualsZeroStuffThenFilter`, `subnormalInputGivesExactZeros` | 5 run, 5 killed (the cleaning of the input is row 7's, shared) | Float32 (`vDSP_desamp`; `vDSP_conv` with an output stride); taps designed in Double; fixed per kernel | open: A-27, A-28, A-31 (wave 3, m5b: the subsampling report of WP-539, §7.5's mitigation of this row) |
| 10 | One-shot convolution, correlation | WP-513 | `one-shot-convolution.md` | 2026-11-21: current (a 2025 permutation-avoiding FFT convolution is a library-level optimisation of the same method) | true: every figure reproduced (direct 0.935 ε of an output's sum; FFT 6.5565e-7 and 2.0048e-6; 281 small outputs, 1 kept by the FFT; 27 843 zeros; the grid of STG-2 1.1969e-6, 2.1762e-7, 4.6245e-7); `Sources/ZTronDSPAnalysis/Correlation/Convolution.swift` | `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift`: `aConvolutionBelowTheCrossoverKeepsItsSmallOutputs`; `Tests/ZTronDSPAnalysisTests/ConvolutionTests.swift`: `automaticFollowsTheCostModelOfTheTable`, `theConvolutionEqualsTheReference`; `Tests/ZTronDSPAnalysisTests/CorrelationTests.swift`: `theCorrelationEqualsTheReference`, `theNormalisationsEqualTheirDefinitions` | 4 run: 3 killed, 1 survived (the refusal past 2²⁸ values: F-905b-1) | Float32 in and out; the method (`vDSP_conv`, a Float32 transform, the partitioned kernel) chosen per call by `OneShotConvolution.method` from the strategy and the crossover table | open: A-1, B-2, A-3, B-4 (wave 3, m5b: finite inputs near the largest float give NaN or ∞ by the transform methods), A-NB1, A-NB2, A-NB4, A-NB23; F-905b-1 |
| 11 | Autocorrelation | WP-515 | `autocorrelation.md` | 2026-11-21: current (searched with row 10: Wiener–Khinchin with zero-padding is the method in use) | true: every figure reproduced (2.8278e-7 of lag 0, coefficients 2.4672e-7, 431 lags below zero, the Hann frame 2.4511e-8 and 7.9473e-8, 0.99999994; one-shot 8.2187e-8 and 7.0079e-7); `Sources/ZTronDSPAnalysis/Nodes/WienerKhinchin.swift`, `Sources/ZTronDSPAnalysis/Nodes/AutocorrelationNode.swift` | `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift`: `theAutocorrelationOfEveryStressSignalIsLinearAndGuarded`; `Tests/ZTronDSPAnalysisTests/CorrelationTests.swift`: `theAutocorrelationByTransformEqualsTheDirectSum`, `theTransformOfAnAutocorrelationPadsByRule`; `Tests/ZTronDSPAnalysisTests/AutocorrelationStepTests.swift`: `theFramesEqualTheDirectSumForAnyBlockSize`, `theNormalisationsAreThoseOfTheOneShotFunction`, `aPeriodicFixturePeaksAtItsPeriod` | 4 run, 4 killed | Float32 transforms (`VDSPFFTPlan` in `WienerKhinchin`); the one-shot function by the method of row 10; fixed by the strategy | open: A-5, B-6 (wave 3, m5b: lag 0 of very large frames); A-NB3 (the currency record; the second pass now has a search) |
| 12 | Polynomial roots | WP-402 | `polynomial-roots.md` | 2026-11-21: current (nothing newer than the unitary-plus-rank-one QR of Aurentz et al. 2015 and 2018, the registered alternative) | corrected: the mitigation of multiple roots stated as measured (a step out of a cluster is refused) and the new tests named; figures reproduced (7.2066e-5, 3.8234e-6, 0.10574, 0, 1.6509 and 8.41e-14, 9.9266e-3), the 120-digit ones excepted; `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift`, `Sources/ZTronDSPDesign/Math/QuadraticRoots.swift` | `Tests/ZTronDSPDesignTests/PolynomialRootFinderTests.swift`: `stressBalancingRescuesABadlyScaledPolynomial`, `stressThePolishBringsWilkinsonWithinItsAccuracy`, `stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic`, `degreeTwoUsesTheClosedFormWithoutCancellation`, `rootsAtTheOriginAreReadFromTheTrailingZerosExactly`, `theDegreeCapIsATypedError`, `theTripleRootReachesItsDocumentedAccuracy` | 7 run, 7 killed (two only by the tests added and strengthened) | Double (`dgebal`, `dhseqr`) and double-double Newton steps (`ExtendedHorner`); design time only | open: A-4, B-1, A-NB1 (wave 1, m4a) |
| 13 | Constant-Q | WP-518, WP-519, WP-520, WP-521, WP-522a, WP-523 | `constant-q-kernel.md`, `half-band-decimator.md`, `sparse-kernel-product.md`, `constant-q-transform.md`, `constant-q-scale.md` | 2026-11-21: current; a faster computation of the registered alternative found (arXiv 2609.29119, 2026: an exact factorisation of the invertible CQT), recorded as CR-020 item 9 and not adopted | corrected: `constant-q-kernel.md` (0.81 %, not 0.5 %, with nothing dropped), `constant-q-transform.md` (252 bins within 0.0112 dB, not 0.008 dB; `denormal` off by 3.4e-45, 2.4 units of the least subnormal, not one), `sparse-kernel-product.md` (one ε is a measurement, not a bound; the transform of finite samples is finite only while it does not overflow); every other figure reproduced (rows keep ≥ 0.999 9539 at 48 kHz, ≥ 0.999 002 at the corners; stop band 80.376 dB; −94.06 dB through the transform; 0.7807 ε·T; the longest atoms within 0.0061 dB; the scale 4.6 ε); `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQKernel.swift`, `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQSchedule.swift`, `Sources/ZTronDSPAnalysis/Nodes/ConstantQNodes.swift`, `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQProjection.swift`, `Sources/ZTronDSPAnalysis/Steps/ConstantQScale.swift` | `Tests/ZTronDSPAnalysisTests/ConstantQStabilityTests.swift`: `aKernelKeepsItsEnergyAtEveryCornerOfTheStressLibrary`, `everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary`, `noStressSignalAliasesThroughTheDecimators`, `aToneThatWouldFoldOntoABinOfALowerOctaveIsNotSeen`, `theProductOfEveryStressSpectrumIsWithinTheBoundOfItsTerms`, `theTransformOfEveryStressSignalIsFiniteAndThatOfTheDefinition`, `theTransformOfTheNonFiniteFixtureIsThatOfTheSignalWithItsValuesReplaced`, `theLongestAtomsOfTheLibraryAreReadFromSignalsHalvedAThousandTimesOver`, `theBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`; `Tests/ZTronDSPAnalysisTests/ConstantQKernelTests.swift`: `aRowKeepsItsEnergyWhateverTheSparsityAsksFor`, `aKernelForAnotherTransformLengthIsRefusedBeforeAProductIsMadeOfIt`, `theSparseProductIsTheDenseProduct`; `Tests/ZTronDSPAnalysisTests/ConstantQScheduleTests.swift`: `theHalfBandFilterPassesTheLowerBandAndRejectsWhatWouldFoldOntoItByEightyDecibels`, `aToneThatWouldAliasLeavesTheDecimatorEightyDecibelsDown`; `Tests/ZTronDSPAnalysisTests/ConstantQTests.swift`: `theTransformOfTheFixturesIsThatOfTheDefinition`, `aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude`; `Tests/ZTronDSPAnalysisTests/ConstantQScaleTests.swift`: `thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` | 24 run, 24 killed (three only by the new tests: the kernel rounded twice, the refusal of a kernel for another length, the replacement of non-finite samples) | Float32 in the hot loop: each octave's transform (`VDSPFFTPlan`), the sparse product (`SparseKernelProduct.multiply`), the half-band decimators (the rate kernel of row 9); the kernel and the scale's weights computed in Double and rounded once; fixed by `MultirateSparseKernelStrategy` when the plan is built; the scale's banded or dense product chosen at compile time (SEL-5) | open: A-6, B-7, A-11, B-10 (wave 3, m5c: finite input near the largest float gives NaN or ∞); A-4, A-5, B-5 (the hop rule); A-10, B-9 (the scale's arithmetic on a bin count); B-8 (coverage); backlog B-4, B-6, B-8 (CR-022 item 2), BL-4, BL-6; CR-020 item 9 |
| 14 | Onset envelope | WP-525 | `onset-strength.md` | 2026-11-21: current (no 2025–2026 onset function supersedes log-mel flux with a maximum filter; SuperFlux is the selected method's own) | corrected: what makes a mean not finite (a NaN level, which `vDSP_vthr` passes through, and a band rising to +∞; the note said only "not a number"); every figure reproduced (4.77e-8 dB, largest 1.345 dB, white noise 180 dB down 0 and 0.8010 dB a frame, at full scale 0.8010 dB, against the reference 1.60e-7); `Sources/ZTronDSPAnalysis/Nodes/OnsetStrengthNode.swift`, `Sources/ZTronDSPAnalysis/Steps/OnsetStrength.swift` | `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift`: `theOnsetStrengthOfEveryStressSignalIsBoundedByItsFloor`; `Tests/ZTronDSPAnalysisTests/OnsetStrengthTests.swift`: `theOnsetStrengthOfTheFixturesEqualsTheReference`, `valuesUnderTheFloorAreRaisedToItFirst`, `aLevelThatIsNotFiniteNeverGivesAValueThatIsNot`, `aColdStartForgetsTheFramesItComparedWith` | 6 run, 6 killed (the guard of a mean that is not finite only by the new test) | Float32 throughout (`vDSP_vthr`, `vDSP_vsub`, `vDSP_meanv`, `vDSP_vswmax` in `OnsetStrengthNode`), the floor narrowed to Float32 when the step is lowered; one implementation | open: A-10 (wave 3, m5b: a floor beyond the range of a float is accepted and every confidence becomes 0); A-11, B-9 (VIS-2) |
| 15 | Tempogram | WP-526, WP-527 | `tempogram.md` | 2026-11-21: current (the 2025 differentiable predominant local pulse builds on the Fourier tempogram; the cyclic tempogram stays the alternative) | corrected: a value of the curve that is not finite, not only one that is not a number, is taken as 0; every figure reproduced (the pedestal 3.719e-5; no coefficient above 0.98402; lag 48 at 117.19 BPM; 641 columns of zeros; against the reference 0.99999999998682 and 6.363e-7); `Sources/ZTronDSPAnalysis/Nodes/TempogramNodes.swift`, `Sources/ZTronDSPAnalysis/Steps/Tempogram.swift` | `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift`: `theTempogramOfEveryStressCurveShowsWhatMovesAndNothingElse`; `Tests/ZTronDSPAnalysisTests/TempogramTests.swift`: `silenceAndACurveThatDoesNotMoveGiveZeros`, `aValueOfTheCurveThatIsNotFiniteIsTakenAsZero`, `theTempogramOfACurveEqualsTheReference`, `theTempogramOfTheMusicFixtureEqualsTheReference` | 5 run, 5 killed (the replacement of a value that is not finite only by the new test) | Float32: the mean and the taper (`vDSP_meanv`, `vDSP_vsadd`, `vDSP_vmul`) in `TempogramNode`, the autocorrelation by a Float32 transform (`WienerKhinchin`), the Fourier rows by one (`FFTPlan`); fixed per method | open: A-12, A-14 (wave 3, m5b: curves near the largest float give ∞ or NaN); A-13, A-15, B-10, B-11 (VIS-2) |
| 16 | Median filtering | WP-219, WP-528, WP-529, WP-530, WP-531a, WP-610 | `lane-exchange.md`, `median-network.md`, `median-lanes.md`, `separation-masks.md`, `harmonic-percussive.md`, `median-metal.md` | 2026-11-21: current (nothing new beside the sorting-network filters of Adams 2021, CR-020 item 2, and a 2025 register-resident selection network; the median filters of Fitzgerald 2010 are still what separation libraries use) | corrected: `separation-masks.md` (the zero-denominator rule removed gives shares of one half, not NaN, and the samples of `HPSS` stay numbers); every other figure reproduced (741 312 medians bit for bit, 14 288 subnormal and 6 739 −0, exchanges 3, 70, 152, 439; 1 074 960 medians of single filters; 228 120 on the GPU; 1 071 144 pairs of shares within 2.250e-7, 588 888 zeros, 41 919 bins lost; the separation 7.998e-8, 1.370e-7, 1.0193 times, 138.65 … 139.31 dB), the lane exchange's timings not measured again (host figures of WP-611b); `Sources/CZTronDSP/ztd_lane_exchange.c`, `Sources/ZTronDSPCore/Toolkit/MedianNetwork.swift`, `Sources/ZTronDSPAnalysis/Nodes/MedianKernels.swift`, `Sources/ZTronDSPAnalysis/Separation/MedianStrategy.swift`, `Sources/ZTronDSPAnalysis/Separation/MaskStrategy.swift`, `Sources/ZTronDSPAnalysis/Nodes/HarmonicPercussiveNode.swift`, `Sources/ZTronDSPAnalysis/Recipes/HPSS.swift`, `Sources/ZTronDSPMetal/Shaders/Median.metal` | `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift`: `theMedianLanesOfEveryStressSignalAreTheSortedMiddle`, `theMasksOfEveryStressSpectrogramAreSharesAtAnyLevel`, `theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold`, `theComponentsOfEveryStressSignalComeBackNoLargerThanTheSignal`; `Tests/CZTronDSPTests/LaneExchangeTests.swift`: `bothImplementationsEqualTheScalarExchange`, `theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers`; `Tests/ZTronDSPCoreTests/MedianNetworkTests.swift`: `theMedianOfEveryStressSignalIsTheSortedMiddle`, `everyZeroOneInputPutsTheMedianOnItsLane`, `theNetworkIsPrunedToWhatTheMedianNeeds`; `Tests/ZTronDSPAnalysisTests/MedianKernelTests.swift`: `theMedianAlongTimeEqualsTheOracle`, `theMedianAlongFrequencyEqualsTheOracle`, `aFilterMayWriteWhereItRead`; `Tests/ZTronDSPAnalysisTests/SeparationMaskTests.swift`: `noShareIsEverNotANumber`, `whereNeitherMedianReachesTheFloorBothMasksAreZero`, `theMasksOfTheFixturesEqualTheReference`; `Tests/ZTronDSPAnalysisTests/HarmonicPercussiveTests.swift`: `aColdStartRefillsTheHistoryOfTheMedian`, `theCausalStepEqualsTheOfflineMediansOnInteriorFrames`; `Tests/ZTronDSPAnalysisTests/HPSSTests.swift`: `theComponentsReconstructTheInput`; `Tests/ZTronDSPMetalTests/MetalMedianFilterTests.swift`: `tiesAndSubnormalValuesAreTheOraclesToo`, `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms` | 19 run, 19 killed (the reflection at a start run again with the masks' tests, which fail too, as the note says) | No arithmetic in the medians: Float32 lanes ordered by the lane exchange (FMIN and FMAX on arm64, or `vDSP_vmin` and `vDSP_vmax`), bound when the filter is made (SEL-3), and integer keys of the float bits on the GPU; the masks in Float32 (`vDSP_vdiv`, `vDSP_vsq`, `vvpowsf`, `vDSP_vthr`), margins and floor narrowed to Float32 when the step is lowered; CPU or GPU chosen by the `MedianStrategy` when the plan is built, a live frame always on the CPU (GPU-1) | open: A-16, B-13 (wave 3, m5b: traps of `MedianOracle` on huge counts); A-18, A-20, B-20 (accepted parameters narrowed to Float32); A-21, B-17 (overflow of the magnitude and of the margin's product near the largest float); B-18 (subnormal quotients); A-24, A-25 (the recipe: a trap at 2⁴⁰ samples, NaN at 10³⁰); B-15 (RT-7), B-16 (§5.11.1); A-17, A-19, A-22, A-23, A-26, B-12, B-14, B-19, B-21 (VIS-2); backlog A-NB5, A-NB6, A-NB18, BL-1, BL-3, BL-4, BL-5, BL-11, BL-14; wave 2, m5a, backlog B-12 of lens B (what the pruning test shows) |
| 17 | Spectral centroid | WP-507 | `spectral-centroid.md` | 2026-11-21: current (a definition; practice still leaves out or flags frames without energy, which the floor does) | corrected: the guard refuses a sum that is not finite, not only one that is not a number; "one to two ε" is at most 2.1 ε; every figure reproduced (146 frames with a centroid and 115 without; `white-noise` 1.750e-3 Hz, 1.42e-7 of the centroid, … `dc` 1.23e-6 Hz); `Sources/ZTronDSPAnalysis/Nodes/SpectralCentroidNode.swift`, `Sources/ZTronDSPAnalysis/Steps/SpectralCentroid.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `theCentroidOfEveryStressSignalIsAFrequencyOrNothing`, `theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing`; `Tests/ZTronDSPAnalysisTests/SpectralCentroidTests.swift`: `silenceHasNoCentroid`, `theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce`, `theRuleOfTheDescriptionIsTheRuleOfTheTypes` | 5 run, 5 killed (two only by the new tests: the guard on a result that is not finite, the ramp rounded once) | Float32: the sum and the dot product by Core's `Vector`, bound to their implementation when the plan is compiled (SEL-3); the ramp computed in Double and rounded once; the floor narrowed to Float32 when the step is lowered | open: wave 2, m5a, backlog B-14 of lens B (no benchmark recorded; PERF-1 asks for one only behind a claim) |
| 18 | Mel conversion | WP-508, WP-535 | `mel-filter-bank.md`, `mel-projection.md` | 2026-11-21: current (a definition in two published formulas; the libraries still offer the Slaney and the HTK convention) | corrected: the HTK round trip holds within 10⁻⁹ Hz below 1 Hz, not relatively (A-5, open); every figure reproduced (9 of 21 banks with an empty band, the counts and the filling lengths of the table; ε·f over a half-width at most 7.56e-15; the projection 2.29e-7 of a band at most, 62 bins, ε·bins 7.39e-6); `Sources/ZTronDSPAnalysis/Mel/MelFilterBank.swift`, `Sources/ZTronDSPAnalysis/Steps/MelScale.swift`, `Sources/ZTronDSPAnalysis/Nodes/MelNodes.swift`, `Sources/ZTronDSPCore/Units/MelFormula.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `aBandThatCoversNoBinIsFoundAtEveryRateOfTheLibrary`, `theEdgesEndOnTheRangeItselfAtEveryRateOfTheLibrary`, `theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`; `Tests/ZTronDSPAnalysisTests/MelTests.swift`: `theConversionsRoundTripAndEqualTheReference`, `theWeightsEqualTheReferenceFilterBank`, `anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt`, `bandedAndDenseProjectionsAgree` | 8 run, 8 killed (the ends of the edges only by the new test) | The edges and the weights in Double, each weight rounded once to Float32; the projection in Float32, banded dot products (Core's `Vector`, bound per band length) or one `cblas_sgemv`, chosen by the crossover when the plan is compiled (§7.4, SEL-3) | open: A-5 (wave 2, m5a: the HTK round trip below 1 Hz); backlog B-14 of lens B (no benchmark recorded) |
| 19 | Cepstrum | WP-509, WP-510 | `cepstrum.md`, `complex-cepstrum.md` | 2026-11-21: current (nothing from 2025–2026 on phase unwrapping; the cepstrum from the roots of the frame's polynomial stays CR-020 item 7) | corrected: `complex-cepstrum.md` (the value beside the frame is the linear term of the phase, minus the delay: −64 for the impulse 64 samples in; the note said its position, and that the half turns are the delay); every other figure reproduced (the real cepstrum at floors 10⁻¹⁰, 10⁻⁴, 10⁻² and 1, `dc` and `nyquist` 0.199 … 5.46e-8, `white-noise` 5.57e-8, its largest value 23.025850 against ln 10¹⁰ = 23.025851; the round trip at or below its prediction on every signal, `full-scale-sine` 3.53e-7 against 1e-5, `denormal` 4.35562e30 against 4.35566e30, `silence` infinite and flagged; the delayed impulse within 2.79e-14); `Sources/ZTronDSPAnalysis/Nodes/CepstrumNodes.swift`, `Sources/ZTronDSPAnalysis/Steps/Cepstrum.swift`, `Sources/ZTronDSPAnalysis/Inversion/StageInversions.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `theCepstrumOfEveryStressSignalIsBoundedByItsFloor`, `theRealCepstrumOfTheStressSpectraIsItsDefinitionRoundedOnce`, `theComplexCepstrumOfEveryStressSignalInvertsOrSaysWhyNot`; `Tests/ZTronDSPAnalysisTests/CepstrumTests.swift`: `theLogarithmIsFloored`, `theRealAndThePowerCepstrumEqualTheGoldenVectors`, `theComplexCepstrumOfADelayedImpulseIsItsDelay`, `theInverseReturnsTheSpectrum`, `theRoundTripRunsThroughAnInverseSTFT`, `thePitchOfAHarmonicFixtureIsWithinOnePerCent`; `Tests/ZTronDSPAnalysisTests/InversionTests.swift`: `binsAtTheFloorOfTheLogarithmAreCounted`, `theComplexCepstrumInvertsAndTheOthersDoNot` | 10 run, 10 killed (the logarithm rounded to single precision only by the new test; its first spelling allocated, and only the allocation test saw it) | Double from the magnitudes on: the logarithm (`vvlog`), the phase (`vvatan2`), the unwrapping and the transforms (`DoubleDFT`); the frame rounded once to Float32 (`vDSP_vdpsp`); fixed in `CepstrumNode`, one implementation | open: A-12 (wave 2, m5a: the cepstral pitch meets 1 % narrowly at 110 Hz, the absolute floor; CR-019 item 13), B-14 (no benchmark recorded), B-15 (RT-7 layer 2 does not reach the leaf loops of `CepstrumNodes`); F-905d-3 (the public documentation gives the delay value no sign) |
| 20 | Band-boost | WP-421 | `band-boost.md`, `matched-peak.md` | 2026-11-21: current (the 2025 multi-shelf graphic equaliser is not a band-boost design; Orfanidis 2005 is still what the tools follow; Vicanek's 2024 matched shelving stays CR-020 item 6) | corrected: `matched-peak.md` (two bounds rounded below what is measured now give it: the centre gain under stress within 3.42e-9 dB, not 3.4e-9; the shape at most 0.534 of the Cookbook's deviation, not 0.53); every other figure reproduced (properties 1 to 6 over the grid 7.774e-11 dB, 2.723e-11, 5.991e-12 dB, 1.431e-11 dB, 0.99998553, 9.286e-14; the stress fixture 5.983e-11 dB and 1.790e-15 in zero-pole form, 7.261e-9 dB as paired biquads, 0.954 dB and 0.237 through closed-form fourth-order sections; the matched peak 2.276e-11 dB … 2.715e-15 over the grid, 3.412e-9 dB and 4.193e-10 under stress); the first formulation of `matched-peak.md` is history, and is told as such; `Sources/ZTronDSPDesign/Equalizers/EqualizerDesign.swift`, `Sources/ZTronDSPDesign/Equalizers/MatchedPeakDesign.swift`, `Sources/ZTronDSPDesign/Systems/SectionPairing.swift` | `Tests/ZTronDSPDesignTests/EqualizerTests.swift`: `stressANarrowLowBandKeepsItsAccuracyInZeroPoleForm`, `orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads`, `property5AllPolesLieStrictlyInsideTheUnitCircle`, `property6ABoostAndTheSameCutAreTheIdentity`, `aGainOfZeroDecibelsIsTheIdentityAtEveryOrder`, `aBandThatReachesFortyNineHundredthsOfTheSampleRateIsRejected`; `Tests/ZTronDSPDesignTests/MatchedPeakTests.swift`: `stressANarrowLowBandKeepsItsAccuracy`, `theBandsTheLimitRejectsAreTheOnesThatReachIt`, `nearNyquistTheShapeIsCloserToTheAnalogPeakThanTheCookbooks`, `whatIsNoPeakIsATypedError`; `Tests/ZTronDSPDesignTests/SectionPairingTests.swift`: `thePairingMatchesTheReferenceSectionForSection` | 12 run: 6 killed (order 1's Cookbook section only by the strengthened test), 6 equivalent (the radicand, the nearest pairing within the band boost, `expm1`, the detune, the difference of squares, the cancelling zero) | Double throughout the design: zeros, poles and gain in ZPK, paired in Double (`SectionPairing`), the matched peak's bisection in Double; design time only; the sections then run in Float32 or Double as chosen when the plan is compiled (row 3) | open: A-NB6, B-BL-4 (wave 1, m4a: properties 1–4 tested on the zero-pole form only; two public names missing from CR-018 item 11); A-B3, B-4 (wave 2, m4b: the matched peak's `.q` is the analog prototype's; COV-3 of `MatchedPeakDesign.swift`); F-905d-2 |
| 21 | Window analysis | WP-501d, WP-501e, WP-501f | `window-gains.md`, `window-smoothness.md`, `window-spectrum.md` | 2026-11-21: current (a 2025 method multiplies cosine-sum windows to lower their side lobes, a design method; nothing on computing the figures) | true: every figure reproduced (the windows without their mean sum to −7.88e-15 … 0, five to round-off; `denormal` exactly 1 bin of noise bandwidth; the jumps' table, `full-scale-square` 44, `nyquist` 1 025, … `decaying-tail` 1, within 0.125 sample; `dc` −13.262 dB and 2.0 bins between the nulls, no level below −400 dB); `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift`, `Sources/ZTronDSPAnalysis/Transform/FrameAlignment.swift`, `Sources/ZTronDSPAnalysis/Steps/FramingSupport.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `theGainsOfEveryStressWindowAreNumbersOrNothing`, `theTailOfAStressWindowIsJudgedAtEveryHeight`, `theJumpsOfEveryStressWindowAreFoundWhereTheyAre`, `theSpectralFiguresOfEveryStressWindowAreNumbersOrNothing`, `theNullOfATruncatedRectangleIsFoundBetweenThePointsOfTheGrid`; `Tests/ZTronDSPAnalysisTests/WindowAnalysisTests.swift`: `theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven`, `theFiguresOfTheStockWindowsEqualTheReference`, `shapeAndEdgesOfTheStockWindows`, `higherOrdersAreToldApart`, `smoothnessIsTheOrderOfTheLowestDerivativeThatJumps`, `anInteriorJumpIsLocatedWithinOneSample`, `aKinkIsNotAJump`, `integrabilityOnTheFrame`; `Tests/ZTronDSPAnalysisTests/InversionTests.swift`: `aFailingWindowIsReportedNotThrown` | 22 run, 22 killed (three only by the new and strengthened tests: the symmetry and the tail judged against the peak, the null placed between the points) | Double throughout: the samples, the grids of the finite differences, the zero-padded transform (`DoubleDFT`); background work (BG-1), when a pipeline is attached, never on the audio thread; fixed in `WindowAnalysis` | open: A-3, A-4, B-10, B-11 (wave 2, m5a: a jump located within one sample with a loosened tolerance, the finest grid 4 096; the Blackman null-to-null width 6.0793 at a frame of 1 000; within one sample against WIN-6 above 8 192 samples; the threshold of constant overlap-add untested) |
| 22 | Inversion analysis | WP-537 | `inversion-analysis.md` | 2026-11-21: current (a 2026 STFT with data-adaptive windows restores reconstruction by normalising its envelope; nothing sharpens NOLA or the frame bounds) | corrected: below the floor `silence` loses 0, not 0.99 to 1.0 of a peak it does not have; `denormal` errs by up to 1.11 of its peak, not 1.1; every other figure reproduced (at B/A 1, 9.6745, 10⁴ and 10⁸ the largest errors 3.58e-7, 8.35e-7, 2.83e-5 and 1.91e-3, 138.88 … 84.00 dB, the predictions 1.907e-5, 1.845e-4, 0.1907 and 1; `denormal` within 71 units of the least subnormal; a tight frame 138.88 dB); `Sources/ZTronDSPAnalysis/Inversion/InversionReport.swift`, `Sources/ZTronDSPAnalysis/Inversion/StageInversions.swift`, `Sources/ZTronDSPAnalysis/Inversion/RateInversions.swift` | `Tests/ZTronDSPAnalysisTests/StabilityTests.swift`: `whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal`, `theComplexCepstrumOfEveryStressSignalInvertsOrSaysWhyNot`; `Tests/ZTronDSPAnalysisTests/InversionTests.swift`: `theConditionsOfAnSTFTAreItsFrameBounds`, `aFailingWindowIsReportedNotThrown`, `aMeasurementIsWhatItsNameSays`, `theReportOfAnExactPairIsExact`, `aBandLimitedFixturePassesTheSamplingTheorem`, `decibelsInvertWhereNoValueIsAtTheFloor`, `cepstralCoefficientsInvertAtFullRank` | 9 run, 9 killed (the head-room of 16 only by the strengthened test, which now computes the prediction itself) | Double for the conditions (Σ w², B/A, the margins) and the band limit; the round trip measured on the pipeline's own Float32 arithmetic and compared in Double; computed when the report is asked for, fixed | open: A-11, B-3 (wave 2, m5a: VIS-2 of `inversionReport(for:sampleRate:after:)`; the measured relative error of INV-2); A-NB9, A-NB10, A-NB11, A-NB12 (wave 3, m5b: NaN or ∞ turns the subsampling verdict; subnormal signals; frames that are not finite read as exact; a trap at Int.max / 2) |
| 23 | Heat-map rendering | WP-605 | `heatmap-rendering.md` | 2026-11-21: current (open GPU spectrograms keep a ring of columns, upload only the new ones and colour in the shader, the registered design; nothing on half-float textures) | true: every figure reproduced (a texel within 4.07e-4 relative, bound 2⁻¹¹; a level within 0.0308 dB; PSNR 68.7 dB at the least over seventeen golden images, six equal pixel for pixel; the warp table 8.06e-4, 5.20e-4 and 6.10e-5 of a row for 2 049 rows); the register's "under 0.005 dB" is CR-016 item 3's, open; `Sources/ZTronDSPMetal/Heatmap/HeatmapTexture.swift`, `Sources/ZTronDSPMetal/Shaders/Heatmap.metal`, `Sources/ZTronDSPMetal/Rendering/FrequencyScale.swift` | `Tests/ZTronDSPMetalTests/HeatmapTextureTests.swift`: `valuesAHalfFloatCannotHoldAreClampedAndNotANumberBecomesTheLowest`, `aNotANumberIsReplacedInWhicheverBinItArrives`, `eachLevelIsTheMaximumOfTheTwoEntriesBelowIt`; `Tests/ZTronDSPMetalTests/HeatmapGoldenTests.swift`: `aOneBinPeakSurvivesEveryScale`, `theRenderedPictureMatchesTheGoldenImage`, `thePictureDoesNotDependOnHowTheColumnsArrived`; `Tests/ZTronDSPMetalTests/FrequencyScaleTests.swift`: `theWarpTableFollowsTheScaleToAThousandthOfARow`, `aTableSpansTheWholeAxisOfTheFeed` | 8 run, 8 killed (the check for a NaN over every bin only by the new test) | Float32 staging (`vDSP_vclip`, `vDSP_vmax` for the levels), converted once to half floats (`vImageConvert_PlanarFtoPlanar16F`) into an `r16Float` texture; the shader in `float` with a warp table of 4 096 entries; fixed when the renderer is made | open: CR-016 item 3 (Proposed: the error of a level in decibels is relative to the level, up to 2⁻⁵ dB, not under 0.005 dB) |
| 24 | Implementation selection | WP-611a | `crossover-search.md` | 2026-11-21: current (SciPy's `choose_conv_method` and the autotuners of FFT libraries time the candidates after a warm-up and keep the result, the registered approach) | corrected: `crossover-search.md` (the GPU median's entry is set by `AnalysisCalibration`, where the CPU median lives; `Calibration.report()` leaves it as it found it); the search's figures reproduced (five synthetic pairs within one grid step, exactly; the real pair at 1 024); the host table is an optimised build's, not reproduced in Debug; `Sources/ZTronDSPMetal/Calibration/Calibration.swift`, `Sources/ZTronDSPMetal/Calibration/CrossoverMeasurement.swift`, `Sources/ZTronDSPMetal/Calibration/StockCandidates.swift`, `Sources/ZTronDSPAnalysis/Calibration/AnalysisCalibration.swift`, `Sources/ZTronDSPCore/Toolkit/Implementation.swift` | `Tests/ZTronDSPMetalTests/CalibrationTests.swift`: `aDisturbedTimingDoesNotMoveTheCrossover`, `theFastestSampleCountsAndADisturbedOneDoesNot`, `theCandidatesTakeTurnsAtEverySize`, `theCrossoverIsTheSizeFromWhichTheHeavierOneStaysFaster`, `theTimerRepeatsACallUntilASampleIsLongEnough`, `aMeasuredTableReplacesWhatWasMeasuredAndKeepsTheRest`, `aSyntheticPairWithAKnownCrossoverIsFoundWithinOneGridStep`, `aRealPairOfWorkloadsIsFoundThroughTheClock`; SEL-6, element-wise and reduction: `Tests/ZTronDSPCoreTests/ToolkitTests.swift`: `implementationsAgreeBitForBit`, `implementationsAgreeWithinTenToTheMinusSix`; lane exchange: `Tests/CZTronDSPTests/LaneExchangeTests.swift`: `bothImplementationsEqualTheScalarExchange`, `theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers`; gain kernel: `Tests/CZTronDSPTests/GainKernelTests.swift`: `bothImplementationsAreBitExactWithAScalarLoop`; biquad kernel: `Tests/CZTronDSPTests/BiquadKernelTests.swift`: `bothImplementationsFollowTheDoubleReferenceOnNoise`, `theNativeLoopIsBitExactWithTheScalarRecurrence`; FIR: `Tests/ZTronDSPDesignTests/SystemStageTests.swift`: `theDirectAndThePartitionedPathAgree`; mel projection: `Tests/ZTronDSPAnalysisTests/MelTests.swift`: `bandedAndDenseProjectionsAgree`; median: `Tests/ZTronDSPMetalTests/MetalMedianFilterTests.swift`: `theNetworkOnTheGPUIsTheNetworkOfTheCore`, `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms`; convolution: `Tests/ZTronDSPAnalysisTests/ConvolutionTests.swift`: `automaticFollowsTheCostModelOfTheTable` | 8 run: 7 killed (two only by the new tests: the fastest sample, the candidates timed in turn), 1 equivalent (the store of a dot product's result: the call goes through a closure the optimiser does not see into) | Double timings (`DispatchTime` nanoseconds, the fastest of the samples); the choice bound from `CrossoverTable` when the plan is compiled (SEL-3), nothing timed at run time | open: F-905d-1 (`CrossoverTable.polynomialClosedForm` decides nothing: no plan asks for `.polynomialRoots`, and the root finder takes the closed form by degree; SEL-6 for polynomial roots is moot) |

## WP-905a: rows 1 to 6

### Row 1: Real FFT (WP-502, `real-fft.md`)

**Currency.** Searched on 2026-11-21: Apple's release notes for iOS and iPadOS 27 (no Accelerate section; the Metal section fixes two sampler clamp-to-edge issues), Apple's security content of iOS 27 (two Accelerate entries, both an out-of-bounds write when processing an image, none on the DFT), FFT accuracy and convolution papers of 2025–2026 on arXiv and ACM TOMS, and MPSGraph's FFT (the registered alternative). Found: Kawakami & Takahashi, "Computing FFTs at Target Precision Using Lower-Precision FFTs" (arXiv 2603.29129, 2026), lower error than FFTW but 107 to 1 315 times slower; "Permutation-Avoiding FFT-Based Convolution" (arXiv 2506.12718, 2025), a library-level optimisation of the convolution, not a different transform; no change to MPSGraph's FFT since WWDC 2024. Outcome: current.

**Notes against the code.** The hazards are §7.5's (round-off with log N; a small bin beside a large one). Code and symbols exist: `VDSPFFTPlan` and `DoubleDFT` in `Sources/ZTronDSPAnalysis/Nodes/TransformPlans.swift` (admission by `TransformLength.admit`, the forward halving and the move of the Nyquist bin), the decibel floor in `Nodes/SpectralValueNode.swift` and `Sources/ZTronDSPCore/Units/Amplification.swift`. To quote what the tests measure, `StabilityTests` now prints its figures (no expectation changed). Measured against the note:

| Figure | Note | Measured |
|---|---|---|
| forward error, of the frame's largest bin, worst over the stress signals: 16, 48, 80, 240, 1 024, 4 096, 16 384 points | the same table | 4.98e-8, 1.128e-7, 1.087e-7, 1.177e-7, 1.217e-7, 1.367e-7, 1.668e-7 |
| forward then inverse, of the signal's peak | the same table | 1.19e-7, 3.58e-7, 3.58e-7, 3.58e-7, 4.77e-7, 6.56e-7, 5.96e-7 |
| a bin 60, 80, 100, 120, 140, 160 dB under the maximum and beyond, error of itself | 3.7e-6, 5.7e-5, 4.1e-4, 1.0 %, 14 %, 58 %, 14–67 times | 3.714e-6, 5.731e-5, 4.088e-4, 1.045e-2, 0.1409, 0.5772, 67.33 |
| decibels of every stress signal against the definition in double precision, floor −80 dB | 7.3e-4 dB | 7.273e-4 dB |

The register's "about 8·10⁻⁸ of the frame maximum (E-30)" is below what is measured at the longest lengths (1.7e-7 at 16 384 points); the note already says so and gives the re-measurement, and the tests hold 2.5e-7. No correction was needed.

**Mutations** (`TransformPlans.swift`, `SpectralValueNode.swift`):

| Mutation | Result |
|---|---|
| R1-floor: the decibel floor of the value node set to −∞ | killed: 40 tests fail, 22 issues; `decibelsOfEveryStressSignalAreNumbersAtOrAboveTheirFloor` ("silence: off by 299.3 dB"), `ValueStepTests.silenceIsTheFloorAndNeverMinusInfinity`, `InversionTests.decibelsInvertWhereNoValueIsAtTheFloor` |
| R1-halving: the forward scale of ½ removed | killed: 298 issues in 24 tests, among them `theErrorOfASinglePrecisionTransformIsAFloorUnderTheFrameMaximum` (all seven lengths) and the golden vectors |
| R1-nyquist: the Nyquist bin left where vDSP packs it | killed: 112 issues; "white-noise, 80 points: off by 0.161 of the frame's largest bin"; `aConstantAndTheNyquistSignalLandInTheirBins` |
| R1-admit: the admission of the length removed from `VDSPFFTPlan.init` | killed: `anIllegalLengthIsATypedErrorAndNoSetupIsCreatedForIt` (10 cases: a setup call was made for 0, 1, 8, 18, 26, 30, 40, 1 000, 2 047) |

**Precision (NUMS-3).** Float32 on the signal path (`VDSPFFTPlan`, split-complex Float32 buffers); Double where a node asks for it (`DoubleDFT`: cepstral steps, window analysis, inversion analysis, the CQ kernel). Chosen per node when the plan is built, not at run time.

**Open.** A-24 and A-NB20 of wave 3 (m5b, WP-532 and WP-504/502): no upper bound on transform lengths (the note's hazard 4). Not fixed here: wave findings.

### Row 2: Framing (WP-203, `mirrored-ring.md`)

**Currency.** Searched on 2026-11-21: double-mapped ring buffers in current libraries (the Rust crates oneringbuf, mutringbuf and PicoRing map virtual memory twice and need a page-size multiple; iOS behaves differently from macOS), and miniaudio's discussion of the technique (issue 671). Outcome: current; the copy on wrap stays the alternative, and is the package's fall-back.

**Notes against the code.** §7.5 names "none in arithmetic; index overflow in long sessions"; the note has both, and two structural hazards besides. `ztd_ring_map_mirrored` (FIXED | OVERWRITE remap, proof loop), `ztd_ring_map_plain`, the automatic fall-back and the page-frame capacity of `ztd_ring_create`, and the 64-bit atomics of `struct ztd_ring` are in `Sources/CZTronDSP/ztd_ring.c`. One statement was too strong and was corrected: a 32-bit position would wrap after 24.8 hours at 48 kHz, but harmlessly for the ring, because every count of frames in it is a difference taken modulo 2³² and every index is a position masked by a power-of-two capacity of at most 2³⁰. What 64 bits protect is the absolute counts: the overrun count (`ztd_ring_overrun_frames`) and the framer's frame index (`Framer`, a Swift `Int`). Hazard 3 had no test; it has one now (below).

**Test added.** `RingStorageTests.aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount(storage:)`, both storages: a ring of 2²⁰ frames is taken past 2³² frames with a lap of 2²⁰ − 7 (no divisor of 2³², so every lap starts elsewhere); the lap that straddles 2³² and the one after it come out bit for bit as the non-finite fixture of WP-016 went in, a mirrored ring gives them as one view, and every count stays exact; then the full ring is given 2·(2³² − 1) frames and counts every one. Measured: 4.297·10⁹ frames through the ring, an overrun count of 8.5899·10⁹; 2.5 s for both cases in Debug.

**Mutations** (`ztd_ring.c`):

| Mutation | Result |
|---|---|
| R2-noremap: the remap and its proof removed, the second view left as the second half of the region (the note's own) | killed: 6 tests, 36 issues: `mirroredAndPlainRingsGiveTheSameResultsBitForBit` (30), `aWindowSpanningTheWrapIsContiguousAndCorrect`, the new test, two two-thread tests, the refusal test |
| R2-proof: the proof's two comparisons removed, the remap kept | survived: equivalent wherever `vm_remap` reports success only for a mirror. The proof is defence against a mapping that is reported granted and is not; no test can make the system do that without a seam in production code. Recorded as F-905a-1 |
| R2-nofallback: no fall-back for an automatic ring | killed: `theRingSurvivesEveryRefusalAndAnAutomaticOneFallsBack` |
| R2-capacity: whole pages only when the mirror is demanded | killed: 2 tests, 12 issues (`anAutomaticRingMirrorsWhenTheSystemGrantsItAndHoldsTheSameEitherWay`, the refusal test) |
| R2-counter32: the two positions 32-bit | survived: equivalent, for the reason under the corrected hazard 3; the new test, which passes 2³², passes with it |
| R2-dropped32: the overrun count 32-bit | killed, by the new test only ("every dropped frame is counted: 4294967294") |
| R2-notouch-mirror: the touch and proof loop removed | killed: `storageIsResidentAsSoonAsTheRingExists` (128 of 128 pages of each channel not resident) |
| R2-notouch-plain: the zero fill of plain storage removed | killed: the same test, plain storage (64 of 64 pages) |

**Precision (NUMS-3).** No arithmetic on samples: Float32 frames are copied bit for bit (NaN, infinities and subnormal values included); positions and the overrun count are 64-bit.

**Open.** F-905a-1 (this audit): the proof of the mirror (`ztd_ring.c`, the loop after the remap) is exercised by no test that could fail. A test would need a way to make the remap report success for something that is not a mirror. Severity: low; a seam is a design decision, not a few-line fix, so none was added.

### Row 3: IIR filtering (WP-208, WP-211; `biquad-single.md`, `biquad-double.md`, `biquad-precision.md`)

**Currency.** Searched on 2026-11-21: round-off and structures of biquad cascades at low cutoffs since 2025 (DAFx 2025 and 2026, JAES). Nothing peer-reviewed turned up: a code issue on RBJ biquads at low cutoffs (WaveSabre issue 69), unreviewed posts on state-variable filters, and a DAFx 2026 paper on time-varying all-pass filters that does not bear on the row. Outcome: current; the state-variable alternative is already CR-020 item 4.

**Notes against the code.** The hazards are §7.5's (poles near z = 1; block-size dependence; state hygiene). Symbols exist: `ztd_biquad_process_accelerate` (the aligned copy for a displaced output, `ztd_flush_state`), `ztd_biquad_process_native` in `Sources/CZTronDSP/ztd_biquad.c`; `ztd_biquad_double_process` with `#pragma STDC FP_CONTRACT OFF` and `ztd_flush_state_double` in `Sources/CZTronDSP/ztd_biquad_double.c`; `spreadingGain()`, `PrecisionMeasurement` (threshold −100 dB, the count of what is not finite) and `FilterLowering.emit` in `Sources/ZTronDSPDesign/Systems/Realization.swift`. Measured against the notes (baseline run):

| Figure | Note | Measured |
|---|---|---|
| WP-208 impulse against double, vDSP_biquad and C loop | 1.5e-6, 2.4e-7 | 1.5482e-6, 2.4192e-7 |
| noise, orders 2, 4, 6, 8, vDSP_biquad | 8.6e-6, 8.0e-6, 1.4e-5, 1.7e-5 | 8.63e-6, 8.0459e-6, 1.4209e-5, 1.6922e-5 |
| noise, orders 2, 4, 6, 8, C loop | 2.0e-6, 2.5e-6, 3.5e-6, 4.8e-6 | 2.0212e-6, 2.4642e-6, 3.464e-6, 4.7671e-6 |
| blocks of 1 and 7 against 512, impulse and noise | −115.1, −128.2, −100.3, −99.2 dB | −115.05, −128.2, −100.31, −99.2 dB |
| E-30's 90 Hz order 8, noise, blocks of 7 against 512 | −59.4 dB | −59.42 dB |
| single against double, the seven stress fixtures and the acceptance fixture | −98.4, −61.5, −33.1, −53.9, −107.6, −120.8, −94.1 dB | −98.352, −61.53, −33.136, −53.932, −107.6, −120.79, −94.129 dB (`theDeviationOfSingleFromDoubleSaysWhichFiltersNeedIt`) |
| WP-211 response error: double, C loop, vDSP_biquad | 3.4e-5, 15.9, 39.1 dB | 3.4033e-5, 15.881, 39.098 dB |
| WP-211 CLICK-1 ratio, a tenth of an octave | 1.03 | 1.0299 |
| WP-433 grid: chosen path, unseen noise, designs in single | −100.2 dB, −97.2 dB, 180 of 448 | −100.2053, −97.2234 dB, 180 of 448 |
| WP-433 one design on the three single kernels | −99.1, −111.1, −115.9 dB | −99.129, −111.138, −115.857 dB |
| WP-433 10 Hz low-pass, a step of one second | −144.5 dB | −144.500 dB |
| WP-428b stress fixtures (margin, deviation, round-off levels) | the note's table | equal: `theFiguresOfTheStressFixturesEqualTheirRecordedValues` holds them (deviation to 0.25 dB, levels to 0.01 dB) |

**Mutations:**

| Mutation | Result |
|---|---|
| R3-displaced: `vDSP_biquad` filters straight into a displaced output | killed: `theOutputDoesNotDependOnWhereTheCallersBufferLies` (18 issues), `channelsAreFilteredIndependentlyAndStateIsCarriedAcrossCalls` |
| R3-flush-accelerate, R3-flush-native: RT-6 removed from either single-precision path | killed, each: `aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind` ("a subnormal value came out of the kernel's memory") |
| R3-double-narrow: the double kernel's state rounded to Float32 | killed: 6 tests, 34 issues; `theTwentyHertzHighPassIsWithinAHundredthOfADecibelOfTheReference` fails at six frequencies, as the note says |
| R3-contract: `FP_CONTRACT ON` in the double kernel | killed in Debug: `theKernelIsItsDefinitionBitForBitForAnyBlockSizes` (hp-20Hz-96k-order8), `theKernelIsItsRecurrenceWithTheFlushWhereItsBlocksEnd` |
| R3-flush-double: RT-6 removed from the double kernel | killed: 3 tests, among them `aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind` |
| R3-spread: the cascade emitted without `spreadingGain()` | killed: `stressALowCutoffAtAHighRateRunsBecauseItsGainIsSpread` ("one second in, the step has arrived: 0.0043 where 1.0 was expected"), `aCascadeBeyondSinglePrecisionIsMeasuredAsSuchAndRunsInDouble` |
| R3-nonfinite: what is not finite no longer counted | killed: `aCascadeBeyondSinglePrecisionIsMeasuredAsSuchAndRunsInDouble` |
| R3-threshold: −90 dB instead of −100 dB | killed: `overTheGridTheChosenPathIsWithinMinus100DecibelsOfTheDoubleReference` (42 designs between −97.4 and −99.6 dB), the recorded figures, `theMeasurementIsThatOfTheKernelThePlanCreates` |

**Precision (NUMS-3).** Float32 on the single-precision paths (`vDSP_biquad`, the C loop, `vDSP_biquadm`); Double state and coefficients in `ztd_biquad_double.c`, samples Float32 at both ends. Chosen when the plan is compiled, by measurement (REAL-3, `FilterLowering.emit`), or by `.environment(\.biquadPrecision, …)`.

**Open.** A-B1 of wave 2 (WP-433): CR-018 item 1 understates the miss on noise the measurement has not seen (−97.2 dB; −90.51 dB on a step and −94.15 dB on a chirp), and the grid passes −100 dB by 0.2 dB. CR-013 items 4 (state hygiene and badly scaled cascades) and 5 (REAL-3 sends the WP-208 fixture to double precision) are Proposed.

### Row 4: IIR design (WP-404 … WP-411, WP-414, WP-418a, WP-418b; eleven notes)

**Currency.** Searched on 2026-11-21: s-to-z mappings published in IEEE Signal Processing Letters and elsewhere in 2025–2026 (only the 2025 interpolation-based mapping of J. Electrical Engineering that the first pass recorded, a 2014 second-order mapping and phase-invariant mappings), "de-cramping" of the bilinear transform at DAFx 2026 (unreviewed posts only), and the evaluation of elliptic functions for filter design (nothing beyond Orchard & Willson 1997, Lutovac, Tošić & Evans, and Orfanidis 2006). The Bessel zeros were searched on 2026-11-18 (CR-020 item 8). Outcome: current.

**Notes against the code.** The hazard is §7.5's (expanding clustered poles is ill-conditioned) in every note, with each step's own beside it. The symbols of every mitigation exist (`secondOrderSections()` and `SectionPairing`, `AnalogPrototype.butterworth`/`chebyshev1`/`chebyshev2`/`elliptic`, `powerRatioMinusOne`, `maximumOrder`, `smallestEllipticComplement`, `EllipticFunctions.landenSequence`/`degreeEquation`/`arcsine`, `BesselPolynomial.roots` with `ExtendedHorner`, `ZeroPoleGain.bilinear`, `FrequencyTransformation` and its split of the two images, the pre-warp and the edge check of `IIRDesign`). Every figure of the eleven notes was found in the baseline run, rounded as the notes round it; for instance:

| Note | Figure in the note | Measured |
|---|---|---|
| section-pairing | 1.39e-17, 1.651e-13 against 0.01683, partial-cascade peaks 0.99999999988 and 2.613 | 1.39e-17, 1.651147e-13 against 0.0168322, 0.9999999998838, 2.6131219 |
| butterworth-prototype | poles 2.5e-16; order 20 expanded 4.8e-9 | 2.4825e-16; 4.7999e-9 |
| chebyshev1 / chebyshev2 | poles 4.1e-16, gain 1.4e-15, ε read back 3.6e-16 / poles 1.7e-15, gain 3.8e-15, δ 2.3e-16 | 4.0666e-16, 1.3555e-15, 3.6372e-16 / 1.7347e-15, 3.8164e-15, 2.2863e-16 |
| elliptic-functions | K 6.4e-16, near m = 1 3.4e-15, degree equation 4.0e-14 and 7.2e-15, sn/cn/dn 6.1e-14, inverse sn 1.0e-14, inverse sc 1.2e-14 | 6.4252e-16, 3.3623e-15, 3.9679e-14, 7.2238e-15, 6.0562e-14, 1.0401e-14, 1.2405e-14 |
| elliptic-prototype | poles 2.3e-14, zeros 1.7e-14, gain 1.2e-13; orders 50 and 60 within the ripple to 7.8e-16 | 2.3147e-14, 1.7444e-14, 1.2214e-13; 6.66e-16 and 7.77e-16 |
| bessel-roots | κ at order 25 7.8e12, residual 7.8e-18 | 7.8246e12, 7.7622e-18 |
| bessel-prototype | poles 1.3e-14, gain 2.6e-13, order 25 expanded 1.1e-5 | 1.3191e-14, 2.5992e-13, 1.0944e-5 |
| bilinear-transform | 4.7e-16, 4.6e-16, 1.3e-15, coefficient form 3.2e-15; mapped back 9.5e-13; through coefficients 1.8e-2 | 4.7332e-16, 4.5776e-16, 1.2556e-15, 3.2290e-15; 9.4518e-13; 0.017551 |
| iir-design-analog | 1.4e-11, 7.2e-15, 5.4e-15 | 1.3924e-11, 7.1916e-15, 5.4210e-15 |
| iir-design-digital | 9.0e-15, 1.0e-15, 5.7e-15, sections 9.1e-15; at the band edges 5.2e-13 | 8.9967e-15, 1.0236e-15, 5.6968e-15, 9.0837e-15; 5.2231e-13 |

**Mutations** (the note's own change wherever it names one):

| Mutation | Result |
|---|---|
| R4-expanded: the poles taken through the expanded denominator before pairing | killed: 5 tests; `stressSectionsKeepThePolesThatAnExpandedPolynomialLoses` (0.016832 where 1e-9 is held) |
| R4-order: the sections in reverse order | killed: `stressTheOrderingKeepsPartialCascadesBelowThePeak`, `thePolesClosestToTheUnitCircleComeLast` (51 issues), the oracle comparisons |
| R4-pairing: a zero taken in list order, not the nearest | killed: `thePairingMatchesTheReferenceSectionForSection` (44 issues), `digitalDesignsMatchTheOracleSectionForSection` |
| R4-gain-last: the gain put into the last section | killed: `theGainGoesIntoTheFirstSection` and the two section-for-section comparisons |
| R4-butter-poly: Butterworth poles as roots of their expanded polynomial | killed: `stressButterworthPolesAreClosedFormNotRootsOfAPolynomial` (1 049 issues) and two oracle tests |
| R4-expm1: `powerRatioMinusOne` as a power minus one (shared by Chebyshev I and II and the elliptic design) | killed: `stressASmallRippleKeepsItsDigits` |
| R4-cap: the order cap raised to 1 024 | killed: `invalidOrdersAreTypedErrors`, `invalidDesignsAreTypedErrors`. (`stressTheHighestOrderIsStillRepresentable` pins order 512 and passes with it: the cap itself is held by the two tests of typed errors.) |
| R4-elliptic-refuse: no refusal below 64 ε of complement | killed: `anEllipticOrderBeyondWhatADoubleResolvesIsRejected` (orders 64, 100, 512) |
| R4-landen: the complement recomputed from the modulus at every Landen step | killed: `stressTheLandenSequenceCarriesTheComplement`, `theCompleteIntegralMatchesTheTable` and three more |
| R4-degree: the complement of the degree equation as 1 − m | killed: `stressTheDegreeEquationKeepsTheComplement`, `theDegreeEquationMatchesTheTable`, `stressAHighOrderEllipticPrototypeStaysEquiripple` |
| R4-arcsine: the logarithmic inverse sine instead of Kahan's | killed: `stressTheInverseSineOfASmallArgumentKeepsItsDigits`, `theInverseSnAndScMatchTheTable` |
| R4-bessel-double: θₙ evaluated in plain double precision | killed: 14 tests; the iteration no longer settles (`numericalFailure(routine: "besselRoots")`), as the note says |
| R4-bilinear-coeff: the zero-pole transform routed through coefficients | killed: 10 tests; `stressTheBilinearTransformOfRootsKeepsWhatTheCoefficientFormLoses` (11 issues) |
| R4-image: the smaller image formed by subtraction | killed: `stressAWideBandKeepsItsAccuracy` (8 issues) |
| R4-prewarp-float: the pre-warp in single precision | killed: 6 tests; `stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles` (47 issues) |

**Precision (NUMS-3).** Double throughout: zeros, poles and gains as `Complex` of Double, Bessel values in double-double. Design time only; nothing of this row runs on the signal path.

**Open.** Wave 1, m4a: A-2 (the bilinear gain ratio is a running product that can underflow, `Bilinear.swift`), A-3 (an underflowed gain is returned as a zero filter, `FrequencyTransformation.swift`), A-NB2 (WP-410's test checks the residual only), A-NB4 (the message of `Bilinear`), A-NB5 (WP-418b edges near 0 Hz and Nyquist). A-NB8 (the currency coverage of this row) is resolved by the supplement of 2026-11-18. Not fixed here.

### Row 5: FIR design (WP-423, WP-425; `fir-design.md`)

**Currency.** Searched on 2026-11-21: least-squares and Kaiser-window FIR design since 2025. Nothing new (MathWorks and GNU Radio material, a fractional-delay paper). Outcome: current; equiripple stays deferred (D-3).

**Notes against the code.** The hazard is §7.5's (normal equations square the condition number). Symbols exist: `LAPACK.solvePositiveDefinite` (`dposv`, `dpocon`), `LAPACK.leastSquaresBySVD` (`dgelsd`), `reciprocalConditionFloor` (1e-10) in `LeastSquaresFIR.swift`, `FIRDesign.search`, the mirroring of the windowed sinc in `FIRDesignMethod.swift`. Measured: firwin 1.1102e-15 (note 1.1e-15), firls 5.5511e-16 (5.6e-16), the gap fits 3.4694e-18 and 2.7423e-14 at reciprocal conditions 2.3e-2 and 1.8e-6 (3.5e-18, 2.7e-14), the 31-tap gap fit 2.386 times the norm of the fall-back's taps without the condition test (2.4 times), the fall-back's weighted error on the stress fixture 2.7534e-5 (2.75e-5), the golden ill-conditioned fit 1.3555e-11, 1.5086e-8 and 9.9495e-6 (1.4e-11, 1.5e-8, 9.9e-6), the reference gain at the band edges 1.7097e-14. Four rows of the note's second table (bands 0…0.3 and 0.4…0.9 at 61 and 101 taps: `rcond` 1.7e-8 and 5.9e-14, errors 2.298e-10, largest taps 1.2667 and 1.2659; the narrow gap at 31 taps: `rcond` 7.4e-18, largest taps 1 145 and 388; at 41 and 101 taps: 6.6e-11 and 2.0e-17) are printed by no test: they are the implementer's measurement of 2026-11-15, consistent with what the tests do print (the 31-tap ratios 1.0019 of the errors and 2.386 of the norms), but not reproduced here. The note now says so (finding F-905a-2).

**Mutations:**

| Mutation | Result |
|---|---|
| R5-nofallback: no `dgelsd` fall-back | killed: `stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack`, `anIllConditionedFitTakesTheFallBackAndStillMeetsTheOracle`, `bothSolversAgreeWhereTheSystemIsWellConditioned` (`numericalFailure` in `dposv`) |
| R5-nocond: no condition test | killed: `stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack` |
| R5-nomeasure: the length search returns its first estimate | killed: 5 tests, among them `stressFiltersAtTheEdgesOfTheBandAreLinearPhaseToTheBitAndReachTheirAttenuation` and `theMeasuredSlopeIsAtLeastTheOneRequested` (43 issues) |
| R5-nomirror: the windowed-sinc taps not mirrored | killed: `stressFiltersAtTheEdgesOfTheBandAreLinearPhaseToTheBitAndReachTheirAttenuation` (14 issues), `aFilterIsLinearPhaseWithUnityGainAtItsReferenceAndHalfAmplitudeAtItsEdges` |

**Precision (NUMS-3).** Double for the design (LAPACK in double precision); the taps become Float32 once, in `FilterLowering.emit(taps:)`.

**Open.** A-1 of wave 2 (m4b, WP-425): the ill-conditioned fixture is held to 1e-4 where 1e-9 was asked (measured 9.9495e-6). Not fixed here. F-905a-2 (this audit, low): four rows of the note's second table are figures no test prints; a test that measures them, or their removal from the note, is the remedy.

### Row 6: Savitzky–Golay (WP-426, `savitzky-golay.md`)

**Currency.** Searched on 2026-11-21: replacements of the Savitzky–Golay smoother since Schmid, Rath & Diebold 2022. OpenMS implements their modified-sinc smoother; a 2026 EGUsphere preprint (egusphere-2026-415) uses DCT smoothing for radar data and is not a replacement. Outcome: current; the better smoother remains CR-020 item 1.

**Notes against the code.** The hazard is §7.5's (ill-conditioned Vandermonde systems). `SavitzkyGolayFit.weights` (`dgels`, the scaled abscissa, the typed errors) is in `Sources/ZTronDSPDesign/Smoothing/SavitzkyGolayDesign.swift`. Measured: against `savgol_coeffs` 4.4569e-13 (note 4.5e-13); order 24 across 401 samples 8.8834e-16 scaled and 8.9495e-16 raw (8.9e-16, 8.9e-16), normal equations 8.4686e-8 scaled and 7.2099e-8 raw (8.5e-8, 7.2e-8). The note was right in every figure but implied that the scaling buys accuracy; on its own fixture it does not, and the note now says what it is for.

**Test added.** `SavitzkyGolayCoefficientTests.stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa`: order 84 across 10 001 samples, a well-posed fit (about 2·√window, 200 here, is what equispaced samples resolve) whose raw powers reach 5 000⁸⁴ = 10³¹⁰·⁷. On the raw abscissa the system is refused; on the scaled one the weights reproduce the polynomial fixtures of WP-016, values and slopes at the centre, to 6.2359e-15 (held to 1e-12).

**Mutations:**

| Mutation | Result |
|---|---|
| R6-normal: the fit through the normal equations (the note's own) | killed: `stressAWideWindowAndAHighOrderNeedTheOrthogonalFactorisation` |
| R6-noscale: the abscissa left unscaled | survived the tests as they were (the existing check of order 150 accepts a typed error from either route); killed by the new test alone ("Numerical failure in dgels") |

**Precision (NUMS-3).** Double for the fit (`dgels`); Float32 weights where the smoothing stage emits them as an FIR filter (`SmoothingStages.swift`).

**Open.** None.

## WP-905b: rows 7 to 12

### Row 7: FIR, short (WP-212, `fir-direct.md`)

**Currency.** Searched on 2026-11-21 with row 1: Apple's iOS 27 release notes and security content list no change to `vDSP_conv` or `vDSP_desamp`. Outcome: current. The register names no alternative.

**Notes against the code.** The hazard is §7.5's: a sum of K products, which is benign. The note adds two hazards of its own, the shape of the call and subnormal input. The symbols exist: the cells of `ZTD_FIR_CELL` frames and the aligned scratch in `Sources/CZTronDSP/ztd_fir.c`, and the cleaning in `ztd_history_accept` (`Sources/CZTronDSP/ztd_history.c`), which the rate kernels share. Measured, as a fraction of the register's bound (`theKernelEqualsOfflineConvolution`): 0.46603, 0.30055, 0.11326, 0.011483, 0.0056847, 0.0011602 and 0.00032499 for 1, 2, 5, 31, 64, 255 and 1 500 taps. The note gives 0.47, 0.30, 0.11, 0.011, 0.0057, 0.0012 and 0.00032.

**Mutations** (`ztd_history.c`, `ztd_fir.c`):

| Mutation | Result |
|---|---|
| R7-clean: the cleaning of the input removed from `ztd_history_accept` | killed: `theErrorStaysWithinTheRegistersBoundOnTheStressSignals` (8 issues: subnormal values from `denormal` and `decaying-tail`), and `subnormalInputGivesExactZeros` of the decimator and of the interpolator |
| R7-cells: `vDSP_conv` called with the block's own length | killed: `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`, all five lengths (36 issues) |

**Precision (NUMS-3).** Float32 sums in `vDSP_conv`, always in one call shape. The taps are designed in Double and rounded once to Float32 (`FilterLowering.emit(taps:)`). The precision is fixed per kernel.

**Open.** None.

### Row 8: FIR, long (WP-214, WP-215; `partitioned-structure.md`, `partitioned-processing.md`)

**Currency.** Searched on 2026-11-21: uniformly and non-uniformly partitioned convolution since 2025. Found: GPU uniform partitioned convolution (arXiv 2509.04390, 2025) and the JAES 2025 work the first pass recorded. Outcome: current. Non-uniform partitioning stays the registered alternative.

**Notes against the code.** The hazard is §7.5's: the transform floor in each partition. The notes add conventions, transform lengths, accumulation and the two paths. The symbols exist in `Sources/CZTronDSP/ztd_partitioned.c`: the kernel spectra scaled by 1/(4N) at creation, the accessor `ztd_partitioned_spectrum` that undoes the scale and carries bin B, the admission of the partition by arithmetic, the clearing of the sums, the input cleaning on both paths, and the flush of the spectra and of the tail. Measured: the kernel spectra are within 1.3154e-7 of the largest bin (note 1.3e-7). Against the direct kernel, over all block sizes, the eight cases of `theOutputIsWithinMinus100dBOfTheDirectKernel` give −120.77, −120.53, −124.29, −129.77, −130, −130.09, −134.08 and −129.53 dB, the note's table. §7.5 gives −139 dB; that distance is CR-013 item 6 (Proposed), and the notes say so.

**Test added.** `PartitionedKernelTests.subnormalInputGivesExactZerosOnBothPaths`. The stress test's filter has its smallest taps in its head, so a product of them with the `denormal` signal (64 steps of the subnormal range) is already zero, whether or not the input is cleaned. The new test uses a filter of 255 taps whose largest taps are in the head of 128. It runs the `denormal` and `decaying-tail` signals of WP-016 in whole partitions, frame by frame, in blocks of 7 and in irregular blocks. It checks that nothing subnormal comes out and that subnormal input gives exact zeros.

**Mutations:**

| Mutation | Result |
|---|---|
| R8-bin: bin B left out of what the accessor returns (the note's own) | killed: `theSpectraEqualTheTransformOfEachPartition` (34 issues), `theSpectraOfTheStressSignalsAreExactWhereTheirEnergyIs` |
| R8-clear: the sums not cleared before use (the note's own) | killed: 4 tests, among them `theStressSignalsStayWithinMinus100dBAndSilenceStaysSilent` and `theOutputIsWithinMinus100dBOfTheDirectKernel` (123 issues) |
| R8-admit: a partition admitted without being a power of two | killed: `thePartitionMustBeAPowerOfTwoFromEightUp` (24 accepted) |
| R8-scale: the stored scale one step above 1/(4N) | killed: `theSpectraOfTheStressSignalsAreExactWhereTheirEnergyIs` (the exact 32 and 1 no longer read back) |
| R8-clean: the input not cleaned on either path | survived the tests as they were; killed by the new test alone (6 issues, on the three cuts that take the direct head) |
| R8-flush-spectra: the delay line's spectra and the tail not flushed | survived, equivalent at the output. The input is already cleaned, so the flush removes only the round-off of values above 10⁻²⁰. That lies far under the −100 dB the kernel is held to and makes no subnormal value. The flush keeps the state clean (RT-6), which no output shows |

**Precision (NUMS-3).** Float32 throughout: the transforms (`vDSP_DFT`), the spectral products and the direct head. The kernel spectra are computed once, at creation. The precision is fixed.

**Open.** CR-013 item 6 (Proposed): the agreement with the direct kernel is −120.5 dB at worst, not §7.5's −139 dB.

### Row 9: Rate changes (WP-213, WP-223; `decimator.md`, `interpolator.md`)

**Currency.** Searched on 2026-11-21: decimation and polyphase interpolation since 2025. Only half-band filter crates and patents turned up. Outcome: current. Multistage half-band stays the registered alternative.

**Notes against the code.** The hazard is §7.5's: aliasing and imaging are filter leakage. The notes add the phase, the shape of the call and the gain. The symbols exist in `Sources/CZTronDSP/ztd_rate.c`: one `vDSP_desamp` per whole cell of `ZTD_DECIMATOR_CELL` outputs, outputs due when frame j·M of the cell has arrived, polyphase taps with the gain folded in, and one strided `vDSP_conv` per phase over a whole cell of `ZTD_INTERPOLATOR_CELL` frames. Measured: the alias of a full-scale tone at the old Nyquist frequency is −99.543 dB (note −99.5). The images of the interpolator are −99.584, −95.889 and −98.189 dB (note −99.6, −95.9 and −98.2). §7.5's "at least 80 dB of rejection by default" is held by `aFullScaleToneAtNyquistDoesNotAliasIntoTheBand`.

**Mutations** (`ztd_rate.c`):

| Mutation | Result |
|---|---|
| R9-lowpass: the decimator's taps replaced by a unit impulse (the note's own) | killed: `aFullScaleToneAtNyquistDoesNotAliasIntoTheBand` ("the alias is 0.0 dB"), `theOutputEqualsFilterThenSubsampleForIrregularBlockSizes` (50 issues), `latencySettlingTimeAndTheFirstFrameAreAsStated` |
| R9-gain: the gain left out of the phase taps (the note's own) | killed: `theGainIsTheFactor` (the constant at 1/L), `theOutputEqualsZeroStuffThenFilter`, `latencySettlingTimeAndResetAreAsStated` |
| R9-phase: an output due one frame later (the phase rounded down) | killed: `theOutputEqualsFilterThenSubsampleForIrregularBlockSizes`, factors 2 to 7 (80 issues: one output short, 857 for 858) |
| R9-dec-cells: `vDSP_desamp` for the due outputs only | killed: `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`, every factor (54 issues) |
| R9-int-cells: `vDSP_conv` over the block's own frames | killed: `theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes`, for a factor of 1 only (9 issues). The strided path of factors 2 to 5 rounds the same for any call length on this simulator |

The cleaning of the input is the history's, shared with row 7. R7-clean was run against these suites too and fails both `subnormalInputGivesExactZeros`.

**Precision (NUMS-3).** Float32 (`vDSP_desamp`, `vDSP_conv`). The taps are designed in Double and given as Float32. The precision is fixed per kernel.

**Open.** A-27, A-28 and A-31 of wave 3 (m5b, WP-539): the inversion report on subsampling traps for very large factors, exists only as a function, and has no round-off term. That report is §7.5's mitigation for this row. Not fixed here.

### Row 10: One-shot convolution, correlation (WP-513, `one-shot-convolution.md`)

**Currency.** Searched on 2026-11-21: FFT convolution since 2025. Found: "Permutation-Avoiding FFT-Based Convolution" (arXiv 2506.12718, 2025), a library-level optimisation of the same method. Outcome: current. This also answers A-NB3 of wave 3, which observed that the first pass's record for rows 10 and 11 had no search.

**Notes against the code.** The hazard is §7.5's: the FFT method loses small outputs beside large ones. The note adds five more hazards. The symbols exist in `Sources/ZTronDSPAnalysis/Correlation/Convolution.swift`: `OneShotConvolution.method`, which returns a forced strategy unchanged and, for `.automatic`, applies the cost model of `CrossoverTable.convolutionUsesFFT` and the partitioned method past `longestTransform`; and `run`, which refuses results past `longestResult`. Measured (`aConvolutionBelowTheCrossoverKeepsItsSmallOutputs`, against the note):

| Figure | Note | Measured |
|---|---|---|
| direct, of the sum of an output's products | 0.94 ε | 0.93535 ε |
| FFT, of the largest output the inputs can give | 6.6e-7 (`full-scale-square`, 1 tap) | 6.5565e-7 (the same case) |
| FFT, of the largest output there is | 2.0e-6 (`full-scale-sine`, 5 taps) | 2.0048e-6 (the same case) |
| outputs 180 dB under the largest, kept to half of themselves: direct, FFT | 281 of 281, 1 | 281 of 281, 1 |
| exact zeros that read something by the FFT method | 27 843 | 27 843 |
| the grid of STG-2, worst: direct, FFT, partitioned (convolution; correlation) | 1.2e-6, 2.2e-7, 4.6e-7; 1.1e-6, 2.2e-7, 3.9e-7 | 1.1969e-6, 2.1762e-7, 4.6245e-7; 1.0537e-6, 2.2183e-7, 3.8820e-7 |
| unbiased correlation of two noise fixtures of 1 024: FFT, direct | 1.07e-5, 7.6e-8 | 1.0689e-5, 7.6347e-8 |

**Mutations** (`Convolution.swift`):

| Mutation | Result |
|---|---|
| R10-method: `.automatic` always takes the FFT (the note's own) | killed: `aConvolutionBelowTheCrossoverKeepsItsSmallOutputs` (57 issues), `automaticFollowsTheCostModelOfTheTable` |
| R10-forced: a forced method overridden for large inputs | killed: `automaticFollowsTheCostModelOfTheTable`, and `CorrelationTests.theNormalisationsEqualTheirDefinitions` (the forced direct unbiased correlation no longer direct) |
| R10-split: the partitioned method never chosen past 2²² points | killed: `automaticFollowsTheCostModelOfTheTable` |
| R10-cap: the refusal of a result longer than 2²⁸ values removed | survived. A test needs inputs of 2²⁸ values, a gibibyte; none exists. Recorded as F-905b-1 |

**Precision (NUMS-3).** Float32 in and out. The method is chosen per call by `OneShotConvolution.method`, from the strategy and the crossover table (SEL-5): `vDSP_conv`, a Float32 transform, or the partitioned kernel.

**Open.** Wave 3 (m5b): A-1 and B-2 (WP-513) and A-3 and B-4 (WP-514): finite inputs whose exact result is finite, near the largest float, come back as NaN or ∞ from the transform methods. Also A-NB1 and A-NB4 (non-finite input), A-NB2 (`.same` for N < K) and A-NB23 (CR-023 item 11, the unbiased correlation by a transform). None is fixed here. F-905b-1 (this audit, low): no test exercises the refusal at 2²⁸ values in `OneShotConvolution.run`. A test that allocates a gibibyte, or a seam for the limit, is the remedy.

### Row 11: Autocorrelation (WP-515, `autocorrelation.md`)

**Currency.** Searched on 2026-11-21 with row 10. Wiener–Khinchin on a zero-padded frame is the method in use; nothing supersedes it. Outcome: current.

**Notes against the code.** The hazards are §7.5's: lag 0 below a neighbour, tiny values of the wrong sign, and wrap-around without padding. The note adds 0/0 and lags past the frame. The symbols exist: `WienerKhinchin.transformLength`, and the zeroing of lags past the frame in `autocorrelate`, in `Sources/ZTronDSPAnalysis/Nodes/WienerKhinchin.swift`; the guard at `floor` and lag 0 written as 1 in `Sources/ZTronDSPAnalysis/Nodes/AutocorrelationNode.swift`; `DSP.correlationFloor`. Measured (`theAutocorrelationOfEveryStressSignalIsLinearAndGuarded`, `theAutocorrelationByTransformEqualsTheDirectSum`):

| Figure | Note | Measured |
|---|---|---|
| frames with energy, without | 37, 26 | 37, 26 |
| a lag, of the value at lag 0 | 2.8e-7 | 2.8278e-7 |
| a coefficient | 2.5e-7 | 2.4672e-7 |
| lags that are exactly zero and read below zero | 431 | 431 |
| the Hann frame of 16 384: lag 1 under lag 0, as it is and by the transform; the coefficient at lag 1 | 2.5e-8, 7.9e-8, 0.99999994 | 2.4511e-8, 7.9473e-8, 0.99999994 |
| one-shot against the direct sum: by the transform, by `vDSP_conv` | 8.2e-8, 7.0e-7 | 8.2187e-8, 7.0079e-7 |

**Mutations** (`WienerKhinchin.swift`, `AutocorrelationNode.swift`):

| Mutation | Result |
|---|---|
| R11-padding: the transform at a fast length of the frame alone (the note's own) | killed: 10 tests; `theAutocorrelationOfEveryStressSignalIsLinearAndGuarded` (72 issues: 36 of the 37 frames with energy), `theNormalisationsAreThoseOfTheOneShotFunction` (468) |
| R11-guard: the coefficient divided whatever lag 0 holds (the note's own) | killed: `theAutocorrelationOfEveryStressSignalIsLinearAndGuarded` (the 26 frames without energy), `theNormalisationsAreThoseOfTheOneShotFunction` |
| R11-lag0: lag 0 left as a value times its rounded reciprocal | killed: `aPeriodicFixturePeaksAtItsPeriod`, `theAutocorrelationOfEveryStressSignalIsLinearAndGuarded` (coefficients off by 6.0e-8 to 1.9e-7), `theNormalisationsAreThoseOfTheOneShotFunction` |
| R11-tail: lags past the frame left as the transform gives them | killed: `theFramesEqualTheDirectSumForAnyBlockSize` (5 cases), `theTransformOfAnAutocorrelationPadsByRule` |

**Precision (NUMS-3).** Float32 transforms (`VDSPFFTPlan`, used by `WienerKhinchin`) in the node and the step. The one-shot function follows the method of row 10. The precision is fixed by the strategy.

**Open.** A-5 and B-6 of wave 3 (m5b): frames of very large values give zeros or ∞ where lag 0 is finite. A-NB3: the currency record, which the second pass of 2026-11-21 now gives a search. Not fixed here.

### Row 12: Polynomial roots (WP-402, `polynomial-roots.md`)

**Currency.** Searched on 2026-11-21: polynomial root-finding since 2025. Nothing newer than the unitary-plus-rank-one QR of Aurentz, Mach, Vandebril and Watkins (2015, 2018), which is the registered alternative. Outcome: current.

**Notes against the code.** The hazards are §7.5's: the conditioning of each root, and multiple roots. The note adds scaling and evaluation beside a root. The symbols exist in `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift`: the trailing zeros, the degree cap, `LAPACK.hessenbergEigenvalues` (`dgebal` with `JOB = 'S'`, `dhseqr`), `polish` with `ExtendedHorner` and its test of the residual, and the hook `init(balancing:polishSteps:)`. The Kahan discriminant and the order without cancellation are in `Sources/ZTronDSPDesign/Math/QuadraticRoots.swift`. Measured: Wilkinson 7.2066e-5 (note 7.2e-5), the triple root 3.8234e-6 (3.8e-6), the expanded Butterworth 0.10574 (0.106), the well-conditioned fixtures 0 (bit-exact), roots of size 1e-4 without balance or polish 1.6509 (1.65) and with balance 8.41e-14, Wilkinson without polish 9.9266e-3 (9.9e-3). The note's 0.152 and 4.8e-5, from 120-digit arithmetic, are printed by no test; the package has no multiple precision, and A-NB1 of wave 1 found five roots outside the unit circle where the note says two. One statement was corrected. "So a multiple root is left alone" read as if the polish left every multiple root unmoved. On the stored `tripleRoot`, which is exact in binary, Newton's method converges, linearly, and the polish takes the error from 8.6e-6 to 3.8e-6. The test of the residual matters where rounding has split the root into a cluster.

**Tests added and strengthened.** `PolynomialRootFinderTests.stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic` (new) rescales the triple root of WP-016 by 0.1, 0.2, …, 4.0, which rounds its coefficients and splits the root into a cluster of three. It requires that no polished root is a worse root of the polynomial than its eigenvalue and that every rescaled polynomial is found to the fixture's 1e-4: measured 6.2443e-6 at worst. It also shows the hazard: the same two Newton steps, kept whatever they do, leave the cluster rescaled by 3.3 off by 6.368e-4. `degreeTwoUsesTheClosedFormWithoutCancellation` (strengthened) gains Kahan's quadratic, 94 906 265.625x² − 189 812 534x + 94 906 268.375, with roots 1 and c/a. Its products b² and 4ac are both rounded; without their errors the discriminant is 0. The nearly double root already in the test has exact products, so it could not tell.

**Mutations** (`PolynomialRootFinder.swift`, `QuadraticRoots.swift`):

| Mutation | Result |
|---|---|
| R12-balance: no balance (the note's own) | killed: `stressBalancingRescuesABadlyScaledPolynomial` (0.895 for roots of size 1e-4), `theStrategyIsAValue` |
| R12-polish: no polish (the note's own) | killed: `stressThePolishBringsWilkinsonWithinItsAccuracy`, `wilkinsonReachesItsDocumentedAccuracy` (9.9266e-3 against 1e-3) |
| R12-keep: every Newton step kept, whatever it does to the residual | survived the tests as they were (every figure the same); killed by the new test alone (13 issues: residuals raised at the scales 2.3, 2.7, 3.3 and 3.7, and 6.368e-4 against 1e-4 at 3.3) |
| R12-origin: roots at the origin left to the eigenvalue solver | killed: `rootsAtTheOriginAreReadFromTheTrailingZerosExactly` |
| R12-cancel: the real roots of a quadratic by the textbook formula | killed: `degreeTwoUsesTheClosedFormWithoutCancellation` (the stiff quadratic off by 0.255) |
| R12-kahan: the discriminant without the errors of its products | survived the test as it was; killed by Kahan's quadratic (1.449e-8 against 1e-15) |
| R12-cap: the degree cap raised to 1 024 | killed: `theDegreeCapIsATypedError` |

**Precision (NUMS-3).** Double: the companion matrix, `dgebal` and `dhseqr`. The Newton steps evaluate p and p′ in double-double. This is design time only: a design never comes here (REAL-1), only a system given as coefficients.

**Open.** Wave 1, m4a: A-4 (`rootCondition` returns ∞ both for a multiple root and for a sum that overflows), B-1 (`DoubleDouble.swift` at 92.11 % coverage: an operator nothing calls), and A-NB1 (five roots outside the unit circle, not two, in the note's 120-digit remark). Not fixed here.

## WP-905c: rows 13 to 18

### Row 13: Constant-Q (WP-518, WP-519, WP-520, WP-521, WP-522a, WP-523; five notes)

**Currency.** Searched on 2026-11-21: constant-Q transforms of 2025–2026, real-time, invertible and multirate, in the venues of §7.3 and on arXiv. Found: Franchino, Moliner and Välimäki, "Exact Factorisation and Fast Computation of Invertible Constant-Q Transforms" (arXiv 2609.29119, eess.SP, submitted on 24 September 2026). It factorises the invertible constant-Q transform exactly, one packed Fourier transform mapped onto shorter inverse transforms per band, and reports analysis–synthesis round trips two to eight times faster than a baseline, over 30 % less peak workspace and about 130 dB signal-to-noise ratio in single precision; it streams by overlapping slices and reports no latency. It computes the registered alternative (the invertible sliced CQ, NSGT) faster. It does not replace the selected octave-recursive analysis, which is chosen for its cost per hop and its latency. Recorded as CR-020 item 9, not adopted. Also seen: a real-time invertible engine on nonstationary Gabor frames (CiCueTea, MATLAB File Exchange, 2026), software rather than a paper. Outcome: current, with one item to watch.

**Notes against the code.** The hazards are §7.5's: the kernel's sparsification (at most 0.1 % of its energy dropped), aliasing accumulated over octaves (at least 80 dB of rejection per octave), and long atoms at low frequencies. The five notes add the mirror image of an atom near 0 Hz and near the Nyquist frequency, the product's round-off, the transform's latency and the scale's thinned bands. The symbols exist: the thinning by the energy criterion, the refusal of a row that cannot keep 99.9 %, the band a halved octave reads, the centring of an atom of even length and the rounding once (`ConstantQKernel.swift`); `HalfBand.taps`, the priming zeros, the lags and the rule of the hop (`ConstantQSchedule.swift`); `SparseKernelProduct.multiply`, the node's refusal of a kernel for another transform length, the order of the octaves, the time stamps and the reset (`Nodes/ConstantQNodes.swift`); the projection with its squared weights (`ConstantQProjection.swift`); the frame check, the order rule and the dense crossover (`Steps/ConstantQScale.swift`). To quote what the tests measure, they now print their figures ("measured WP-518" to "measured WP-523"); no expectation was changed. Measured against the notes:

| Figure | Note | Measured |
|---|---|---|
| octave 6 of the defaults, sparsity 0.01, at 22.05, 44.1 and 48 kHz: entries kept, of all; the least share of a row's energy kept | 383 of 11 556, 383 of 23 076, 364 of 23 076; 0.999 9565, 0.999 9554, 0.999 9539 | the same |
| entries at 48 kHz for sparsities 0, 0.001, 0.01, and 0.05 up | 18 468, 1 042, 364, 209 (a share of 0.999 0010) | the same |
| an atom's energy at negative frequencies: Blackman–Harris, Hann, Hamming | 3.4e-11, 7.3e-9, 5.7e-5 | 3.36e-11, 7.28e-9, 5.72e-5 |
| the corners of `StressFixture.filtersNearZero`: the lowest atom; the least share kept | 27 434 to 987 622 samples; at least 0.999 | 27 434, 246 906, 987 622, 226 845; 0.999 002 to 0.999 24 |
| the kept entries against their values by the definition, summed in double precision (new test) | rounded once | within 0.499 69 of a unit in the last place, 2 876 parts |
| the half-band: taps; pass band; stop band; Σ\|h\|; the sum of the taps | 53; 0.000 84 dB; 80.38 dB; 1.6293; 1 within 2.2e-16 | 53; 0.000 8417 dB; 80.376 dB; 1.6293; 1 within 2.2e-16 |
| a tone through one decimator at 0.6, 0.7, 0.8, 0.9 and 1.0 of the Nyquist frequency | −92.1, −118.9, −105.3, −96.8, −103.0 dB | −92.09, −118.92, −105.27, −96.76, −102.96 dB |
| a tone that would fold onto a bin of a lower octave, through the transform | −94.06 dB | −94.06 dB |
| six decimators: `nyquist`; `full-scale-sine` and `full-scale-square` at the fifth | −94.8 dB; −95.8 and −101.9 dB | −94.77 dB; −95.76 and −101.93 dB |
| the half-band designed for a stop band from 0.5 | 103 taps | 103 taps |
| the product, the worst row in ε·T: square, white noise, sine, decaying tail, impulse | 0.78, 0.51, 0.18, 0.18, 0.16 | 0.7807, 0.5121, 0.1817, 0.1819, 0.157 |
| tones at bin centres: the highest octave at 22.05, 44.1 and 48 kHz; all 252 bins | 0.008 dB | 0.0077, 0.0078, 0.0089 dB; 0.0112 dB (corrected) |
| the fixtures at sparsity 0.01, of the largest magnitude: music, speech, variable-Q, top octave | 0.46, 0.86, 0.69, 0.49 % | 0.4627, 0.864, 0.693, 0.491 % |
| the same with nothing dropped | 0.18, 0.81, 0.47, 0.0014 % (the kernel's note: "within 0.5 %") | 0.183, 0.813, 0.472, 0.00144 % (the kernel's note corrected to 0.82 %) |
| the stress signals against the definition, of their peak | 0.36 to 1.7 % | 0.359 % (`full-scale-square`) to 1.68 % (`dc`) |
| `denormal`, absolutely | one unit of the least subnormal | 3.42e-45, 2.4 units of 1.4e-45 (corrected) |
| the longest atoms of the library | within 0.0061 dB | within 0.0061 dB |
| latency at 22.05, 44.1 and 48 kHz | 18 919, 36 263, 39 335 samples | the same |
| the scale against the dense projection in double precision: music; speech | 3.1e-7, 2.4e-7; 2.5e-7, 2.1e-7 | 3.09e-7, 2.44e-7; 2.55e-7, 2.09e-7 |
| the scale's worst band on the stress signals | 4.6 ε | 4.64 ε (`full-scale-square`, Accelerate, magnitudes) |

`sparse-kernel-product.md` was qualified in two places, both from wave 3: "under one ε of the terms in every row" is a measurement on one kernel (other kernels reach 3.58 ε·T, inside the bound; backlog B-4 of m5c, lens A), and "the transform of finite samples is finite" holds only while it does not overflow (B-7 of m5c, lens B, open; BL-4).

**Tests added.** `ConstantQStabilityTests.everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary`: at every corner of `StressFixture.filtersNearZero`, every part of every kept entry is within half a unit in the last place of its value by the definition, a direct DFT of the atom summed in double precision in the test (worst 0.499 69, 2 876 parts). `ConstantQKernelTests.aKernelForAnotherTransformLengthIsRefusedBeforeAProductIsMadeOfIt`: the node built with a kernel for twice its transform length is refused, with the length named. `ConstantQStabilityTests.theTransformOfTheNonFiniteFixtureIsThatOfTheSignalWithItsValuesReplaced`: on `StressFixture.nonFiniteSignal`, every coefficient is a number and every frame is that of the signal with its three values replaced, bit for bit.

**Mutations** (`ConstantQKernel.swift`, `ConstantQSchedule.swift`, `ConstantQNodes.swift`, `ConstantQProjection.swift`, `ConstantQScale.swift`, `ztd_history.c`, `OfflineRunner.swift`):

| Mutation | Result |
|---|---|
| R13-energy: the energy test removed from the thinning | killed: `aKernelKeepsItsEnergyAtEveryCornerOfTheStressLibrary` (18 issues), `aRowKeepsItsEnergyWhateverTheSparsityAsksFor` (a row keeps 0.85 of its energy at sparsity 0.3, 0.29 at 0.9) |
| R13-whole: the energy taken from the one-sided magnitudes, not the whole atom | killed: 5 tests, among them the stress test and `theSparseKernelIsTheDenseKernelWhereItKeepsIt` (a stated share off by 4.9e-9 against 1e-9) |
| R13-refuse: a row that cannot keep 99.9 % accepted | killed: 5 tests, among them `aRowThatCannotKeepItsEnergyIsRefusedAndTheErrorSaysWhy` and `aBinTheFrameDoesNotResolveIsRefusedAndTheErrorNamesTheFrameThatWould` |
| R13-band: the band a halved octave reads opened to its whole spectrum | killed: 4 tests, `withoutSparsityTheKernelIsTheDenseKernelOverTheBandItReads` with 3 074 issues |
| R13-centre: an atom of even length centred half a sample off | killed: 6 tests, among them `aKernelIsTheTransformOfItsAtoms` (20 issues) and `thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` (79) |
| R13-double: the kernel rounded twice, to single before the scaling by 1/N | survived the tests as they were (a unit in the last place at most, under their 1e-6); killed by the new rounding test alone (198 of 752 and 163 of 720 parts are not their value rounded once) |
| R13-halfband: the 53-tap half-band replaced by three taps | killed: 8 tests, 150 issues (the stop band 9.2 dB down; 252 bins off by 1.12 dB) |
| R13-primes: the priming zeros removed | killed: 4 tests, `everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples` with 221 issues |
| R13-delays: the lags left out of the schedule | killed: 7 tests, 2 428 issues |
| R13-hop: a hop that cannot halve from octave to octave admitted | killed: `theHopHalvesFromOctaveToOctaveAndAHopThatCannotIsRefusedWithTheNearestThatCan`, `theStepRefusesAnIllegalHopWhenThePipelineIsAttachedAndNamesTheStage` |
| R13-phase: the decimator's phase dropped at every call | killed: 13 tests, 936 issues, among them `aDecimatorDoesNotDependOnHowItsInputIsCutAndStartsAgainAfterAReset` |
| R13-sign: `a·y − b·x` for the imaginary part of the product | killed: 9 tests, 850 issues |
| R13-rowend: a row of the product ending one entry early | killed: 7 tests, 591 issues |
| R13-kernel-length: the node's refusal of a kernel for another transform length removed | survived the tests as they were (the strategy only makes kernels for the transform it runs); killed by the new refusal test alone ("a kernel for 480 points on a transform of 240") |
| R13-order: the octaves written in the wrong order | killed: 6 tests, 256 issues |
| R13-stamp: frames stamped without the block's origin | killed: `aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore`, `theFramesDoNotDependOnTheBlockSize` |
| R13-reset: the histories kept over a reset | killed: `afterAColdStartTheFramesAreThoseOfAFreshStream` |
| R13-clean: subnormal input left in the decimators' history (`ztd_history.c`) | killed: `noStressSignalAliasesThroughTheDecimators` (`denormal`, depths 2 to 5) |
| R13-num1: non-finite samples not replaced where the signal enters (`OfflineRunner.swift`) | survived the constant-Q tests as they were (none fed such a sample); killed by the new test on the non-finite fixture alone |
| R13-frame: a scale whose longest atom does not fit the frame accepted | killed: `aBinTheFrameDoesNotResolveIsRefusedAndTheErrorNamesTheFrameThatWould`, `theBandsOfEveryStressSignalAreSumsOfNonNegativeTerms` |
| R13-rule: the scale's order rule opened to every kind of value | killed: three tests of the rule |
| R13-select: the dense product never chosen | killed: `theNodesGiveTheProjectionInDoublePrecisionAndAgreeWithEachOther` |
| R13-square: the weights of powers left unsquared | killed: `aBandIsTheResponseOfItsAtomAroundItsCentre` (61 issues), `thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` (115) |
| R13-run: the weights under the threshold zeroed inside a band's run | killed: `aBandIsTheResponseOfItsAtomAroundItsCentre` (60 issues) |

The logs are `.build/logs/m9-registers/batch-row13.log` and, for the three mutations made again against the new tests, `batch-row13b-15.log`. Hazard 4 of `constant-q-transform.md` (the rounding of atom lengths by the recursion) has no code to remove: it is accepted and measured.

**Precision (NUMS-3).** Float32 in the hot loop: the transform of each octave (`VDSPFFTPlan`), the sparse product (`SparseKernelProduct.multiply`, Float32 sums of a dozen terms) and the half-band decimators (the rate kernel of row 9). The kernel and the scale's weights are computed in Double and rounded once to Float32 when the plan is built. The strategy (`MultirateSparseKernelStrategy`) fixes the precision; the scale's banded or dense product is chosen when the plan is compiled, from the crossover table (SEL-5).

**Open.** Wave 3, m5c, not fixed here: A-6 and B-7 (a finite sample near the largest float gives NaN through the transform), A-11 and B-10 (the scale's sums overflow on finite spectra); A-4, A-5 and B-5 (the rule of the hop: an overflow in the suggestion near `Int.max`, and no legal hop from 26 octaves); A-10 and B-9 (the scale's arithmetic on a bin count overflows); B-8 (`ConstantQProjection.swift` at 96.15 % coverage); the backlog items B-4 (one ε against 3.58 ε·T, now in the note), B-6 and B-8 (the latency, CR-022 item 2), BL-4 (the note's claim of finiteness, now qualified) and BL-6 (SEL-6 asserted at 10⁻⁴). The documentation findings A-3, A-7, A-8, A-12, B-4, B-6 and B-11 (VIS-2) are outside the register. CR-020 item 9 is new.

### Row 14: Onset envelope (WP-525, `onset-strength.md`)

**Currency.** Searched on 2026-11-21: onset detection functions of 2025–2026 (spectral flux, low latency, SuperFlux) in ISMIR and DAFx. Nothing new: the results are reference implementations of SuperFlux (Essentia, librosa), which is the selected method (Böck and Widmer 2013), and older work. Outcome: current.

**Notes against the code.** The hazard is §7.5's: differences of logarithms amplify the noise floor. The note adds the round-off under the transform's floor, an empty band, and the first frames. The symbols exist: the floor raised by `vDSP_vthr`, the comparison with the reference of `lag` frames before, the maximum filter (`vDSP_vswmax`), the first `lag` frames written without a value, the reset, and the guard of a mean that is not finite (`Nodes/OnsetStrengthNode.swift`); the refusal of a floor that is not finite and the order rule (`Steps/OnsetStrength.swift`). Measured (`theOnsetStrengthOfEveryStressSignalIsBoundedByItsFloor`, `theOnsetStrengthOfTheFixturesEqualsTheReference`):

| Figure | Note | Measured |
|---|---|---|
| every stress signal at full scale, floor −80 dB: off the definition in double precision; the largest value | 4.8e-8 dB; 1.35 dB | 4.768e-8 dB; 1.3454 dB |
| every stress signal 180 dB down | 0 in every frame | 0 in every frame |
| white noise 180 dB down under a floor of −1 000 dB; at full scale | 0.80 dB a frame; 0.80 dB | 0.8010 dB; 0.8010 dB (now printed) |
| against the reference, floors −80, −20, 0 and +10 dB | within 1.6e-7 of the largest value | 1.598e-7 (`music-lag3-max5-floor10`) |

One statement was corrected. The note said that a mean "that is not a number, which only levels that are not numbers can give" is written as 0 with confidence 0. The guard is on a mean that is not finite. The new test measured what gives one: a NaN level, which `vDSP_vthr` passes through instead of raising it to the floor, in its own frame and in the frame `lag` later that is compared with it; and a band rising to +∞. A level of −∞ is raised to the floor like any level under it.

**Tests added.** `OnsetStrengthTests.aLevelThatIsNotFiniteNeverGivesAValueThatIsNot`: `StressFixture.nonFiniteSignal` read as levels of −50 to −30 dB in frames of eight bands, handed to the step by a stage of the tests' own (the entry of a pipeline replaces samples, not frames), with lag 1 and with lag 2 and a maximum over three bands. Every value is finite and not negative; the frame holding the NaN, the frame compared with it and the frame in which a band rises to +∞ carry no value (0, confidence 0); every other value is that of the same levels with −∞ and the NaN at the floor and +∞ at the largest float. Measured: with lag 1 frames 9, 10 and 21 carry no value, with lag 2 frames 9, 11 and 21; the frame holding −∞ has its value (2.59 and 0.88 dB, confidence 1); no other value differs.

**Mutations** (`OnsetStrengthNode.swift`, `OnsetStrength.swift`):

| Mutation | Result |
|---|---|
| R14-floor: the floor lowered to −∞ (the note's own) | killed: `theOnsetStrengthOfEveryStressSignalIsBoundedByItsFloor` (59 issues), `theOnsetStrengthOfTheFixturesEqualsTheReference` (5), `valuesUnderTheFloorAreRaisedToItFirst` (3) |
| R14-finite: a floor that is not finite admitted | killed: `nonsenseIsRefusedWhenThePipelineIsAttached` |
| R14-first: the first `lag` frames given a value | killed: 4 tests, 30 issues |
| R14-reset: the count of frames kept over a reset | killed: `aColdStartForgetsTheFramesItComparedWith` |
| R14-nan: a mean that is not finite written as it is, with confidence 1 | survived the tests as they were (none handed the step a level that is not finite); killed by the new test alone |
| R14-rule: the order rule opened to magnitudes | killed: three tests of the rule (`theRuleOfTheDescriptionIsTheRuleOfTheTypes`, `tierTwoAcceptsExactlyWhatTheTypesAccept`, `aDisagreementBetweenTheTiersIsSeen`) |

**Precision (NUMS-3).** Float32 throughout: `vDSP_vthr`, `vDSP_vsub`, `vDSP_meanv` and `vDSP_vswmax` in `OnsetStrengthNode`; the floor is narrowed to Float32 when the step is lowered. One implementation; nothing is chosen.

**Open.** Wave 3, m5b, not fixed here: A-10 (a floor of 3.5e38 and more is accepted, becomes +∞ in Float32, and every confidence becomes 0); A-11 and B-9 (VIS-2).

### Row 15: Tempogram (WP-526, WP-527; `tempogram.md`)

**Currency.** Searched on 2026-11-21: tempograms and tempo estimation of 2025–2026 in ISMIR. Found: a differentiable predominant local pulse (dPLP, from Müller's group at the AudioLabs Erlangen, ISMIR 2025), which builds on the Fourier tempogram rather than replacing it. The cyclic tempogram stays the registered alternative. Outcome: current.

**Notes against the code.** The hazards are §7.5's: 0/0 on silence, and a mean that swamps the tempo rows. The note adds lag 0 and its neighbours, a pedestal and the transform's floor. The symbols exist: the mean removed and the window function applied, and the replacement of a value that is not finite (`TempogramNode`); the guard at lag 0 and the lags in the range (`AutocorrelationTempogramTransform`); the bins in the range (`FourierTempogramTransform`), all in `Nodes/TempogramNodes.swift`. Measured (`theTempogramOfEveryStressCurveShowsWhatMovesAndNothingElse`, `TempogramTests`):

| Figure | Note | Measured |
|---|---|---|
| a pedestal of 1 000 times the curve's largest value, against the curve without it | within 3.7e-5 | 3.7193e-5 |
| the largest coefficient of any curve | at most 0.985 | 0.98402 |
| `full-scale-square`: the largest row | lag 48, 117.19 BPM | lag 48 (asserted) |
| `silence`, `dc`, `denormal` | exact zeros, 641 columns each | the same (asserted) |
| against the reference: the least frame-wise cosine similarity; the largest difference | 0.99999999998; 6.4e-7 of the largest value | 0.99999999998682; 6.363e-7 |

One statement was made exact: "a value of the curve that is not a number is taken as 0" now says "not finite"; the code replaces NaN and both infinities.

**Tests added.** `TempogramTests.aValueOfTheCurveThatIsNotFiniteIsTakenAsZero`: `StressFixture.nonFiniteSignal` as a curve of 1 024 values, handed to the step by a new stage of the tests' own (`CurveAsNovelty` in `FrameSupport.swift`), since the entry of a pipeline replaces non-finite samples. Four tempograms (both methods, causal and centred): 2 948 columns, every value finite, and every column that of the curve with its three values at 0, bit for bit.

**Mutations** (`TempogramNodes.swift`):

| Mutation | Result |
|---|---|
| R15-mean: the mean left in the window (the note's own) | killed: 5 tests, among them the stress test (1 289 issues) and `silenceAndACurveThatDoesNotMoveGiveZeros` (436) |
| R15-guard: lag 0 divided whatever it holds (the note's own) | killed: the stress test (3 146 issues: coefficients of NaN for `silence`, `dc`, `denormal`, `impulse`), `silenceAndACurveThatDoesNotMoveGiveZeros` |
| R15-rows: lags 0 to 2 kept among the rows | killed: 6 tests, among them the stress test (642 issues) and the golden comparisons |
| R15-bins: bin 1 kept among the Fourier rows | killed: 5 tests, among them `nonsenseIsRefusedWhenThePipelineIsAttached` and the golden comparisons |
| R15-nan: a value that is not finite taken into the window as it is | survived the tests as they were (none handed the step such a value); killed by the new test alone |

**Precision (NUMS-3).** Float32: the mean and the window function (`vDSP_meanv`, `vDSP_vsadd`, `vDSP_vmul`) in `TempogramNode`, the autocorrelation by a Float32 transform (`WienerKhinchin`, row 11) and the Fourier rows by a Float32 transform (`FFTPlan`). Fixed per method; nothing is chosen at run time.

**Open.** Wave 3, m5b, not fixed here: A-12 (the autocorrelation tempogram of a curve scaled by 10²⁰ or the largest float gives ±∞ where the coefficients do not depend on the scale) and A-14 (the Fourier tempogram of such a curve is NaN: the mean overflows); A-13, A-15, B-10 and B-11 (VIS-2).

### Row 16: Median filtering (WP-219, WP-528, WP-529, WP-530, WP-531a, WP-610; six notes)

**Currency.** Searched on 2026-11-21: fast median filters by sorting networks and SIMD, and median-based harmonic–percussive separation, 2025–2026. Found: Adams' separable sorting networks of 2021 (CR-020 item 2 already, with its patent); a 2025 preprint of a data-oblivious selection network that runs in registers (seen in the first pass); mappings of sorting networks to vector lanes with NEON minima and maxima, and to CUDA, which is what the package does. For the separation, the median filtering of Fitzgerald (DAFx 2010) is still what the libraries implement. Outcome: current; nothing to add to CR-020.

**Notes against the code.** The hazard of §7.5 (no arithmetic; ties and non-finite values) is the one each note names, and the notes add what a stream adds: edges, lanes left as the network leaves them, the quotient of the masks, the history of a stream, the resynthesis of a masked first frame, and subnormal values on a GPU. The symbols exist: the rule of IEEE 754-2019 in `ztd_lane_exchange.c`; Batcher's network and its pruning (`MedianNetwork.sorting`, `pruned`); `reflectedIndex`, the lanes filled anew and the copy before the write (`MedianKernels.swift`); the zero-denominator rule, the ratio taken first, the residual held at 0 and the validation (`MaskStrategy.swift`, `HarmonicPercussiveNode.swift`, `Steps/HarmonicPercussive.swift`); the cold start, the look-ahead as a delay line and the framing of the recipe (`HarmonicPercussiveNode.swift`, `Recipes/HPSS.swift`); the integer keys and the reflection of the GPU kernel (`Median.metal`). Measured:

| Figure | Note | Measured |
|---|---|---|
| the stress library: medians bit for bit; subnormal; −0 (`median-lanes.md`) | 741 312; 14 288; 6 739 | the same ("measured stability row 16") |
| exchanges a frame, 3, 17, 31 and 63 lanes | 3, 70, 152, 439 | the same |
| medians of single filters equal to the oracle | 1 074 960 | 232 560 along frequency and 842 400 along time ("measured WP-529"): 1 074 960 |
| exchanges kept after pruning, 3, 5 and 9 lanes (`median-network.md`) | 3; at most 9; at most 26 | asserted by `theNetworkIsPrunedToWhatTheMedianNeeds` |
| elements of seeded spectrograms equal to the oracle on the GPU (`median-metal.md`) | 228 120 | 228 120 |
| pairs of shares; their largest error; exact zeros; bins lost at 2⁻⁷⁰ (`separation-masks.md`) | 1 071 144; 2.3e-7; 588 888; 41 919 | 1 071 144; 2.2504e-7; 588 888; 41 919 |
| against the reference: soft masks; hard masks | within 5.5e-5; equal on every bin above −60 dB | 5.51e-5; 100.0 % of 85 454 bins |
| the separation: components against the bin; the harmonic part; the largest sample (`harmonic-percussive.md`) | 8.0e-8 (0.7 ε); 1.4e-7; 1.02 times | 7.9976e-8; 1.3704e-7; 1.01934 times |
| `HPSS`: the three components against the signal | 138.6 to 139.3 dB | 138.647 to 139.311 dB |
| the recipe framing causally: peaks of `full-scale-sine`, `full-scale-square`, `white-noise` | 3.1 and 3.4; 4.5 and 3.5; 489 times | 3.10 and 3.36; 4.55 and 3.55; 488.8 and 489.1 times (with the mutation in place) |

The timings of `lane-exchange.md` are host figures recorded for WP-611b and were not measured again. One statement was wrong: with the zero-denominator rule removed, `separation-masks.md` said, the soft masks are not numbers where both medians are zero, and neither are the samples `HPSS` returns. The quotient's own rule for a ratio without a value gives one half instead: the mutation made again gives shares of 0.5 in the same 14 877, 14 364 and 7 308 pairs a setting, and the samples of `HPSS` stay numbers no larger than the signal's. The paragraph is corrected. The pruning test of `MedianNetworkTests` shows that pruning again changes nothing, which `median-network.md` reads as "every exchange that is kept is one the median depends on"; wave 2 recorded that idempotence alone does not show that (m5a, backlog B-12 of lens B), and the audit paragraph of the note says so.

**Tests added.** None: a change to every mitigation fails a test of the row. The masks' tests were added to the reflection mutation's run, since `median-lanes.md` says they fail with it.

**Mutations** (19):

| Mutation | Result |
|---|---|
| R16-lane-rule: the scalar exchange a plain compare-and-swap (`lane-exchange.md`'s own) | killed: `theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers` (9 issues) |
| R16-drop: the first exchange of the pruned network dropped (`median-network.md`'s own) | killed: 9 tests, among them `theMedianOfEveryStressSignalIsTheSortedMiddle` (13), `everyZeroOneInputPutsTheMedianOnItsLane` (7) and `randomDataGivesTheSortedMiddle` (192) |
| R16-prune: the network left unpruned | killed: `theNetworkIsPrunedToWhatTheMedianNeeds` (28 of 28 exchanges kept for 9 lanes) |
| R16-reflect: the missing lanes of a start taken from the oldest frame (`median-lanes.md`'s own) | killed: four tests of `MedianKernelTests`, the stress test (236 issues), `theCausalStepEqualsTheOfflineMediansOnInteriorFrames` (123) and the stress test of the separation; run again with the masks' tests, `theMasksOfEveryStressSpectrogramAreSharesAtAnyLevel` (31) and `theMasksOfTheFixturesEqualTheReference` (4) |
| R16-freqpad: a frame padded with its edge bin instead of its reflection | killed: the stress test (152), `theMedianAlongFrequencyEqualsTheOracle` (80), `aWholeSpectrogramOnCPULanesEqualsTheOracle` (28) |
| R16-refill: the lanes not filled anew for every frame | killed: the stress test (152), `aFilterAlongTimeIsTheCentredMedianHalfAKernelLate` (132), `theMedianAlongTimeEqualsTheOracle` (80) |
| R16-inplace: the medians written before the frame is copied into the lanes | killed: `aFilterMayWriteWhereItRead` |
| R16-num1: the replacement of non-finite samples in `OfflineRunner` removed | killed: the stress test's pipeline on `StressFixture.nonFiniteSignal` (2 issues) |
| R16-zero: the zero-denominator rule removed (`separation-masks.md`'s own) | killed: the masks' stress test (72), `whereNeitherMedianReachesTheFloorBothMasksAreZero` (4), `marginsLeaveAResidual` (5), the stress test of the separation |
| R16-ratio: the powers taken before the quotient (`separation-masks.md`'s own) | killed: the masks' stress test (48), `noShareIsEverNotANumber` (9), `theHardMaskIsTheLimitOfTheSoftOne` (2) |
| R16-residual: the residual not held at 0 | killed: `theThreeComponentsAddUpToTheSpectrum` (3 111) |
| R16-validate: margins from 0 to 1 admitted | killed: `nonsenseIsRefusedWhenThePipelineIsAttached`, `whatMakesNoSeparationIsRefused` |
| R16-reset: the filter along time kept over a reset (`harmonic-percussive.md`'s own) | killed: `aColdStartRefillsTheHistoryOfTheMedian` (4), the stress test of the separation (the four signals the note names) |
| R16-both: the mask applied to the real part alone | killed: six tests, among them `onAComplexSpectrumTheMaskIsAppliedAndThePhaseKept` (3) and the stress test of the separation (7) |
| R16-framing: the recipe framing causally whatever the median (`harmonic-percussive.md`'s own) | killed: five tests, among them the stress test of the components (6), `theComponentsReconstructTheInput` (8) and `theRecipeIsItsExpansion` (3) |
| R16-silence: a centred step on a complex spectrum writing nothing while its first frame waits | killed: four tests, among them the stress test of the components (33) and `theLatencyIsOneFrameLessAHopPlusTheLookAhead` |
| R16-gpu: `.metal` admitted for a live frame | killed: `aLiveFrameIsFilteredOnCPULanesWhateverTheStrategy` and two refusal tests |
| R16-keys: each value through one float operation before its key is made (`median-metal.md`'s own) | killed: `tiesAndSubnormalValuesAreTheOraclesToo` (15: 672 subnormal medians along time and 192 along frequency for a kernel of 31, and the order of the zeros) |
| R16-mirror: the GPU's reflection off by one | killed: six tests, `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms` with 73 issues |

**Precision (NUMS-3).** No arithmetic in the medians: Float32 lanes ordered by the lane exchange, FMIN and FMAX four lanes at a time on arm64 or `vDSP_vmin` and `vDSP_vmax`, bound when the filter is made (SEL-3); on the GPU, unsigned integer keys of the float bits. The masks in Float32 (`vDSP_vdiv`, `vDSP_vsq`, `vvpowsf`, `vDSP_vthr` in `MaskStrategy`, `vDSP_vmul` and `vDSP_zvabs` in `HarmonicPercussiveNode`); the margins and the floor are narrowed to Float32 when the step is lowered. CPU or GPU is chosen by the `MedianStrategy` when the plan is built, and a live frame is always filtered on the CPU (GPU-1).

**Open.** Wave 3, m5b, not fixed here: A-16 and B-13 (traps of `MedianOracle` for huge counts and kernels); A-18, A-20 and B-20 (accepted Double parameters narrowed to Float32: a power, the margins, the floor); A-21 and B-17 (`vDSP_zvabs` and the product of a median by its margin overflow near the largest float); B-18 (quotients of subnormal medians); A-24 and A-25 (the recipe traps at 2⁴⁰ samples and gives NaN at 10³⁰); B-15 (RT-7 on `HardMask.mask`); B-16 (a strategy's members called on the analysis thread, §5.11.1); A-17, A-19, A-22, A-23, A-26, B-12, B-14, B-19 and B-21 (VIS-2); backlog A-NB5, A-NB6, A-NB18, BL-1, BL-3, BL-4, BL-5, BL-11 and BL-14. Wave 2, m5a, backlog B-12 of lens B (the comment on the pruning test claims more than it asserts).

### Row 17: Spectral centroid (WP-507, `spectral-centroid.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers a definition): the spectral centroid and frames without energy in audio feature work of 2025–2026. No new method: implementations still leave silent frames out, add an epsilon or smooth, and a 2026 benchmark of audio descriptors leaves silent frames out of its statistics. Outcome: current.

**Notes against the code.** The hazard is §7.5's (a ratio with a small denominator); the note adds weights that are not energies and the round-off of the two sums. The symbols exist: the floor, the guard on the sum and the guard on the result, and the last value with confidence 0 (`SpectralCentroidNode`); the ramp in Double, Core's `Vector` bound when the plan is compiled, the order rule and the refusal of a negative floor (`Steps/SpectralCentroid.swift`). Measured (`theCentroidOfEveryStressSignalIsAFrequencyOrNothing`, which now prints the table):

| Figure | Note | Measured |
|---|---|---|
| `white-noise`: the largest error; of the centroid | 1.7e-3 Hz; 1.4e-7 | 1.7496e-3 Hz; 1.4220e-7 |
| `nyquist` | 4.2e-4 Hz; 1.7e-8 | 4.1607e-4 Hz; 1.7348e-8 |
| `full-scale-square` | 2.8e-4 Hz; 4.6e-8 | 2.7600e-4 Hz; 4.6457e-8 |
| `full-scale-sine` | 2.5e-4 Hz; 2.5e-7 | 2.5020e-4 Hz; 2.5114e-7 |
| `decaying-tail` | 4.3e-6 Hz; 1.0e-9 | 4.3066e-6 Hz; 1.0113e-9 |
| `dc` | 1.2e-6 Hz; 7.9e-8 | 1.2289e-6 Hz; 7.8621e-8 |
| frames with a centroid; without | 146; 115 | 146; 115 |

Two statements were made exact: the guard on the sum refuses one that is not finite, not only one that is not a number; and "one to two ε of the centroid" is at most 2.1 ε (`full-scale-sine`).

**Tests added.** `StabilityTests.theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing`: each signal of `StressFixture.signals` read as a spectrum of 513 magnitudes and scaled by 2⁰, 2⁴⁰, 2⁸⁰, 2¹⁰⁰, 2¹¹⁰, 2¹¹⁶, 2¹²⁰ and 2¹²⁶. Every value is finite; a confident centroid is that of the unscaled weights in double precision within 8 ε of Nyquist, and 35 of 35 are bit for bit those of the unscaled weights; a frame without one repeats the last value with confidence 0. In 10 frames the weighted sum is past the largest float while the sum of the weights is not; the frames that lose their centroid are 0, 0, 0, 0, 5, 5, 5 and 6 at the eight scales. `SpectralCentroidTests.theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce`: 361 frames, each with its weight in one bin of 361 bins 66.67 Hz apart; each centroid is the bin's frequency rounded once, 361 of 361, where rounding the width first would move 151.

**Mutations** (`SpectralCentroidNode.swift`, `SpectralCentroid.swift`):

| Mutation | Result |
|---|---|
| R17-floor: the floor dropped from the guard, "the sum is a number" left (the note's own) | killed: `silenceHasNoCentroid`, the stress test (6 issues: the six signals with energy, 180 dB down) |
| R17-last: 0 written instead of the last value | killed: `silenceHasNoCentroid`, the stress test (28) |
| R17-rule: the order rule opened to every kind of value on a linear axis | killed: `aWrongOrderIsRefusedOnTheDescriptions` (3), `theRuleOfTheDescriptionIsTheRuleOfTheTypes` (2) |
| R17-nonfinite: a result that is not finite written with confidence 1 | survived the tests as they were (no test overflowed a sum); killed by the new scaled test (22 issues: +∞ with confidence 1 for `white-noise`, `nyquist` and `full-scale-square` at 2¹¹⁰ and 2¹¹⁶) |
| R17-ramp: the ramp rounded twice, `Float(k) · Float(width)` | survived: every width the tests used is a float, and there the two roundings agree; killed by the new single-bin test (bins 5, 10, 13, 15, … not their frequency rounded once) |

**Precision (NUMS-3).** Float32: the sum and the dot product against the ramp, by Core's `Vector`, bound to their implementation for the bins of the range when the plan is compiled (SEL-3); the ramp computed in Double and rounded once; the floor narrowed to Float32 when the step is lowered.

**Open.** Wave 2, m5a, backlog B-14 of lens B: no benchmark is recorded for the step (PERF-1 asks for one only behind a performance claim, and the row makes none).

### Row 18: Mel conversion (WP-508, WP-535; `mel-filter-bank.md`, `mel-projection.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers a definition in two published formulas): alternatives to the triangular mel filter bank in 2025–2026. No paper proposes one for this use; the libraries keep the Slaney and the HTK conventions. Outcome: current.

**Notes against the code.** The hazard is §7.5's (a narrow low band on a short frame covers no bin); the notes add the edges through the formula and back, slopes from differences, a bin on an edge, sums of products, two implementations, and powers that underflow. The symbols exist: the edges with their ends set to the range, `firstEmptyBand`, `smallestFillingLength`, the clamp at zero (`Mel/MelFilterBank.swift`); the check when the pipeline is attached with its advice, and the crossover (`Steps/MelScale.swift`); `BandedMelNode` and `DenseMelNode` (`Nodes/MelNodes.swift`); the formulas (`ZTronDSPCore/Units/MelFormula.swift`). Measured (`aBandThatCoversNoBinIsFoundAtEveryRateOfTheLibrary` and `theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms`, which now print their tables):

| Figure | Note | Measured |
|---|---|---|
| banks of 128 bands with an empty band, of 21 | 9 | 9 |
| empty bands at 256, 1 024 and 4 096 points, and the smallest filling length, for the seven fixtures | the table of `mel-filter-bank.md` | the same: 32, 0, 0, 768; 43, 6, 0, 1 536; 51, 19, 0, 2 560; 32, 0, 0, 768; 35, 0, 0, 960; 34, 0, 0, 768; 34, 0, 0, 768 |
| hazard 3: ε·f over the half-width of a slope | below 1e-13 | 7.5587e-15 at most |
| the round trip; the weights against the reference | within 1e-9; within 1e-6 | asserted (HTK absolutely, below 1 Hz) |
| the projection: the longest band; ε·bins | 62 bins; 7.4e-6 | 62; 7.3910e-6 |
| banded and dense, of the band | 2.3e-7 and 1.6e-7 at most | `full-scale-sine` 2.2918e-7 and 1.5569e-7, `white-noise` 1.9445e-7 and 1.3196e-7, `full-scale-square` 1.4680e-7 and 9.5082e-8, `decaying-tail` 1.3041e-7 and 9.2472e-8, `dc` 1.1503e-7 and 1.0552e-7, `nyquist` 8.0303e-8 and 1.0271e-7; exact zeros for `silence`, `denormal` and `impulse` |

One statement was qualified: the round trip "within 10⁻⁹" is relative for Slaney, and absolute below 1 Hz for HTK, whose relative error is 3.83·10⁻⁸ at 10⁻⁶ Hz (wave 2, m5a, A-5, open; `MelTests` holds HTK to 10⁻⁹·max(f, 1)).

**Tests added.** `StabilityTests.theEdgesEndOnTheRangeItselfAtEveryRateOfTheLibrary`: 84 banks at the rates and corners of `StressFixture.filtersNearZero` and `filtersNearNyquist` (three ranges each, 40 bands on 4 096 points and 128 on 16 384, both formulas). Every bank ends on its range; when the range ends at the Nyquist frequency no band owns its bin, and when it starts at 0 Hz no band owns bin 0; the round trip through the formula alone misses 85 of the 168 ends.

**Mutations** (`MelFilterBank.swift`, `MelScale.swift`):

| Mutation | Result |
|---|---|
| R18-empty: `firstEmptyBand` answering that there is none (`mel-filter-bank.md`'s own) | killed: the stress test (18 issues), `aBandThatCoversNoBinIsReportedNotHidden`, `anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt`, `theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms` |
| R18-filling: the filling length tested against twice the upper edge | killed: four tests, among them the stress test (9) |
| R18-clamp: the weights not clamped at zero | killed: four tests, 447 issues (`theWeightsEqualTheReferenceFilterBank` 277) |
| R18-range: a range up to twice the Nyquist frequency admitted | killed: `aBankIsAValue` |
| R18-rule: the order rule opened to every kind of value on a linear axis | killed: `aWrongOrderIsRefusedOnTheDescriptions` (2), `theRuleOfTheDescriptionIsTheRuleOfTheTypes` (2) |
| R18-select: the dense product never chosen, whatever the crossover says | killed: `bandedAndDenseProjectionsAgree` ("bands × bins decide (§7.4)") |
| R18-ends: the ends of the edges left to the round trip through the formula | survived the tests as they were; killed by the new test (103 issues: an upper edge of 95 999.9999999999 Hz at 96 kHz, one of 24 000.000000000004 Hz that gives the Nyquist bin a weight) |
| R18-check: the check removed from `MelScale` (`mel-projection.md`'s own) | killed: `anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt`, `theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms` (its first spelling named a variable out of scope and did not compile; it was spelled again and run) |

**Precision (NUMS-3).** The edges and the weights in Double, each weight rounded once to Float32. The projection in Float32: banded dot products by Core's `Vector`, each bound to the loop its length calls for, or one `cblas_sgemv` of the whole bank, chosen by the measured crossover of `.melProjection` when the plan is compiled (§7.4, SEL-3).

**Open.** Wave 2, m5a, not fixed here: A-5 (the HTK pair in `MelFormula.swift` cancels below 1 Hz; `log1p` and `expm1` were asked for); backlog B-14 of lens B (no benchmark recorded).

## WP-905d: rows 19 to 24

### Row 19: Cepstrum (WP-509, WP-510; `cepstrum.md`, `complex-cepstrum.md`)

**Currency.** Searched on 2026-11-21: phase unwrapping for the complex cepstrum in 2025–2026. Nothing from those two years: discontinuity detection with adaptive integration (Tribolet 1977) is still the method in use, and the root-based and the differential cepstrum are still the ways around unwrapping. Outcome: current; CR-020 item 7 (the cepstrum from the roots of the frame's polynomial, as the alternative for the complex cepstrum offline) stands.

**Notes against the code.** The hazards are §7.5's (the logarithm of a near-zero magnitude; ambiguous phase unwrapping); the notes add the logarithm of round-off, the delay as a ramp, the sign of bin 0 and the cost of the floor in the round trip. The symbols exist: the clamp of the squared magnitudes at the floor before the logarithm (`vDSP_vthrD`), double precision from the magnitudes on (`vvlog`, `vvatan2`, `DoubleDFT`), the unwrapping at π, the delay and the sign taken out and carried after the quefrencies, and the one rounding to `Float` (`Nodes/CepstrumNodes.swift`); the refusal of a floor that is not positive and finite (`Steps/Cepstrum.swift`); the bins at the floor counted, the largest phase step held against π, and the cost of the floor held against the frame's peak (`Inversion/StageInversions.swift`). Measured (`theCepstrumOfEveryStressSignalIsBoundedByItsFloor` and `theComplexCepstrumOfEveryStressSignalInvertsOrSaysWhyNot`, which now print their tables as "measured WP-509" and "measured WP-510"):

| Figure | Note | Measured |
|---|---|---|
| the real cepstrum against its definition in double precision, of the frame maximum, at floors 10⁻¹⁰, 10⁻⁴, 10⁻² and 1: `dc`, `nyquist` | 0.20; 1.4e-8; 4.5e-8; 5.5e-8 | 0.199; 1.38e-8; 4.54e-8; 5.46e-8 |
| `full-scale-sine` | 2.9e-2; 2.6e-5; 2.1e-7; 1.1e-7 | 2.93e-2; 2.62e-5; 2.11e-7; 1.13e-7 |
| `full-scale-square` | 8.1e-5; 4.5e-5; 6.8e-7; 6.4e-8 | 8.10e-5; 4.52e-5; 6.77e-7; 6.37e-8 |
| `decaying-tail` | 6.5e-5; 1.4e-8; 1.4e-8; 0 | 6.52e-5; 1.39e-8; 1.39e-8; 0 |
| `white-noise` | 5.6e-8 at each | 5.57e-8 at the first three, 5.64e-8 at 1 |
| `silence`, `denormal`, `impulse` | 2.8e-8; 1.4e-8; 1.4e-8; 0 | 2.75e-8; 1.39e-8; 1.39e-8; 0 |
| the largest value at the default floor: real; power cepstrum | at most 23.03, ln 10¹⁰; at most its square | 23.025850 (ln 10¹⁰ = 23.025851); 530.19 |
| the complex round trip, measured and predicted: `full-scale-sine`, `white-noise`, `full-scale-square` | 3.5e-7, 6.8e-7, 1.8e-7; 10⁻⁵ | 3.53e-7, 6.83e-7, 1.82e-7; 10⁻⁵ |
| `dc` and `nyquist`; `impulse` | 8.9e-7; 2.0e-7 | 8.94e-7; 2.03e-7 |
| `decaying-tail`; `denormal` | 1.7e28 and 1.7e28; 4.4e30 and 4.4e30 | 1.70141e28 and 1.70143e28; 4.35562e30 and 4.35566e30 |
| `silence` | infinite and infinite | infinite and infinite, every bin at the floor |
| the impulse 64 samples into a frame | zero to 2.8e-14, "its position of 64 samples" beside it | 2.79e-14, and −64 beside it |
| the impulse at the start of a frame; half a frame in | exact zeros and no delay; the delay not recovered | exact zeros and 0; 0, with a largest value of 1.0001 |

Two statements of `complex-cepstrum.md` were corrected. The value carried beside the frame is the linear term of the phase, minus the delay: −64 for the impulse 64 samples in, which is what `theComplexCepstrumOfADelayedImpulseIsItsDelay` expects. And the number of half turns at the Nyquist bin is minus the delay, a delay past the middle of the frame reading as an advance. The code was right; the note said "its position" and "the delay".

**Tests added.** `StabilityTests.theRealCepstrumOfTheStressSpectraIsItsDefinitionRoundedOnce`: the nine signals of `StressFixture.signals`, Hann frames of 1 024 samples transformed in double precision and rounded once to single precision, handed to `Cepstrum(.real)` as complex frames, at floors of 10⁻¹⁰ and 10⁻². Each of the 9 234 values must lie within half a unit in its last place, plus 10⁻¹³ of the largest logarithm, of the definition evaluated in double precision from the same single-precision spectrum; the largest error is 0.998 of that bound. It holds the node to double precision from the magnitudes on, which no test could see before: the comparison with the definition in the stress test allows 10⁻⁵ of the frame maximum, far more than a logarithm in single precision adds.

**Mutations** (`CepstrumNodes.swift`, `Cepstrum.swift`, `StageInversions.swift`):

| Mutation | Result |
|---|---|
| R19-floor: the clamp given a threshold of 0 (`cepstrum.md`'s own) | killed: eight tests, among them the stress test (21 issues), `theLogarithmIsFloored`, `theRealAndThePowerCepstrumEqualTheGoldenVectors` and the pitch tests, as the note says |
| R19-refuse: a floor that is not positive and finite admitted | killed: `theLogarithmIsFloored` |
| R19-single: the logarithm rounded to `Float` after `vvlog` | killed only by `CepstrumTests.theNodesRunWithoutAllocating`, through the conversion's own allocation. Spelled again without allocating (R19-single-2, through the node's output buffer), it passed the tests as they were and was killed by the new test: 11 of the 18 pairs of signal and floor (`dc`, `full-scale-sine`, `full-scale-square`, `nyquist` and `white-noise` at both floors, `decaying-tail` at 10⁻¹⁰) |
| R19-unwrap: steps taken as wraps only beyond 3π | killed: `theComplexCepstrumOfADelayedImpulseIsItsDelay` (4 issues), the stress test (2) |
| R19-delay: the ramp not subtracted (`complex-cepstrum.md`'s own) | killed: six tests; the stress test with `white-noise` off by 2.2012 of the frame maximum, as the note says |
| R19-sign: the sign of bin 0 not put back by the inverse | killed: five tests (`theInverseReturnsTheSpectrum`, `theRoundTripRunsThroughAnInverseSTFT`, the stress test, two of `InversionTests`) |
| R19-ramp: the ramp not put back by the inverse | killed: the same five tests |
| R19-count: bins counted at the floor only below 0 | killed: `binsAtTheFloorOfTheLogarithmAreCounted` (2), the stress test (10: `silence` measured infinite against a predicted 10⁻⁵) |
| R19-phase: the condition on the largest phase step always holding | killed: the stress test ("the phase of noise has no one unwrapping: flagged") |
| R19-lost: the cost of the floor not divided by the frame's peak | killed: `binsAtTheFloorOfTheLogarithmAreCounted`, the stress test (`denormal` measured 4.36e30 against a predicted 1.0e-5) |

**Precision (NUMS-3).** Double from the magnitudes on: the squared magnitudes and their clamp (`vDSP_vthrD`), the logarithm (`vvlog`), the phase (`vvatan2`), the unwrapping and the inverse transform (`DoubleDFT`); the frame is rounded once to `Float` as it leaves the node (`vDSP_vdpsp`). One implementation, fixed in `CepstrumNode` and `InverseCepstrumNode`; the spectrum they read is the single-precision transform of row 1.

**Open.** Wave 2, m5a, not fixed here: A-12 (the cepstral pitch meets its 1 % narrowly at 110 Hz, because the floor is absolute; CR-019 item 13); B-14 (no benchmark recorded); B-15 (RT-7 layer 2 does not reach the leaf loops of `CepstrumNodes.swift`). F-905d-3 (this audit, low): the documentation of `Cepstrum(.complex)` (`Steps/Cepstrum.swift`) says that the delay travels with the frame, but not its sign or its unit: the value is minus the delay, as a fraction of the transform length, and past the middle of the frame it reads as an advance. A matter of VIS-2; this audit changed no production file.

### Row 20: Band-boost (WP-421; `band-boost.md`, `matched-peak.md`)

**Currency.** Searched on 2026-11-21: peaking and high-order equaliser design, DAFx and JAES, 2025–2026. Found: Schlecht, Sinjanakhom and Välimäki, "Multi-shelf graphic equalizer" (Signal Processing, 2025), cascaded shelves for graphic equalisers and not a band-boost design; Orfanidis 2005 is still the reference the tools follow (MATLAB's `designParamEQ`). Outcome: current; CR-020 item 6 (Vicanek's matched second-order shelving of 2024, as the alternative for the shelves) stands.

**Notes against the code.** The hazard is §7.5's (fourth-order sections from closed-form coefficients lose accuracy for narrow, low bands: 0.06 dB at the centre and 2·10⁻² in the boost–cut identity); the notes add the limit at 0.49 of the sample rate, the pole radius and its per-order gain, the half-gain level, and the matched peak's three conditions in closed form. The symbols exist: the design in ZPK, order 1 as the Cookbook section, the pole radius with its per-order gain, the radicand from sin ω₀ and the limit (`Equalizers/EqualizerDesign.swift`); the pairing of the zero-pole form into biquads, nearest zero to each pole (`Systems/SectionPairing.swift`); the closed form of the three conditions, `expm1`, the detune without the subtraction, x − x₀ as a product of sines, the two bisections and the zero formed so that it does not cancel (`Equalizers/MatchedPeakDesign.swift`). Measured (the MEASURED lines of `BandBoostTests` and `MatchedPeakTests`):

| Figure | Note | Measured |
|---|---|---|
| band boost, properties 1 to 6 over the grid | 7.8e-11 dB, 2.7e-11, 6.0e-12 dB, 1.4e-11 dB, 0.99998553, 9.3e-14 | 7.774e-11 dB, 2.723e-11, 5.991e-12 dB, 1.431e-11 dB, 0.99998553, 9.286e-14 |
| the stress fixture: zero-pole form; the paired biquads; closed-form fourth-order sections | 6.0e-11 dB and 1.8e-15; 7.3e-9 dB; 0.95 dB and 0.24 | 5.983e-11 dB and 1.790e-15; 7.261e-9 dB; 0.954 dB and 0.237 |
| matched peak over the grid: properties 1, 2, 4, 5 and boost · cut − 1 | 2.3e-11 dB, 1.8e-11, 3.9e-15 dB, 0.99997720, 2.7e-15 | 2.276e-11 dB, 1.760e-11, 3.857e-15 dB, 0.99997720, 2.715e-15 |
| matched peak under stress: centre gain; bandwidth | within 3.4e-9 dB; within 4.2e-10 | 3.412e-9 dB; 4.193e-10 |
| its shape against the analog peak: of the Cookbook's deviation; the worst fixtures | at most 0.53; 2.14 and 9.80 dB | 0.534; 2.139 and 9.801 dB |

Two bounds of `matched-peak.md` had been rounded below what is measured and now give the measured figure: the centre gain under stress within 3.42e-9 dB, and the shape at most 0.534 of the Cookbook's deviation. The note's first formulation (a half-gain width known to 1e-8, twenty bands refused) is told as history; that code is gone, and no test reproduces its figures.

**Tests strengthened.** `BandBoostTests.orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads` (`EqualizerTests.swift`) now also asks for what only the Cookbook's section has: one middle coefficient shared by numerator and denominator, b₁ = a₁ bit for bit. A section paired from the same zeros and poles agrees with it within 10⁻¹³ everywhere else, which is why the test could not tell the two apart before.

**Mutations** (`EqualizerDesign.swift`, `MatchedPeakDesign.swift`, `SectionPairing.swift`):

| Mutation | Result |
|---|---|
| R20-quartic: the poles taken back from the expanded polynomial (the hazard itself) | killed: four tests, among them `property5AllPolesLieStrictlyInsideTheUnitCircle` (577 issues) and the stress test |
| R20-inverse: the pole radius without the per-order gain | killed: four tests: properties 2 (3 836 issues) and 6 (960), order 1 (7), the stress test (2) |
| R20-limit: the limit at 0.49 of the sample rate widened | killed: `aBandThatReachesFortyNineHundredthsOfTheSampleRateIsRejected` |
| R20-order1: order 1 designed as a paired section, not the Cookbook's | passed the tests as they were; killed by the strengthened test (R20-order1-2: b₁ and a₁ differ by a unit in the last place in each of the six order-one bands of the test, at 1 kHz: 100 Hz and 333.33 Hz wide, 0.1 and 1 octave, Q 0.5 and 4) |
| R20-radicand: the radicand formed from cos²ω₀ − 1 | equivalent: its absolute error of about 2ε is relative 1.3e-10 at the lowest corner of the stress library (20 Hz at 96 kHz, sin²ω₀ = 1.7e-6); the figures move from 5.98e-11 to 3.76e-11 dB (zero-pole form) and from 7.26e-9 to 2.00e-8 dB (paired biquads), against bounds of 0.01 dB |
| R20-pairing: a zero taken in list order, not the nearest | equivalent for this row: the paired biquads stay within 6.29e-9 dB. The nearest pairing is row 4's mitigation, killed there (R4-pairing: `thePairingMatchesTheReferenceSectionForSection`, 44 issues, and `digitalDesignsMatchTheOracleSectionForSection`) |
| R20-expm1: `1 − exp(−decay)` in place of `expm1` | equivalent: exact where it cancels (Sterbenz: r within a factor of two of 1); it gives the gap of the pole as stored, `expm1` the prototype's, and the stored pole carries that rounding either way. The stress figures fall: the bandwidth from 4.19e-10 to 7.93e-11, the centre gain from 3.41e-9 to 3.33e-9 dB (F-905d-2) |
| R20-detune: ω₀ − ω₀·root in place of the form without the subtraction | equivalent: exact where it cancels (Sterbenz: θ within a factor of two of ω₀); no figure moves |
| R20-sines: x − x₀ as a difference of squares | equivalent: it cancels by x₀ / (x − x₀), about f₀ / Δf, at most 1 000 in the stress (0.02 Hz at 20 Hz): three digits of sixteen; no printed figure moves |
| R20-zero: of z and 1/z, the cancelling one formed first | equivalent: their distances to z = 1 have the sum −4x and the product 4x, so the cancelling one loses about log₁₀ 2·abs(x) digits, which counts only for a zero far from the unit circle; the identity moves from 2.71e-15 to 3.69e-15 |
| R20-bisect: 20 bisection steps in place of 200 | killed: five tests (`theBandsTheLimitRejectsAreTheOnesThatReachIt` 136 issues) |
| R20-level: the half-gain level with x₀ in place of x₀² | killed: six tests (`theBandsTheLimitRejectsAreTheOnesThatReachIt` 252 issues) |

**Precision (NUMS-3).** Double throughout the design: zeros, poles and gain in ZPK as `Complex` of Double, paired into sections in Double (`SectionPairing`), the matched peak's conditions and bisections in Double; design time only. The sections then run in Float32 or Double as the realisation chosen when the plan is compiled decides (row 3, REAL-3).

**Open.** Wave 1, m4a, not fixed here: A-NB6 (properties 1–4 are tested on the zero-pole form only; the sections differ from it by up to 3.2e-7 of the peak); B-BL-4 (two public names missing from CR-018 item 11). Wave 2, m4b: A-B3 (the matched peak's `.q` is the analog prototype's Q); B-4 (COV-3 of `MatchedPeakDesign.swift`). F-905d-2 (this audit, an observation): the matched peak's gap and detune are the prototype's, not those of the poles as stored; taken from the stored poles, the stress bandwidth error would fall from 4.19e-10 to 7.93e-11. Not changed: WP-422 is optional, and the error is 10⁴ under its bound.

### Row 21: Window analysis (WP-501d, WP-501e, WP-501f; `window-gains.md`, `window-smoothness.md`, `window-spectrum.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers the package's own procedure): side-lobe fall-off, scalloping loss and window figures, 2025–2026. Found: Yamaoka and Oshima (IEEE Access, 2025), side lobes lowered by multiplying cosine-sum windows, a method of design; Prabhu (2014) is still the reference for the figures. Nothing on computing them. Outcome: current.

**Notes against the code.** The hazard is §7.5's (finite differences amplify round-off as ε / hᵏ; reliable to order 4 at steps of 2⁻¹² of the frame or more); the notes add sums that are round-off, tails, the symmetry and the edges, the noise threshold, jumps between the points of a grid, spectra under −400 dB, nulls between the points of the padded transform, and the floor under Σ w². The symbols exist: the thresholds relative to the peak for a sum, the symmetry and the tail, the probes of the tail, the edge values from the window's symmetric form at three points (`Windows/WindowAnalysis.swift`); the grids, the highest derivative, the persistence, the noise threshold scaled by the peak, the placing of a jump at the steepest step, Riemann sums compared; the padding sixteen-fold, the parabola, the floor of −400 dB, the reference at the power at 0 Hz, or at the largest where that is zero, `nil` where there is no null, the fall-off fitted between N/32 bins (8 at least) and N/4 (all in `WindowAnalysis.swift`); the threshold of `WindowNormalization` (`Transform/FrameAlignment.swift`); the floor under Σ w² (`Steps/FramingSupport.swift`). Measured (the stress tests, which now print "measured WP-501d", "WP-501e" and "WP-501f"):

| Figure | Note | Measured |
|---|---|---|
| sums without their mean, a tenth as high: `full-scale-sine`, `full-scale-square`, `decaying-tail`, `impulse`, `white-noise`; `nyquist` | −4.6e-16, −7.9e-15, 2.2e-15, 1.5e-15, −5.8e-16; exactly 0 | −4.58e-16, −7.88e-15, 2.24e-15, 1.51e-15, −5.83e-16; 0 |
| `denormal`, a rectangle 9e-44 high: noise bandwidth; symmetric | exactly 1 bin; yes | 1 bin; yes |
| jumps: `full-scale-square`, `nyquist`, `dc`, `impulse`, `denormal` | 44, 1 025, 2, 2, 2 | the same, and `full-scale-sine` and `decaying-tail` 1 each; all of smoothness 0 |
| where the jumps are | the steps within ⅛ sample, the edges exact | the same |
| `dc`: the peak side lobe; null to null | −13.26 dB; 2 bins | −13.262 dB; 2.0 bins |
| `denormal` against `dc`; `impulse`; `nyquist` | the same spectrum within 10⁻⁶ dB; 0 dB throughout; −400 dB at 0 Hz and 0 dB at Nyquist | within 0.0 dB, point for point; the same; the same |
| the lowest level of any spectrum | −400 dB | −400 dB (8 windows, 24 reports) |

**Tests added.** `StabilityTests.theTailOfAStressWindowIsJudgedAtEveryHeight`: five functions, a Gaussian, a constant, one settling to 1 + 1/(1 + abs(t)), one falling as 1/abs(t) and one a hundredth outside the frame, whose verdicts are zero, 1, 1.00000095, zero and 0.01. Scaled to the library's subnormal height (the peak of `denormal`), 10⁻²⁰, 10²⁰ and 10³⁰, each gives the same verdict (a value relatively within 1e-9 once scaled back) and the same integrability. `StabilityTests.theNullOfATruncatedRectangleIsFoundBetweenThePointsOfTheGrid`: the library's rectangle (`dc`) cut short to 1 000, 999, 900, 700 and 513 of the frame's 1 024 samples, whose first nulls lie 1 024 / n bins out, between two points of the padded transform: 2.04974, 2.05182, 2.27655, 2.92697 and 3.99245 bins between the nulls against 2.04800, 2.05005, 2.27556, 2.92571 and 3.99220, within 1.8e-3 (bound 2.5e-3), where the nearest points are 0.008 to 0.051 bin off; numpy's widths, from the same definition, are the measured ones. `theJumpsOfEveryStressWindowAreFoundWhereTheyAre` now asks its shapes at the five heights whether they are mirror images.

**Mutations** (`WindowAnalysis.swift`, `FrameAlignment.swift`, `FramingSupport.swift`):

| Mutation | Result |
|---|---|
| R21-sum: the sum for the noise bandwidth tested only for being exactly zero (`window-gains.md`'s own) | killed: `theGainsOfEveryStressWindowAreNumbersOrNothing` (5 issues), as the note says |
| R21-norm: the same change in `WindowNormalization` | killed: the same test (10: the framing steps attach) |
| R21-mirror: the symmetry judged with an absolute tolerance | passed the tests as they were; killed by the strengthened test (R21-mirror-2, 6 issues: Hann and sin⁴ at 10²⁰ and 10³⁰ judged not symmetric, the step at 9e-44 and 10⁻²⁰ judged symmetric) |
| R21-tail: the tail probed at 11 arguments in place of 21 | killed: `theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven` (1 + 1/abs(t) reported undefined) |
| R21-tail-scale: the tail judged at a scale of 1, not the window's peak | passed the tests as they were; killed by the new test (R21-tail-scale-2, 6 issues: the constant, the settling function and the hundredth tend to zero at the two small heights) |
| R21-double: the samples rounded to single precision | killed: four tests (128 issues of the reference figures) |
| R21-edges: the edge values read from the samples | killed: `shapeAndEdgesOfTheStockWindows` (2) |
| R21-grid-double: the grids sampled in single precision | killed: `higherOrdersAreToldApart` (3), the jumps stress test (13: the triangle at 9e-44 of smoothness 0) |
| R21-grids: three grids at the finest step | killed: eight tests |
| R21-order: no derivative beyond the third | killed: `higherOrdersAreToldApart` (2), the jumps stress test (5: sin⁴ of smoothness 3) |
| R21-persist: a persistence of one half | killed: seven tests |
| R21-noise: the noise threshold not scaled by the peak (`window-smoothness.md`'s own) | killed: the jumps stress test (9), as the note says |
| R21-place: a jump left where the coarse grid found it | killed: three tests (1 070 issues) |
| R21-riemann: Riemann sums taken to agree untested | killed: `integrabilityOnTheFrame` (2) |
| R21-pad: padding four-fold in place of sixteen-fold | killed: the reference figures (41 issues), and the spectral stress test stops on an index past the end of the shorter spectrum |
| R21-parabola: the parabola left out | killed: the reference figures (5) |
| R21-null: the null placed on the nearest point of the padded transform | passed the tests as they were (every null they saw lay on a point); killed by the new test (R21-null-2, 5 issues: 2.0, 2.0, 2.25, 2.875 and 4.0 bins) |
| R21-floor400: the floor of −400 dB removed (`window-spectrum.md`'s own) | killed: the spectral stress test (13), as the note says |
| R21-ref: the reference fixed at the power at 0 Hz | killed: the spectral stress test (`nyquist`) |
| R21-nil: a width of 0 where there is no null | killed: the spectral stress test (`impulse`) |
| R21-falloff: the fall-off fitted over every lobe | killed: the reference figures (23) |
| R21-nola: no floor under Σ w² | killed: `aFailingWindowIsReportedNotThrown`, the B/A stress test (4) |

**Precision (NUMS-3).** Double throughout: the samples, the grids of the finite differences, the zero-padded transform (`DoubleDFT`) and the figures. The analysis is background work (BG-1), made when a pipeline is attached or when it is asked for, never on the audio thread; one implementation, fixed in `WindowAnalysis`.

**Open.** Wave 2, m5a, not fixed here: A-3 (a jump is located within one sample by a loosened tolerance; the grids of WIN-4, `finestGrid` 4 096); A-4 (the Blackman window's null-to-null width is 6.0793 bins at a frame of 1 000: two zeros nearly meet between two points, and the chord finds neither); B-10 (within one sample against WIN-6 above 8 192 samples); B-11 (the threshold of constant overlap-add is untested).

### Row 22: Inversion analysis (WP-537, `inversion-analysis.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers the package's own procedure on classical results): STFT invertibility, frame bounds, NOLA and COLA, 2025–2026. Found: a 2026 preprint on an STFT with data-adaptive windows, which restores reconstruction by normalising its envelope. Nothing that sharpens NOLA or the frame bounds. Outcome: current.

**Notes against the code.** The hazards are §7.5's (division by a small Σ w²; a measurement limited by Float32); the note adds a prediction that understates and relative errors against nothing. The symbols exist: B/A and the prediction from it, the margins of the conditions (`Inversion/StageInversions.swift`); the floor under Σ w² (`OverlapAdd.nonZeroFloor`, `Steps/FramingSupport.swift`); the head-room of the transform and of the logarithm (`StageInversions.swift`); the measurement, a frame's error held against its maximum, silence and an exact pair (`Inversion/InversionReport.swift`); the band limit through a Kaiser window of β = 24 and the negligible share (`Inversion/RateInversions.swift`). Measured (`whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal`, which now prints "measured WP-537"):

| Figure | Note | Measured |
|---|---|---|
| B/A 1: the largest error; the signal-to-noise ratios; the prediction | 3.6e-7; 138.9 to 145.9 dB; 1.9e-5 | 3.58e-7; 138.88 to 145.86 dB; 1.907e-5 |
| B/A 9.67 | 8.3e-7; 134.9 to 141.5 dB; 1.8e-4 | 8.35e-7; 134.90 to 141.50 dB; 1.845e-4 |
| B/A 10⁴ | 2.8e-5; 113.7 to 119.9 dB; 0.19 | 2.83e-5; 113.73 to 119.95 dB; 0.1907 |
| B/A 10⁸ | 1.9e-3; 84.0 to 90.5 dB; 1 | 1.91e-3; 84.00 to 90.50 dB; 1 |
| `silence`, `decaying-tail`, `impulse` | exact | exact |
| `denormal`, in units of the least subnormal number | at most 71, up to 1.1 of its peak | 1, 13, 69 and 71; 1.08 and 1.11 of its peak at the two largest ratios |
| below the floor (B/A 10¹²): what is lost, of the peak | 0.99 to 1.0 | `full-scale-sine` 0.994, `dc` 1.0, `white-noise` 0.999; `silence` 0, with a margin of −9.9e-11 |
| a tight frame | 139 to 146 dB | 138.88 dB at the least |

Two statements were made exact: below the floor `silence`, which has nothing to lose, loses 0; and `denormal` errs by up to 1.11 of its peak, not 1.1.

**Tests strengthened.** `StabilityTests.whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal` now computes the prediction of the note itself, min(16·ε·log₂ M · B/A, 1) with M = 1 024, and holds every reported prediction to it within 1e-9, relatively. The tests took the prediction from the function under test, and with a head-room of 1 in place of 16 every measured error still lay under it (at B/A = 1 the largest is 0.30 of ε·log₂ M).

**Mutations** (`StageInversions.swift`, `InversionReport.swift`, `RateInversions.swift`):

| Mutation | Result |
|---|---|
| R22-ratio: the prediction without B/A, round-off alone (the note's own) | killed: `theConditionsOfAnSTFTAreItsFrameBounds`, the stress test (7 issues), as the note says |
| R22-margin: the margin's sign turned below the floor | killed: `aFailingWindowIsReportedNotThrown`, the stress test (4) |
| R22-held: a frame's error not held against the frame's maximum | killed: five tests (`aMeasurementIsWhatItsNameSays`, the inversions of decibels, cepstral coefficients and the cepstra, the complex-cepstrum stress test) |
| R22-silent: an error against silence reported as 0, not infinite | killed: `aMeasurementIsWhatItsNameSays` |
| R22-snr: an exact round trip reported as 0 dB, not infinite | killed: `aMeasurementIsWhatItsNameSays`, `theReportOfAnExactPairIsExact` |
| R22-headroom: the head-room of the transform's round-off cut from 16 to 1 | passed the tests as they were; killed by the strengthened test (R22-headroom-2, 24 issues: every prediction a sixteenth of the rule) |
| R22-log: the head-room of a logarithm and its exponential cut from 10⁻⁵ to 10⁻⁷ | killed: four tests (the complex-cepstrum stress test 8 issues) |
| R22-kaiser: the band limit measured through a Kaiser window of β = 8 | killed: `aBandLimitedFixturePassesTheSamplingTheorem` (3: the band-limited fixture leaks 2.6e-9 above its band) |
| R22-share: no share counted as negligible | killed: `aBandLimitedFixturePassesTheSamplingTheorem` (2) |

**Precision (NUMS-3).** Double for the conditions (Σ w² over the shifts, B/A, the margins) and for the band limit; the round trip runs through the pipeline's own arithmetic, Float32, and is compared in Double. Computed when a report is asked for (`inversionReport(for:sampleRate:after:)`), as background work; one implementation.

**Open.** Wave 2, m5a, not fixed here: A-11 (VIS-2 of `inversionReport(for:sampleRate:after:)`); B-3 (the measured relative error of INV-2). Wave 3, m5b: A-NB9 (NaN or ∞ in the signal turns the verdict of the subsampling report); A-NB10 (subnormal signals); A-NB11 (frames that are not finite read as exact); A-NB12 (the upsampling report traps at Int.max / 2).

### Row 23: Heat-map rendering (WP-605, `heatmap-rendering.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers the package's own design): real-time spectrograms on the GPU, 2025–2026. Open projects keep a ring of columns, upload only the new ones and colour in the shader, which is the registered design; nothing on half-float textures. Outcome: current.

**Notes against the code.** The hazard is §7.5's (half-float quantisation); the note adds values a half float cannot hold, a value that is not a number, a one-bin peak under a scale that squeezes rows, and the warp table. The symbols exist: the clamp to ±65 504 (`vDSP_vclip`), the test for a NaN over the bins (`vDSP_sve`) and its replacement by the lowest value, the levels as maxima of pairs (`vDSP_vmax`), and the one conversion to half floats (`Heatmap/HeatmapTexture.swift`); the walk of the levels over the stretch of rows a pixel covers, the sliver given up at each end of a stretch, and the interpolation between rows (`Shaders/Heatmap.metal`); the warp table of 4 096 entries (`Rendering/FrequencyScale.swift`). Measured (printed by `HeatmapTextureTests`, `HeatmapGoldenTests` and `FrequencyScaleTests`):

| Figure | Note | Measured |
|---|---|---|
| a texel, relative to the stored value | at most 2⁻¹¹ = 4.9e-4; measured 4.07e-4 | 4.07e-4 |
| a level in decibels | at most 2⁻⁵ = 0.031 dB between 64 and 128 dB in magnitude | 0.0308 dB |
| PSNR over the seventeen fixtures, at the least; fixtures equal pixel for pixel | 68.7 dB; six | 68.7 dB (`heatmap-bands`), the largest difference one level; six (`heatmap-chroma`, `heatmap-partial`, `heatmap-zoom` and the three peaks) |
| the warp table, of a row: 2 049 rows on the logarithmic, mel and linear axes; 1 025 rows | 8.1e-4, 5.2e-4, 6.1e-5; half of each | 8.06e-4, 5.20e-4, 6.10e-5; 4.03e-4, 2.60e-4, 3.05e-5 |

The register's "under 0.005 dB" does not hold for levels stored in decibels, as the note says: that is CR-016 item 3 (Proposed), open.

**Tests added.** `HeatmapTextureTests.aNotANumberIsReplacedInWhicheverBinItArrives`: the library's non-finite signal (`StressFixture.nonFiniteSignal`, 64 values) turned column by column so that its NaN arrives in bin k of column k, for every k of 64 bins, into a texture whose history is 64 columns. Every texel read back is finite, and the NaN's bin holds −65 504 in its column. The stress test as it was could not tell a check over half the bins from a check over all of them: its NaNs sit in the lower half.

**Mutations** (`HeatmapTexture.swift`, `Heatmap.metal`, `FrequencyScale.swift`):

| Mutation | Result |
|---|---|
| R23-clip: the clamp widened to ±∞ (the note's own) | killed: the stress test (180 issues), as the note says |
| R23-nan: the replacement of a NaN skipped (the note's own) | killed: the stress test (7), as the note says |
| R23-sve: the check for a NaN summed over half the bins | passed the tests as they were; killed by the new test (R23-sve-2, 33 issues: bins 32 to 63 read back as NaN) |
| R23-walk: the walk of the levels switched off in the shader (the note's own) | killed: `aOneBinPeakSurvivesEveryScale` (140), three golden images, as the note says |
| R23-levels: levels built by `vDSP_vmin` (the note's own) | killed: four tests (`eachLevelIsTheMaximumOfTheTwoEntriesBelowIt` 1 439 issues), as the note says |
| R23-table: a warp table of 256 entries | killed: three tests (`theWarpTableFollowsTheScaleToAThousandthOfARow` 11, `aTableSpansTheWholeAxisOfTheFeed`, `theUniformsAreWhatTheShaderDeclares`) |
| R23-sliver: no sliver given up at the ends of a stretch (with the nearest-row filter a row's edge on a fragment's edge then belongs to two fragments) | killed: one golden image (`heatmap-chroma`, 23.2 dB) |
| R23-between: the lower row in place of the interpolant | killed: three tests (golden images 12, `aOneBinPeakSurvivesEveryScale` 9, `thePictureDoesNotDependOnHowTheColumnsArrived`) |

**Precision (NUMS-3).** Float32 staging: the clamp (`vDSP_vclip`) and the levels (`vDSP_vmax`) in single precision, then one conversion to half floats (`vImageConvert_PlanarFtoPlanar16F`) into an `r16Float` texture; the shader works in `float` and reads rows through the warp table of 4 096 entries. Fixed by the texture's format when the renderer is made; one implementation.

**Open.** CR-016 item 3 (Proposed): the register's "under 0.005 dB"; for levels stored in decibels the error is relative to the level, up to 2⁻⁵ dB (0.031 dB measured), a tenth of a colour step.

### Row 24: Implementation selection (WP-611a, `crossover-search.md`)

**Currency.** Searched on 2026-11-21 (the first pass made no search: the row registers the package's own design): the measured choice between implementations, 2025–2026. SciPy's `choose_conv_method` (a prediction, or timing with `measure=True`) and the autotuners of FFT libraries (time the candidates after a warm-up, keep the result) do what the row registers. Outcome: current.

**Notes against the code.** The hazard is §7.5's (two implementations that differ by round-off, bit-exact for element-wise primitives and within 10⁻⁶ for reductions: SEL-6, tested per primitive); the note adds that a wrong crossover costs speed and never correctness, and that the measurement is what can go wrong: a disturbed timing, curves that are level, the clock's resolution, work the optimiser removes. The symbols exist: the fastest of the samples, the candidates timed in turn at every size, the crossover as the smallest size from which the heavier one stays faster, the repetitions up to a sample's duration (`Calibration/Calibration.swift`, `CallTimer`, `Calibration.crossover`); the table that keeps what was not measured and gives `Int.max` to an implementation that never wins (`Calibration/CrossoverMeasurement.swift`); the stock workloads, whose results escape (`Calibration/StockCandidates.swift`). Measured (`CalibrationTests`, Debug):

| Figure | Note | Measured |
|---|---|---|
| five synthetic pairs | at the first size of the grid past the crossing, exactly | the same |
| the real pair, n units against 512 | found at 1 024; 36.7 ns at 16 units to 35.8 µs at 16 384 against 1.1 µs (an optimised build) | 1 024; 128.7 ns to 86.5 µs against 2.71 µs (Debug) |
| the host table | an optimised build, the suite alone | not reproduced, and not meant to be: in Debug the crossovers were 8 and 8 (element-wise), 8 and 8, 4 and 4 (the two reductions), 8 and 16 (the lane exchange), 8 and 8 (the gain kernel), 1 and 2 (the biquad), 256 and 512 (the FIR) in two runs |
| `Calibration.report()` | half a second to a few seconds | 0.47 s alone; 3.36 s with the whole suite |
| the GPU median's entry | "keeps its initial value" | left as it was by `Calibration.report()`; set by `AnalysisCalibration` (69 768 in the full Debug run) |

One statement was incomplete and is corrected: `Calibration.report()` has no CPU median to time against the GPU and leaves `CrossoverTable.medianGPU` as it found it; the analysis calibration (`Sources/ZTronDSPAnalysis/Calibration/AnalysisCalibration.swift`), where the CPU median lives, times the two and sets it.

SEL-6, the agreement of the implementations a crossover chooses between, is shown per primitive by these tests, all passing in Debug and Release:

| Primitive | Test |
|---|---|
| element-wise | `ToolkitTests.implementationsAgreeBitForBit` (`Tests/ZTronDSPCoreTests/ToolkitTests.swift`) |
| reduction | `ToolkitTests.implementationsAgreeWithinTenToTheMinusSix` |
| lane exchange | `LaneExchangeTests.bothImplementationsEqualTheScalarExchange`, `theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers` (`Tests/CZTronDSPTests/LaneExchangeTests.swift`) |
| gain kernel | `GainKernelTests.bothImplementationsAreBitExactWithAScalarLoop` (`Tests/CZTronDSPTests/GainKernelTests.swift`) |
| biquad kernel | `BiquadKernelTests.bothImplementationsFollowTheDoubleReferenceOnNoise`, `theNativeLoopIsBitExactWithTheScalarRecurrence` (`Tests/CZTronDSPTests/BiquadKernelTests.swift`) |
| FIR, direct or partitioned | `SystemStageTests.theDirectAndThePartitionedPathAgree` (`Tests/ZTronDSPDesignTests/SystemStageTests.swift`) |
| mel projection, banded or dense | `MelTests.bandedAndDenseProjectionsAgree` (`Tests/ZTronDSPAnalysisTests/MelTests.swift`) |
| median, CPU or GPU | `MetalMedianFilterTests.theNetworkOnTheGPUIsTheNetworkOfTheCore`, `theMedianEqualsTheSortBasedOracleOnRandomSpectrograms` (`Tests/ZTronDSPMetalTests/MetalMedianFilterTests.swift`) |
| one-shot convolution | `ConvolutionTests.automaticFollowsTheCostModelOfTheTable` (`Tests/ZTronDSPAnalysisTests/ConvolutionTests.swift`; the methods' agreement is row 10's) |
| polynomial roots | none needed: the entry decides nothing (F-905d-1) |

**Tests added.** `CalibrationTests.theFastestSampleCountsAndADisturbedOneDoesNot`: a `CallTimer` of five samples with no time to spare, so one call per sample after the untimed warm-up; the first timed call spins for about a million steps, the others do nothing. Six calls are made, and the figure is under a hundredth of the disturbed call's time. `CalibrationTests.theCandidatesTakeTurnsAtEverySize`: two candidates whose times are formulas (3·n and 100) record the order in which the search calls them on the sizes 8, 16, 32 and 64; the order alternates size by size, and the crossover is 64.

**Mutations** (`Calibration.swift`, `CrossoverMeasurement.swift`, `StockCandidates.swift`):

| Mutation | Result |
|---|---|
| R24-lasting: the first size at which the heavier one is faster taken as the crossover (the note's own) | killed: `aDisturbedTimingDoesNotMoveTheCrossover` (2), as the note says |
| R24-level: a tie taken as a win | killed: `theCrossoverIsTheSizeFromWhichTheHeavierOneStaysFaster` |
| R24-repeat: the call not repeated up to the sample's duration | killed: `theTimerRepeatsACallUntilASampleIsLongEnough` |
| R24-never: an implementation that never wins given 0 in place of `Int.max` | killed: `aMeasuredTableReplacesWhatWasMeasuredAndKeepsTheRest` (2), `theExportedScriptEqualsTheGoldenScript` |
| R24-keep: one curve allowed to decide an entry | killed: three tests |
| R24-fastest: the slowest sample taken in place of the fastest | passed the tests as they were; killed by the new test (R24-fastest-2: a call that does nothing reads 6.70 ms, the time of its one disturbed sample) |
| R24-interleave: every size of one candidate timed before the other's | passed the tests as they were; killed by the new test (R24-interleave-2: the calls come out in candidate order) |
| R24-escape: the dot product's result not stored | equivalent: the product is called through a closure value the optimiser does not see into, so the call is made with or without the store, and nothing but its timing could change |

**Precision (NUMS-3).** Timings in Double: `DispatchTime` in nanoseconds, the fastest of the samples, each sample repeated until it lasts its duration (0.2 ms by default). The crossovers are integers of `CrossoverTable`, bound to each primitive's implementation when the plan is compiled (SEL-3); nothing is timed at run time.

**Open.** F-905d-1 (this audit, low): `CrossoverTable.polynomialClosedForm` decides nothing. It is read only by `implementation(for:size:requested:)`, in the case `.polynomialRoots` (`Sources/ZTronDSPCore/Toolkit/Implementation.swift`, line 139), and no caller in Sources asks for `.polynomialRoots`: `CompanionQRRootFinder` takes the closed form by its degree (`switch degree`, cases 0, 1 and 2, `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift`). The entry is measured nowhere either. So SEL-6 has nothing to show for polynomial roots. The remedy, wiring the root finder to the table or removing the entry, is a design decision and is left to the owner.
