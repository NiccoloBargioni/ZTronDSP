# ``ZTronDSPDesign``

Linear time-invariant systems, designed and analysed, and the sequence stages that run them: gain,
filters, equalisers, smoothers, rate changers and convolution.

## Overview

A sequence stage runs on any sampled sequence (samples, a novelty curve, a scalar track) and keeps
its domain, so it may stand anywhere such a sequence flows. Its filter is designed when the
pipeline is attached, on the control context, and runs on the analysis thread without allocating.
The designs are public on their own: ``IIRDesign`` and ``FIRDesign`` give the systems the stages
run, ``SystemAnalysis`` gives their responses, poles, zeros and stability, and a system can be
written out of its parts with ``IIRSystem`` and ``FIRSystem``.

## Topics

### Gain and filters

- ``Gain``
- ``LowPass``
- ``HighPass``
- ``BandPass``
- ``BandStop``
- ``Filter``
- ``FilterDesign``
- ``FilterResponse``

### Equalisers

- ``BandBoost``
- ``LowShelf``
- ``HighShelf``
- ``MatchedPeak``
- ``Bandwidth``
- ``ShelfSlope``
- ``EqualizerDesign``
- ``MatchedPeakDesign``

### Smoothing

- ``SavitzkyGolay``
- ``SavitzkyGolayEdge``
- ``AlphaBeta``

### Rate changes and convolution

- ``Decimate``
- ``Interpolate``
- ``Subsample``
- ``Upsample``
- ``Convolve``
- ``ConvolutionStrategy``

### IIR design

- ``IIRDesign``
- ``FilterFamily``
- ``ButterworthFamily``
- ``Chebyshev1Family``
- ``Chebyshev2Family``
- ``EllipticFamily``
- ``BesselFamily``
- ``BesselNormalization``
- ``FilterOrderStrategy``
- ``FilterOrderEstimate``
- ``ButterworthOrderStrategy``
- ``Chebyshev1OrderStrategy``
- ``Chebyshev2OrderStrategy``
- ``EllipticOrderStrategy``
- ``AnalogPrototype``
- ``FrequencyTransformation``

### FIR design

- ``FIRDesign``
- ``FIRDesignMethod``
- ``WindowedSincMethod``
- ``LeastSquaresMethod``
- ``LeastSquares``

### Systems

- ``LTISystem``
- ``IIRSystem``
- ``FIRSystem``
- ``IIRSystemBuilder``
- ``FIRSystemBuilder``
- ``IIRSystemContent``
- ``FIRSystemContent``
- ``SystemElement``
- ``IIRSystemElement``
- ``FIRSystemElement``
- ``Pole``
- ``Zero``
- ``Section``
- ``Taps``
- ``TransferFunction``
- ``ZeroPoleGain``
- ``SecondOrderSections``
- ``DifferenceEquation``
- ``SystemDomain``
- ``SystemKind``

### Analysis of a system

- ``SystemAnalysis``
- ``MagnitudeScale``
- ``RootConditions``
- ``Polynomial``
- ``PolynomialRootFinder``
- ``CompanionQRRootFinder``
