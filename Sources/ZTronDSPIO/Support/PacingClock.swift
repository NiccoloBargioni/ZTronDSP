import CZTronDSP
import Foundation

/// The time a source's own thread paces itself with: the monotonic clock of the machine, or a
/// clock a test holds (COV-5).
///
/// Threading: both members are called on the thread that paces, a reader thread or a pacing
/// thread, never on the audio I/O thread or the analysis thread.
protocol PacingClock: Sendable {
    /// Seconds on a monotonic clock.
    var now: Double { get }

    /// Blocks the calling thread until the clock reads `deadline`, or for a shorter while: a
    /// caller that needs the deadline looks at `now` and sleeps again. Returning early is what
    /// lets a thread that is being stopped notice it.
    func sleep(until deadline: Double)
}

/// The monotonic clock the analysis thread also runs on (`ztd_thread_now`).
struct MonotonicClock: PacingClock {
    /// The longest one call sleeps: a thread that is being stopped is gone within this time.
    static let longestSleep = 0.02

    var now: Double { ztd_thread_now() }

    func sleep(until deadline: Double) {
        ztd_thread_sleep_until(min(deadline, ztd_thread_now() + MonotonicClock.longestSleep))
    }
}

/// A thread a source runs a loop of its own on, a file reader or a pacer, and the means to
/// end it.
///
/// Threading: `start`, `cancel` and `join` belong to the control context. The body runs on
/// the thread and asks `isCancelled` between its steps.
final class SourceThread: Sendable {
    private let cancelled = Guarded(false)
    private let finished = DispatchGroup()

    private init() {}

    /// Starts a thread that runs `body` once.
    static func start(
        name: String, qualityOfService: QualityOfService, _ body: @escaping @Sendable (SourceThread) -> Void
    ) -> SourceThread {
        let handle = SourceThread()
        handle.finished.enter()
        let thread = Thread {
            body(handle)
            handle.finished.leave()
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()
        return handle
    }

    /// True once the thread was asked to end.
    var isCancelled: Bool { cancelled.get() }

    /// Asks the thread to end. It does so at its next look at `isCancelled`.
    func cancel() {
        cancelled.set(true)
    }

    /// Waits until the body has returned. False when it has not within `timeout` seconds.
    func join(timeout: Double) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }
}
