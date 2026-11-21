import MetalKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPUI

/// The display's own clock, a `DisplayLinkClock`, with the test listening in: it is told of
/// every tick before the surface hears of it and after the surface has dealt with it. The
/// surface under test ticks on the real display link, at the display's rate; the test only
/// reads what stands between two ticks.
@MainActor
final class TappedClock: FrameClock {
    private let link = DisplayLinkClock()
    /// What the scheduler sets: its own handler.
    var onTick: (@MainActor (CFTimeInterval) -> Void)?
    /// Called with the time of a tick before the scheduler's handler runs.
    var before: (@MainActor (CFTimeInterval) -> Void)?
    /// Called with the time of a tick after the scheduler's handler has run.
    var after: (@MainActor (CFTimeInterval) -> Void)?

    init() {
        link.onTick = { [weak self] time in
            guard let self else { return }
            before?(time)
            onTick?(time)
            after?(time)
        }
    }

    var isPaused: Bool {
        get { link.isPaused }
        set { link.isPaused = newValue }
    }

    var preferredRate: Int {
        get { link.preferredRate }
        set { link.preferredRate = newValue }
    }

    func invalidate() {
        link.invalidate()
    }
}

/// Everything a hosted test sees of one component: the counters of its surface, what the
/// surface was asked to show, its axes, the pipeline it hosts, the Metal view the bridge
/// made for it, and what stood after every frame of its display link.
@MainActor
final class Watch {
    /// The counters after one frame of the surface's display link: a tick that got past the
    /// frame-rate cap and reached the surface.
    struct Frame: Equatable {
        /// Updates that got past the comparison of V-3, so far.
        var updates: Int
        /// Frames drawn, so far.
        var draws: Int
        /// Uploads of columns, so far.
        var uploads: Int
        /// Times the Metal view was asked for a frame, which is when a drawable is taken.
        var taken: Int
    }

    let probe = RenderProbe()
    let inspector = SurfaceInspector()
    let axes = AxisProbe()
    let hosts = PipelineHostProbe()
    /// The tap on the Metal view, once the view is found.
    private(set) var tap: MetalViewTap?
    /// One entry per frame of the surface's display link since the tap was put on.
    private(set) var frames: [Frame] = []
    /// Called before and after every tick of a clock of the hierarchy, when a test wants to
    /// look for itself: `true` after the surface has dealt with the tick.
    var onTick: (@MainActor (Bool) -> Void)?
    /// The time the clock that ticked last gave its tick: a display link's `timestamp`.
    private(set) var tickTime: CFTimeInterval = 0

    private var clocks: [TappedClock] = []
    private var seenFrames = 0
    private(set) lazy var clockSource = ClockSource { [unowned self] in makeClock() }

    private func makeClock() -> any FrameClock {
        let clock = TappedClock()
        clock.before = { [weak self] time in
            self?.tickTime = time
            self?.onTick?(false)
        }
        clock.after = { [weak self] _ in self?.ticked() }
        clocks.append(clock)
        return clock
    }

    private func ticked() {
        defer { onTick?(true) }
        guard let tap else { return }
        // The axes tick on clocks of their own: only a frame of the surface counts.
        let now = tap.coordinator.scheduler.frames
        guard now != seenFrames else { return }
        seenFrames = now
        frames.append(Frame(updates: probe.updates, draws: probe.draws, uploads: probe.uploads, taken: tap.frames))
    }

    /// Puts a tap on the one Metal view of `hosted`.
    func attach<Content>(to hosted: Hosted<Content>) throws {
        let views = hosted.metalViews
        try #require(views.count == 1, "one component, one Metal view: \(views.count)")
        let tap = try #require(MetalViewTap(views[0]), "the view is one the bridge made")
        seenFrames = tap.coordinator.scheduler.frames
        self.tap = tap
    }

    /// The Metal view the bridge made.
    var view: MTKView {
        get throws { try #require(tap).view }
    }

    var coordinator: SurfaceCoordinator {
        get throws { try #require(tap).coordinator }
    }

    var scheduler: FrameScheduler {
        get throws { try coordinator.scheduler }
    }

    /// Times the Metal view was asked for a frame since the tap was put on: drawables taken.
    var taken: Int { tap?.frames ?? 0 }

    /// The counters as they stand now, in the shape of a frame's.
    var now: Frame {
        Frame(updates: probe.updates, draws: probe.draws, uploads: probe.uploads, taken: taken)
    }
}

extension View {
    /// Puts the probes of `watch` into the environment of the components inside this view,
    /// and gives their surfaces a display clock the watch listens to.
    func watched(by watch: Watch) -> some View {
        environment(\.dspRenderProbe, watch.probe)
            .environment(\.dspSurfaceInspector, watch.inspector)
            .environment(\.dspAxisProbe, watch.axes)
            .environment(\.dspPipelineHostProbe, watch.hosts)
            .environment(\.dspClockSource, watch.clockSource)
    }
}

/// Hosts `content` over a piece of state in a window of the application, with the probes of
/// `watch` in its environment, waits for the first frame of its one component, and puts the
/// tap on its Metal view.
@MainActor
func hostWatched<Value, Content: View>(
    _ initial: Value, _ handle: StateHandle<Value>, watch: Watch, size: CGSize = CGSize(width: 240, height: 160),
    @ViewBuilder content: @escaping (Binding<Value>) -> Content
) async throws -> Hosted<some View> {
    let scene = try await AppScene.active()
    let hosted = Hosted(in: scene, size: size, Stateful(initial, handle) { binding in content(binding).watched(by: watch) })
    #expect(await eventually { watch.probe.draws >= 1 }, "the surface drew its first frame into a real drawable")
    try watch.attach(to: hosted)
    // The first layout may be one more frame.
    await displayFrames(4)
    return hosted
}

/// The component under test: a heat map or a waveform.
struct Shown: View {
    let kind: SurfaceKind
    let heatmap: HeatmapFeed
    let waveform: WaveformFeed

    init(_ kind: SurfaceKind, heatmap: HeatmapFeed, waveform: WaveformFeed) {
        self.kind = kind
        self.heatmap = heatmap
        self.waveform = waveform
    }

    /// The component of a live feed's kind, on its feed.
    init(_ live: LiveFeed) {
        self.init(live.kind, heatmap: live.heatmap, waveform: live.waveform)
    }

    var body: some View {
        switch kind {
        case .heatmap: HeatmapView(feed: heatmap)
        case .waveform: WaveformView(feed: waveform)
        }
    }
}
