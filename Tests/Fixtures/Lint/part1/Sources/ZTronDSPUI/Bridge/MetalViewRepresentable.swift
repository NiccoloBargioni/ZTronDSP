import SwiftUI
import MetalKit
import QuartzCore                                            // !! UB-2

struct MetalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = MTKView

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)        // !! UB-3
        view.isPaused = true
        let metalView = MTKView(frame: .zero, device: nil)
        metalView.backgroundColor = UIColor.clear            // !! UB-3 UB-2
        metalView.layer.isOpaque = false                     // !! UB-3
        metalView.isPaused = true
        metalView?.alpha = 0.5                               // !! UB-3
        MTKView(frame: .zero, device: nil).isPaused = true   // !! UB-3
        return metalView
    }

    func updateUIView(_ uiView: MTKView, context: Context) { // !! UB-3
        let host: UIView = uiView                            // !! UB-2
        _ = host
    }
}
