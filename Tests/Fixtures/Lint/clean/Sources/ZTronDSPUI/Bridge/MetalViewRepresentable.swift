import SwiftUI
import MetalKit

/// The one bridge between SwiftUI and the Metal view (§8.6).
struct MetalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = MTKView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero, device: nil)
        metalView.delegate = context.coordinator
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        metalView.preferredFramesPerSecond = 60
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        func mtkView(_ metalView: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in metalView: MTKView) {
            guard let drawable = metalView.currentDrawable else { return }
            _ = metalView.currentRenderPassDescriptor
            _ = drawable.layer
            metalView.draw()
        }
    }
}
