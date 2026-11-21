import Foundation

/// The end of a turn of the main run loop: the moment a frame of a size transition is made
/// (§8.9, SZ-2). By then SwiftUI and UIKit have laid the view out for this turn, and the
/// transaction that carries the new bounds is not committed yet, so a frame that is drawn
/// here and presented with the transaction reaches the display together with the bounds it
/// was drawn for.
///
/// This is the seam between a surface and the run loop, as ``FrameClock`` is the seam between
/// a surface and the display. In an app it is a run-loop observer; a test hands the surface
/// one whose turns it ends itself.
///
/// Threading: main actor.
@MainActor
protocol TurnEnd: AnyObject {
    /// Called once at the end of a turn that was asked for.
    var onEnd: (@MainActor () -> Void)? { get set }
    /// Asks for one call of `onEnd` at the end of the current turn. Asking again before the
    /// call is made asks for the same call. Nothing is called for a turn nobody asked for:
    /// a surface at rest keeps nothing on the run loop.
    func request()
    /// Ends it for good: a call that was asked for is not made, and none is made again.
    func invalidate()
}

/// The end of a turn of the main run loop, by a Core Foundation run-loop observer.
///
/// The observer is called when the run loop is about to wait, or to exit, in the common
/// modes, ahead of the observer with which Core Animation commits the turn's transaction
/// (order 2 000 000). It is on the run loop only from ``request()`` to the call that answers
/// it.
///
/// A request can be made when the run loop is already on its way to sleep: UIKit lays views
/// out while the transaction is being committed, after this observer's place in the turn.
/// The run loop is therefore told to turn once more instead of sleeping, and the call is
/// made at the end of that turn, a moment later and before the next frame of the display.
/// It is told so with every request; one that is made in the middle of a turn is answered at
/// the end of that turn all the same.
///
/// Threading: main actor. Creating one adds nothing to the run loop and wakes nobody.
@MainActor
final class RunLoopTurnEnd: TurnEnd {
    /// What the observer calls. It knows its owner weakly: the run loop keeps the observer.
    @MainActor
    private final class Target {
        weak var owner: RunLoopTurnEnd?
    }

    /// Ahead of Core Animation's commit, which is an observer of order 2 000 000.
    static let order: CFIndex = 1_900_000

    var onEnd: (@MainActor () -> Void)?
    /// True from a request to the call that answers it.
    private(set) var isWaiting = false
    private var isInvalidated = false
    private let mode: CFRunLoopMode
    // `CFRunLoopObserverInvalidate` may be called from any thread, which is all `deinit` does.
    private nonisolated(unsafe) let observer: CFRunLoopObserver

    /// - Parameter mode: the mode of the main run loop the observer is added in: the common
    ///   modes in an app. A test passes a mode in which nothing else runs.
    init(mode: CFRunLoopMode = .commonModes) {
        self.mode = mode
        let target = Target()
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Self.order) { _, _ in
            MainActor.assumeIsolated { target.owner?.fire() }
        }
        target.owner = self
    }

    deinit {
        CFRunLoopObserverInvalidate(observer)
    }

    func request() {
        guard !isWaiting, !isInvalidated else { return }
        isWaiting = true
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        // Observers that are added while the run loop calls its observers are not called in
        // that pass: without this the call would wait for whatever wakes the run loop next.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func invalidate() {
        isInvalidated = true
        onEnd = nil
        withdraw()
    }

    private func fire() {
        guard isWaiting else { return }
        // Taken off first: what is called may ask for the next turn.
        withdraw()
        onEnd?()
    }

    private func withdraw() {
        guard isWaiting else { return }
        isWaiting = false
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, mode)
    }
}
