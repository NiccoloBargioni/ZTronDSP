import SwiftUI
import Testing
import UIKit
@testable import ZTronDSPUI

// UIKit is imported here for one purpose: hosting a SwiftUI view under test (UB-6).
//
// A package test runs in the test runner's own process, without an application. What that
// process offers was found out before anything was built on it (iOS 27.0 simulator):
//
// - a `UIWindow` with a `UIHostingController` evaluates bodies, runs `onAppear`, `onDisappear`
//   and `.task`, and animates: inside `withAnimation` an `Animatable` receives one
//   interpolated value per display frame;
// - a display link ticks at the display's rate while a window is visible;
// - a Metal view in such a window hands out drawables;
// - `\.scenePhase` reads `.background` there, so a hosted view is given `.active` by hand;
// - there is no touch input: gestures are scripted through their seam;
// - there is no application, so no scene changes its phase and nothing rotates.

/// A SwiftUI view in a window of the test process.
@MainActor
final class Hosted<Content: View> {
    private let window: UIWindow
    private let controller: UIHostingController<Content>

    init(size: CGSize = CGSize(width: 240, height: 160), _ content: Content) {
        controller = UIHostingController(rootView: content)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Takes the view out of the hierarchy: `onDisappear` runs and Metal views are dismantled.
    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// The test's hand on a piece of `@State` of the view under test.
@MainActor
final class StateHandle<Value> {
    fileprivate var read: (() -> Value)?
    fileprivate var write: ((Value, Animation?, @escaping () -> Void) -> Void)?

    /// True once the view is in the hierarchy.
    var isConnected: Bool { write != nil }

    /// The state's value now.
    var value: Value? { read?() }

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
}

/// A root view that owns one piece of state and gives the test a handle on it. The scene
/// phase is set to `.active`, which a view in a real scene reads by itself.
struct Stateful<Value, Content: View>: View {
    @State private var value: Value
    private let handle: StateHandle<Value>
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, _ handle: StateHandle<Value>, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.handle = handle
        self.content = content
    }

    var body: some View {
        content($value)
            .environment(\.scenePhase, .active)
            .onAppear {
                handle.read = { value }
                handle.write = { next, animation, completion in
                    guard let animation else {
                        value = next
                        completion()
                        return
                    }
                    if #available(iOS 17.0, *) {
                        withAnimation(animation) { value = next } completion: { completion() }
                    } else {
                        withAnimation(animation) { value = next }
                        completion()
                    }
                }
            }
    }
}

/// Waits until the display has shown `count` more frames: time passing, measured in what a
/// view could have drawn, not in seconds.
@MainActor
func displayFrames(_ count: Int) async {
    let clock = DisplayLinkClock()
    let seen = Box(0)
    clock.onTick = { _ in seen.value += 1 }
    clock.isPaused = false
    _ = await eventually { seen.value >= count }
    clock.invalidate()
}
