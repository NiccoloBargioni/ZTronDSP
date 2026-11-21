import Foundation
import QuartzCore
import Testing
@testable import ZTronDSPUI

// Waiting without asserting on the wall clock: a hosted test waits for a condition, or for
// frames of the display, never for seconds. A timeout only bounds a failure.

/// Waits until `condition` holds, looking again every half millisecond; false when it does
/// not hold within `timeout` seconds. The timeout is long: it bounds a failure on a machine
/// that may be many times slower than usual, and a test that passes never waits for it.
@MainActor
func eventually(timeout: Double = 120, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

/// Lets everything that is already on the main queue run: a liveness change that a feed has
/// announced is delivered when this returns.
@MainActor
func mainQueueDrained() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Counts the frames of the display with a display link of its own, for as long as it lives.
@MainActor
final class DisplayTicks {
    private let clock = DisplayLinkClock()
    /// Frames the display has shown since the counter was made.
    private(set) var count = 0
    /// Called on every frame, after it is counted.
    var onTick: (@MainActor (Int) -> Void)?

    init() {
        clock.onTick = { [weak self] _ in
            guard let self else { return }
            count += 1
            onTick?(count)
        }
        clock.isPaused = false
    }

    func stop() {
        clock.isPaused = true
        clock.invalidate()
    }
}

/// Waits until the display has shown `count` more frames: time passing, measured in what a
/// view could have drawn, not in seconds.
@MainActor
func displayFrames(_ count: Int) async {
    let ticks = DisplayTicks()
    _ = await eventually { ticks.count >= count }
    ticks.stop()
}
