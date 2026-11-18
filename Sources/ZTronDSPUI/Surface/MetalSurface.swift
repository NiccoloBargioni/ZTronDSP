import CoreGraphics
import Foundation
import Metal
import QuartzCore
import ZTronDSPMetal

/// What a view hands its surface on every update: what to show, and the few things around it
/// that are not appearance. The representable passes it on untouched (§8.6).
///
/// A value for the main actor.
struct SurfaceInput {
    /// The feed and how it is shown. `updateUIView` compares this, and the frame-rate cap,
    /// with what the surface shows, and returns when they are equal (V-3).
    var content: SurfaceContent
    /// `.maximumFrameRate(_:)`.
    var maximumFrameRate = 60
    /// True while the scene is active and the view is on screen. While it is false the
    /// display link is paused and nothing is submitted to the GPU (§8.3).
    var isPresented = true
    /// The size the view is laid out at, in points, as an `Animatable` probe in the SwiftUI
    /// wrapper sees it: during an animated change of size it holds one interpolated size per
    /// display frame (SZ-4). `nil` where no probe reports.
    var size: CGSize?
    /// Counts what the surface does, for the stability tests; read once, when the surface is
    /// made. A surface that is given none keeps one of its own.
    var probe: RenderProbe?
    /// Where the surface gets its display clock from, when a test supplies it; read once,
    /// when the surface is made. Without one the surface makes a `DisplayLinkClock`.
    var clocks: ClockSource?
    /// Told what the surface shows, when a test wants to see it; read once, when the surface
    /// is made.
    var inspector: SurfaceInspector?
}

/// Sees what a surface is asked to show: every content that reached its renderer, in order.
/// A hosted test injects one through the environment to see that a modifier's value arrived
/// (WP-812) and which values an animation passed through (WP-813). A surface that is given
/// none tells nobody.
///
/// Threading: main actor.
@MainActor
final class SurfaceInspector {
    /// What the surface was made with, and then every update that got past the comparison
    /// of V-3.
    private(set) var contents: [SurfaceContent] = []

    func record(_ content: SurfaceContent) {
        contents.append(content)
    }

    /// The appearance of the heat map the surface shows now.
    var heatmap: HeatmapAppearance? {
        if case .heatmap(_, let appearance)? = contents.last { return appearance }
        return nil
    }

    /// The appearance of the waveform the surface shows now.
    var waveform: WaveformAppearance? {
        if case .waveform(_, let appearance)? = contents.last { return appearance }
        return nil
    }
}

/// What a surface's layer says about its size on a display tick: the layer's half of the
/// rule that detects a size transition (SZ-4).
///
/// An immutable value.
struct LayerGeometry: Equatable, Sendable {
    /// The layer's bounds, in points: where a transition ends.
    var modelSize: CGSize
    /// The size the layer is shown at right now, in points: the bounds of its presentation
    /// layer. Equal to `modelSize` when nothing moves.
    var presentationSize: CGSize
    /// True while the layer carries an animation.
    var isAnimating: Bool
    /// Pixels per point.
    var scale: CGFloat

    /// The drawable size for a size in points: whole pixels, at least one each way.
    static func pixels(_ size: CGSize, scale: CGFloat) -> CGSize {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        return CGSize(width: max((size.width * factor).rounded(), 1), height: max((size.height * factor).rounded(), 1))
    }

    /// The drawable size that fits what is shown now.
    var presentationPixels: CGSize { Self.pixels(presentationSize, scale: scale) }
    /// The drawable size that fits the layer once nothing moves.
    var modelPixels: CGSize { Self.pixels(modelSize, scale: scale) }

    /// True while the layer is on its way to another size: it is shown at a size that is not
    /// its own, or it is being animated.
    var isMoving: Bool { isAnimating || presentationPixels != modelPixels }
}

/// The layer of a Metal surface, as far as a size transition needs it (§8.9): the seam of
/// WP-823. In an app it is the view's `CAMetalLayer`, reached through the first drawable
/// (SZ-5); a test scripts one.
///
/// Threading: main actor.
@MainActor
protocol SurfaceLayer: AnyObject {
    /// The layer's size now; `nil` once the layer is gone.
    var geometry: LayerGeometry? { get }
    /// Says whether a drawable is presented with the layer's transaction, so that content and
    /// bounds change in the same frame (SZ-3), or as soon as it is ready.
    func setPresentsWithTransaction(_ presents: Bool)
}

/// The view a coordinator draws into, as far as the coordinator needs it: the seam between
/// the logic of a surface and `MTKView`. In an app the bridge file implements it with the
/// members of UB-3; a test implements it over an off-screen texture.
///
/// Threading: main actor.
@MainActor
protocol MetalSurface: AnyObject {
    /// The device drawables are made on. The view exists before the Metal context does.
    var device: (any MTLDevice)? { get set }
    /// The size of the drawable, in pixels.
    var drawableSize: CGSize { get set }
    /// Says whether the drawable follows the view's bounds by itself. Off during a size
    /// transition (SZ-2).
    func setAutoResizeDrawable(_ follows: Bool)
    /// Draws one frame now: takes the next drawable and hands it, with a pass into it, to the
    /// coordinator's `render(to:presenting:)`. The explicit draw of §8.3.
    func draw()
}

/// A `CAMetalLayer` as a ``SurfaceLayer``.
///
/// The layer is the one the first drawable names, never one read off the view (SZ-5). It is
/// held weakly: it belongs to the view.
///
/// Threading: main actor.
@MainActor
final class MetalLayerAdapter: SurfaceLayer {
    private weak var layer: CAMetalLayer?

    init(_ layer: CAMetalLayer) {
        self.layer = layer
        // What the renderers leave untouched is transparent, so that a SwiftUI background
        // shows through (UB-3: background is a SwiftUI modifier).
        layer.isOpaque = false
    }

    var geometry: LayerGeometry? {
        guard let layer else { return nil }
        let model = layer.bounds.size
        return LayerGeometry(modelSize: model, presentationSize: layer.presentation()?.bounds.size ?? model,
                             isAnimating: !(layer.animationKeys() ?? []).isEmpty, scale: layer.contentsScale)
    }

    func setPresentsWithTransaction(_ presents: Bool) {
        layer?.presentsWithTransaction = presents
    }
}
