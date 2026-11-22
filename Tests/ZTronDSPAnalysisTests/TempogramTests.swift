import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// A tempogram method written outside the package's stock set: the energy of the window in
/// one row. It is passed the same way as a stock one (§5.3).
struct EnergyTempogram: TempogramMethod {
    func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform {
        EnergyTransform(window: window, tempo: (range.lowerBound + range.upperBound) / 2)
    }

    final class EnergyTransform: TempogramTransform {
        let beatsPerMinute: [Double]
        private let window: Int

        init(window: Int, tempo: Double) {
            self.window = window
            beatsPerMinute = [tempo]
        }

        func transform(_ segment: UnsafePointer<Float>, into column: UnsafeMutablePointer<Float>) {
            var sum: Float = 0
            var index = 0
            while index < window {
                sum += segment[index] * segment[index]
                index += 1
            }
            column[0] = sum
        }
    }
}

/// A method that gives no row at all.
struct EmptyTempogram: TempogramMethod {
    func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform {
        EnergyTempogram.EnergyTransform(window: window, tempo: .nan)
    }
}

/// The autocorrelation tempogram (WP-526) and the Fourier tempogram (WP-527): the acceptance
/// of §6.9, and what every step owes (STG-1).
@Suite("Tempograms")
struct TempogramTests {
    /// The columns of a tempogram of a novelty curve handed over value by value.
    private func columns(of curve: [Float], rate: Double, _ step: Tempogram, blockSize: Int = 37) throws -> [[Float]] {
        try Pipeline { SamplesAsNovelty(); step }.process(curve, format: SignalFormat(sampleRate: rate), blockSize: blockSize)
    }

    private func step(for golden: GoldenCase) throws -> Tempogram {
        let window = try golden.integer("window"), range = try golden.number("low") ... golden.number("high")
        let taper: Window = try golden.string("taper") == "hamming" ? .hamming : .hann
        let alignment: FrameAlignment = try golden.integer("centred") == 1 ? .centered : .causal
        if try golden.string("method") == "fourier" {
            return Tempogram(.fourier(resolution: try golden.integer("resolution")), window: window, taper: taper, range: range, alignment: alignment)
        }
        return Tempogram(.autocorrelation, window: window, taper: taper, range: range, alignment: alignment)
    }

    /// The least frame-wise cosine similarity, and the largest difference of any value relative
    /// to the largest value of the reference.
    private func compare(_ columns: [[Float]], _ golden: GoldenCase, _ name: String) throws -> (cosine: Double, deviation: Double) {
        let frames = try golden.integer("frames"), rows = try golden.integer("rows")
        let reference = try golden.real("columns")
        #expect(columns.count == frames && columns.allSatisfy { $0.count == rows }, "\(name): \(columns.count) columns of \(columns.first?.count ?? 0) rows")
        guard columns.count == frames, reference.count == frames * rows else { return (0, .infinity) }
        var least = 1.0, deviation = 0.0
        let largest = reference.map { abs($0) }.max() ?? 1
        for (index, column) in columns.enumerated() {
            let wanted = Array(reference[index * rows ..< (index + 1) * rows])
            least = min(least, cosineSimilarity(column, wanted))
            for (a, b) in zip(column, wanted) { deviation = max(deviation, abs(Double(a) - b) / largest) }
        }
        return (least, deviation)
    }

    // MARK: Golden (§6.9): frame-wise cosine similarity ≥ 0.99 against the reference

    static let curveCases = [
        "curve-autocorrelation-384-hann-30-300-causal", "curve-autocorrelation-384-hann-30-300-centred", "curve-fourier-384-hann-30-300-causal-x4",
        "curve-fourier-384-hann-30-300-centred-x4", "curve-autocorrelation-101-hamming-60-240-centred", "curve-fourier-101-hamming-60-240-causal-x8",
        "curve-fourier-128-hann-30-300-centred-x1",
    ]

    @Test(arguments: TempogramTests.curveCases)
    func theTempogramOfACurveEqualsTheReference(name: String) throws {
        let file = try GoldenFile(named: "tempogram", in: .module)
        let fixture = try file.require("curve"), golden = try file.require(name)
        let curve = try fixture.floats("curve"), rate = try fixture.number("featureRate")
        let tempogram = try step(for: golden)
        let result = try compare(try columns(of: curve, rate: rate, tempogram), golden, name)
        print("measured WP-526/527: \(name): least frame-wise cosine similarity \(result.cosine) (tolerance 0.99); largest difference \(result.deviation) of the largest value")
        #expect(result.cosine >= 0.99, "\(name): cosine similarity \(result.cosine)")
        #expect(result.deviation <= 1e-4, "\(name): well inside the acceptance, the values themselves agree to \(result.deviation)")
        // The axis gives the tempo of each row, as the reference computed it.
        let axis = try environmentAtTheEnd(of: Pipeline { SamplesAsNovelty(); tempogram }, sampleRate: rate).frequencyAxis
        guard case .tempo(let tempi)? = axis else { Issue.record("\(name): the axis is \(String(describing: axis)), not tempi"); return }
        expectClose(tempi, try golden.real("beatsPerMinute"), .relative(1e-12), name)
        #expect(zip(tempi, tempi.dropFirst()).allSatisfy { $0 < $1 }, "the rows ascend in tempo")
    }

    @Test(arguments: ["music-autocorrelation-64-hann-30-300-causal", "music-autocorrelation-64-hann-30-300-centred", "music-fourier-64-hann-30-300-causal-x4",
                      "music-fourier-64-hann-30-300-centred-x4"])
    func theTempogramOfTheMusicFixtureEqualsTheReference(name: String) throws {
        // The whole chain, from samples: the reference is the tempogram of the reference curve.
        let file = try GoldenFile(named: "tempogram", in: .module)
        let chain = try file.require("music"), golden = try file.require(name)
        let fixture = try GoldenFile(named: "fixtures", in: .module).require("music")
        let samples = try fixture.floats("samples"), format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        let frame = try chain.integer("frame"), hop = try chain.integer("hop"), bands = try chain.integer("bands")
        let tempogram = try step(for: golden)
        let columns: [[Float]] = try Pipeline {
            STFT(frame: frame, hop: hop, alignment: .centered); Power(); MelScale(bands: bands); Decibels(); OnsetStrength()
            tempogram
        }.process(samples, format: format, blockSize: 441)
        let result = try compare(columns, golden, name)
        print("measured WP-526/527: \(name): least frame-wise cosine similarity \(result.cosine) (tolerance 0.99); largest difference \(result.deviation) of the largest value")
        #expect(result.cosine >= 0.99, "\(name): cosine similarity \(result.cosine)")
    }

    // MARK: A 120 BPM click track (§6.9)

    @Test(arguments: [44_100.0, 48_000.0])
    func aClickTrackAt120BeatsPerMinuteShowsItsTempo(sampleRate: Double) throws {
        let clicks = TestSignal.clickTrack(beatsPerMinute: 120, sampleRate: sampleRate, count: Int(9 * sampleRate))
        let format = SignalFormat(sampleRate: sampleRate), featureRate = sampleRate / 512
        let novelty = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength() }
        func nearest(_ tempo: Double, in tempi: [Double]) -> Int { tempi.indices.min { abs(tempi[$0] - tempo) < abs(tempi[$1] - tempo) } ?? 0 }
        func tempi(_ step: Tempogram) throws -> [Double] {
            guard case .tempo(let rows)? = try environmentAtTheEnd(of: novelty.appending(step), sampleRate: sampleRate).frequencyAxis else { return [] }
            return rows
        }

        // The autocorrelation tempogram: the row nearest to 120 BPM is the largest value of the frame.
        let autocorrelation = Tempogram(.autocorrelation)
        let lags: [[Float]] = try novelty.appending(autocorrelation).process(clicks, format: format)
        let lagTempi = try tempi(autocorrelation)
        let beat = nearest(120, in: lagTempi)
        #expect(lags.count == Int(9 * sampleRate - 2_048) / 512 + 1 - 383 && lags.count > 300, "\(lags.count) columns")
        #expect(abs(lagTempi[beat] - 120) < 1.5, "the row nearest to 120 BPM is \(lagTempi[beat]) BPM")
        for (index, column) in lags.enumerated() {
            let largest = try #require(column.indices.max { column[$0] < column[$1] })
            #expect(largest == beat, "\(sampleRate) Hz, column \(index): the largest value is at \(lagTempi[largest]) BPM")
            #expect(column[beat] > column[beat - 1] && column[beat] > column[beat + 1], "a local maximum")
        }
        // Lag ℓ is 60·featureRate / ℓ beats per minute.
        let period = Int((60 * featureRate / 120).rounded())
        expectClose(lagTempi[beat], 60 * featureRate / Double(period), .relative(1e-12))

        // The Fourier tempogram: the largest values lie on the rows nearest to 120 BPM and its multiple, 240.
        let fourier = Tempogram(.fourier)
        let bins: [[Float]] = try novelty.appending(fourier).process(clicks, format: format)
        let binTempi = try tempi(fourier)
        let first = nearest(120, in: binTempi), second = nearest(240, in: binTempi)
        expectClose(binTempi[1] - binTempi[0], 60 * featureRate / 1_536, .relative(1e-12), "the rows are 60·featureRate / length BPM apart")
        for (index, column) in bins.enumerated() {
            #expect(column[first] > column[first - 1] && column[first] > column[first + 1], "\(sampleRate) Hz, column \(index): a local maximum at \(binTempi[first]) BPM")
            // The two highest peaks of the column are the tempo and its multiple, each within a row.
            let peaks = (1 ..< column.count - 1).filter { column[$0] > column[$0 - 1] && column[$0] >= column[$0 + 1] }.sorted { column[$0] > column[$1] }
            let strongest = Array(peaks.prefix(2))
            #expect(strongest.count == 2 && strongest.contains { abs($0 - first) <= 1 } && strongest.contains { abs($0 - second) <= 1 },
                    "\(sampleRate) Hz, column \(index): the highest peaks are at \(strongest.map { binTempi[$0] }) BPM")
        }
    }

    // MARK: Zero denominators and a mean that would swamp the rows (NUM-1, §7.5 row 15)

    @Test func silenceAndACurveThatDoesNotMoveGiveZeros() throws {
        let rate = 93.75
        for curve in [[Float](repeating: 0, count: 500), [Float](repeating: 7.25, count: 500)] {
            let lags = try columns(of: curve, rate: rate, Tempogram(.autocorrelation))
            #expect(lags.count == 117 && lags.allSatisfy { $0.allSatisfy { $0 == 0 } }, "a value at lag 0 under the floor: zeros, not 0/0")
            let bins = try columns(of: curve, rate: rate, Tempogram(.fourier))
            #expect(bins.count == 117 && bins.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1e-3 } }, "the mean is removed: a constant has no tempo")
        }
        // The same pulses on a pedestal a thousand times their height: the mean is out, the tempo row stands.
        var pulses = [Float](repeating: 0, count: 600)
        for index in stride(from: 0, to: 600, by: 47) { pulses[index] = 1 }
        let plain = try columns(of: pulses, rate: rate, Tempogram(.autocorrelation))
        let lifted = try columns(of: pulses.map { $0 + 1_000 }, rate: rate, Tempogram(.autocorrelation))
        let tempi = (19 ... 187).reversed().map { 60 * rate / Double($0) }
        let beat = try #require(tempi.firstIndex { abs($0 - 60 * rate / 47) < 1e-9 })
        for (a, b) in zip(plain, lifted) {
            #expect(a.indices.max { a[$0] < a[$1] } == beat && b.indices.max { b[$0] < b[$1] } == beat)
            expectClose(b, a, .absolute(2e-2), "the pedestal does not change the picture")
        }
        // The floor is the method's to move.
        #expect(try columns(of: pulses, rate: rate, Tempogram(AutocorrelationTempogram(floor: 1e6))).allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func aValueOfTheCurveThatIsNotFiniteIsTakenAsZero() throws {
        // The non-finite fixture of WP-016 as a novelty curve: a NaN at value 146, +∞ at 341 and
        // −∞ at 512. The entry of a pipeline replaces samples (NUM-1); the values of a step reach
        // the next step as they are, so a stage of the tests' own hands them over.
        let rate = 93.75
        let fixture = StressFixture.nonFiniteSignal(count: 1_024)
        let replaced = fixture.samples.map { $0.isFinite ? $0 : 0 }
        let format = SignalFormat(sampleRate: rate), drive = [Float](repeating: 0, count: fixture.samples.count)
        func columns(_ curve: [Float], _ step: Tempogram) throws -> [[Float]] {
            try Pipeline { CurveAsNovelty(curve); step }.process(drive, format: format, blockSize: 64)
        }
        let handed: [ScalarFrame] = try Pipeline { CurveAsNovelty(fixture.samples) }.process(drive, format: format, blockSize: 64)
        #expect(fixture.nonFiniteCount == 3 && handed.filter { !$0.value.isFinite }.count == 3, "the step is handed the three values as they are")
        var compared = 0, notFinite = 0, unequal = 0
        for step in [Tempogram(.autocorrelation), Tempogram(.fourier), Tempogram(.autocorrelation, alignment: .centered), Tempogram(.fourier, alignment: .centered)] {
            let poisoned = try columns(fixture.samples, step), clean = try columns(replaced, step)
            #expect(poisoned.count == clean.count && poisoned.count >= 641, "\(poisoned.count) columns")
            let wrong = poisoned.reduce(0) { $0 + $1.filter { !$0.isFinite }.count }
            let differing = zip(poisoned, clean).filter { $0.map(\.bitPattern) != $1.map(\.bitPattern) }.count
            #expect(wrong == 0, "no NaN, no infinity (NUM-1): \(wrong) values are not finite")
            #expect(differing == 0, "the columns are those of the curve with its \(fixture.nonFiniteCount) values at 0, bit for bit: \(differing) differ")
            compared += poisoned.count
            notFinite += wrong
            unequal += differing
        }
        print("measured WP-526/527: the non-finite fixture as a curve of 1 024 values, four tempograms: \(compared) columns, \(notFinite) values not finite, \(unequal) columns not those of the curve with its 3 values at 0")
    }

    // MARK: Alignment and latency

    @Test func aCentredColumnIsTheCausalOneOfHalfAWindowLater() throws {
        let rate = 100.0
        let curve = TestSignal.whiteNoise(count: 400, seed: 526, amplitude: 1).map { abs($0) }
        let makers: [(Int, @Sendable (FrameAlignment) -> Tempogram)] = [
            (64, { Tempogram(.autocorrelation, window: 64, alignment: $0) }), (65, { Tempogram(.fourier, window: 65, alignment: $0) }),
        ]
        for (window, tempogram) in makers {
            let causal = CollectingSink<TempoSpectrum>(), centred = CollectingSink<TempoSpectrum>()
            try Pipeline { SamplesAsNovelty(); tempogram(.causal); Emit(to: causal) }.run(on: curve, format: SignalFormat(sampleRate: rate), blockSize: 50)
            try Pipeline { SamplesAsNovelty(); tempogram(.centered); Emit(to: centred) }.run(on: curve, format: SignalFormat(sampleRate: rate), blockSize: 50)
            let lead = window / 2, ahead = window - lead - 1
            #expect(causal.frameCount == 400 - window + 1 && centred.frameCount == 400 - (window - lead) + 1)
            // Causal: a column's time is that of the newest value of its window.
            let values = CollectingSink<Novelty>()
            try Pipeline { SamplesAsNovelty(); Emit(to: values) }.run(on: curve, format: SignalFormat(sampleRate: rate), blockSize: 50)
            #expect(causal.times == Array(values.times[(window - 1)...]), "window \(window)")
            // Centred: the time of the value the window is centred on, known `ahead` values later.
            #expect(centred.times == Array(values.times[..<centred.frameCount]), "window \(window): content times, to the bit")
            #expect(centred.environment?.latency == Double(ahead) / rate && causal.environment?.latency == 0, "the look-ahead is latency, declared (REAL-5)")
            // Past the lead-in the centred windows are the causal ones.
            #expect(Array(centred.reals[lead...]) == causal.reals, "window \(window)")
            #expect(centred.reals[0] != causal.reals[0], "the first centred columns hold the ramp that leads the curve in")
            let node = try TempogramNode(window: window, taper: try Window.hann.samples(count: window), alignment: .centered,
                                         transform: try AutocorrelationTempogram().makeTransform(window: window, featureRate: rate, range: 30 ... 300))
            #expect(node.latencyFrames == ahead && node.settlingFrames == window - ahead)
            let live = try TempogramNode(window: window, taper: try Window.hann.samples(count: window), alignment: .causal,
                                         transform: try FourierTempogram().makeTransform(window: window, featureRate: rate, range: 30 ... 300))
            #expect(live.latencyFrames == 0 && live.settlingFrames == window)
        }
        #expect(Tempogram.lookAhead(window: 384, alignment: .centered) == 191 && Tempogram.lookAhead(window: 384, alignment: .causal) == 0)
    }

    // MARK: Downstream (ENV-1), order (O-9), spellings, activation

    @Test func downstreamTheRowsAreTempi() throws {
        let noise = TestSignal.whiteNoise(count: 48_000, seed: 527, amplitude: 0.5)
        let novelty = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40); Decibels(); OnsetStrength() }
        let sink = CollectingSink<TempoSpectrum>()
        try novelty.appending(Tempogram(.autocorrelation, window: 96, range: 60 ... 240)).emit(to: sink).run(on: noise, format: mono48, blockSize: 441)
        let rate = 187.5
        let expected = (47 ... 96 - 1).filter { 60 * rate / Double($0) >= 60 && 60 * rate / Double($0) <= 240 }.reversed().map { 60 * rate / Double($0) }
        #expect(sink.axis == .tempo(beatsPerMinute: expected) && sink.axis?.unit == .beatsPerMinute && sink.axis?.rowCount == expected.count)
        #expect(sink.environment?.frameSize == 96 && sink.environment?.hopSize == 1 && sink.environment?.featureRate == rate && sink.environment?.sampleRate == rate)
        #expect(sink.frameCount == 184 - 96 + 1 && sink.reals.allSatisfy { $0.count == expected.count })
        // A feed labels its rows from the axis, without knowing how they were produced.
        let feed = HeatmapFeed(history: 16)
        try Pipeline { novelty; Tempogram(.fourier, window: 96); Emit(to: feed) }.run(on: noise, format: mono48)
        guard case .tempo(let tempi)? = feed.axis else { Issue.record("the feed's axis is \(String(describing: feed.axis))"); return }
        #expect(feed.rowCount == tempi.count && feed.columnCount == 16 && tempi.first.map { $0 >= 30 } == true && tempi.last.map { $0 <= 300 } == true)
        expectClose(tempi[1] - tempi[0], 60 * rate / 384, .relative(1e-12))
    }

    @Test func theOrderRuleInBothTiers() throws {
        let rule = try #require(Tempogram().stageDescriptions.first?.rule)
        #expect(rule == .fixed(.novelty, .tempoSpectrum) && rule(.novelty) == .tempoSpectrum)
        for tag in [DomainTag.samples, .scalar, .lags, .tempoSpectrum, .spectrum(axis: .mel, values: .decibel), .quefrency] { #expect(rule(tag) == nil, "\(tag) (O-9)") }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(Tempogram()) }
        let decibels = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256)).appending(Power().stageDescription).appending(Decibels().stageDescription)
        #expect(throws: DSPError.self) { _ = try decibels.appending(Tempogram()) }
        #expect(try decibels.appending(OnsetStrength().stageDescription).appending(Tempogram()).outputTag == .tempoSpectrum)
        #expect(throws: DSPError.self) { _ = try decibels.appending(OnsetStrength().stageDescription).appending(Tempogram()).appending(Tempogram()) }
    }

    @Test func descriptionsSpellingsAndActivation() throws {
        let novelty = Pipeline { STFT(frame: 1_024, hop: 256); Power(); Decibels(); OnsetStrength() }
        #expect(novelty.tempogram() == Pipeline { novelty; Tempogram() } && novelty.tempogram() == novelty.tempogram(.autocorrelation, window: 384, taper: .hann, range: 30 ... 300, alignment: .causal))
        #expect(novelty.tempogram(.fourier, window: 128, taper: .hamming, range: 60 ... 200, alignment: .centered, isActive: false)
            == Pipeline { novelty; Tempogram(.fourier, window: 128, taper: .hamming, range: 60 ... 200, alignment: .centered, isActive: false) })
        #expect(novelty.tempogram() != novelty.tempogram(.fourier) && novelty.tempogram(.fourier) != novelty.tempogram(.fourier(resolution: 8)))
        #expect(novelty.tempogram() != novelty.tempogram(window: 200) && novelty.tempogram() != novelty.tempogram(taper: .hamming) && novelty.tempogram() != novelty.tempogram(range: 30 ... 200))
        #expect(novelty.tempogram() != novelty.tempogram(alignment: .centered) && novelty.tempogram() != novelty.tempogram(AutocorrelationTempogram(floor: 1e-3)))
        #expect(Tempogram().method is AutocorrelationTempogram && Tempogram(.fourier).method is FourierTempogram && Tempogram.stageName == "Tempogram")
        #expect(FourierTempogram().resolution == 4 && FourierTempogram.fourier(resolution: 8).resolution == 8 && AutocorrelationTempogram().floor == 1e-10)
        // Sequence stages may stand between the curve and the tempogram (O-1).
        let smoothed: [[Float]] = try novelty.lowPass(.butterworth, cutoff: .hertz(20), order: 2).tempogram(window: 64)
            .process(TestSignal.whiteNoise(count: 24_000, seed: 3), format: mono48)
        #expect(smoothed.count == 90 - 64 + 1)

        let dark = CollectingSink<TempoSpectrum>()
        try novelty.tempogram(window: 64, isActive: false).emit(to: dark).run(on: TestSignal.whiteNoise(count: 24_000, seed: 3), format: mono48)
        #expect(dark.frameCount == 0, "switched off, it suspends its branch (ACT-3)")
        // A stage that is switched off is still checked (§5.5.3): its values have to make sense.
        #expect(throws: DSPError.self) {
            try novelty.tempogram(window: 16, isActive: false).emit(to: CollectingSink<TempoSpectrum>()).run(on: TestSignal.silence(count: 4_096), format: mono48)
        }
    }

    @Test func aMethodWrittenOutsideIsPassedTheSameWay() throws {
        let curve: [Float] = (0 ..< 40).map { Float($0 % 4) }
        let energy = try columns(of: curve, rate: 50, Tempogram(EnergyTempogram(), window: 8, taper: .rectangular, range: 100 ... 200))
        // Every window holds 0, 1, 2, 3 twice: mean 1.5, energy 8·1.25.
        #expect(energy.count == 33 && energy.allSatisfy { $0 == [10] })
        #expect(try environmentAtTheEnd(of: Pipeline { SamplesAsNovelty(); Tempogram(EnergyTempogram(), window: 8) }, sampleRate: 50).frequencyAxis == .tempo(beatsPerMinute: [165]))
        #expect(Tempogram(EnergyTempogram()) != Tempogram() && Tempogram(EnergyTempogram()) == Tempogram(EnergyTempogram()))
        #expect(errorMessage { _ = try columns(of: curve, rate: 50, Tempogram(EmptyTempogram(), window: 8)) }?.contains("gives no row between") == true)
    }

    // MARK: Attach-time checks

    @Test func nonsenseIsRefusedWhenThePipelineIsAttached() {
        let curve = [Float](repeating: 1, count: 600)
        func refusal(_ step: Tempogram, rate: Double = 93.75) -> String? { errorMessage { _ = try columns(of: curve, rate: rate, step) } }
        #expect(refusal(Tempogram(window: 1))?.contains("Invalid parameter window") == true && refusal(Tempogram(window: 1 << 17))?.contains("Invalid parameter window") == true)
        #expect(refusal(Tempogram(range: 0 ... 100))?.contains("Invalid parameter range") == true && refusal(Tempogram(range: 120 ... 120))?.contains("Invalid parameter range") == true)
        #expect(refusal(Tempogram(range: 30 ... .infinity))?.contains("Invalid parameter range") == true)
        #expect(refusal(Tempogram(taper: .hann.half))?.contains("Invalid parameter window") == true, "a half window does not taper a whole one")
        // No row inside the range: the lags of 16 values at 93.75 per second start at 375 BPM.
        #expect(refusal(Tempogram(window: 16))?.contains("no lag of a window of 16 values lies between 30.0 and 300.0 beats per minute") == true)
        #expect(refusal(Tempogram(.fourier(resolution: 1), window: 16, range: 30 ... 40))?.contains("no bin of a transform of 16 points") == true)
        #expect(refusal(Tempogram(.fourier(resolution: 0)))?.contains("Invalid parameter resolution") == true && refusal(Tempogram(.fourier(resolution: 65)))?.contains("resolution") == true)
        #expect(refusal(Tempogram(AutocorrelationTempogram(floor: -1)))?.contains("Invalid parameter floor") == true)
        #expect(refusal(Tempogram(window: 2, range: 1_000 ... 6_000)) == nil && refusal(Tempogram(.fourier(resolution: 64), window: 2)) == nil)
        // The transforms make the same checks for whoever calls them directly.
        #expect(throws: DSPError.self) { _ = try AutocorrelationTempogram().makeTransform(window: 1, featureRate: 100, range: 30 ... 300) }
        #expect(throws: DSPError.self) { _ = try FourierTempogram().makeTransform(window: 64, featureRate: 0, range: 30 ... 300) }
        #expect(throws: DSPError.self) { _ = try FourierTempogram().makeTransform(window: 64, featureRate: 100, range: 300 ... 30.5 + 269.5) }
    }

    // MARK: Cold start (ACT-10)

    @Test func aColdStartRefillsTheWindow() throws {
        let curve = TestSignal.whiteNoise(count: 300, seed: 9, amplitude: 1).map { abs($0) }
        let format = SignalFormat(sampleRate: 100)
        for alignment in [FrameAlignment.causal, .centered] {
            try expectAFreshStreamAfterAColdStart(of: Pipeline { SamplesAsNovelty(); Tempogram(.autocorrelation, window: 64, alignment: alignment) }, on: curve,
                                                  "an autocorrelation tempogram, \(alignment)", format: format, blockSize: 50)
            try expectAFreshStreamAfterAColdStart(of: Pipeline { SamplesAsNovelty(); Tempogram(.fourier, window: 64, alignment: alignment) }, on: curve,
                                                  "a Fourier tempogram, \(alignment)", format: format, blockSize: 50)
        }
        // No stale column: after a cold start nothing is emitted until a window is held again.
        let cold = try twoPasses(of: Pipeline { SamplesAsNovelty(); Tempogram(.autocorrelation, window: 64) }, on: curve, coldStart: true, format: format, blockSize: 50)
        #expect(cold.frameCount == 2 * (300 - 64 + 1))
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodesRunWithoutAllocating() throws {
        let lags = CountingSink<TempoSpectrum>(), bins = CountingSink<TempoSpectrum>(), centred = CountingSink<TempoSpectrum>(), fine = CountingSink<TempoSpectrum>()
        try expectNoAllocationsRunning(
            Pipeline().stft(frame: 2_048, hop: 512).power().melScale(bands: 128).decibels().onsetStrength()
                .tap { $0.tempogram(.autocorrelation).emit(to: lags) }
                .tap { $0.tempogram(.fourier).emit(to: bins) }
                .tap { $0.tempogram(.autocorrelation, window: 128, alignment: .centered).emit(to: centred) }
                .tap { $0.tempogram(.fourier(resolution: 8), window: 100, taper: .hamming, alignment: .centered).emit(to: fine) })
        #expect(lags.frames > 600 && bins.frames > 600 && centred.frames > 900 && fine.frames > 900, "\(lags.frames), \(bins.frames), \(centred.frames), \(fine.frames) columns")
    }
}
