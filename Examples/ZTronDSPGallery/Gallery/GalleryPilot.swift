import SwiftUI

/// What the process was launched with: `-Name value` pairs on the command line, which is how
/// a UI test tells the application what to show.
enum Launch {
    /// The value of the launch argument `-<name> <value>`.
    static func value(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: name)
    }

    /// `-GalleryExample <name>`: the screen to open at launch.
    static var example: Example? {
        value("GalleryExample").flatMap(Example.init(rawValue:))
    }

    /// `-GallerySheet <name>`: the screen to show in a sheet at launch.
    static var sheet: Example? {
        value("GallerySheet").flatMap(Example.init(rawValue:))
    }
}

/// The gallery's seam for its hosted tests, which run inside the application.
///
/// A hosted test cannot hand the application a view of its own without erasing its type, so
/// to see the gallery's screens it drives the application itself: ``open(_:)`` shows a screen
/// as a tap on its row does.
///
/// The pilot also says which phase the application's scene is in. A view that a test hosts
/// in a window of its own is not told (a hosting controller does not hand the phase on), so
/// the test gives it the phase a view of the scene reads.
///
/// Threading: main actor. A plain object: nothing observes it. The root view registers the
/// closure that changes its own state, and reports the phase it reads.
@MainActor
final class GalleryPilot {
    static let shared = GalleryPilot()

    /// The phase the application's scene reads now; `nil` until the root view has appeared.
    private(set) var scenePhase: ScenePhase?

    private var opener: ((Example?) -> Void)?
    private var presenter: ((Example?) -> Void)?
    private var phaseListeners: [Int: (ScenePhase) -> Void] = [:]
    private var nextListener = 0

    /// True once the root view is in the hierarchy and can be driven.
    var isReady: Bool { opener != nil }

    // MARK: What a test does

    /// Opens the screen of `example`; `nil` goes back to the list.
    func open(_ example: Example?) {
        opener?(example)
    }

    /// Shows the screen of `example` in a sheet over whatever is open; `nil` dismisses it.
    func present(_ example: Example?) {
        presenter?(example)
    }

    /// Calls `listener` with the scene's phase whenever it changes. Returns what
    /// ``removePhaseListener(_:)`` takes.
    func addPhaseListener(_ listener: @escaping (ScenePhase) -> Void) -> Int {
        nextListener += 1
        phaseListeners[nextListener] = listener
        return nextListener
    }

    func removePhaseListener(_ id: Int) {
        phaseListeners[id] = nil
    }

    // MARK: What the root view does

    /// The root view appeared: `open` shows a screen, `present` shows one in a sheet.
    func attach(open: @escaping (Example?) -> Void, present: @escaping (Example?) -> Void) {
        opener = open
        presenter = present
    }

    /// The root view read another scene phase.
    func sceneChanged(to phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        for listener in phaseListeners.values { listener(phase) }
    }
}
