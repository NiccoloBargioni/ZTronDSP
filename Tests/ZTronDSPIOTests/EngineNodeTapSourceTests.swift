import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// `EngineNodeTapSource` (WP-706): the pacing buffer, on a tap and a clock the test holds.
/// The real tap, on a node of an engine in manual rendering mode, is tested with the other
/// tests that make real engines (`SimulatorTests`), which must not run side by side.
@Suite("Engine node tap source")
struct EngineNodeTapSourceTests {
    let format = SignalFormat(sampleRate: 48_000, channelCount: 1)
    /// A block of the pacer and of the engine: 10 ms.
    let blockSize = 480
    let blockDuration = 0.01

    private func ramp(_ count: Int, from start: Int = 0) -> [Float] {
        (0 ..< count).map { Float(start + $0) }
    }

    /// A source on a fake tap and a manual clock, attached and started.
    private func paced(clock: ManualClock = ManualClock()) async throws -> (FakeTap, ManualClock, Attachment) {
        let tap = FakeTap(format: format)
        let source = EngineNodeTapSource(tap: tap, blockSize: blockSize, clock: clock)
        let attached = try await Attachment(source, blockSize: blockSize)
        try attached.session.start()
        return (tap, clock, attached)
    }

    // MARK: Preparing and starting

    @Test func preparingReadsTheFormatOfTheTappedBus() async throws {
        let tap = FakeTap(format: SignalFormat(sampleRate: 44_100, channelCount: 2))
        let source = EngineNodeTapSource(tap: tap, blockSize: 512, clock: ManualClock())
        #expect(!source.format.isValid)
        try await source.prepare()
        #expect(source.format == SignalFormat(sampleRate: 44_100, channelCount: 2))
        #expect(tap.bufferSizes.isEmpty, "preparing installs nothing")
    }

    @Test func aBusThatCannotBeTappedIsRefused() async {
        func refusal(_ output: NodeOutput, blockSize: Int = 512) async -> DSPError? {
            let tap = FakeTap()
            tap.setOutput(output)
            do throws(DSPError) {
                try await EngineNodeTapSource(tap: tap, blockSize: blockSize, clock: ManualClock()).prepare()
                return nil
            } catch {
                return error
            }
        }
        func isUnavailable(_ error: DSPError?) -> Bool { if case .sourceUnavailable = error { true } else { false } }
        func isUnsupported(_ error: DSPError?) -> Bool { if case .unsupportedConfiguration = error { true } else { false } }
        func isInvalid(_ error: DSPError?, _ name: String) -> Bool { if case .invalidParameter(_, name, _) = error { true } else { false } }
        #expect(await refusal(NodeOutput(format: format, isAttached: true, hasBus: true, isFloat: true)) == nil)
        #expect(isUnavailable(await refusal(NodeOutput(format: format, isAttached: false, hasBus: true, isFloat: true))), "a node without an engine")
        #expect(isInvalid(await refusal(NodeOutput(format: format, isAttached: true, hasBus: false, isFloat: true)), "bus"), "a bus the node does not have")
        #expect(isUnavailable(await refusal(NodeOutput(format: SignalFormat(sampleRate: 0, channelCount: 0), isAttached: true, hasBus: true, isFloat: false))), "a bus without a format")
        #expect(isUnsupported(await refusal(NodeOutput(format: format, isAttached: true, hasBus: true, isFloat: false))), "samples that are not Float32")
        #expect(isUnsupported(await refusal(NodeOutput(format: SignalFormat(sampleRate: 48_000, channelCount: 300), isAttached: true, hasBus: true, isFloat: true))))
        #expect(isInvalid(await refusal(NodeOutput(format: format, isAttached: true, hasBus: true, isFloat: true), blockSize: 0), "blockSize"))
    }

    @Test func startingInstallsATapForBurstsOfATenthOfASecond() async throws {
        for (rate, expected) in [(48_000.0, 4_800), (44_100.0, 4_410), (22_050.0, 2_205), (11_025.0, 1_103)] {
            let tap = FakeTap(format: SignalFormat(sampleRate: rate, channelCount: 2))
            let source = EngineNodeTapSource(tap: tap, blockSize: 256, clock: ManualClock())
            #expect(throws: DSPError.self) { try source.start() }
            try await source.prepare()
            try source.start()
            try source.start()
            #expect(tap.bufferSizes == [expected] && tap.isInstalled, "100 ms, the shortest a tap delivers (E-15); and once")
            source.stop()
            source.stop()
            #expect(tap.removes == 1 && !tap.isInstalled, "stopping removes the tap, once")
        }
    }

    @Test func aTapThatCannotBeInstalledFailsTheStart() async throws {
        let tap = FakeTap(format: format)
        let source = EngineNodeTapSource(tap: tap, blockSize: 256, clock: ManualClock())
        try await source.prepare()
        tap.failInstall(with: .sourceUnavailable(reason: "the bus has a tap"))
        #expect(throws: DSPError.sourceUnavailable(reason: "the bus has a tap")) { try source.start() }
        tap.setOutput(NodeOutput(format: format, isAttached: false, hasBus: true, isFloat: true))
        #expect(throws: DSPError.self) { try source.start() }
        #expect(tap.bufferSizes.count == 1, "a node that was detached since is not asked for a tap")
        tap.failInstall(with: nil)
        tap.setOutput(NodeOutput(format: format, isAttached: true, hasBus: true, isFloat: true))
        try source.start()
        #expect(tap.isInstalled)
        source.stop()
    }

    // MARK: The pacing buffer

    /// The pacer looks once per block duration. With a burst in the buffer, every look
    /// releases one block: the blocks leave at the block rate, one burst late.
    @Test func blocksAreReleasedAtTheBlockRate() async throws {
        let (tap, clock, attached) = try await paced()
        let burst = ramp(4_800)
        tap.deliver([burst])
        await pause(milliseconds: 40)
        #expect(attached.sink.frameCount == 0, "40 ms of real time and no tick of the clock: nothing is released")
        for tick in 1 ... 10 {
            clock.advance(by: blockDuration)
            #expect(await eventually { attached.sink.frameCount == tick * blockSize }, "tick \(tick)")
            await pause(milliseconds: 5)
            #expect(attached.sink.frameCount == tick * blockSize, "one block per tick, not more")
        }
        #expect(attached.sink.samples() == burst, "the samples of the burst, in order")
        #expect(attached.sink.blockSizes.allSatisfy { $0 == blockSize })

        // The buffer has run dry: ticks release nothing. The next burst leaves the same way.
        clock.advance(by: blockDuration)
        clock.advance(by: 0.5)
        await pause()
        #expect(attached.sink.frameCount == 4_800)
        tap.deliver([ramp(4_800, from: 4_800)])
        for tick in 1 ... 3 {
            clock.advance(by: blockDuration)
            #expect(await eventually { attached.sink.frameCount == 4_800 + tick * blockSize })
        }
        // A pacer that was held up for three block durations owes three blocks, and pays them.
        clock.advance(by: blockDuration * 3 + 0.001)
        #expect(await eventually { attached.sink.frameCount == 4_800 + 6 * blockSize })
        await pause(milliseconds: 5)
        #expect(attached.sink.frameCount == 4_800 + 6 * blockSize, "three block durations, three blocks")
        #expect(attached.sink.samples() == ramp(4_800 + 6 * blockSize))
        attached.session.detach()
    }

    @Test func aTickReleasesNothingUntilAWholeBlockIsThere() async throws {
        let (tap, clock, attached) = try await paced()
        tap.deliver([ramp(300)])
        clock.advance(by: blockDuration * 5)
        await pause()
        #expect(attached.sink.frameCount == 0, "300 frames are not a block")
        tap.deliver([ramp(300, from: 300)])
        clock.advance(by: blockDuration)
        #expect(await eventually { attached.sink.frameCount == blockSize })
        clock.advance(by: blockDuration)
        await pause()
        #expect(attached.sink.samples() == ramp(blockSize), "and the 120 frames left over wait for the rest of their block")
        attached.session.detach()
    }

    @Test func whatWaitsBeyondTwoBurstsIsReleasedAtOnce() async throws {
        let (tap, clock, attached) = try await paced()
        // Four bursts before the pacer looks: it was held up, or the tap's clock runs fast.
        for burst in 0 ..< 4 { tap.deliver([ramp(4_800, from: burst * 4_800)]) }
        clock.advance(by: blockDuration)
        #expect(await eventually { attached.sink.frameCount == 2 * 4_800 }, "all but two bursts leave at the first look")
        await pause(milliseconds: 40)
        #expect(attached.sink.frameCount == 2 * 4_800, "the two bursts that may wait, wait")
        clock.advance(by: blockDuration)
        #expect(await eventually { attached.sink.frameCount == 2 * 4_800 + blockSize })
        await pause(milliseconds: 5)
        #expect(attached.sink.frameCount == 2 * 4_800 + blockSize, "and leave at the block rate")
        #expect(attached.sink.samples() == ramp(2 * 4_800 + blockSize), "nothing is lost or reordered by catching up")
        attached.session.detach()
    }

    @Test func stoppingDropsWhatWasNotReleased() async throws {
        let (tap, clock, attached) = try await paced()
        tap.deliver([ramp(4_800)])
        clock.advance(by: blockDuration)
        #expect(await eventually { attached.sink.frameCount == blockSize })
        attached.session.stop()
        #expect(!tap.isInstalled)
        tap.deliverLate([ramp(4_800)])                          // a burst that was on its way belongs to nobody
        clock.advance(by: 1)
        try attached.session.start()
        #expect(tap.bufferSizes.count == 2, "started again: a new tap")
        tap.deliverLate([ramp(4_800, from: 50_000)])            // nor does a straggler of the old tap belong to the new start
        tap.deliver([ramp(960, from: 10_000)])
        for _ in 0 ..< 2 {
            clock.advance(by: blockDuration)
            await pause(milliseconds: 10)
        }
        #expect(await eventually { attached.sink.frameCount == blockSize + 960 })
        #expect(Array(attached.sink.samples()[blockSize...]) == ramp(960, from: 10_000), "what follows a stop starts with what arrives after it")
        attached.session.detach()
    }

    @Test func aBufferThatIsFullDropsTheNewestBurstsAndReportsAnOverrun() async throws {
        // No engine: nobody hands the source a ring, so nothing can be released.
        let tap = FakeTap(format: format)
        let clock = ManualClock()
        let source = EngineNodeTapSource(tap: tap, blockSize: blockSize, clock: clock)
        let log = SourceLog(source)
        try await source.prepare()
        try source.start()
        let capacity = EngineNodeTapSource.capacity(for: format)
        #expect(capacity == 72_000, "a second and a half")
        var delivered = 0
        while delivered < 3 * capacity {
            tap.deliver([ramp(4_800)])
            delivered += 4_800
        }
        clock.advance(by: blockDuration)
        let total = delivered
        #expect(await eventually {
            if case .overrun(let frames)? = log.all.first { frames > 0 && frames < total } else { false }
        }, "the pacing buffer never grows; what did not fit is counted and reported")
        source.stop()
    }

    // MARK: The format

    @Test func aBurstInAnotherFormatIsAFormatChange() async throws {
        let (tap, clock, attached) = try await paced()
        let stereo = SignalFormat(sampleRate: 44_100, channelCount: 2)
        let left = ramp(4_410), right = ramp(4_410, from: 100_000)
        tap.deliver([left, right], format: stereo)
        #expect(await eventually { attached.log.contains(.replanned(.formatChanged)) }, "the session re-plans")
        #expect(attached.session.environment.sampleRate == 44_100 && attached.session.environment.channelCount == 2)
        clock.advance(by: 1)
        #expect(await eventually { attached.sink.channelCount == 2 && attached.sink.frameCount >= blockSize })
        #expect(attached.session.state == .running)
        let got = attached.sink.frameCount
        #expect(attached.sink.samples(ofChannel: 0) == Array(left[..<got]) && attached.sink.samples(ofChannel: 1) == Array(right[..<got]),
                "the burst that brought the new format is the first of it")
        attached.session.detach()
    }

    @Test func aBurstTheTapCannotTakeFailsTheSource() async throws {
        let (tap, _, attached) = try await paced()
        tap.deliver([ramp(4_800)], isFloat: false)
        #expect(await eventually {
            if case .failed(.unsupportedConfiguration) = attached.session.state { true } else { false }
        })
        #expect(await eventually { !tap.isInstalled }, "a failed source is stopped")
    }
}

/// The pacing buffer by itself, and what the tap source does when memory or a thread fails it
/// (WP-706).
@Suite("Engine node tap source: the pacing buffer and failures")
struct PacingBufferTests {
    let format = SignalFormat(sampleRate: 48_000, channelCount: 2)

    @Test func theBufferKeepsBurstsInOrderAndCountsWhatItCannotKeep() throws {
        let buffer = try BurstBuffer(channelCount: 2, capacity: 4_096)
        let left = (0 ..< 3_000).map { Float($0) }, right = left.map { -$0 }
        withBufferList(planar: [left, right]) { buffer.append($0, frameCount: 3_000) }
        #expect(buffer.available == 3_000 && buffer.largestBurst == 3_000 && buffer.lostFrames == 0)
        withBufferList(planar: [left, right]) { buffer.append($0, frameCount: 3_000) }
        #expect(buffer.available == 4_096 && buffer.lostFrames == 1_904, "a full buffer drops the newest frames and counts them")
        withBufferList(planar: [left]) { buffer.append($0, frameCount: 100) }
        #expect(buffer.lostFrames == 2_004 && buffer.largestBurst == 3_000, "a burst of another layout is not kept")

        let storage = try ZTronDSPCore.AudioBuffer(channelCount: 2, capacity: 1_000)
        var block = storage.block(frameCount: 0)
        #expect(buffer.release(into: &block) == 1_000 && block.frameCount == 1_000)
        #expect(Array(block.samples(ofChannel: 0)) == Array(left[..<1_000]) && Array(block.samples(ofChannel: 1)) == Array(right[..<1_000]))
        #expect(buffer.available == 3_096)
    }

    @Test func aBufferThatCannotBeHadIsAnError() throws {
        for (channels, capacity) in [(0, 100), (-1, 100), (257, 100), (2, 0), (2, -4), (2, (1 << 30) + 1)] {
            #expect(throws: DSPError.self, "\(channels) channels of \(capacity) frames") { _ = try BurstBuffer(channelCount: channels, capacity: capacity) }
        }
        // Every request for memory refused in turn. A buffer is not made, or it is made whole:
        // the ring falls back to plain storage when its mirror is refused, and without the
        // ring's memory or the tap's there is no buffer.
        var refusals = 0, buffers = 0
        for request in 0 ..< 16 {
            refuseAllocation(request)
            defer { refuseAllocation(-1) }
            do throws(DSPError) {
                let buffer = try BurstBuffer(channelCount: 2, capacity: 1_024)
                refuseAllocation(-1)
                withBufferList(planar: [[1, 2, 3], [4, 5, 6]]) { buffer.append($0, frameCount: 3) }
                #expect(buffer.available == 3 && buffer.lostFrames == 0)
                buffers += 1
            } catch {
                guard case .resourceAllocationFailed = error else {
                    Issue.record("expected resourceAllocationFailed, got \(error)")
                    return
                }
                refusals += 1
            }
        }
        #expect(refusals >= 3 && buffers >= 1, "\(refusals) refusals left no buffer, \(buffers) left a whole one")
    }

    @Test func aNewFormatWithoutMemoryForItFailsTheSource() async throws {
        let tap = FakeTap(format: SignalFormat(sampleRate: 48_000, channelCount: 1))
        let source = EngineNodeTapSource(tap: tap, blockSize: 480, clock: ManualClock())
        let log = SourceLog(source)
        try await source.prepare()
        try source.start()
        // The burst arrives on this thread, and so does the request for the new buffer.
        refuseAllocation(0)
        tap.deliver([[1, 2, 3], [4, 5, 6]], format: format)
        refuseAllocation(-1)
        #expect(await log.shows([.failed(.resourceAllocationFailed(what: "the pacing buffer of a node tap"))]))
        #expect(source.format.channelCount == 1, "the format is not the one that could not be taken")
        tap.deliver([[1, 2, 3]])
        await pause()
        #expect(log.all.count == 1, "a source that has failed says so once")
        source.stop()
    }

    /// A pacing thread that does not end in time is left behind: `stop()` returns, and the
    /// source starts again with a new buffer and a new thread.
    @Test func aPacerThatIsStuckDoesNotHoldTheSourceUp() async throws {
        let tap = FakeTap(format: SignalFormat(sampleRate: 48_000, channelCount: 1))
        let clock = StubbornClock()
        let source = EngineNodeTapSource(tap: tap, blockSize: 480, clock: clock, stopTimeout: 0.02)
        try await source.prepare()
        try source.start()
        #expect(await eventually { clock.isAsleep }, "the pacer is in its sleep")
        source.stop()
        // Not a bound on the wall clock, which a busy machine does not keep: `stop()` came back
        // while the pacer was still asleep, so it gave up after its time-out.
        #expect(clock.isAsleep && !tap.isInstalled, "stop() returned while the pacer was still in its sleep")
        try source.start()
        #expect(tap.isInstalled && tap.bufferSizes.count == 2)
        source.stop()
    }

    @Test func aSourceThreadRunsOnceAndCanBeJoined() {
        let ran = Shared(0)
        let thread = SourceThread.start(name: "com.zombietron.ztrondsp.test", qualityOfService: .utility) { thread in
            while !thread.isCancelled { usleep(200) }
            ran.withLock { $0 += 1 }
        }
        #expect(!thread.isCancelled && !thread.join(timeout: 0.02), "it runs until it is asked to end")
        thread.cancel()
        #expect(thread.join(timeout: 2) && thread.isCancelled && ran.get() == 1)
        #expect(thread.join(timeout: 0), "a thread that has ended is joined at once")
    }
}
