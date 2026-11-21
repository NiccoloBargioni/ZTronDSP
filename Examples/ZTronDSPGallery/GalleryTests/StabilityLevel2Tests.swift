import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPUI

extension InApp {
    /// The stability suite, level 2 (WP-809b): every scenario of the table in §8.4, through
    /// real SwiftUI hosting in the gallery. The component is in a window of the application's
    /// scene; SwiftUI evaluates bodies, animates and lays out; the bridge makes a real Metal
    /// view that hands out real drawables; the surface ticks on the display link, at the
    /// display's rate. What is asserted are the counters of the `RenderProbe` and of the
    /// other probes, per frame of the display where the table speaks of frames. Nothing is
    /// asserted on the wall clock.
    ///
    /// Each scenario runs for the heat map and for the waveform, as at level 1
    /// (`Tests/ZTronDSPUITests/StabilityTests.swift`).
    @MainActor
    @Suite("Stability contract, level 2 (WP-809b)")
    struct StabilityTests {
        /// A live feed with `blocks` blocks in it.
        private func feed(_ kind: SurfaceKind, blocks: Int = 4, live: Bool = true) async throws -> LiveFeed {
            let feed = try await LiveFeed(kind)
            try await feed.start()
            if blocks > 0 { await feed.send(0 ..< blocks) }
            if !live { await feed.stop() }
            return feed
        }

        /// The pipeline that writes a feed of `kind`: what a view hosts with `.pipeline(_:on:)`.
        private static func writer(_ kind: SurfaceKind, heatmap: HeatmapFeed, waveform: WaveformFeed) -> Pipeline<Samples, Samples> {
            switch kind {
            case .heatmap:
                Pipeline<Samples, Samples>().tap { $0.appending(TestColumns(rows: 16, axis: .indices(count: 16), hop: 16)).emit(to: heatmap) }
            case .waveform:
                Pipeline<Samples, Samples>().tap { $0.appending(TestPairs(pairsPerBlock: 8)).emit(to: waveform) }
            }
        }

        // MARK: Scenario 1

        /// Parent re-evaluates its body 100 times with equal inputs: 0 renderer updates, 0
        /// draws, 0 new attachments. The view hosts the pipeline that writes its feed, so the
        /// attachment that must not be repeated is a real one.
        @Test(arguments: SurfaceKind.allCases)
        func aParentThatEvaluatesItsBodyAHundredTimesChangesNothing(kind: SurfaceKind) async throws {
            let engine = DSPEngine(blockSize: 16), source = HandFedSource()
            let heatmap = HeatmapFeed(history: 256), waveform = WaveformFeed(history: 256)
            let watch = Watch(), handle = StateHandle<Int>(), evaluations = Box(0)
            let hosted = try await hostWatched(0, handle, watch: watch) { counter in
                let _ = evaluations.value += 1
                VStack(spacing: 0) {
                    Text("\(counter.wrappedValue)")
                    // Everything below is made anew by every evaluation: equal values, not the same ones.
                    Shown(kind, heatmap: heatmap, waveform: waveform)
                        .axis(.time)
                        .pipeline(Self.writer(kind, heatmap: heatmap, waveform: waveform), on: source)
                }
                .dspEngine(engine)
            }
            defer { hosted.close() }
            let isLive = { kind == .heatmap ? heatmap.isLive : waveform.isLive }
            let generation = { kind == .heatmap ? heatmap.generation : waveform.generation }
            #expect(await eventually { watch.hosts.attaches == 1 && isLive() }, "the view attached its pipeline: \(watch.hosts.failures)")
            // Four blocks arrive and are drawn.
            let values = FeedWriter.columns(0 ..< 4, rows: 16)
            #expect(source.write(values) == values.count)
            #expect(await eventually { generation() >= 4 })
            #expect(await eventually { watch.probe.uploadedColumns == 4 * (kind == .heatmap ? 1 : 8) })
            #expect(await eventually { watch.axes.draws >= 1 }, "the time axis is drawn")
            await displayFrames(6)

            let before = watch.now, axisDraws = watch.axes.draws, evaluated = evaluations.value
            for step in 1 ... 100 {
                let seen = evaluations.value
                handle.set(step)
                #expect(await eventually { evaluations.value > seen }, "evaluation \(step)")
            }
            await displayFrames(6)
            #expect(handle.value == 100 && evaluations.value - evaluated >= 100, "the parent's body ran a hundred times")
            #expect(watch.probe.updates == 0, "0 renderer updates: updateUIView returned at the comparison every time (V-3)")
            #expect(watch.now == before, "0 draws, and no drawable taken: \(watch.now) after \(before)")
            #expect(watch.probe.makes == 1, "one Metal view")
            #expect(watch.probe.attaches == 1 && watch.hosts.attaches == 1 && watch.hosts.detaches == 0, "0 new attachments")
            #expect(watch.hosts.updates.isEmpty, "an equal pipeline is no update of the session")
            #expect(watch.axes.draws == axisDraws, "and the axis was not drawn again")
            #expect(try watch.scheduler.isRunning && isLive(), "all the while the feed was live")
        }

        // MARK: Scenario 2

        /// Session running, no new data for one second: 0 draws; each tick returns after one
        /// atomic load, which is seen here as a tick that takes no drawable.
        @Test(arguments: SurfaceKind.allCases)
        func aRunningSessionWithoutNewDataDrawsNothing(kind: SurfaceKind) async throws {
            let live = try await feed(kind)
            let watch = Watch(), handle = StateHandle<Int>()
            let hosted = try await hostWatched(0, handle, watch: watch) { _ in Shown(live) }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(live.isLive && scheduler.isRunning, "a live feed keeps the display link running")
            let before = watch.now, ticks = scheduler.ticks, frames = watch.frames.count
            // One second of the display: sixty ticks of the surface's own link.
            #expect(await eventually { scheduler.ticks >= ticks + 60 }, "the link ticks: \(scheduler.ticks - ticks) ticks")
            // Not every tick has to: the frame-rate cap passes a tick by when the display link
            // gives it a time less than a frame after the one before, which the link of a busy
            // simulator does now and then (58 of 60 were seen under load).
            #expect(watch.frames.count - frames >= 45, "and the ticks reach the surface: \(watch.frames.count - frames) of \(scheduler.ticks - ticks)")
            #expect(watch.probe.draws == before.draws, "no draw without a cause (V-4)")
            #expect(watch.taken == before.taken, "no tick took a drawable")
            #expect(watch.probe.uploads == before.uploads)
            #expect(try watch.coordinator.renderer?.pendingCauses.isEmpty == true)
            await live.stop()
        }

        // MARK: Scenario 3

        /// Session stopped, or the branch suspended: display link paused; 0 wake-ups.
        @Test(arguments: SurfaceKind.allCases)
        func aStoppedSessionOrASuspendedBranchPausesTheDisplayLink(kind: SurfaceKind) async throws {
            let live = try await feed(kind)
            let watch = Watch(), handle = StateHandle<Int>()
            let hosted = try await hostWatched(0, handle, watch: watch) { _ in Shown(live) }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(scheduler.isRunning)

            // The branch is suspended (ACT-11).
            await live.setBranchActive(false)
            #expect(await eventually { !scheduler.isRunning }, "the link pauses")
            var ticks = scheduler.ticks
            let draws = watch.probe.draws
            await displayFrames(60)
            #expect(scheduler.ticks == ticks && !scheduler.isRunning, "0 wake-ups in a second of the display")

            // It resumes: the link runs again.
            await live.setBranchActive(true)
            #expect(await eventually { scheduler.isRunning })
            #expect(await eventually { scheduler.ticks >= ticks + 10 }, "and ticks")

            // The session is stopped.
            await live.stop()
            #expect(await eventually { !scheduler.isRunning }, "the link pauses")
            ticks = scheduler.ticks
            await displayFrames(60)
            #expect(scheduler.ticks == ticks && !scheduler.isRunning, "0 wake-ups in a second of the display")
            #expect(watch.probe.draws == draws, "nothing was drawn meanwhile: there was nothing new")
        }

        // MARK: Scenario 4

        /// Data arriving at twice the display rate for one second: draws ≤ display ticks; every
        /// column present in the texture.
        @Test(arguments: SurfaceKind.allCases)
        func dataAtTwiceTheDisplayRateIsAtMostOneDrawPerFrameAndNothingIsLost(kind: SurfaceKind) async throws {
            let live = try await feed(kind, blocks: 0)
            let watch = Watch(), handle = StateHandle<Int>()
            let hosted = try await hostWatched(0, handle, watch: watch) { _ in Shown(live) }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            let before = watch.now, frames = watch.frames.count
            // Two blocks with every frame of the display, for sixty frames.
            let display = DisplayTicks(), sent = Box(0)
            display.onTick = { _ in
                guard sent.value < 60 else { return }
                live.write(2 * sent.value ..< 2 * sent.value + 2)
                sent.value += 1
            }
            #expect(await eventually { sent.value == 60 })
            display.stop()
            let columns = 120 * live.itemsPerBlock
            #expect(await eventually { watch.probe.uploadedColumns == columns }, "every column went up: \(watch.probe.uploadedColumns) of \(columns)")
            await displayFrames(4)
            let during = Array(watch.frames[frames...])
            let drawn = watch.probe.draws - before.draws
            #expect(drawn >= 1 && drawn <= during.count, "draws ≤ display ticks: \(drawn) draws in \(during.count) frames")
            var previous = before
            for frame in during {
                #expect(frame.draws - previous.draws <= 1 && frame.uploads - previous.uploads <= 1, "at most one draw, in one pass, per frame")
                previous = frame
            }
            #expect(watch.probe.uploadedColumns == columns, "each column once")
            #expect(watch.probe.uploads <= watch.probe.draws, "an upload is part of a draw")
            #expect(watch.probe.drawCalls == watch.probe.draws, "one draw call per frame (V-5)")
            #expect(watch.probe.allocations == 1 && watch.probe.clears == 0, "the texture was allocated once (V-6)")
            #expect(scheduler.isRunning)
            await live.stop()
        }

        // MARK: Scenario 5

        /// Colour map changed: exactly 1 draw, 0 column uploads.
        @Test func aChangedColourMapIsExactlyOneDrawAndNoUpload() async throws {
            let live = try await feed(.heatmap, live: false)
            let watch = Watch(), handle = StateHandle<Bool>()
            let hosted = try await hostWatched(false, handle, watch: watch) { magma in
                HeatmapView(feed: live.heatmap).colorMap(magma.wrappedValue ? ListedColorMap.magma : ListedColorMap.viridis)
            }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(await eventually { !scheduler.isRunning }, "nothing to do: the link is paused")
            let before = watch.now, columns = watch.probe.uploadedColumns
            handle.set(true)
            #expect(await eventually { watch.probe.updates == 1 }, "the map reached the surface")
            #expect(await eventually { watch.probe.draws == before.draws + 1 })
            await displayFrames(6)
            #expect(watch.probe.draws == before.draws + 1 && watch.taken == before.taken + 1, "exactly one draw")
            #expect(watch.probe.uploads == before.uploads && watch.probe.uploadedColumns == columns, "nothing uploaded")
            #expect(watch.inspector.heatmap?.colorMap == AnyColorMap(ListedColorMap.magma))
            #expect(!scheduler.isRunning, "and the link is paused again")
        }

        // MARK: Scenario 6

        /// Value range animated over half a second: 1 draw per display frame, 0 uploads. The
        /// heat map animates its value range, the waveform its amplitude range.
        @Test(arguments: SurfaceKind.allCases)
        func anAnimatedRangeIsOneDrawPerDisplayFrameAndNoUpload(kind: SurfaceKind) async throws {
            let live = try await feed(kind, live: false)
            let watch = Watch(), handle = StateHandle<Float>()
            let hosted = try await hostWatched(Float(0), handle, watch: watch) { way in
                Shown(live)
                    .valueRange(-90 + 60 * way.wrappedValue ... 0)
                    .amplitudeRange(-1 ... 1 - 0.75 * way.wrappedValue)
            }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(await eventually { !scheduler.isRunning })
            let before = watch.now, columns = watch.probe.uploadedColumns, frames = watch.frames.count, shown = watch.inspector.contents.count
            await handle.animate(to: 1, .linear(duration: 0.5))
            #expect(await eventually { !scheduler.isRunning }, "the animation is over: the link pauses")
            await displayFrames(4)

            // What the renderer was shown: values on the way, each further than the one before.
            let values = watch.inspector.contents.dropFirst(shown).map { content -> Double in
                switch content {
                case .heatmap(_, let appearance): Double(appearance.valueRange.lowerBound + 90) / 60
                case .waveform(_, let appearance): Double(1 - appearance.amplitudeRange.upperBound) / 0.75
                }
            }
            #expect(values.count >= 2 && values.count == watch.probe.updates, "one update per value SwiftUI handed over: \(values.count)")
            #expect(abs((values.last ?? 0) - 1) < 1e-6 && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "interpolated, frame by frame: \(values)")

            // Frame by frame of the display: a frame with a new value is one draw, a frame
            // without one is none.
            var previous = before, framesWithValues = 0, missed = 0, uncaused = 0
            for frame in watch.frames[frames...] {
                let fresh = frame.updates - previous.updates, drawn = frame.draws - previous.draws
                #expect(drawn <= 1, "never two draws in one frame")
                if fresh > 0 { framesWithValues += 1 }
                if fresh > 0, drawn == 0 { missed += 1 }
                if fresh == 0, drawn > 0 { uncaused += 1 }
                previous = frame
            }
            let drawn = watch.probe.draws - before.draws
            #expect(framesWithValues >= 2, "SwiftUI handed the surface values on \(framesWithValues) frames")
            #expect(missed == 0 && uncaused == 0, "1 draw per display frame: \(missed) frames with a value and no draw, \(uncaused) draws without a value")
            #expect(drawn == framesWithValues, "\(drawn) draws for \(framesWithValues) frames with a new value")
            #expect(watch.probe.uploads == before.uploads && watch.probe.uploadedColumns == columns, "0 uploads")
            let after = watch.now
            await displayFrames(6)
            #expect(watch.now == after, "when the animation is over nothing is drawn any more")
        }

        // MARK: Scenario 7

        /// View resized without animation: 1 draw per changed size, 0 uploads.
        ///
        /// The frame for the new size is made at the end of the run-loop turn in which the
        /// view's bounds move, and presented with the transaction that carries them (SZ-2).
        /// Before that correction a hosted resize was two draws on iOS 18.6 and 27.0, the
        /// first at the old size (`Spikes/WP-822-findings.md`). The test prints what it
        /// counted.
        @Test(arguments: SurfaceKind.allCases)
        func aResizeWithoutAnimationIsOneDrawPerChangedSizeAndNoUpload(kind: SurfaceKind) async throws {
            let live = try await feed(kind, live: false)
            let watch = Watch(), handle = StateHandle<CGSize>()
            let hosted = try await hostWatched(CGSize(width: 120, height: 80), handle, watch: watch, size: CGSize(width: 300, height: 300)) { size in
                Shown(live).frame(width: size.wrappedValue.width, height: size.wrappedValue.height)
            }
            defer { hosted.close() }
            let scheduler = try watch.scheduler, view = try watch.view
            #expect(await eventually { !scheduler.isRunning })
            let scale = view.contentScaleFactor
            #expect(view.drawableSize == CGSize(width: 120 * scale, height: 80 * scale))
            let before = watch.now, allocations = watch.probe.allocations
            let sizes = [CGSize(width: 160, height: 80), CGSize(width: 160, height: 140), CGSize(width: 91, height: 57)]
            var counted: [Int] = []
            for (index, size) in sizes.enumerated() {
                handle.set(size)
                #expect(await eventually { watch.probe.draws > before.draws + index }, "the new size is drawn")
                #expect(await eventually { !scheduler.isRunning })
                await displayFrames(4)
                counted.append(watch.probe.draws - before.draws)
                #expect(watch.probe.draws == before.draws + index + 1, "one draw for \(size): \(watch.probe.draws - before.draws - index)")
                #expect(view.drawableSize == CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()), "at the new size: \(view.drawableSize)")
            }
            print("ZTD resize without animation, \(kind): draws after each of the three sizes \(counted)")
            #expect(watch.probe.uploads == before.uploads && watch.probe.allocations == allocations, "resizing uploads nothing and allocates no data texture (V-6)")
            #expect(watch.probe.updates == 0, "a size is not appearance")
            #expect(try !watch.coordinator.isInSizeTransition && !scheduler.isRunning)
        }

        // MARK: Scenario 8

        /// Feed replaced: texture cleared once, then normal operation.
        @Test(arguments: SurfaceKind.allCases)
        func aReplacedFeedClearsTheTextureOnceAndThenWorksAsBefore(kind: SurfaceKind) async throws {
            let first = try await feed(kind), second = try await feed(kind, blocks: 3)
            let items = first.itemsPerBlock
            let watch = Watch(), handle = StateHandle<Bool>()
            let hosted = try await hostWatched(false, handle, watch: watch) { other in
                Shown(kind, heatmap: other.wrappedValue ? second.heatmap : first.heatmap, waveform: other.wrappedValue ? second.waveform : first.waveform)
            }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(watch.probe.uploadedColumns == 4 * items)
            let draws = watch.probe.draws
            handle.set(true)
            #expect(await eventually { watch.probe.updates == 1 }, "the other feed reached the surface")
            #expect(await eventually { watch.probe.draws == draws + 1 })
            await displayFrames(4)
            #expect(watch.probe.clears == 1, "cleared once")
            #expect(watch.probe.draws == draws + 1 && watch.probe.allocations == 1 && watch.probe.makes == 1, "the texture and the view are kept: the shape is the same")
            #expect(watch.probe.uploadedColumns == (4 + 3) * items, "the new feed's columns went up")
            // Normal operation: new data of the new feed is drawn, the old feed's is not.
            await second.send(3 ..< 5)
            #expect(await eventually { watch.probe.uploadedColumns == (4 + 5) * items })
            #expect(await eventually { watch.probe.draws == draws + 2 })
            await first.send(4 ..< 6)
            await displayFrames(6)
            #expect(watch.probe.draws == draws + 2 && watch.probe.uploadedColumns == (4 + 5) * items, "the old feed does not reach the surface any more")
            #expect(watch.probe.clears == 1)
            // The surface follows the liveness of the feed it shows now.
            await first.stop()
            await displayFrames(4)
            #expect(scheduler.isRunning, "the new feed is still live")
            await second.stop()
            #expect(await eventually { !scheduler.isRunning })
        }

        // MARK: Scenario 9

        /// Scene inactive, then active: 0 draws while inactive; 1 draw on return. The phase
        /// the component reads is taken out of the application's hands here and set by the
        /// test, once to `.inactive` and once to `.background`; the test that follows lets
        /// the application really leave the foreground.
        @Test(arguments: SurfaceKind.allCases)
        func nothingIsDrawnWhileTheSceneIsInactiveAndOneFrameOnReturn(kind: SurfaceKind) async throws {
            let live = try await feed(kind)
            let watch = Watch(), handle = StateHandle<Float>()
            let hosted = try await hostWatched(Float(0), handle, watch: watch) { way in
                Shown(live)
                    .valueRange(-90 + 60 * way.wrappedValue ... 0)
                    .amplitudeRange(-1 ... 1 - 0.75 * way.wrappedValue)
            }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(handle.phase == .active && scheduler.isRunning, "the scene is active and the feed is live")
            var blocks = 4
            for (round, phase) in [ScenePhase.inactive, .background].enumerated() {
                let before = watch.now, updates = watch.probe.updates
                handle.forcePhase(phase)
                #expect(await eventually { !scheduler.isRunning }, "\(phase): the scheduler is paused although the feed is live")
                let ticks = scheduler.ticks
                // Data keeps arriving and the appearance changes: nothing is submitted to the GPU.
                await live.send(blocks ..< blocks + 5)
                blocks += 5
                handle.set(Float(round + 1) / 2)
                #expect(await eventually { watch.probe.updates == updates + 1 }, "the appearance reached the surface")
                await displayFrames(60)
                #expect(watch.probe.draws == before.draws && watch.taken == before.taken, "\(phase): 0 draws in a second of the display")
                #expect(scheduler.ticks == ticks && !scheduler.isRunning, "and no wake-up")
                handle.forcePhase(nil)
                #expect(await eventually { watch.probe.draws == before.draws + 1 }, "1 draw on return")
                #expect(watch.probe.uploadedColumns == blocks * live.itemsPerBlock, "with everything that arrived meanwhile")
                #expect(await eventually { scheduler.ticks >= ticks + 30 }, "the link runs again: the feed is live")
                #expect(watch.probe.draws == before.draws + 1 && watch.taken == before.taken + 1, "and nothing further is drawn: nothing new arrived")
            }
            await live.stop()
        }

        /// Scene inactive, then active, for real: the application leaves the foreground and
        /// comes back, and the component is told by the phase the application's own scene
        /// reads. A test cannot send its own application to the background and bring it back;
        /// `gallery.sh` does it from outside when the test asks (`Stagehand`). Without it the
        /// test does not run.
        @Test(.enabled(if: Stagehand.isPresent, "needs gallery.sh to bring another application to the front and the gallery back"))
        func nothingIsDrawnWhileTheApplicationIsInTheBackgroundAndOneFrameOnItsReturn() async throws {
            let live = try await feed(.heatmap)
            let watch = Watch(), handle = StateHandle<Int>()
            let hosted = try await hostWatched(0, handle, watch: watch) { _ in Shown(live) }
            defer { hosted.close() }
            let scheduler = try watch.scheduler
            #expect(handle.phase == .active && scheduler.isRunning, "the scene is active and the feed is live")
            // Beside it, a view in a hosting controller that nobody tells the phase: what does
            // it read while the application leaves and returns?
            let untold = Box<[ScenePhase]>([])
            let bare = Hosted(in: try await AppScene.active(), size: CGSize(width: 40, height: 40), InApp.HostingControllerTests.PhaseReader(seen: untold))
            defer { bare.close() }
            // The application may work on for a while when it is in the background.
            let task = UIApplication.shared.beginBackgroundTask(withName: "stability")
            defer { UIApplication.shared.endBackgroundTask(task) }
            let before = watch.now

            try Stagehand.ask("leave")
            #expect(await eventually(timeout: 600) { handle.phase == .background }, "the application left the foreground: \(handle.phases)")
            #expect(UIApplication.shared.applicationState == .background)
            #expect(await eventually { !scheduler.isRunning }, "the scheduler is paused although the feed is live")
            let ticks = scheduler.ticks
            // A display link of the test's own, which nothing pauses: does the display tick at
            // all for an application in the background?
            let display = DisplayTicks()
            defer { display.stop() }
            // Data keeps arriving: nothing is submitted to the GPU.
            await live.send(4 ..< 9)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await live.send(9 ..< 14)
            print("ZTD stagehand: a display link of its own ticked \(display.count) times while the application was in the background")
            #expect(watch.probe.draws == before.draws && watch.taken == before.taken, "0 draws while the application is in the background")
            #expect(scheduler.ticks == ticks, "and no wake-up")

            try Stagehand.ask("return")
            #expect(await eventually(timeout: 600) { handle.phase == .active }, "the application is in the foreground again: \(handle.phases)")
            #expect(await eventually { watch.probe.draws == before.draws + 1 }, "1 draw on return")
            #expect(watch.probe.uploadedColumns == 14 * live.itemsPerBlock, "with everything that arrived meanwhile")
            #expect(await eventually { scheduler.ticks >= ticks + 30 }, "the link runs again: the feed is live")
            #expect(watch.probe.draws == before.draws + 1 && watch.taken == before.taken + 1, "and nothing further is drawn: nothing new arrived")
            print("ZTD stagehand: phases \(handle.phases)")
            let read = untold.value.reduce(into: [ScenePhase]()) { phases, phase in if phases.last != phase { phases.append(phase) } }
            print("ZTD stagehand: a view in a hosting controller that is told nothing read \(read)")
            #expect(handle.phases.contains(.inactive), "on the way out and back the scene was inactive: \(handle.phases)")
            await live.stop()
        }
    }
}
