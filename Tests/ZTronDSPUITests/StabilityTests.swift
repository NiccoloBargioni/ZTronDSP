import CoreGraphics
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The stability suite, level 1 (WP-809a): every scenario of the table in §8.4, asserted by
/// the counters of a `RenderProbe`, with the coordinator and the renderer driven directly: a
/// clock the test fires, an off-screen texture in the place of the Metal view, and a real
/// session that keeps the feed live. Each scenario runs for the heat map and for the waveform
/// (WP-803a, WP-804).
@MainActor
@Suite("Stability contract, level 1")
struct StabilityTests {
    /// A live feed with `blocks` blocks in it and a stage that has drawn it.
    private func scene(_ kind: SurfaceKind, blocks: Int = 4, start: Bool = true) async throws -> (LiveFeed, Stage) {
        let live = try await LiveFeed(kind)
        if start {
            try await live.start()
            if blocks > 0 { await live.send(0 ..< blocks) }
        }
        let stage = try await Stage(live.content)
        return (live, stage)
    }

    private func other(_ content: SurfaceContent, value: Float) -> SurfaceContent {
        switch content {
        case .heatmap(let feed, var appearance):
            appearance.valueRange = -90 ... value
            return .heatmap(feed, appearance)
        case .waveform(let feed, var appearance):
            appearance.amplitudeRange = -1 ... value
            return .waveform(feed, appearance)
        }
    }

    // MARK: Scenario 1

    /// Parent re-evaluates its body 100 times with equal inputs: 0 renderer updates, 0 draws,
    /// 0 new attachments.
    @Test(arguments: SurfaceKind.allCases)
    func equalInputsAHundredTimesChangeNothing(kind: SurfaceKind) async throws {
        var (live, stage) = try await scene(kind)
        await live.stop()
        stage.settle()
        let draws = stage.probe.draws, ticks = stage.coordinator.scheduler.ticks, taken = stage.surface.drawablesTaken
        #expect(draws == 1 && stage.probe.makes == 1 && stage.probe.updates == 0)
        for _ in 0 ..< 100 {
            // What a parent's body makes again: equal values, not the same ones.
            stage.show(live.content)
        }
        #expect(stage.probe.updates == 0, "updateUIView returned at the comparison every time (V-3)")
        #expect(!stage.isRunning, "nothing asked for a frame")
        #expect(stage.clock.fire(60) == 0)
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken && stage.coordinator.scheduler.ticks == ticks)
        #expect(stage.probe.attaches == 0 && stage.probe.makes == 1 && stage.probe.uploads == 1)
    }

    // MARK: Scenario 2

    /// Session running, no new data for one second: 0 draws; each tick returns after one
    /// atomic load.
    @Test(arguments: SurfaceKind.allCases)
    func aRunningSessionWithoutNewDataDrawsNothing(kind: SurfaceKind) async throws {
        let (live, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        #expect(draws == 1 && live.isLive && stage.isRunning, "a live feed keeps the display link running")
        // One second of display ticks.
        #expect(stage.clock.fire(60) == 60, "every tick is delivered")
        #expect(stage.probe.draws == draws, "no draw without a cause (V-4)")
        #expect(stage.surface.drawablesTaken == taken, "no tick took a drawable")
        #expect(stage.probe.uploads == 1 && stage.coordinator.renderer?.pendingCauses.isEmpty == true)
        // "One atomic load": such a tick asks nothing of the heap.
        let clock = stage.clock
        expectNoAllocations("1 000 ticks of an idle surface") {
            var tick = 0
            while tick < 1_000 {
                clock.fire()
                tick += 1
            }
        }
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken)
        await live.stop()
    }

    // MARK: Scenario 3

    /// Session stopped, or the branch suspended: display link paused; 0 wake-ups.
    @Test(arguments: SurfaceKind.allCases)
    func aStoppedSessionOrASuspendedBranchPausesTheDisplayLink(kind: SurfaceKind) async throws {
        let (live, stage) = try await scene(kind)
        stage.tick()
        #expect(stage.isRunning)

        // The branch is suspended (ACT-11).
        await live.setBranchActive(false)
        #expect(stage.settle() <= 1, "one last look at the feed, then the link pauses")
        #expect(!stage.isRunning && stage.clock.isPaused)
        var ticks = stage.coordinator.scheduler.ticks
        let draws = stage.probe.draws
        #expect(stage.clock.fire(60) == 0 && stage.coordinator.scheduler.ticks == ticks, "0 wake-ups")

        // It resumes: the link runs again.
        await live.setBranchActive(true)
        #expect(stage.isRunning)
        #expect(stage.clock.fire(10) == 10)

        // The session is stopped.
        await live.stop()
        #expect(stage.settle() <= 1)
        #expect(!stage.isRunning && stage.clock.isPaused)
        ticks = stage.coordinator.scheduler.ticks
        #expect(stage.clock.fire(60) == 0 && stage.coordinator.scheduler.ticks == ticks, "0 wake-ups")
        #expect(stage.probe.draws == draws, "nothing was drawn meanwhile: there was nothing new")
    }

    /// What arrives just before a session stops is still shown: the feed's last word is one
    /// more tick.
    @Test(arguments: SurfaceKind.allCases)
    func whatArrivedBeforeTheStopIsStillDrawn(kind: SurfaceKind) async throws {
        let (live, stage) = try await scene(kind)
        stage.tick()
        await live.send(4 ..< 7)
        await live.stop()
        let draws = stage.probe.draws
        #expect(stage.settle() == 1)
        #expect(stage.probe.draws == draws + 1 && stage.probe.uploadedColumns == 7 * live.itemsPerBlock)
        #expect(!stage.isRunning)
    }

    // MARK: Scenario 4

    /// Data arriving at twice the display rate for one second: draws ≤ display ticks; every
    /// column present in the texture.
    @Test(arguments: SurfaceKind.allCases)
    func dataAtTwiceTheDisplayRateIsOneDrawPerTickAndNothingIsLost(kind: SurfaceKind) async throws {
        let (live, stage) = try await scene(kind, blocks: 0)
        stage.tick()
        let before = stage.probe.draws
        var ticks = 0
        for tick in 0 ..< 60 {
            // Two blocks between two ticks.
            await live.send(2 * tick ..< 2 * tick + 2)
            #expect(stage.tick())
            ticks += 1
        }
        #expect(stage.probe.draws - before <= ticks && stage.probe.draws - before == 60)
        #expect(stage.probe.uploadedColumns == 120 * live.itemsPerBlock && stage.probe.uploads == 60, "every column went up, each once")
        #expect(stage.probe.drawCalls == stage.probe.draws, "one draw call per frame (V-5)")
        #expect(stage.probe.allocations == 1 && stage.probe.clears == 0)
        await live.stop()
        stage.settle()
        // Every column is in the texture: the picture is the one a surface that takes them
        // all at once draws.
        let fresh = try await Stage(live.content)
        fresh.settle()
        #expect(fresh.probe.uploadedColumns == 120 * live.itemsPerBlock && fresh.probe.uploads == 1)
        #expect(try fresh.surface.pixels() == stage.surface.pixels())
    }

    // MARK: Scenario 5

    /// Colour map changed: exactly 1 draw, 0 column uploads.
    @Test func aChangedColourMapIsExactlyOneDrawAndNoUpload() async throws {
        var (live, stage) = try await scene(.heatmap)
        await live.stop()
        stage.settle()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        let before = try stage.surface.pixels()
        var appearance = HeatmapAppearance()
        appearance.colorMap = AnyColorMap(ListedColorMap.magma)
        stage.show(.heatmap(live.heatmap, appearance))
        #expect(stage.probe.updates == 1 && stage.isRunning)
        #expect(stage.settle() == 1, "one tick serves it")
        #expect(stage.probe.draws == draws + 1, "exactly one draw")
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns, "nothing uploaded")
        #expect(try stage.surface.pixels() != before, "the picture shows the other map")
        // The same map again is no update at all.
        stage.show(.heatmap(live.heatmap, appearance))
        #expect(stage.probe.updates == 1 && !stage.isRunning)
    }

    /// The other discrete values: each is one draw and no upload.
    @Test func everyOtherAppearanceValueIsOneDrawAndNoUpload() async throws {
        var (live, stage) = try await scene(.heatmap)
        await live.stop()
        stage.settle()
        var appearance = HeatmapAppearance()
        func changed(_ what: String, _ change: (inout HeatmapAppearance) -> Void) {
            let draws = stage.probe.draws, uploads = stage.probe.uploads, updates = stage.probe.updates
            change(&appearance)
            stage.show(.heatmap(live.heatmap, appearance))
            #expect(stage.settle() == 1, "\(what)")
            #expect(stage.probe.draws == draws + 1 && stage.probe.uploads == uploads && stage.probe.updates == updates + 1, "\(what)")
        }
        changed("frequency scale") { $0.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale()) }
        changed("value range") { $0.valueRange = -60 ... -10 }
        changed("row range") { $0.rowRange = 2 ... 9 }
        changed("row interpolation") { $0.rowInterpolation = .nearest }
        changed("time span") { $0.timeSpan = 0.001 }
    }

    // MARK: Scenario 6

    /// Value range animated over half a second: 1 draw per display frame, 0 uploads.
    @Test(arguments: SurfaceKind.allCases)
    func anAnimatedRangeIsOneDrawPerDisplayFrameAndNoUpload(kind: SurfaceKind) async throws {
        var (live, stage) = try await scene(kind)
        await live.stop()
        stage.settle()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        // Half a second at 60 frames a second: SwiftUI hands the surface one interpolated
        // appearance per display frame.
        for frame in 1 ... 30 {
            stage.show(other(live.content, value: Float(frame) / 30))
            #expect(stage.tick())
            #expect(stage.probe.draws == draws + frame, "one draw for frame \(frame)")
        }
        #expect(stage.probe.updates == 30)
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns, "0 uploads")
        #expect(stage.settle() == 0 && !stage.isRunning, "the animation is over: the link pauses")
    }

    // MARK: Scenario 7

    /// View resized without animation: 1 draw per changed size, 0 uploads.
    @Test(arguments: SurfaceKind.allCases)
    func aResizeIsOneDrawPerChangedSizeAndNoUpload(kind: SurfaceKind) async throws {
        let (live, stage) = try await scene(kind)
        await live.stop()
        stage.settle()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, allocations = stage.probe.allocations
        let sizes = [CGSize(width: 96, height: 24), CGSize(width: 96, height: 60), CGSize(width: 31, height: 17)]
        for (index, size) in sizes.enumerated() {
            stage.surface.resize(to: size)
            #expect(stage.isRunning)
            #expect(stage.settle() == 1)
            #expect(stage.probe.draws == draws + index + 1, "one draw for \(size)")
            #expect(stage.surface.drawnSizes.last == size)
        }
        // The same size again is no cause.
        stage.surface.resize(to: sizes[2])
        #expect(!stage.isRunning && stage.probe.draws == draws + 3)
        #expect(stage.probe.uploads == uploads && stage.probe.allocations == allocations, "resizing uploads nothing and allocates no data texture (V-6)")
    }

    // MARK: Scenario 8

    /// Feed replaced: texture cleared once, then normal operation.
    @Test(arguments: SurfaceKind.allCases)
    func aReplacedFeedClearsTheTextureOnceAndThenWorksAsBefore(kind: SurfaceKind) async throws {
        var (first, stage) = try await scene(kind)
        stage.tick()
        let second = try await LiveFeed(kind)
        try await second.start()
        await second.send(0 ..< 3)
        let draws = stage.probe.draws
        stage.show(second.content)
        #expect(stage.probe.updates == 1)
        #expect(stage.tick())
        #expect(stage.probe.clears == 1, "cleared once")
        #expect(stage.probe.draws == draws + 1 && stage.probe.allocations == 1, "the texture is kept: the shape is the same")
        #expect(stage.probe.uploadedColumns == (4 + 3) * first.itemsPerBlock, "the new feed's columns went up")
        // Normal operation: new data of the new feed is drawn, the old feed's is not.
        await second.send(3 ..< 5)
        #expect(stage.tick() && stage.probe.draws == draws + 2)
        await first.send(4 ..< 6)
        #expect(stage.tick() && stage.probe.draws == draws + 2, "the old feed does not reach the surface any more")
        #expect(stage.probe.clears == 1)
        // The surface follows the liveness of the feed it shows now.
        await first.stop()
        stage.tick()
        #expect(stage.isRunning, "the new feed is still live")
        await second.stop()
        #expect(stage.settle() <= 1 && !stage.isRunning)
    }

    // MARK: Scenario 9

    /// Scene inactive, then active: 0 draws while inactive; 1 draw on return.
    @Test(arguments: SurfaceKind.allCases)
    func nothingIsDrawnWhileTheSceneIsInactiveAndOneFrameOnReturn(kind: SurfaceKind) async throws {
        var (live, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        stage.setPresented(false)
        #expect(!stage.isRunning, "the scheduler is paused although the feed is live")
        // Data keeps arriving and the appearance changes: nothing is submitted to the GPU.
        await live.send(4 ..< 9)
        stage.show(other(live.content, value: 0.5))
        #expect(stage.clock.fire(60) == 0)
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken, "0 draws while inactive")
        stage.setPresented(true)
        #expect(stage.isRunning)
        #expect(stage.tick())
        #expect(stage.probe.draws == draws + 1, "1 draw on return")
        #expect(stage.probe.uploadedColumns == 9 * live.itemsPerBlock, "with everything that arrived meanwhile")
        #expect(stage.clock.fire(30) == 30 && stage.probe.draws == draws + 1)
        await live.stop()
    }

    /// A scene that returns with nothing new still draws once: the drawable may be stale.
    @Test func aSceneThatReturnsWithNothingNewDrawsOnce() async throws {
        var (live, stage) = try await scene(.heatmap)
        await live.stop()
        stage.settle()
        let draws = stage.probe.draws
        stage.setPresented(false)
        stage.setPresented(true)
        #expect(stage.settle() == 1 && stage.probe.draws == draws + 1)
        #expect(stage.probe.updates == 0, "presence is not appearance")
    }
}
