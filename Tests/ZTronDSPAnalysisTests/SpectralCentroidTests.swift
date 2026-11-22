import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `SpectralCentroid` step and its measuring spelling (WP-507): the acceptance of §6.5.
@Suite("SpectralCentroid")
struct SpectralCentroidTests {
    private let stft = STFT(frame: 1_024, hop: 256, window: .hann)
    private let binWidth = 48_000.0 / 1_024

    // MARK: Acceptance (§6.5)

    @Test(arguments: [440.0, 1_234.5, 5_000, 12_000, 20_003.7])
    func aSineGivesItsFrequencyWithinHalfABin(frequency: Double) throws {
        let sine = TestSignal.sine(frequency: frequency, sampleRate: 48_000, count: 16_384, amplitude: 0.7)
        let magnitude: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(sine, format: mono48)
        let power: [ScalarFrame] = try Pipeline { stft; Power(); SpectralCentroid() }.process(sine, format: mono48)
        #expect(magnitude.count == (16_384 - 1_024) / 256 + 1 && power.count == magnitude.count)
        for values in [magnitude, power] {
            #expect(values.allSatisfy { abs(Double($0.value) - frequency) <= binWidth / 2 && $0.confidence == 1 },
                    "\(frequency) Hz: \(values.map { $0.value }.min() ?? 0) … \(values.map { $0.value }.max() ?? 0)")
        }
    }

    @Test func whiteNoiseGivesAQuarterOfTheSampleRate() throws {
        let noise = TestSignal.gaussianNoise(count: 256 * 203 + 1_024, seed: 507, standardDeviation: 0.2)
        for values in [try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(noise, format: mono48) as [ScalarFrame],
                       try Pipeline { stft; Power(); SpectralCentroid() }.process(noise, format: mono48)] {
            let mean = values.prefix(200).reduce(0) { $0 + Double($1.value) } / 200
            #expect(values.count >= 200 && abs(mean - 12_000) <= 0.02 * 12_000, "the mean over 200 frames is \(mean) Hz")
        }
    }

    @Test func silenceHasNoCentroid() throws {
        let silence: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(TestSignal.silence(count: 4_096), format: mono48)
        #expect(silence.count == 13 && silence.allSatisfy { $0 == ScalarFrame(value: 0, confidence: 0) }, "0 before the first value, with confidence 0")

        // After a tone, silence repeats the last value with confidence 0: no NaN, no jump to 0 Hz.
        let signal = TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 8_192) + TestSignal.silence(count: 8_192)
        let values: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid() }.process(signal, format: mono48)
        let lastHeard = try #require(values.last { $0.confidence == 1 })
        #expect(values.suffix(20).allSatisfy { $0 == ScalarFrame(value: lastHeard.value, confidence: 0) } && lastHeard.value > 0)
        #expect(abs(values[20].value - 3_000) < 30 && values[20].confidence == 1)
        #expect(values.allSatisfy { $0.value.isFinite && $0.confidence.isFinite }, "no step emits NaN (NUM-1)")
        // A floor above the signal treats it as silence.
        let floored: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid(floor: 1e9) }.process(signal, format: mono48)
        #expect(floored.allSatisfy { $0.confidence == 0 && $0.value == 0 })
    }

    @Test func aRangeLimitsTheBinsThatCount() throws {
        let two = TestSignal.sum(TestSignal.sine(frequency: 1_500, sampleRate: 48_000, count: 8_192, amplitude: 0.5),
                                 TestSignal.sine(frequency: 9_000, sampleRate: 48_000, count: 8_192, amplitude: 0.5))
        func centroid(_ range: FrequencyRange?) throws -> Float {
            let values: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid(range: range) }.process(two, format: mono48)
            return try #require(values.last).value
        }
        expectClose(try centroid(nil), 5_250, .absolute(binWidth / 2), "two equal tones: the middle")
        expectClose(try centroid(.hertz(0 ... 24_000)), try centroid(nil), .absolute(1e-3))
        expectClose(try centroid(.hertz(500 ... 3_000)), 1_500, .absolute(binWidth / 2))
        expectClose(try centroid(FrequencyRange(from: .hertz(6_000), to: .fractionOfNyquist(0.5))), 9_000, .absolute(binWidth / 2))
        #expect(throws: DSPError.self) { _ = try centroid(.hertz(100 ... 30_000)) }
        #expect(throws: DSPError.self) { _ = try centroid(.hertz(3_000 ... 3_000)) }
        #expect(throws: DSPError.self) { _ = try centroid(.hertz(3_010 ... 3_020)) }
        let message = errorMessage { _ = try centroid(.hertz(3_010 ... 3_020)) }
        #expect(message?.contains("no bin lies between") == true && message?.contains("SpectralCentroid") == true, "\(message ?? "")")
        #expect(throws: DSPError.self) { let _: [ScalarFrame] = try Pipeline { stft; Magnitude(); SpectralCentroid(floor: -1) }.process(two, format: mono48) }
    }

    @Test func theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce() throws {
        // A frame with all its weight in one bin has the frequency of that bin as its centroid,
        // exactly: the bin's index times the bin width, rounded once to a float. 361 bins up to
        // 24 kHz are 66.66… Hz apart, a width that is not a float, so rounding the width first
        // and the product after it would move some bins by a unit in the last place. (The widths
        // of power-of-two transforms at 44.1, 48, 96 and 192 kHz are floats: there the two agree.)
        let bins = 361, nyquist = 24_000.0, width = nyquist / Double(bins - 1)
        let frames = (0 ..< bins).map { bin in (0 ..< bins).map { Float($0 == bin ? 1 : 0) } }
        let values: [ScalarFrame] = try Pipeline {
            FrameSequence<Spectrum<LinearFrequency, MagnitudeValues>>(frames, hop: 512, nyquist: nyquist)
            SpectralCentroid()
        }.process(FrameSequence<Spectrum<LinearFrequency, MagnitudeValues>>.drive(bins), format: mono48)
        #expect(values.count == bins)
        let wrong = values.indices.filter { values[$0].confidence != 1 || values[$0].value.bitPattern != Float(Double($0) * width).bitPattern }
        #expect(wrong.isEmpty, "bins \(wrong.prefix(8)) are not their frequency rounded once")
        // The test can tell the two roundings apart.
        let twice = (0 ..< bins).filter { Float($0) * Float(width) != Float(Double($0) * width) }
        #expect(!twice.isEmpty, "rounding the width first moves \(twice.count) of the \(bins) bins")
        print("measured WP-507: \(bins) bins \(width) Hz apart, a frame of weight in one bin each: \(bins - wrong.count) centroids that are the bin's frequency rounded once; rounding the width first would move \(twice.count)")
    }

    @Test(arguments: [1, 7, 480, 4_096])
    func theValuesDoNotDependOnTheBlockSize(blockSize: Int) throws {
        let signal = TestSignal.chirp(from: 200, to: 15_000, sampleRate: 48_000, count: 20_000, amplitude: 0.5)
        let pipeline = Pipeline { stft; Magnitude(); SpectralCentroid(range: .hertz(100 ... 20_000)) }
        let reference: [ScalarFrame] = try pipeline.process(signal, format: mono48, blockSize: 512)
        #expect(try pipeline.process(signal, format: mono48, blockSize: blockSize) == reference)
    }

    @Test func downstreamIsAScalarTrackAtTheFeatureRate() throws {
        let sink = CollectingSink<Scalar>(), halved = CollectingSink<Scalar>()
        try Pipeline { stft; Magnitude(); SpectralCentroid(); Emit(to: sink); TestGain(0.5); Emit(to: halved) }
            .run(on: TestSignal.whiteNoise(count: 8_192, seed: 1), format: mono48)
        #expect(sink.environment?.sampleRate == 187.5 && sink.environment?.isInSpectralScope == false && sink.axis == nil)
        expectClose(sink.times, (0 ..< sink.frameCount).map { Double($0 * 256 + 1_023) / 48_000 }, .absolute(1e-12), "a value keeps the time of its frame")
        #expect(halved.scalars.map { $0.value } == sink.scalars.map { $0.value * 0.5 })
    }

    // MARK: The measuring spelling (OUT-1)

    @Test func theMeasuringSpellingIsItsTapExpansion() {
        let box = StateBox(Float(0))
        let measured = Pipeline { stft; Magnitude(); SpectralCentroid(range: .hertz(50 ... 8_000), to: box.binding) }
        let expanded = Pipeline().appending(stft).magnitude().tap { $0.spectralCentroid(range: .hertz(50 ... 8_000)).emit(to: box.binding) }
        #expect(measured == expanded, "description for description")
        #expect(Pipeline().appending(stft).magnitude().spectralCentroid(range: .hertz(50 ... 8_000), to: box.binding) == measured)
        #expect(Pipeline { stft; Power(); SpectralCentroid() } == Pipeline().appending(stft).power().spectralCentroid())
        #expect(Pipeline { stft; Power(); SpectralCentroid(to: box.binding, isActive: false) }
            == Pipeline().appending(stft).power().tap(isActive: false) { $0.spectralCentroid().emit(to: box.binding) })
        #expect(SpectralCentroid<Scalar>.stageName == "SpectralCentroid" && SpectralCentroid(to: box.binding, isActive: false).activation == .constant(false))
        #expect(throws: DSPError.self) { var context = try lowering(); try SpectralCentroid(to: box.binding).lower(&context) }
    }

    @Test @MainActor func aMeasuringCentroidPassesTheSpectrumOnAndWritesItsBinding() throws {
        let centroid = StateBox(Float(-1)), frame = StateBox(ScalarFrame.none)
        let feed = HeatmapFeed(history: 64), plain = HeatmapFeed(history: 64)
        let sine = TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 8_192)
        try Pipeline {
            Tap { stft; Magnitude(); SpectralCentroid(to: centroid.binding); SpectralCentroid(to: frame.binding); Decibels(); Emit(to: feed) }
            Tap { stft; Magnitude(); Decibels(); Emit(to: plain) }
        }.run(on: sine, format: mono48)
        expectClose(centroid.value, 3_000, .absolute(binWidth / 2))
        #expect(frame.value.value == centroid.value && frame.value.confidence == 1 && centroid.writes == 1)
        #expect(feed.snapshot().values == plain.snapshot().values && feed.columnCount == 29, "the spectrum that follows is untouched")
    }

    // MARK: Order (O-8), both tiers

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() {
        let rule = SpectralCentroid<Scalar>.rule
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.complex, .magnitude, .power, .decibel] {
                let accepted = axis == .linear && (values == .magnitude || values == .power)
                #expect(rule(.spectrum(axis: axis, values: values)) == (accepted ? .scalar : nil), "\(axis), \(values) (O-8)")
            }
        }
        for tag in [DomainTag.samples, .scalar, .quefrency, .chroma] { #expect(rule(tag) == nil) }
    }

    @Test func aWrongOrderIsRefusedOnTheDescriptions() throws {
        let box = StateBox(Float(0))
        let spectrum = try DynamicPipeline().appending(stft)
        #expect(throws: DSPError.self) { _ = try spectrum.appending(SpectralCentroid().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(Decibels().stageDescription).appending(SpectralCentroid().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(MelScale(bands: 20).stageDescription).appending(SpectralCentroid().stageDescription) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(SpectralCentroid(to: box.binding).stageDescription) }
        #expect(try spectrum.appending(Magnitude().stageDescription).appending(SpectralCentroid().stageDescription).outputTag == .scalar)
        #expect(try spectrum.appending(Magnitude().stageDescription).appending(SpectralCentroid(to: box.binding).stageDescription).outputTag
            == .spectrum(axis: .linear, values: .magnitude), "the measuring spelling keeps the domain")
    }

    @Test @MainActor func switchedOffItSuspendsOrStopsMeasuring() throws {
        let value = StateBox(Float(-1)), sink = CollectingSink<Scalar>()
        let after = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        try Pipeline { stft; Magnitude(); SpectralCentroid(to: value.binding, isActive: false); Emit(to: after); SpectralCentroid(isActive: false); Emit(to: sink) }
            .run(on: TestSignal.whiteNoise(count: 4_096, seed: 3), format: mono48)
        #expect(value.writes == 0 && after.frameCount == 13 && sink.frameCount == 0)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let a = CountingSink<Scalar>(), b = CountingSink<Scalar>(), c = CountingSink<Scalar>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Magnitude(); SpectralCentroid(); Emit(to: a) }
            Tap { STFT(frame: 2_048, hop: 512); Power(); SpectralCentroid(range: .hertz(100 ... 1_000)); Emit(to: b) }
            Tap { STFT(frame: 64, hop: 16); Magnitude(); SpectralCentroid(range: .hertz(0 ... 6_000)); Emit(to: c) }
        })
        #expect(a.frames > 990 && b.frames == a.frames && c.frames > 31_000)
    }
}
