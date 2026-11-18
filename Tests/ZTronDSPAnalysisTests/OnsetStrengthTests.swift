import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// The `OnsetStrength` step with its floor (WP-525), and what every step owes (STG-1).
@Suite("Onset strength")
struct OnsetStrengthTests {
    typealias Decibels4 = Spectrum<LinearFrequency, DecibelValues>
    private let noise = TestSignal.whiteNoise(count: 12_000, seed: 525, amplitude: 0.5)

    /// The novelty curve of a list of frames of decibels, one frame per block.
    private func curve(of frames: [[Float]], _ step: OnsetStrength, repeating rounds: Int = 1) throws -> [ScalarFrame] {
        try Pipeline { FrameSequence<Decibels4>(frames); step }.process(FrameSequence<Decibels4>.drive(frames.count * rounds), format: mono48)
    }

    // MARK: Golden (STG-2): the definition of §6.9, 10⁻³ of the largest value

    static let cases = ["music-lag1-max1-floor-80", "music-lag1-max3-floor-80", "music-lag2-max1-floor0", "music-lag3-max5-floor10", "music-lag1-max4-floor-80",
                        "speech-lag1-max1-floor-80", "speech-lag2-max3-floor-80", "speech-lag1-max1-floor-20"]

    @Test(arguments: OnsetStrengthTests.cases)
    func theOnsetStrengthOfTheFixturesEqualsTheReference(name: String) throws {
        let golden = try GoldenFile(named: "onset_strength", in: .module).require(name)
        let fixture = try GoldenFile(named: "fixtures", in: .module).require(try golden.string("fixture"))
        let samples = try fixture.floats("samples"), format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        let frame = try golden.integer("frame"), hop = try golden.integer("hop"), bands = try golden.integer("bands")
        let lag = try golden.integer("lag"), maxSize = try golden.integer("maxSize"), floor = try golden.number("floor")
        let alignment: FrameAlignment = try golden.integer("centred") == 1 ? .centered : .causal
        let reference = try golden.real("onset")
        let values: [ScalarFrame] = try Pipeline {
            STFT(frame: frame, hop: hop, alignment: alignment); Power(); MelScale(bands: bands); Decibels()
            OnsetStrength(lag: lag, maxSize: maxSize, floor: floor)
        }.process(samples, format: format, blockSize: 441)
        let count = try golden.integer("frames")
        #expect(values.count == count && reference.count == count)
        expectClose(values.map { $0.value }, reference, .relativeToMaximum(1e-3), name)
        let largest = reference.max() ?? 0
        let worst = zip(values, reference).map { abs(Double($0.value) - $1) }.max() ?? 0
        print("measured WP-525: \(name): off by \(worst / largest) of the largest value, \(largest) (tolerance 1e-3)")
        // The first `lag` frames have nothing to be compared with: no value yet.
        #expect(values[..<lag].allSatisfy { $0.value == 0 && $0.confidence == 0 } && values[lag...].allSatisfy { $0.confidence == 1 })
        #expect(values.allSatisfy { $0.value >= 0 && $0.value.isFinite })
    }

    @Test func theFixturesReachUnderTheFloor() throws {
        // A case in which nothing lies under the floor says nothing about the floor.
        let golden = try GoldenFile(named: "onset_strength", in: .module)
        #expect(try golden.require("speech-lag1-max1-floor-80").number("flooredShare") > 0.01, "the pauses of the speech fixture are silence: −160 dB, raised to the default floor")
        #expect(try golden.require("music-lag2-max1-floor0").number("flooredShare") > 0.5)
        #expect(try golden.require("music-lag1-max1-floor-80").number("flooredShare") == 0)
    }

    // MARK: The definition, on frames written by hand

    @Test func aRiseCountsAndAFallDoesNot() throws {
        let quiet = [Float](repeating: -40, count: 8), loud = [Float](repeating: -30, count: 8)
        // Up by 10 dB in every band, then down again.
        let values = try curve(of: [quiet, quiet, loud, loud, quiet, quiet], OnsetStrength())
        #expect(values.map { $0.value } == [0, 0, 10, 0, 0, 0])
        #expect(values.map { $0.confidence } == [0, 1, 1, 1, 1, 1], "the first frame has nothing before it")
        // A rise in half the bands is half the mean.
        let half = (0 ..< 8).map { Float($0 < 4 ? -30 : -40) }
        #expect(try curve(of: [quiet, half], OnsetStrength()).map { $0.value } == [0, 5])
        // A lag of two compares with the frame before the last.
        let lagged = try curve(of: [quiet, quiet, loud, loud, quiet, quiet], OnsetStrength(lag: 2))
        #expect(lagged.map { $0.value } == [0, 0, 10, 10, 0, 0] && lagged.map { $0.confidence } == [0, 0, 1, 1, 1, 1])
    }

    @Test func theMaximumFilterKeepsAMovingPartialFromCountingAsAnOnset() throws {
        // One partial 20 dB over a floor of −60 dB, moving up by one band per frame: a vibrato.
        func frame(_ band: Int) -> [Float] { (0 ..< 16).map { $0 == band ? -40 : -60 } }
        let glide = [frame(5), frame(6), frame(7), frame(6), frame(5)]
        let plain = try curve(of: glide, OnsetStrength()).map { $0.value }
        #expect(plain == [0, 1.25, 1.25, 1.25, 1.25], "without the filter every step is 20 dB in one band of sixteen")
        // Over three bands the reference already holds the partial where it moves to.
        #expect(try curve(of: glide, OnsetStrength(maxSize: 3)).map { $0.value } == [0, 0, 0, 0, 0])
        // An even filter reaches one band further down than up: bands b − 1 … b. A partial that
        // came from the band below is found there; one that came from above is not.
        #expect(try curve(of: glide, OnsetStrength(maxSize: 2)).map { $0.value } == [0, 0, 0, 1.25, 1.25])
        // A partial that appears is an onset whatever the filter; at the edge the filter reflects.
        let appears = [[Float](repeating: -60, count: 16), frame(0), frame(15)]
        #expect(try curve(of: appears, OnsetStrength(maxSize: 5)).map { $0.value } == [0, 1.25, 1.25])
        #expect(try curve(of: [frame(15), frame(15), frame(14)], OnsetStrength(maxSize: 16)).map { $0.value } == [0, 0, 0], "a filter over every band")
    }

    @Test func valuesUnderTheFloorAreRaisedToItFirst() throws {
        // A noise floor that moves by 10 dB from frame to frame, 100 dB down: no onset.
        let low = [Float](repeating: -100, count: 8), lower = [Float](repeating: -110, count: 8)
        let flicker = [lower, low, lower, low, lower, low]
        #expect(try curve(of: flicker, OnsetStrength()).allSatisfy { $0.value == 0 }, "under −80 dB nothing counts")
        #expect(try curve(of: flicker, OnsetStrength(floor: -200)).map { $0.value } == [0, 10, 0, 10, 0, 10], "without a floor that reaches it, the flicker is onsets")
        // A rise from under the floor counts from the floor.
        let rise = [low, [Float](repeating: -70, count: 8)]
        #expect(try curve(of: rise, OnsetStrength()).map { $0.value } == [0, 10])
        #expect(try curve(of: rise, OnsetStrength(floor: -75)).map { $0.value } == [0, 5])
        // Silence as the decibel conversion writes it, −160 dB, is under any sensible floor.
        let silence = try Pipeline { STFT(frame: 256, hop: 64); Power(); Decibels(); OnsetStrength() }.process(TestSignal.silence(count: 2_048), format: mono48)
        #expect(silence.count == 29 && silence.allSatisfy { $0.value == 0 })
    }

    // MARK: Downstream: a novelty curve (§5.2, ENV-1)

    @Test func downstreamTheSignalIsANoveltyCurveAtTheFeatureRate() throws {
        let sink = CollectingSink<Novelty>(), spectra = CollectingSink<Spectrum<MelFrequency, DecibelValues>>()
        try Pipeline {
            STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40); Decibels(); Emit(to: spectra)
            OnsetStrength(); Emit(to: sink)
        }.run(on: noise, format: mono48, blockSize: 441)
        let environment = try #require(sink.environment)
        #expect(environment.sampleRate == 187.5 && environment.nyquistFrequency == 93.75, "the rate of the curve is the feature rate")
        #expect(environment.frameSize == nil && environment.hopSize == nil && environment.frequencyAxis == nil && environment.featureRate == nil, "outside the spectral scope")
        #expect(sink.axis == nil && environment.latency == 0 && environment.channelCount == 1)
        #expect(sink.scalars.count == spectra.frameCount && sink.times == spectra.times, "one value per frame, at the frame's time")
        #expect(sink.indices == Array(0 ..< sink.frameCount))
        // A filter after it means hertz of the curve (§5.2): 4 Hz passes, 100 Hz lies beyond its Nyquist frequency.
        let framing = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40); Decibels() }
        let smoothed: [ScalarFrame] = try framing.onsetStrength().lowPass(.butterworth, cutoff: .hertz(4), order: 2).process(noise, format: mono48)
        #expect(smoothed.count == sink.scalars.count)
        #expect(errorMessage { let _: [ScalarFrame] = try framing.onsetStrength().lowPass(.butterworth, cutoff: .hertz(100), order: 2).process(noise, format: mono48) }?
            .contains("Nyquist frequency of 93.75 Hz") == true)
    }

    @Test @MainActor func aBindingOfOneValueTakesTheCurve() throws {
        // O-11: a novelty value goes into a Binding<Float> or a Binding<ScalarFrame>.
        let framing = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40); Decibels() }
        let values: [ScalarFrame] = try framing.onsetStrength().process(noise, format: mono48)
        let latest = StateBox<Float>(-1), frame = StateBox(ScalarFrame.none)
        try framing.onsetStrength().emit(to: latest.binding).emit(to: frame.binding).run(on: noise, format: mono48)
        #expect(latest.value == values.last?.value && frame.value == values.last && latest.writes == 1)
    }

    // MARK: Order (O-9), both tiers

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() throws {
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.complex, .magnitude, .power, .decibel] {
                #expect(OnsetStrength.rule(.spectrum(axis: axis, values: values)) == (values == .decibel ? .novelty : nil), "\(axis), \(values) (O-9)")
            }
        }
        for tag in [DomainTag.samples, .novelty, .scalar, .quefrency, .lags, .tempoSpectrum, .chroma] { #expect(OnsetStrength.rule(tag) == nil, "\(tag)") }
        let spectrum = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        let step = OnsetStrength().stageDescription
        #expect(throws: DSPError.self) { _ = try spectrum.appending(step) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(step) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(step) }
        let decibels = try spectrum.appending(Power().stageDescription).appending(Decibels().stageDescription)
        #expect(try decibels.appending(step).outputTag == .novelty)
        #expect(throws: DSPError.self) { _ = try decibels.appending(step).appending(step) }
    }

    @Test func descriptionsSpellingsAndActivation() throws {
        let stft = STFT(frame: 1_024, hop: 256)
        #expect(Pipeline { stft; Power(); Decibels(); OnsetStrength(lag: 2, maxSize: 3, floor: -60) } == Pipeline().appending(stft).power().decibels().onsetStrength(lag: 2, maxSize: 3, floor: -60))
        #expect(Pipeline().appending(stft).power().decibels().onsetStrength() == Pipeline().appending(stft).power().decibels().onsetStrength(lag: 1, maxSize: 1, floor: -80, isActive: true))
        let base = Pipeline().appending(stft).magnitude().melScale(bands: 40).decibels()
        #expect(base.onsetStrength() != base.onsetStrength(lag: 2) && base.onsetStrength() != base.onsetStrength(maxSize: 2) && base.onsetStrength() != base.onsetStrength(floor: -70))
        #expect(base.onsetStrength() != base.onsetStrength(isActive: false))
        #expect(OnsetStrength.stageName == "OnsetStrength" && OnsetStrength().lag == 1 && OnsetStrength().maxSize == 1 && OnsetStrength().floor == -80)

        let dark = CollectingSink<Novelty>()
        try Pipeline { stft; Power(); Decibels(); OnsetStrength(isActive: false); Emit(to: dark) }.run(on: noise, format: mono48)
        #expect(dark.frameCount == 0, "switched off, it suspends its branch (ACT-3)")
        // Equal steps in two taps are computed once, with the framing before them (F5).
        let a = CollectingSink<Novelty>(), b = CollectingSink<Novelty>()
        let shared = Pipeline {
            Tap { stft; Power(); Decibels(); OnsetStrength(); Emit(to: a) }
            Tap { stft; Power(); Decibels(); OnsetStrength(); Emit(to: b) }
        }
        #expect(nodeNames(try lowered(shared).steps) == ["STFT", "Power", "Decibels", "OnsetStrength"])
        try shared.run(on: noise, format: mono48)
        #expect(a.scalars == b.scalars && a.frameCount == 43)
    }

    // MARK: Attach-time checks

    @Test func nonsenseIsRefusedWhenThePipelineIsAttached() {
        func refusal(_ step: OnsetStrength, bands: Int = 40) -> String? {
            errorMessage { let _: [ScalarFrame] = try Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: bands); Decibels(); step }.process(noise, format: mono48) }
        }
        #expect(refusal(OnsetStrength(lag: 0))?.contains("Invalid parameter lag") == true && refusal(OnsetStrength(lag: 5_000))?.contains("Invalid parameter lag") == true)
        #expect(refusal(OnsetStrength(maxSize: 0))?.contains("Invalid parameter maxSize") == true)
        #expect(refusal(OnsetStrength(maxSize: 41))?.contains("a maximum over 41 bands does not fit a spectrum of 40") == true)
        #expect(refusal(OnsetStrength(floor: .nan))?.contains("Invalid parameter floor") == true && refusal(OnsetStrength(floor: -.infinity))?.contains("Invalid parameter floor") == true)
        #expect(refusal(OnsetStrength(lag: 4_096, maxSize: 40)) == nil)
        // Frames of the right domain from a stage that opens no scope: no axis, no feature rate.
        #expect(errorMessage { let _: [ScalarFrame] = try Pipeline { FixedFrames<Decibels4>([Float](repeating: -30, count: 33)); OnsetStrength() }.process(noise, format: mono48) }?
            .contains("OnsetStrength needs the frames of a spectral scope") == true)
    }

    // MARK: Cold start, latency, settling (ACT-10, STG-1)

    @Test func aColdStartForgetsTheFramesItComparedWith() throws {
        let short = Array(noise[..<3_000])
        let chain = Pipeline { STFT(frame: 256, hop: 64); Power(); MelScale(bands: 20); Decibels() }
        try expectAFreshStreamAfterAColdStart(of: chain.onsetStrength(), on: short, "OnsetStrength")
        try expectAFreshStreamAfterAColdStart(of: chain.onsetStrength(lag: 3, maxSize: 5), on: short, "OnsetStrength with a lag and a filter")
        // The second pass begins without a value again.
        let cold = try twoPasses(of: chain.onsetStrength(lag: 2), on: short, coldStart: true)
        let half = cold.scalars.count / 2
        #expect(cold.scalars[half - 1].confidence == 1 && cold.scalars[half ..< half + 2].allSatisfy { $0.confidence == 0 && $0.value == 0 } && cold.scalars[half + 2].confidence == 1)
        let node = try OnsetStrengthNode(bands: 40, lag: 3, maxSize: 5, floor: -80)
        #expect(node.latencyFrames == 0 && node.settlingFrames == 3, "no delay; it compares frames that both arrived since a reset after `lag` frames")
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let plain = CountingSink<Novelty>(), filtered = CountingSink<Novelty>()
        // A branch that begins with a step of a family is written fluently (ORD-3).
        try expectNoAllocationsRunning(
            Pipeline().stft(frame: 2_048, hop: 512).power().melScale(bands: 128).decibels()
                .tap { $0.onsetStrength().emit(to: plain) }
                .tap { $0.onsetStrength(lag: 3, maxSize: 7, floor: -60).emit(to: filtered) })
        #expect(plain.frames > 990 && filtered.frames > 990, "\(plain.frames) and \(filtered.frames) values")
    }
}
