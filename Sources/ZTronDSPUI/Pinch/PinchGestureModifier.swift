import SwiftUI

/// One pinch as the gestures deliver it: the tracker that reads it, the touches of a gesture
/// that reports each finger, and where the pinch stood last. A view keeps one of these for
/// as long as it lives; changing it invalidates nothing.
///
/// Threading: main actor.
@MainActor
final class PinchSession {
    private var tracker: PinchTracker?
    private var last: PinchState?
    /// The fingers of a gesture that reports each touch by itself (iOS 18 and later).
    private var touches = TouchBook<AnyHashable>()

    /// Takes one report of a gesture. Returns where the pinch stands, or `nil` while nothing
    /// scales yet.
    func feed(_ sample: PinchSample, enabled: Axis.Set) -> PinchState? {
        if tracker?.enabled != enabled { tracker = PinchTracker(enabled: enabled) }
        guard let state = tracker?.update(sample) else { return nil }
        last = state
        return state
    }

    /// One finger of a gesture that reports each touch moved or lifted. Returns the pinch's
    /// state while two fingers are down, and the last state, marked as ended, when the pinch
    /// has just lost a finger.
    func touch(_ id: AnyHashable, at location: CGPoint, isDown: Bool, enabled: Axis.Set) -> (state: PinchState, ended: Bool)? {
        touches.record(id, at: location, isDown: isDown)
        if let pair = touches.pair {
            return feed(.touches(pair.0, pair.1), enabled: enabled).map { ($0, false) }
        }
        return finish().map { ($0, true) }
    }

    /// The fingers lifted. Returns where the pinch stood, once, or `nil` when there was none.
    func finish() -> PinchState? {
        defer {
            tracker?.end()
            last = nil
        }
        return last
    }

    /// Forgets every touch: the gesture is over.
    func clearTouches() {
        touches.clear()
    }
}

/// Plays pinches into a surface in the place of the gestures: a hosted test feeds it the
/// samples a gesture would report, and they take the way a gesture's take, through the
/// session and the tracker to the view (the seam of WP-819). Injected through the
/// environment; without one only fingers pinch.
///
/// Threading: main actor.
@MainActor
final class PinchScript {
    /// Set by the surface that listens, for as long as it is on screen with a pinch enabled.
    fileprivate var deliver: (@MainActor (PinchSample) -> Void)?
    fileprivate var move: (@MainActor (AnyHashable, CGPoint, Bool) -> Void)?
    fileprivate var lift: (@MainActor () -> Void)?

    /// True while a surface with a pinch enabled listens.
    var isHeard: Bool { deliver != nil }

    /// One report of a gesture.
    func feed(_ sample: PinchSample) {
        deliver?(sample)
    }

    /// One finger of a gesture that reports each touch by itself went down or moved
    /// (`isDown`), or lifted: what the gesture of iOS 18 and later reports.
    func touch(_ id: AnyHashable, at location: CGPoint, isDown: Bool = true) {
        move?(id, location, isDown)
    }

    /// The fingers lift.
    func end() {
        lift?()
    }
}

/// Which gestures a surface reads a pinch from (PINCH-8): one path per OS.
enum PinchPath: Equatable, Sendable {
    /// iOS 18 and later: `SpatialEventGesture`, which reports both touch locations.
    case touches
    /// iOS 17: `MagnifyGesture` with a simultaneous `DragGesture`.
    case magnify
    /// iOS 15 and 16: `MagnificationGesture` with a simultaneous `DragGesture`.
    case legacy

    /// The path of the OS the process runs on.
    static var current: PinchPath {
        if #available(iOS 18.0, *) { return .touches }
        if #available(iOS 17.0, *) { return .magnify }
        return .legacy
    }
}

/// Installs the pinch gesture of §8.8 on a surface, by the path of the OS it runs on
/// (PINCH-8), and reports where the pinch stands.
///
/// | OS | Gestures |
/// |---|---|
/// | iOS 18 and later | `SpatialEventGesture`: both touch locations. |
/// | iOS 17 | `MagnifyGesture` with a simultaneous `DragGesture`. |
/// | iOS 15 and 16 | `MagnificationGesture` with a simultaneous `DragGesture`. |
///
/// With no axis enabled nothing is installed (PINCH-1). What each path's gestures report is
/// turned into a ``PinchSample`` and nothing more; everything else is the tracker's.
///
/// Threading: main actor.
struct PinchGestureModifier: ViewModifier {
    /// The axes `.pinchScaling(_:)` enabled, limited to what the component can scale.
    let axes: Axis.Set
    /// The size of the surface, in points.
    let size: CGSize
    /// What the surface shows: when it changes, `onPinch` may have changed with it.
    let shown: SurfaceContent
    let onPinch: @MainActor (PinchState, CGSize, Bool) -> Void

    @Environment(\.dspPinchScript) private var script
    /// The path a test asks for in the place of the OS's own, to see an older path installed.
    @Environment(\.dspPinchPath) private var forcedPath
    /// The pinch as the gestures deliver it, for as long as the view lives.
    @State private var session = PinchSession()

    func body(content: Content) -> some View {
        // The surface keeps its place whether a pinch is enabled or not: the gesture lies on
        // a clear layer above it, and with no axis enabled there is no such layer (PINCH-1).
        content.overlay(alignment: .center) { catcher }
    }

    @ViewBuilder
    private var catcher: some View {
        if !axes.isEmpty {
            gestured(Color.clear.contentShape(Rectangle())).background(listener)
        }
    }

    /// The clear layer with the gestures of the path: the OS's own, unless a test asks for an
    /// older one. A path that the OS does not have falls back to the oldest, which every OS has.
    @ViewBuilder
    private func gestured(_ layer: some View) -> some View {
        switch forcedPath ?? .current {
        case .touches:
            if #available(iOS 18.0, *) { layer.gesture(touchGesture) } else { layer.gesture(legacyGesture) }
        case .magnify:
            if #available(iOS 17.0, *) { layer.gesture(magnifyGesture) } else { layer.gesture(legacyGesture) }
        case .legacy:
            layer.gesture(legacyGesture)
        }
    }

    /// Lets a test's script deliver what a gesture would.
    private func listen() {
        guard let script else { return }
        script.deliver = { sample in sampled(sample) }
        script.move = { id, location, isDown in touched(id, at: location, isDown: isDown) }
        script.lift = { lifted() }
    }

    private var listener: some View {
        Color.clear
            .onAppear { listen() }
            .onChange(of: size) { _ in listen() }
            .onChange(of: axes) { _ in listen() }
            .onChange(of: shown) { _ in listen() }
            .onDisappear {
                script?.deliver = nil
                script?.move = nil
                script?.lift = nil
            }
    }

    // MARK: What the gestures report, as the tracker's samples

    /// A gesture reported the pinch as a whole.
    private func sampled(_ sample: PinchSample) {
        guard let state = session.feed(sample, enabled: axes) else { return }
        onPinch(state, size, false)
    }

    /// A gesture reported one finger.
    private func touched(_ id: AnyHashable, at location: CGPoint, isDown: Bool) {
        guard let step = session.touch(id, at: location, isDown: isDown, enabled: axes) else { return }
        onPinch(step.state, size, step.ended)
    }

    /// The gesture ended.
    private func lifted() {
        if let state = session.finish() { onPinch(state, size, true) }
        session.clearTouches()
    }

    // MARK: The gestures, by OS (PINCH-8)

    @available(iOS 18.0, *)
    private var touchGesture: some Gesture {
        SpatialEventGesture(coordinateSpace: .local)
            .onChanged { events in events.forEach { touched(AnyHashable($0.id), at: $0.location, isDown: $0.phase == .active) } }
            .onEnded { _ in lifted() }
    }

    @available(iOS 17.0, *)
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard let pinch = value.first else { return }
                sampled(.magnification(scale: pinch.magnification, start: pinch.startLocation, firstFingerStart: value.second?.startLocation))
            }
            .onEnded { _ in lifted() }
    }

    private var legacyGesture: some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard let scale = value.first else { return }
                sampled(.legacy(scale: scale, firstFingerStart: value.second?.startLocation, firstFingerTravel: value.second?.translation))
            }
            .onEnded { _ in lifted() }
    }
}
