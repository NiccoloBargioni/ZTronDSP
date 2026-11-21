# ``ZTronDSPAnalysis``

The spectral steps and recipes, their strategies, and the analyses that run beside a pipeline: from
the short-time Fourier transform to the mel scale, cepstra, the constant-Q transform and chroma,
onset strength and tempograms, and harmonic–percussive separation.

## Overview

A step names the domain it consumes and the one it produces, so the compiler accepts it only where
it may stand: ``STFT`` turns samples into a complex spectrum, ``Magnitude`` and ``Power`` turn that
into real values, ``MelScale`` and ``Decibels`` follow either. A step whose domains depend on what
comes before it is a ``ContextDependentStep``. A recipe, such as ``Spectrogram`` or ``MFCC``, stands
for the steps it expands to. A strategy decides how a step computes what it computes (the FFT
backend, the constant-Q kernel, the median filter, the mask of a separation): the stock strategies
are public, and an app may write its own.

Steps are designed when the pipeline is attached, on the control context; their kernels and nodes
run on the analysis thread without allocating. The analyses of windows and of inversions are
computed in the background, on the package's background executor, which allocates; what they
return are immutable values, usable on any thread.

## Topics

### The spectral front-end

- ``STFT``
- ``InverseSTFT``
- ``Magnitude``
- ``Power``
- ``Decibels``
- ``InverseDecibels``
- ``LinearValueKind``
- ``Framer``
- ``FrameAlignment``
- ``WindowNormalization``

### Recipes

- ``Spectrogram``
- ``MelSpectrogram``
- ``MFCC``
- ``ChromaCQT``
- ``HPSS``

### The mel scale and cepstra

- ``MelScale``
- ``MelFilterBank``
- ``MelNormalization``
- ``SlaneyMelNormalization``
- ``UnitPeakMelNormalization``
- ``Cepstrum``
- ``CepstrumKind``
- ``InverseCepstrum``
- ``Lifter``
- ``CepstralPitch``
- ``CepstralCoefficients``
- ``InverseCepstralCoefficients``

### Features of a spectrum

- ``SpectralCentroid``
- ``Level``
- ``LevelKind``
- ``Waveform``
- ``ScalarTrack``
- ``MeasuredSpectrum``
- ``FrequencyRange``

### The constant-Q transform and chroma

- ``ConstantQ``
- ``ConstantQScale``
- ``ConstantQStrategy``
- ``MultirateSparseKernelStrategy``
- ``ConstantQGeometry``
- ``ConstantQKernel``
- ``ChromaFold``
- ``ChromaNormalization``
- ``L1ChromaNormalization``
- ``L2ChromaNormalization``
- ``MaximumChromaNormalization``
- ``UnscaledChromaNormalization``

### Convolution and correlation

- ``Autocorrelation``
- ``ConvolutionMode``
- ``CorrelationNormalization``
- ``ConvolutionCrossover``

### Rhythm

- ``OnsetStrength``
- ``Tempogram``
- ``TempogramMethod``
- ``TempogramTransform``
- ``AutocorrelationTempogram``
- ``FourierTempogram``

### Harmonic–percussive separation

- ``HarmonicPercussive``
- ``HarmonicPercussiveComponent``
- ``MaskStrategy``
- ``SoftMask``
- ``HardMask``
- ``MedianStrategy``
- ``MedianFilter``
- ``MedianAxis``
- ``AutomaticMedian``
- ``SelectionNetworkMedian``
- ``MetalMedian``

### Steps and their strategies

- ``ContextDependentStep``
- ``InvertibleStage``
- ``FFTBackend``
- ``FFTPlan``
- ``VDSPFFTBackend``

### Inversion and window analyses

- ``InversionReport``
- ``InversionContext``
- ``InversionCondition``
- ``InversionMeasurement``
- ``InversionRoundTrip``
- ``WindowAnalysis``
- ``AnalysisCalibrationReport``
