import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `Magnitude`, `Power`, `Decibels`, `InverseDecibels` and the `Spectrogram` recipe (WP-534).
@Suite("Value steps")
struct ValueStepTests {
    typealias Linear<V: SpectralValues> = Spectrum<LinearFrequency, V>
    private let signal = TestSignal.whiteNoise(count: 6_000, seed: 534, amplitude: 0.6)
    private let stft = STFT(frame: 512, hop: 128)

    // MARK: Analytic values

    @Test func magnitudeAndPowerAreWhatTheirNamesSay() throws {
        let complex = try complexFrames(of: Pipeline { stft }, on: signal)
        let magnitudes: [[Float]] = try Pipeline { stft; Magnitude() }.process(signal, format: mono48)
        let powers: [[Float]] = try Pipeline { stft; Power() }.process(signal, format: mono48)
        #expect(magnitudes.count == complex.frameCount && powers.count == complex.frameCount && magnitudes[0].count == 257)
        for frame in [0, 7, complex.frameCount - 1] {
            let expected = zip(complex.reals[frame], complex.imaginaries[frame]).map { Double($0) * Double($0) + Double($1) * Double($1) }
            expectClose(powers[frame], expected, .relative(1e-6))
            expectClose(magnitudes[frame], expected.map { $0.squareRoot() }, .relative(1e-6))
        }
        #expect(magnitudes.allSatisfy { $0.allSatisfy { $0 >= 0 } })
    }

    @Test func aFullScaleSineReadsZeroDecibelsWithEitherValue() throws {
        let sine = TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 4_096)
        let amplitude = STFT(frame: 1_024, hop: 512, normalization: .amplitude)
        let fromMagnitudes: [[Float]] = try Pipeline { amplitude; Magnitude(); Decibels() }.process(sine, format: mono48)
        let fromPowers: [[Float]] = try Pipeline { amplitude; Power(); Decibels() }.process(sine, format: mono48)
        expectClose(try #require(fromMagnitudes.last)[64], 0, .absolute(1e-3), "20·log₁₀ of a magnitude")
        expectClose(try #require(fromPowers.last)[64], 0, .absolute(1e-3), "10·log₁₀ of a power: the same level")
        expectClose(try #require(fromPowers.last), try #require(fromMagnitudes.last), .absolute(2e-3))
        // Half the amplitude is 6.02 dB less; a reference of 0.5 brings it back to 0.
        let half = sine.map { $0 * 0.5 }
        let quiet: [[Float]] = try Pipeline { amplitude; Magnitude(); Decibels() }.process(half, format: mono48)
        let referenced: [[Float]] = try Pipeline { amplitude; Magnitude(); Decibels(reference: 0.5) }.process(half, format: mono48)
        expectClose(try #require(quiet.last)[64], -6.0206, .absolute(1e-3))
        expectClose(try #require(referenced.last)[64], 0, .absolute(1e-3))
        let power: [[Float]] = try Pipeline { amplitude; Power(); Decibels(reference: 0.25) }.process(half, format: mono48)
        expectClose(try #require(power.last)[64], 0, .absolute(1e-3), "the reference of a power is a power")
    }

    @Test func silenceIsTheFloorAndNeverMinusInfinity() throws {
        let silence = TestSignal.silence(count: 2_048)
        let floored: [[Float]] = try Pipeline { stft; Power(); Decibels() }.process(silence, format: mono48)
        #expect(floored.allSatisfy { $0.allSatisfy { $0 == -160 } }, "the default floor (§6.1)")
        let raised: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(floor: -80) }.process(silence, format: mono48)
        #expect(raised.allSatisfy { $0.allSatisfy { $0 == -80 } })
        let noise: [[Float]] = try Pipeline { stft; Power(); Decibels(floor: -20) }.process(signal, format: mono48)
        #expect(noise.allSatisfy { $0.allSatisfy { $0 >= -20 && $0.isFinite } } && noise.contains { $0.contains { $0 > -20 } })
    }

    @Test func inverseDecibelsUndoesDecibelsAboveTheFloor() throws {
        let magnitudes: [[Float]] = try Pipeline { stft; Magnitude() }.process(signal, format: mono48)
        let powers: [[Float]] = try Pipeline { stft; Power() }.process(signal, format: mono48)
        let backToMagnitudes: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(); InverseDecibels(.magnitude) }.process(signal, format: mono48)
        let backToPowers: [[Float]] = try Pipeline { stft; Power(); Decibels(reference: 3); InverseDecibels(.power, reference: 3) }.process(signal, format: mono48)
        for frame in 0 ..< magnitudes.count {
            expectClose(backToMagnitudes[frame], magnitudes[frame], .relativeToMaximum(1e-5))
            expectClose(backToPowers[frame], powers[frame], .relativeToMaximum(1e-5))
        }
        // What was clamped at the floor comes back as the floor.
        let clamped: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(floor: 10); InverseDecibels(.magnitude) }.process(signal, format: mono48)
        let floor = Float(pow(10, 0.5))
        #expect(clamped.allSatisfy { $0.allSatisfy { $0 >= floor * 0.99999 } } && clamped.contains { $0.contains { abs($0 - floor) < 1e-4 } })
    }

    // MARK: Order (O-3, O-4), both tiers

    @Test func theRulesOfTheDescriptionsAreTheRulesOfTheTypes() {
        let axes: [DomainTag.Axis] = [.linear, .mel, .constantQ]
        let values: [DomainTag.Values] = [.complex, .magnitude, .power, .decibel]
        for axis in axes {
            for value in values {
                let tag = DomainTag.spectrum(axis: axis, values: value)
                #expect(Magnitude.rule(tag) == (value == .complex ? .spectrum(axis: axis, values: .magnitude) : nil), "Magnitude after \(tag) (O-3)")
                #expect(Power.rule(tag) == (value == .complex ? .spectrum(axis: axis, values: .power) : nil), "Power after \(tag) (O-3)")
                #expect(Decibels.rule(tag) == (value == .magnitude || value == .power ? .spectrum(axis: axis, values: .decibel) : nil), "Decibels after \(tag) (O-4)")
                #expect(InverseDecibels<MagnitudeValues>.rule(tag) == (value == .decibel ? .spectrum(axis: axis, values: .magnitude) : nil))
                #expect(InverseDecibels<PowerValues>.rule(tag) == (value == .decibel ? .spectrum(axis: axis, values: .power) : nil))
            }
        }
        for tag in [DomainTag.samples, .scalar, .novelty, .quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum, .envelope] {
            #expect(Magnitude.rule(tag) == nil && Power.rule(tag) == nil && Decibels.rule(tag) == nil && InverseDecibels<PowerValues>.rule(tag) == nil, "\(tag) (O-2)")
        }
        #expect(Magnitude.rule != Power.rule && InverseDecibels<MagnitudeValues>.rule != InverseDecibels<PowerValues>.rule, "a rule of its own has a name of its own")
    }

    @Test func aWrongOrderIsRefusedOnTheDescriptionsToo() throws {
        let spectrum = try DynamicPipeline().appending(stft)
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Decibels().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(Power().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Magnitude().stageDescription).appending(Decibels().stageDescription).appending(Decibels().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(InverseDecibels(.power).stageDescription) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(Magnitude().stageDescription) }
        let valid = try spectrum.appending(Power().stageDescription).appending(Decibels().stageDescription).appending(InverseDecibels(.magnitude).stageDescription)
        #expect(valid.outputTag == .spectrum(axis: .linear, values: .magnitude))
        // A pipeline whose types lie is caught when it is attached (ORD-6).
        let forged = Pipeline<Samples, Spectrum<LinearFrequency, DecibelValues>>(unchecked: Pipeline { stft }.stages + [Decibels().stageDescription])
        #expect(throws: DSPError.invalidStageOrder(stage: StagePath().appending("Decibels", index: 1), found: .spectrum(axis: .linear, values: .complex))) {
            _ = try forged.process(signal, format: mono48)
        }
    }

    @Test func theFluentSpellingAndTheBuilderGiveEqualDescriptions() {
        let built = Pipeline { stft; Power(); Decibels(reference: 2, floor: -90); InverseDecibels(.power, reference: 2); Decibels() }
        let fluent = Pipeline().appending(stft).power().decibels(reference: 2, floor: -90).inverseDecibels(.power, reference: 2).decibels()
        #expect(built == fluent)
        #expect(Pipeline { stft; Magnitude() } == Pipeline().appending(stft).magnitude())
        #expect(Pipeline { stft; Magnitude() }.stages != Pipeline { stft; Power() }.stages)
        #expect(Pipeline { stft; Magnitude(); Decibels() } != Pipeline { stft; Magnitude(); Decibels(floor: -100) })
        #expect(Magnitude.stageName == "Magnitude" && InverseDecibels<PowerValues>.stageName == "InverseDecibels")
    }

    @Test func equalStepsAfterEqualFramingAreComputedOnce() throws {
        let feed = HeatmapFeed(history: 8), other = HeatmapFeed(history: 8)
        let pipeline = Pipeline {
            Tap { stft; Power(); Decibels(); Emit(to: feed) }
            Tap { stft; Power(); Decibels(); Emit(to: other) }
            Tap { stft; Power(); Decibels(floor: -90); Emit(to: CountingSink<Spectrum<LinearFrequency, DecibelValues>>()) }
        }
        #expect(nodeNames(try lowered(pipeline).steps) == ["STFT", "Power", "Decibels", "Decibels"], "the equal run of steps that follows is shared too (F5)")
    }

    // MARK: Activation, environment, axis (STG-1)

    @Test @MainActor func switchedOffAValueStepSuspendsTheRestOfItsBranch() throws {
        let off = StateBox(false)
        let dark = HeatmapFeed(history: 8), bound = HeatmapFeed(history: 8), live = HeatmapFeed(history: 64)
        try Pipeline {
            Tap { stft; Power(isActive: false); Decibels(); Emit(to: dark) }
            Tap { stft; Power(); Decibels(isActive: off.binding); Emit(to: bound) }
            Tap { stft; Magnitude(isActive: true); Decibels(isActive: .active); Emit(to: live) }
        }.run(on: signal, format: mono48)
        #expect(dark.columnCount == 0 && bound.columnCount == 0 && live.columnCount == (6_000 - 512) / 128 + 1)
        #expect(Decibels(isActive: off.binding).activation.isBound && Magnitude().activation == .active)
    }

    @Test func theAxisAndTheScopeAreUnchangedDownstream() throws {
        let sink = CollectingSink<Spectrum<LinearFrequency, DecibelValues>>()
        try Pipeline { STFT(frame: 512, hop: 128, paddedTo: 1_024); Power(); Decibels(); Emit(to: sink) }.run(on: signal, format: mono48)
        #expect(sink.axis == .linearFrequency(binCount: 513, nyquist: 24_000) && sink.environment?.frameSize == 512 && sink.environment?.hopSize == 128)
        #expect(sink.reals.allSatisfy { $0.count == 513 })
        expectClose(sink.times.first ?? -1, 511.0 / 48_000, .absolute(1e-12), "a frame keeps its time down the branch")
    }

    @Test func outsideASpectralScopeThereIsNothingToConvert() {
        struct Bare: PipelineStage {
            typealias Input = Samples
            typealias Output = Spectrum<LinearFrequency, ComplexValues>
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                context.emit(.analysis(AnalysisStep(name: "Bare", key: 0, output: .complex(count: 9)) { () throws(DSPError) -> any AnalysisNode in
                    SpectralValueNode(.magnitude, bins: 9)
                }))
            }
        }
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { Bare(); Magnitude() }.process(signal, format: mono48) }
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(reference: 0) }.process(signal, format: mono48) }
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(floor: -.infinity) }.process(signal, format: mono48) }
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { stft; Magnitude(); Decibels(); InverseDecibels(.magnitude, reference: -1) }.process(signal, format: mono48) }
    }

    // MARK: The recipe (§5.2)

    @Test func theSpectrogramRecipeIsItsExpansion() throws {
        let feed = HeatmapFeed(history: 64)
        let recipe = Pipeline { Spectrogram(frame: 1_024, hop: 256, window: .hamming, to: feed) }
        let expansion = Pipeline { Tap { STFT(frame: 1_024, hop: 256, window: .hamming, normalization: .amplitude); Power(); Decibels(); Emit(to: feed) } }
        #expect(recipe == expansion, "description for description")
        #expect(Pipeline().spectrogram(frame: 1_024, hop: 256, window: .hamming, to: feed) == recipe)
        #expect(Pipeline { Spectrogram(to: feed) } == Pipeline { Tap { STFT(frame: 2_048, hop: 512, normalization: .amplitude); Power(); Decibels(); Emit(to: feed) } })
        #expect(Pipeline { Spectrogram(to: feed, isActive: false) } == Pipeline { Tap(isActive: false) { STFT(frame: 2_048, hop: 512, normalization: .amplitude); Power(); Decibels(); Emit(to: feed) } })
        #expect(Pipeline { Spectrogram(to: feed) } != Pipeline { Spectrogram(to: HeatmapFeed()) }, "a feed is part of the description")
        #expect(Spectrogram(to: feed, isActive: false).activation == .constant(false))
        #expect(throws: DSPError.self) { var context = try lowering(); try Spectrogram(to: feed).lower(&context) }
    }

    @Test func aSpectrogramFillsItsFeedAndLeavesTheSamplesAlone() throws {
        let feed = HeatmapFeed(history: 64)
        let sine = TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 8_192)
        let output = try Pipeline { Spectrogram(frame: 1_024, hop: 256, to: feed); TestGain(0.5) }.process(sine, format: mono48)
        #expect(output == sine.map { $0 * 0.5 })
        let snapshot = feed.snapshot()
        #expect(snapshot.columnCount == (8_192 - 1_024) / 256 + 1 && snapshot.rowCount == 513)
        #expect(snapshot.axis == .linearFrequency(binCount: 513, nyquist: 24_000) && feed.environment?.featureRate == 187.5)
        let last = Array(snapshot.column(snapshot.columnCount - 1))
        expectClose(last[64], 0, .absolute(1e-3), "a full-scale sine reads 0 dB in a spectrogram")
        #expect(last.allSatisfy { $0 >= -160 && $0 <= 0.01 })
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodesRunWithoutAllocating() throws {
        let a = CountingSink<Spectrum<LinearFrequency, DecibelValues>>(), b = CountingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let c = CountingSink<Spectrum<LinearFrequency, PowerValues>>()
        let feed = HeatmapFeed(history: 128)
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 1_024, hop: 256); Magnitude(); Decibels(reference: 2, floor: -100); Emit(to: a); InverseDecibels(.magnitude, reference: 2); Emit(to: b) }
            Tap { STFT(frame: 1_024, hop: 256); Power(); Emit(to: c); Decibels(); InverseDecibels(.power); Emit(to: CountingSink<Spectrum<LinearFrequency, PowerValues>>()) }
            Spectrogram(frame: 2_048, hop: 512, to: feed)
        })
        #expect(a.frames > 1_990 && b.frames == a.frames && c.frames == a.frames && feed.columnCount == 128)
    }
}

/// A lowering context at the start of a signal, for a stage that is lowered on its own.
func lowering(sampleRate: Double = 48_000) throws -> LoweringContext {
    let environment = DSPEnvironment(sampleRate: sampleRate)
    let position = IRPosition(domain: .samples, environment: environment, maximumFrames: 512, format: .samples(channelCount: 1, maximumFrames: 512))
    return LoweringContext(position: position, path: StagePath().appending("Stage", index: 0), crossovers: .shipped)
}
