import CoreGraphics
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// Size transitions (WP-823, §8.9, as corrected after the spike WP-822): a frame that is due
/// to a change of size is made at the end of the run-loop turn, when the view has been laid
/// out, and presented with the layer's transaction; the drawable has the size the layer is
/// shown at, times the scale SwiftUI reports; the last frame is drawn at the layer's own
/// size. The layer, the view and the end of a turn are scripted through their seams
/// (`SurfaceLayer`, `MetalSurface`, `TurnEnd`), in the order a hosted view goes through them
/// (`Examples/ZTronDSPGallery/Spikes/WP-822-findings.md`): the display tick comes first, then
/// SwiftUI moves the view, then the turn ends. The gallery's hosted acceptance (WP-824) runs
/// the same rule in a real application.
@MainActor
@Suite("Size transitions")
struct SizeTransitionTests {
    static let start = CGSize(width: 100, height: 60)
    static let end = CGSize(width: 160, height: 150)
    static let scale: CGFloat = 2

    private static func pixels(_ size: CGSize) -> CGSize {
        LayerGeometry.pixels(size, scale: scale)
    }

    private func content(_ kind: SurfaceKind) throws -> SurfaceContent {
        switch kind {
        case .heatmap:
            let feed = HeatmapFeed(history: 32)
            try FeedWriter.append(FeedWriter.columns(0 ..< 5, rows: 16), rows: 16, to: feed)
            return .heatmap(feed, HeatmapAppearance())
        case .waveform:
            let feed = WaveformFeed(history: 128)
            try FeedWriter.append(pairs: (0 ..< 64).flatMap { index in [-Float(index) / 64, Float(index) / 64] }, to: feed)
            return .waveform(feed, WaveformAppearance())
        }
    }

    /// A stopped feed with five columns, a surface that has drawn it at `start`, and the
    /// surface's layer in the test's hands.
    private func scene(_ kind: SurfaceKind = .heatmap, scale: CGFloat = SizeTransitionTests.scale) async throws -> (Stage, ScriptedLayer, SurfaceContent) {
        let content = try content(kind)
        await mainQueueDrained()
        var stage = try await Stage(content, size: LayerGeometry.pixels(Self.start, scale: scale), displayScale: scale)
        let layer = ScriptedLayer(size: Self.start)
        stage.adopt(layer)
        stage.report(size: Self.start)
        #expect(stage.settle() == 1 && stage.probe.draws == 1)
        #expect(stage.coordinator.drawnSize == LayerGeometry.pixels(Self.start, scale: scale))
        return (stage, layer, content)
    }

    private func between(_ from: CGSize, _ to: CGSize, _ fraction: CGFloat) -> CGSize {
        CGSize(width: from.width + (to.width - from.width) * fraction, height: from.height + (to.height - from.height) * fraction)
    }

    /// What SwiftUI does in one turn when it gives the view another size: the probe is handed
    /// the size, the view's bounds move, and the view resizes its drawable by itself as long
    /// as it may.
    private func move(_ stage: inout Stage, _ layer: ScriptedLayer, to size: CGSize) {
        stage.report(size: size)
        layer.show(size, model: size, animating: false)
        stage.surface.resize(to: Self.pixels(size))
    }

    // MARK: A layer that Core Animation animates: a rotation (SZ-4, the layer's signal)

    /// The view is given its final bounds at once and its layer is shown at sizes on the
    /// way. One frame per tick of the display, each made at the end of the tick's turn, at
    /// the size the layer is shown at then.
    @Test(arguments: SurfaceKind.allCases)
    func aLayerThatMovesIsFollowedFrameByFrameAtTheEndOfEachTurn(kind: SurfaceKind) async throws {
        let (stage, layer, _) = try await scene(kind)
        let uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        // The view lays out at its new size and resizes its drawable by itself, once.
        layer.show(Self.start, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        #expect(stage.turns.isRequested && stage.probe.draws == 1, "the frame is asked for at the end of this turn, and nothing is drawn before")
        #expect(stage.endTurn())
        // The first frame of the transition: at the size the layer is shown at, which is
        // still the old one, not at the size the view jumped to.
        #expect(stage.coordinator.isInSizeTransition && stage.isRunning)
        #expect(stage.surface.drawableSize == Self.pixels(Self.start) && stage.probe.draws == 2)
        #expect(!stage.surface.autoResizeDrawable, "automatic resizing is off for the duration (SZ-2)")
        #expect(layer.presentsWithTransaction && stage.surface.drawnWithTransaction.last == true, "presented with the transaction (SZ-3)")
        let steps = 12
        for step in 1 ..< steps {
            let shown = between(Self.start, Self.end, CGFloat(step) / CGFloat(steps))
            #expect(stage.tick(), "the display link runs for the whole transition")
            #expect(stage.probe.draws == 1 + step, "tick \(step): nothing is drawn on the tick itself")
            // Core Animation works out how the layer is shown after the display-link callbacks.
            layer.show(shown, model: Self.end, animating: true)
            #expect(stage.endTurn())
            #expect(stage.coordinator.isInSizeTransition)
            #expect(stage.surface.drawableSize == Self.pixels(shown), "frame \(step): the drawable has the size the layer is shown at")
            #expect(stage.surface.drawnSizes.last == Self.pixels(shown) && stage.probe.draws == 2 + step, "and one frame was drawn at it")
            #expect(!stage.surface.autoResizeDrawable && layer.presentsWithTransaction && stage.surface.drawnWithTransaction.last == true)
        }
        // The animation is over: the layer is shown at its own size. The last frame was
        // drawn for a size on the way, so one more is drawn, at the exact size.
        layer.show(Self.end, model: Self.end, animating: false)
        #expect(stage.frame())
        #expect(stage.coordinator.isInSizeTransition && stage.probe.draws == 2 + steps)
        #expect(stage.surface.drawableSize == Self.pixels(Self.end) && stage.surface.drawnSizes.last == Self.pixels(Self.end))
        // A frame of the display in which nothing moved: the transition ends, nothing is drawn.
        #expect(stage.frame())
        #expect(!stage.coordinator.isInSizeTransition && stage.probe.draws == 2 + steps)
        #expect(stage.surface.autoResizeDrawable && !layer.presentsWithTransaction, "outside a transition the drawable sizes itself and presentation is asynchronous again")
        #expect(stage.settle(limit: 30) <= 1 && !stage.isRunning && stage.probe.draws == 2 + steps, "nothing more is drawn")
        #expect(!stage.turns.isRequested, "and nothing is left on the run loop")
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns && stage.probe.allocations == 1, "nothing was uploaded (SZ-1)")
    }

    /// A layer that ends where its last frame was drawn needs no frame more.
    @Test func aTransitionThatEndsAtTheSizeOfItsLastFrameDrawsNothingMore() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(Self.start, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        layer.show(Self.end, model: Self.end, animating: true)
        stage.frame()
        #expect(stage.probe.draws == 3 && stage.surface.drawableSize == Self.pixels(Self.end))
        // The animation is taken off the layer; the layer already is where the last frame was drawn.
        layer.show(Self.end, model: Self.end, animating: false)
        stage.frame()
        #expect(!stage.coordinator.isInSizeTransition && stage.probe.draws == 3, "no spare draw at the end")
    }

    /// While the layer moves, a turn that ends without a tick of the display makes no frame:
    /// one frame for each frame of the display.
    @Test func aMovingLayerIsDrawnOncePerFrameOfTheDisplay() async throws {
        var (stage, layer, _) = try await scene()
        layer.show(Self.start, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        #expect(stage.probe.draws == 2)
        // SwiftUI evaluates the view again in a turn of its own: the probe is handed the
        // final size, once, and the layer has moved on meanwhile.
        layer.show(between(Self.start, Self.end, 0.2), model: Self.end, animating: true)
        stage.report(size: Self.end)
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 2 && stage.surface.drawableSize == Self.pixels(Self.start), "no tick, no frame")
        stage.frame()
        #expect(stage.probe.draws == 3 && stage.surface.drawableSize == Self.pixels(between(Self.start, Self.end, 0.2)))
    }

    /// SZ-1: rendering does not depend on resolution. A frame of the transition is the frame
    /// a surface draws directly at that size.
    @Test func aFrameOfATransitionShowsWhatADirectDrawAtThatSizeShows() async throws {
        let (stage, layer, content) = try await scene()
        let middle = between(Self.start, Self.end, 0.5)
        layer.show(middle, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        let during = try stage.surface.pixels()
        let direct = try await Stage(content, size: Self.pixels(middle))
        direct.settle()
        let reference = try direct.surface.pixels()
        #expect(during.width == reference.width && during.height == reference.height)
        #expect(during == reference)
    }

    // MARK: A size that SwiftUI steps (SZ-4, the probe's signal)

    /// SwiftUI gives the view one interpolated size per display frame, after the display
    /// tick of that frame. Each is drawn at the end of the turn it arrives in, so the frame
    /// and the bounds it was drawn for go to the display together.
    @Test(arguments: SurfaceKind.allCases)
    func aSteppedSizeIsDrawnAtTheEndOfTheTurnItArrivesIn(kind: SurfaceKind) async throws {
        var (stage, layer, _) = try await scene(kind)
        let steps = 10
        for step in 1 ... steps {
            let size = between(Self.start, Self.end, CGFloat(step) / CGFloat(steps))
            // The tick of this frame comes first and finds the layer where the last frame left it.
            #expect(stage.tick() == (step > 1), "the display link runs from the first frame of the transition on")
            move(&stage, layer, to: size)
            #expect(stage.probe.draws == step, "frame \(step): nothing is drawn before the turn ends, least of all on the tick")
            #expect(stage.endTurn())
            #expect(stage.coordinator.isInSizeTransition && !stage.surface.autoResizeDrawable && layer.presentsWithTransaction)
            #expect(stage.surface.drawableSize == Self.pixels(size), "the drawable has the size the view was given in this turn")
            #expect(stage.probe.draws == 1 + step && stage.surface.drawnSizes.last == Self.pixels(size) && stage.surface.drawnWithTransaction.last == true)
        }
        // No new size: the transition is over. The last frame was drawn at the exact size
        // already, so nothing more is drawn.
        #expect(stage.frame())
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable && !layer.presentsWithTransaction)
        #expect(stage.probe.draws == 1 + steps, "no spare draw")
        #expect(stage.surface.drawableSize == Self.pixels(Self.end))
        #expect(stage.settle(limit: 30) <= 1 && !stage.isRunning && !stage.turns.isRequested)
        #expect(stage.probe.uploads == 1)
    }

    /// A step of less than a pixel is the same drawable: no frame is drawn for it, and the
    /// transition goes on while the probe reports.
    @Test func aStepOfLessThanAPixelIsNotDrawn() async throws {
        var (stage, layer, _) = try await scene()
        move(&stage, layer, to: Self.end)
        stage.endTurn()
        #expect(stage.probe.draws == 2 && stage.coordinator.isInSizeTransition)
        let nearly = CGSize(width: Self.end.width + 0.2, height: Self.end.height)
        stage.tick()
        move(&stage, layer, to: nearly)
        stage.endTurn()
        #expect(stage.probe.draws == 2 && stage.coordinator.isInSizeTransition, "the same pixels: no frame, and the transition is not over while sizes arrive")
        stage.frame()
        #expect(!stage.coordinator.isInSizeTransition && stage.probe.draws == 2)
    }

    // MARK: A resize without animation (§8.4)

    /// The order of iOS 17: SwiftUI gives the view its new bounds in the turn of the change.
    /// One draw, at the end of that turn, presented with the transaction so that the old
    /// picture is never shown stretched.
    @Test func aSingleNewSizeIsOneDrawAtTheEndOfItsTurn() async throws {
        var (stage, layer, _) = try await scene()
        let size = CGSize(width: 140, height: 90)
        move(&stage, layer, to: size)
        #expect(stage.probe.draws == 1 && stage.turns.requests == 1, "asked for once, whatever announced the size")
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 2 && stage.surface.drawnSizes.last == Self.pixels(size) && stage.surface.drawnWithTransaction.last == true)
        // The next frame of the display finds nothing moving: the transition is over.
        #expect(stage.settle() == 2, "the tick that ends the transition, and one with nothing to do")
        #expect(stage.probe.draws == 2 && !stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable)
        // The same size reported again is not a change.
        stage.report(size: size)
        #expect(!stage.isRunning && !stage.turns.isRequested && stage.probe.draws == 2)
        #expect(stage.probe.updates == 0, "a size is not appearance")
    }

    /// The order of iOS 18 and later: the probe is handed the new size in the turn of the
    /// change, and the bounds move with the next frame of the display, after its tick. Still
    /// one draw, in the turn the bounds move in; none on the tick, and none for the probe's
    /// report alone.
    @Test func aSizeTheProbeSeesAFrameBeforeTheBoundsMoveIsOneDraw() async throws {
        var (stage, layer, _) = try await scene()
        let size = CGSize(width: 140, height: 90)
        stage.report(size: size)
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 1 && !stage.coordinator.isInSizeTransition, "the layer has not moved: nothing to draw, and no transition")
        // The next frame of the display: its tick, then the bounds.
        stage.tick()
        #expect(stage.probe.draws == 1, "no draw at the old size on the tick")
        layer.show(size, model: size, animating: false)
        stage.surface.resize(to: Self.pixels(size))
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 2 && stage.surface.drawnSizes.last == Self.pixels(size) && stage.surface.drawnWithTransaction.last == true)
        stage.settle()
        #expect(stage.probe.draws == 2 && !stage.coordinator.isInSizeTransition, "one draw for one new size")
    }

    /// Three sizes in a row, each in a frame of its own: three draws.
    @Test func everyNewSizeIsOneDraw() async throws {
        var (stage, layer, _) = try await scene()
        let sizes = [CGSize(width: 140, height: 90), CGSize(width: 140, height: 120), CGSize(width: 61, height: 37)]
        for (index, size) in sizes.enumerated() {
            move(&stage, layer, to: size)
            stage.endTurn()
            #expect(stage.probe.draws == 2 + index && stage.surface.drawnSizes.last == Self.pixels(size), "one draw for \(size)")
            stage.settle()
            #expect(stage.probe.draws == 2 + index && !stage.coordinator.isInSizeTransition)
        }
    }

    /// A view rounds the drawable it sizes itself in its own way: a fraction of a pixel may
    /// come out one pixel away from the surface's reckoning. That is not another size: when
    /// the view takes its drawable back at the end of a transition and announces such a
    /// size, nothing is drawn, and the next size the view really gets is one draw.
    @Test func theWayTheViewRoundsItsDrawableIsNotAnotherSize() async throws {
        var (stage, layer, content) = try await scene()
        let size = CGSize(width: 140.2, height: 90.3)
        // The view rounds up: 281 × 181 pixels, where the surface reckons 280 × 181.
        stage.report(size: size)
        layer.show(size, model: size, animating: false)
        stage.surface.resize(to: CGSize(width: 281, height: 181))
        stage.endTurn()
        #expect(stage.probe.draws == 2 && stage.surface.drawableSize == Self.pixels(size), "the frame is drawn at the size the layer has, to the pixel")
        stage.frame()
        #expect(!stage.coordinator.isInSizeTransition)
        // The view sizes its drawable itself again, its own way, and says so.
        stage.surface.resize(to: CGSize(width: 281, height: 181))
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 2 && !stage.coordinator.isInSizeTransition, "the same layer at the same size: nothing to draw")
        stage.settle()
        #expect(stage.probe.draws == 2 && !stage.isRunning)
        // A frame that is drawn for another cause goes into the drawable as the view sized it.
        guard case .heatmap(let feed, var appearance) = content else { return }
        appearance.valueRange = -10 ... 0
        stage.show(.heatmap(feed, appearance))
        stage.settle()
        #expect(stage.probe.draws == 3 && stage.surface.drawnSizes.last == CGSize(width: 281, height: 181))
        // The probe tells of a size the layer has not got yet: still nothing to draw, although
        // the last frame's drawable is a pixel wider than the surface reckons the layer.
        stage.report(size: CGSize(width: 150, height: 90.3))
        #expect(stage.endTurn())
        #expect(stage.probe.draws == 3 && !stage.coordinator.isInSizeTransition)
        // A pixel more is another size.
        let wider = CGSize(width: 140.7, height: 90.3)
        layer.show(wider, model: wider, animating: false)
        stage.report(size: wider)
        stage.endTurn()
        #expect(stage.probe.draws == 4 && stage.surface.drawableSize == Self.pixels(wider))
    }

    // MARK: The scale (SZ-2)

    /// The drawable is sized with the scale SwiftUI reports for the display. The layer is
    /// asked with that scale and never for one of its own.
    @Test func theDrawableIsSizedWithTheScaleOfTheDisplay() async throws {
        var (stage, layer, _) = try await scene(scale: 3)
        let shown = between(Self.start, Self.end, 0.25)
        layer.show(shown, model: Self.end, animating: true)
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: 3))
        stage.endTurn()
        #expect(stage.surface.drawableSize == LayerGeometry.pixels(shown, scale: 3), "three pixels to the point")
        #expect(!layer.askedScales.isEmpty && layer.askedScales.allSatisfy { $0 == 3 })
        // The view moves to a display of another scale: the next frame is sized with it.
        stage.setDisplayScale(2)
        let later = between(Self.start, Self.end, 0.5)
        layer.show(later, model: Self.end, animating: true)
        stage.frame()
        #expect(stage.surface.drawableSize == LayerGeometry.pixels(later, scale: 2))
        #expect(layer.askedScales.last == 2)
    }

    // MARK: The bound (SZ-2)

    /// A layer that is shown larger than the largest texture of the device gets a drawable
    /// of the largest size there is, not one that Metal would refuse.
    @Test func theDrawableIsNeverLargerThanTheLargestTexture() async throws {
        let (stage, layer, _) = try await scene()
        let limit = CGFloat(stage.context.capabilities.maximumTextureDimension)
        // A layer that is shown 20 000 points high, at two pixels to the point.
        layer.show(CGSize(width: 12, height: 20_000), model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        #expect(stage.surface.drawableSize == CGSize(width: 24, height: limit), "cut to the largest texture: \(stage.surface.drawableSize)")
        #expect(stage.probe.draws == 2 && stage.surface.drawnSizes.last == CGSize(width: 24, height: limit), "and drawn")
        // The transition ends at the layer's own size.
        layer.show(Self.end, model: Self.end, animating: false)
        stage.frame()
        stage.frame()
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.drawableSize == Self.pixels(Self.end))
        // A view that gives its own drawable a size beyond the limit is cut back before a
        // frame is drawn into it.
        let tall = CGSize(width: 8, height: 40_000)
        layer.show(tall, model: tall, animating: false)
        stage.surface.resize(to: Self.pixels(tall))
        stage.endTurn()
        #expect(stage.surface.drawableSize == CGSize(width: 16, height: limit) && stage.surface.drawnSizes.last == CGSize(width: 16, height: limit))
    }

    // MARK: The frame-rate cap (SZ-2)

    /// A tick that comes sooner than the cap allows is still a frame of the display: during
    /// a transition it is followed like every other.
    @Test func noTickOfATransitionIsHeldAgainstTheFrameRateCap() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(Self.start, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        #expect(stage.coordinator.scheduler.followsDisplay && stage.clock.preferredRate == FrameScheduler.displayRate)
        let handled = stage.coordinator.scheduler.frames
        // Ticks 10 ms apart, as a display link delivers them after a late one: the cap of 60
        // a second would let every other one pass by.
        for step in 1 ... 6 {
            let shown = between(Self.start, Self.end, CGFloat(step) / 8)
            #expect(stage.clock.fire(rate: 100))
            layer.show(shown, model: Self.end, animating: true)
            stage.endTurn()
            #expect(stage.surface.drawableSize == Self.pixels(shown) && stage.probe.draws == 2 + step, "tick \(step) made its frame")
        }
        #expect(stage.coordinator.scheduler.frames == handled + 6, "every tick reached the surface")
        layer.show(Self.end, model: Self.end, animating: false)
        stage.frame()
        stage.frame()
        #expect(!stage.coordinator.scheduler.followsDisplay && stage.clock.preferredRate == 60, "the cap is back when the transition is over")
    }

    // MARK: The edges

    /// Presentation sizes between whole pixels: the drawable is the nearest whole pixel
    /// each way, and never smaller than one.
    @Test func drawableSizesAreWholePixels() {
        #expect(LayerGeometry.pixels(CGSize(width: 204.00005, height: 126.00008), scale: 3) == CGSize(width: 612, height: 378))
        #expect(LayerGeometry.pixels(CGSize(width: 10.4, height: 10.6), scale: 1) == CGSize(width: 10, height: 11))
        #expect(LayerGeometry.pixels(.zero, scale: 2) == CGSize(width: 1, height: 1))
        #expect(LayerGeometry.pixels(CGSize(width: 5, height: 7), scale: 0) == CGSize(width: 5, height: 7), "a scale that is no scale counts as 1")
        #expect(LayerGeometry.pixels(CGSize(width: 5, height: 7), scale: .nan) == CGSize(width: 5, height: 7))
        let still = LayerGeometry(modelSize: Self.start, presentationSize: Self.start, isAnimating: false, scale: 2)
        #expect(!still.isMoving && still.presentationPixels == CGSize(width: 200, height: 120) && still.modelPixels == still.presentationPixels)
        // A presentation size that differs by less than a pixel is the same drawable.
        let close = LayerGeometry(modelSize: Self.start, presentationSize: CGSize(width: 100.1, height: 60.1), isAnimating: false, scale: 2)
        #expect(!close.isMoving)
        #expect(LayerGeometry(modelSize: Self.start, presentationSize: Self.start, isAnimating: true, scale: 2).isMoving)
        #expect(LayerGeometry(modelSize: Self.end, presentationSize: Self.start, isAnimating: false, scale: 2).isMoving)
    }

    /// Before the first drawable there is no layer to follow: the view sizes its drawable
    /// itself, a reported size starts nothing, and a size the view announces is drawn on
    /// the next tick.
    @Test func withoutALayerThereIsNoTransition() async throws {
        var (stage, _, _) = try await scene()
        stage.coordinator.layer = nil
        stage.report(size: Self.end)
        #expect(!stage.turns.isRequested && !stage.endTurn(), "nothing to look at: no step is asked for")
        #expect(stage.settle() == 0 && !stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable && stage.probe.draws == 1)
        stage.surface.resize(to: Self.pixels(Self.end))
        #expect(!stage.turns.isRequested && stage.settle() == 1 && stage.probe.draws == 2, "drawn on the tick")
        #expect(stage.surface.drawnSizes.last == Self.pixels(Self.end) && stage.surface.drawnWithTransaction.last == false)
    }

    /// SwiftUI can give a view another size, and another scale, before the view has drawn
    /// its first frame. There is no layer to look at yet: no step is asked for, and the tick
    /// draws the first frame as every tick does. Left to a step, with no layer to follow, the
    /// frame would not be drawn at all.
    @Test func aSizeBeforeTheFirstDrawableDoesNotHoldBackTheFirstFrame() async throws {
        let content = try content(.heatmap)
        await mainQueueDrained()
        var stage = try await Stage(content, size: Self.pixels(Self.start))
        stage.report(size: Self.start)
        stage.report(size: Self.end)
        stage.setDisplayScale(3)
        #expect(!stage.turns.isRequested, "there is no layer to look at")
        #expect(stage.tick() && stage.probe.draws == 1, "the tick drew the first frame")
        #expect(!stage.endTurn() && stage.settle() == 0 && stage.probe.draws == 1 && !stage.coordinator.isInSizeTransition)
    }

    /// The content of a scene with another range of values: a cause of its own, and a frame
    /// asked for.
    private func recoloured(_ content: SurfaceContent) -> SurfaceContent {
        guard case .heatmap(let feed, var appearance) = content else { return content }
        appearance.valueRange = -70 ... -10
        return .heatmap(feed, appearance)
    }

    /// A tick in a turn in which a step is asked for draws nothing: its frame is made at
    /// the end of the turn. That holds when the step finds nothing to follow, too: what was
    /// due on the tick is drawn there, not lost.
    @Test func whatWasDueOnATickIsDrawnAtTheEndOfItsTurn() async throws {
        var (stage, layer, content) = try await scene()
        // The probe is handed another size, the appearance changes, and the tick comes
        // after both, in the same turn.
        stage.report(size: Self.end)
        stage.show(recoloured(content))
        #expect(stage.turns.isRequested && stage.tick() && stage.probe.draws == 1, "not on the tick")
        #expect(stage.endTurn() && stage.probe.draws == 2 && !stage.coordinator.isInSizeTransition, "at the end of its turn")
        #expect(stage.settle() == 0 && stage.probe.draws == 2)
        // The same when the layer is gone by the end of the turn.
        stage.report(size: Self.start)
        stage.show(content)
        layer.vanish()
        #expect(stage.tick() && stage.probe.draws == 2)
        #expect(stage.endTurn() && stage.probe.draws == 3, "drawn although there is nothing to follow")
        #expect(stage.settle() == 0 && stage.probe.draws == 3)
    }

    /// A frame that is made at the end of a turn and finds no drawable is tried again on the
    /// next two ticks, as a frame that a tick makes is; then it waits for the next cause.
    @Test func aFrameAtTheEndOfATurnThatFindsNoDrawableIsTriedAgain() async throws {
        var (stage, _, content) = try await scene()
        stage.report(size: Self.end)
        stage.show(recoloured(content))
        stage.surface.handsOutNoDrawable = true
        #expect(stage.tick() && stage.endTurn())
        #expect(stage.probe.draws == 1 && stage.isRunning, "no drawable: another tick is asked for")
        stage.surface.handsOutNoDrawable = false
        #expect(stage.tick() && stage.probe.draws == 2, "the next tick draws it")
        #expect(stage.settle() == 0)
        // Without a drawable for good it is given up after three tries.
        stage.report(size: Self.start)
        stage.show(content)
        stage.surface.handsOutNoDrawable = true
        #expect(stage.tick() && stage.endTurn())
        let ticks = stage.settle(limit: 10)
        #expect(ticks == 2 && !stage.isRunning && stage.probe.draws == 2, "it gave up after \(ticks) more ticks")
        #expect(stage.coordinator.renderer?.pendingCauses.isEmpty == false, "the cause is still pending")
    }

    /// A layer that goes away in the middle of a transition ends it: the display link must
    /// not run on.
    @Test func aLayerThatVanishesEndsTheTransition() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(between(Self.start, Self.end, 0.3), model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        #expect(stage.coordinator.isInSizeTransition && stage.isRunning)
        layer.vanish()
        stage.frame()
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable && !stage.coordinator.scheduler.followsDisplay)
        #expect(stage.settle(limit: 10) <= 1 && !stage.isRunning)
    }

    /// A view that has no drawable in the middle of a transition, as a view of no size has
    /// none: the frame is tried three times, then the transition ends and the display link
    /// pauses.
    @Test func aTransitionWithoutADrawableEnds() async throws {
        var (stage, layer, _) = try await scene()
        move(&stage, layer, to: Self.end)
        stage.endTurn()
        #expect(stage.coordinator.isInSizeTransition && stage.probe.draws == 2)
        // The view is given another size and hands out no drawable any more.
        stage.surface.handsOutNoDrawable = true
        stage.tick()
        move(&stage, layer, to: CGSize(width: 120, height: 80))
        stage.endTurn()
        #expect(stage.probe.draws == 2 && stage.coordinator.isInSizeTransition)
        let ticks = stage.settle(limit: 20)
        #expect(ticks <= 5 && !stage.isRunning && !stage.coordinator.isInSizeTransition, "it gave up after \(ticks) ticks")
        #expect(stage.coordinator.renderer?.pendingCauses.isEmpty == false, "the cause is still pending")
    }

    /// Data that arrives during a transition is uploaded as always: the same frame shows the
    /// new size and the new columns, and it is the frame made at the end of the turn.
    @Test func newDataDuringATransitionIsUploadedOnce() async throws {
        let live = try await LiveFeed(.heatmap)
        try await live.start()
        await live.send(0 ..< 3)
        var stage = try await Stage(live.content, size: Self.pixels(Self.start))
        let layer = ScriptedLayer(size: Self.start)
        stage.adopt(layer)
        stage.report(size: Self.start)
        stage.frame()
        #expect(stage.probe.draws == 1)
        for step in 1 ... 5 {
            let size = between(Self.start, Self.end, CGFloat(step) / 5)
            await live.send(3 + step - 1 ..< 3 + step)
            stage.tick()
            let afterTheTick = stage.probe.draws
            move(&stage, layer, to: size)
            stage.endTurn()
            // The tick of the first frame draws the new column at the old size: the
            // transition has not begun. From then on a frame is one draw, at the end of its turn.
            #expect(afterTheTick == step + 1 && stage.probe.draws == step + 2, "frame \(step): \(afterTheTick) draws after the tick, \(stage.probe.draws) after the turn")
            #expect(stage.probe.uploadedColumns == 3 + step)
        }
        // Columns that arrive in a frame of the transition in which no size does are drawn
        // at the end of that turn, with the frame that ends the transition.
        await live.send(8 ..< 9)
        let draws = stage.probe.draws
        stage.tick()
        #expect(stage.probe.draws == draws, "not on the tick")
        stage.endTurn()
        #expect(stage.probe.draws == draws + 1 && stage.probe.uploadedColumns == 9 && !stage.coordinator.isInSizeTransition)
        await live.stop()
        stage.settle()
        #expect(stage.probe.allocations == 1)
    }

    /// A draw the view makes by itself in the middle of a transition, with nothing pending,
    /// puts nothing into the drawable.
    @Test func aDrawWithoutACauseDuringATransitionDrawsNothing() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(between(Self.start, Self.end, 0.4), model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        stage.surface.draw()
        #expect(stage.surface.drawablesTaken == taken + 1 && stage.probe.draws == draws, "no cause, no frame")
    }

    /// The coordinator's own change of the drawable's size is not a resize the view made.
    @Test func settingTheDrawableSizeIsNotCountedAsAResize() async throws {
        let (stage, layer, _) = try await scene()
        let size = between(Self.start, Self.end, 0.5)
        layer.show(size, model: Self.end, animating: true)
        stage.surface.resize(to: Self.pixels(Self.end))
        stage.endTurn()
        let draws = stage.probe.draws
        // The view announces the size the coordinator has just set: nothing new.
        stage.coordinator.drawableSizeWillChange(to: Self.pixels(size))
        #expect(!stage.turns.isRequested)
        layer.show(Self.end, model: Self.end, animating: false)
        stage.settle()
        #expect(stage.probe.draws == draws + 1, "only the final frame")
    }

    /// While the view is not presented nothing is drawn, at the end of a turn or anywhere
    /// else; the size it has when it comes back is drawn then.
    @Test func aSizeThatArrivesWhileTheViewIsNotPresentedIsDrawnOnItsReturn() async throws {
        var (stage, layer, _) = try await scene()
        stage.setPresented(false)
        move(&stage, layer, to: Self.end)
        stage.endTurn()
        #expect(stage.probe.draws == 1 && !stage.coordinator.isInSizeTransition && !stage.isRunning)
        stage.setPresented(true)
        stage.settle()
        #expect(stage.probe.draws == 2 && stage.surface.drawnSizes.last == Self.pixels(Self.end))
    }

    /// A size that arrives before the Metal context does: there is nothing to draw with, so
    /// the frame is not made, the transition gives up as it does without a drawable, and
    /// the size is drawn when the context has arrived.
    @Test func aSizeThatArrivesBeforeTheMetalContextIsDrawnWhenTheContextArrives() async throws {
        let content = try content(.heatmap)
        await mainQueueDrained()
        let context = try await sharedContext()
        let clock = ManualClock(), turns = ManualTurn(), probe = RenderProbe()
        let coordinator = SurfaceCoordinator(input: SurfaceInput(content: content, probe: probe, displayScale: Self.scale), clock: clock, turns: turns)
        let surface = OffscreenSurface(context: context, size: Self.pixels(Self.start))
        surface.coordinator = coordinator
        coordinator.attach(surface)
        let layer = ScriptedLayer(size: Self.end)
        coordinator.layer = layer
        surface.layer = layer
        #expect(coordinator.renderer == nil, "the context is made off the main thread")
        surface.resize(to: Self.pixels(Self.end))
        #expect(turns.end())
        #expect(coordinator.isInSizeTransition && probe.draws == 0, "the size is followed, and nothing can be drawn yet")
        // Three frames of the display without a frame: the transition gives up.
        var ticks = 0
        while ticks < 10, clock.fire() {
            turns.end()
            ticks += 1
        }
        #expect(!coordinator.isInSizeTransition && !coordinator.scheduler.isRunning && probe.draws == 0, "after \(ticks) ticks")
        #expect(await eventually { coordinator.renderer != nil }, "the shared context arrived")
        #expect(clock.fire() && probe.draws == 1 && surface.drawnSizes.last == Self.pixels(Self.end), "and the size is drawn")
        coordinator.detach()
    }

    /// A surface that is detached with a frame asked for makes none.
    @Test func aDetachedSurfaceLeavesNothingOnTheRunLoop() async throws {
        var (stage, layer, _) = try await scene()
        move(&stage, layer, to: Self.end)
        #expect(stage.turns.isRequested)
        stage.coordinator.detach()
        #expect(stage.turns.isInvalidated && !stage.turns.isRequested && !stage.endTurn())
        #expect(stage.probe.draws == 1)
    }
}
