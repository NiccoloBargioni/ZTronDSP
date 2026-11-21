import MetalKit
import SwiftUI
import Testing
import UIKit
import ZTronDSPMetal
@testable import ZTronDSPGallery
@testable import ZTronDSPUI

// UIKit is imported in this target for one purpose: hosting a SwiftUI view under test in the
// application, and looking at what hosts it (UB-6). The tests run inside the gallery: there
// is an application, a scene in the foreground, a display, and a display link that ticks.
//
// What the application gives a hosted view, as found on the iOS 27.0, 18.6 and 17.5
// simulators:
//
// - a view of the application's own scene (`WindowGroup`) reads `\.scenePhase` as `.active`;
// - a view in a `UIHostingController` reads `.background`, in the application as in a bare
//   test process, although its window belongs to the scene in the foreground. A component
//   therefore never draws there unless the host hands the phase down, as the components'
//   documentation asks of it; a surface that is told none says so once in the log
//   (`HostingControllerTests`). `Stateful` hands its content the phase the application's
//   scene reads, so that the value and its changes are the real ones.

/// The application's scene.
@MainActor
enum AppScene {
    /// The scene, once it is in the foreground and the gallery's root view can be driven.
    static func active() async throws -> UIWindowScene {
        var found: UIWindowScene?
        _ = await eventually(timeout: 300) {
            found = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            return found != nil && GalleryPilot.shared.isReady && GalleryPilot.shared.scenePhase == .active
        }
        return try #require(found, "the application has a scene in the foreground")
    }
}

extension UIWindowScene {
    /// Asks the scene to turn its interface, which it does with the animation of a turned
    /// device. `refused` is told, on the main actor, why the system did not do it.
    ///
    /// The system calls the error handler of a geometry request on a queue of its own when
    /// it gives the request up (seen on iOS 18.6, on a loaded machine: a request that was not
    /// answered in time). A closure written in a test would belong to the main actor and
    /// trap there, so the handler given to the system belongs to no actor and hands what it
    /// was told over.
    @MainActor
    func turnInterface(to orientations: UIInterfaceOrientationMask, refused: @escaping @MainActor (String) -> Void = { _ in }) {
        requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { @Sendable error in
            let reason = error.localizedDescription
            Task { @MainActor in refused(reason) }
        }
    }
}

/// A SwiftUI view in a window of its own, in the application's scene.
@MainActor
final class Hosted<Content: View> {
    let window: UIWindow
    private let controller: UIHostingController<Content>

    init(in scene: UIWindowScene, size: CGSize = CGSize(width: 240, height: 160), _ content: Content) {
        controller = UIHostingController(rootView: content)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: CGPoint(x: 20, y: 100), size: size)
        window.windowLevel = .normal + 1
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Takes the view out of the hierarchy: `onDisappear` runs and Metal views are dismantled.
    ///
    /// SwiftUI may keep what it hosted alive for a while after its window is gone (seen on
    /// iOS 17.5), and a surface that lived on would tick in the tests that follow. So the
    /// surfaces of the hierarchy are ended here, by what `dismantleUIView` calls.
    func close() {
        for coordinator in coordinators { coordinator.detach() }
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The Metal views of the hierarchy, in the order they are found.
    var metalViews: [MTKView] {
        MetalViews.all(in: window)
    }

    /// The coordinators of the surfaces the hierarchy holds.
    var coordinators: [SurfaceCoordinator] {
        metalViews.compactMap { MetalViews.coordinator(of: $0) }
    }
}

/// Finds the Metal views a SwiftUI hierarchy made, and what stands behind them.
@MainActor
enum MetalViews {
    static func all(in view: UIView) -> [MTKView] {
        var found: [MTKView] = []
        func search(_ view: UIView) {
            if let metal = view as? MTKView { found.append(metal) }
            view.subviews.forEach(search)
        }
        search(view)
        return found
    }

    /// True while `view` is where a person could see it: in a window, inside the window's
    /// bounds, neither hidden nor under a hidden view, and still the bridge's (a Metal view
    /// that SwiftUI has dismantled has no delegate any more).
    static func isShown(_ view: MTKView) -> Bool {
        guard view.delegate != nil, let window = view.window else { return false }
        guard view.convert(view.bounds, to: nil).intersects(window.bounds) else { return false }
        var current: UIView? = view
        while let here = current {
            if here.isHidden || here.alpha == 0 { return false }
            current = here.superview
        }
        return true
    }

    /// The coordinator that decides for `view`, through the delegate the bridge gave it, or
    /// through a tap a test put in front of that delegate.
    static func coordinator(of view: MTKView) -> SurfaceCoordinator? {
        if let host = view.delegate as? MetalViewHost { return host.coordinator }
        if let tap = view.delegate as? MetalViewTap { return tap.coordinator }
        return nil
    }
}

/// Stands between a hosted Metal view and the delegate the bridge gave it, passes both of the
/// view's calls on, and counts them: how often the view was asked for a frame, which is how
/// often a drawable was taken, and which drawable sizes the view announced.
@MainActor
final class MetalViewTap: NSObject, MTKViewDelegate {
    let view: MTKView
    let coordinator: SurfaceCoordinator
    private let host: MetalViewHost
    /// Times the view asked its delegate for a frame.
    private(set) var frames = 0
    /// The drawable sizes the view announced, in order.
    private(set) var announcedSizes: [CGSize] = []
    /// Called when the view announces a drawable size, before the bridge hears of it.
    var onSizeChange: (@MainActor (CGSize) -> Void)?
    /// Called around the frame the bridge draws: before it with `false`, after it with `true`.
    var onFrame: (@MainActor (MTKView, Bool) -> Void)?

    /// Puts a tap in front of the delegate of `view`; `nil` when the view is not one the
    /// bridge made.
    init?(_ view: MTKView) {
        guard let host = view.delegate as? MetalViewHost else { return nil }
        self.view = view
        self.host = host
        coordinator = host.coordinator
        super.init()
        view.delegate = self
    }

    /// Gives the view its own delegate back.
    func remove() {
        if view.delegate === self { view.delegate = host }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        announcedSizes.append(size)
        onSizeChange?(size)
        host.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        frames += 1
        onFrame?(view, false)
        host.draw(in: view)
        onFrame?(view, true)
    }
}

/// The test's hand on the state of the view under test.
@MainActor
final class StateHandle<Value> {
    fileprivate var read: (() -> Value)?
    fileprivate var write: ((Value, Animation?, @escaping () -> Void) -> Void)?
    fileprivate var force: ((ScenePhase?) -> Void)?
    /// The scene phases the view was given, in order.
    fileprivate(set) var phases: [ScenePhase] = []

    /// True once the view is in the hierarchy.
    var isConnected: Bool { write != nil }

    /// The state's value now.
    var value: Value? { read?() }

    /// The scene phase the view under test reads now.
    var phase: ScenePhase? { phases.last }

    /// Sets the state, as a control would.
    func set(_ value: Value) {
        write?(value, nil, {})
    }

    /// Sets the state inside `withAnimation` and returns when the animation has completed.
    func animate(to value: Value, _ animation: Animation) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let write else {
                continuation.resume()
                return
            }
            write(value, animation) { continuation.resume() }
        }
    }

    /// Sets the state inside `withAnimation` and returns at once: the animation is on its way.
    func startAnimation(to value: Value, _ animation: Animation, completion: @escaping () -> Void = {}) {
        write?(value, animation, completion)
    }

    /// Gives the view a scene phase of the test's choosing in the place of the application's;
    /// `nil` gives it the application's again.
    func forcePhase(_ phase: ScenePhase?) {
        force?(phase)
    }
}

/// A root view that owns one piece of state and gives the test a handle on it.
///
/// A view in a hosting controller is not told the phase of its scene (see the head of this
/// file), so the root hands its content the phase the application's own scene reads, and
/// follows it when it changes.
struct Stateful<Value, Content: View>: View {
    @State private var value: Value
    /// The phase of the application's scene.
    @State private var phase = GalleryPilot.shared.scenePhase ?? .background
    /// A phase the test put in its place.
    @State private var forced: ScenePhase?
    @State private var listener: Int?
    private let handle: StateHandle<Value>
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, _ handle: StateHandle<Value>, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.handle = handle
        self.content = content
    }

    var body: some View {
        let shown = forced ?? phase
        let _ = note(shown)
        content($value)
            .environment(\.scenePhase, shown)
            .ignoresSafeArea()
            .onAppear {
                handle.read = { value }
                handle.write = { next, animation, completion in
                    guard let animation else {
                        value = next
                        completion()
                        return
                    }
                    withAnimation(animation) { value = next } completion: { completion() }
                }
                handle.force = { forced = $0 }
                phase = GalleryPilot.shared.scenePhase ?? .background
                listener = GalleryPilot.shared.addPhaseListener { phase = $0 }
            }
            .onDisappear {
                if let listener { GalleryPilot.shared.removePhaseListener(listener) }
                listener = nil
            }
    }

    private func note(_ phase: ScenePhase) {
        if handle.phases.last != phase { handle.phases.append(phase) }
    }
}
