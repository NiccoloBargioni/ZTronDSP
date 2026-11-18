import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO
import ZTronDSPTesting

/// `FileSource` (WP-707): the reader thread, the lossless ring, pacing on a clock the test
/// holds, rate conversion, and the source-transparency property of R-01. The files are
/// written with `AVAudioFile` into a temporary directory by each test.
@Suite("File source")
struct FileSourceTests {
    /// Everything a file source delivers to a pipeline that only collects.
    private func decode(_ source: FileSource, blockSize: Int = 128, smoothing: Bool = false) async throws -> (Collector, SessionLog) {
        let attached = try await Attachment(source, blockSize: blockSize, smoothing: smoothing)
        try attached.session.start()
        #expect(await attached.session.reaches(.finished, timeout: 20))
        return (attached.sink, attached.log)
    }

    // MARK: Decoded samples ≡ reference

    @Test func aFloatFileIsDeliveredBitForBit() async throws {
        let fixtures = try AudioFixtures()
        let left = TestSignal.whiteNoise(count: 5_003, seed: 11), right = TestSignal.whiteNoise(count: 5_003, seed: 12)
        let url = try fixtures.write([left, right], sampleRate: 44_100, name: "stereo.caf")
        let source = FileSource(url: url, pacing: .asFastAsPossible)
        let (sink, log) = try await decode(source)
        #expect(source.format == SignalFormat(sampleRate: 44_100, channelCount: 2), "the file's own format")
        #expect(sink.samples(ofChannel: 0).map { $0.bitPattern } == left.map { $0.bitPattern })
        #expect(sink.samples(ofChannel: 1).map { $0.bitPattern } == right.map { $0.bitPattern })
        #expect(sink.blockSizes.dropLast().allSatisfy { $0 == 128 } && sink.blockSizes.last == 5_003 % 128, "full blocks, then the rest")
        #expect(await eventually { log.states.prefix(2) == [.running, .finished] }, "the source reports its end after its last write, and the session finishes when the ring is drained")
    }

    @Test func aSixteenBitWaveFileIsDeliveredExactly() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 48_000, seed: 5)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "mono16.wav", bitDepth: 16)
        let source = FileSource(url: url, pacing: .asFastAsPossible, blockSize: 333)
        let (sink, _) = try await decode(source)
        #expect(source.format == SignalFormat(sampleRate: 48_000, channelCount: 1))
        #expect(sink.samples() == signal, "integers come back as the fractions they were")
    }

    @Test func aFileOfFourChannelsKeepsItsChannels() async throws {
        let fixtures = try AudioFixtures()
        let channels = (0 ..< 4).map { TestSignal.whiteNoise(count: 2_000, seed: UInt64(30 + $0)) }
        let url = fixtures.directory.appendingPathComponent("quad.caf")
        // Four channels need a layout to be written.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000))
        buffer.frameLength = 2_000
        let data = try #require(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() { data[index].update(from: samples, count: 2_000) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let source = FileSource(url: url, pacing: .asFastAsPossible)
        let (sink, _) = try await decode(source)
        #expect(source.format == SignalFormat(sampleRate: 48_000, channelCount: 4))
        for channel in 0 ..< 4 { #expect(sink.samples(ofChannel: channel) == channels[channel], "channel \(channel)") }
    }

    /// The reader waits for room instead of dropping (RT-8): a file far longer than the ring
    /// arrives whole, as fast as the pipeline drains it.
    @Test func aFileLongerThanTheRingLosesNothing() async throws {
        let fixtures = try AudioFixtures()
        let signal = TestSignal.whiteNoise(count: 300_000, seed: 2)        // 6.25 s; the ring holds half a second
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "long.wav")
        let started = Date()
        let (sink, log) = try await decode(FileSource(url: url, pacing: .asFastAsPossible), blockSize: 512)
        #expect(sink.samples() == signal)
        #expect(!log.all.contains { if case .overrun = $0 { true } else { false } }, "a reader thread waits; it never overruns")
        #expect(Date().timeIntervalSince(started) < 6.25, "and it is not held to the file's own speed")
    }

    // MARK: Source transparency (R-01)

    /// The same samples through `BufferSource`, `ScriptedSource` in irregular batches and
    /// `FileSource` in either pacing give bit-identical pipeline output.
    @Test func bufferScriptedAndFileSourcesGiveBitIdenticalPipelineOutput() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 10_007, seed: 9)
        func output(_ source: any SampleSource) async throws -> [UInt32] {
            let attached = try await Attachment(source, blockSize: 256, smoothing: true)
            try attached.session.start()
            #expect(await attached.session.reaches(.finished, timeout: 20))
            return attached.sink.samples().map { $0.bitPattern }
        }
        let reference = try await output(BufferSource(signal, sampleRate: 48_000))
        #expect(reference.count == signal.count && reference != signal.map { $0.bitPattern }, "the pipeline does change the signal")
        #expect(try await output(ScriptedSource(signal, sampleRate: 48_000, batchSizes: [1, 1_000, 7, 300, 4_096, 3])) == reference, "irregular batches")

        let float = try fixtures.write([signal], sampleRate: 48_000, name: "float.wav")
        let integer = try fixtures.write([signal], sampleRate: 48_000, name: "integer.wav", bitDepth: 16)
        #expect(try await output(FileSource(url: float, pacing: .asFastAsPossible)) == reference, "a file, as fast as it is processed")
        #expect(try await output(FileSource(url: integer, pacing: .asFastAsPossible, blockSize: 100)) == reference, "a 16-bit file read in blocks of 100")
        #expect(try await output(FileSource(url: float, pacing: .realTime, sampleRate: nil, blockSize: 512, clock: LeapingClock())) == reference, "a file paced in real time")
        #expect(try await output(FileSource(url: float, pacing: .asFastAsPossible, sampleRate: 48_000)) == reference, "asked for the rate it has: not converted")
    }

    // MARK: Pacing

    /// With an injected clock, real-time pacing releases blocks at the block rate, give or
    /// take one block: block k leaves when the clock reads k block durations.
    @Test func realTimePacingReleasesBlocksAtTheBlockRate() async throws {
        let fixtures = try AudioFixtures()
        // 375 frames at 48 kHz are 1/128 s, which a Double holds exactly: ticks add up to
        // whole block durations without rounding.
        let blockSize = 375, blockDuration = 1.0 / 128, blocks = 12
        let signal = steppedSignal(count: blocks * blockSize, seed: 3)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "paced.wav")
        let clock = ManualClock()
        let source = FileSource(url: url, pacing: .realTime, sampleRate: nil, blockSize: blockSize, clock: clock)
        let attached = try await Attachment(source, blockSize: blockSize)
        try attached.session.start()

        // The first block is due at the start; no other is before the clock moves.
        #expect(await eventually { attached.sink.frameCount == blockSize })
        await pause(milliseconds: 40)
        #expect(attached.sink.frameCount == blockSize, "40 ms of real time and no tick: nothing more is released")
        for tick in 1 ..< blocks {
            clock.advance(by: blockDuration)
            #expect(await eventually { attached.sink.frameCount == (tick + 1) * blockSize }, "tick \(tick)")
            await pause(milliseconds: 3)
            let released = attached.sink.frameCount
            #expect(abs(released - tick * blockSize) <= blockSize, "the clock reads \(tick) block durations: \(released) frames are out")
        }
        #expect(await attached.session.reaches(.finished), "after its last write the source has ended, without another tick")
        #expect(attached.sink.samples() == signal)
        #expect(attached.sink.times == (0 ..< blocks).map { Double($0 * blockSize) / 48_000 })
    }

    @Test func aReaderThatFellBehindCatchesUpWithoutLosingABlock() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 20 * 375, seed: 6)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "late.wav")
        let clock = ManualClock()
        let attached = try await Attachment(FileSource(url: url, pacing: .realTime, sampleRate: nil, blockSize: 375, clock: clock), blockSize: 375)
        try attached.session.start()
        #expect(await eventually { attached.sink.frameCount == 375 })
        clock.advance(by: 5.5 / 128)                            // five and a half block durations at once
        #expect(await eventually { attached.sink.frameCount == 6 * 375 })
        await pause()
        #expect(attached.sink.frameCount == 6 * 375, "what was due is out, what is not due is not")
        clock.advance(by: 10)
        #expect(await attached.session.reaches(.finished))
        #expect(attached.sink.samples() == signal)
    }

    @Test func asFastAsPossibleNeverLooksAtTheClock() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 30_000, seed: 8)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "fast.wav")
        let clock = ManualClock()
        let source = FileSource(url: url, pacing: .asFastAsPossible, sampleRate: nil, blockSize: 512, clock: clock)
        let (sink, _) = try await decode(source)
        #expect(sink.samples() == signal && clock.sleepCount == 0)
    }

    /// The reader loop by itself, on the test's thread: what it writes and when it ends.
    @Test func theReaderLoopWritesEveryBlockAndThenReportsTheEnd() throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 1_050, seed: 4)
        let url = try fixtures.write([signal], sampleRate: 8_000, name: "loop.wav")
        let channel = SourceEventChannel()
        var written: [Float] = [], sizes: [Int] = []
        let thread = SourceThread.start(name: "idle", qualityOfService: .utility) { _ in }
        let reader = try FileReader(url: url, sampleRate: nil, blockSize: 400)
        let total = FileSource.read(reader, pacing: .asFastAsPossible, clock: ManualClock(), channel: channel, thread: thread) { block in
            written.append(contentsOf: block.samples(ofChannel: 0))
            sizes.append(block.frameCount)
            return block.frameCount
        }
        #expect(total == 1_050 && sizes == [400, 400, 250] && written == signal)

        // A writer that takes less than it is given is a ring that was closed: the reader stops, and has not ended.
        reader.seek(toFrame: 0)
        var taken = 0
        let partial = FileSource.read(reader, pacing: .asFastAsPossible, clock: ManualClock(), channel: channel, thread: thread) { block in
            taken += 1
            return taken == 2 ? 150 : block.frameCount
        }
        #expect(partial == 550 && taken == 2)

        // A thread that was asked to end reads nothing more.
        thread.cancel()
        #expect(thread.join(timeout: 1) && thread.isCancelled)
        reader.seek(toFrame: 0)
        #expect(FileSource.read(reader, pacing: .realTime, clock: ManualClock(), channel: channel, thread: thread) { $0.frameCount } == 0)
    }

    // MARK: Stopping, starting, starting over

    /// Stopping and starting continues where the pipeline left off: what had been read ahead
    /// into the ring is read again, so no sample is lost and none comes twice.
    @Test func stoppingAndStartingContinuesWhereThePipelineLeftOff() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 30 * 375, seed: 7)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "resume.wav")
        let clock = ManualClock()
        let source = FileSource(url: url, pacing: .realTime, sampleRate: nil, blockSize: 375, clock: clock)
        // The engine's blocks are not the reader's: after every write some frames stay in the ring.
        let attached = try await Attachment(source, blockSize: 128)
        try attached.session.start()
        for _ in 0 ..< 4 {
            clock.advance(by: 1.0 / 128)
            await pause(milliseconds: 10)
        }
        // Five blocks of 375 frames are out: fourteen blocks of 128 for the pipeline, 83 frames left in the ring.
        #expect(await eventually { attached.sink.frameCount == 14 * 128 })
        attached.session.stop()
        let delivered = attached.sink.frameCount
        #expect(delivered > 0 && delivered < signal.count && delivered % 128 == 0, "stopped part of the way: \(delivered) frames")

        try attached.session.start()
        clock.advance(by: 10)
        #expect(await attached.session.reaches(.finished))
        #expect(attached.sink.samples() == signal, "every sample once, in order, across the stop")
    }

    @Test func aFinishedSessionStartsTheFileOver() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 3_000, seed: 1)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "again.wav")
        let attached = try await Attachment(FileSource(url: url, pacing: .asFastAsPossible))
        try attached.session.start()
        #expect(await attached.session.reaches(.finished))
        try attached.session.start()
        #expect(await eventually { attached.sink.frameCount == 2 * signal.count })
        #expect(await attached.session.reaches(.finished))
        #expect(attached.sink.samples() == signal + signal, "prepared again, a source that has an end starts over")
    }

    // MARK: Rate conversion

    @Test func aFileIsConvertedToTheRateAskedFor() async throws {
        let fixtures = try AudioFixtures()
        let tone = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 48_000, amplitude: 0.5)
        let url = try fixtures.write([tone, tone.map { -$0 }], sampleRate: 48_000, name: "tone.wav")
        let source = FileSource(url: url, pacing: .asFastAsPossible, sampleRate: 16_000)
        let (sink, _) = try await decode(source)
        #expect(source.format == SignalFormat(sampleRate: 16_000, channelCount: 2), "the format is the one asked for")
        let converted = sink.samples(ofChannel: 0)
        #expect(abs(converted.count - 16_000) <= 64, "a second is a second: \(converted.count) frames at 16 kHz")
        // The same tone: its level and its frequency, away from the converter's edges.
        try #require(converted.count >= 14_000)
        let middle = Array(converted[2_000 ..< 14_000])
        let rms = (middle.reduce(0) { $0 + Double($1) * Double($1) } / Double(middle.count)).squareRoot()
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 0.005, "an RMS of \(rms) for a sine of amplitude 0.5")
        let crossings = middle.indices.dropFirst().filter { (middle[$0 - 1] < 0) != (middle[$0] < 0) }.count
        #expect(abs(crossings - 1_500) <= 2, "\(crossings) zero crossings in 0.75 s of a 1 kHz tone")
        #expect(sink.samples(ofChannel: 1).count == converted.count)
        expectClose(sink.samples(ofChannel: 1), converted.map { -$0 }, .absolute(1e-6), "the channels are converted alike")
    }

    @Test func aFileIsConvertedUpwardsToo() async throws {
        let fixtures = try AudioFixtures()
        let tone = TestSignal.sine(frequency: 441, sampleRate: 22_050, count: 22_050, amplitude: 0.25)
        let url = try fixtures.write([tone], sampleRate: 22_050, name: "low.wav")
        let source = FileSource(url: url, pacing: .realTime, sampleRate: 44_100, blockSize: 512, clock: LeapingClock())
        let (sink, _) = try await decode(source, blockSize: 512)
        #expect(source.format.sampleRate == 44_100)
        #expect(abs(sink.frameCount - 44_100) <= 128)
        try #require(sink.frameCount >= 39_690)
        let middle = Array(sink.samples()[4_410 ..< 39_690])
        let crossings = middle.indices.dropFirst().filter { (middle[$0 - 1] < 0) != (middle[$0] < 0) }.count
        #expect(abs(crossings - 706) <= 2, "\(crossings) zero crossings in 0.8 s of a 441 Hz tone")
    }

    // MARK: Files that cannot be read

    @Test func aFileThatCannotBeReadIsSourceUnavailable() async throws {
        let fixtures = try AudioFixtures()
        func refusal(_ source: FileSource) async -> DSPError? {
            do throws(DSPError) {
                try await source.prepare()
                return nil
            } catch {
                return error
            }
        }
        let missing = await refusal(FileSource(url: fixtures.directory.appendingPathComponent("nowhere.wav")))
        guard case .sourceUnavailable(let reason)? = missing else {
            Issue.record("a missing file is sourceUnavailable, not \(String(describing: missing))")
            return
        }
        #expect(reason.contains("nowhere.wav"), "the error names the file: \(reason)")

        let text = fixtures.directory.appendingPathComponent("notes.wav")
        try Data("not audio at all".utf8).write(to: text)
        if case .sourceUnavailable? = await refusal(FileSource(url: text)) {} else { Issue.record("a file that is not audio is sourceUnavailable") }

        let good = try fixtures.write([steppedSignal(count: 100, seed: 1)], sampleRate: 8_000, name: "good.wav")
        for blockSize in [0, -5, 1 << 25] {
            if case .invalidParameter(_, "blockSize", _)? = await refusal(FileSource(url: good, blockSize: blockSize)) {} else { Issue.record("a block size of \(blockSize)") }
        }
        for rate in [0.0, -44_100, .infinity, .nan] {
            if case .invalidParameter(_, "sampleRate", _)? = await refusal(FileSource(url: good, sampleRate: rate)) {} else { Issue.record("a sample rate of \(rate)") }
        }
        #expect(await refusal(FileSource(url: good)) == nil)
        #expect(throws: DSPError.self) { try FileSource(url: good).start() }
        await #expect(throws: DSPError.self) { try await DSPEngine(blockSize: 64).attach(Pipeline(), to: FileSource(url: text)) }
    }

    @Test func anEmptyFileEndsAtOnce() async throws {
        let fixtures = try AudioFixtures()
        let url = try fixtures.write([[]], sampleRate: 48_000, name: "empty.wav")
        let (sink, log) = try await decode(FileSource(url: url))
        #expect(sink.frameCount == 0)
        #expect(await eventually { log.states.prefix(2) == [.running, .finished] })
    }

    // MARK: The reader

    @Test func theReaderDeliversBlocksAndSeeks() throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 250, seed: 2)
        let url = try fixtures.write([signal, signal.map { -$0 }], sampleRate: 8_000, name: "seek.wav")
        let reader = try FileReader(url: url, sampleRate: nil, blockSize: 100)
        #expect(reader.format == SignalFormat(sampleRate: 8_000, channelCount: 2))
        func drain() throws -> ([Int], [Float], [Float]) {
            var sizes: [Int] = [], left: [Float] = [], right: [Float] = []
            while let block = try reader.next() {
                sizes.append(block.frameCount)
                left.append(contentsOf: block.samples(ofChannel: 0))
                right.append(contentsOf: block.samples(ofChannel: 1))
            }
            return (sizes, left, right)
        }
        var (sizes, left, right) = try drain()
        #expect(sizes == [100, 100, 50] && left == signal && right == signal.map { -$0 })
        #expect(try reader.next() == nil, "the end is the end")
        reader.seek(toFrame: 120)
        (sizes, left, right) = try drain()
        #expect(sizes == [100, 30] && left == Array(signal[120...]))
        reader.seek(toFrame: -3)
        #expect(try drain().1 == signal, "before the start is the start")
        reader.seek(toFrame: 9_999)
        #expect(try reader.next() == nil, "past the end is the end")
    }

    @Test func theConvertingReaderSeeksToTheNearestFrameOfTheFile() throws {
        let fixtures = try AudioFixtures()
        let tone = TestSignal.sine(frequency: 100, sampleRate: 8_000, count: 8_000, amplitude: 0.5)
        let url = try fixtures.write([tone], sampleRate: 8_000, name: "convert.wav")
        let reader = try FileReader(url: url, sampleRate: 4_000, blockSize: 256)
        #expect(reader.format == SignalFormat(sampleRate: 4_000, channelCount: 1))
        func count() throws -> Int {
            var frames = 0
            while let block = try reader.next() { frames += block.frameCount }
            return frames
        }
        let whole = try count()
        #expect(abs(whole - 4_000) <= 64, "\(whole) frames at half the rate")
        #expect(try reader.next() == nil)
        reader.seek(toFrame: 3_000)                              // frame 6 000 of the file: a quarter is left
        let rest = try count()
        #expect(abs(rest - 1_000) <= 64, "\(rest) frames from three quarters on")
        #expect(throws: DSPError.self) { _ = try FileReader(url: url, sampleRate: 4_000, blockSize: 0) }
    }
}

/// What a file source does when a file fails under it, when a thread is stuck, and on the
/// real clock (WP-707).
@Suite("File source: failures and the real clock")
struct FileSourceFailureTests {
    /// Cuts the file at `url` down to its first 2 000 bytes: what follows cannot be read.
    private func truncate(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2_000)
        try handle.close()
    }

    @Test(arguments: [nil, 24_000.0] as [Double?])
    func aReadThatFailsIsSourceUnavailable(sampleRate: Double?) async throws {
        let fixtures = try AudioFixtures()
        let url = try fixtures.write([steppedSignal(count: 50_000, seed: 1)], sampleRate: 48_000, name: "cut.wav")
        let reader = try FileReader(url: url, sampleRate: sampleRate, blockSize: 4_096)
        #expect(try reader.next() != nil)
        try truncate(url)
        do throws(DSPError) {
            while try reader.next() != nil {}
            Issue.record("the file has lost its samples")
        } catch {
            guard case .sourceUnavailable(let reason) = error else {
                Issue.record("expected sourceUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("cut.wav"), "the error names the file: \(reason)")
        }

        // The reader loop reports the failure where it would have reported the end.
        _ = try fixtures.write([steppedSignal(count: 50_000, seed: 1)], sampleRate: 48_000, name: "cut.wav")
        let again = try FileReader(url: url, sampleRate: sampleRate, blockSize: 4_096)
        #expect(try again.next() != nil)
        try truncate(url)
        let channel = SourceEventChannel()
        let log = SourceLog(stream: channel.stream)
        let thread = SourceThread.start(name: "idle", qualityOfService: .utility) { _ in }
        let written = FileSource.read(again, pacing: .asFastAsPossible, clock: ManualClock(), channel: channel, thread: thread) { $0.frameCount }
        #expect(written < 50_000)
        #expect(await eventually {
            if case .failed(.sourceUnavailable)? = log.all.first { log.all.count == 1 } else { false }
        }, "one event, the failure; no end is reported for a file that failed")
    }

    @Test func aFileThatFailsWhileItPlaysFailsTheSession() async throws {
        let fixtures = try AudioFixtures()
        let url = try fixtures.write([steppedSignal(count: 50_000, seed: 2)], sampleRate: 48_000, name: "cut.wav")
        let clock = ManualClock()
        let source = FileSource(url: url, pacing: .realTime, sampleRate: nil, blockSize: 4_096, clock: clock)
        let attached = try await Attachment(source, blockSize: 512)
        try attached.session.start()
        #expect(await eventually { attached.sink.frameCount == 4_096 })
        await pause()                                           // the reader holds its second block and waits for it to be due
        try truncate(url)
        clock.advance(by: 10)
        #expect(await eventually {
            if case .failed(.sourceUnavailable) = attached.session.state { true } else { false }
        }, "a file that cannot be read any further fails the session; it does not end it")
        #expect(attached.sink.frameCount >= 4_096 && attached.sink.frameCount < 50_000)
    }

    @Test func aRateTheConverterDoesNotOfferIsUnsupported() async throws {
        let fixtures = try AudioFixtures()
        let url = try fixtures.write([steppedSignal(count: 5_000, seed: 1)], sampleRate: 48_000, name: "rates.wav")
        for rate in [0.001, 1e9, 1e15] {
            do throws(DSPError) {
                try await FileSource(url: url, sampleRate: rate).prepare()
                Issue.record("\(rate) Hz is no rate a file is converted to")
            } catch {
                guard case .unsupportedConfiguration(let reason, _) = error else {
                    Issue.record("expected unsupportedConfiguration for \(rate) Hz, got \(error)")
                    continue
                }
                #expect(reason.contains("rates.wav"))
            }
        }
    }

    /// The public initialiser paces on the machine's own clock: a tenth of a second of audio
    /// takes about a tenth of a second.
    @Test func aFileIsPacedOnTheRealClock() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 4_800, seed: 3)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "tenth.wav")
        let attached = try await Attachment(FileSource(url: url, blockSize: 480), blockSize: 480)
        let started = Date()
        try attached.session.start()
        #expect(await attached.session.reaches(.finished))
        let elapsed = Date().timeIntervalSince(started)
        // The last of ten blocks is due nine block durations after the first.
        // The lower bound is the pacing; how much longer a busy machine takes is not the source's.
        #expect(elapsed >= 0.085, "0.1 s of audio took \(elapsed) s")
        #expect(attached.sink.samples() == signal)
    }

    @Test func theMachinesClockSleepsInShortStretches() {
        let clock = MonotonicClock()
        let start = clock.now
        clock.sleep(until: start + 0.005)
        #expect(clock.now - start >= 0.004, "it sleeps until the deadline")
        let before = clock.now
        clock.sleep(until: before + 5)
        let slept = clock.now - before
        #expect(slept >= 0.015 && slept < 1, "and never for long in one go, so a thread that is being stopped notices: \(slept) s")
        clock.sleep(until: clock.now - 1)
        #expect(clock.now >= before)
    }

    /// A reader that does not end in time is left behind: `stop()` returns, and the source
    /// is without a file until it is prepared again.
    @Test func aReaderThatIsStuckDoesNotHoldTheSourceUp() async throws {
        let fixtures = try AudioFixtures()
        let signal = steppedSignal(count: 20 * 375, seed: 5)
        let url = try fixtures.write([signal], sampleRate: 48_000, name: "stuck.wav")
        let clock = StubbornClock()
        let source = FileSource(url: url, pacing: .realTime, sampleRate: nil, blockSize: 375, clock: clock, stopTimeout: 0.02)
        let attached = try await Attachment(source, blockSize: 125)
        try attached.session.start()
        #expect(await eventually { attached.sink.frameCount == 375 }, "the first block is due at once")
        #expect(await eventually { clock.isAsleep }, "the reader waits for the second")
        attached.session.stop()
        // Not a bound on the wall clock, which a busy machine does not keep: `stop()` came back
        // while the reader was still asleep, so it gave up after its time-out.
        #expect(clock.isAsleep, "stop gave up on the thread after its time-out, not after the thread's sleep")
        #expect(throws: DSPError.self) { try attached.session.start() }
        // Prepared again, the file starts over; the thread that was left behind ends by itself.
        #expect(await eventually(timeout: 20) { !clock.isAsleep })
        let fresh = FileSource(url: url, pacing: .asFastAsPossible)
        let again = try await Attachment(fresh, blockSize: 125)
        try again.session.start()
        #expect(await again.session.reaches(.finished))
        #expect(again.sink.samples() == signal)
    }
}
