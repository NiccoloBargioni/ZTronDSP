import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// EXT-4, the third of the three: `ExternalMelScale`, a step family with a node of its own,
/// against the stock `MelScale`.
///
/// Both nodes apply the weights of the public `MelFilterBank` with the dot products of the
/// toolkit, band by band, each bound to the implementation its length calls for, or with one
/// dense product: the kernel is the same, so the comparison is bit for bit.
@Suite("Mel parity")
struct MelParityTests {
    let noise = TestSignal.whiteNoise(count: 30_000, seed: 535, amplitude: 0.8)
    let tone = TestSignal.sum(TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 30_000, amplitude: 0.5),
                              TestSignal.chirp(from: 100, to: 12_000, sampleRate: 48_000, count: 30_000, amplitude: 0.4))

    typealias LinearPower = Spectrum<LinearFrequency, PowerValues>
    typealias MelPower = Spectrum<MelFrequency, PowerValues>

    /// The frames of both steps behind `STFT → Power`.
    private func frames(
        frame: Int, hop: Int, _ stock: MelScale, _ external: ExternalMelScale, on signal: [Float], format: SignalFormat = mono48, blockSize: Int = 512,
        crossovers: CrossoverTable = .shipped
    ) throws -> (stock: [[Float]], external: [[Float]]) {
        let a: [[Float]] = try Pipeline { STFT(frame: frame, hop: hop); Power(); stock }.process(signal, format: format, blockSize: blockSize, crossovers: crossovers)
        let b: [[Float]] = try Pipeline { STFT(frame: frame, hop: hop); Power(); external }.process(signal, format: format, blockSize: blockSize, crossovers: crossovers)
        return (a, b)
    }

    @Test func outputEqualsTheStockStepBitForBit() throws {
        // Frames from 480 to 4 096 points and from 12 to 128 bands: bands of two bins and bands
        // of more than sixty-four, so every one of the three dot products is bound somewhere.
        let shapes: [(frame: Int, hop: Int, bands: Int)] = [(1_024, 256, 40), (2_048, 512, 128), (4_096, 1_024, 64), (480, 160, 12), (256, 64, 20), (4_096, 512, 20)]
        for shape in shapes {
            for signal in [noise, tone] {
                let result = try frames(frame: shape.frame, hop: shape.hop, MelScale(bands: shape.bands), ExternalMelScale(bands: shape.bands), on: signal)
                #expect(result.external == result.stock, "frame \(shape.frame), \(shape.bands) bands")
                #expect(result.stock.count == (signal.count - shape.frame) / shape.hop + 1 && result.stock[0].count == shape.bands)
            }
        }
    }

    @Test func everyStrategyGivesTheSameFloats() throws {
        let range = FrequencyRange.hertz(300 ... 8_000)
        let cases: [(String, MelScale, ExternalMelScale)] = [
            ("HTK formula", MelScale(bands: 40, formula: .htk), ExternalMelScale(bands: 40, formula: .htk)),
            ("unit peaks", MelScale(bands: 40, normalization: .none), ExternalMelScale(bands: 40, normalization: .none)),
            ("a range", MelScale(bands: 24, range: range), ExternalMelScale(bands: 24, range: range)),
            ("HTK, unit peaks, a range", MelScale(bands: 24, range: range, formula: .htk, normalization: .none),
             ExternalMelScale(bands: 24, range: range, formula: .htk, normalization: .none)),
            ("a range in mels", MelScale(bands: 16, range: FrequencyRange(from: .mel(5), to: .mel(40))),
             ExternalMelScale(bands: 16, range: FrequencyRange(from: .mel(5), to: .mel(40)))),
        ]
        for (name, stock, external) in cases {
            let result = try frames(frame: 2_048, hop: 512, stock, external, on: noise)
            #expect(result.external == result.stock, "\(name)")
        }
    }

    @Test func magnitudesAreProjectedLikePowers() throws {
        let stock: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256, window: .hamming); Magnitude(); MelScale(bands: 40) }.process(tone, format: mono48)
        let external: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256, window: .hamming); Magnitude(); ExternalMelScale(bands: 40) }.process(tone, format: mono48)
        #expect(external == stock && !stock.isEmpty)
        // A padded transform has more bins than the frame alone: the bank follows the bins.
        let padded: [[Float]] = try Pipeline { STFT(frame: 1_000, hop: 250, paddedTo: 4_096); Power(); MelScale(bands: 64) }.process(tone, format: mono48)
        let paddedExternal: [[Float]] = try Pipeline { STFT(frame: 1_000, hop: 250, paddedTo: 4_096); Power(); ExternalMelScale(bands: 64) }.process(tone, format: mono48)
        #expect(paddedExternal == padded && !padded.isEmpty)
    }

    @Test func everyImplementationGivesTheFloatsOfItsTwin() throws {
        // SEL-3: the node binds its dot products when the plan is compiled, as the stock node does.
        for implementation in [Implementation.native, .accelerate, .automatic] {
            let stock: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 1_024); Power(); MelScale(bands: 64) }
                .environment(\.implementation, implementation).process(noise, format: mono48)
            let external: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 1_024); Power(); ExternalMelScale(bands: 64) }
                .environment(\.implementation, implementation).process(noise, format: mono48)
            #expect(external == stock, "\(implementation)")
        }
        // Other crossovers: the 8-lane loop from 4 bins, vDSP from 8; then no vDSP at all; then the dense product.
        let tables = [
            CrossoverTable(reductionSIMD: 4, reductionAccelerate: 8),
            CrossoverTable(reductionSIMD: 8, reductionAccelerate: 1 << 20),
            CrossoverTable(reductionSIMD: 1 << 20, reductionAccelerate: 1 << 20),
            CrossoverTable(reductionSIMD: 32, reductionAccelerate: 16),
            CrossoverTable(melDense: 1),
        ]
        for table in tables {
            let result = try frames(frame: 2_048, hop: 512, MelScale(bands: 128), ExternalMelScale(bands: 128), on: noise, crossovers: table)
            #expect(result.external == result.stock, "\(table)")
        }
        // The dense product by its size alone: 128 bands of 8 193 bins are more than 2²⁰ weights.
        let dense = try frames(frame: 16_384, hop: 4_096, MelScale(bands: 128), ExternalMelScale(bands: 128), on: noise)
        #expect(dense.external == dense.stock && !dense.stock.isEmpty)
    }

    @Test func theFramesAreTheFilterBankAppliedToTheSpectrum() throws {
        // An oracle that is neither node: the bank's own one-shot projection, in double precision.
        let sink = CollectingSink<LinearPower>()
        let frames: [[Float]] = try Pipeline { STFT(frame: 2_048, hop: 512); Power(); Emit(to: sink); ExternalMelScale(bands: 128) }.process(tone, format: mono48)
        let bank = try MelFilterBank(bands: 128, binCount: 1_025, nyquist: 24_000)
        #expect(sink.frames.count == frames.count && !frames.isEmpty)
        for (spectrum, bands) in zip(sink.frames, frames) {
            expectClose(bands, bank.applied(to: spectrum), .relativeToMaximum(1e-6))
        }
        #expect(try ExternalMelScale(bands: 128).bank(binCount: 1_025, nyquist: 24_000, sampleRate: 48_000) == bank)
    }

    @Test func blockSizesAndSourcesChangeNothing() async throws {
        let pipeline: Pipeline<Samples, MelPower> = Pipeline { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40) }
        let stockPipeline: Pipeline<Samples, MelPower> = Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 40) }
        let reference: [[Float]] = try pipeline.process(noise, format: mono48)
        #expect(reference == (try stockPipeline.process(noise, format: mono48)))
        for blockSize in [64, 500, 4_096] {
            let frames: [[Float]] = try pipeline.process(noise, format: mono48, blockSize: blockSize)
            #expect(frames == reference, "blocks of \(blockSize)")
        }
        // Offline ≡ engine, whatever the source's batches are.
        let buffered = try await framesThroughEngine(pipeline, on: BufferSource(noise, sampleRate: 48_000))
        let scripted = try await framesThroughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [1, 7, 300, 513, 64, 2, 4_000]))
        let small = try await framesThroughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [129]), blockSize: 100)
        let stock = try await framesThroughEngine(stockPipeline, on: BufferSource(noise, sampleRate: 48_000))
        let stockSmall = try await framesThroughEngine(stockPipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [129]), blockSize: 100)
        #expect(buffered.frames == reference && scripted.frames == reference && small.frames == reference)
        #expect(stock.frames == reference && stockSmall.frames == reference)
        // The frames carry the times and the indices the stock step gives them.
        #expect(buffered.times == stock.times && buffered.indices == stock.indices)
        #expect(small.times == stockSmall.times && small.indices == stockSmall.indices)
        #expect(buffered.indices == Array(0 ..< reference.count))
        // A causal frame is stamped with the time of the sample it ends at, one hop after the frame before it,
        // whatever the blocks are; the step passes the time on.
        let first = try #require(buffered.times.first)
        print("PARITY the first mel frame of a 1 024-point causal STFT is stamped \(first * 48_000) samples after the start")
        #expect(first * 48_000 >= 1_022.5 && first * 48_000 <= 1_024.5)
        expectClose(buffered.times, (0 ..< reference.count).map { first + Double(256 * $0) / 48_000 }, .absolute(1.0e-9))
        expectClose(small.times, buffered.times, .absolute(1.0e-9))
    }

    @Test func downstreamTheAxisIsMel() async throws {
        // §6.11: the environment and the sinks describe a mel axis by the band centres in hertz.
        let source = { BufferSource(TestSignal.whiteNoise(count: 8_192, seed: 9), sampleRate: 44_100) }
        let external = try await framesThroughEngine(Pipeline { STFT(frame: 2_048, hop: 512); Power(); ExternalMelScale(bands: 64) }, on: source())
        let stock = try await framesThroughEngine(Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 64) }, on: source())
        let axis = try #require(external.axis)
        #expect(axis == stock.axis)
        guard case .mel(let centers) = axis else {
            Issue.record("the axis after the step is \(axis)")
            return
        }
        #expect(centers.count == 64 && centers == centers.sorted() && centers[63] < 22_050)
        #expect(external.environment == stock.environment)
        let environment = try #require(external.environment)
        #expect(environment.frequencyAxis == axis && environment.frameSize == 2_048 && environment.hopSize == 512 && environment.latency == 0)
        // What follows a mel axis follows this step: the decibel conversion, the cepstral coefficients, a feed.
        let feed = HeatmapFeed(history: 64)
        try Pipeline { STFT(frame: 2_048, hop: 512); Power(); ExternalMelScale(bands: 64); Decibels(); Emit(to: feed); CepstralCoefficients(count: 13) }
            .run(on: TestSignal.whiteNoise(count: 8_192, seed: 9), format: SignalFormat(sampleRate: 44_100))
        #expect(feed.axis == axis && feed.rowCount == 64 && feed.columnCount > 0)
    }

    @Test func bothSpellingsGiveOneDescription() throws {
        let built = Pipeline { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40) }
        let fluent = Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 40)
        #expect(built == fluent)
        #expect(built != Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 41))
        #expect(built != Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 40, formula: .htk))
        #expect(built != Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 40, normalization: .none))
        #expect(built == Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 40, isActive: true))
        #expect(built != Pipeline().stft(frame: 1_024, hop: 256).power().externalMelScale(bands: 40, isActive: false))
        // The step is not the stock one: two descriptions, though they do the same work.
        #expect(built.stages != Pipeline().stft(frame: 1_024, hop: 256).power().melScale(bands: 40).stages)
        // A branch that begins with the step is written fluently (ORD-3).
        let branched = Pipeline().stft(frame: 1_024, hop: 256).power().tap { $0.externalMelScale(bands: 40).decibels() }
        #expect(branched.outputTag == .spectrum(axis: .linear, values: .power))
        // Two branches that differ in an argument of the step are one step with a conditional argument (E-19).
        for wide in [true, false] {
            let pipeline = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); ExternalMelScale(bands: wide ? 64 : 40) }
            #expect(pipeline.outputTag == .spectrum(axis: .mel, values: .magnitude))
        }
    }

    @Test func theRuleOfTheFamilyIsTheStockRule() throws {
        // §5.8.2, tier 2: the description carries the family's rule; ORD-2 asks that it agree with the types.
        let axes: [DomainTag.Axis] = [.linear, .mel, .constantQ]
        let values: [DomainTag.Values] = [.complex, .magnitude, .power, .decibel]
        var tags: [DomainTag] = [.samples, .quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum, .envelope, .novelty, .scalar]
        for axis in axes {
            for value in values { tags.append(.spectrum(axis: axis, values: value)) }
        }
        for tag in tags {
            #expect(ExternalMelScale.rule(tag) == MelScale.rule(tag), "\(tag)")
        }
        #expect(ExternalMelScale.rule(.spectrum(axis: .linear, values: .power)) == .spectrum(axis: .mel, values: .power))
        #expect(ExternalMelScale.rule != MelScale.rule, "a rule of one's own has a name of its own")

        let step = ExternalMelScale(bands: 40).stageDescription
        #expect(step.name == "ExternalMelScale" && step.rule == ExternalMelScale.rule)
        var dynamic = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        var error = #expect(throws: DSPError.self) { try dynamic.append(step) }
        guard case .invalidStageOrder(let stage, let found)? = error else {
            Issue.record("the step after a complex spectrum: \(String(describing: error))")
            return
        }
        #expect(stage.stageName == "ExternalMelScale" && found == .spectrum(axis: .linear, values: .complex))
        try dynamic.append(Power().stageDescription)
        try dynamic.append(step)
        #expect(dynamic.outputTag == .spectrum(axis: .mel, values: .power))
        error = #expect(throws: DSPError.self) { try dynamic.append(step) }
        guard case .invalidStageOrder(_, let again)? = error else {
            Issue.record("the step twice: \(String(describing: error))")
            return
        }
        #expect(again == .spectrum(axis: .mel, values: .power))
        // A typed pipeline that claims an order the rule refuses is refused when it is attached (ORD-6).
        let forged = Pipeline<Samples, MelPower>(unchecked: [step])
        #expect(throws: DSPError.self) { let _: [[Float]] = try forged.process(noise, format: mono48) }
    }

    @Test func aBandThatCoversNoBinIsRejectedAndNamed() throws {
        // O-18: 128 bands on a 256-point frame; the error names the band and the length that would fill it.
        let error = #expect(throws: DSPError.self) {
            let _: [[Float]] = try Pipeline { STFT(frame: 256, hop: 64); Power(); ExternalMelScale(bands: 128) }.process(noise, format: mono48)
        }
        guard case .invalidParameter(let stage, let parameter, let reason)? = error else {
            Issue.record("128 bands on 129 bins: \(String(describing: error))")
            return
        }
        #expect(parameter == "bands" && stage.stageName == "ExternalMelScale")
        let stock = #expect(throws: DSPError.self) {
            let _: [[Float]] = try Pipeline { STFT(frame: 256, hop: 64); Power(); MelScale(bands: 128) }.process(noise, format: mono48)
        }
        guard case .invalidParameter(_, let stockParameter, let stockReason)? = stock else {
            Issue.record("the stock step: \(String(describing: stock))")
            return
        }
        #expect(stockParameter == parameter && stockReason == reason, "the same band, the same advice: \(reason)")
        #expect(reason.contains("band 0 of 128") && reason.contains("a transform of"))

        // A range that ends above the Nyquist frequency, an empty one, and a count that holds nothing.
        for range in [FrequencyRange.hertz(0 ... 30_000), .hertz(2_000 ... 2_000)] {
            let refused = #expect(throws: DSPError.self) {
                let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 20, range: range) }.process(noise, format: mono48)
            }
            let refusedStock = #expect(throws: DSPError.self) {
                let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Power(); MelScale(bands: 20, range: range) }.process(noise, format: mono48)
            }
            guard case .invalidParameter(let stage, let parameter, let reason)? = refused, case .invalidParameter(_, let stockParameter, let stockReason)? = refusedStock else {
                Issue.record("\(range): \(String(describing: refused)) and \(String(describing: refusedStock))")
                continue
            }
            #expect(parameter == "range" && stockParameter == "range" && reason == stockReason && stage.stageName == "ExternalMelScale")
        }
        #expect(throws: DSPError.self) {
            let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 0) }.process(noise, format: mono48)
        }
    }
}
