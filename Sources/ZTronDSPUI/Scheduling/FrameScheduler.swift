import Foundation
import QuartzCore

/// Decides when a Metal surface gets a display tick (§8.3).
///
/// The scheduler wraps a display clock and keeps it paused unless there is a reason to tick:
///
/// - the feed is **live** (its session runs and its branch is not suspended, ACT-11), or
/// - a **frame was requested**: the renderer's dirty set is not empty,
///
/// and never while the scene is not active. A paused clock wakes nobody, so a view whose
/// session is stopped costs nothing at all. The control side tells the scheduler when the
/// feed's liveness changes; the analysis thread never wakes the main thread.
///
/// On a tick the scheduler calls its handler once, at most `maximumFrameRate` times a
/// second. The handler asks the renderer whether a draw is due (one atomic load when there is
/// nothing to do) and says whether it still wants a frame; a request is good for one tick.
///
/// ```swift
/// let scheduler = FrameScheduler(clock: DisplayLinkClock())
/// scheduler.onFrame = { _ in renderer.needsDraw() ? draw() : false }
/// scheduler.setFeedLive(feed.isLive)
/// scheduler.requestFrame()            // something became dirty
/// ```
///
/// Threading: main actor. Nothing here allocates after creation.
@MainActor
final class FrameScheduler {
    private let clock: any FrameClock

    /// What a tick does. Returns whether another frame is wanted although nothing new was
    /// requested: a draw that could not be made yet, a size transition that goes on.
    var onFrame: (@MainActor (CFTimeInterval) -> Bool)?

    /// True while the feed is live.
    private(set) var isFeedLive = false
    /// True while the scene is active and the view is on screen.
    private(set) var isSceneActive = true
    /// True from a request until the tick that serves it.
    private(set) var isFrameRequested = false
    /// The most frames per second the handler is called for.
    private(set) var maximumFrameRate: Int
    /// The time of the last tick that reached the handler.
    private var lastFrame: CFTimeInterval?
    private var isInvalidated = false

    /// Ticks the clock delivered: the wake-ups of the main thread on this scheduler's account.
    private(set) var ticks = 0
    /// Ticks that reached the handler: those the frame-rate cap let through.
    private(set) var frames = 0

    /// - Parameter maximumFrameRate: the cap of `.maximumFrameRate`; values below 1 count as 1.
    init(clock: any FrameClock, maximumFrameRate: Int = 60) {
        self.clock = clock
        self.maximumFrameRate = max(maximumFrameRate, 1)
        clock.isPaused = true
        clock.preferredRate = self.maximumFrameRate
        clock.onTick = { [weak self] time in self?.tick(at: time) }
    }

    /// True while the clock ticks.
    var isRunning: Bool { !isInvalidated && !clock.isPaused }

    /// The feed became live, or stopped being live.
    func setFeedLive(_ live: Bool) {
        guard live != isFeedLive else { return }
        isFeedLive = live
        evaluate()
    }

    /// The scene became active or inactive, or the view came on or went off screen. While
    /// inactive the clock is paused whatever else holds, and a request waits.
    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        evaluate()
    }

    /// The dirty set is not empty: tick at least once more.
    func requestFrame() {
        guard !isFrameRequested else { return }
        isFrameRequested = true
        evaluate()
    }

    /// Changes the cap on frames per second.
    func setMaximumFrameRate(_ rate: Int) {
        let rate = max(rate, 1)
        guard rate != maximumFrameRate else { return }
        maximumFrameRate = rate
        clock.preferredRate = rate
    }

    /// Ends the scheduler: the clock never ticks again.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        clock.isPaused = true
        clock.onTick = nil
        clock.invalidate()
        onFrame = nil
    }

    private func evaluate() {
        guard !isInvalidated else { return }
        let run = isSceneActive && (isFeedLive || isFrameRequested)
        if clock.isPaused == run { clock.isPaused = !run }
    }

    /// The shortest time between two frames the cap allows, with a twentieth of slack for the
    /// clock's own jitter: a clock that ticks at the cap must not lose every other frame.
    private var minimumInterval: CFTimeInterval {
        0.95 / Double(maximumFrameRate)
    }

    private func tick(at time: CFTimeInterval) {
        guard !isInvalidated else { return }
        ticks += 1
        guard isSceneActive else {
            evaluate()
            return
        }
        // A clock faster than the cap: this tick is skipped, and what is pending waits for the next.
        if let lastFrame, time > lastFrame, time - lastFrame < minimumInterval { return }
        lastFrame = time
        frames += 1
        isFrameRequested = false
        if onFrame?(time) == true { isFrameRequested = true }
        evaluate()
    }
}
