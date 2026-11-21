import MetalKit
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPGallery
@testable import ZTronDSPUI

extension InApp {
    /// WP-810: every example of the gallery launches and runs on a mock source. Each screen is
    /// opened in the application's own scene, as a tap on its row opens it, and every Metal
    /// surface on it is seen to draw what the mock source delivers.
    @MainActor
    @Suite("The gallery's screens (WP-810)")
    struct ScreenTests {
        /// The Metal surfaces a screen shows.
        static func surfaces(of example: Example) -> Int {
            switch example {
            case .waveform, .appearance, .pinch, .sizeChange, .activation: 2
            case .sourceFed: 4
            default: 1
            }
        }

        private func metalViews(of scene: UIWindowScene) -> [MTKView] {
            scene.windows.flatMap { MetalViews.all(in: $0) }
        }

        @Test func theApplicationIsTheGallery() async throws {
            let scene = try await AppScene.active()
            #expect(Bundle.main.bundleIdentifier == "com.zombietron.ztrondsp.gallery", "the tests run inside the application")
            #expect(GalleryPilot.shared.scenePhase == .active, "a view of the application's own scene reads an active phase")
            #expect(metalViews(of: scene).allSatisfy { !MetalViews.isShown($0) }, "the list shows no component")
            #expect(Example.components.count == 11)
        }

        @Test(arguments: Example.components)
        func theScreenRunsOnItsMockSourceAndEveryComponentDraws(example: Example) async throws {
            let scene = try await AppScene.active()
            let pilot = GalleryPilot.shared
            // What an earlier screen may have left behind does not count for this one.
            let before = Set(metalViews(of: scene).map(ObjectIdentifier.init))
            func opened() -> [MTKView] { metalViews(of: scene).filter { !before.contains(ObjectIdentifier($0)) } }
            pilot.open(example)

            // Every component on the screen makes one Metal view and draws.
            let surfaces = Self.surfaces(of: example)
            #expect(await eventually { opened().count == surfaces }, "\(opened().count) Metal views, not \(surfaces)")
            let views = opened()
            let coordinators = views.compactMap { MetalViews.coordinator(of: $0) }
            #expect(coordinators.count == surfaces && views.allSatisfy { MetalViews.isShown($0) })
            #expect(await eventually { coordinators.allSatisfy { $0.probe.draws >= 1 } }, "every surface drew: \(coordinators.map(\.probe.draws))")
            // The screen's pipeline runs on its mock source: what the source delivers arrives
            // in every picture. A tempogram shows its first column once it holds a whole
            // window of the novelty curve; a recording may be there, whole, at the first draw.
            #expect(await eventually { coordinators.allSatisfy { $0.probe.uploadedColumns >= 1 } },
                    "every surface drew data: columns \(coordinators.map(\.probe.uploadedColumns)), draws \(coordinators.map(\.probe.draws))")
            #expect(coordinators.allSatisfy { $0.probe.drawCalls >= 1 && $0.probe.uploads >= 1 })
            #expect(coordinators.allSatisfy { $0.failure == nil && $0.probe.makes == 1 })
            let feeds = coordinators.map(\.content.feed)
            // The overview of a recording ends when the recording does; every other feed stays live.
            #expect(await eventually { feeds.filter(\.isLive).count == (example == .waveform ? 1 : surfaces) }, "the sessions run")

            // Back to the list: the pipelines are detached, and the surfaces tick no more. The
            // screen is closed only when the navigation has settled from opening it: on iOS
            // 17.5 a path that is changed while the push is still under way is not followed,
            // and the screen stays.
            await displayFrames(60)
            pilot.open(nil)
            #expect(await eventually { feeds.allSatisfy { !$0.isLive } }, "the screen's sessions ended with it")
            #expect(await eventually { coordinators.allSatisfy { !$0.scheduler.isRunning } }, "and its surfaces tick no more")
            // SwiftUI takes the Metal views away: at once, or when it next rebuilds the
            // navigation. No component is left where a person could see it.
            #expect(await eventually { metalViews(of: scene).allSatisfy { !MetalViews.isShown($0) } }, "no component is left on the screen")
            // The navigation settles before the next screen is opened.
            await displayFrames(60)
        }
    }

    /// What a component is told in the other places of an application built with SwiftUI.
    @MainActor
    @Suite("A component in a sheet of the application's scene")
    struct SheetTests {
        /// A screen of the gallery in a sheet over the list: the content of a sheet is hosted
        /// by SwiftUI itself, in a controller of its own.
        @Test func aComponentInASheetIsToldThePhaseOfItsSceneAndDraws() async throws {
            let scene = try await AppScene.active()
            let pilot = GalleryPilot.shared
            let before = Set(scene.windows.flatMap { MetalViews.all(in: $0) }.map(ObjectIdentifier.init))
            func metalViews() -> [MTKView] {
                scene.windows.flatMap { MetalViews.all(in: $0) }.filter { !before.contains(ObjectIdentifier($0)) && MetalViews.isShown($0) }
            }
            #expect(metalViews().isEmpty)
            pilot.present(.spectrogram)
            #expect(await eventually { metalViews().count == 1 }, "the sheet shows its component")
            let coordinator = try #require(metalViews().first.flatMap { MetalViews.coordinator(of: $0) })
            let drew = await eventually(timeout: 60) { coordinator.probe.draws >= 1 && coordinator.probe.uploadedColumns >= 1 }
            print("ZTD sheet: draws=\(coordinator.probe.draws) columns=\(coordinator.probe.uploadedColumns) toldActive=\(coordinator.scheduler.isSceneActive)")
            // The content of a sheet is hosted by SwiftUI in a controller of its own, and is
            // told the phase of the scene all the same: it draws, and has nothing to say.
            #expect(drew, "the component in the sheet drew what its mock source delivers")
            #expect(coordinator.scheduler.isSceneActive && coordinator.phaseNotices == 0)
            pilot.present(nil)
            #expect(await eventually { metalViews().isEmpty }, "the sheet is gone, and its Metal view with it")
            await displayFrames(60)
        }
    }

    /// What a component is told when it is hosted in a `UIHostingController`, as a hosted test
    /// and an application built with UIKit host it.
    @MainActor
    @Suite("A component in a hosting controller")
    struct HostingControllerTests {
        /// Reads the scene phase and writes it down.
        struct PhaseReader: View {
            let seen: Box<[ScenePhase]>
            @Environment(\.scenePhase) private var scenePhase

            var body: some View {
                let _ = seen.value.append(scenePhase)
                Color.clear
            }
        }

        /// What the documentation of the components says of a host that is not a SwiftUI
        /// scene (§8.3, `HeatmapView`): SwiftUI hands the scene phase to the scenes of an
        /// `App` only, so a view in a `UIHostingController` reads `.background`, although its
        /// window belongs to the scene in the foreground and the application is active. The
        /// component makes its Metal view and draws nothing; and once its feed is live it
        /// says so, once, in the log.
        @Test func aComponentInAHostingControllerThatIsToldNoPhaseDrawsNothingAndSaysSoOnce() async throws {
            let scene = try await AppScene.active()
            let live = try await LiveFeed(.heatmap)
            let probe = RenderProbe(), seen = Box<[ScenePhase]>([])
            let hosted = Hosted(in: scene, ZStack {
                PhaseReader(seen: seen)
                HeatmapView(feed: live.heatmap)
            }
            .environment(\.dspRenderProbe, probe))
            defer { hosted.close() }
            #expect(await eventually { probe.makes == 1 }, "the Metal view is made")
            let view = try #require(MetalViews.all(in: hosted.window).first), coordinator = try #require(MetalViews.coordinator(of: view))
            await displayFrames(10)
            #expect(scene.activationState == .foregroundActive && GalleryPilot.shared.scenePhase == .active, "the scene of the window is active")
            #expect(seen.value.last == .background, "and the view in the hosting controller reads: \(seen.value)")
            #expect(coordinator.phaseNotices == 0, "nothing is said while the feed is not live")
            try await live.start()
            await live.send(0 ..< 4)
            await displayFrames(20)
            #expect(coordinator.phaseNotices == 1, "said once the feed is live")
            #expect(probe.draws == 0 && !coordinator.scheduler.isRunning, "the component draws nothing, and its display link does not run")
            // Once: not again when the feed stops and starts.
            await live.setBranchActive(false)
            await live.setBranchActive(true)
            await live.send(4 ..< 6)
            await displayFrames(10)
            #expect(coordinator.phaseNotices == 1 && probe.draws == 0)
            await live.stop()
        }

        /// The same component draws at once when the host hands the phase of its scene down
        /// with `.environment(\.scenePhase, …)`, as the documentation asks of it, and it has
        /// nothing to say in the log.
        @Test func givenThePhaseOfItsSceneTheComponentDrawsAndSaysNothing() async throws {
            let scene = try await AppScene.active()
            let live = try await LiveFeed(.heatmap)
            try await live.start()
            await live.send(0 ..< 6)
            let probe = RenderProbe(), seen = Box<[ScenePhase]>([])
            let hosted = Hosted(in: scene, ZStack {
                PhaseReader(seen: seen)
                HeatmapView(feed: live.heatmap)
            }
            .environment(\.dspRenderProbe, probe)
            .environment(\.scenePhase, .active))
            defer { hosted.close() }
            #expect(await eventually { probe.draws >= 1 && probe.uploadedColumns == 6 }, "the component drew what its feed holds")
            let view = try #require(MetalViews.all(in: hosted.window).first), coordinator = try #require(MetalViews.coordinator(of: view))
            #expect(seen.value.last == .active && coordinator.phaseNotices == 0)
            await live.stop()
        }

        /// And through `Stateful`, which hands its content the phase the application's own
        /// scene reads, as every other hosted test does.
        @Test func givenThePhaseTheApplicationReadsTheComponentDraws() async throws {
            let scene = try await AppScene.active()
            let feed = HeatmapFeed(history: 64)
            try FeedWriter.append(FeedWriter.columns(0 ..< 6, rows: 16), rows: 16, to: feed)
            let probe = RenderProbe(), handle = StateHandle<Int>()
            let hosted = Hosted(in: scene, Stateful(0, handle) { _ in
                SpectrogramView(feed: feed).environment(\.dspRenderProbe, probe)
            })
            defer { hosted.close() }
            #expect(await eventually { probe.draws >= 1 }, "the component drew")
            #expect(handle.phase == .active && probe.uploadedColumns == 6)
        }
    }
}
