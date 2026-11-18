import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// EXT-4, the first of the three: `ExternalGain`, a `SampleProcessor` written outside the
/// package, against the stock `Gain`. A product of two floats is one IEEE operation however it
/// is computed, so the two give the same floats: the comparison is bit for bit.
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
