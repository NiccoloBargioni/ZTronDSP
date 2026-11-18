import SwiftUI
import ZTronDSPCore
import ZTronDSPMetal

/// The Metal surface of a component, as SwiftUI animates it (ANI-1, SZ-4).
///
/// This is the `Animatable` between the values the appearance modifiers set and the Metal
/// view. Its animatable data are the continuous values of the appearance (value range, time
/// span, vertical range, amplitude range) and the size the surface is laid out at. Inside
/// `withAnimation`, or under `.animation(_:value:)`, SwiftUI hands it one interpolated set per
/// display frame; each goes to the Metal view as one update, which is one draw with other
/// uniforms and no upload. The size is the probe of §8.9: during an animated change of size
/// the surface learns one interpolated size per display frame.
///
/// Colour map and frequency scale are not interpolated: they change at once.
///
/// Threading: main actor. The body depends on no per-frame data (V-1).
struct SurfaceHost: View, Animatable {
    /// What the modifiers ask for: the values an animation ends at.
    let content: SurfaceContent
    /// The continuous values of `content`.
    let rest: AppearanceVector
    /// The continuous values this frame shows: `rest`, unless an animation is on its way.
    var shown: AppearanceVector
    /// The size the surface is laid out at in this frame, in points.
    var size: CGSize
    let maximumFrameRate: Int
    let isPresented: Bool
    let probe: RenderProbe?
    let clocks: ClockSource?
    let inspector: SurfaceInspector?

    init(
        content: SurfaceContent, vector: AppearanceVector, size: CGSize, maximumFrameRate: Int, isPresented: Bool, probe: RenderProbe? = nil,
        clocks: ClockSource? = nil, inspector: SurfaceInspector? = nil
    ) {
        self.content = content
        rest = vector
        shown = vector
        self.size = size
        self.maximumFrameRate = maximumFrameRate
        self.isPresented = isPresented
        self.probe = probe
        self.clocks = clocks
        self.inspector = inspector
    }

    nonisolated var animatableData: AnimatablePair<AppearanceVector, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(shown, AnimatablePair(size.width, size.height)) }
        set {
            shown = newValue.first
            size = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    /// What the surface shows in this frame: the content, with the continuous values of an
    /// animation that is on its way.
    var shownContent: SurfaceContent {
        switch content {
        case .heatmap(let feed, let appearance): .heatmap(feed, appearance.showing(shown, rest: rest))
        case .waveform(let feed, let appearance): .waveform(feed, appearance.showing(shown, rest: rest))
        }
    }

    var body: some View {
        MetalViewRepresentable(input: SurfaceInput(
            content: shownContent, maximumFrameRate: maximumFrameRate, isPresented: isPresented, size: size, probe: probe, clocks: clocks,
            inspector: inspector))
    }
}

/// The place of a Metal surface in a component: it measures the size the surface is given,
/// knows whether the surface is on screen in an active scene, and carries the pinch gesture
/// when one is enabled.
///
/// Threading: main actor. The only state it writes is whether the view is on screen, when
/// that changes (V-2).
struct SurfaceFrame: View {
    let content: SurfaceContent
    let vector: AppearanceVector
    /// The axes a pinch may scale; empty installs no gesture (PINCH-1).
    let pinchAxes: Axis.Set
    /// Called for every step of a pinch with where it stands, the size of the surface, and
    /// whether the fingers have lifted.
    let onPinch: @MainActor (PinchState, CGSize, Bool) -> Void

    @Environment(\.dspMaximumFrameRate) private var maximumFrameRate
    @Environment(\.dspRenderProbe) private var probe
    @Environment(\.dspClockSource) private var clocks
    @Environment(\.dspSurfaceInspector) private var inspector
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    var body: some View {
        GeometryReader { proxy in
            SurfaceHost(content: content, vector: vector, size: proxy.size, maximumFrameRate: maximumFrameRate,
                        isPresented: isOnScreen && scenePhase == .active, probe: probe, clocks: clocks, inspector: inspector)
                .modifier(PinchGestureModifier(axes: pinchAxes, size: proxy.size, shown: content, onPinch: onPinch))
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

// MARK: Values a view keeps for itself (PINCH-5)

/// A value a pinch scaled when the modifier that sets it was given a constant: the view
/// keeps the scaled value itself until the constant changes.
struct Kept<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The constant the view had when the pinch scaled it; `nil` when no modifier set one.
    var base: Value?
    /// What the pinch made of it.
    var value: Value
}

extension Optional {
    /// The value a component shows for a setting: the binding's; or the value a pinch left,
    /// as long as the constant is the one the pinch began with; or the constant; or `nil`
    /// when no modifier set anything and nothing was pinched.
    @MainActor
    func shown<Value>(keeping kept: Kept<Value>?) -> Value? where Wrapped == AppearanceSetting<Value> {
        if case .bound(let binding)? = self { return binding.wrappedValue }
        let constant = self?.constant
        if let kept, kept.base == constant { return kept.value }
        return constant
    }

    /// Stores what a pinch made of a setting: writes the binding and returns `nil`, or
    /// returns what the view has to keep for a constant.
    @MainActor
    func storing<Value>(_ value: Value) -> Kept<Value>? where Wrapped == AppearanceSetting<Value> {
        if case .bound(let binding)? = self {
            if binding.wrappedValue != value { binding.wrappedValue = value }
            return nil
        }
        return Kept(base: self?.constant, value: value)
    }
}
