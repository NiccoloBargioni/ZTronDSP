import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// EXT-4, the first of the three: `ExternalGain`, a `SampleProcessor` written outside the
/// package, against the stock `Gain`. A product of two floats is one IEEE operation however it
/// is computed, so the two give the same floats: the comparison is bit for bit, and so it is
/// for the ramp of a changed amount, which is the stock kernel's closed form.
@Suite("Gain parity")
struct GainParityTests {
    let noise = TestSignal.whiteNoise(count: 12_345, seed: 907, amplitude: 0.9)
    let blockSizes = [1, 7, 64, 333, 512, 1_000, 4_096]
    let amounts: [Amplification] = [.decibels(-3), .decibels(6), .linear(-0.5), .linear(0), .decibels(-160), .linear(1.000_000_1)]

    /// The comparison of the suite. A seeded violation, for the self-test of
    /// Scripts/external-parity.sh, makes the twin another gain: the suite must then fail.
    static var twinAmount: Amplification {
        ProcessInfo.processInfo.environment["ZTD_EXTERNAL_SEEDED_VIOLATION"] == "gain" ? .decibels(-3.01) : .decibels(-3)
    }

    @Test func outputEqualsTheStockGainBitForBit() throws {
        for amount in amounts {
            for blockSize in blockSizes {
                let stock = try Pipeline { Gain(amount) }.process(noise, format: mono48, blockSize: blockSize)
                let external = try Pipeline { ExternalGain(amount) }.process(noise, format: mono48, blockSize: blockSize)
                #expect(external == stock, "\(amount) in blocks of \(blockSize): \(deviation(external, from: stock)) of the peak apart")
                #expect(external.count == noise.count)
            }
        }
        let stock = try Pipeline { Gain(GainParityTests.twinAmount) }.process(noise, format: mono48)
        let external = try Pipeline { ExternalGain(.decibels(-3)) }.process(noise, format: mono48)
        #expect(external == stock, "the twin of the suite: \(deviation(external, from: stock)) of the peak apart")
    }

    @Test func otherSignalsAndRatesGiveTheSameFloats() throws {
        let signals: [(String, [Float])] = [
            ("a sine", TestSignal.sine(frequency: 997, sampleRate: 44_100, count: 5_000)),
            ("an impulse", TestSignal.impulse(count: 600, at: 3)),
            ("a chirp", TestSignal.chirp(from: 20, to: 20_000, sampleRate: 44_100, count: 8_000, amplitude: 0.7)),
            ("a tail that decays below the state floor", TestSignal.decayingTail(count: 3_000, ratio: 0.97)),
            ("silence", TestSignal.silence(count: 700)),
        ]
        let format = SignalFormat(sampleRate: 44_100)
        for (name, signal) in signals {
            let stock = try Pipeline { Gain(.decibels(-7.5)) }.process(signal, format: format, blockSize: 300)
            let external = try Pipeline { ExternalGain(.decibels(-7.5)) }.process(signal, format: format, blockSize: 300)
            #expect(external == stock, "\(name)")
        }
    }

    @Test func aGainPerChannelEqualsTheStockOne() throws {
        let left = TestSignal.whiteNoise(count: 4_000, seed: 1), right = TestSignal.whiteNoise(count: 4_000, seed: 2)
        let third = TestSignal.whiteNoise(count: 4_000, seed: 3)
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2), three = SignalFormat(sampleRate: 48_000, channelCount: 3)
        let amounts: [Amplification] = [.decibels(-6), .linear(2)]
        let stock = try Pipeline { Gain(channels: amounts) }.process(channels: [left, right], format: stereo, blockSize: 500)
        let external = try Pipeline { ExternalGain(channels: amounts) }.process(channels: [left, right], format: stereo, blockSize: 500)
        #expect(external == stock)
        #expect(external.count == 2 && external[1] == right.map { $0 * 2 })

        // One amount for every channel, on three channels.
        let wide = try Pipeline { Gain(.decibels(-9)) }.process(channels: [left, right, third], format: three)
        let wideExternal = try Pipeline { ExternalGain(.decibels(-9)) }.process(channels: [left, right, third], format: three)
        #expect(wideExternal == wide)
    }

    @Test func itStandsWhereAStockGainStandsInAChain() throws {
        // Between stock stages, in a tap, and on a feature-rate sequence: wherever a sequence stage may stand.
        let stock = try Pipeline {
            HighPass(.butterworth, cutoff: .hertz(90), order: 2)
            Gain(.decibels(-4))
            LowPass(.butterworth, cutoff: .hertz(6_000), order: 4)
        }.process(noise, format: mono48, blockSize: 480)
        let external = try Pipeline {
            HighPass(.butterworth, cutoff: .hertz(90), order: 2)
            ExternalGain(.decibels(-4))
            LowPass(.butterworth, cutoff: .hertz(6_000), order: 4)
        }.process(noise, format: mono48, blockSize: 480)
        #expect(external == stock)

        // After a step that starts a scalar sequence, the gain scales the values of that sequence.
        let stockLevels: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.02, hop: 0.01); Gain(.linear(0.5)) }.process(noise, format: mono48)
        let externalLevels: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.02, hop: 0.01); ExternalGain(.linear(0.5)) }.process(noise, format: mono48)
        #expect(externalLevels == stockLevels)
        #expect(!stockLevels.isEmpty)
    }

    @Test func aGainOfOneLeavesNoTraceAndTheSignalUnchanged() throws {
        #expect(try Pipeline { ExternalGain(.decibels(0)) }.process(noise, format: mono48) == noise)
        #expect(try Pipeline { ExternalGain(.linear(1)) }.process(noise, format: mono48, blockSize: 77) == noise)
    }

    @Test func bothSpellingsGiveOneDescription() throws {
        // API-1: the builder and the fluent spelling produce equal values.
        #expect(Pipeline { ExternalGain(.decibels(-3)) } == Pipeline().externalGain(.decibels(-3)))
        #expect(Pipeline { ExternalGain(channels: [.decibels(-3), .unity]) } == Pipeline().externalGain(channels: [.decibels(-3), .unity]))
        #expect(Pipeline { ExternalGain(.decibels(-3)) } != Pipeline { ExternalGain(.decibels(-4)) })
        // ACT-12: the default, `true` and `.active` are one description; a constant `false` is another.
        #expect(Pipeline { ExternalGain(.decibels(-3), isActive: true) } == Pipeline { ExternalGain(.decibels(-3)) })
        #expect(Pipeline { ExternalGain(.decibels(-3), isActive: .active) } == Pipeline { ExternalGain(.decibels(-3)) })
        #expect(Pipeline { ExternalGain(.decibels(-3), isActive: false) } != Pipeline { ExternalGain(.decibels(-3)) })
        // ACT-4: switched off for good, the stage is compiled away.
        #expect(try Pipeline { ExternalGain(.decibels(-3), isActive: .bypassed) }.process(noise, format: mono48) == noise)
        // ANI-2: the amount, in decibels, is the stage's continuous value.
        let gain = ExternalGain(.linear(0.5))
        #expect(gain.parameters == Gain(.linear(0.5)).parameters)
        #expect(gain.replacingParameters([-12][...]).amounts == [Amplification.linear(0.5).replacing(animatableValue: -12)])
        #expect(gain.replacingParameters(gain.parameters[...]) == gain)
    }

    @Test func wrongArgumentsAreErrorsThatNameTheStage() throws {
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let error = #expect(throws: DSPError.self) {
            try Pipeline { ExternalGain(channels: [.unity, .unity, .unity]) }.process(channels: [[0, 1], [1, 0]], format: stereo)
        }
        guard case .invalidParameter(let stage, let parameter, _)? = error else {
            Issue.record("three gains for two channels: \(String(describing: error))")
            return
        }
        #expect(parameter == "channels" && stage.stageName == "ExternalGain")
        let stock = #expect(throws: DSPError.self) {
            try Pipeline { Gain(channels: [.unity, .unity, .unity]) }.process(channels: [[0, 1], [1, 0]], format: stereo)
        }
        guard case .invalidParameter(let stockStage, let stockParameter, _)? = stock else {
            Issue.record("the stock gain: \(String(describing: stock))")
            return
        }
        #expect(stockParameter == parameter && stockStage.stageName == "Gain")
        #expect(throws: DSPError.self) { try Pipeline { ExternalGain(.linear(.infinity)) }.process(noise, format: mono48) }
        #expect(throws: DSPError.self) { try Pipeline { ExternalGain(.linear(.nan)) }.process(noise, format: mono48) }
        #expect(throws: DSPError.self) { try Pipeline { ExternalGain(channels: [.decibels(-3), .linear(.nan)]) }.process(channels: [[0, 1], [1, 0]], format: stereo) }
        // A ramp lasts a finite time that is not negative, and a number of frames a kernel counts.
        for ramp in [-0.001, .nan, .infinity, 1.0e6] {
            let error = #expect(throws: DSPError.self, "a ramp of \(ramp) s") { try Pipeline { ExternalGain(.decibels(-3), ramp: ramp) }.process(noise, format: mono48) }
            guard case .invalidParameter(let stage, let parameter, _)? = error else {
                Issue.record("a ramp of \(ramp) s: \(String(describing: error))")
                continue
            }
            #expect(parameter == "ramp" && stage.stageName == "ExternalGain")
        }
        #expect(try Pipeline { ExternalGain(.decibels(-3), ramp: 0) }.process(noise, format: mono48) == Pipeline { Gain(.decibels(-3), ramp: 0) }.process(noise, format: mono48))
    }

    // MARK: The ramp of a changed amount (§5.5.4, CLICK-1)

    /// What happens between two blocks: new factors for every channel, one per channel, a count
    /// that fits neither, or a reset.
    enum Event: Sendable {
        case every(Float)
        case each([Float])
        case reset
    }

    /// The events of a run, each before the first block that begins at or after its frame: a
    /// move, a new target in the middle of it, a move to silence, a reset in the middle of a move,
    /// one value per channel twice, three values for two channels, and a last move.
    static let events: [(frame: Int, event: Event)] = [
        (600, .every(0.25)), (800, .each([1, -0.5])), (2_000, .every(0)), (2_200, .reset),
        (3_000, .each([-1, 3])), (3_100, .each([-1, 3])), (3_500, .each([1, 2, 3])), (5_000, .every(1)),
    ]

    @Test(arguments: [[1], [7], [64], [333], [512], [1_000], [3, 500, 17, 64]])
    func theRampIsTheStockKernelsRampBitForBit(_ blockSizes: [Int]) throws {
        // The processor's ramp is the closed form of the stock gain kernel: with `left` frames of
        // the move still to come after a frame, its gain is target − increment · left, and exactly
        // the target for the last. Driven with the same values between the same blocks, the two
        // give the same floats, out of place and in place, whatever the blocks, for a ramp of 10 ms,
        // of one frame, and none.
        let left = TestSignal.whiteNoise(count: 6_000, seed: 11, amplitude: 0.9), right = TestSignal.whiteNoise(count: 6_000, seed: 12, amplitude: 0.9)
        let start: [Float] = [0.5, -2]
        for ramp in [480, 1, 0] {
            var kernel = start.withUnsafeBufferPointer { ztd_gain_create(2, $0.baseAddress, UInt32(ramp), ZTD_IMPLEMENTATION_NATIVE) }
            defer { ztd_kernel_destroy(&kernel) }
            try #require(!ztd_kernel_is_null(&kernel))
            let outOfPlace = try ExternalGainProcessor(factors: start, rampFrames: ramp)
            let inPlace = try ExternalGainProcessor(factors: start, rampFrames: ramp)
            let largest = blockSizes.max() ?? 1
            let input = try AudioBuffer(channelCount: 2, capacity: largest), inside = try AudioBuffer(channelCount: 2, capacity: largest)
            let stock = try AudioBuffer(channelCount: 2, capacity: largest), own = try AudioBuffer(channelCount: 2, capacity: largest)
            var heard: (stock: [[Float]], own: [[Float]], inPlace: [[Float]]) = ([[], []], [[], []], [[], []])
            var position = 0, turn = 0, next = 0
            while position < left.count {
                while next < GainParityTests.events.count, GainParityTests.events[next].frame <= position {
                    apply(GainParityTests.events[next].event, to: &kernel, outOfPlace, inPlace)
                    next += 1
                }
                let frames = min(blockSizes[min(turn, blockSizes.count - 1)], left.count - position)
                for index in 0 ..< frames {
                    input.channel(0)[index] = left[position + index]
                    input.channel(1)[index] = right[position + index]
                    inside.channel(0)[index] = left[position + index]
                    inside.channel(1)[index] = right[position + index]
                }
                let written = kernel.process?(kernel.state, input.block(frameCount: frames).constantChannelTable, stock.block(frameCount: frames).channelTable, 2, UInt32(frames)) ?? 0
                #expect(Int(written) == frames)
                var target = own.block(frameCount: frames)
                outOfPlace.process(input.block(frameCount: frames), into: &target)
                var block = inside.block(frameCount: frames)
                inPlace.process(&block)
                for channel in 0 ..< 2 {
                    heard.stock[channel] += UnsafeBufferPointer(start: stock.channel(channel), count: frames)
                    heard.own[channel] += UnsafeBufferPointer(start: own.channel(channel), count: frames)
                    heard.inPlace[channel] += UnsafeBufferPointer(start: inside.channel(channel), count: frames)
                }
                position += frames
                turn += 1
            }
            #expect(heard.own == heard.stock, "out of place, a ramp of \(ramp) frames, blocks of \(blockSizes)")
            #expect(heard.inPlace == heard.stock, "in place, a ramp of \(ramp) frames, blocks of \(blockSizes)")
            // The last move lands on a gain of exactly 1.
            #expect(Array(heard.own[0].suffix(150)) == Array(left.suffix(150)) && Array(heard.own[1].suffix(150)) == Array(right.suffix(150)), "the last move arrived")
        }
    }

    /// Hands `event` to the stock kernel, as the engine sends it a value update, and to the two processors.
    private func apply(_ event: Event, to kernel: inout ztd_kernel_t, _ processors: ExternalGainProcessor...) {
        var command = ztd_command_t()
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        switch event {
        case .every(let factor):
            command.count = 1
            command.scalar.0 = Double(factor)
            kernel.command?(kernel.state, &command)
            for processor in processors { [Double(factor)].withUnsafeBufferPointer { processor.setValues($0) } }
        case .each(let factors):
            factors.withUnsafeBufferPointer { factors in
                command.count = UInt32(factors.count)
                command.values = UnsafeRawPointer(factors.baseAddress)
                kernel.command?(kernel.state, &command)
            }
            for processor in processors { factors.map { Double($0) }.withUnsafeBufferPointer { processor.setValues($0) } }
        case .reset:
            kernel.reset?(kernel.state)
            for processor in processors { processor.reset() }
        }
    }

    @Test func aChannelBeyondTheFactorsPassesUnchangedAndAnEmptyUpdateIsIgnored() throws {
        // A plan hands the processor as many channels as it was made for; one beyond them, out of
        // place, is copied as it is. No values, or a count that fits neither one nor every
        // channel, change nothing.
        let processor = try ExternalGainProcessor(factors: [0.5], rampFrames: 0)
        let signal = TestSignal.whiteNoise(count: 256, seed: 5, amplitude: 0.9)
        let input = try AudioBuffer(channels: [signal, signal]), output = try AudioBuffer(channelCount: 2, capacity: 256)
        var block = output.block()
        processor.process(input.block(), into: &block)
        #expect(output.array(ofChannel: 0) == signal.map { $0 * 0.5 } && output.array(ofChannel: 1) == signal)
        [Double]().withUnsafeBufferPointer { processor.setValues($0) }
        [2.0, 3.0].withUnsafeBufferPointer { processor.setValues($0) }
        processor.process(input.block(), into: &block)
        #expect(output.array(ofChannel: 0) == signal.map { $0 * 0.5 })
        // Without a ramp, a new factor is there from the first frame of the next block.
        [0.25].withUnsafeBufferPointer { processor.setValues($0) }
        processor.process(input.block(), into: &block)
        #expect(output.array(ofChannel: 0) == signal.map { $0 * 0.25 })
        #expect(processor.latencyFrames == 0 && processor.settlingFrames == 0)
    }

    @Test func theSameSamplesThroughEverySourceGiveTheSameOutput() async throws {
        // §10.1, property layer: offline ≡ engine, and a source of irregular batches changes nothing.
        let pipeline = Pipeline { ExternalGain(.decibels(-3)) }
        let offline = try pipeline.process(noise, format: mono48)
        let stock = try Pipeline { Gain(.decibels(-3)) }.process(noise, format: mono48)
        let buffered = try await throughEngine(pipeline, on: BufferSource(noise, sampleRate: 48_000))
        let scripted = try await throughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [1, 7, 300, 513, 64, 2, 4_000]))
        let small = try await throughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [129]), blockSize: 100)
        #expect(buffered == [offline] && scripted == [offline] && small == [offline])
        #expect(offline == stock)
    }

    @Test func itIsCheckedAtAttachTimeLikeAnyStage() throws {
        // §5.8.2, tier 2: the description carries the rule of a sequence stage.
        var dynamic = try DynamicPipeline().appending(ExternalGain(.decibels(-3)))
        #expect(dynamic.outputTag == .samples)
        try dynamic.append(STFT(frame: 256, hop: 64))
        let error = #expect(throws: DSPError.self) { try dynamic.append(ExternalGain(.decibels(-3))) }
        guard case .invalidStageOrder(let stage, let found)? = error else {
            Issue.record("a gain after a spectrum: \(String(describing: error))")
            return
        }
        #expect(stage.stageName == "ExternalGain" && found == .spectrum(axis: .linear, values: .complex))
    }
}
