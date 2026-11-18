import Foundation
import QuartzCore

/// The clock a ``FrameScheduler`` ticks on: the one seam between the scheduler and the
/// display (§8.3). In an app it is a `CADisplayLink`; a test hands the scheduler a clock it
/// fires itself, so that every scenario of §8.4 runs without waiting for a display.
///
/// Threading: main actor.
@MainActor
protocol FrameClock: AnyObject {
    /// A paused clock delivers no tick: the main thread is not woken on its account.
    var isPaused: Bool { get set }
    /// The most ticks per second the clock is asked to deliver.
    var preferredRate: Int { get set }
    /// Called on every tick with the time of the frame on the display's clock, in seconds.
    var onTick: (@MainActor (CFTimeInterval) -> Void)? { get set }
    /// Ends the clock for good: it never ticks again.
    func invalidate()
}

/// The display's clock: a `CADisplayLink` on the main run loop, in the common modes, so that
/// it keeps ticking while a scroll view tracks a finger.
///
/// The link starts paused. It keeps its target alive, and the target only knows the clock
/// weakly, so releasing the clock is enough to end it: `deinit` invalidates the link.
///
/// Threading: main actor. Creating one adds a paused source to the main run loop and costs
/// no wake-up.
@MainActor
final class DisplayLinkClock: FrameClock {
    /// What the link calls. It holds the clock weakly: the link retains its target.
    private final class Target: NSObject {
        weak var clock: DisplayLinkClock?

        @MainActor @objc func tick(_ link: CADisplayLink) {
            clock?.onTick?(link.timestamp)
        }
    }

    // `invalidate()` is documented as safe from any thread, which is all `deinit` does with it.
    private nonisolated(unsafe) let link: CADisplayLink

    var onTick: (@MainActor (CFTimeInterval) -> Void)?

    init() {
        let target = Target()
        link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        target.clock = self
    }

    deinit {
        link.invalidate()
    }

    var isPaused: Bool {
        get { link.isPaused }
        set {
            guard link.isPaused != newValue else { return }
            link.isPaused = newValue
        }
    }

    var preferredRate: Int = 60 {
        didSet {
            let rate = Float(max(preferredRate, 1))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: max(rate / 2, 1), maximum: rate, preferred: rate)
        }
    }

    func invalidate() {
        link.invalidate()
    }
}
