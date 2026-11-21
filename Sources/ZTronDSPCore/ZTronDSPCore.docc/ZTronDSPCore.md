# ``ZTronDSPCore``

Describing a pipeline, compiling it into a plan and running it: the stage protocols, signal
domains, environment, engine, sources, feeds and the toolkit that every stage is built from.

## Overview

The core holds no processing stage. It holds what a stage is (``StageValue``, ``PipelineStage``,
``SequenceStage``), what a pipeline is (``Pipeline``, written with ``PipelineBuilder`` or with
fluent methods), the constructs that give a pipeline its shape (``Tap``, ``Group``,
``EnvironmentReader``, ``Emit``), and what runs it: ``DSPEngine`` compiles a pipeline on the control
context into a plan and runs the plan on its analysis thread, for one ``PipelineSession`` per
attachment. The stock stages live in `ZTronDSPDesign` and `ZTronDSPAnalysis` and use nothing of
this module that a stage written outside the package cannot use.

Every symbol's documentation states its threading contract in the words of the execution contexts:
the control context, the analysis thread, the I/O thread, the main thread or main actor, the
background executor, or any thread; and whether it allocates.

## Topics

### Describing a pipeline

- ``Pipeline``
- ``PipelineBuilder``
- ``PipelineContent``
- ``SequenceChain``
- ``DynamicPipeline``

### Stages

- ``StageValue``
- ``PipelineStage``
- ``SequenceStage``
- ``Recipe``
- ``StageDescription``
- ``StagePath``
- ``DomainRule``

### The shape of a pipeline

- ``Tap``
- ``Group``
- ``EnvironmentReader``
- ``Emit``
- ``Measuring``

### Switching stages on and off

- ``ActivationSource``
- ``StageActivation``
- ``Activation``
- ``ActivatedStage``
- ``ActivatedSequenceStage``
- ``BoundSwitch``

### Signal domains

- ``SignalDomain``
- ``SampledSequence``
- ``RealVectorDomain``
- ``ScalarValuedDomain``
- ``DomainTag``
- ``Samples``
- ``Spectrum``
- ``SpectralAxis``
- ``SpectralValues``
- ``LinearFrequency``
- ``MelFrequency``
- ``ConstantQFrequency``
- ``ComplexValues``
- ``MagnitudeValues``
- ``PowerValues``
- ``DecibelValues``
- ``Quefrency``
- ``MelCepstrum``
- ``Chroma``
- ``Lags``
- ``TempoSpectrum``
- ``Envelope``
- ``Novelty``
- ``Scalar``

### Units and values

- ``Frequency``
- ``Amplification``
- ``RollOff``
- ``RollOffRounding``
- ``Window``
- ``ZeroPadding``
- ``Ramp``
- ``Complex``

### The environment

- ``DSPEnvironment``
- ``DSPEnvironmentKey``
- ``SettableDSPEnvironmentKey``
- ``BiquadPrecision``
- ``BiquadPrecisionKey``
- ``ImplementationKey``
- ``ResultRateKey``

### Engine and sessions

- ``DSPEngine``
- ``PipelineSession``
- ``SessionState``
- ``SessionEvent``
- ``ReplanReason``
- ``DSPError``
- ``CrossoverTable``
- ``Implementation``
- ``Primitive``

### Sources

- ``SampleSource``
- ``PushSampleSource``
- ``PullSampleSource``
- ``SignalFormat``
- ``SourceKind``
- ``SourceEvent``
- ``SourceEventChannel``
- ``Pacing``
- ``ChannelPolicy``
- ``BufferSource``
- ``GeneratorSource``
- ``ScriptedSource``
- ``ProcessedSource``

### Results and feeds

- ``HeatmapFeed``
- ``WaveformFeed``
- ``FeatureStream``
- ``FeatureCallback``
- ``FeatureSink``
- ``ScalarResultTarget``
- ``VectorResultTarget``
- ``ScalarResultValue``
- ``BoundResult``
- ``FeedCursor``
- ``FeedRead``
- ``FeedSnapshot``
- ``FeedAxis``
- ``FeedObservation``

### Writing a stage

- ``LoweringContext``
- ``KernelSpec``
- ``CustomKernel``
- ``CustomProcessor``
- ``SampleProcessor``
- ``AdjustableSampleProcessor``
- ``OutOfPlaceSampleProcessor``
- ``AnalysisNode``
- ``AnalysisStep``
- ``AnyStrategy``
- ``StageValidation``
- ``ParameterVector``

### The toolkit

- ``DSP``
- ``Vector``
- ``AudioBlock``
- ``AudioBuffer``
- ``AlignedBuffer``
- ``FrameView``
- ``FrameWriter``
- ``RingWriter``
- ``HistoryBuffer``
- ``OverlapAdder``
- ``MedianNetwork``

### In the background

- ``BackgroundWork``
- ``AnalysisScheduling``
- ``MATLABScript``
- ``MATLABExportable``
