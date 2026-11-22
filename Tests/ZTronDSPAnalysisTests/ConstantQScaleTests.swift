import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `ConstantQScale` step, the pseudo constant-Q (WP-523): an axis conversion like
/// `MelScale`, and what a stage package delivers with it (STG-1).
@Suite("ConstantQScale")
struct ConstantQScaleTests {
    typealias Scaled<V: SpectralValues> = Spectrum<ConstantQFrequency, V>

    private let rate = 22_050.0
    private var format: SignalFormat { SignalFormat(sampleRate: rate) }

    /// The step a golden case of the pseudo constant-Q describes.
    private func step(of golden: GoldenCase, sparsity: Double) throws -> ConstantQScale {
        ConstantQScale(
            fmin: .hertz(try golden.number("fmin")), octaves: try golden.integer("octaves"), binsPerOctave: try golden.integer("binsPerOctave"),
            tuning: try golden.number("tuning"), filterScale: try golden.number("filterScale"), gamma: try golden.number("gamma"), sparsity: sparsity)
    }

    // MARK: The dense projection in double precision (STG-2)

    @Test(arguments: ["music-semitones", "speech-thirds-of-semitones"])
    func thePseudoConstantQOfTheFixturesEqualsTheDenseProjection(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("pseudo-\(name)")
        let signal = try fixture(of: golden)
        let frame = try golden.integer("frame"), hop = try golden.integer("hop"), bins = try golden.integer("bins"), frames = try golden.integer("frames")
        let scale = try step(of: golden, sparsity: 0)
        let stft = STFT(frame: frame, hop: hop)
        // Magnitudes through the magnitude of the response; powers through its square.
        let magnitudes: [[Float]] = try Pipeline { stft; Magnitude(); scale }.process(signal.samples, format: signal.format, blockSize: 441)
        let powers: [[Float]] = try Pipeline { stft; Power(); scale }.process(signal.samples, format: signal.format, blockSize: 441)
        let referenceMagnitudes = try golden.real("magnitudes"), referencePowers = try golden.real("powers")
        #expect(magnitudes.count == frames && powers.count == frames && magnitudes.allSatisfy { $0.count == bins })
        var worstMagnitude = 0.0, worstPower = 0.0
        for index in 0 ..< min(frames, magnitudes.count) {
            let range = index * bins ..< (index + 1) * bins
            expectClose(magnitudes[index], Array(referenceMagnitudes[range]), .relativeToMaximum(1e-5), "\(name), magnitudes, frame \(index)")
            expectClose(powers[index], Array(referencePowers[range]), .relativeToMaximum(1e-5), "\(name), powers, frame \(index)")
            for (read, reference, slot) in [(magnitudes[index], Array(referenceMagnitudes[range]), 0), (powers[index], Array(referencePowers[range]), 1)] {
                let largest = reference.map { abs($0) }.max() ?? 0
                guard largest > 0 else { continue }
                let off = zip(read, reference).map { abs(Double($0) - $1) }.max() ?? 0
                if slot == 0 { worstMagnitude = max(worstMagnitude, off / largest) } else { worstPower = max(worstPower, off / largest) }
            }
        }
        print("measured WP-523: \(name): magnitudes within \(worstMagnitude), powers within \(worstPower) of the frame maximum of the dense projection in double precision")
        // The response of a band is 1 at its centre, which lies between two bins of the frame.
        let geometry = try geometry(of: golden)
        let projection = try ConstantQProjection(geometry: geometry, binCount: frame / 2 + 1, window: .hann, sparsity: 0, squared: false)
        expectClose(projection.bands.map { Double($0.weights.max() ?? 0) }, try golden.real("peakOfResponse"), .absolute(1e-6))
        #expect(projection.bands.allSatisfy { $0.firstBin == 0 && $0.weights.count == frame / 2 + 1 }, "without sparsity a band is every bin")
    }

    @Test func theNodesGiveTheProjectionInDoublePrecisionAndAgreeWithEachOther() throws {
        let signal = TestSignal.whiteNoise(count: 16_000, seed: 523, amplitude: 0.5)
        let stft = STFT(frame: 2_048, hop: 512)
        let scale = ConstantQScale(fmin: .hertz(220), octaves: 5, binsPerOctave: 12, tuning: 0.2, filterScale: 0.9)
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 5, binsPerOctave: 12, tuning: 0.2, filterScale: 0.9, sampleRate: rate)
        for squared in [false, true] {
            let projection = try ConstantQProjection(geometry: geometry, binCount: 1_025, window: .hann, sparsity: 0.01, squared: squared)
            let linear: Pipeline<Samples, Spectrum<LinearFrequency, MagnitudeValues>> = Pipeline { stft; Magnitude() }
            let squares: Pipeline<Samples, Spectrum<LinearFrequency, PowerValues>> = Pipeline { stft; Power() }
            let spectra: [[Float]] = squared ? try squares.process(signal, format: format) : try linear.process(signal, format: format)
            func frames(_ implementation: Implementation?, crossovers: CrossoverTable = .shipped) throws -> [[Float]] {
                let scaledMagnitudes = linear.appending(scale.stageDescription, producing: Scaled<MagnitudeValues>.self)
                let scaledPowers = squares.appending(scale.stageDescription, producing: Scaled<PowerValues>.self)
                if let implementation {
                    return squared ? try scaledPowers.environment(\.implementation, implementation).process(signal, format: format)
                        : try scaledMagnitudes.environment(\.implementation, implementation).process(signal, format: format)
                }
                return squared ? try scaledPowers.process(signal, format: format, crossovers: crossovers)
                    : try scaledMagnitudes.process(signal, format: format, crossovers: crossovers)
            }
            let banded = try frames(.native), dense = try frames(.accelerate), automatic = try frames(nil)
            #expect(banded.count == spectra.count && dense.count == spectra.count && banded.count == 28)
            for index in banded.indices {
                let exact = projection.applied(to: spectra[index])
                expectClose(banded[index], exact, .relativeToMaximum(1e-5), "banded, \(squared ? "powers" : "magnitudes"), frame \(index)")
                expectClose(dense[index], exact, .relativeToMaximum(1e-5), "dense, frame \(index)")
                expectClose(dense[index], banded[index], .relative(1e-4), "the implementations of one primitive agree (SEL-6)")
                expectClose(automatic[index], banded[index], .relative(1e-4), "below the crossover the automatic choice is the banded one")
            }
            // Above the crossover the automatic choice is the dense product: bands × bins decide (§7.4).
            #expect(try frames(nil, crossovers: CrossoverTable(melDense: 1_000)) == dense)
        }
        #expect(nodeNames(try lowered(Pipeline { stft; Magnitude(); scale }, sampleRate: rate).steps) == ["STFT", "Magnitude", "ConstantQScale"])
    }

    // MARK: The weights

    @Test func aBandIsTheResponseOfItsAtomAroundItsCentre() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 5, binsPerOctave: 12, sampleRate: rate)
        let magnitudes = try ConstantQProjection(geometry: geometry, binCount: 2_049, window: .hann, sparsity: 0.01, squared: false)
        let powers = try ConstantQProjection(geometry: geometry, binCount: 2_049, window: .hann, sparsity: 0.01, squared: true)
        let whole = try ConstantQProjection(geometry: geometry, binCount: 2_049, window: .hann, sparsity: 0, squared: false)
        #expect(magnitudes.bandCount == 60 && magnitudes.binCount == 2_049 && powers.bandCount == 60)
        let width = rate / 4_096
        for (index, band) in magnitudes.bands.enumerated() {
            let centre = geometry.frequency(ofBin: index)
            let nearest = Int((centre / width).rounded())
            #expect(band.firstBin <= nearest && nearest < band.firstBin + band.weights.count, "band \(index) holds the bin nearest to its centre")
            #expect(band.weights.allSatisfy { $0 >= 0 && $0 <= 1 + 1e-6 } && band.weights.count >= 3, "band \(index)")
            // The largest weight is the response next to the centre: 1, less what half a bin of the frame costs.
            let peak = band.weights.max() ?? 0
            let position = band.firstBin + (band.weights.firstIndex(of: peak) ?? 0)
            #expect(abs(position - nearest) <= 1 && peak >= 0.84, "band \(index): \(peak) at bin \(position), the centre is at bin \(centre / width)")
            // The response of a Hann window of N samples, by its closed form, at the band's bins.
            let length = Double(geometry.atomLength(ofBin: index))
            for (offset, weight) in band.weights.enumerated() where abs(Double(band.firstBin + offset) * width - centre) < 1.5 * rate / length {
                let x = (Double(band.firstBin + offset) * width - centre) * length / rate
                let response = abs(x) < 1e-9 ? 1 : abs(sin(.pi * x) / (.pi * x) / (1 - x * x))
                expectClose(weight, response, .absolute(2e-3), "band \(index), \(x) bins of its atom off the centre")
            }
            // The weights of a spectrum of powers are the squares of those of magnitudes.
            #expect(powers.bands[index].firstBin == band.firstBin)
            expectClose(powers.bands[index].weights, band.weights.map { $0 * $0 }, .absolute(1e-6))
            // A thinned band is a run of the whole one, as it is.
            #expect(Array(whole.bands[index].weights[band.firstBin ..< band.firstBin + band.weights.count]) == band.weights)
        }
        // The lower the band, the narrower in hertz: fewer bins of the frame.
        #expect(magnitudes.bands[0].weights.count < magnitudes.bands[59].weights.count)
        let dense = magnitudes.denseWeights()
        #expect(dense.count == 60 * 2_049 && dense.filter { $0 != 0 }.count <= magnitudes.bands.reduce(0) { $0 + $1.weights.count })
        let ones = [Float](repeating: 1, count: 2_049)
        expectClose(magnitudes.applied(to: ones), magnitudes.bands.map { $0.weights.reduce(0, +) }, .relative(1e-6))
        #expect(magnitudes.applied(to: [1, 1]).allSatisfy { $0 == 0 }, "bins a spectrum does not have count as zero")
        let again = try ConstantQProjection(geometry: geometry, binCount: 2_049, window: .hann, sparsity: 0.01, squared: false)
        #expect(magnitudes == again && magnitudes.hashValue == again.hashValue && magnitudes != powers && magnitudes != whole)
    }

    @Test func aToneAtABinCentrePeaksInItsBin() throws {
        // One signal, a tone at each bin centre after the other, two frames long each.
        let scale = ConstantQScale(fmin: .hertz(220), octaves: 5, binsPerOctave: 12)
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 5, binsPerOctave: 12, sampleRate: rate)
        var signal: [Float] = []
        for bin in 0 ..< 60 {
            signal += TestSignal.sine(frequency: geometry.frequency(ofBin: bin), sampleRate: rate, count: 8_192, amplitude: 0.5, phase: Double(bin))
        }
        let stft = STFT(frame: 4_096, hop: 1_024, normalization: .amplitude)
        let magnitudes: [[Float]] = try Pipeline { stft; Magnitude(); scale }.process(signal, format: format)
        let powers: [[Float]] = try Pipeline { stft; Power(); scale }.process(signal, format: format)
        #expect(magnitudes.count == (signal.count - 4_096) / 1_024 + 1 && powers.count == magnitudes.count)
        for bin in 0 ..< 60 {
            // Frame 8·bin + 2 lies wholly inside the tone of the bin.
            let frame = magnitudes[8 * bin + 2], squares = powers[8 * bin + 2]
            #expect(indexOfMaximum(frame.map(Double.init)) == bin && indexOfMaximum(squares.map(Double.init)) == bin, "bin \(bin)")
            // A band sums what the frame's own window spreads over the bins around the tone.
            #expect(frame[bin] > 0.5 && frame[bin] < 1.1, "bin \(bin) reads \(frame[bin])")
        }
    }

    // MARK: Downstream (ENV-1, VC-5)

    @Test func downstreamTheAxisIsConstantQAndChromaFoldFollows() throws {
        let sink = CollectingSink<Scaled<DecibelValues>>()
        let scale = ConstantQScale(fmin: .hertz(110), octaves: 6, binsPerOctave: 12, tuning: 0.25)
        try Pipeline { STFT(frame: 4_096, hop: 512); Power(); scale; Decibels(); Emit(to: sink) }
            .run(on: TestSignal.whiteNoise(count: 9_000, seed: 4), format: format)
        let geometry = try ConstantQGeometry(minimumFrequency: 110, octaves: 6, binsPerOctave: 12, tuning: 0.25, sampleRate: rate)
        #expect(sink.axis == geometry.axis && sink.axis == .constantQ(minimumFrequency: 110 * pow(2, 0.25 / 12), binsPerOctave: 12, binCount: 72))
        #expect(sink.reals.count == 10 && sink.reals.allSatisfy { $0.count == 72 })
        #expect(sink.environment?.frameSize == 4_096 && sink.environment?.hopSize == 512 && sink.environment?.latency == 0, "the framing is that of the STFT")
        let feed = HeatmapFeed(history: 16)
        try Pipeline { STFT(frame: 4_096, hop: 512); Power(); scale; Decibels(); Emit(to: feed) }.run(on: TestSignal.whiteNoise(count: 9_000, seed: 4), format: format)
        #expect(feed.axis == geometry.axis && feed.rowCount == 72 && feed.snapshot().values == sink.reals.flatMap { $0 })
        // The magnitudes fold into chroma: an A sounds, class 9 is the strongest.
        let chroma: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 512); Magnitude(); ConstantQScale(fmin: .hertz(110), octaves: 6, binsPerOctave: 12); ChromaFold() }
            .process(TestSignal.sine(frequency: 880, sampleRate: rate, count: 9_000, amplitude: 0.5), format: format)
        #expect(chroma.count == 10 && chroma.allSatisfy { $0.count == 12 && indexOfMaximum($0.map(Double.init)) == 9 && $0[9] == 1 })
    }

    // MARK: Attach-time checks

    @Test func aBinTheFrameDoesNotResolveIsRefusedAndTheErrorNamesTheFrameThatWould() throws {
        func failure(_ scale: ConstantQScale, frame: Int = 2_048, rate: Double = 22_050) -> DSPError? {
            do {
                let _: [[Float]] = try Pipeline { STFT(frame: frame, hop: frame / 4); Magnitude(); scale }.process(TestSignal.silence(count: 2 * frame), format: SignalFormat(sampleRate: rate))
                return nil
            } catch {
                return error
            }
        }
        // The defaults of §6.8 start on C1: an atom of 34 683 samples at 22.05 kHz.
        let unresolved = try #require(failure(ConstantQScale()))
        guard case .invalidParameter(let stage, let parameter, let reason) = unresolved else {
            Issue.record("not an invalid parameter: \(unresolved)")
            return
        }
        #expect(stage.stageName == "ConstantQScale" && parameter == "fmin")
        #expect(reason.contains("an atom of 34683 samples") && reason.contains("longer than the frame of 2048 samples") && reason.contains("A frame of 40960 samples holds it")
                && reason.contains("this frame holds the bins from 553.8"), "\(reason)")
        // What the error advises is right. This frame holds the bins from 553.9 Hz up …
        #expect(failure(ConstantQScale(fmin: .hertz(553.9), octaves: 4)) == nil && failure(ConstantQScale(fmin: .hertz(553), octaves: 4)) != nil)
        // … and the frame it names holds the lowest bin, where the transform length before it does not.
        let semitones = ConstantQScale(fmin: .hertz(220), octaves: 4, binsPerOctave: 12)
        let short = try #require(failure(semitones, frame: 1_024))
        #expect("\(short)".contains("an atom of 1686 samples") && "\(short)".contains("A frame of 1920 samples holds it"), "\(short)")
        #expect(failure(semitones, frame: 1_920) == nil && failure(semitones, frame: 1_536) != nil)
        // The frame decides, not the transform it is padded to.
        let padded = errorMessage {
            let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256, paddedTo: 4_096); Magnitude(); ConstantQScale(fmin: .hertz(553.9), octaves: 4) }
                .process(TestSignal.silence(count: 4_096), format: format)
        }
        #expect(padded?.contains("longer than the frame of 1024 samples") == true, "\(padded ?? "attached")")

        func named(_ error: DSPError?) -> String? {
            if case .invalidParameter(_, let name, _)? = error { return name }
            return nil
        }
        #expect(named(failure(ConstantQScale(fmin: .hertz(600), octaves: 5))) == "octaves", "bins that reach the Nyquist frequency")
        #expect(named(failure(ConstantQScale(fmin: .hertz(-1), octaves: 4))) == "fmin" && named(failure(ConstantQScale(fmin: .hertz(0), octaves: 4))) == "fmin")
        #expect(named(failure(ConstantQScale(fmin: .hertz(600), octaves: 4, sparsity: 1))) == "sparsity")
        #expect(named(failure(ConstantQScale(fmin: .hertz(600), octaves: 4, window: .hann.half))) == "window")
        #expect(named(failure(ConstantQScale(fmin: .hertz(600), octaves: 4, binsPerOctave: 0))) == "binsPerOctave")
        #expect(named(failure(ConstantQScale(fmin: .hertz(600), octaves: 4, binsPerOctave: 1))) == "binsPerOctave", "atoms of one period")
        #expect(failure(ConstantQScale(fmin: .hertz(600), octaves: 4, window: .custom { _ in 0 })) != nil, "WIN-3")
        #expect(failure(ConstantQScale(fmin: .hertz(600), octaves: 3, binsPerOctave: 24, tuning: -0.5, filterScale: 0.5, gamma: 3, window: .blackmanHarris, sparsity: 0.1)) == nil)
        #expect(failure(ConstantQScale(fmin: .fractionOfNyquist(0.1), octaves: 2)) == nil, "a frequency in any unit")
    }

    @Test func whereItsScopeIsMissingTheStepIsATypedError() {
        typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
        let scale = ConstantQScale(fmin: .hertz(3_000), octaves: 2, binsPerOctave: 12)
        func refusal(_ frames: FixedFrames<Magnitudes>) -> String? {
            errorMessage { try Pipeline { frames; scale }.emit(to: CollectingSink<Scaled<MagnitudeValues>>()).run(on: TestSignal.silence(count: 600), format: mono48) }
        }
        #expect(refusal(FixedFrames([Float](repeating: 1, count: 33)))?.contains("ConstantQScale needs the frames of a spectral scope on a linear-frequency axis") == true)
        // 26 bins are those of a transform of 50 points, which the response cannot be laid on.
        let odd = FixedFrames<Magnitudes>([Float](repeating: 1, count: 26), scope: .spectral(frameSize: 50, hopSize: 10, axis: .linearFrequency(binCount: 26, nyquist: 24_000)))
        #expect(refusal(odd)?.contains("a transform of 50 points, which is none") == true)
        let even = FixedFrames<Magnitudes>([Float](repeating: 1, count: 257), scope: .spectral(frameSize: 512, hopSize: 128, axis: .linearFrequency(binCount: 257, nyquist: 24_000)))
        #expect(refusal(even) == nil)
    }

    // MARK: Order, both tiers

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() {
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.complex, .magnitude, .power, .decibel] {
                let accepted = axis == .linear && (values == .magnitude || values == .power)
                #expect(ConstantQScale.rule(.spectrum(axis: axis, values: values)) == (accepted ? .spectrum(axis: .constantQ, values: values) : nil), "\(axis), \(values)")
            }
        }
        for tag in [DomainTag.samples, .scalar, .quefrency, .melCepstrum, .chroma] { #expect(ConstantQScale.rule(tag) == nil) }
    }

    @Test func aWrongOrderIsRefusedOnTheDescriptions() throws {
        let spectrum = try DynamicPipeline().appending(STFT(frame: 4_096, hop: 512))
        let scale = ConstantQScale(fmin: .hertz(600), octaves: 4).stageDescription
        #expect(throws: DSPError.self) { _ = try spectrum.appending(scale) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(Decibels().stageDescription).appending(scale) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(scale).appending(scale) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(MelScale(bands: 20).stageDescription).appending(scale) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(scale) }
        #expect(try spectrum.appending(Magnitude().stageDescription).appending(scale).outputTag == .spectrum(axis: .constantQ, values: .magnitude))
        #expect(try spectrum.appending(Power().stageDescription).appending(scale).outputTag == .spectrum(axis: .constantQ, values: .power))
    }

    @Test func descriptionsAndActivation() throws {
        let stft = STFT(frame: 4_096, hop: 512)
        #expect(Pipeline { stft; Power(); ConstantQScale(fmin: .hertz(600), octaves: 4, binsPerOctave: 24, tuning: 0.1, filterScale: 2, gamma: 1, window: .hamming, sparsity: 0.05) }
            == Pipeline().appending(stft).power().constantQScale(fmin: .hertz(600), octaves: 4, binsPerOctave: 24, tuning: 0.1, filterScale: 2, gamma: 1, window: .hamming, sparsity: 0.05))
        #expect(Pipeline { stft; Magnitude(); ConstantQScale() }
            == Pipeline().appending(stft).magnitude().constantQScale(fmin: .midiNote(24), octaves: 7, binsPerOctave: 36, tuning: 0, filterScale: 1, gamma: 0, window: .hann, sparsity: 0.01, isActive: true))
        let different: [ConstantQScale] = [
            ConstantQScale(fmin: .midiNote(25)), ConstantQScale(octaves: 6), ConstantQScale(binsPerOctave: 12), ConstantQScale(tuning: 0.5), ConstantQScale(filterScale: 2),
            ConstantQScale(gamma: 2), ConstantQScale(window: .hamming), ConstantQScale(sparsity: 0.1), ConstantQScale(isActive: false),
        ]
        for step in different { #expect(Pipeline { stft; Power(); step } != Pipeline { stft; Power(); ConstantQScale() }) }
        let defaults = ConstantQScale()
        #expect(defaults.fmin == .midiNote(24) && defaults.octaves == 7 && defaults.binsPerOctave == 36 && defaults.tuning == 0 && defaults.filterScale == 1)
        #expect(defaults.gamma == 0 && defaults.window == .hann && defaults.sparsity == 0.01 && defaults.activation == .active && ConstantQScale.stageName == "ConstantQScale")

        let dark = CollectingSink<Scaled<PowerValues>>()
        try Pipeline { stft; Power(); ConstantQScale(fmin: .hertz(600), octaves: 4, isActive: false); Emit(to: dark) }.run(on: TestSignal.silence(count: 9_000), format: format)
        #expect(dark.frameCount == 0, "switched off, it suspends its branch (ACT-3)")
    }

    // MARK: Cold start, latency, the real-time audit (STG-1, RT-7)

    @Test func theNodesKeepNothingAndAddNoDelay() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 600, octaves: 4, binsPerOctave: 12, sampleRate: rate)
        let projection = try ConstantQProjection(geometry: geometry, binCount: 1_025, window: .hann, sparsity: 0.01, squared: false)
        let nodes: [any AnalysisNode] = [try BandedConstantQNode(projection, crossovers: .shipped, requested: .automatic), try DenseConstantQNode(projection)]
        for node in nodes { #expect(node.latencyFrames == 0 && node.settlingFrames == 0, "\(type(of: node))") }
        // One frame in, one frame out: after a cold start the frames are those of the framing before them.
        let noise = TestSignal.whiteNoise(count: 9_000, seed: 77, amplitude: 0.5)
        for implementation in [Implementation.native, .accelerate] {
            let pipeline = Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); ConstantQScale(fmin: .hertz(600), octaves: 4, binsPerOctave: 12) }
                .environment(\.implementation, implementation)
            let cold = try twoPasses(of: pipeline, on: noise, coldStart: true, format: format)
            let half = cold.frameCount / 2
            #expect(half == 14 && Array(cold.reals[..<half]) == Array(cold.reals[half...]) && Array(cold.times[..<half]) == Array(cold.times[half...]), "\(implementation)")
        }
    }

    @Test func theNodesRunWithoutAllocating() throws {
        let banded = CountingSink<Scaled<PowerValues>>(), dense = CountingSink<Scaled<MagnitudeValues>>()
        try expectNoAllocationsRunning(Pipeline { STFT(frame: 4_096, hop: 512); Power(); ConstantQScale(fmin: .hertz(700), octaves: 5); Emit(to: banded) })
        #expect(banded.frames > 990)
        try expectNoAllocationsRunning(
            Pipeline { STFT(frame: 2_048, hop: 256); Magnitude(); ConstantQScale(fmin: .hertz(1_200), octaves: 4, binsPerOctave: 12); Emit(to: dense) }
                .environment(\.implementation, .accelerate))
        #expect(dense.frames > 1_990)
    }
}
