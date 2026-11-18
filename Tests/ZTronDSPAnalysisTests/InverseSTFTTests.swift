import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `InverseSTFT` step (WP-505): overlap-add with window-sum-of-squares normalisation, its
/// overlap-add check, its delay.
@Suite("InverseSTFT")
struct InverseSTFTTests {
    private let signal = TestSignal.sum(
        TestSignal.whiteNoise(count: 30_000, seed: 505, amplitude: 0.4),
        TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 30_000, amplitude: 0.5))

    /// The round trip, and the part of it that is defined: the output from its delay on, as
    /// long as the input is.
    private func roundTrip(_ stft: STFT, blockSize: Int = 512) throws -> (output: [Float], delay: Int) {
        let output = try Pipeline { stft; stft.inverse }.process(signal, format: mono48, blockSize: blockSize)
        return (output, InverseSTFT.delay(frame: stft.frame, hop: stft.hop, alignment: stft.alignment).total)
    }

    // MARK: Reconstruction (§6.4.1)

    @Test(arguments: [
        STFT(frame: 2_048, hop: 512), STFT(frame: 2_048, hop: 1_024), STFT(frame: 1_024, hop: 256, window: .hamming),
        STFT(frame: 240, hop: 80, window: .blackman), STFT(frame: 1_024, hop: 1_024, window: .rectangular),
        STFT(frame: 1_024, hop: 256, paddedTo: 2_048), STFT(frame: 1_024, hop: 256, normalization: .amplitude),
        STFT(frame: 1_024, hop: 128, window: .kaiser(beta: 6), normalization: .power),
        STFT(frame: 2_048, hop: 512, alignment: .centered), STFT(frame: 960, hop: 240, window: .hamming, paddedTo: 1_024, alignment: .centered),
        STFT(frame: 1_024, hop: 512, window: .hann.symmetric, normalization: .amplitude, alignment: .centered),
    ])
    func theRoundTripReconstructsTheSignal(stft: STFT) throws {
        let (output, delay) = try roundTrip(stft)
        #expect(output.count > 20_000 && output.count <= signal.count, "never more samples out than in: \(output.count)")
        #expect(output[..<delay].allSatisfy { $0 == 0 }, "the output begins with its delay, as zeros")
        // Causal framing cannot recover the samples the first window barely weighs; from one
        // frame in, every sample is covered by all the frames that reach it.
        let first = stft.alignment == .centered ? 0 : stft.frame
        let reconstructed = Array(output[(delay + first)...])
        let reference = Array(signal[first ..< first + reconstructed.count])
        let ratio = signalToNoise(reconstructed, reference)
        #expect(ratio >= 100, "SNR \(ratio) dB for \(stft.window), frame \(stft.frame), hop \(stft.hop), \(stft.alignment)")
    }

    @Test func centredFramingReconstructsFromTheFirstSample() throws {
        let (output, delay) = try roundTrip(STFT(frame: 1_024, hop: 256, alignment: .centered))
        #expect(delay == 768)
        expectClose(Array(output[delay ..< delay + 2_000]), Array(signal[..<2_000]), .deviationBelow(decibels: -110))
    }

    @Test(arguments: [1, 7, 100, 4_096])
    func theOutputDoesNotDependOnTheBlockSize(blockSize: Int) throws {
        for stft in [STFT(frame: 1_024, hop: 256), STFT(frame: 480, hop: 120, alignment: .centered)] {
            #expect(try roundTrip(stft, blockSize: blockSize).output == roundTrip(stft, blockSize: 512).output)
        }
    }

    // MARK: Delay and times (REAL-5)

    @Test func theReportedLatencyIsTheMeasuredDelayOfAnImpulse() throws {
        let impulse = TestSignal.impulse(count: 8_000, at: 3_000)
        for (stft, expected) in [(STFT(frame: 1_024, hop: 256), 768), (STFT(frame: 1_024, hop: 512, alignment: .centered), 512),
                                 (STFT(frame: 512, hop: 512, window: .rectangular), 0), (STFT(frame: 512, hop: 384, window: .rectangular, alignment: .centered), 256)] {
            let sink = CollectingSink<Samples>()
            let output = try Pipeline { stft; stft.inverse; Emit(to: sink) }.process(impulse, format: mono48)
            let position = try #require(output.firstIndex { abs($0) > 0.5 })
            #expect(position == 3_000 + expected, "\(stft.alignment), hop \(stft.hop)")
            let latency = try #require(sink.environment?.latency)
            #expect(latency == Double(expected) / 48_000, "the environment reports the delay: \(latency)")
            #expect(sink.environment?.isInSpectralScope == false && sink.environment?.sampleRate == 48_000 && sink.environment?.channelCount == 1)
            // A block's time is the time of the signal its first sample holds.
            #expect(sink.blockLengths.allSatisfy { $0 <= stft.hop })
            var position0 = 0
            for (index, length) in sink.blockLengths.enumerated() {
                expectClose(sink.times[index], Double(position0 - expected) / 48_000, .absolute(1e-9))
                position0 += length
            }
            #expect(sink.indices.first == 0 && sink.indices.last == output.count - (sink.blockLengths.last ?? 0))
        }
    }

    @Test func theDelayIsWhatASampleWaitsForTheLastFrameThatCoversIt() {
        #expect(InverseSTFT.delay(frame: 1_024, hop: 256, alignment: .causal) == (768, 768))
        #expect(InverseSTFT.delay(frame: 1_024, hop: 256, alignment: .centered) == (768, 256), "half a frame of it is the analysis's own")
        #expect(InverseSTFT.delay(frame: 1_024, hop: 1_024, alignment: .causal) == (0, 0))
        #expect(InverseSTFT.delay(frame: 1_024, hop: 768, alignment: .centered) == (512, 0), "never less than the analysis declared")
    }

    // MARK: The overlap-add check (O-17, WIN-3)

    @Test func aWindowAndHopThatLeaveSamplesUncoveredAreRefusedAtAttachTime() throws {
        func failure(_ stft: STFT) -> DSPError? {
            do {
                _ = try Pipeline { stft; stft.inverse }.process(signal, format: mono48)
                return nil
            } catch {
                return error
            }
        }
        let hann = try #require(failure(STFT(frame: 1_024, hop: 1_024)), "a Hann window is zero where frames that do not overlap meet")
        #expect("\(hann)".contains("non-zero overlap-add") && "\(hann)".contains("A hop of 512 passes"), "\(hann)")
        #expect(hann.stage?.stageName == "InverseSTFT")
        #expect(failure(STFT(frame: 1_024, hop: 512, window: .custom { $0 < 0.25 ? 1 : 0 })) != nil, "a quarter of every hop is weighed by no frame")
        #expect(failure(STFT(frame: 1_024, hop: 512, window: .custom { $0 < 0.5 ? 1 : 0 })) == nil, "every sample is reached by a frame that weighs it")
        #expect(failure(STFT(frame: 1_024, hop: 768)) == nil && failure(STFT(frame: 1_024, hop: 1)) == nil)
    }

    @Test func itNeedsTheScopeOfAnSTFT() throws {
        // A complex spectrum from elsewhere has no frame and hop to synthesise with.
        struct Bare: PipelineStage {
            typealias Input = Samples
            typealias Output = Spectrum<LinearFrequency, ComplexValues>
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                context.emit(.analysis(AnalysisStep(name: "Bare", key: 0, output: .complex(count: 9)) { () throws(DSPError) -> any AnalysisNode in
                    SpectralValueNode(.magnitude, bins: 9)
                }))
            }
        }
        #expect(throws: DSPError.self) { _ = try Pipeline { Bare(); InverseSTFT() }.process(signal, format: mono48) }
    }

    // MARK: Description, order, activation (STG-1)

    @Test func theInverseOfAnAnalysisCarriesItsWindowNormalisationAndAlignment() {
        let stft = STFT(frame: 512, hop: 128, window: .kaiser(beta: 5), normalization: .power, alignment: .centered)
        #expect(stft.inverse == InverseSTFT(window: .kaiser(beta: 5), normalization: .power, alignment: .centered))
        #expect(STFT(frame: 512, hop: 128).inverse == InverseSTFT(), "the defaults are those of STFT")
        #expect(Pipeline { stft; stft.inverse } == Pipeline().stft(frame: 512, hop: 128, window: .kaiser(beta: 5), normalization: .power, alignment: .centered)
            .inverseSTFT(window: .kaiser(beta: 5), normalization: .power, alignment: .centered))
        #expect(InverseSTFT() != InverseSTFT(window: .hamming) && InverseSTFT(isActive: false).activation == .constant(false))
        #expect(InverseSTFT.stageName == "InverseSTFT" && InverseSTFT().backend is VDSPFFTBackend)
    }

    @Test func theRuleOfTheDescriptionAcceptsTheComplexLinearSpectrumOnly() throws {
        let description = try #require(InverseSTFT().stageDescriptions.first)
        #expect(description.rule(.spectrum(axis: .linear, values: .complex)) == .samples)
        for tag in [DomainTag.samples, .spectrum(axis: .linear, values: .magnitude), .spectrum(axis: .linear, values: .power),
                    .spectrum(axis: .mel, values: .complex), .spectrum(axis: .constantQ, values: .complex), .quefrency, .scalar] {
            #expect(description.rule(tag) == nil, "\(tag) (O-6)")
        }
    }

    @Test func sequenceStagesRunOnTheSamplesItReturns() throws {
        let plain = try roundTrip(STFT(frame: 512, hop: 128)).output
        let scaled = try Pipeline { STFT(frame: 512, hop: 128); InverseSTFT(); TestGain(0.5) }.process(signal, format: mono48)
        #expect(scaled == plain.map { $0 * 0.5 })
    }

    @Test func switchedOffItSuspendsWhatFollows() throws {
        let after = CollectingSink<Samples>(), before = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>()
        let output = try Pipeline { STFT(frame: 512, hop: 128); Emit(to: before); InverseSTFT(isActive: false); Emit(to: after) }
            .process(signal, format: mono48)
        #expect(output.isEmpty && after.frameCount == 0 && before.frameCount > 100)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let samples = CountingSink<Samples>(), centered = CountingSink<Samples>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 1_024, hop: 256, alignment: .centered); InverseSTFT(alignment: .centered); Emit(to: centered) }
            STFT(frame: 2_048, hop: 512, paddedTo: 4_096, normalization: .amplitude)
            InverseSTFT(normalization: .amplitude)
            Emit(to: samples)
        })
        #expect(samples.frames > 990 && centered.frames > 1_990)
    }
}
