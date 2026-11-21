import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

// The appearance of a component is set with modifiers, one value each, never with a style
// object (VC-4, API-6). Each modifier puts its value into the SwiftUI environment, so it may
// sit on the component or on any view around it, in any order, and one modifier can serve
// several components.
//
// A value that is set to what it already is causes nothing: the surface compares what it is
// asked to show with what it shows (V-3). A change costs one draw and uploads nothing (§8.4).
//
// Threading: main actor, like every view modifier. None of them allocates beyond the small
// value it stores.

extension View {
    /// The colours a heat map shows its values in: `.viridis` (the default), `.magma`,
    /// `.inferno`, `.turbo`, `.grayscale`, stops of your own, or a map written outside the
    /// package.
    ///
    /// Discrete: a change takes effect at once and is not animated (ANI-1).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func colorMap(_ map: some ColorMap) -> some View {
        environment(\.dspColorMap, AnyColorMap(map))
    }

    /// The values a heat map shows as the first and as the last colour of its map; values
    /// outside are clamped. Decibels for a spectrogram (the default is −90 … 0), plain values
    /// for a chromagram or a tempogram (0 … 1).
    ///
    /// Animatable: inside `withAnimation` the view is redrawn once per display frame with an
    /// interpolated range (ANI-1).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func valueRange(_ range: ClosedRange<Float>) -> some View {
        environment(\.dspValueRange, .constant(range))
    }

    /// The value range, read from a binding.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func valueRange(_ range: Binding<ClosedRange<Float>>) -> some View {
        environment(\.dspValueRange, .bound(range))
    }

    /// How the frequency axis of a heat map is laid out: `.linear` (the default),
    /// `.logarithmic`, `.mel`, or a scale written outside the package.
    ///
    /// The scale warps rows that are evenly spaced in hertz, for display only. A feed whose
    /// rows are already mel bands, constant-Q bins, pitch classes or tempi is drawn bin for
    /// bin whatever the scale (VC-5). Discrete: a change takes effect at once.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func frequencyScale(_ scale: some FrequencyScale) -> some View {
        environment(\.dspFrequencyScale, AnyFrequencyScale(scale))
    }

    /// What the bottom and the top edge of a heat map show, in the unit of the feed's axis:
    /// hertz for a spectrogram, beats per minute for a tempogram, seconds for lags and
    /// quefrencies, row numbers otherwise. Without this modifier the whole axis is shown.
    ///
    /// A range that reaches beyond the axis is cut off at its ends. Animatable (ANI-1). With
    /// `.pinchScaling(.vertical)` a pinch scales the range, and the view keeps the scaled
    /// range itself until this one changes (PINCH-5).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func frequencyRange(_ range: ClosedRange<Double>) -> some View {
        environment(\.dspFrequencyRange, .constant(range))
    }

    /// The vertical range, read from a binding; a vertical pinch writes it (PINCH-5).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func frequencyRange(_ range: Binding<ClosedRange<Double>>) -> some View {
        environment(\.dspFrequencyRange, .bound(range))
    }

    /// The seconds a component shows across its width, the present at the right edge.
    /// Without this modifier the feed's whole history is shown.
    ///
    /// The span changes what is shown, never what is computed. Animatable (ANI-1). With
    /// `.pinchScaling(.horizontal)` a pinch scales the span, and the view keeps the scaled
    /// span itself until this one changes (PINCH-5).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func timeSpan(_ seconds: Double) -> some View {
        environment(\.dspTimeSpan, .constant(seconds))
    }

    /// The time span, read from a binding; a horizontal pinch writes it (PINCH-5).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func timeSpan(_ seconds: Binding<Double>) -> some View {
        environment(\.dspTimeSpan, .bound(seconds))
    }

    /// The amplitudes at the bottom and at the top edge of a waveform; the default is
    /// −1 … 1, full scale. An envelope that reaches past them is cut off at the edge.
    ///
    /// Animatable (ANI-1). With `.pinchScaling(.vertical)` a pinch scales the range.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func amplitudeRange(_ range: ClosedRange<Float>) -> some View {
        environment(\.dspAmplitudeRange, .constant(range))
    }

    /// The amplitude range, read from a binding; a vertical pinch writes it (PINCH-5).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func amplitudeRange(_ range: Binding<ClosedRange<Float>>) -> some View {
        environment(\.dspAmplitudeRange, .bound(range))
    }

    /// The most frames per second a component draws; the default is 60, and values below 1
    /// count as 1 (§8.3). A component draws only when there is something new to show, so
    /// this is a cap, not a rate.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func maximumFrameRate(_ framesPerSecond: Int) -> some View {
        environment(\.dspMaximumFrameRate, framesPerSecond)
    }

    /// Shows an axis beside the components inside this view (VC-2): `.axis(.frequency)` to
    /// the left of the picture, `.axis(.time)` below it. Several calls add up.
    ///
    /// An axis is a separate view drawn with `Canvas`, labelled from the feed's `FeedAxis`
    /// (VC-5), and redrawn only when the appearance, the feed's axis or the environment
    /// changes. The same views can be placed by themselves: ``FrequencyAxisView``,
    /// ``TimeAxisView``, ``PitchClassAxisView``, ``TempoAxisView``.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func axis(_ axis: DSPAxis) -> some View {
        transformEnvironment(\.dspShownAxes) { $0.formUnion(.axis(axis)) }
    }

    /// Lets a pinch scale the components inside this view along the axes named (PINCH-1):
    /// a horizontal pinch scales the time span, a vertical one the frequency, tempo or
    /// amplitude range. A chromagram's twelve rows are fixed, so it scales in time only.
    ///
    /// The line through the two fingers when the pinch begins decides the axis: within 30° of
    /// horizontal or of vertical it is that axis, otherwise both (PINCH-3). A pinch along an
    /// axis that is not enabled does nothing. Scaling changes what is shown, never what is
    /// computed (PINCH-2). Off by default: without this modifier, or with an empty set, a
    /// component installs no gesture.
    ///
    /// On iOS 18 and later the two touches give the finger line. Before iOS 18 the gestures
    /// report where the first finger went down only when it lands before the second; when
    /// both fingers land in the same moment the finger line is not known, and the pinch
    /// scales every axis named here (PINCH-8). With one axis named that is the same pinch;
    /// with both, a pinch whose fingers land together scales both whatever its direction.
    ///
    /// Threading: main actor, like every view modifier; it stores one small value.
    public func pinchScaling(_ axes: Axis.Set) -> some View {
        environment(\.dspPinchAxes, axes)
    }
}
