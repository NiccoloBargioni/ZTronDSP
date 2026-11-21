# ``ZTronDSPUI``

SwiftUI views that draw what a source or a pipeline produces, the modifiers that attach a pipeline
to a view's life, and the bridge that puts a session's environment into SwiftUI's.

## Overview

A view of this module draws a feed of the core with a renderer of `ZTronDSPMetal`: ``HeatmapView``
the columns of a `HeatmapFeed`, ``WaveformView`` a `WaveformFeed`, and ``SpectrogramView``,
``ChromagramView`` and ``TempogramView`` the feeds of the matching recipes, either from a feed of
the app's or from a source, for which the view attaches the pipeline itself. The axis views label
a heatmap or a waveform in its own units. Every view runs on the main actor, as SwiftUI's do; its
renderer allocates its textures when its surface is made, and again only when the feed's shape
changes.

The modifiers are methods of `View`. `.pipeline(_:on:)` attaches a pipeline to a source for as long
as the view is shown, and `.processing { … }` puts stages in front of what the source-fed views
inside compute; `.dspEngine(_:)` names the engine they attach to, and `.dspEnvironment(_:)` puts a
session's sample rate, Nyquist frequency, channel count and latency into SwiftUI's environment.
`.colorMap(_:)`, `.valueRange(_:)`, `.frequencyScale(_:)` and their siblings set how the views
inside draw.

## Topics

### Heatmaps

- ``HeatmapView``
- ``SpectrogramView``
- ``ChromagramView``
- ``TempogramView``

### Waveforms

- ``WaveformView``

### Axes

- ``FrequencyAxisView``
- ``PitchClassAxisView``
- ``TempoAxisView``
- ``TimeAxisView``
- ``DSPAxis``
