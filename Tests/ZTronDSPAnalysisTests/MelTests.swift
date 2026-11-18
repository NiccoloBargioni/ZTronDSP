import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The mel filter bank (WP-508) and the `MelScale` step with its recipe (WP-535): the
/// acceptance of §6.11.
@Suite("Mel scale")
struct MelTests {
    typealias Mel<V: SpectralValues> = Spectrum<MelFrequency, V>

    // MARK: The formulas (WP-508)

    @Test func theConversionsRoundTripAndEqualTheReference() throws {
        let golden = try GoldenFile(named: "mel", in: .module).require("formulas")
        let hertz = try golden.real("hertz")
        expectClose(DSP.mel(fromHertz: hertz, formula: .slaney), try golden.real("slaney"), .relative(1e-12))
        expectClose(DSP.mel(fromHertz: hertz, formula: .htk), try golden.real("htk"), .relative(1e-12))
        #expect(DSP.mel(fromHertz: 1_000, formula: .slaney) == 15, "1 000 Hz is 15 mel (Slaney)")
        for frequency in stride(from: 0.0, through: 24_000, by: 37.3) {
            expectClose(DSP.hertz(fromMel: DSP.mel(fromHertz: frequency, formula: .slaney), formula: .slaney), frequency, .relative(1e-9))
            expectClose(DSP.hertz(fromMel: DSP.mel(fromHertz: frequency, formula: .htk), formula: .htk), frequency, .absolute(1e-9 * max(frequency, 1)))
        }
    }

    // MARK: The filter bank (WP-508)

    @Test(arguments: ["default-22050-2048-128", "htk-48000-1024-40-peak", "slaney-16000-512-26-range", "htk-44100-4096-64-area", "slaney-48000-240-12-peak"])
    func theWeightsEqualTheReferenceFilterBank(name: String) throws {
        let golden = try GoldenFile(named: "mel", in: .module).require("bank-\(name)")
        let rate = try golden.number("sampleRate"), length = try golden.integer("length"), bands = try golden.integer("bands")
        let isHTK = try golden.integer("htk") == 1, isSlaney = try golden.integer("slaney") == 1
        let range = try golden.number("fmin") ... golden.number("fmax")
        func bank<F: MelFormula, N: MelNormalization>(_ formula: F, _ normalization: N) throws -> MelFilterBank {
            try MelFilterBank(bands: bands, binCount: length / 2 + 1, nyquist: rate / 2, range: range, formula: formula, normalization: normalization)
        }
        let formula: any MelFormula = isHTK ? HTKMelFormula() : SlaneyMelFormula()
        let normalization: any MelNormalization = isSlaney ? SlaneyMelNormalization() : UnitPeakMelNormalization()
        let built = try bank(formula, normalization)
        let reference = try golden.real("weights")
        let shape = try golden.shape("weights")
        #expect(shape == [bands, length / 2 + 1] && built.bandCount == bands && built.binCount == length / 2 + 1)
        expectClose(built.denseWeights(), reference, .relativeToMaximum(1e-6))
        expectClose(built.denseWeights(), reference, .absolute(1e-6))
        expectClose(built.edges, try golden.real("edges"), .relative(1e-12))
        #expect(built.firstEmptyBand == nil && built.centers == Array(built.edges[1 ... bands]))

        // Every weight lies on its triangle, whose peak is 2 / (f(m+2) − f(m)) under Slaney's
        // normalisation and 1 without; the sampled weights need not reach it.
        for (index, band) in built.bands.enumerated() {
            let lower = built.edges[index], center = built.edges[index + 1], upper = built.edges[index + 2]
            let peak = isSlaney ? 2 / (upper - lower) : 1
            expectClose(normalization.gain(lowerEdge: lower, center: center, upperEdge: upper), peak, .relative(1e-15))
            for (offset, weight) in band.weights.enumerated() {
                let frequency = Double(band.firstBin + offset) * built.binWidth
                let triangle = peak * min((frequency - lower) / (center - lower), (upper - frequency) / (upper - center))
                expectClose(weight, triangle, .relative(1e-6))
                #expect(weight > 0 && Double(weight) <= peak * (1 + 1e-6) && frequency > lower && frequency < upper)
            }
        }
    }

    @Test func aBandThatCoversNoBinIsReportedNotHidden() throws {
        let sparse = try MelFilterBank(bands: 128, binCount: 129, nyquist: 24_000)
        let empty = try #require(sparse.firstEmptyBand)
        #expect(sparse.bands[empty].weights.isEmpty && sparse.applied(to: [Float](repeating: 1, count: 129))[empty] == 0)
        let filling = try #require(MelFilterBank.smallestFillingLength(edges: sparse.edges, sampleRate: 48_000, above: 256))
        let filled = try MelFilterBank(bands: 128, binCount: filling / 2 + 1, nyquist: 24_000)
        let shorter = try MelFilterBank(bands: 128, binCount: (DSP.previousFastLength(filling - 1) ?? 16) / 2 + 1, nyquist: 24_000)
        #expect(filled.firstEmptyBand == nil, "\(filling) points fill every band")
        #expect(shorter.firstEmptyBand != nil, "and no shorter transform does")
        #expect(MelFilterBank.smallestFillingLength(edges: [0, 1e-9, 2e-9, 24_000], sampleRate: 48_000, above: 16) == nil)
    }

    @Test func aBankIsAValue() throws {
        let a = try MelFilterBank(bands: 20, binCount: 257, nyquist: 8_000), b = try MelFilterBank(bands: 20, binCount: 257, nyquist: 8_000)
        let more = try MelFilterBank(bands: 21, binCount: 257, nyquist: 8_000)
        let htk = try MelFilterBank(bands: 20, binCount: 257, nyquist: 8_000, formula: .htk)
        let unitPeak = try MelFilterBank(bands: 20, binCount: 257, nyquist: 8_000, normalization: .none)
        #expect(a == b && a.hashValue == b.hashValue && a != more && a != htk && a != unitPeak)
        let spectrum = (0 ..< 257).map { Float($0 % 7) * 0.25 }
        let dense = a.denseWeights()
        let expected = (0 ..< 20).map { band in (0 ..< 257).reduce(0.0) { $0 + Double(dense[band * 257 + $1]) * Double(spectrum[$1]) } }
        expectClose(a.applied(to: spectrum), expected, .relative(1e-6))
        for (bands, bins, nyquist, range) in [(0, 257, 8_000.0, nil as ClosedRange<Double>?), (1 << 17, 257, 8_000, nil), (20, 1, 8_000, nil), (20, 257, 0, nil),
                                              (20, 257, 8_000, 0 ... 9_000), (20, 257, 8_000, 500 ... 500), (20, 257, 8_000, -5 ... 500)] {
            #expect(throws: DSPError.self) { _ = try MelFilterBank(bands: bands, binCount: bins, nyquist: nyquist, range: range) }
        }
    }

    // MARK: The step (WP-535)

    @Test(arguments: ["speech", "music"])
    func theMelPowerSpectrogramOfTheFixturesEqualsTheReference(name: String) throws {
        let fixture = try GoldenFile(named: "fixtures", in: .module).require(name)
        let golden = try GoldenFile(named: "mel", in: .module).require("spectrogram-\(name)")
        let samples = try fixture.floats("samples"), format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        let frame = try golden.integer("frame"), hop = try golden.integer("hop"), bands = try golden.integer("bands")
        let reference = try golden.real("mel")
        let frames: [[Float]] = try Pipeline { STFT(frame: frame, hop: hop, alignment: .centered); Power(); MelScale(bands: bands) }
            .process(samples, format: format, blockSize: 441)
        let count = try golden.integer("frames")
        #expect(frames.count == count && frames.allSatisfy { $0.count == bands })
        for (index, values) in frames.enumerated() {
            expectClose(values, Array(reference[index * bands ..< (index + 1) * bands]), .relativeToMaximum(1e-4), "\(name), frame \(index)")
        }
    }

    @Test func bandedAndDenseProjectionsAgree() throws {
        let signal = TestSignal.whiteNoise(count: 12_000, seed: 535, amplitude: 0.5)
        let pipeline = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 60, range: .hertz(100 ... 16_000), formula: .htk, normalization: .none) }
        let banded: [[Float]] = try pipeline.environment(\.implementation, .native).process(signal, format: mono48)
        let dense: [[Float]] = try pipeline.environment(\.implementation, .accelerate).process(signal, format: mono48)
        let automatic: [[Float]] = try pipeline.process(signal, format: mono48)
        #expect(banded.count == 43 && dense.count == 43)
        for index in banded.indices {
            expectClose(dense[index], banded[index], .relative(1e-5), "the implementations of one primitive agree (SEL-6)")
            expectClose(automatic[index], banded[index], .relative(1e-5))
        }
        #expect(nodeNames(try lowered(pipeline).steps) == ["STFT", "Power", "MelScale"])
        // Above the crossover the automatic choice is the dense product.
        let small = CrossoverTable(melDense: 1_000)
        let viaTable: [[Float]] = try pipeline.process(signal, format: mono48, crossovers: small)
        #expect(viaTable == dense, "bands × bins decide (§7.4)")
    }

    @Test func aBankOnAMagnitudeSpectrumGivesMagnitudesAndOnPowersPowers() throws {
        let sine = TestSignal.sine(frequency: 2_000, sampleRate: 48_000, count: 8_192, amplitude: 0.5)
        let stft = STFT(frame: 1_024, hop: 512)
        let bank = try MelFilterBank(bands: 40, binCount: 513, nyquist: 24_000)
        let magnitudes: [[Float]] = try Pipeline { stft; Magnitude() }.process(sine, format: mono48)
        let powers: [[Float]] = try Pipeline { stft; Power() }.process(sine, format: mono48)
        let melMagnitudes: [[Float]] = try Pipeline { stft; Magnitude(); MelScale(bands: 40) }.process(sine, format: mono48)
        let melPowers: [[Float]] = try Pipeline { stft; Power(); MelScale(bands: 40) }.process(sine, format: mono48)
        for index in magnitudes.indices {
            expectClose(melMagnitudes[index], bank.applied(to: magnitudes[index]), .relativeToMaximum(1e-6))
            expectClose(melPowers[index], bank.applied(to: powers[index]), .relativeToMaximum(1e-6))
        }
        let peak = try #require(melPowers.last?.enumerated().max { $0.element < $1.element }?.offset)
        #expect(abs(bank.centers[peak] - 2_000) < 100, "the tone lands in the band around it")
    }

    @Test func downstreamTheAxisIsMelByBandCentres() throws {
        let sink = CollectingSink<Mel<DecibelValues>>()
        try Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 32, range: .hertz(50 ... 12_000)); Decibels(); Emit(to: sink) }
            .run(on: TestSignal.whiteNoise(count: 4_096, seed: 4), format: mono48)
        let bank = try MelFilterBank(bands: 32, binCount: 513, nyquist: 24_000, range: 50 ... 12_000)
        #expect(sink.axis == .mel(centers: bank.centers) && sink.reals.allSatisfy { $0.count == 32 })
        #expect(sink.environment?.frequencyAxis?.unit == .hertz && sink.environment?.frameSize == 1_024 && sink.environment?.hopSize == 256)
        let feed = HeatmapFeed(history: 16)
        try Pipeline { MelSpectrogram(frame: 1_024, hop: 256, bands: 32, range: .hertz(50 ... 12_000), to: feed) }
            .run(on: TestSignal.whiteNoise(count: 4_096, seed: 4), format: mono48)
        #expect(feed.axis == .mel(centers: bank.centers) && feed.rowCount == 32 && feed.columnCount == 13)
        #expect(feed.snapshot().values == sink.reals.flatMap { $0 }, "the recipe is the branch written out")
    }

    // MARK: Attach-time checks (O-18)

    @Test func anEmptyBandIsRefusedAndTheErrorNamesItAndTheFrameThatWouldFillIt() throws {
        func failure(_ step: MelScale, frame: Int = 256) -> DSPError? {
            do {
                let _: [[Float]] = try Pipeline { STFT(frame: frame, hop: frame / 4); Power(); step }.process(TestSignal.silence(count: 600), format: mono48)
                return nil
            } catch {
                return error
            }
        }
        let empty = try #require(failure(MelScale(bands: 128)), "128 bands on a 256-point frame")
        guard case .invalidParameter(let stage, let parameter, let reason) = empty else {
            Issue.record("not an invalid parameter: \(empty)")
            return
        }
        #expect(stage.stageName == "MelScale" && parameter == "bands")
        #expect(reason.contains("band 0 of 128") && reason.contains("256 points") && reason.contains("a transform of 768 points is the smallest that fills every band"), "\(reason)")
        #expect(failure(MelScale(bands: 128), frame: 768) == nil && failure(MelScale(bands: 128), frame: 720) != nil && failure(MelScale(bands: 128), frame: 512) != nil)
        #expect(failure(MelScale(bands: 20)) == nil)
        #expect(failure(MelScale(bands: 20, range: .hertz(0 ... 30_000))) != nil, "the range ends at or below Nyquist")
        #expect(failure(MelScale(bands: 20, range: .hertz(4_000 ... 4_000))) != nil && failure(MelScale(bands: 20, range: FrequencyRange(from: .hertz(5_000), to: .hertz(4_000)))) != nil)
        #expect(failure(MelScale(bands: 0)) != nil && failure(MelScale(bands: -3)) != nil)
        #expect(failure(MelScale(bands: 20, range: FrequencyRange(from: .mel(5), to: .fractionOfNyquist(1)))) == nil, "a range in any unit, up to Nyquist itself")
    }

    // MARK: Order (O-5), both tiers

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() {
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.complex, .magnitude, .power, .decibel] {
                let accepted = axis == .linear && (values == .magnitude || values == .power)
                #expect(MelScale.rule(.spectrum(axis: axis, values: values)) == (accepted ? .spectrum(axis: .mel, values: values) : nil), "\(axis), \(values) (O-5)")
            }
        }
        for tag in [DomainTag.samples, .scalar, .quefrency, .melCepstrum] { #expect(MelScale.rule(tag) == nil) }
    }

    @Test func aWrongOrderIsRefusedOnTheDescriptions() throws {
        let spectrum = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        let mel = MelScale(bands: 20).stageDescription
        #expect(throws: DSPError.self) { _ = try spectrum.appending(mel) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(Decibels().stageDescription).appending(mel) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(mel).appending(mel) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(mel) }
        #expect(try spectrum.appending(Magnitude().stageDescription).appending(mel).outputTag == .spectrum(axis: .mel, values: .magnitude))
    }

    @Test func descriptionsRecipesAndActivation() throws {
        let stft = STFT(frame: 1_024, hop: 256)
        #expect(Pipeline { stft; Power(); MelScale(bands: 40, range: .hertz(0 ... 8_000), formula: .htk, normalization: .none) }
            == Pipeline().appending(stft).power().melScale(bands: 40, range: .hertz(0 ... 8_000), formula: .htk, normalization: .none))
        #expect(Pipeline { stft; Power(); MelScale(bands: 40) } == Pipeline().appending(stft).power().melScale(bands: 40, formula: .slaney, normalization: .slaney))
        #expect(Pipeline { stft; Power(); MelScale(bands: 40) } != Pipeline { stft; Power(); MelScale(bands: 40, formula: .htk) })
        #expect(Pipeline { stft; Power(); MelScale(bands: 40) } != Pipeline { stft; Power(); MelScale(bands: 40, normalization: .none) })
        #expect(MelScale(bands: 40, formula: .htk).formula is HTKMelFormula && MelScale(bands: 40).normalization is SlaneyMelNormalization)
        #expect(MelScale.stageName == "MelScale" && FrequencyRange.hertz(1 ... 2).description == "1.0 Hz … 2.0 Hz")

        let feed = HeatmapFeed()
        #expect(Pipeline { MelSpectrogram(frame: 1_024, hop: 256, bands: 40, window: .hamming, range: .hertz(0 ... 8_000), to: feed) }
            == Pipeline { Tap { STFT(frame: 1_024, hop: 256, window: .hamming); Power(); MelScale(bands: 40, range: .hertz(0 ... 8_000)); Decibels(); Emit(to: feed) } })
        #expect(Pipeline { MelSpectrogram(to: feed, isActive: false) }
            == Pipeline { Tap(isActive: false) { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); Emit(to: feed) } })
        #expect(Pipeline().melSpectrogram(bands: 64, to: feed) == Pipeline { MelSpectrogram(bands: 64, to: feed) })

        let dark = CollectingSink<Mel<PowerValues>>()
        try Pipeline { stft; Power(); MelScale(bands: 20, isActive: false); Emit(to: dark) }.run(on: TestSignal.silence(count: 4_096), format: mono48)
        #expect(dark.frameCount == 0, "switched off, it suspends its branch (ACT-3)")
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodesRunWithoutAllocating() throws {
        let banded = CountingSink<Mel<PowerValues>>(), dense = CountingSink<Mel<MagnitudeValues>>()
        let feed = HeatmapFeed(history: 64)
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Emit(to: banded) }
            MelSpectrogram(frame: 2_048, hop: 512, bands: 40, to: feed)
        })
        #expect(banded.frames > 990 && feed.columnCount == 64)
        try expectNoAllocationsRunning(
            Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 64); Emit(to: dense) }.environment(\.implementation, .accelerate))
        #expect(dense.frames > 1_990)
    }
}
