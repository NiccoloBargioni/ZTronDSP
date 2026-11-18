import CoreGraphics
import Foundation
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The stability suite, level 1, for a source-fed view (§8.4): every scenario of the table,
/// asserted by counters, for a spectrogram and for a waveform that analyse a source
/// themselves.
///
/// A source-fed component is two things: the attachment it keeps on its source, and the
/// surface that shows the feed the attachment writes. Here both are driven directly, as the
/// view drives them: the model that keeps the attachment, with the component's own pipeline
/// on a source the test feeds by hand; and the coordinator of the surface, with a clock the
/// test fires and an off-screen texture in the place of the Metal view. Both count into one
/// `RenderProbe`, as they do in a view.
@MainActor
@Suite("Stability contract, level 1, source-fed")
struct SourceFedStabilityTests {
    /// A component in the hierarchy, its session running, `blocks` blocks sent, and the
    /// surface that shows its feed.
    private func scene(_ kind: SourceFedKind, blocks: Int = 4) async throws -> (SourceFedRig, Stage) {
        let rig = SourceFedRig(kind)
        rig.appear()
        await rig.running()
        if blocks > 0 { await rig.send(0 ..< blocks) }
        let stage = try await Stage(rig.content, probe: rig.render)
        return (rig, stage)
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
    @Test(arguments: SourceFedKind.allCases)
    func equalInputsAHundredTimesChangeNothing(kind: SourceFedKind) async throws {
        var (rig, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        #expect(draws == 1 && stage.probe.makes == 1 && stage.probe.updates == 0 && stage.probe.attaches == 1)
        for _ in 0 ..< 100 {
            // What a parent's body makes again: the same source, an equal pipeline, equal
            // appearance values.
            rig.evaluate()
            stage.show(rig.content)
        }
        await mainQueueDrained()
        #expect(stage.probe.updates == 0, "0 renderer updates: updateUIView returned at the comparison every time (V-3)")
        #expect(stage.probe.attaches == 1 && rig.host.attaches == 1 && rig.host.requests == 1, "0 new attachments")
        #expect(rig.host.updates.isEmpty, "and the session was handed nothing")
        // The session runs, so the display ticks; nothing is new, so nothing is drawn.
        #expect(stage.clock.fire(60) == 60)
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken, "0 draws")
        #expect(stage.probe.makes == 1 && stage.probe.uploads == 1)
        rig.leave()
    }

    // MARK: Scenario 2

    /// Session running, no new data for one second: 0 draws; each tick returns after one
    /// atomic load.
    @Test(arguments: SourceFedKind.allCases)
    func aRunningSessionWithoutNewDataDrawsNothing(kind: SourceFedKind) async throws {
        let (rig, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        #expect(draws == 1 && rig.isLive && stage.isRunning, "the view's own session keeps the display link running")
        #expect(stage.clock.fire(60) == 60, "every tick is delivered")
        #expect(stage.probe.draws == draws, "no draw without a cause (V-4)")
        #expect(stage.surface.drawablesTaken == taken, "no tick took a drawable")
        #expect(stage.probe.uploads == 1 && stage.coordinator.renderer?.pendingCauses.isEmpty == true)
        let clock = stage.clock
        expectNoAllocations("1 000 ticks of an idle source-fed surface") {
            var tick = 0
            while tick < 1_000 {
                clock.fire()
                tick += 1
            }
        }
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken)
        rig.leave()
    }

    // MARK: Scenario 3

    /// Session stopped, or the branch suspended: display link paused; 0 wake-ups. The session
    /// of a source-fed view stops running when its source is interrupted, when its source
    /// ends, and when the view leaves.
    @Test(arguments: SourceFedKind.allCases)
    func aSessionThatDoesNotRunPausesTheDisplayLink(kind: SourceFedKind) async throws {
        let (rig, stage) = try await scene(kind)
        stage.tick()
        #expect(stage.isRunning)

        // The source is interrupted: a phone call.
        rig.source.announce(.interrupted)
        await rig.live(false)
        #expect(rig.host.session?.state == .interrupted)
        #expect(stage.settle() <= 1, "one last look at the feed, then the link pauses")
        #expect(!stage.isRunning && stage.clock.isPaused)
        var ticks = stage.coordinator.scheduler.ticks
        let draws = stage.probe.draws
        #expect(stage.clock.fire(60) == 0 && stage.coordinator.scheduler.ticks == ticks, "0 wake-ups")

        // It resumes: the link runs again.
        rig.source.announce(.resumed)
        await rig.live(true)
        #expect(stage.isRunning)
        #expect(stage.clock.fire(10) == 10)
        #expect(stage.probe.draws == draws, "nothing was drawn meanwhile: there was nothing new")

        // The view leaves the hierarchy: its session is detached.
        let feed = rig.feed
        rig.leave()
        #expect(await eventually(timeout: patience) { !feed.isLive })
        await mainQueueDrained()
        #expect(stage.settle() <= 1)
        #expect(!stage.isRunning && stage.clock.isPaused)
        ticks = stage.coordinator.scheduler.ticks
        #expect(stage.clock.fire(60) == 0 && stage.coordinator.scheduler.ticks == ticks, "0 wake-ups")
    }

    /// A source that ends leaves its picture standing and the display link paused.
    @Test(arguments: SourceFedKind.allCases)
    func aSourceThatEndsPausesTheDisplayLinkAndWhatArrivedIsStillDrawn(kind: SourceFedKind) async throws {
        let (rig, stage) = try await scene(kind)
        stage.tick()
        await rig.send(4 ..< 7)
        rig.source.announce(.ended)
        #expect(await eventually(timeout: patience) { rig.host.session?.state == .finished })
        await rig.live(false)
        let draws = stage.probe.draws
        #expect(stage.settle() == 1, "the feed's last word is one more tick")
        #expect(stage.probe.draws == draws + 1 && stage.probe.uploadedColumns == 7 * rig.itemsPerBlock, "what arrived before the end is shown")
        #expect(!stage.isRunning && stage.clock.fire(60) == 0)
        rig.leave()
    }

    // MARK: Scenario 4

    /// Data arriving at twice the display rate for one second: draws ≤ display ticks; every
    /// column present in the texture.
    @Test(arguments: SourceFedKind.allCases)
    func dataAtTwiceTheDisplayRateIsOneDrawPerTickAndNothingIsLost(kind: SourceFedKind) async throws {
        let (rig, stage) = try await scene(kind, blocks: 0)
        stage.tick()
        let before = stage.probe.draws
        var ticks = 0
        for tick in 0 ..< 60 {
            // Two blocks between two ticks.
            await rig.send(2 * tick ..< 2 * tick + 2)
            #expect(stage.tick())
            ticks += 1
        }
        #expect(stage.probe.draws - before <= ticks && stage.probe.draws - before == 60)
        #expect(stage.probe.uploadedColumns == 120 * rig.itemsPerBlock && stage.probe.uploads == 60, "every column went up, each once")
        #expect(stage.probe.drawCalls == stage.probe.draws, "one draw call per frame (V-5)")
        #expect(stage.probe.allocations == 1 && stage.probe.clears == 0)
        #expect(rig.host.updates.isEmpty && stage.probe.updates == 0 && stage.probe.attaches == 1, "data is no cause for an update or an attachment")
        // Every column is in the texture: the picture is the one a surface that takes them
        // all at once draws.
        let feed = rig.content
        rig.leave()
        stage.settle()
        let fresh = try await Stage(feed)
        fresh.settle()
        #expect(fresh.probe.uploadedColumns == 120 * rig.itemsPerBlock && fresh.probe.uploads == 1)
        #expect(try fresh.surface.pixels() == stage.surface.pixels())
    }

    // MARK: Scenario 5

    /// Colour map changed: exactly 1 draw, 0 column uploads.
    @Test func aChangedColourMapIsExactlyOneDrawAndNoUpload() async throws {
        var (rig, stage) = try await scene(.spectrogram)
        stage.tick()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        let before = try stage.surface.pixels()
        var appearance = HeatmapAppearance()
        appearance.colorMap = AnyColorMap(ListedColorMap.magma)
        stage.show(.heatmap(rig.heatmap, appearance))
        #expect(stage.probe.updates == 1)
        #expect(stage.tick())
        #expect(stage.probe.draws == draws + 1, "exactly one draw")
        #expect(stage.clock.fire(30) == 30 && stage.probe.draws == draws + 1)
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns, "nothing uploaded")
        #expect(try stage.surface.pixels() != before, "the picture shows the other map")
        #expect(rig.host.updates.isEmpty && rig.host.attaches == 1, "appearance is nothing to the session")
        // The same map again is no update at all.
        stage.show(.heatmap(rig.heatmap, appearance))
        #expect(stage.probe.updates == 1)
        rig.leave()
    }

    // MARK: Scenario 6

    /// Value range animated over half a second: 1 draw per display frame, 0 uploads.
    @Test(arguments: SourceFedKind.allCases)
    func anAnimatedRangeIsOneDrawPerDisplayFrameAndNoUpload(kind: SourceFedKind) async throws {
        var (rig, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        for frame in 1 ... 30 {
            stage.show(other(rig.content, value: Float(frame) / 30))
            #expect(stage.tick())
            #expect(stage.probe.draws == draws + frame, "one draw for frame \(frame)")
        }
        #expect(stage.probe.updates == 30)
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns, "0 uploads")
        #expect(rig.host.updates.isEmpty, "the session is handed nothing")
        #expect(stage.clock.fire(30) == 30 && stage.probe.draws == draws + 30, "the animation is over: nothing more is drawn")
        rig.leave()
    }

    /// The other animation of a source-fed view, that of its pipeline (ANI-3): one update of
    /// the session per display frame, and nothing for the surface to do. No renderer update,
    /// no draw beyond what new data asks for.
    @Test(arguments: SourceFedKind.allCases)
    func anAnimatedProcessingValueIsNoCauseForADraw(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind)
        rig.processing = PipelineHostTests.chain([-6])
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 4)
        var stage = try await Stage(rig.content, probe: rig.render)
        stage.tick()
        let draws = stage.probe.draws
        for frame in 1 ... 30 {
            rig.processing = PipelineHostTests.chain([-6 - Double(frame) / 2])
            rig.evaluate()
            stage.show(rig.content)
            await rig.settled()
            #expect(stage.tick())
        }
        #expect(rig.host.updates.count == 30, "one update of the session per frame")
        #expect(stage.probe.updates == 0 && stage.probe.draws == draws && stage.probe.attaches == 1, "0 renderer updates, 0 draws, 0 new attachments")
        rig.leave()
    }

    // MARK: Scenario 7

    /// View resized without animation: 1 draw per changed size, 0 uploads.
    @Test(arguments: SourceFedKind.allCases)
    func aResizeIsOneDrawPerChangedSizeAndNoUpload(kind: SourceFedKind) async throws {
        let (rig, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, allocations = stage.probe.allocations
        let sizes = [CGSize(width: 96, height: 24), CGSize(width: 96, height: 60), CGSize(width: 31, height: 17)]
        for (index, size) in sizes.enumerated() {
            stage.surface.resize(to: size)
            #expect(stage.tick())
            #expect(stage.probe.draws == draws + index + 1, "one draw for \(size)")
            #expect(stage.surface.drawnSizes.last == size)
            #expect(stage.clock.fire(5) == 5 && stage.probe.draws == draws + index + 1)
        }
        // The same size again is no cause.
        stage.surface.resize(to: sizes[2])
        #expect(stage.clock.fire(5) == 5 && stage.probe.draws == draws + 3)
        #expect(stage.probe.uploads == uploads && stage.probe.allocations == allocations, "resizing uploads nothing and allocates no data texture (V-6)")
        #expect(rig.host.updates.isEmpty && stage.probe.attaches == 1)
        rig.leave()
    }

    // MARK: Scenario 8

    /// Feed replaced: texture cleared once, then normal operation. A source-fed view's feed is
    /// replaced when the view is given another source: the picture of one source is not
    /// continued with another's.
    @Test(arguments: SourceFedKind.allCases)
    func anotherSourceClearsTheTextureOnceAndThenWorksAsBefore(kind: SourceFedKind) async throws {
        var (rig, stage) = try await scene(kind)
        stage.tick()
        let first = rig.source, draws = stage.probe.draws
        // The view is given another source: another attachment, into another feed.
        rig.give(rig.otherSource())
        stage.show(rig.content)
        #expect(stage.probe.updates == 1)
        await rig.running()
        await rig.send(4 ..< 7)
        #expect(stage.tick())
        #expect(stage.probe.clears == 1, "cleared once")
        #expect(stage.probe.draws == draws + 1 && stage.probe.allocations == 1, "the texture is kept: the shape is the same")
        #expect(stage.probe.uploadedColumns == (4 + 3) * rig.itemsPerBlock, "the other source's columns went up")
        #expect(stage.probe.attaches == 2 && rig.host.detaches == 1, "one attachment ended, one made")
        // Normal operation: what the other source delivers is drawn; the first source
        // reaches nobody.
        await rig.send(7 ..< 9)
        #expect(stage.tick() && stage.probe.draws == draws + 2)
        first.write(SourceFedRig.blocks(9 ..< 11))
        await mainQueueDrained()
        #expect(stage.tick() && stage.probe.draws == draws + 2, "the first source does not reach the surface any more")
        #expect(stage.probe.clears == 1 && stage.probe.uploadedColumns == (4 + 5) * rig.itemsPerBlock)
        #expect(stage.isRunning, "the surface follows the liveness of the feed it shows now")
        rig.leave()
        stage.show(rig.content)
        #expect(stage.settle() <= 2 && !stage.isRunning)
    }

    /// The analysis replaced: a spectrogram whose frame changes keeps its feed, which takes
    /// another shape. The data texture is allocated anew once, for the other number of bins
    /// (V-6), then normal operation.
    @Test func anotherAnalysisFrameReallocatesTheTextureOnceAndThenWorksAsBefore() async throws {
        let (rig, stage) = try await scene(.spectrogram)
        stage.tick()
        #expect(stage.probe.allocations == 1 && stage.probe.uploadedColumns == 4)
        rig.frame = AnalysisFrame(frame: 32, hop: 16, window: .hann)
        rig.evaluate()
        await rig.settled()
        let block = SourceFedRig.blocks(4 ..< 5)
        #expect(await eventually(timeout: patience) {
            rig.source.write(block)
            return rig.heatmap.rowCount == 17 && rig.heatmap.columnCount >= 3
        }, "the plan of the other frame took over, and the feed refills")
        let draws = stage.probe.draws
        #expect(stage.tick())
        #expect(stage.probe.allocations == 2, "allocated once more: 17 bins in the place of 9")
        #expect(stage.probe.draws == draws + 1 && stage.probe.updates == 0 && stage.probe.attaches == 1, "the surface was told nothing: it found the feed changed")
        // Normal operation.
        let columns = stage.probe.uploadedColumns
        #expect(await eventually(timeout: patience) {
            rig.source.write(block)
            return rig.heatmap.columnCount >= 8
        })
        #expect(stage.tick())
        #expect(stage.probe.allocations == 2 && stage.probe.uploadedColumns > columns && stage.probe.draws == draws + 2)
        rig.leave()
    }

    // MARK: Scenario 9

    /// Scene inactive, then active: 0 draws while inactive; 1 draw on return.
    @Test(arguments: SourceFedKind.allCases)
    func nothingIsDrawnWhileTheSceneIsInactiveAndOneFrameOnReturn(kind: SourceFedKind) async throws {
        var (rig, stage) = try await scene(kind)
        stage.tick()
        let draws = stage.probe.draws, taken = stage.surface.drawablesTaken
        stage.setPresented(false)
        #expect(!stage.isRunning, "the scheduler is paused although the session runs")
        // Data keeps arriving and the appearance changes: nothing is submitted to the GPU.
        await rig.send(4 ..< 9)
        stage.show(other(rig.content, value: 0.5))
        #expect(stage.clock.fire(60) == 0)
        #expect(stage.probe.draws == draws && stage.surface.drawablesTaken == taken, "0 draws while inactive")
        #expect(rig.host.session?.state == .running && stage.probe.attaches == 1, "the attachment is the view's, not the scene's: it stays")
        stage.setPresented(true)
        #expect(stage.isRunning)
        #expect(stage.tick())
        #expect(stage.probe.draws == draws + 1, "1 draw on return")
        #expect(stage.probe.uploadedColumns == 9 * rig.itemsPerBlock, "with everything that arrived meanwhile")
        #expect(stage.clock.fire(30) == 30 && stage.probe.draws == draws + 1)
        rig.leave()
    }
}
