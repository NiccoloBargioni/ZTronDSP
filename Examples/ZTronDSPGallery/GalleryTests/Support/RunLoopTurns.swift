import CoreFoundation
import Foundation

/// Sees the main run loop go to wait: the end of a turn. What a test hands ``atEndOfTurn(_:)``
/// runs when the loop next goes to wait, after every observer that was installed with a
/// smaller order has run in that same pass. The session's binding pump samples its switches
/// in such an observer, of order 0 (BIND-2).
///
/// Threading: main actor.
@MainActor
final class RunLoopTurns {
    private var observer: CFRunLoopObserver?
    private var pending: [@MainActor () -> Void] = []
    /// Turns that ended since the object was made.
    private(set) var ended = 0

    init() {
        let created = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ended += 1
                let due = self.pending
                self.pending = []
                for action in due { action() }
            }
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    }

    /// Runs `action` when the turn of the run loop that is under way ends.
    func atEndOfTurn(_ action: @escaping @MainActor () -> Void) {
        pending.append(action)
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        pending = []
    }
}
