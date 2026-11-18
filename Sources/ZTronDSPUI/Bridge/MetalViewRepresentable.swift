import MetalKit
import SwiftUI

// The UIKit boundary (§8.6). This is the one file of the package that names `MTKView` and
// what SwiftUI's representable protocol requires (UB-2). It imports SwiftUI and MetalKit and
// nothing else, refers to the view only as `metalView`, and uses on it only the members that
// MetalKit declares (UB-3). It holds no logic: what is shown, when a frame is drawn and how
// the drawable follows the view's size is decided by `SurfaceCoordinator`, which never sees
// the view, only the `MetalSurface` this file hands it.

/// A Metal view in a SwiftUI hierarchy: the bridge every component of the package draws
/// through.
///
/// The view runs in explicit-draw mode (§8.3): it is paused and does not draw when it is
/// told that it needs display, so nothing is drawn unless the coordinator asks for a frame.
/// Background, opacity and layout are SwiftUI modifiers on the representable; no member the
/// view inherits is touched.
///
/// Threading: main actor, as every view.
struct MetalViewRepresentable: UIViewRepresentable {
    /// What the surface shows and what surrounds it. `updateUIView` hands it to the
    /// coordinator, which returns at once when nothing in it changed (V-3).
    let input: SurfaceInput

    func makeCoordinator() -> MetalViewHost {
        MetalViewHost(coordinator: SurfaceCoordinator(input: input))
    }

    func makeUIView(context: Context) -> MTKView {
        let host = context.coordinator
        let metalView = MTKView(frame: .zero, device: host.coordinator.device)
        // Explicit draw (E-12): the view never draws by itself.
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.autoResizeDrawable = true
        metalView.delegate = host
        host.metalView = metalView
        host.coordinator.attach(host)
        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        context.coordinator.coordinator.update(input)
    }

    static func dismantleUIView(_ metalView: MTKView, coordinator: MetalViewHost) {
        coordinator.coordinator.detach()
        metalView.delegate = nil
    }
}

/// The Metal view as the coordinator sees it, and the view's delegate: it passes the view's
/// two calls on and gives the coordinator the members of UB-3 it needs. Nothing is decided
/// here.
///
/// Threading: main actor.
final class MetalViewHost: NSObject, MTKViewDelegate, MetalSurface {
    let coordinator: SurfaceCoordinator
    weak var metalView: MTKView?

    init(coordinator: SurfaceCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: MetalSurface

    var device: (any MTLDevice)? {
        get { metalView?.device }
        set { metalView?.device = newValue }
    }

    var drawableSize: CGSize {
        get { metalView?.drawableSize ?? .zero }
        set { metalView?.drawableSize = newValue }
    }

    func setAutoResizeDrawable(_ follows: Bool) {
        metalView?.autoResizeDrawable = follows
    }

    func draw() {
        metalView?.draw()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ metalView: MTKView, drawableSizeWillChange size: CGSize) {
        coordinator.drawableSizeWillChange(to: size)
    }

    func draw(in metalView: MTKView) {
        // The layer is reached through the drawable, never through the view (SZ-5).
        guard let pass = metalView.currentRenderPassDescriptor, let drawable = metalView.currentDrawable else { return }
        coordinator.render(to: pass, presenting: drawable)
    }
}
