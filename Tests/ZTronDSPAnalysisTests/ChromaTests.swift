import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A chroma normalisation of the tests' own: a strategy written outside the package is passed
/// the same way as a stock one (§5.3). It divides by twice the largest value.
struct HalvingChromaNormalization: ChromaNormalization {
    func norm(of chroma: UnsafeBufferPointer<Float>) -> Float {
        var largest: Float = 0
        var index = 0
        while index < chroma.count {
            if chroma[index] > largest { largest = chroma[index] }
            index += 1
        }
        return 2 * largest
    }
}

/// The `ChromaFold` step with its normalisations and the `ChromaCQT` recipe (WP-524): the
/// chroma acceptance of §6.8, and what a stage package delivers (STG-1).
@Suite("Chroma")
struct ChromaTests {
    typealias Magnitudes = Spectrum<ConstantQFrequency, MagnitudeValues>

    private let rate = 22_050.0
    private var format: SignalFormat { SignalFormat(sampleRate: rate) }

    /// Constant-Q magnitudes no signal need be found for: one frame per block, on an axis of
    /// `binsPerOctave` bins per octave from `fmin`.
    private func frames(_ values: [Float], fmin: Double = noteFrequency(36), binsPerOctave: Int = 12) -> FixedFrames<Magnitudes> {
        FixedFrames(values, scope: .spectral(frameSize: 4_096, hopSize: 512, axis: .constantQ(minimumFrequency: fmin, binsPerOctave: binsPerOctave, binCount: values.count)))
    }

    private func chroma(_ values: [Float], fmin: Double = noteFrequency(36), binsPerOctave: Int = 12, _ fold: ChromaFold = ChromaFold()) throws -> [Float] {
        let result: [[Float]] = try Pipeline { frames(values, fmin: fmin, binsPerOctave: binsPerOctave); fold }.process(TestSignal.silence(count: 512), format: mono48)
        return try #require(result.first)
    }

    // MARK: The acceptance of §6.8

    @Test func theStrongestPitchClassIsRightForEveryClassInEveryOctave() throws {
        // C1 … B7: every pitch class in each of the seven octaves of the default transform.
        let transform = Pipeline { ConstantQ(); Magnitude(); ChromaFold() }
        var weakest: Float = 1
        for note in 24 ..< 108 {
            let tone = TestSignal.sine(frequency: noteFrequency(Double(note)), sampleRate: rate, count: 30_000, amplitude: 0.5, phase: Double(note))
            let frames: [[Float]] = try transform.process(tone, format: format)
            let last = try #require(frames.last)
            #expect(last.count == 12 && indexOfMaximum(last.map(Double.init)) == note % 12, "note \(note), \(FeedAxis.pitchClassNames[note % 12])\(note / 12 - 1): \(last)")
            #expect(last[note % 12] == 1, "under .max the strongest class reads 1")
            // The next strongest class is far below it.
            let runnerUp = last.enumerated().filter { $0.offset != note % 12 }.map { $0.element }.max() ?? 0
            weakest = min(weakest, 1 - runnerUp)
        }
        #expect(weakest > 0.9, "the strongest class leads the next by \(weakest) at least")
    }

    @Test func aChordReadsItsNotes() throws {
        // A minor in three octaves: A, C and E are the three strongest classes.
        var chord = [Float](repeating: 0, count: 30_000)
        for note in [45, 48, 52, 57, 60, 64, 69, 72, 76] {
            let tone = TestSignal.sine(frequency: noteFrequency(Double(note)), sampleRate: rate, count: chord.count, amplitude: 0.1, phase: Double(note))
            for index in chord.indices { chord[index] += tone[index] }
        }
        let frames: [[Float]] = try Pipeline { ConstantQ(); Magnitude(); ChromaFold(normalization: .l1) }.process(chord, format: format)
        let last = try #require(frames.last)
        let strongest = Set(last.enumerated().sorted { $0.element > $1.element }.prefix(3).map { $0.offset })
        #expect(strongest == [9, 0, 4], "\(last)")
        expectClose(last.reduce(0, +), 1, .absolute(1e-5), "under .l1 a frame adds up to 1")
        #expect(last[9] > 0.25 && last[0] > 0.25 && last[4] > 0.25)
    }

    @Test(arguments: ["music-defaults", "speech-semitones", "music-variable-q", "music-top-octave"])
    func theChromaOfTheFixturesIsThatOfTheReference(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("transform-\(name)")
        let signal = try fixture(of: golden)
        let reference = try golden.real("chroma"), sums = try golden.real("chromaSums")
        let transform = try constantQ(of: golden)
        let normalised: [[Float]] = try Pipeline { transform; Magnitude(); ChromaFold() }.process(signal.samples, format: signal.format, blockSize: 441)
        let plain: [[Float]] = try Pipeline { transform; Magnitude(); ChromaFold(normalization: .none) }.process(signal.samples, format: signal.format, blockSize: 441)
        let frames = try golden.integer("frames")
        #expect(normalised.count > 5 && normalised.count <= frames && plain.count == normalised.count)
        // The largest pitch-class sum of the excerpt: what the sums are held against.
        let peak = sums[..<(normalised.count * 12)].max() ?? 0
        var least = 1.0, worstSum = 0.0
        for frame in normalised.indices {
            let expected = Array(reference[frame * 12 ..< (frame + 1) * 12])
            least = min(least, cosineSimilarity(normalised[frame].map(Double.init), expected))
            #expect(normalised[frame].max() == 1 && normalised[frame].allSatisfy { $0 >= 0 && $0 <= 1 }, "frame \(frame)")
            // Without normalisation: the sums of the magnitudes themselves.
            for index in 0 ..< 12 { worstSum = max(worstSum, abs(Double(plain[frame][index]) - sums[frame * 12 + index]) / peak) }
        }
        #expect(least >= 0.98, "\(name): the least frame-wise cosine similarity to the reference chroma is \(least); 0.98 is asked for (§6.8)")
        #expect(least >= 0.998, "\(name): … and measures \(least)")
        #expect(worstSum <= 0.01, "\(name): a pitch-class sum is off by \(worstSum) of the largest of the excerpt")
    }

    @Test func silenceGivesZeros() throws {
        func fold<N: ChromaNormalization>(_ normalization: N) throws -> [[Float]] {
            try Pipeline { ConstantQ(); Magnitude(); ChromaFold(normalization: normalization) }.process(TestSignal.silence(count: 25_000), format: format)
        }
        for frames in [try fold(.max), try fold(.l1), try fold(.l2), try fold(.none), try fold(HalvingChromaNormalization())] {
            #expect(frames.count > 5 && frames.allSatisfy { $0.count == 12 && $0.allSatisfy { $0 == 0 } }, "twelve zeros, and no NaN (NUM-1)")
        }
        // Through the recipe, into a feed.
        let feed = HeatmapFeed(history: 16)
        try Pipeline { ChromaCQT(to: feed) }.run(on: TestSignal.silence(count: 25_000), format: format)
        #expect(feed.columnCount > 5 && feed.snapshot().values.allSatisfy { $0 == 0 })
    }

    // MARK: Folding

    @Test func aBinBelongsToTheClassOfTheSemitoneNearestToIt() {
        // 36 bins per octave from a C: the bin on the semitone and its two neighbours.
        let thirds = ChromaFold.pitchClasses(minimumFrequency: noteFrequency(24), binsPerOctave: 36, binCount: 252)
        #expect(Array(thirds[0 ..< 8]) == [0, 0, 1, 1, 1, 2, 2, 2] && Array(thirds[33 ..< 38]) == [11, 11, 0, 0, 0])
        for bin in 0 ..< 252 {
            let expected = Int32(Int((Double(bin) / 3).rounded()) % 12)
            #expect(thirds[bin] == expected, "bin \(bin)")
        }
        for pitchClass in 0 ..< 12 {
            let members = thirds.filter { $0 == Int32(pitchClass) }.count
            #expect(members == 21, "three bins in each of seven octaves")
        }
        // One bin per semitone: bin k is class k mod 12, from whatever note the bins start on.
        let fromC: [Int32] = (0 ..< 24).map { Int32($0 % 12) }, fromA: [Int32] = (0 ..< 13).map { Int32(($0 + 9) % 12) }
        #expect(ChromaFold.pitchClasses(minimumFrequency: noteFrequency(36), binsPerOctave: 12, binCount: 24) == fromC)
        #expect(ChromaFold.pitchClasses(minimumFrequency: 55, binsPerOctave: 12, binCount: 13) == fromA, "from an A")
        #expect(ChromaFold.pitchClasses(minimumFrequency: 440, binsPerOctave: 12, binCount: 4) == [9, 10, 11, 0])
        // Quarter tones: the bin halfway between two semitones goes with the upper one.
        #expect(ChromaFold.pitchClasses(minimumFrequency: noteFrequency(60), binsPerOctave: 24, binCount: 6) == [0, 1, 1, 2, 2, 3])
        // Tuning has moved the bins, not the classes: bin 0 a quarter of a semitone above a C is still a C.
        #expect(ChromaFold.pitchClasses(minimumFrequency: noteFrequency(36.25), binsPerOctave: 12, binCount: 3) == [0, 1, 2])
        #expect(ChromaFold.pitchClasses(minimumFrequency: noteFrequency(35.75), binsPerOctave: 12, binCount: 3) == [0, 1, 2])
        // Below MIDI note 0 as well.
        #expect(ChromaFold.pitchClasses(minimumFrequency: noteFrequency(-3), binsPerOctave: 12, binCount: 2) == [9, 10])
    }

    @Test func theMagnitudesOfAClassAreSummedThresholdedAndNormalised() throws {
        // Two octaves of semitones from C2: bin k holds k + 1, so class c sums (c + 1) + (c + 13).
        let values = (0 ..< 24).map { Float($0 + 1) }
        let sums = (0 ..< 12).map { Float(2 * $0 + 14) }
        #expect(try chroma(values, ChromaFold(normalization: .none)) == sums)
        expectClose(try chroma(values, ChromaFold(normalization: .max)), sums.map { $0 / 36 }, .relative(1e-6))
        expectClose(try chroma(values, ChromaFold(normalization: .l1)), sums.map { $0 / 300 }, .relative(1e-6))
        expectClose(try chroma(values, ChromaFold(normalization: .l2)), sums.map { $0 / Float(8_072).squareRoot() }, .relative(1e-6))
        expectClose(try chroma(values, ChromaFold(normalization: HalvingChromaNormalization())), sums.map { $0 / 72 }, .relative(1e-6))
        #expect(try chroma(values) == chroma(values, ChromaFold(normalization: .max)), "the default is .max")

        // What lies below the threshold is discarded before the frame is normalised.
        let thresholded = try chroma(values, ChromaFold(normalization: .l1, threshold: 25))
        #expect(Array(thresholded[..<6]) == [0, 0, 0, 0, 0, 0], "sums of 14 … 24 lie below 25")
        expectClose(Array(thresholded[6...]), [26, 28, 30, 32, 34, 36].map { Float($0) / 186 }, .relative(1e-6))
        #expect(try chroma(values, ChromaFold(normalization: .none, threshold: 26)) == [0, 0, 0, 0, 0, 0, 26, 28, 30, 32, 34, 36], "a sum on the threshold stays")
        #expect(try chroma(values, ChromaFold(threshold: 40)) == [Float](repeating: 0, count: 12), "everything discarded: twelve zeros")
        // From another note, the classes turn with it: bins from an A.
        let fromA = try chroma([1, 0, 0, 5], fmin: 110, ChromaFold(normalization: .none))
        #expect(fromA[9] == 1 && fromA[0] == 5 && fromA.reduce(0, +) == 6, "\(fromA)")
    }

    @Test func aFrameBelowTheFloorIsTwelveZeros() throws {
        let faint = [Float](repeating: 1e-12, count: 24)
        #expect(try chroma(faint) == [Float](repeating: 0, count: 12), "a largest sum of 2·10⁻¹² lies below the floor of 10⁻¹⁰")
        #expect(try chroma(faint, ChromaFold(floor: 1e-13)) == [Float](repeating: 1, count: 12), "above its floor a frame is divided by its norm")
        #expect(try chroma(faint, ChromaFold(normalization: .none)).allSatisfy { $0 == 2e-12 }, "without a norm there is nothing to divide by")
        #expect(try chroma([Float](repeating: 0, count: 24), ChromaFold(floor: 0)) == [Float](repeating: 0, count: 12), "0 / 0 is twelve zeros whatever the floor")
        // Magnitudes single precision cannot add: twelve zeros, not infinity or NaN (NUM-1).
        let huge = [Float](repeating: .greatestFiniteMagnitude, count: 24)
        for fold in [ChromaFold(), ChromaFold(normalization: .none), ChromaFold(normalization: .l2)] {
            #expect(try chroma(huge, fold) == [Float](repeating: 0, count: 12))
        }
        let large = try chroma([Float](repeating: 1e30, count: 24), ChromaFold(normalization: .l2))
        #expect(large.allSatisfy { $0 == 0 }, "squares that overflow have no norm: \(large)")
        #expect(try chroma([Float](repeating: 1e30, count: 24)) == [Float](repeating: 1, count: 12))
    }

    // MARK: Attach-time checks

    @Test func binsThatDoNotFoldOntoTwelveClassesAreRefused() throws {
        func refusal(_ pipeline: Pipeline<Samples, Chroma>) -> String? {
            errorMessage { let _: [[Float]] = try pipeline.process(TestSignal.silence(count: 512), format: mono48) }
        }
        let values = [Float](repeating: 1, count: 30)
        let ten = try #require(refusal(Pipeline { frames(values, binsPerOctave: 10); ChromaFold() }))
        #expect(ten.contains("binsPerOctave") && ten.contains("10 bins per octave") && ten.contains("a multiple of 12") && ten.contains("the nearest is 12"), "\(ten)")
        #expect(refusal(Pipeline { frames(values, binsPerOctave: 30); ChromaFold() })?.contains("the nearest are 24 and 36") == true)
        #expect(refusal(Pipeline { frames(values, binsPerOctave: 0); ChromaFold() }) != nil)
        for bins in [12, 24, 36, 120] { #expect(refusal(Pipeline { frames(values, binsPerOctave: bins); ChromaFold() }) == nil, "\(bins)") }
        // Through the transform, with the stage in the error.
        let attached = try #require(refusal(Pipeline { ConstantQ(binsPerOctave: 30); Magnitude(); ChromaFold() }))
        #expect(attached.contains("the nearest are 24 and 36") && attached.contains("ChromaFold[2]"), "\(attached)")
        #expect(refusal(Pipeline { ChromaCQT(binsPerOctave: 18, to: HeatmapFeed()) }.appending(ConstantQ()).magnitude().chromaFold())?.contains("the nearest are 12 and 24") == true)
        // Thresholds and floors that are no magnitudes.
        #expect(refusal(Pipeline { frames(values); ChromaFold(threshold: -1) })?.contains("threshold") == true)
        #expect(refusal(Pipeline { frames(values); ChromaFold(floor: -1) })?.contains("floor") == true && refusal(Pipeline { frames(values); ChromaFold(floor: .nan) }) != nil)
        // Frames of the right domain without the axis: the types agree, and there is nothing to fold.
        #expect(refusal(Pipeline { FixedFrames<Magnitudes>(values); ChromaFold() })?.contains("ChromaFold needs the bins of a constant-Q spectrum") == true)
        let linear = FixedFrames<Magnitudes>(values, scope: .spectral(frameSize: 58, hopSize: 16, axis: .linearFrequency(binCount: 30, nyquist: 24_000)))
        #expect(refusal(Pipeline { linear; ChromaFold() })?.contains("no constant-Q axis") == true)
    }

    // MARK: Order (O-7), both tiers

    @Test func theRuleOfTheDescriptionAcceptsConstantQMagnitudesOnly() throws {
        let description = try #require(ChromaFold().stageDescriptions.first)
        #expect(description.rule(.spectrum(axis: .constantQ, values: .magnitude)) == .chroma)
        for tag in OrderMatrixTests.domains where tag != .spectrum(axis: .constantQ, values: .magnitude) { #expect(description.rule(tag) == nil, "\(tag)") }

        let stft = try DynamicPipeline().appending(STFT(frame: 4_096, hop: 512)), transform = try DynamicPipeline().appending(ConstantQ())
        // O-7: the bins of an STFT are not spaced by semitones.
        #expect(throws: DSPError.self) { _ = try stft.appending(Magnitude().stageDescription).appending(ChromaFold()) }
        #expect(throws: DSPError.self) { _ = try transform.appending(ChromaFold()) }
        #expect(throws: DSPError.self) { _ = try transform.appending(Power().stageDescription).appending(ChromaFold()) }
        #expect(throws: DSPError.self) { _ = try transform.appending(Magnitude().stageDescription).appending(Decibels().stageDescription).appending(ChromaFold()) }
        #expect(throws: DSPError.self) { _ = try stft.appending(Power().stageDescription).appending(ConstantQScale().stageDescription).appending(ChromaFold()) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(ChromaFold()) }
        #expect(try transform.appending(Magnitude().stageDescription).appending(ChromaFold()).outputTag == .chroma)
        #expect(try stft.appending(Magnitude().stageDescription).appending(ConstantQScale().stageDescription).appending(ChromaFold()).outputTag == .chroma)
        // Nothing that takes a spectrum follows chroma.
        let folded = try transform.appending(Magnitude().stageDescription).appending(ChromaFold())
        #expect(throws: DSPError.self) { _ = try folded.appending(Decibels().stageDescription) }
        #expect(throws: DSPError.self) { _ = try folded.appending(ChromaFold()) }
    }

    @Test func descriptionsAndTheRecipe() throws {
        #expect(Pipeline { ConstantQ(); Magnitude(); ChromaFold(normalization: .l2, threshold: 0.1, floor: 1e-6) }
            == Pipeline().constantQ().magnitude().chromaFold(normalization: .l2, threshold: 0.1, floor: 1e-6))
        #expect(Pipeline { ConstantQ(); Magnitude(); ChromaFold() } == Pipeline().constantQ().magnitude().chromaFold(normalization: .max, threshold: 0, floor: 1e-10, isActive: true))
        let different: [ChromaFold] = [
            ChromaFold(normalization: .l1), ChromaFold(normalization: .l2), ChromaFold(normalization: .none), ChromaFold(normalization: HalvingChromaNormalization()),
            ChromaFold(threshold: 0.5), ChromaFold(floor: 1e-3), ChromaFold(isActive: false),
        ]
        for fold in different { #expect(Pipeline { ConstantQ(); Magnitude(); fold } != Pipeline { ConstantQ(); Magnitude(); ChromaFold() }) }
        #expect(ChromaFold().normalization is MaximumChromaNormalization && ChromaFold(normalization: .l1).normalization is L1ChromaNormalization)
        #expect(ChromaFold(normalization: .l2).normalization is L2ChromaNormalization && ChromaFold(normalization: .none).normalization is UnscaledChromaNormalization)
        #expect(ChromaFold().threshold == 0 && ChromaFold().floor == 1e-10 && ChromaFold().activation == .active && ChromaFold.stageName == "ChromaFold")

        // The recipe is the branch written out (§5.2).
        let feed = HeatmapFeed()
        #expect(Pipeline { ChromaCQT(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, tuning: 0.2, gamma: 3, hop: 256, normalization: .l1, threshold: 0.01, to: feed) }
            == Pipeline { Tap { ConstantQ(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, tuning: 0.2, gamma: 3, hop: 256); Magnitude(); ChromaFold(normalization: .l1, threshold: 0.01); Emit(to: feed) } })
        #expect(Pipeline { ChromaCQT(to: feed) } == Pipeline { Tap { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: feed) } }, "the defaults of §6.8")
        #expect(Pipeline { ChromaCQT(to: feed, isActive: false) } == Pipeline { Tap(isActive: false) { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: feed) } })
        #expect(Pipeline().chromaCQT(octaves: 5, to: feed) == Pipeline { ChromaCQT(octaves: 5, to: feed) })
        #expect(Pipeline().chromaCQT(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, tuning: 0.2, gamma: 3, hop: 256, normalization: .l1, threshold: 0.01, to: feed)
            == Pipeline { ChromaCQT(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, tuning: 0.2, gamma: 3, hop: 256, normalization: .l1, threshold: 0.01, to: feed) })
        #expect(ChromaCQT(to: feed).activation == .active && ChromaCQT(to: feed, isActive: false).activation != .active && ChromaCQT.stageName == "ChromaCQT")
        let recipe = try #require(ChromaCQT(to: feed).stageDescriptions.first)
        #expect(recipe.rule(.samples) == .samples && ChromaCQT(to: feed).stageDescriptions.count == 1)
    }

    @Test @MainActor func theRecipeFeedsAChromagramAndABinding() throws {
        let tone = TestSignal.sine(frequency: noteFrequency(64), sampleRate: rate, count: 30_000, amplitude: 0.5)      // an E
        let feed = HeatmapFeed(history: 64), direct = CollectingSink<Chroma>(), values = StateBox([Float]())
        let output = try Pipeline {
            TestGain(0.5)
            ChromaCQT(to: feed)
            Pipeline().chromaCQT(to: values.binding)
            Tap { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: direct) }
        }.process(tone, format: format)
        #expect(output == tone.map { $0 * 0.5 }, "the samples pass on unchanged")
        // A feed of chroma has the twelve pitch classes as its rows, C first.
        #expect(feed.axis == .pitchClasses && feed.rowCount == 12 && feed.columnCount == direct.frameCount && direct.frameCount > 20)
        #expect(feed.snapshot().values == direct.reals.flatMap { $0 }, "the recipe is the branch written out")
        #expect(direct.axis == .pitchClasses && direct.environment?.frequencyAxis == .pitchClasses && direct.environment?.hopSize == 512)
        let latency = try #require(direct.environment?.latency)
        #expect(latency > 0.8 && feed.snapshot().environment?.latency == latency, "the latency of the transform reaches the feed: \(latency) s")
        #expect(FeedAxis.pitchClasses.unit == .pitchClass && FeedAxis.pitchClassNames[4] == "E")
        // The binding holds the last frame: twelve values, the E the strongest.
        #expect(values.value.count == 12 && values.value == direct.reals.last && values.value[4] == 1, "\(values.value)")
        // Three branches, one transform (F5).
        let lowered = try lowered(Pipeline { ChromaCQT(to: HeatmapFeed()); ChromaCQT(to: HeatmapFeed()); Tap { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: CollectingSink<Chroma>()) } }, sampleRate: rate)
        #expect(nodeNames(lowered.steps) == ["ConstantQ", "Magnitude", "ChromaFold"], "\(nodeNames(lowered.steps))")

        // Switched off, the branch is suspended and the feed stays empty (ACT-3).
        let dark = HeatmapFeed(history: 8), off = StateBox(false)
        try Pipeline { ChromaCQT(to: dark, isActive: false); ChromaCQT(to: HeatmapFeed(), isActive: off.binding) }.run(on: tone, format: format)
        #expect(dark.columnCount == 0)
    }

    // MARK: Cold start, latency, the real-time audit (STG-1, RT-7)

    @Test func theNodeKeepsNothingAndAddsNoDelay() throws {
        let node = try ChromaFoldNode(classes: [0, 5, 11, 40, -3], threshold: 0, floor: 1e-10, normalization: MaximumChromaNormalization())
        #expect(node.latencyFrames == 0 && node.settlingFrames == 0 && ChromaFoldNode.classCount == 12)
        // After a cold start the chroma are those of a fresh stream: what there is to forget is the transform's.
        let noise = TestSignal.whiteNoise(count: 9_000, seed: 77, amplitude: 0.5)
        let pipeline = Pipeline { ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, hop: 64); Magnitude(); ChromaFold(normalization: .l2) }
        let cold = try twoPasses(of: pipeline, on: noise, coldStart: true, format: format)
        let half = cold.frameCount / 2
        #expect(half > 100 && Array(cold.reals[..<half]) == Array(cold.reals[half...]) && Array(cold.times[..<half]) == Array(cold.times[half...]))
        for frame in cold.reals { expectClose(frame.reduce(0) { $0 + $1 * $1 }, 1, .absolute(1e-5), "under .l2 a frame has unit length") }
    }

    @Test func theNodesRunWithoutAllocating() throws {
        let folded = CountingSink<Chroma>(), custom = CountingSink<Chroma>()
        let feed = HeatmapFeed(history: 64)
        try expectNoAllocationsRunning(Pipeline {
            ChromaCQT(to: feed)
            Tap { ConstantQ(fmin: .midiNote(36), octaves: 6, binsPerOctave: 12, gamma: 5, hop: 128); Magnitude(); ChromaFold(normalization: .l1, threshold: 0.01); Emit(to: folded) }
            Tap { ConstantQ(fmin: .midiNote(36), octaves: 6, binsPerOctave: 12, gamma: 5, hop: 128); Magnitude(); ChromaFold(normalization: HalvingChromaNormalization()); Emit(to: custom) }
        })
        #expect(feed.columnCount == 64 && folded.frames > 3_900 && custom.frames == folded.frames)
        let scaled = CountingSink<Chroma>()
        try expectNoAllocationsRunning(Pipeline { STFT(frame: 4_096, hop: 512); Magnitude(); ConstantQScale(fmin: .hertz(440), octaves: 5, binsPerOctave: 12); ChromaFold(); Emit(to: scaled) })
        #expect(scaled.frames > 990)
    }
}
