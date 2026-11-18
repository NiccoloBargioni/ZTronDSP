import Foundation
import ZTronDSPCore

/// Tells a view that labels a feed when the feed's shape changes: what its rows are, how many
/// columns a second it gets, how many it keeps.
///
/// A feed announces only its liveness; nothing in it is observable (V-2). A pipeline gives a
/// feed its shape when it is attached, and may give it another one when the session is
/// updated or the source changes its format. So the watcher looks at the shape whenever the
/// feed's liveness changes, and twice a second while the feed is live. While the feed is not
/// live it looks at nothing and wakes nobody. A look reads the feed's record of its axis and
/// compares it with the last one; the view is told only when they differ.
///
/// Threading: main actor.
@MainActor
final class FeedShapeWatcher {
    /// How often a live feed is looked at, per second.
    static let looksPerSecond = 2

    private var scheduler: FrameScheduler?
    private var observation: FeedObservation?
    private var feed: FeedReference?
    private var last: FeedShape?
    private var onChange: (@MainActor (FeedShape) -> Void)?

    /// Shapes that differed from the one before: what the view was told.
    private(set) var changes = 0
    /// Looks at the feed.
    private(set) var looks = 0

    /// True while the watcher's clock ticks.
    var isRunning: Bool { scheduler?.isRunning ?? false }

    /// Starts watching `feed`. `onChange` is called with every shape that differs from the
    /// one before, the first being the shape the feed has now.
    ///
    /// - Parameter clock: the clock the watcher ticks on; `nil` makes a display link.
    func watch(_ feed: FeedReference, clock: (any FrameClock)? = nil, onChange: @escaping @MainActor (FeedShape) -> Void) {
        stop()
        self.feed = feed
        self.onChange = onChange
        last = feed.shape
        let scheduler = FrameScheduler(clock: clock ?? DisplayLinkClock(), maximumFrameRate: Self.looksPerSecond)
        scheduler.onFrame = { [weak self] _ in
            self?.look()
            return false
        }
        self.scheduler = scheduler
        observation = feed.observeLiveness { [weak self] _ in self?.livenessChanged() }
        scheduler.setFeedLive(feed.isLive)
    }

    /// Stops watching. Nothing ticks afterwards.
    func stop() {
        observation?.cancel()
        observation = nil
        scheduler?.invalidate()
        scheduler = nil
        feed = nil
        onChange = nil
        last = nil
    }

    private func livenessChanged() {
        guard let feed else { return }
        scheduler?.setFeedLive(feed.isLive)
        // A feed gets its shape when its pipeline is attached, just before it becomes live;
        // an offline run has filled it by the time it stops being live.
        look()
    }

    private func look() {
        guard let feed else { return }
        looks += 1
        let shape = feed.shape
        guard shape != last else { return }
        last = shape
        changes += 1
        onChange?(shape)
    }
}
