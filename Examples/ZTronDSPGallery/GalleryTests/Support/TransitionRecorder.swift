import CoreFoundation
import MetalKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import ZTronDSP
@testable import ZTronDSPUI

/// Writes down, in order, how a hosted Metal view moves through a change of size: what its
/// layer says on every tick of the surface's display link; every drawable size the view
/// announces; every frame the view is asked for; every size an `Animatable` probe is handed;
/// for every frame of the display, what stands when the run loop goes to wait and the
/// transaction is about to be committed, which is what the frame on the display is made of;
/// and every transaction that was committed with bounds no frame had been drawn for.
///
/// This is the instrument of the spike WP-822 and of the acceptance WP-824. It reads; it
/// changes nothing the surface decides. Frames of the display are counted with a display
/// link of the recorder's own, so that a frame is seen whether the surface ticks in it or not.
///
/// The surface makes the frame of a size transition at the end of the run-loop turn, in an
/// observer ahead of Core Animation's commit (`RunLoopTurnEnd`, order 1 900 000). The
/// recorder looks between the two (order 1 999 000): what it reads is what the surface has
/// just made of the turn. It asks the layer how it is shown only there, where the surface has
/// asked a moment before; never on a tick, where nobody asks any more.
///
/// Threading: main actor.
@MainActor
final class TransitionRecorder {
    /// What the layer of the Metal view and the view say at one moment.
    struct Snapshot: Equatable {
        /// The layer's bounds, in points.
        var model: CGSize
        /// The bounds of its presentation layer, in points.
        var presentation: CGSize
        /// The keys of the animations the layer carries.
        var keys: [String]
        /// The size of the drawable, in pixels.
        var drawable: CGSize
        /// Whether the view resizes its drawable by itself.
        var autoResize: Bool
        /// Whether the layer presents with its transaction.
        var presentsWithTransaction: Bool
        /// Pixels per point as the layer says it: its `contentsScale`.
        var scale: CGFloat
        /// Pixels per point of the display the view is on.
        var displayScale: CGFloat
        /// The layers above the Metal layer that move: carry an animation, or are shown at
        /// another size than their own.
        var movingAncestors: [String]

        /// The size the layer is shown at, in whole pixels of the display.
        var presentationPixels: CGSize { LayerGeometry.pixels(presentation, scale: displayScale) }
        var modelPixels: CGSize { LayerGeometry.pixels(model, scale: displayScale) }
        /// How far the drawable is from the size the layer is shown at, in pixels of the
        /// display: the larger of the two differences.
        var mismatch: CGFloat {
            max(abs(drawable.width - presentation.width * displayScale), abs(drawable.height - presentation.height * displayScale))
        }
        /// True while the layer is on its way: it carries an animation, or is shown at a size
        /// that is not its own.
        var isMoving: Bool { !keys.isEmpty || presentationPixels != modelPixels }
    }

    /// What the surface saw and did on a tick of its own display link.
    struct SurfaceTick: Equatable {
        /// What stood when the tick began: what the surface reads.
        var before: Snapshot
        /// What stood when the surface had dealt with the tick.
        var after: Snapshot
    }

    /// One frame of the display: a turn of the run loop in which a display link fired.
    struct Frame {
        var index: Int
        /// The tick of the surface in this frame, when it ticked.
        var surface: SurfaceTick?
        /// What stood when the run loop went to wait: what the frame on the display is made of.
        var committed: Snapshot
        /// Whether the coordinator was in a size transition then.
        var inTransition: Bool
        /// Frames drawn, uploads and drawables taken by then.
        var draws: Int
        var uploads: Int
        var taken: Int
        /// How the layer was shown when the surface drew its frame of this turn, in points;
        /// `nil` when no frame was drawn in it.
        var shownWhenDrawn: CGSize?

        /// How far the drawable was from the size the layer was shown at when the surface
        /// drew the frame, in pixels: what the surface's rule made of the turn.
        var mismatchWhenDrawn: CGFloat {
            guard let shown = shownWhenDrawn else { return 0 }
            let scale = committed.displayScale
            return max(abs(committed.drawable.width - shown.width * scale), abs(committed.drawable.height - shown.height * scale))
        }

        /// True when the layer was shown more than a pixel further on when the transaction
        /// was committed than when the frame was drawn, a moment before in the same turn.
        /// Core Animation works out how an animated layer is shown for a time of its own
        /// choosing, and that time can move on between two readings of one turn: when the
        /// turn straddles a frame of the display because the main thread was held up, and,
        /// seen on iOS 18.6, for every frame that follows such a hold-up. A surface can size
        /// its drawable only for what the layer says when the frame is made, so such a frame
        /// is counted and judged by `mismatchWhenDrawn`, not by what the layer said later.
        var layerMovedOn: Bool {
            guard let shown = shownWhenDrawn else { return false }
            let scale = committed.displayScale
            return max(abs(committed.presentation.width - shown.width), abs(committed.presentation.height - shown.height)) * scale > 1
        }
    }

    private(set) var frames: [Frame] = []
    private(set) var lines: [String] = []
    /// Pixels per point of the display, read when the recorder was made.
    let displayScale: CGFloat
    /// Called when the view has been asked for a frame and the frame is drawn: the drawable
    /// is still the view's current one.
    var onFrameDrawn: (@MainActor (MTKView) -> Void)?
    /// Transactions that were committed while the layer rested at a size no frame had been
    /// drawn for: the picture of another size was stretched over the layer until the next
    /// frame was presented. Each is written down with how long that took.
    private(set) var commitsWithoutAFrame = 0
    /// The longest time, in seconds, from such a commit to the end of the turn in which the
    /// frame for the bounds was drawn.
    private(set) var longestWithoutAFrame: CFTimeInterval = 0

    private let watch: Watch
    private let view: MTKView
    private let layer: CAMetalLayer
    private let coordinator: SurfaceCoordinator
    private let display = DisplayLinkClock()
    private let start = CACurrentMediaTime()
    private var pendingBefore: (snapshot: Snapshot, schedulerFrames: Int, schedulerTicks: Int)?
    /// The time the surface's clock gave the last tick that reached the surface.
    private var handledTickTime: CFTimeInterval?
    private var surfaceTick: SurfaceTick?
    /// How the layer was shown when it was last asked, at the end of a frame.
    private var lastShown: CGSize?
    /// How the layer was shown when the frame of the current turn was drawn.
    private var shownWhenDrawn: CGSize?
    private var displayTicked = false
    private var observer: CFRunLoopObserver?
    private var afterCommit: CFRunLoopObserver?
    /// When a transaction was committed with bounds no frame was drawn for, until one is.
    private var withoutAFrameSince: CFTimeInterval?

    /// Starts recording the one Metal view under `watch`.
    init(_ watch: Watch) throws {
        self.watch = watch
        let tap = try #require(watch.tap, "the watch has found its Metal view")
        view = tap.view
        layer = try #require(view.layer as? CAMetalLayer, "a Metal view has a Metal layer")
        coordinator = tap.coordinator
        displayScale = view.window?.screen.scale ?? view.contentScaleFactor
        tap.onSizeChange = { [weak self] size in self?.note("view.drawableSizeWillChange size=\(Self.text(size))") }
        tap.onFrame = { [weak self] view, done in
            guard let self else { return }
            note(done ? "view.draw.end draws=\(watch.probe.draws)" : "view.draw.begin drawable=\(Self.text(view.drawableSize))")
            if done {
                onFrameDrawn?(view)
            } else {
                // The surface has asked the layer how it is shown a moment ago, to size this
                // frame: asking again gives the same answer.
                shownWhenDrawn = isAnimated ? layer.presentation()?.bounds.size ?? layer.bounds.size : layer.bounds.size
            }
        }
        watch.onTick = { [weak self] done in self?.clockTicked(done: done) }
        display.onTick = { [weak self] _ in self?.displayTicked = true }
        display.isPaused = false
        // Just before Core Animation commits the transaction, which its observer does at
        // order 2 000 000, and after the surface has made its frame of the turn: what is
        // read here is what goes to the display.
        let created = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnEnded() }
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        // And just after the commit: UIKit lays views out while the transaction is being
        // committed, so bounds can move after every observer that comes before the commit.
        // Only the layer's own bounds are read here, never how it is shown: the first
        // reading of a presentation layer after a commit fixes the time of every later one
        // until the next commit (`wp822-presentation-clock.log`).
        let after = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.committed() }
        }
        afterCommit = after
        CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
        note("recorder.start displayScale=\(Self.text(displayScale)) " + Self.text(snapshot()))
    }

    /// Stops recording and takes the recorder's hands off the view.
    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        if let afterCommit { CFRunLoopRemoveObserver(CFRunLoopGetMain(), afterCommit, .commonModes) }
        afterCommit = nil
        try? journal?.close()
        journal = nil
        display.isPaused = true
        display.invalidate()
        watch.onTick = nil
        watch.tap?.onSizeChange = nil
        watch.tap?.onFrame = nil
    }

    /// Adds a line: its number, the seconds since the recorder was made, and `text`.
    func note(_ text: String) {
        let line = String(format: "%05d %8.4f ", lines.count, CACurrentMediaTime() - start) + text
        lines.append(line)
        if let journal { try? journal.write(contentsOf: Data((line + "\n").utf8)) }
    }

    private var journal: FileHandle?

    /// Writes every line into `<name>.log` in the application's Documents folder as it is
    /// recorded, so that the log is there even when the application does not live to save it.
    func keepJournal(as name: String) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = folder.appendingPathComponent(name + ".log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        journal = try? FileHandle(forWritingTo: url)
        _ = try? journal?.seekToEnd()
    }

    /// What the layer and the view say now. With `asksPresentation` off, the layer is not
    /// asked how it is shown: a layer without an animation is shown at its own size, and an
    /// animated one is taken to be shown as it last said at the end of a frame.
    func snapshot(asksPresentation: Bool = true) -> Snapshot {
        let model = layer.bounds.size
        let keys = layer.animationKeys() ?? []
        let shown: CGSize
        if asksPresentation {
            shown = layer.presentation()?.bounds.size ?? model
            lastShown = shown
        } else {
            shown = keys.isEmpty ? model : lastShown ?? model
        }
        var moving: [String] = []
        var above = layer.superlayer
        while let ancestor = above {
            let ancestorKeys = ancestor.animationKeys() ?? []
            if !ancestorKeys.isEmpty {
                // The view that owns the layer, without its generic arguments.
                let owner = (ancestor.delegate).map { String(describing: type(of: $0)) } ?? "CALayer"
                let name = owner.split(separator: "<").first.map(String.init) ?? owner
                moving.append("\(name)[\(ancestorKeys.joined(separator: "+"))] own=\(Self.text(ancestor.bounds.size))")
            }
            above = ancestor.superlayer
        }
        return Snapshot(
            model: model, presentation: shown, keys: keys,
            drawable: view.drawableSize, autoResize: view.autoResizeDrawable, presentsWithTransaction: layer.presentsWithTransaction,
            scale: layer.contentsScale, displayScale: displayScale, movingAncestors: moving)
    }

    /// True while the layer carries an animation. Asks nothing about how it is shown.
    var isAnimated: Bool {
        !(layer.animationKeys() ?? []).isEmpty
    }

    private func clockTicked(done: Bool) {
        let schedulerFrames = coordinator.scheduler.frames
        let schedulerTicks = coordinator.scheduler.ticks
        guard done else {
            // Nobody asks the layer how it is shown on a tick: the surface asks at the end of
            // the turn, and the recorder after it.
            pendingBefore = (snapshot(asksPresentation: false), schedulerFrames, schedulerTicks)
            return
        }
        // The axes tick on clocks of their own: only a frame of the surface counts.
        guard let begun = pendingBefore else { return }
        guard schedulerFrames != begun.schedulerFrames else {
            // The surface's own clock ticked and its scheduler kept the tick from the
            // surface: the frame-rate cap, or a scene that is not active.
            if schedulerTicks != begun.schedulerTicks {
                pendingBefore = nil
                let since = handledTickTime.map { String(format: "%.1f ms", (watch.tickTime - $0) * 1_000) } ?? "an unknown time"
                note("surface.tick passed by: the scheduler was ticked and did not call the surface; by the clock's own time this tick came \(since) after the last one that reached it")
            }
            return
        }
        pendingBefore = nil
        handledTickTime = watch.tickTime
        let tick = SurfaceTick(before: begun.snapshot, after: snapshot(asksPresentation: false))
        surfaceTick = tick
        note("surface.tick begin " + Self.text(tick.before))
        note("surface.tick end   " + Self.text(tick.after) + " inTransition=\(coordinator.isInSizeTransition ? 1 : 0) draws=\(watch.probe.draws)")
    }

    private func turnEnded() {
        guard displayTicked || surfaceTick != nil else { return }
        let frame = Frame(index: frames.count, surface: surfaceTick, committed: snapshot(), inTransition: coordinator.isInSizeTransition,
                          draws: watch.probe.draws, uploads: watch.probe.uploads, taken: watch.taken, shownWhenDrawn: shownWhenDrawn)
        displayTicked = false
        surfaceTick = nil
        shownWhenDrawn = nil
        frames.append(frame)
        note("frame \(frame.index) end " + Self.text(frame.committed)
            + String(format: " mismatch=%.2f", Double(frame.committed.mismatch)) + " inTransition=\(frame.inTransition ? 1 : 0) draws=\(frame.draws) uploads=\(frame.uploads)"
            + " ticks=\(coordinator.scheduler.ticks) handled=\(coordinator.scheduler.frames)"
            + (frame.shownWhenDrawn == nil ? "" : String(format: " whenDrawn=%.2f", Double(frame.mismatchWhenDrawn)))
            + (frame.layerMovedOn ? " movedOn=1" : ""))
    }

    /// The transaction of this pass has been committed. Where the layer rests at a size that
    /// the last frame was not drawn at, the display now shows that frame stretched, until the
    /// frame for the bounds is presented: written down with the time it took.
    private func committed() {
        guard isAnimated == false, let drawn = coordinator.drawnSize else { return }
        let wanted = LayerGeometry.pixels(layer.bounds.size, scale: displayScale)
        let isBehind = abs(wanted.width - drawn.width) > 1 || abs(wanted.height - drawn.height) > 1
        let now = CACurrentMediaTime()
        if isBehind {
            guard withoutAFrameSince == nil else { return }
            withoutAFrameSince = now
            commitsWithoutAFrame += 1
            note("commit.without-a-frame model=\(Self.text(layer.bounds.size)) wanted=\(Self.text(wanted)) drawn=\(Self.text(drawn))")
        } else if let since = withoutAFrameSince {
            withoutAFrameSince = nil
            longestWithoutAFrame = max(longestWithoutAFrame, now - since)
            note(String(format: "commit.with-its-frame %.1f ms after the commit without one", (now - since) * 1_000))
        }
    }

    /// Writes the lines recorded so far into the application's Documents folder as
    /// `<name>.log`, from where `gallery.sh logs` copies them.
    func save(as name: String) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
    }

    // MARK: Text

    static func text(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }

    static func text(_ size: CGSize) -> String {
        String(format: "(%.2f,%.2f)", Double(size.width), Double(size.height))
    }

    static func text(_ snapshot: Snapshot) -> String {
        var text = "model=\(text(snapshot.model)) shown=\(text(snapshot.presentation)) keys=[\(snapshot.keys.joined(separator: "+"))]"
            + " drawable=\(text(snapshot.drawable)) scale=\(text(snapshot.scale))"
            + " auto=\(snapshot.autoResize ? 1 : 0) withTransaction=\(snapshot.presentsWithTransaction ? 1 : 0)"
        if !snapshot.movingAncestors.isEmpty { text += " above={" + snapshot.movingAncestors.joined(separator: "; ") + "}" }
        return text
    }
}

/// An `Animatable` view that is handed a size, built as the size probe of `ZTronDSPUI` is
/// (`SurfaceHost` inside the `GeometryReader` of `SurfaceFrame`): it tells the recorder every
/// size its body is evaluated with and every size SwiftUI sets through its animatable data.
struct SizeTap: View, Animatable {
    var size: CGSize
    let recorder: Box<TransitionRecorder?>

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set {
            size = CGSize(width: newValue.first, height: newValue.second)
            let size = size, recorder = recorder
            MainActor.assumeIsolated { recorder.value?.note("probe.set size=\(TransitionRecorder.text(size))") }
        }
    }

    var body: some View {
        let _ = recorder.value?.note("probe.body size=\(TransitionRecorder.text(size))")
        Color.clear
    }
}

extension View {
    /// Lays a size probe behind this view: it is offered the size this view is offered.
    func sizeTapped(by recorder: Box<TransitionRecorder?>) -> some View {
        background(GeometryReader { proxy in SizeTap(size: proxy.size, recorder: recorder) })
    }
}
