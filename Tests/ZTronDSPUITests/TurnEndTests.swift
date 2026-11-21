import Foundation
import Testing
@testable import ZTronDSPUI

/// The end of a run-loop turn, on the real main run loop (§8.9, SZ-2): the moment a frame of
/// a size transition is made. The observer is on the run loop only from a request to the
/// call that answers it, the call comes ahead of the place where Core Animation commits the
/// turn's transaction, and a request that is made while the run loop is already calling its
/// observers is answered a turn later without waiting for anything to wake the run loop.
@MainActor
@Suite("The end of a run-loop turn")
struct TurnEndTests {
    /// An observer of the test's own, where Core Animation's commit is: when the run loop is
    /// about to wait or to exit, at order 2 000 000.
    private func commitPlace(in mode: CFRunLoopMode = .commonModes, _ note: @escaping @MainActor () -> Void) -> CFRunLoopObserver {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(nil, activities, true, 2_000_000) { _, _ in
            MainActor.assumeIsolated { note() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        return observer
    }

    /// A timer of the test's own on the main run loop, `seconds` from now.
    private func timer(after seconds: Double, in mode: CFRunLoopMode, _ note: @escaping @MainActor () -> Void) -> CFRunLoopTimer {
        let timer: CFRunLoopTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + seconds, 0, 0, 0) { _ in
            MainActor.assumeIsolated { note() }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, mode)
        return timer
    }

    @Test func aRequestIsAnsweredOnceAtTheEndOfTheTurn() async {
        let turn = RunLoopTurnEnd(), calls = Box(0)
        turn.onEnd = { calls.value += 1 }
        #expect(!turn.isWaiting, "creating one puts nothing on the run loop")
        turn.request()
        turn.request()
        #expect(turn.isWaiting && calls.value == 0, "not while the turn is still under way")
        #expect(await eventually { calls.value == 1 })
        #expect(!turn.isWaiting, "taken off the run loop when it has answered")
        for _ in 0 ..< 5 { await mainQueueDrained() }
        #expect(calls.value == 1, "asked twice in one turn, answered once; and no turn that follows is answered")
        // The next request is answered again.
        turn.request()
        #expect(await eventually { calls.value == 2 })
    }

    @Test func noTurnIsAnsweredThatNobodyAskedFor() async {
        let turn = RunLoopTurnEnd(), calls = Box(0)
        turn.onEnd = { calls.value += 1 }
        for _ in 0 ..< 5 { await mainQueueDrained() }
        #expect(calls.value == 0 && !turn.isWaiting)
    }

    /// The call is made ahead of the place of Core Animation's commit, in the same pass of
    /// the run loop: what is drawn there goes out with the transaction of that turn.
    @Test func theCallComesAheadOfTheCommitOfItsTurn() async {
        #expect(RunLoopTurnEnd.order < 2_000_000)
        let turn = RunLoopTurnEnd(), log = Box<[String]>([])
        let observer = commitPlace { log.value.append("commit") }
        defer { CFRunLoopObserverInvalidate(observer) }
        turn.onEnd = { log.value.append("end") }
        turn.request()
        #expect(await eventually { log.value.contains("end") })
        #expect(await eventually { log.value.last == "commit" })
        let place = log.value.firstIndex(of: "end") ?? 0
        #expect(place + 1 < log.value.count && log.value[place + 1] == "commit", "end, then the commit of the same pass: \(log.value)")
    }

    /// UIKit lays views out while the transaction is committed, after the turn end's place.
    /// A request from there is answered in a turn of its own, right away: the run loop does
    /// not go to sleep first.
    @Test func aRequestMadeWhileTheTurnIsEndingIsAnsweredInATurnOfItsOwn() async {
        let turn = RunLoopTurnEnd(), log = Box<[String]>([]), asked = Box(false)
        turn.onEnd = { log.value.append("end") }
        let observer = commitPlace {
            log.value.append("commit")
            if !asked.value {
                asked.value = true
                turn.request()
            }
        }
        defer { CFRunLoopObserverInvalidate(observer) }
        #expect(await eventually { log.value.contains("end") })
        let place = log.value.firstIndex(of: "end") ?? 0
        #expect(place >= 1 && log.value[place - 1] == "commit", "the pass in which it was asked for ended without it: \(log.value)")
        #expect(log.value.filter { $0 == "end" }.count == 1)
    }

    /// The same where the request has to wake the run loop by itself: the test runs the main
    /// run loop in a mode of its own, which holds the two observers and one timer and nothing
    /// else, so that no work of the main queue and no source or timer of anybody else is
    /// served in it. With the wake-up the request is answered before the run loop sleeps;
    /// without it the run loop sleeps on the request, and the timer comes first.
    ///
    /// Two things from outside can turn one round: the test runner wakes the main run loop
    /// about a tenth of a second into a run, whatever its mode, which answers a request
    /// that nothing else woke the run loop for (hence a timer well before that); and a
    /// machine that holds the main thread up between two passes of the run loop lets the
    /// timer in first. Neither turns most of five rounds.
    @Test func aRequestMadeWhileTheTurnIsEndingWakesTheRunLoop() async {
        let mode = CFRunLoopMode("ZTronDSPUITests.TurnEndTests" as CFString)
        var rounds: [[String]] = []
        for _ in 1 ... 5 {
            rounds.append(requestWhereTheCommitIs(in: mode))
            for _ in 0 ..< 20 { await mainQueueDrained() }
        }
        let answered = rounds.filter { $0.prefix(2) == ["commit", "end"] }.count
        #expect(answered >= 4, "asked for where the commit is, answered before the run loop slept in \(answered) rounds of 5: \(rounds)")
    }

    /// One run of the main run loop in `mode` in which a request is made where the commit
    /// is; returns what happened, in order: "commit", "end", and "timer" when the run loop
    /// slept until its timer.
    private func requestWhereTheCommitIs(in mode: CFRunLoopMode) -> [String] {
        let log = Box<[String]>([]), asked = Box(false)
        // A mode runs only while it holds a timer or a source; and this one says when the
        // run loop slept.
        let late = timer(after: 0.02, in: mode) { log.value.append("timer") }
        defer { CFRunLoopTimerInvalidate(late) }
        // Whatever was waiting to wake the run loop already is taken first.
        for _ in 0 ..< 3 { CFRunLoopRunInMode(mode, 0, false) }
        let turn = RunLoopTurnEnd(mode: mode)
        turn.onEnd = {
            log.value.append("end")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        let observer = commitPlace(in: mode) {
            log.value.append("commit")
            if !asked.value {
                asked.value = true
                turn.request()
            }
        }
        defer { CFRunLoopObserverInvalidate(observer) }
        CFRunLoopRunInMode(mode, 60, false)
        return log.value
    }

    /// What is called may ask for the next turn.
    @Test func aRequestFromTheCallIsAnsweredInTheNextTurn() async {
        let turn = RunLoopTurnEnd(), calls = Box(0)
        turn.onEnd = {
            calls.value += 1
            if calls.value < 3 { turn.request() }
        }
        turn.request()
        #expect(await eventually { calls.value == 3 })
        for _ in 0 ..< 3 { await mainQueueDrained() }
        #expect(calls.value == 3 && !turn.isWaiting)
    }

    @Test func anInvalidatedTurnEndAnswersNothing() async {
        let turn = RunLoopTurnEnd(), calls = Box(0)
        turn.onEnd = { calls.value += 1 }
        turn.request()
        turn.invalidate()
        #expect(!turn.isWaiting && turn.onEnd == nil)
        turn.request()
        #expect(!turn.isWaiting, "nothing is asked for any more")
        for _ in 0 ..< 5 { await mainQueueDrained() }
        #expect(calls.value == 0)
        // One that is let go of with a request pending answers nothing either.
        var other: RunLoopTurnEnd? = RunLoopTurnEnd()
        other?.onEnd = { calls.value += 1 }
        other?.request()
        other = nil
        for _ in 0 ..< 5 { await mainQueueDrained() }
        #expect(calls.value == 0)
    }
}
