import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The stock sources and the adapter that turns any source into blocks (WP-315…318, WP-340).
@Suite("Sources")
struct SourceTests {
    /// Everything a pull source delivers, asked for in blocks of `blockSize`.
    private func render(_ source: any PullSampleSource, blockSize: Int = 64, limit: Int = 1_000_000) async throws -> [[Float]] {
        try await source.prepare()
        let buffer = try AudioBuffer(channelCount: source.format.channelCount, capacity: blockSize)
        var channels = [[Float]](repeating: [], count: source.format.channelCount)
        while channels[0].count < limit {
            var block = buffer.block(frameCount: 0)
            let frames = source.render(into: &block)
            guard frames > 0 else { break }
            for channel in channels.indices { channels[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.channel(channel), count: frames)) }
        }
        return channels
    }

    // MARK: GeneratorSource (WP-316)

    @Test func aSineIsWhatItsFormulaSays() async throws {
        let source = GeneratorSource(.sine(frequency: .hertz(440), amplitude: 0.5, phase: 0.25), sampleRate: 44_100, channelCount: 2, duration: 0.1)
        let output = try await render(source)
        #expect(output[0].count == 4_410 && output[0] == output[1], "the same signal on every channel")
        let expected = (0 ..< 4_410).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 44_100 + 0.25)) }
        #expect(output[0] == expected)
    }

    @Test func aChirpSweepsLinearlyOrLogarithmically() async throws {
        let rate = 48_000.0, count = 48_000
        let linear = try await render(GeneratorSource(.chirp(from: .hertz(100), to: .hertz(4_100), duration: 1), sampleRate: rate, duration: 1.5))[0]
        // The phase of a linear sweep is 2π(f₀t + (f₁ − f₀)t² / 2T); after T it goes on at f₁.
        for n in [0, 1, 1_000, 24_000, count - 1] {
            let t = Double(n) / rate
            #expect(abs(Double(linear[n]) - sin(2 * .pi * (100 * t + 4_000 * t * t / 2))) < 1e-6)
        }
        let late = Double(count + 4_800) / rate
        #expect(abs(Double(linear[count + 4_800]) - sin(2 * .pi * (100 + 2_000) + 2 * .pi * 4_100 * (late - 1))) < 1e-6, "phase-continuous past its end")
        // Zero crossings per 0.1 s double with every octave of a logarithmic sweep.
        let sweep = try await render(GeneratorSource(.logarithmicChirp(from: .hertz(200), to: .hertz(3_200), duration: 1), sampleRate: rate, duration: 1))[0]
        func crossings(_ range: Range<Int>) -> Int { range.dropFirst().filter { (sweep[$0 - 1] < 0) != (sweep[$0] < 0) }.count }
        let early = crossings(0 ..< 12_000), later = crossings(12_000 ..< 24_000)
        #expect(abs(Double(later) / Double(early) - 2) < 0.05, "one octave per quarter second: \(early) then \(later) crossings")
        await #expect(throws: DSPError.self) { try await GeneratorSource(.logarithmicChirp(from: .hertz(0), to: .hertz(100), duration: 1)).prepare() }
    }

    @Test func noiseIsSeededAndHasItsSpectrum() async throws {
        let white = try await render(GeneratorSource(.whiteNoise(amplitude: 0.5, seed: 7), channelCount: 2, duration: 2))
        let again = try await render(GeneratorSource(.whiteNoise(amplitude: 0.5, seed: 7), channelCount: 2, duration: 2), blockSize: 333)
        let other = try await render(GeneratorSource(.whiteNoise(amplitude: 0.5, seed: 8), duration: 2))
        #expect(white == again, "the same seed gives the same samples, whatever the block size")
        #expect(white[0] != other[0] && white[0] != white[1], "another seed, and another channel, another stream")
        let mean = white[0].reduce(0, +) / Float(white[0].count)
        let variance = white[0].map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(white[0].count)
        #expect(abs(mean) < 0.005 && abs(variance - 0.25 / 3) < 0.002, "uniform in ±0.5: mean 0, variance a²/3")
        #expect(white[0].allSatisfy { $0 >= -0.5 && $0 < 0.5 })

        // Pink noise: the power in each octave band is the same, where white noise doubles it.
        func octavePowers(_ samples: [Float]) -> [Double] {
            [250.0, 500, 1_000, 2_000, 4_000].map { low in
                var power = 0.0
                // A direct transform at a few frequencies per band is enough for a slope.
                for step in 0 ..< 24 {
                    let frequency = low * pow(2, (Double(step) + 0.5) / 24)
                    var re = 0.0, im = 0.0
                    for (n, sample) in samples.prefix(48_000).enumerated() {
                        let angle = 2 * Double.pi * frequency * Double(n) / 48_000
                        re += Double(sample) * cos(angle)
                        im += Double(sample) * sin(angle)
                    }
                    power += (re * re + im * im) * frequency          // density × bandwidth of the step
                }
                return power
            }
        }
        let pink = try await render(GeneratorSource(.pinkNoise(seed: 3), duration: 1))[0]
        let bands = octavePowers(pink)
        let spread = 10 * log10(bands.max()! / bands.min()!)
        #expect(spread < 3, "equal power per octave within the scatter of one second: \(spread) dB")
        let whiteBands = octavePowers(white[0])
        #expect(10 * log10(whiteBands[4] / whiteBands[0]) > 9, "the same measure on white noise rises by 3 dB per octave")
        #expect(pink.allSatisfy { abs($0) <= 1 })
    }

    @Test func impulsesStepsSilenceAndFunctions() async throws {
        let impulse = try await render(GeneratorSource(.impulse(amplitude: 2, at: 5), duration: 0.001))[0]
        #expect(impulse.count == 48 && impulse[5] == 2 && impulse.filter { $0 != 0 }.count == 1)
        let train = try await render(GeneratorSource(.impulseTrain(period: 10), duration: 0.001))[0]
        #expect(train.enumerated().allSatisfy { $0.element == ($0.offset % 10 == 0 ? 1 : 0) })
        let step = try await render(GeneratorSource(.step(amplitude: 0.5, at: 3), duration: 0.001), blockSize: 7)[0]
        #expect(step == [0, 0, 0] + [Float](repeating: 0.5, count: 45))
        #expect(try await render(GeneratorSource(.silence, duration: 0.001))[0] == [Float](repeating: 0, count: 48))
        let ramp = try await render(GeneratorSource(.function { frame, time in Float(frame) + Float(time) }, sampleRate: 1_000, duration: 0.004))[0]
        #expect(ramp == [0, 1.001, 2.002, 3.003])
        let endless = GeneratorSource(.silence)
        #expect(try await render(endless, limit: 10_000)[0].count >= 10_000, "without a duration a generator has no end")
        #expect(endless.pacing == .realTime && GeneratorSource(.silence, pacing: .asFastAsPossible).pacing == .asFastAsPossible)
    }

    @Test func aGeneratorRejectsWhatItCannotRender() async {
        await #expect(throws: DSPError.self) { try await GeneratorSource(.sine(frequency: .hertz(30_000))).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.silence, sampleRate: 0).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.silence, duration: -1).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.impulseTrain(period: 0)).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.chirp(from: .hertz(1), to: .hertz(2), duration: 0)).prepare() }
    }

    @Test func preparingAGeneratorStartsItOver() async throws {
        let source = GeneratorSource(.whiteNoise(seed: 1), duration: 0.01)
        let first = try await render(source), second = try await render(source)
        #expect(first == second && first[0].count == 480)
    }

    // MARK: BufferSource and ScriptedSource (WP-317)

    @Test func aBufferSourceDeliversItsSamples() async throws {
        let left = TestSignal.whiteNoise(count: 1_000, seed: 1), right = TestSignal.whiteNoise(count: 1_000, seed: 2)
        let source = BufferSource(channels: [left, right], sampleRate: 22_050)
        #expect(source.format == SignalFormat(sampleRate: 22_050, channelCount: 2) && source.pacing == .asFastAsPossible)
        #expect(try await render(source, blockSize: 300) == [left, right])
        let looping = BufferSource([1, 2, 3], sampleRate: 48_000, loops: true)
        #expect(try await render(looping, blockSize: 2, limit: 8)[0] == [1, 2, 3, 1, 2, 3, 1, 2])
        await #expect(throws: DSPError.self) { try await BufferSource(channels: [[1, 2], [1]], sampleRate: 48_000).prepare() }
        await #expect(throws: DSPError.self) { try await BufferSource(channels: [], sampleRate: 48_000).prepare() }
    }

    @Test func aScriptedSourceFollowsItsScript() async throws {
        let format = SignalFormat(sampleRate: 48_000)
        let error = DSPError.sourceUnavailable(reason: "scripted")
        let source = ScriptedSource(format: format, [
            .samples([[1, 2, 3]]), .event(.overrun(droppedFrames: 9)), .samples([[4, 5, 6, 7, 8]]),
            .formatChange(SignalFormat(sampleRate: 96_000)), .samples([[9]]), .failure(error),
        ])
        var events: [SourceEvent] = []
        let listener = Task { () -> [SourceEvent] in
            var seen: [SourceEvent] = []
            for await event in source.events {
                seen.append(event)
                if seen.count == 3 { break }
            }
            return seen
        }
        try await source.prepare()
        let buffer = try AudioBuffer(channelCount: 1, capacity: 4)
        var sizes: [Int] = [], samples: [Float] = []
        for _ in 0 ..< 7 {
            var block = buffer.block(frameCount: 0)
            let frames = source.render(into: &block)
            sizes.append(frames)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.channel(0), count: frames))
        }
        #expect(sizes == [3, 4, 1, 0, 1, 4, 4], "each call brings one batch, or what fits of it; a format change ends the old stream")
        #expect(samples == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0, 0, 0], "after a failure the source delivers silence")
        #expect(source.format.sampleRate == 96_000 && source.renderCount == 7)
        let heard = Locked<[SourceEvent]?>(nil)
        let waiter = Task { heard.set(await listener.value) }
        #expect(await eventually(timeout: 5) { heard.get() != nil }, "the three events of the script arrive")
        if heard.get() == nil { listener.cancel() }
        await waiter.value
        events = heard.get() ?? []
        #expect(events == [.overrun(droppedFrames: 9), .formatChanged(SignalFormat(sampleRate: 96_000)), .failed(error)])
        try await source.prepare()
        #expect(source.format == format, "prepared again, the script starts over")
    }

    @Test func aScriptOfBatchSizesDeliversThoseSizes() async throws {
        let samples = TestSignal.whiteNoise(count: 1_000, seed: 8)
        let source = ScriptedSource(samples, sampleRate: 48_000, batchSizes: [7, 300, 1, 64])
        try await source.prepare()
        let buffer = try AudioBuffer(channelCount: 1, capacity: 512)
        var sizes: [Int] = [], delivered: [Float] = []
        while true {
            var block = buffer.block(frameCount: 0)
            let frames = source.render(into: &block)
            guard frames > 0 else { break }
            sizes.append(frames)
            delivered.append(contentsOf: UnsafeBufferPointer(start: buffer.channel(0), count: frames))
        }
        #expect(sizes == [7, 300, 1] + [Int](repeating: 64, count: 10) + [52], "each call brings the batch the script names; the last size repeats")
        #expect(delivered == samples)
        // A batch with fewer channels than the block has is silence on the others; a batch
        // longer than the block is delivered over several calls.
        let stereo = ScriptedSource(format: SignalFormat(sampleRate: 48_000, channelCount: 2), [.samples([[1, 2, 3]]), .samples([[], []]), .samples([[4], [5]])])
        try await stereo.prepare()
        let pair = try AudioBuffer(channelCount: 2, capacity: 2)
        var left: [Float] = [], right: [Float] = [], calls: [Int] = []
        while true {
            var block = pair.block(frameCount: 0)
            let frames = stereo.render(into: &block)
            guard frames > 0 else { break }
            calls.append(frames)
            left.append(contentsOf: UnsafeBufferPointer(start: pair.channel(0), count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: pair.channel(1), count: frames))
        }
        #expect(calls == [2, 1, 1] && left == [1, 2, 3, 4] && right == [0, 0, 0, 5], "an empty batch delivers nothing and ends nothing")
        await #expect(throws: DSPError.self) { try await ScriptedSource(format: SignalFormat(sampleRate: 0), []).prepare() }
    }

    @Test func renderingStockPullSourcesAllocatesNothing() async throws {
        // RT-2: `render` runs on the analysis thread.
        let scripted = ScriptedSource(TestSignal.whiteNoise(count: 64 * 400, seed: 3), sampleRate: 48_000, batchSizes: [17, 64, 5])
        let buffered = BufferSource(TestSignal.whiteNoise(count: 64 * 400, seed: 4), sampleRate: 48_000)
        let sources: [any PullSampleSource] = [
            scripted, buffered, GeneratorSource(.sine(frequency: .hertz(440))), GeneratorSource(.pinkNoise(seed: 1), channelCount: 2),
            GeneratorSource(.chirp(from: .hertz(100), to: .hertz(2_000), duration: 1)), GeneratorSource(.impulseTrain(period: 7)),
        ]
        for source in sources {
            try await source.prepare()
            let adapter = try SourceAdapter.make(for: source, blockSize: 64)
            let buffer = try AudioBuffer(channelCount: source.format.channelCount, capacity: 64)
            expectNoAllocations("\(type(of: source))") {
                var count = 0
                while count < 300 {
                    _ = adapter.next(into: buffer)
                    count += 1
                }
            }
        }
    }

    // MARK: The block assembler (WP-318)

    @Test func anyBatchPatternYieldsTheSameBlocks() async throws {
        let signal = TestSignal.whiteNoise(count: 5_003, seed: 21)
        var reference: [[Float]]?
        for sizes in [[5_003], [1], [64], [63, 65], [1, 1_000, 7, 300], [4_096, 3], [200, 1, 1, 1, 500]] {
            let source = ScriptedSource(signal, sampleRate: 48_000, batchSizes: sizes)
            try await source.prepare()
            let adapter = try SourceAdapter.make(for: source, blockSize: 128)
            let buffer = try AudioBuffer(channelCount: 1, capacity: 128)
            var blocks: [[Float]] = []
            loop: while true {
                switch adapter.next(into: buffer) {
                case .block(let frames): blocks.append(buffer.array(ofChannel: 0, frameCount: frames))
                case .waiting: Issue.record("a pull source never keeps the engine waiting")
                case .ended: break loop
                }
            }
            #expect(blocks.dropLast().allSatisfy { $0.count == 128 } && blocks.last?.count == 5_003 % 128, "full blocks, then the rest: \(sizes)")
            #expect(blocks.flatMap { $0 } == signal)
            if let reference { #expect(blocks == reference, "batches of \(sizes)") } else { reference = blocks }
            #expect(adapter.kind == .pull && adapter.pacing == .asFastAsPossible)
        }
    }

    @Test func aRingIsReadInWholeBlocks() throws {
        let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        let adapter = try SourceAdapter.make(for: source, blockSize: 100)
        let buffer = try AudioBuffer(channelCount: 2, capacity: 100)
        #expect(adapter.kind == .push && adapter.pacing == .realTime && source.connects == 1)
        func isWaiting() -> Bool { if case .waiting = adapter.next(into: buffer) { true } else { false } }
        #expect(isWaiting())
        source.write([Float](repeating: 0.5, count: 99))
        #expect(isWaiting(), "less than a block: nothing yet")
        source.write([Float](repeating: 0.25, count: 150))
        guard case .block(100) = adapter.next(into: buffer) else { Issue.record("a full block was due"); return }
        #expect(buffer.array(ofChannel: 1) == [Float](repeating: 0.5, count: 99) + [0.25])
        guard case .block(100) = adapter.next(into: buffer) else { Issue.record("a second block was due"); return }
        #expect(isWaiting())
        adapter.endAfterDraining()
        guard case .block(49) = adapter.next(into: buffer) else { Issue.record("the rest was due"); return }
        guard case .ended = adapter.next(into: buffer) else { Issue.record("the stream was over"); return }
        // The newest frames are dropped when the ring is full, and counted (RT-8).
        adapter.rewind()
        let capacity = 24_000 + 100_000
        #expect(source.write([Float](repeating: 0, count: capacity)) < capacity)
        #expect(adapter.droppedFrames > 0)
        #expect(throws: DSPError.self) { _ = try SourceAdapter.make(for: ManualPushSource(format: SignalFormat(sampleRate: 0)), blockSize: 64) }
        #expect(throws: DSPError.self) { _ = try SourceAdapter.make(for: source, blockSize: 0) }
    }

    @Test func aSourceThatIsNeitherPushNorPullIsRefused() async {
        final class Neither: SampleSource, @unchecked Sendable {
            let channel = SourceEventChannel()
            var format: SignalFormat { SignalFormat(sampleRate: 48_000) }
            var events: AsyncStream<SourceEvent> { channel.stream }
            func prepare() async throws(DSPError) {}
            func start() throws(DSPError) {}
            func stop() {}
        }
        await #expect(throws: DSPError.self) { _ = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: Neither()) }
    }

    // MARK: The non-finite guard and overruns (WP-340, RT-8)

    @Test func nonFiniteSamplesBecomeZeroAndAreCounted() async throws {
        let fixture = StressFixture.nonFiniteSignal(count: 4_000)
        let engine = DSPEngine(blockSize: 128)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: BufferSource(fixture.samples, sampleRate: 48_000))
        let log = EventLog(session)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples == fixture.samples.map { $0.isFinite ? $0 : 0 }, "NaN and infinity become 0 where the signal enters (NUM-1)")
        #expect(await eventually {
            log.all.reduce(0) { total, event in if case .nonFiniteInput(let count) = event { total + count } else { total } } == fixture.nonFiniteCount
        }, "and are counted in a session event")
    }

    @Test func theGuardTouchesNothingThatIsFinite() {
        let denormal = Float(bitPattern: 0x0000_1234)
        var samples: [Float] = [0, -0.0, 1, -1, .leastNonzeroMagnitude, .greatestFiniteMagnitude, .nan, .infinity, -.infinity, .signalingNaN, denormal]
        let replaced = samples.withUnsafeMutableBufferPointer { ztd_copy_finite($0.baseAddress, $0.baseAddress, UInt32($0.count)) }
        #expect(replaced == 4)
        let expected: [Float] = [0, -0.0, 1, -1, .leastNonzeroMagnitude, .greatestFiniteMagnitude, 0, 0, 0, 0, denormal]
        #expect(samples.map { $0.bitPattern } == expected.map { $0.bitPattern },
                "finite samples keep every bit, the sign of zero and denormals included")
        var out = [Float](repeating: 9, count: 3)
        #expect(ztd_copy_finite([1, .nan, 2], &out, 3) == 1 && out == [1, 0, 2])
        #expect(ztd_copy_finite(nil, nil, 0) == 0)
    }

    @Test func anOverrunIsReported() async throws {
        let rig = Rig()
        let session = try await rig.engine.attach(Pipeline(), to: rig.source)
        let log = EventLog(session)
        try session.start()
        let flood = [Float](repeating: 0.1, count: 200_000)
        let written = rig.source.write(flood)
        #expect(written < flood.count, "the ring never grows")
        rig.engine.core.runTurn()
        rig.engine.core.runTurn()
        await rig.drain()
        #expect(await eventually { log.contains(.overrun(droppedFrames: flood.count - written)) })
        rig.source.send(.overrun(droppedFrames: 3))
        #expect(await eventually { log.contains(.overrun(droppedFrames: 3)) }, "a source's own report is passed on")
    }
}
