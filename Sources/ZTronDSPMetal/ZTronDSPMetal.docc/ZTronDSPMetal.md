# ``ZTronDSPMetal``

Textures, renderers and GPU compute kernels: what draws a feed, and what computes on the GPU for
the analysis steps. No views.

## Overview

A renderer draws a feed into whatever render pass it is handed: ``HeatmapRenderer`` the columns of
a `HeatmapFeed`, ``WaveformRenderer`` the envelope of a `WaveformFeed`. It runs on the main actor,
does nothing on a display tick unless something is pending, uploads exactly the columns that
arrived since its last draw, and allocates its data texture again only when the feed changes
shape. ``MetalContext`` holds the device, its command queue and the shader library: the build
compiles the shaders into the module's resource bundle, a context loads them and builds its
pipeline states once, off the main thread, and ``MetalContext/shared()`` keeps one for the life of
the process. The sizes at which a primitive moves to another implementation are measured with
``Calibration`` and kept as data, in the core's `CrossoverTable`.

## Topics

### Renderers

- ``HeatmapRenderer``
- ``WaveformRenderer``
- ``RowInterpolation``
- ``RenderProbe``
- ``RenderCauses``

### Colour and frequency scales

- ``ColorMap``
- ``TurboColorMap``
- ``GrayscaleColorMap``
- ``ListedColorMap``
- ``DisplayColor``
- ``FrequencyScale``
- ``LinearFrequencyScale``
- ``LogarithmicFrequencyScale``
- ``MelFrequencyScale``

### The device and its kernels

- ``MetalContext``
- ``MetalCapabilities``
- ``MetalMedianFilter``

### Images

- ``OffscreenTarget``
- ``PixelImage``

### Crossovers and calibration

- ``Calibration``
- ``CalibrationCandidate``
- ``CalibrationCurve``
- ``CalibrationReport``
- ``CrossoverEntry``
- ``CrossoverMeasurement``
