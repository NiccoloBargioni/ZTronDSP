import CoreGraphics
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// Size transitions (WP-823, §8.9): the drawable follows the size the layer is shown at on
/// every display tick, frames are presented with the layer's transaction, and the last frame
/// is drawn at the layer's own size. The layer and the view are scripted through their seams
/// (`SurfaceLayer`, `MetalSurface`); how a hosted Metal view really moves through an animated
/// change of size is what the spike WP-822 finds out.
@MainActor
@Suite("Size transitions")
struct SizeTransitionTests {
    static let start = CGSize(width: 100, height: 60)
    static let end = CGSize(width: 160, height: 150)
    static let scale: CGFloat = 2

    /// A stopped feed with five columns, a surface that has drawn it at `start`, and the
    /// surface's layer in the test's hands.
    private func scene(_ kind: SurfaceKind = .heatmap) async throws -> (Stage, ScriptedLayer, SurfaceContent) {
        let content: SurfaceContent
        switch kind {
        case .heatmap:
            let feed = HeatmapFeed(history: 32)
            try FeedWriter.append(FeedWriter.columns(0 ..< 5, rows: 16), rows: 16, to: feed)
            content = .heatmap(feed, HeatmapAppearance())
        case .waveform:
            let feed = WaveformFeed(history: 128)
            try FeedWriter.append(pairs: (0 ..< 64).flatMap { index in [-Float(index) / 64, Float(index) / 64] }, to: feed)
            content = .waveform(feed, WaveformAppearance())
        }
        await mainQueueDrained()
        var stage = try await Stage(content, size: LayerGeometry.pixels(Self.start, scale: Self.scale))
        let layer = ScriptedLayer(size: Self.start, scale: Self.scale)
        stage.adopt(layer)
        stage.report(size: Self.start)
        #expect(stage.settle() == 1 && stage.probe.draws == 1)
        return (stage, layer, content)
    }

    private func between(_ from: CGSize, _ to: CGSize, _ fraction: CGFloat) -> CGSize {
        CGSize(width: from.width + (to.width - from.width) * fraction, height: from.height + (to.height - from.height) * fraction)
    }

    // MARK: A layer that animates (SZ-4, the layer's signal)

    /// The layer's own size jumps to where the transition ends, and the layer is shown at
    /// sizes on the way: what Core Animation does with an animated change of bounds.
    @Test(arguments: SurfaceKind.allCases)
    func theDrawableFollowsThePresentationSizeAtEveryTick(kind: SurfaceKind) async throws {
        let (stage, layer, _) = try await scene(kind)
        let uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        // The view lays out at its new size and resizes its drawable by itself, once.
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: Self.scale))
        #expect(stage.isRunning)
        let steps = 12
        for step in 1 ..< steps {
            let shown = between(Self.start, Self.end, CGFloat(step) / CGFloat(steps))
            layer.show(shown, model: Self.end, animating: true)
            #expect(stage.tick(), "the display link runs for the whole transition")
            #expect(stage.coordinator.isInSizeTransition)
            let wanted = LayerGeometry.pixels(shown, scale: Self.scale)
            #expect(stage.surface.drawableSize == wanted, "tick \(step): the drawable has the size the layer is shown at")
            #expect(stage.surface.drawnSizes.last == wanted && stage.probe.draws == 1 + step, "and one frame was drawn at it")
            #expect(!stage.surface.autoResizeDrawable, "automatic resizing is off for the duration (SZ-2)")
            #expect(layer.presentsWithTransaction && stage.surface.drawnWithTransaction.last == true, "presented with the transaction (SZ-3)")
        }
        // The animation is over: the layer is shown at its own size.
        layer.show(Self.end, model: Self.end, animating: false)
        #expect(stage.tick())
        #expect(!stage.coordinator.isInSizeTransition)
        #expect(stage.surface.drawableSize == LayerGeometry.pixels(Self.end, scale: Self.scale))
        #expect(stage.surface.drawnSizes.last == LayerGeometry.pixels(Self.end, scale: Self.scale), "a final draw at the model size")
        #expect(stage.probe.draws == 1 + steps)
        #expect(stage.surface.autoResizeDrawable && !layer.presentsWithTransaction && stage.surface.drawnWithTransaction.last == false,
                "outside a transition the drawable sizes itself and presentation is asynchronous again")
        #expect(stage.clock.fire(30) == 0 && !stage.isRunning, "nothing more is drawn")
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns && stage.probe.allocations == 1, "nothing was uploaded (SZ-1)")
    }

    /// SZ-1: rendering does not depend on resolution. A frame of the transition is the frame
    /// a surface draws directly at that size.
    @Test func aFrameOfATransitionShowsWhatADirectDrawAtThatSizeShows() async throws {
        let (stage, layer, content) = try await scene()
        let middle = between(Self.start, Self.end, 0.5)
        layer.show(middle, model: Self.end, animating: true)
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: Self.scale))
        stage.tick()
        let during = try stage.surface.pixels()
        let direct = try await Stage(content, size: LayerGeometry.pixels(middle, scale: Self.scale))
        direct.settle()
        let reference = try direct.surface.pixels()
        #expect(during.width == reference.width && during.height == reference.height)
        #expect(during == reference)
    }

    // MARK: A size that SwiftUI steps (SZ-4, the probe's signal)

    /// The probe of the SwiftUI wrapper reports one interpolated size per display frame, and
    /// the layer is at that size already: nothing animates on the layer.
    @Test(arguments: SurfaceKind.allCases)
    func aSteppedSizeIsFollowedTickByTickAndEndsWithoutASpareDraw(kind: SurfaceKind) async throws {
        var (stage, layer, _) = try await scene(kind)
        let steps = 10
        for step in 1 ... steps {
            let size = between(Self.start, Self.end, CGFloat(step) / CGFloat(steps))
            layer.show(size, model: size, animating: false)
            stage.report(size: size)
            #expect(stage.isRunning)
            #expect(stage.tick())
            #expect(stage.coordinator.isInSizeTransition && !stage.surface.autoResizeDrawable && layer.presentsWithTransaction)
            #expect(stage.surface.drawableSize == LayerGeometry.pixels(size, scale: Self.scale))
            #expect(stage.probe.draws == 1 + step && stage.surface.drawnSizes.last == LayerGeometry.pixels(size, scale: Self.scale))
        }
        // No new size: the transition is over. The last frame was drawn at the exact size
        // already, so nothing more is drawn.
        #expect(stage.tick())
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable && !layer.presentsWithTransaction)
        #expect(stage.probe.draws == 1 + steps, "no spare draw")
        #expect(stage.surface.drawableSize == LayerGeometry.pixels(Self.end, scale: Self.scale))
        #expect(stage.clock.fire(30) == 0)
        #expect(stage.probe.uploads == 1)
    }

    /// A resize without animation, as the probe sees it: one draw for the changed size
    /// (§8.4), presented with the transaction so that the old picture is never shown
    /// stretched.
    @Test func aSingleNewSizeIsOneDraw() async throws {
        var (stage, layer, _) = try await scene()
        let size = CGSize(width: 140, height: 90)
        layer.show(size, model: size, animating: false)
        // Both things a hosted view does: the view resizes its drawable, and the probe reports.
        stage.surface.resize(to: LayerGeometry.pixels(size, scale: Self.scale))
        stage.report(size: size)
        #expect(stage.settle() == 2, "the tick that draws and the tick that ends the transition")
        #expect(stage.probe.draws == 2 && stage.surface.drawnSizes.last == LayerGeometry.pixels(size, scale: Self.scale))
        #expect(stage.surface.drawnWithTransaction.last == true)
        // The same size reported again is not a change.
        stage.report(size: size)
        #expect(!stage.isRunning && stage.probe.draws == 2)
        #expect(stage.probe.updates == 0, "a size is not appearance")
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
    /// itself and a reported size starts nothing.
    @Test func withoutALayerThereIsNoTransition() async throws {
        var (stage, _, _) = try await scene()
        stage.coordinator.layer = nil
        stage.report(size: Self.end)
        #expect(stage.settle() == 1)
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable && stage.probe.draws == 1)
    }

    /// A layer that goes away in the middle of a transition ends it: the display link must
    /// not run on.
    @Test func aLayerThatVanishesEndsTheTransition() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(between(Self.start, Self.end, 0.3), model: Self.end, animating: true)
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: Self.scale))
        stage.tick()
        #expect(stage.coordinator.isInSizeTransition && stage.isRunning)
        layer.geometry = nil
        stage.tick()
        #expect(!stage.coordinator.isInSizeTransition && stage.surface.autoResizeDrawable)
        #expect(stage.clock.fire(10) == 0)
    }

    /// Data that arrives during a transition is uploaded as always: the same frame shows the
    /// new size and the new columns.
    @Test func newDataDuringATransitionIsUploadedOnce() async throws {
        let live = try await LiveFeed(.heatmap)
        try await live.start()
        await live.send(0 ..< 3)
        var stage = try await Stage(live.content, size: LayerGeometry.pixels(Self.start, scale: Self.scale))
        let layer = ScriptedLayer(size: Self.start, scale: Self.scale)
        stage.adopt(layer)
        stage.report(size: Self.start)
        stage.tick()
        for step in 1 ... 5 {
            let size = between(Self.start, Self.end, CGFloat(step) / 5)
            layer.show(size, model: size, animating: false)
            stage.report(size: size)
            await live.send(3 + step - 1 ..< 3 + step)
            stage.tick()
            #expect(stage.probe.draws == 1 + step && stage.probe.uploadedColumns == 3 + step)
        }
        await live.stop()
        stage.settle()
        #expect(stage.probe.draws == 6 && stage.probe.allocations == 1)
    }

    /// A draw the view makes by itself in the middle of a transition, with nothing pending,
    /// puts nothing into the drawable.
    @Test func aDrawWithoutACauseDuringATransitionDrawsNothing() async throws {
        let (stage, layer, _) = try await scene()
        layer.show(between(Self.start, Self.end, 0.4), model: Self.end, animating: true)
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: Self.scale))
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        stage.surface.draw()
        #expect(stage.surface.drawablesTaken == taken + 1 && stage.probe.draws == draws, "no cause, no frame")
    }

    /// The coordinator's own change of the drawable's size is not a resize the view made.
    @Test func settingTheDrawableSizeIsNotCountedAsAResize() async throws {
        let (stage, layer, _) = try await scene()
        let size = between(Self.start, Self.end, 0.5)
        layer.show(size, model: Self.end, animating: true)
        stage.surface.resize(to: LayerGeometry.pixels(Self.end, scale: Self.scale))
        stage.tick()
        let draws = stage.probe.draws
        // The view announces the size the coordinator has just set: nothing new.
        stage.coordinator.drawableSizeWillChange(to: LayerGeometry.pixels(size, scale: Self.scale))
        layer.show(Self.end, model: Self.end, animating: false)
        #expect(stage.settle() == 1 && stage.probe.draws == draws + 1, "only the final frame")
    }
}
