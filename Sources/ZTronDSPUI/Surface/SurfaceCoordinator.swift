import CoreGraphics
import Foundation
import Metal
import QuartzCore
import ZTronDSPCore
import ZTronDSPMetal

/// Everything a Metal surface decides: when it draws, what it uploads, how it follows its
/// size. It stands between the SwiftUI wrapper, which only says what should be shown, and
/// the Metal view, which only hands out drawables; neither holds any logic (§8.6).
///
/// **The stability contract (§8.4).**
///
/// - ``update(_:)`` compares the incoming appearance and feed identity with the current ones
///   and returns at once when they are equal (V-3). Only an update that got past the
///   comparison is counted by the probe and reaches the renderer.
/// - Nothing is drawn without a cause from the renderer's dirty set (V-4). On a display tick
///   the coordinator asks the renderer whether a draw is due, which is one atomic load when
///   there is nothing to do, and returns without touching a drawable.
/// - The display link runs only while the feed is live or a cause is pending, and never while
///   the view is not presented (§8.3). The feed says when its liveness changes; the analysis
///   thread wakes nobody.
///
/// **Size transitions (§8.9).** While the view is on its way to another size, the drawable
/// follows the size the layer is shown at on every display tick, automatic resizing is off,
/// and each frame is presented with the layer's transaction (SZ-2, SZ-3). A transition is
/// under way while the size probe of the SwiftUI wrapper keeps reporting new sizes, or while
/// the layer says it moves (SZ-4). When neither holds any more the drawable is given its
/// exact size and, where that differs from the last frame's, one more frame is drawn.
///
/// The Metal context is made off the main thread (BG-1): a coordinator that is not given one
/// asks for the shared context when it is created and starts drawing when it arrives.
///
/// Threading: main actor. A tick with nothing to do allocates nothing.
@MainActor
final class SurfaceCoordinator {
    /// The counters of this surface: the probe it was given, or one of its own.
    let probe: RenderProbe
    /// What decides when the surface gets a display tick.
    let scheduler: FrameScheduler

    private(set) var content: SurfaceContent
    private(set) var renderer: SurfaceRenderer?
    /// Why no renderer could be made: no Metal device, or a feed no texture fits.
    private var creationFailure: DSPError?

    /// Why the surface shows nothing, or no data: there is no Metal device, or the feed has a
    /// shape no texture of the device fits. `nil` while all is well.
    var failure: DSPError? { creationFailure ?? renderer?.failure }
    /// True between the first sign of a size transition and the tick that ends it.
    private(set) var isInSizeTransition = false

    private var context: MetalContext?
    private var maximumFrameRate: Int
    private var isPresented: Bool
    private weak var surface: (any MetalSurface)?
    /// The layer behind the surface: taken from the first drawable (SZ-5), or set by a test.
    var layer: (any SurfaceLayer)?
    private var observation: FeedObservation?
    private var contextRequest: Task<Void, Never>?
    private let inspector: SurfaceInspector?

    /// The last size the wrapper's probe reported, and whether it moved since the last tick.
    private var reportedSize: CGSize?
    private var sizeMoved = false
    /// The drawable size the coordinator last heard of, so that the same size twice is one cause.
    private var knownDrawableSize: CGSize?
    /// True while the coordinator itself sets the drawable's size.
    private var isSizingDrawable = false
    /// Whether the draw of the current tick put a frame into a drawable.
    private var didDraw = false
    /// Draws in a row that found no drawable to draw into.
    private var missedDraws = 0

    /// - Parameters:
    ///   - clock: the display clock; a test passes one it fires itself.
    ///   - context: the Metal context; `nil` asks for the shared one in the background.
    init(input: SurfaceInput, clock: (any FrameClock)? = nil, context: MetalContext? = nil) {
        probe = input.probe ?? RenderProbe()
        content = input.content
        maximumFrameRate = max(input.maximumFrameRate, 1)
        isPresented = input.isPresented
        reportedSize = input.size
        inspector = input.inspector
        inspector?.record(input.content)
        scheduler = FrameScheduler(clock: clock ?? input.clocks?.makeClock() ?? DisplayLinkClock(), maximumFrameRate: input.maximumFrameRate)
        scheduler.onFrame = { [weak self] _ in self?.tick() ?? false }
        scheduler.setSceneActive(isPresented)
        observeFeed()
        if let context {
            install(context)
        } else {
            contextRequest = Task { [weak self] in
                let result: Result<MetalContext, DSPError>
                do throws(DSPError) { result = .success(try await MetalContext.shared()) } catch { result = .failure(error) }
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let context): self?.install(context)
                case .failure(let error): self?.creationFailure = error
                }
            }
        }
    }

    /// The device the surface draws on, once the context has arrived.
    var device: (any MTLDevice)? { context?.device }

    // MARK: The view's life

    /// The view was made: `makeUIView` calls this once.
    func attach(_ surface: any MetalSurface) {
        self.surface = surface
        probe.recordMake()
        if let device, surface.device == nil { surface.device = device }
        scheduler.requestFrame()
    }

    /// The view is gone: the display link ends and nothing is drawn again.
    func detach() {
        contextRequest?.cancel()
        contextRequest = nil
        observation?.cancel()
        observation = nil
        scheduler.invalidate()
        surface = nil
        layer = nil
    }

    private func install(_ context: MetalContext) {
        self.context = context
        if let surface, surface.device == nil { surface.device = context.device }
        makeRenderer()
        scheduler.requestFrame()
    }

    private func makeRenderer() {
        guard let context else { return }
        do throws(DSPError) {
            renderer = try SurfaceRenderer(context: context, content: content, probe: probe)
            creationFailure = nil
        } catch {
            renderer = nil
            creationFailure = error
        }
    }

    // MARK: Updates (V-3)

    /// What `updateUIView` calls. Returns at once when the appearance, the feed and the
    /// frame-rate cap are the ones the surface already shows.
    func update(_ input: SurfaceInput) {
        setPresented(input.isPresented)
        reportSize(input.size)
        let rate = max(input.maximumFrameRate, 1)
        guard input.content != content || rate != maximumFrameRate else { return }
        probe.recordUpdate()
        if rate != maximumFrameRate {
            maximumFrameRate = rate
            scheduler.setMaximumFrameRate(rate)
        }
        guard input.content != content else { return }
        let isOtherFeed = !input.content.hasSameFeed(as: content)
        content = input.content
        inspector?.record(content)
        if isOtherFeed { observeFeed() }
        // A renderer draws one kind of feed; content of the other kind gets a renderer of its own.
        if renderer?.show(content) != true { makeRenderer() }
        scheduler.requestFrame()
    }

    private func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        scheduler.setSceneActive(presented)
        guard presented else { return }
        // Back on screen: one draw, whatever happened meanwhile (§8.4, last scenario).
        renderer?.becameVisible()
        scheduler.requestFrame()
    }

    private func observeFeed() {
        observation?.cancel()
        observation = content.feed.observeLiveness { [weak self] _ in self?.feedLivenessChanged() }
        scheduler.setFeedLive(content.feed.isLive)
    }

    private func feedLivenessChanged() {
        // The announcement travels through the main queue and may be overtaken by the next
        // change, or by another feed: what counts is what the feed says now.
        scheduler.setFeedLive(content.feed.isLive)
        // One more tick either way: what arrived just before the feed stopped is still shown.
        scheduler.requestFrame()
    }

    // MARK: Size

    /// The size probe of the SwiftUI wrapper (SZ-4): a size that differs from the last one
    /// reported is a sign that the view is on its way to another size.
    private func reportSize(_ size: CGSize?) {
        guard let size, size != reportedSize else { return }
        let isFirst = reportedSize == nil
        reportedSize = size
        // The first report is the first layout, which the view announces itself.
        guard !isFirst else { return }
        sizeMoved = true
        scheduler.requestFrame()
    }

    /// The view is about to change the size of its drawable by itself: one draw, nothing
    /// uploaded (V-6).
    func drawableSizeWillChange(to size: CGSize) {
        guard !isSizingDrawable, size != knownDrawableSize else { return }
        knownDrawableSize = size
        renderer?.drawableSizeChanged()
        scheduler.requestFrame()
    }

    private func setDrawableSize(_ size: CGSize) {
        guard let surface, surface.drawableSize != size else { return }
        isSizingDrawable = true
        surface.drawableSize = size
        isSizingDrawable = false
        knownDrawableSize = size
    }

    /// One step of a size transition, at the start of a display tick (SZ-2 … SZ-4).
    private func stepSizeTransition() {
        let moved = sizeMoved
        sizeMoved = false
        guard let surface else { return }
        // Without a layer there is no drawable yet, and nothing that could be shown stretched:
        // the view sizes its first drawable by itself.
        guard let layer, let geometry = layer.geometry else {
            if isInSizeTransition {
                isInSizeTransition = false
                surface.setAutoResizeDrawable(true)
            }
            return
        }
        if moved || geometry.isMoving {
            if !isInSizeTransition {
                isInSizeTransition = true
                surface.setAutoResizeDrawable(false)
                layer.setPresentsWithTransaction(true)
            }
            // The drawable follows the size the layer is shown at, and every tick of a
            // transition is one draw (SZ-2).
            setDrawableSize(geometry.presentationPixels)
            renderer?.drawableSizeChanged()
        } else if isInSizeTransition {
            isInSizeTransition = false
            layer.setPresentsWithTransaction(false)
            if surface.drawableSize != geometry.modelPixels {
                // The last frame was drawn for a size on the way: one more at the exact size.
                setDrawableSize(geometry.modelPixels)
                renderer?.drawableSizeChanged()
            }
            surface.setAutoResizeDrawable(true)
        }
    }

    // MARK: The display tick (§8.3)

    /// What a display tick does. Returns whether another tick is wanted although nothing new
    /// was requested.
    private func tick() -> Bool {
        guard isPresented else { return false }
        stepSizeTransition()
        guard let renderer else { return false }
        // One atomic load when the dirty set is empty: no drawable is taken (V-4).
        guard renderer.needsDraw() else { return isInSizeTransition }
        guard let surface else { return false }
        renderer.resolve()
        didDraw = false
        surface.draw()
        missedDraws = didDraw ? 0 : missedDraws + 1
        // A draw that found no drawable is tried again on the next two ticks, then it waits
        // for the next cause: a view of no size must not keep the display link running.
        return isInSizeTransition || (!didDraw && missedDraws <= 2)
    }

    /// What the surface calls from its draw: renders one frame into `pass` and presents
    /// `drawable` with it. During a size transition the frame is presented with the layer's
    /// transaction (SZ-3); otherwise as soon as it is ready.
    func render(to pass: MTLRenderPassDescriptor, presenting drawable: (any CAMetalDrawable)?) {
        guard let renderer else { return }
        if layer == nil, let drawable {
            let adopted = MetalLayerAdapter(drawable.layer)
            adopted.setPresentsWithTransaction(isInSizeTransition)
            layer = adopted
        }
        if isInSizeTransition, let commands = context?.commandQueue.makeCommandBuffer() {
            guard renderer.render(to: pass, in: commands) else { return }
            commands.commit()
            if let drawable {
                commands.waitUntilScheduled()
                drawable.present()
            }
            didDraw = true
        } else {
            didDraw = renderer.draw(to: pass, presenting: drawable)
        }
    }
}
