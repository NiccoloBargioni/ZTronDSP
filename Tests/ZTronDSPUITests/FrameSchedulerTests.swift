import Foundation
import QuartzCore
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// `FrameScheduler` (WP-802): the rules of §8.3 for when a surface gets a display tick,
/// driven by a clock the test fires.
@MainActor
@Suite("Frame scheduler")
struct FrameSchedulerTests {
    private func scheduler(maximumFrameRate: Int = 60) -> (FrameScheduler, ManualClock, () -> Int) {
        let clock = ManualClock()
        let scheduler = FrameScheduler(clock: clock, maximumFrameRate: maximumFrameRate)
        let frames = Box(0)
        scheduler.onFrame = { _ in
            frames.value += 1
            return false
        }
        return (scheduler, clock, { frames.value })
    }

    // MARK: Paused unless there is a reason

    @Test func aNewSchedulerIsPausedAndWakesNobody() {
        let (scheduler, clock, frames) = scheduler()
        #expect(clock.isPaused && !scheduler.isRunning)
        #expect(clock.fire(60) == 0, "a paused clock delivers no tick")
        #expect(scheduler.ticks == 0 && frames() == 0)
    }

    @Test func aRequestIsGoodForOneTick() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.requestFrame()
        #expect(scheduler.isRunning && scheduler.isFrameRequested)
        #expect(clock.fire(10) == 1, "the clock pauses again after the tick that served the request")
        #expect(frames() == 1 && scheduler.ticks == 1 && !scheduler.isRunning && !scheduler.isFrameRequested)
    }

    /// WP-802: a burst gives at most one draw per tick.
    @Test func aBurstOfRequestsIsOneFramePerTick() {
        let (scheduler, clock, frames) = scheduler()
        for _ in 0 ..< 50 { scheduler.requestFrame() }
        #expect(clock.fire(5) == 1)
        #expect(frames() == 1, "fifty requests before a tick are one frame")
        for tick in 1 ... 20 {
            for _ in 0 ..< 7 { scheduler.requestFrame() }
            clock.fire()
            #expect(frames() == 1 + tick)
        }
        #expect(scheduler.ticks == 21 && scheduler.frames == 21)
    }

    @Test func aHandlerThatStillWantsAFrameGetsTheNextTick() {
        let clock = ManualClock()
        let scheduler = FrameScheduler(clock: clock)
        let left = Box(3)
        scheduler.onFrame = { _ in
            left.value -= 1
            return left.value > 0
        }
        scheduler.requestFrame()
        #expect(clock.fire(10) == 3, "three ticks, then nothing is wanted any more")
        #expect(!scheduler.isRunning)
    }

    @Test func aRequestMadeInsideTheHandlerIsServedOnTheNextTick() {
        let clock = ManualClock()
        let scheduler = FrameScheduler(clock: clock)
        let frames = Box(0)
        scheduler.onFrame = { [weak scheduler] _ in
            frames.value += 1
            if frames.value == 1 { scheduler?.requestFrame() }
            return false
        }
        scheduler.requestFrame()
        #expect(clock.fire(10) == 2 && frames.value == 2)
    }

    // MARK: A live feed

    @Test func aLiveFeedKeepsTheClockRunningAndAFeedThatStopsPausesIt() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.setFeedLive(true)
        #expect(scheduler.isRunning)
        #expect(clock.fire(60) == 60 && frames() == 60, "one frame per tick while the feed is live")
        scheduler.setFeedLive(false)
        #expect(!scheduler.isRunning, "the display link is paused")
        #expect(clock.fire(60) == 0 && scheduler.ticks == 60, "no wake-ups")
        scheduler.setFeedLive(false)
        scheduler.setFeedLive(true)
        scheduler.setFeedLive(true)
        #expect(scheduler.isRunning)
    }

    // MARK: The scene

    @Test func nothingTicksWhileTheSceneIsNotActive() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.setFeedLive(true)
        scheduler.setSceneActive(false)
        #expect(!scheduler.isRunning)
        scheduler.requestFrame()
        #expect(!scheduler.isRunning, "a request waits for the scene")
        #expect(clock.fire(60) == 0 && frames() == 0)
        scheduler.setSceneActive(true)
        #expect(scheduler.isRunning && scheduler.isFrameRequested, "the request is still there")
        #expect(clock.fire() && frames() == 1)
        // A scene that is inactive and a feed that is not live: the request alone resumes it.
        scheduler.setFeedLive(false)
        scheduler.setSceneActive(false)
        scheduler.requestFrame()
        scheduler.setSceneActive(true)
        #expect(clock.fire(5) == 1 && frames() == 2)
    }

    /// A tick that was already on its way when the scene went inactive does nothing.
    @Test func aTickThatArrivesWhileInactiveIsNotAFrame() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.setFeedLive(true)
        scheduler.setSceneActive(false)
        clock.isPaused = false
        #expect(clock.fire())
        #expect(frames() == 0 && clock.isPaused, "the scheduler pauses the clock again")
    }

    // MARK: The cap of `.maximumFrameRate`

    @Test(arguments: [(60, 120.0, 60), (60, 60.0, 60), (30, 60.0, 30), (120, 120.0, 120), (50, 60.0, 30), (1, 60.0, 1), (60, 30.0, 30)])
    func framesPerSecondNeverExceedTheCap(cap: Int, displayRate: Double, expected: Int) {
        let (scheduler, clock, frames) = scheduler(maximumFrameRate: cap)
        #expect(clock.preferredRate == cap, "the clock is asked for no more than the cap")
        scheduler.setFeedLive(true)
        // One second of a display at `displayRate`, after a first tick that starts the count.
        clock.fire(rate: displayRate)
        let first = frames()
        clock.fire(Int(displayRate), rate: displayRate)
        #expect(frames() - first == expected, "\(expected) frames in a second at a cap of \(cap) on a \(Int(displayRate)) Hz display")
        #expect(frames() - first <= cap)
    }

    @Test func theCapCanBeChangedAndValuesBelowOneCountAsOne() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.setFeedLive(true)
        scheduler.setMaximumFrameRate(30)
        #expect(clock.preferredRate == 30 && scheduler.maximumFrameRate == 30)
        clock.fire()
        let first = frames()
        clock.fire(60)
        #expect(frames() - first == 30)
        scheduler.setMaximumFrameRate(0)
        #expect(scheduler.maximumFrameRate == 1 && clock.preferredRate == 1)
        #expect(FrameScheduler(clock: ManualClock(), maximumFrameRate: -5).maximumFrameRate == 1)
    }

    /// While the surface follows a size transition no tick is held against the cap (SZ-2):
    /// every tick of the display reaches the handler, and the clock is asked for the
    /// display's own rate. A frame of a transition that is not made is shown stretched.
    @Test(arguments: [30, 60])
    func duringASizeTransitionEveryTickOfTheDisplayIsAFrame(cap: Int) {
        let (scheduler, clock, frames) = scheduler(maximumFrameRate: cap)
        scheduler.setFeedLive(true)
        clock.fire()
        scheduler.setFollowsDisplay(true)
        #expect(scheduler.followsDisplay && clock.preferredRate == FrameScheduler.displayRate, "the clock is asked for the display's rate")
        var first = frames()
        clock.fire(120, rate: 120)
        #expect(frames() - first == 120, "a 120 Hz display: 120 frames, whatever the cap of \(cap)")
        // A tick that follows a late one comes sooner than the display's period: still a frame.
        first = frames()
        for _ in 0 ..< 10 {
            clock.fire(rate: 45)
            clock.fire(rate: 90)
        }
        #expect(frames() - first == 20)
        // The cap can change meanwhile, and counts again when the transition is over.
        scheduler.setMaximumFrameRate(20)
        #expect(clock.preferredRate == FrameScheduler.displayRate)
        scheduler.setFollowsDisplay(false)
        scheduler.setFollowsDisplay(false)
        #expect(!scheduler.followsDisplay && clock.preferredRate == 20)
        clock.fire()
        first = frames()
        clock.fire(60)
        #expect(frames() - first == 20, "20 frames a second again")
        // A cap above the fastest display is what the clock is asked for.
        scheduler.setMaximumFrameRate(240)
        scheduler.setFollowsDisplay(true)
        #expect(clock.preferredRate == 240)
    }

    /// A skipped tick keeps what is pending: the request is served by the next tick the cap
    /// lets through.
    @Test func aRequestSurvivesATickTheCapSkips() {
        let (scheduler, clock, frames) = scheduler(maximumFrameRate: 30)
        scheduler.requestFrame()
        clock.fire()
        #expect(frames() == 1)
        scheduler.requestFrame()
        clock.fire()
        #expect(frames() == 1 && scheduler.isRunning && scheduler.isFrameRequested, "too soon for a second frame")
        clock.fire()
        #expect(frames() == 2 && !scheduler.isRunning)
    }

    // MARK: The end

    @Test func anInvalidatedSchedulerNeverTicksAgain() {
        let (scheduler, clock, frames) = scheduler()
        scheduler.setFeedLive(true)
        scheduler.invalidate()
        scheduler.invalidate()
        #expect(clock.isInvalidated && clock.isPaused && clock.onTick == nil)
        scheduler.requestFrame()
        scheduler.setFeedLive(false)
        scheduler.setFeedLive(true)
        scheduler.setSceneActive(false)
        scheduler.setSceneActive(true)
        #expect(clock.isPaused && !scheduler.isRunning && frames() == 0)
    }

    // MARK: The display's own clock

    /// The real clock: a `CADisplayLink` that is created paused, ticks while it runs and stops
    /// when it is paused. The display of a process without a window refreshes slowly, so the
    /// test waits for ticks, not for a time.
    @Test func theDisplayLinkClockTicksOnlyWhileItRuns() async {
        let clock = DisplayLinkClock()
        let ticks = Box(0)
        clock.onTick = { _ in ticks.value += 1 }
        #expect(clock.isPaused, "created paused")
        clock.preferredRate = 30
        #expect(clock.preferredRate == 30)
        clock.isPaused = false
        clock.isPaused = false
        #expect(await eventually { ticks.value >= 2 }, "a running display link ticks")
        clock.isPaused = true
        let paused = ticks.value
        // Another clock measures the time that passes: while it ticks twice, the paused one is silent.
        let witness = DisplayLinkClock()
        let seen = Box(0)
        witness.onTick = { _ in seen.value += 1 }
        witness.isPaused = false
        #expect(await eventually { seen.value >= 2 })
        #expect(ticks.value == paused, "a paused display link wakes nobody")
        witness.invalidate()
        clock.invalidate()
    }

    /// A clock that is released ends its display link: nothing ticks into a dead scheduler.
    @Test func aClockThatIsReleasedStopsTicking() async {
        let ticks = Box(0)
        var clock: DisplayLinkClock? = DisplayLinkClock()
        clock?.onTick = { _ in ticks.value += 1 }
        clock?.isPaused = false
        #expect(await eventually { ticks.value >= 1 })
        clock = nil
        let after = ticks.value
        let witness = DisplayLinkClock()
        let seen = Box(0)
        witness.onTick = { _ in seen.value += 1 }
        witness.isPaused = false
        #expect(await eventually { seen.value >= 2 })
        #expect(ticks.value == after)
        witness.invalidate()
    }
}
