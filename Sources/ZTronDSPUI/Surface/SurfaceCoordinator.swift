import CoreGraphics
import Foundation
import Metal
import os
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
/// **Size transitions (§8.9).** A frame that is due to a change of size is not made on the
/// display tick. SwiftUI moves a view's bounds after the tick of the same frame, and UIKit
/// lays views out later still, so a frame made on the tick would be shown one step late,
/// stretched over bounds it was not drawn for. The size is read and the frame is made at the
/// end of the run-loop turn (``TurnEnd``), when the view has been laid out and the turn's
/// transaction is not committed yet, and the frame is presented with that transaction (SZ-2,
/// SZ-3).
///
/// - A size that SwiftUI or a layout gives the view moves the view's own bounds. The view
///   announces the new size of its drawable, or, while a transition is under way and the
///   drawable no longer follows the bounds by itself, the size probe of the SwiftUI wrapper
///   reports it. One frame is drawn at the end of that turn: a resize without animation is
///   one draw, and an animated one is one draw per frame of the display.
/// - A rotation gives the view its final bounds at once and animates the layer. While the
///   layer says it moves, one frame is drawn per tick of the display, at the size the layer
///   is shown at times the scale of the display.
/// - The transition ends at the end of the first frame of the display in which neither
///   happened and the layer rests at the size of the last frame. Nothing more is drawn then.
///
/// A frame is due whenever the layer is shown at another size, in whole pixels, than the one
/// the surface last drew a frame of this kind for; the drawable is then given exactly that
/// size. During a transition the view does not resize its drawable by itself, no tick is
/// held against the frame-rate cap, and nothing is drawn on the tick itself. The scale is
/// the one SwiftUI reports for the display, never the layer's `contentsScale`, which the
/// Metal view rewrites whenever its drawable is given a size by hand; and the drawable is
/// never given a size beyond the largest texture of the device.
///
/// The Metal context is made off the main thread (BG-1): a coordinator that is not given one
/// asks for the shared context when it is created and starts drawing when it arrives.
///
/// Threading: main actor. A tick with nothing to do allocates nothing, and a surface at rest
/// keeps nothing on the run loop.
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
    /// True from the first frame of a size transition to the end of the turn that ends it.
    private(set) var isInSizeTransition = false
    /// Times the surface said that it has read no scene phase but `.background`: 0 or 1.
    private(set) var phaseNotices = 0

    private var context: MetalContext?
    private var maximumFrameRate: Int
    private var isPresented: Bool
    private weak var surface: (any MetalSurface)?
    /// The layer behind the surface: taken from the first drawable (SZ-5), or set by a test.
    var layer: (any SurfaceLayer)?
    private var observation: FeedObservation?
    private var contextRequest: Task<Void, Never>?
    private let inspector: SurfaceInspector?

    /// Calls back at the end of a run-loop turn: where a frame of a size transition is made.
    private let turns: any TurnEnd
    /// True from asking for the end of the turn to the call that answers.
    private var isStepRequested = false
    /// Pixels per point of the display, as SwiftUI reports them (SZ-2).
    private var displayScale: CGFloat
    /// The last size the wrapper's probe reported.
    private var reportedSize: CGSize?
    /// Whether a sign of another size arrived since the last step: the probe reported one,
    /// the view announced one, or the display's scale changed.
    private var sizeMoved = false
    /// Whether the display ticked since the last step.
    private var displayTicked = false
    /// The drawable size the coordinator last heard of, so that the same size twice is one cause.
    private var knownDrawableSize: CGSize?
    /// True while the coordinator itself sets the drawable's size.
    private var isSizingDrawable = false
    /// The size of the drawable the last frame was drawn into; `nil` before the first frame.
    private(set) var drawnSize: CGSize?
    /// The size the layer was shown at, in whole pixels of the display, when the surface last
    /// looked at it and had a frame for it: what a step compares the layer with. It is the
    /// surface's own reckoning (points times the display's scale, rounded), so the way the
    /// view rounds the drawable it sizes itself never counts as another size. `nil` until
    /// the first frame has been drawn into a drawable of the layer.
    private var followedSize: CGSize?
    /// Whether the draw that is under way put a frame into a drawable.
    private var didDraw = false
    /// Draws in a row that found no drawable to draw into.
    private var missedDraws = 0
    /// True once the surface has read a scene phase other than `.background`.
    private var hasLeftBackground: Bool

    private static let log = Logger(subsystem: "com.zombietron.ztrondsp", category: "surface")

    /// - Parameters:
    ///   - clock: the display clock; a test passes one it fires itself.
    ///   - turns: the end of a run-loop turn; a test passes one whose turns it ends itself.
    ///   - context: the Metal context; `nil` asks for the shared one in the background.
    init(input: SurfaceInput, clock: (any FrameClock)? = nil, turns: (any TurnEnd)? = nil, context: MetalContext? = nil) {
        probe = input.probe ?? RenderProbe()
        content = input.content
        maximumFrameRate = max(input.maximumFrameRate, 1)
        isPresented = input.isPresented
        reportedSize = input.size
        displayScale = input.displayScale
        hasLeftBackground = !input.isSceneInBackground
        inspector = input.inspector
        inspector?.record(input.content)
        self.turns = turns ?? RunLoopTurnEnd()
        scheduler = FrameScheduler(clock: clock ?? input.clocks?.makeClock() ?? DisplayLinkClock(), maximumFrameRate: input.maximumFrameRate)
        scheduler.onFrame = { [weak self] _ in self?.tick() ?? false }
        self.turns.onEnd = { [weak self] in self?.turnEnded() }
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
        turns.invalidate()
        isStepRequested = false
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
        if !input.isSceneInBackground { hasLeftBackground = true }
        setPresented(input.isPresented)
        setDisplayScale(input.displayScale)
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
        // Back on screen: one draw, whatever happened meanwhile (§8.4, last scenario). The
        // view may have been given another size meanwhile: the frame is made at the end of
        // this turn, like every frame that may be due to a size.
        renderer?.becameVisible()
        scheduler.requestFrame()
        if layer != nil { requestStep() }
    }

    private func observeFeed() {
        observation?.cancel()
        observation = content.feed.observeLiveness { [weak self] _ in self?.feedLivenessChanged() }
        scheduler.setFeedLive(content.feed.isLive)
        noticeAPhaseNobodySupplied()
    }

    private func feedLivenessChanged() {
        // The announcement travels through the main queue and may be overtaken by the next
        // change, or by another feed: what counts is what the feed says now.
        scheduler.setFeedLive(content.feed.isLive)
        // One more tick either way: what arrived just before the feed stopped is still shown.
        scheduler.requestFrame()
        noticeAPhaseNobodySupplied()
    }

    /// Says once, in the log, that the surface has a live feed and has read no scene phase
    /// but `.background`, so that it draws nothing (§8.3). SwiftUI hands the phase to the
    /// scenes of an `App` only: in any other host the view reads `.background` until the
    /// host hands the phase of its scene down. Called when the feed's liveness may have
    /// changed, on the main actor; never from a tick.
    private func noticeAPhaseNobodySupplied() {
        guard !hasLeftBackground, phaseNotices == 0, content.feed.isLive else { return }
        phaseNotices = 1
        Self.log.notice("""
            A ZTronDSP view has a live feed and has read no scene phase but .background, so it draws nothing. \
            If its host is not a SwiftUI scene (a hosting controller, for one), the host has to hand the phase \
            of its scene down: .environment(\\.scenePhase, phase) on the view it hosts.
            """)
    }

    // MARK: Size

    /// The scale of the display changed, or was first told: the same view is another size in
    /// pixels.
    private func setDisplayScale(_ scale: CGFloat) {
        guard scale != displayScale else { return }
        displayScale = scale
        sizeMayHaveMoved()
    }

    /// The size probe of the SwiftUI wrapper (SZ-4): a size that differs from the last one
    /// reported is a sign that SwiftUI moves the view's bounds, in this turn or, for a change
    /// without animation on iOS 18 and later, with the next frame of the display.
    private func reportSize(_ size: CGSize?) {
        guard let size, size != reportedSize else { return }
        let isFirst = reportedSize == nil
        reportedSize = size
        // The first report is the first layout, which the view announces itself.
        guard !isFirst else { return }
        sizeMayHaveMoved()
    }

    /// The view is about to change the size of its drawable by itself, because its bounds
    /// moved: one draw, nothing uploaded (V-6). The frame is made at the end of this turn,
    /// with the transaction that carries the bounds (SZ-2).
    func drawableSizeWillChange(to size: CGSize) {
        guard !isSizingDrawable, size != knownDrawableSize else { return }
        knownDrawableSize = size
        guard layer != nil else {
            // Before the first drawable there is no layer to read, and no picture that could
            // be shown stretched: the tick draws the size the view gave itself.
            renderer?.drawableSizeChanged()
            scheduler.requestFrame()
            return
        }
        sizeMayHaveMoved()
    }

    /// A sign that the view may be shown at another size: the step at the end of this turn
    /// looks at the layer. Before the first drawable there is no layer to look at, and no
    /// picture that could be shown stretched; nothing is asked for then, so that the tick
    /// which draws the first frame is not left to a step that has nothing to follow.
    private func sizeMayHaveMoved() {
        guard layer != nil else { return }
        sizeMoved = true
        requestStep()
    }

    private func setDrawableSize(_ size: CGSize) {
        guard let surface, surface.drawableSize != size else { return }
        isSizingDrawable = true
        surface.drawableSize = size
        isSizingDrawable = false
        knownDrawableSize = size
    }

    /// The largest drawable the device has a texture for, each way; before the Metal context
    /// has arrived, the largest every device has one for.
    private var largestDrawable: CGFloat {
        CGFloat(context?.capabilities.maximumTextureDimension ?? 8_192)
    }

    /// `size`, cut to what a drawable can be (SZ-2): a drawable beyond the largest texture
    /// of the device would end the application when it is asked for.
    private func fitted(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, 1), largestDrawable), height: min(max(size.height, 1), largestDrawable))
    }

    private func requestStep() {
        guard !isStepRequested else { return }
        isStepRequested = true
        turns.request()
    }

    /// The end of a run-loop turn the surface asked for.
    private func turnEnded() {
        isStepRequested = false
        stepSizeTransition()
    }

    /// One step of the size rule, at the end of a run-loop turn (SZ-2 … SZ-4): the view has
    /// been laid out for this turn, and what is drawn now is presented with the transaction
    /// that carries its bounds.
    private func stepSizeTransition() {
        let moved = sizeMoved, ticked = displayTicked
        sizeMoved = false
        displayTicked = false
        guard isPresented, let surface else { return }
        // A layer that is gone ends a transition. The tick of this turn drew nothing, because
        // a step was asked for: what was due on it is drawn here.
        guard let layer, let geometry = layer.geometry(scale: displayScale) else {
            if isInSizeTransition { endTransition(surface, nil) }
            drawIfDue(on: surface)
            return
        }
        let target = fitted(geometry.presentationPixels)
        if geometry.isMoving {
            // Core Animation shows the layer at another size with every frame of the display
            // (a rotation): one frame for each, at the size the layer is shown at now.
            if isInSizeTransition, !ticked { return }
            beginTransition(surface, layer)
            drawFrame(sized: target, on: surface)
        } else if target != followedSize {
            // The layer rests at a size no frame was drawn for: SwiftUI, or a layout, moved
            // the view's bounds in this turn. The first frame of a transition, the next one,
            // or the only one of a resize without animation.
            beginTransition(surface, layer)
            drawFrame(sized: target, on: surface)
        } else {
            // The layer is where the last frame left it. A frame of the display in which
            // nothing announced another size either ends the transition; a sign without a
            // move is SwiftUI telling of bounds it moves later.
            if isInSizeTransition, ticked, !moved { endTransition(surface, layer) }
            drawIfDue(on: surface)
        }
    }

    private func beginTransition(_ surface: any MetalSurface, _ layer: any SurfaceLayer) {
        guard !isInSizeTransition else { return }
        isInSizeTransition = true
        surface.setAutoResizeDrawable(false)
        layer.setPresentsWithTransaction(true)
        scheduler.setFollowsDisplay(true)
        // The display link runs for the whole transition: its ticks say when a frame of the
        // display has passed, which is how a layer that moves is followed and how the end
        // is found.
        scheduler.requestFrame()
    }

    private func endTransition(_ surface: any MetalSurface, _ layer: (any SurfaceLayer)?) {
        isInSizeTransition = false
        layer?.setPresentsWithTransaction(false)
        scheduler.setFollowsDisplay(false)
        surface.setAutoResizeDrawable(true)
    }

    /// Gives the drawable `size`, the size the layer is shown at, and draws one frame into
    /// it now.
    private func drawFrame(sized size: CGSize, on surface: any MetalSurface) {
        setDrawableSize(size)
        renderer?.drawableSizeChanged()
        // When no drawable was to be had three times in a row, as for a view of no size, the
        // size counts as followed all the same, so that the transition can end and the
        // display link can pause. The cause stays pending for the next frame that finds a
        // drawable.
        if draw(on: surface) || missedDraws > 2 { followedSize = size }
    }

    /// Draws one frame now if a cause is pending: what arrived during a transition, or was
    /// due on a tick that left its frame to this step, is drawn at the end of the turn. A
    /// draw that finds no drawable is tried again on the next two ticks, as one that a tick
    /// makes is.
    private func drawIfDue(on surface: any MetalSurface) {
        guard let renderer, renderer.needsDraw() else { return }
        if !draw(on: surface), missedDraws <= 2 { scheduler.requestFrame() }
    }

    /// Draws one frame now. Returns whether a frame went into a drawable.
    @discardableResult
    private func draw(on surface: any MetalSurface) -> Bool {
        guard let renderer else {
            missedDraws += 1
            return false
        }
        renderer.resolve()
        didDraw = false
        surface.draw()
        missedDraws = didDraw ? 0 : missedDraws + 1
        return didDraw
    }

    // MARK: The display tick (§8.3)

    /// What a display tick does. Returns whether another tick is wanted although nothing new
    /// was requested.
    private func tick() -> Bool {
        guard isPresented else { return false }
        if isInSizeTransition || isStepRequested {
            // A frame of the display has begun. What it shows is drawn at the end of this
            // turn, when the view has been laid out for it (SZ-2); nothing is drawn here.
            displayTicked = true
            requestStep()
            return isInSizeTransition
        }
        guard let renderer else { return false }
        // One atomic load when the dirty set is empty: no drawable is taken (V-4).
        guard renderer.needsDraw() else { return false }
        guard let surface else { return false }
        draw(on: surface)
        if didDraw, followedSize == nil, let geometry = layer?.geometry(scale: displayScale) {
            // The first frame in a drawable of the layer: the size the size rule starts from.
            followedSize = fitted(geometry.presentationPixels)
        }
        // A draw that found no drawable is tried again on the next two ticks, then it waits
        // for the next cause: a view of no size must not keep the display link running.
        return !didDraw && missedDraws <= 2
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
        // The size of the picture on the display from now on. The size rule does not compare
        // the layer with it, but with its own reckoning of the size it drew for (`followedSize`):
        // this one is for an instrument that asks what the last frame was drawn into.
        if didDraw, let surface { drawnSize = surface.drawableSize }
    }
}
