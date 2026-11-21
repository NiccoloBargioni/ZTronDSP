import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// The coordinator of the Metal bridge (WP-801): what it counts, what it compares (V-3), how
/// it comes by its Metal context, and what it does when it cannot draw.
@MainActor
@Suite("Surface coordinator")
struct SurfaceCoordinatorTests {
    private func heatmap(columns: Int = 5, rows: Int = 16, history: Int = 64, axis: FeedAxis? = nil) throws -> HeatmapFeed {
        let feed = HeatmapFeed(history: history)
        try FeedWriter.append(FeedWriter.columns(0 ..< columns, rows: rows), rows: rows, axis: axis, to: feed)
        return feed
    }

    // MARK: Make and update, counted by the probe

    @Test func aSurfaceCountsOneMakeAndDrawsItsFeedOnce() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        let stage = try await Stage(.heatmap(feed, HeatmapAppearance()))
        #expect(stage.probe.makes == 1 && stage.probe.updates == 0 && stage.probe.draws == 0)
        #expect(stage.isRunning, "a new surface asks for its first frame")
        #expect(stage.settle() == 1)
        #expect(stage.probe.draws == 1 && stage.probe.drawCalls == 1 && stage.probe.uploadedColumns == 5 && stage.probe.allocations == 1)
        #expect(!stage.isRunning && stage.coordinator.failure == nil)
        #expect(stage.surface.device == nil || stage.surface.device === stage.context.device)
    }

    /// V-3: only an update that changes the appearance, the feed or the frame-rate cap gets
    /// past the comparison and is counted.
    @Test func onlyAChangeGetsPastTheComparison() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        var stage = try await Stage(.heatmap(feed, HeatmapAppearance()))
        stage.settle()
        stage.updateAgain()
        stage.show(.heatmap(feed, HeatmapAppearance()))
        #expect(stage.probe.updates == 0 && !stage.isRunning)

        var appearance = HeatmapAppearance()
        appearance.valueRange = -70 ... -5
        stage.show(.heatmap(feed, appearance))
        #expect(stage.probe.updates == 1 && stage.isRunning)
        stage.show(.heatmap(feed, appearance))
        stage.updateAgain()
        #expect(stage.probe.updates == 1, "the same appearance again")
        #expect(stage.settle() == 1 && stage.probe.draws == 2)

        // The frame-rate cap is appearance too; it changes nothing that is drawn.
        stage.setMaximumFrameRate(30)
        #expect(stage.probe.updates == 2 && !stage.isRunning && stage.clock.preferredRate == 30)
        stage.setMaximumFrameRate(30)
        #expect(stage.probe.updates == 2)

        // Another feed object with equal contents is another feed.
        let twin = try heatmap()
        await mainQueueDrained()
        stage.show(.heatmap(twin, appearance))
        #expect(stage.probe.updates == 3)
        #expect(stage.settle() == 1 && stage.probe.draws == 3 && stage.probe.clears == 1)
    }

    /// Two appearances made from equal strategies are equal, whatever their types are called.
    @Test func appearancesCompareByValue() {
        var first = HeatmapAppearance(), second = HeatmapAppearance()
        #expect(first == second)
        first.colorMap = AnyColorMap(ListedColorMap.magma)
        #expect(first != second)
        second.colorMap = AnyColorMap(ListedColorMap.magma)
        #expect(first == second)
        second.colorMap = AnyColorMap(TurboColorMap())
        #expect(first != second, "another type of map")
        second = first
        second.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale(lowestFrequency: 20))
        #expect(first != second && !second.frequencyScale.isLinear && first.frequencyScale.isLinear)
        first.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale())
        #expect(first == second, "the default lowest frequency is 20 Hz")
        first.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale(lowestFrequency: 50))
        #expect(first != second)
    }

    @Test func contentsCompareByFeedIdentityAndAppearance() throws {
        let feed = HeatmapFeed(), other = HeatmapFeed(), wave = WaveformFeed()
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()) == .heatmap(feed, HeatmapAppearance()))
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()) != .heatmap(other, HeatmapAppearance()))
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()) != .waveform(wave, WaveformAppearance()))
        #expect(SurfaceContent.waveform(wave, WaveformAppearance()) == .waveform(wave, WaveformAppearance()))
        #expect(SurfaceContent.waveform(wave, WaveformAppearance()) != .waveform(WaveformFeed(), WaveformAppearance()))
        var loud = WaveformAppearance()
        loud.amplitudeRange = -0.5 ... 0.5
        #expect(SurfaceContent.waveform(wave, loud) != .waveform(wave, WaveformAppearance()))
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()).hasSameFeed(as: .heatmap(feed, HeatmapAppearance())))
        #expect(!SurfaceContent.heatmap(feed, HeatmapAppearance()).hasSameFeed(as: .waveform(wave, WaveformAppearance())))
        #expect(SurfaceContent.waveform(wave, loud).hasSameFeed(as: .waveform(wave, WaveformAppearance())))
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()).feed == .heatmap(feed) && SurfaceContent.waveform(wave, loud).feed == .waveform(wave))
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()).feed.shape.columnRate == nil, "a feed no pipeline writes has no rate")
        #expect(SurfaceContent.heatmap(feed, HeatmapAppearance()).feed.shape.history == 512 && SurfaceContent.waveform(wave, loud).feed.shape.history == 2_048)
    }

    // MARK: Seconds and axis units become columns and rows

    /// A time span is given in seconds and a renderer counts in columns: the feed's own
    /// feature rate converts, as soon as a pipeline has written it into the feed.
    @Test func theTimeSpanFollowsTheFeedsFeatureRate() async throws {
        // 16 rows, a hop of 480 samples at 48 kHz: 100 columns a second.
        let feed = HeatmapFeed(history: 400)
        var appearance = HeatmapAppearance()
        appearance.timeSpan = 2
        var stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 400, height: 8))
        stage.settle()
        #expect(FeedReference.heatmap(feed).shape.columnRate == nil)
        // A pipeline is attached and writes 400 columns, the newest hundred of them loud;
        // nothing tells the view.
        let values = (0 ..< 400).flatMap { column in [Float](repeating: column >= 300 ? 0 : -90, count: 16) }
        try FeedWriter.append(values, rows: 16, hop: 480, to: feed)
        await mainQueueDrained()
        #expect(FeedReference.heatmap(feed).shape.columnRate == 100)
        stage.settle()
        // Two seconds are the newest 200 columns, two pixels each: the loud hundred fill the right half.
        let narrow = try stage.surface.pixels()
        let loud = narrow.pixel(x: 397, y: 4), quiet = narrow.pixel(x: 2, y: 4)
        #expect(loud != quiet)
        #expect(narrow.pixel(x: 100, y: 4) == quiet && narrow.pixel(x: 190, y: 4) == quiet, "the older second")
        #expect(narrow.pixel(x: 210, y: 4) == loud && narrow.pixel(x: 300, y: 4) == loud, "the newest second")
        // The whole history, 4 s, is a pixel a column: the loud hundred fill the last quarter.
        appearance.timeSpan = nil
        stage.show(.heatmap(feed, appearance))
        stage.settle()
        let whole = try stage.surface.pixels()
        #expect(whole.pixel(x: 250, y: 4) == quiet && whole.pixel(x: 290, y: 4) == quiet)
        #expect(whole.pixel(x: 310, y: 4) == loud && whole.pixel(x: 397, y: 4) == loud)
        #expect(stage.probe.uploads == 1, "nothing was uploaded again")
    }

    /// `.frequencyRange` is given in the unit of the feed's axis. Rows evenly spaced in hertz
    /// take it as it is; every other axis is drawn bin for bin and takes rows.
    @Test func theVerticalRangeIsGivenInTheUnitOfTheAxis() async throws {
        // Eight tempo rows, 60 … 200 beats per minute; the row for 120 is the only one that is loud.
        let tempi = [60.0, 80, 100, 120, 140, 160, 180, 200]
        let feed = HeatmapFeed(history: 4)
        let column: [Float] = [-90, -90, -90, 0, -90, -90, -90, -90]
        try FeedWriter.append(column + column, rows: 8, axis: .tempo(beatsPerMinute: tempi), to: feed)
        await mainQueueDrained()
        var appearance = HeatmapAppearance()
        appearance.rowInterpolation = .nearest
        var stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 8, height: 80))
        stage.settle()
        let whole = try stage.surface.pixels()
        // Row 3 of 8 is the fourth cell from the bottom: y counts from the top of the picture.
        let loud = whole.pixel(x: 4, y: 80 - 35), quiet = whole.pixel(x: 4, y: 80 - 5)
        #expect(loud != quiet)
        #expect(whole.pixel(x: 4, y: 80 - 45) == quiet && whole.pixel(x: 4, y: 80 - 25) == quiet)
        // 110 … 130 beats per minute is exactly the cell of 120.
        appearance.rowRange = 110 ... 130
        stage.show(.heatmap(feed, appearance))
        stage.settle()
        let zoomed = try stage.surface.pixels()
        #expect(zoomed.pixel(x: 4, y: 3) == loud && zoomed.pixel(x: 4, y: 40) == loud && zoomed.pixel(x: 4, y: 77) == loud)
        #expect(stage.probe.uploads == 1)
    }

    // MARK: The Metal context arrives in the background (BG-1)

    @Test func aSurfaceWithoutAContextAsksForTheSharedOneAndDrawsWhenItArrives() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        let context = try await sharedContext()
        let clock = ManualClock()
        let probe = RenderProbe()
        let coordinator = SurfaceCoordinator(input: SurfaceInput(content: .heatmap(feed, HeatmapAppearance()), probe: probe), clock: clock)
        let surface = OffscreenSurface(context: context)
        surface.coordinator = coordinator
        #expect(coordinator.device == nil && coordinator.renderer == nil, "the context is made off the main thread, never in the initialiser")
        // A draw that reaches the surface before there is anything to draw with does nothing.
        coordinator.render(to: MTLRenderPassDescriptor(), presenting: nil)
        #expect(probe.draws == 0)
        coordinator.attach(surface)
        // A tick before the context is there draws nothing and asks for nothing.
        clock.fire()
        #expect(probe.draws == 0 && surface.drawablesTaken == 0 && probe.makes == 1)
        #expect(await eventually { coordinator.renderer != nil }, "the shared context arrived")
        #expect(surface.device === context.device, "the view is given its device then")
        #expect(clock.fire() && probe.draws == 1 && probe.uploadedColumns == 5)
        coordinator.detach()
    }

    @Test func aSurfaceThatIsGoneBeforeItsContextArrivesNeverDraws() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        let clock = ManualClock()
        let coordinator = SurfaceCoordinator(input: SurfaceInput(content: .heatmap(feed, HeatmapAppearance())), clock: clock)
        coordinator.detach()
        // The request was cancelled: let whatever is still on its way run.
        _ = try await sharedContext()
        await mainQueueDrained()
        #expect(coordinator.renderer == nil && clock.isInvalidated)
    }

    // MARK: What cannot be drawn

    /// A feed whose history fits no texture of the device: the surface says why and draws
    /// nothing, and a feed that fits is drawn afterwards.
    @Test func aFeedNoTextureFitsIsReportedAndTheNextFeedIsDrawn() async throws {
        let context = try await sharedContext()
        let huge = HeatmapFeed(history: context.capabilities.maximumTextureDimension + 1)
        var stage = try await Stage(.heatmap(huge, HeatmapAppearance()))
        #expect(stage.coordinator.renderer == nil)
        guard case .unsupportedConfiguration = stage.coordinator.failure else {
            Issue.record("expected unsupportedConfiguration, got \(String(describing: stage.coordinator.failure))")
            return
        }
        #expect(stage.settle() <= 1 && stage.probe.draws == 0 && !stage.isRunning)
        let feed = try heatmap()
        await mainQueueDrained()
        stage.show(.heatmap(feed, HeatmapAppearance()))
        #expect(stage.coordinator.failure == nil && stage.coordinator.renderer != nil)
        #expect(stage.settle() == 1 && stage.probe.draws == 1)
    }

    /// A view of no size has no drawable. The draw is tried on two more ticks and then waits
    /// for the next cause, so that such a view does not keep the display link running.
    @Test func aDrawWithoutADrawableDoesNotKeepTheDisplayLinkRunning() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        let stage = try await Stage(.heatmap(feed, HeatmapAppearance()), size: .zero)
        #expect(stage.settle(limit: 20) == 3, "the first tick and two more")
        #expect(stage.probe.draws == 0 && !stage.isRunning)
        #expect(stage.coordinator.renderer?.pendingCauses.isEmpty == false, "the cause is still pending")
        // The view gets a size: one draw.
        stage.surface.resize(to: CGSize(width: 32, height: 16))
        #expect(stage.settle() == 1 && stage.probe.draws == 1)
    }

    /// A feed that takes a shape no texture fits after the surface was made: the surface
    /// says why and keeps running.
    @Test func aFeedThatGrowsIntoAShapeNoTextureFitsIsReported() async throws {
        let context = try await sharedContext()
        let feed = HeatmapFeed(history: 1)
        let stage = try await Stage(.heatmap(feed, HeatmapAppearance()))
        stage.settle()
        #expect(stage.coordinator.failure == nil && stage.probe.draws == 1)
        // One column of more rows than a texture is wide.
        let rows = context.capabilities.maximumTextureDimension + 1
        try FeedWriter.append([Float](repeating: -20, count: rows), rows: rows, to: feed)
        await mainQueueDrained()
        stage.settle()
        guard case .unsupportedConfiguration = stage.coordinator.failure else {
            Issue.record("expected unsupportedConfiguration, got \(String(describing: stage.coordinator.failure))")
            return
        }
        #expect(stage.probe.uploadedColumns == 0 && !stage.isRunning, "nothing was uploaded, and the display link is paused")
    }

    /// What a hosted test sees of a surface: every content that reached the renderer.
    @Test func anInspectorSeesWhatTheSurfaceShows() async throws {
        let feed = try heatmap()
        let wave = WaveformFeed(history: 64)
        await mainQueueDrained()
        let inspector = SurfaceInspector()
        #expect(inspector.heatmap == nil && inspector.waveform == nil && inspector.contents.isEmpty)
        let coordinator = SurfaceCoordinator(input: SurfaceInput(content: .heatmap(feed, HeatmapAppearance()), inspector: inspector), clock: ManualClock(),
                                             context: try await sharedContext())
        #expect(inspector.contents == [.heatmap(feed, HeatmapAppearance())] && inspector.heatmap == HeatmapAppearance() && inspector.waveform == nil)
        coordinator.update(SurfaceInput(content: .heatmap(feed, HeatmapAppearance()), inspector: inspector))
        #expect(inspector.contents.count == 1, "an update that changes nothing is not recorded")
        coordinator.update(SurfaceInput(content: .waveform(wave, WaveformAppearance()), inspector: inspector))
        #expect(inspector.contents.count == 2 && inspector.waveform == WaveformAppearance() && inspector.heatmap == nil)
        coordinator.detach()
    }

    /// The layer of a real Metal surface, as the size transition reads it (SZ-5).
    @Test func aMetalLayerTellsItsSizeAndTakesTheTransactionFlag() {
        let layer = CAMetalLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        layer.contentsScale = 3
        let adapter = MetalLayerAdapter(layer)
        #expect(layer.isOpaque == false, "what the renderers leave untouched is transparent")
        // The scale is the one handed in, the display's as SwiftUI reports it (SZ-2), never
        // the layer's own: the Metal view rewrites `contentsScale` whenever its drawable is
        // given a size by hand, and a size computed with it shrinks or grows with every frame.
        let geometry = adapter.geometry(scale: 2)
        #expect(geometry?.modelSize == CGSize(width: 120, height: 80) && geometry?.scale == 2)
        #expect(geometry?.presentationSize == CGSize(width: 120, height: 80) && geometry?.isAnimating == false && geometry?.isMoving == false)
        #expect(geometry?.modelPixels == CGSize(width: 240, height: 160), "two pixels to the point, whatever the layer's contentsScale says")
        layer.contentsScale = 0.37
        #expect(adapter.geometry(scale: 2)?.modelPixels == CGSize(width: 240, height: 160))
        adapter.setPresentsWithTransaction(true)
        #expect(layer.presentsWithTransaction)
        adapter.setPresentsWithTransaction(false)
        #expect(!layer.presentsWithTransaction)
        // A layer that carries an animation is on its way.
        let animation = CABasicAnimation(keyPath: "bounds.size")
        animation.duration = 10
        layer.add(animation, forKey: "resize")
        #expect(adapter.geometry(scale: 2)?.isAnimating == true && adapter.geometry(scale: 2)?.isMoving == true)
        // The layer belongs to the view: once it is gone the adapter says so.
        let orphan = autoreleasepool { MetalLayerAdapter(CAMetalLayer()) }
        // The transaction that noted the layer's change lets go of it when it is committed.
        CATransaction.flush()
        #expect(orphan.geometry(scale: 2) == nil)
        orphan.setPresentsWithTransaction(true)
    }

    /// A surface whose view was never made, or is gone, has nothing to tick for.
    @Test func aSurfaceWithoutAViewDrawsNothing() async throws {
        let feed = try heatmap()
        await mainQueueDrained()
        let clock = ManualClock(), probe = RenderProbe()
        let coordinator = SurfaceCoordinator(input: SurfaceInput(content: .heatmap(feed, HeatmapAppearance()), probe: probe), clock: clock,
                                             context: try await sharedContext())
        #expect(clock.fire(5) == 1, "the first frame is asked for, finds no view, and is not asked for again")
        #expect(probe.draws == 0 && probe.makes == 0 && !coordinator.scheduler.isRunning)
        coordinator.detach()
    }

    // MARK: The end of a surface

    @Test func aDetachedSurfaceEndsItsDisplayLinkAndIgnoresWhatFollows() async throws {
        let live = try await LiveFeed(.heatmap)
        try await live.start()
        var stage = try await Stage(live.content)
        stage.tick()
        #expect(stage.isRunning && stage.probe.draws == 1)
        stage.coordinator.detach()
        #expect(stage.clock.isInvalidated && !stage.isRunning)
        await live.send(0 ..< 2)
        var appearance = HeatmapAppearance()
        appearance.valueRange = -10 ... 0
        stage.show(.heatmap(live.heatmap, appearance))
        stage.surface.resize(to: CGSize(width: 10, height: 10))
        #expect(stage.clock.fire(10) == 0 && stage.probe.draws == 1)
        await live.stop()
        #expect(!stage.isRunning)
    }

    /// A waveform surface is the same coordinator over the other renderer.
    @Test func aWaveformSurfaceDrawsItsFeed() async throws {
        let feed = WaveformFeed(history: 256)
        try FeedWriter.append(pairs: (0 ..< 64).flatMap { index in [-Float(index) / 64, Float(index) / 64] }, to: feed)
        await mainQueueDrained()
        var stage = try await Stage(.waveform(feed, WaveformAppearance()))
        #expect(stage.settle() == 1 && stage.probe.draws == 1 && stage.probe.uploadedColumns == 64)
        let before = try stage.surface.pixels()
        var appearance = WaveformAppearance()
        appearance.fill = DisplayColor(red: 1, green: 0, blue: 0)
        stage.show(.waveform(feed, appearance))
        #expect(stage.settle() == 1 && stage.probe.draws == 2 && stage.probe.uploads == 1)
        #expect(try stage.surface.pixels() != before)
        appearance.timeSpan = 0.5
        stage.show(.waveform(feed, appearance))
        #expect(stage.probe.updates == 2)
        stage.settle()
    }

    // MARK: A scene phase nobody supplied (§8.3)

    /// SwiftUI hands the scene phase to the scenes of an `App` only. In a hosting controller
    /// a view reads `.background` for as long as the host does not hand the phase down, and
    /// a surface there never draws. It says so, in the log, once: when its feed is live and
    /// it has read no other phase since it was made.
    @Test func aSurfaceThatOnlyEverReadTheBackgroundPhaseSaysSoOnceWhenItsFeedIsLive() async throws {
        let live = try await LiveFeed(.heatmap)
        var stage = try await Stage(live.content, isPresented: false, isSceneInBackground: true)
        stage.updateAgain()
        #expect(stage.coordinator.phaseNotices == 0, "nothing to say while there is nothing to show")
        try await live.start()
        #expect(stage.coordinator.phaseNotices == 1, "said when the feed became live")
        // Once for the surface: not when the feed stops and starts, not with new data, not
        // with another update, not with another feed.
        await live.send(0 ..< 3)
        await live.setBranchActive(false)
        await live.setBranchActive(true)
        stage.updateAgain()
        let other = try await LiveFeed(.heatmap)
        try await other.start()
        stage.show(other.content)
        #expect(stage.coordinator.phaseNotices == 1)
        #expect(stage.settle() == 0 && stage.probe.draws == 0, "and it draws nothing: it is not presented")
        await live.stop()
        await other.stop()
    }

    /// A feed that is live already when the surface is made under `.background`: said at
    /// once.
    @Test func aSurfaceMadeUnderTheBackgroundPhaseOnALiveFeedSaysSoAtOnce() async throws {
        let live = try await LiveFeed(.waveform)
        try await live.start()
        let stage = try await Stage(live.content, isPresented: false, isSceneInBackground: true)
        #expect(stage.coordinator.phaseNotices == 1)
        await live.stop()
    }

    /// A surface that has read any other phase knows that a phase is supplied: `.background`
    /// is then what it says, and nothing is logged, whenever the feed is live.
    @Test func aSurfaceThatReadAnotherPhaseSaysNothing() async throws {
        // Made in an active scene, which then goes to the background with a live feed.
        let live = try await LiveFeed(.heatmap)
        try await live.start()
        var stage = try await Stage(live.content)
        stage.setPresented(false)
        stage.setSceneInBackground(true)
        await live.setBranchActive(false)
        await live.setBranchActive(true)
        #expect(stage.coordinator.phaseNotices == 0)
        await live.stop()
        // Made under `.background`, and told another phase before its feed is live.
        let later = try await LiveFeed(.heatmap)
        var other = try await Stage(later.content, isPresented: false, isSceneInBackground: true)
        other.setSceneInBackground(false)
        other.setSceneInBackground(true)
        try await later.start()
        #expect(other.coordinator.phaseNotices == 0)
        await later.stop()
        // A feed that is never live gives nothing to say.
        let still = try await Stage(.heatmap(try heatmap(), HeatmapAppearance()), isPresented: false, isSceneInBackground: true)
        #expect(still.coordinator.phaseNotices == 0)
    }

    /// A coordinator shows one kind of feed for its whole life; content of the other kind
    /// gets a renderer of its own.
    @Test func contentOfTheOtherKindGetsAnotherRenderer() async throws {
        let feed = try heatmap()
        let wave = WaveformFeed(history: 64)
        try FeedWriter.append(pairs: [-0.5, 0.5, -0.25, 0.25], to: wave)
        await mainQueueDrained()
        var stage = try await Stage(.heatmap(feed, HeatmapAppearance()))
        stage.settle()
        let renderer = try #require(stage.coordinator.renderer)
        #expect(renderer.show(.heatmap(feed, HeatmapAppearance())) && !renderer.show(.waveform(wave, WaveformAppearance())))
        #expect(renderer.content == .heatmap(feed, HeatmapAppearance()), "content of the other kind changes nothing")
        stage.show(.waveform(wave, WaveformAppearance()))
        #expect(stage.coordinator.renderer !== renderer)
        #expect(stage.settle() == 1 && stage.probe.draws == 2 && stage.probe.allocations == 2)
    }
}
