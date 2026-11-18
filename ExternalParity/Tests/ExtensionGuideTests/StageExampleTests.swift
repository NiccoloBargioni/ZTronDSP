import CExtensionGuide
import ExtensionGuide
import ExternalTestSupport
import Foundation
import SwiftUI
import Testing
import ZTronDSP
import ZTronDSPTesting

// WP-908: every example of the extension guide builds outside the package and runs in a test.
// This file: rows 1 to 4 of §5.11.1, the four kinds of stage.

/// Row 1, a step between domains: `SpectralFlux`, a `PipelineStage` with an `AnalysisNode`.
@Suite("Guide 1: a step between domains")
struct StepBetweenDomainsTests {
    /// Half a second of silence, then half a second of a tone.
    let signal = TestSignal.silence(count: 24_000) + TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 24_000, amplitude: 0.5)

    @Test func theFluxPeaksWhereEnergyArrives() throws {
        let flux: [ScalarFrame] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); SpectralFlux() }.process(signal, format: mono48)
        let frames = (signal.count - 1_024) / 256 + 1
        // The first frame has nothing to be compared with: one value per frame from the second on.
        #expect(flux.count == frames - 1)
        #expect(flux.allSatisfy { $0.value >= 0 && $0.value.isFinite && $0.confidence == 1 })
        let peak = flux.map { $0.value }.max() ?? 0
        let at = flux.firstIndex { $0.value == peak } ?? -1
        // The tone enters the frames that end between samples 24 000 and 25 024: frames 90 to 94, values 89 to 93.
        #expect(peak > 0 && at >= 88 && at <= 94, "the largest flux, \(peak), is value \(at)")
        #expect(flux[..<80].allSatisfy { $0.value == 0 }, "silence does not rise")
        #expect(flux[100...].allSatisfy { $0.value < 0.02 * peak }, "a steady tone hardly rises")
    }

    @Test func whatFollowsIsASampledSequenceAtTheFeatureRate() throws {
        // §5.2: a step that produces a novelty curve starts a new sampled sequence. A sequence
        // stage follows it, and its frequencies are frequencies of that sequence (ENV-1).
        let smoothed: [ScalarFrame] = try Pipeline {
            STFT(frame: 1_024, hop: 256); Magnitude(); SpectralFlux()
            LowPass(.butterworth, cutoff: .hertz(4), order: 2)
        }.process(signal, format: mono48)
        #expect(smoothed.count == (signal.count - 1_024) / 256)
        // 48 000 / 256 = 187.5 values per second: 100 Hz lies beyond the Nyquist frequency of the curve.
        #expect(throws: DSPError.self) {
            let _: [ScalarFrame] = try Pipeline {
                STFT(frame: 1_024, hop: 256); Magnitude(); SpectralFlux()
                LowPass(.butterworth, cutoff: .hertz(100), order: 2)
            }.process(signal, format: mono48)
        }
        #expect(Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); SpectralFlux() } == Pipeline().stft(frame: 1_024, hop: 256).magnitude().spectralFlux())
    }

    @Test func itIsOrderCheckedInBothTiers() throws {
        // Tier 1 is the compiler's (the fixtures); tier 2 is the rule the description carries.
        var dynamic = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        try dynamic.append(Power().stageDescription)
        let error = #expect(throws: DSPError.self) { try dynamic.append(SpectralFlux()) }
        guard case .invalidStageOrder(let stage, let found)? = error else {
            Issue.record("the flux of powers: \(String(describing: error))")
            return
        }
        #expect(stage.stageName == "SpectralFlux" && found == .spectrum(axis: .linear, values: .power))
        let accepted = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256)).appending(Magnitude().stageDescription).appending(SpectralFlux())
        #expect(accepted.outputTag == .novelty)
        // A typed pipeline that claims an order the rule refuses is refused when it is run (ORD-6).
        let forged = Pipeline<Samples, Novelty>(unchecked: SpectralFlux().stageDescriptions)
        #expect(throws: DSPError.self) { let _: [ScalarFrame] = try forged.process(signal, format: mono48) }
    }

    @Test func switchedOffItSuspendsItsBranchAndStartsColdWhenItComesBack() async throws {
        // ACT-3, ACT-10: the step changes the domain, so off it suspends the rest of its branch;
        // on again the node starts as at the start of a session, with no frame to compare with.
        let box = StateBox(true)
        let sink = CollectingSink<Novelty>()
        let noise = TestSignal.whiteNoise(count: 60 * 64, seed: 3, amplitude: 0.5)
        let run = try await HandFedRun(Pipeline().tap { $0.stft(frame: 256, hop: 64).magnitude().spectralFlux(isActive: box.binding).emit(to: sink) })
        try #require(await run.feed(Array(noise[..<1_280])))
        let first = sink.frameCount
        await run.set(box, to: false)
        try #require(await run.feed(Array(noise[1_280 ..< 2_560])))
        let off = sink.frameCount
        await run.set(box, to: true)
        try #require(await run.feed(Array(noise[2_560...])))
        try #require(await run.finish())
        // 17 frames in the first 20 blocks: 16 values. Suspended: none. Back: 20 frames, 19 values.
        #expect(first == 16 && off == 16 && sink.frameCount == 16 + 19, "\(first), \(off), \(sink.frameCount)")
        #expect(run.output.samples == noise)
    }
}

/// Row 2, a sample-domain stage in Swift: `Despike`, a `SampleProcessor`.
@Suite("Guide 2: a sample-domain stage in Swift")
struct SampleStageInSwiftTests {
    /// The median of each sample and the two before it, the memory starting with zeros.
    static func reference(_ signal: [Float]) -> [Float] {
        var older: Float = 0, newer: Float = 0
        return signal.map { current in
            defer { older = newer; newer = current }
            return [older, newer, current].sorted()[1]
        }
    }

    @Test func aSpikeOfOneSampleIsRemovedAndTheRestComesOneFrameLate() throws {
        var signal = TestSignal.sine(frequency: 100, sampleRate: 48_000, count: 4_000, amplitude: 0.5)
        for position in [100, 101 + 700, 2_000, 3_999] { signal[position] = position % 2 == 0 ? 1 : -1 }
        let output = try Pipeline { Despike() }.process(signal, format: mono48)
        #expect(output == SampleStageInSwiftTests.reference(signal))
        #expect(abs(output[101]) < 0.6 && abs(output[2_001]) < 0.6, "the spikes are gone")
        // A signal that only rises is its own median, one frame late.
        let ramp = (0 ..< 500).map { Float($0) / 500 }
        #expect(try Pipeline { Despike() }.process(ramp, format: mono48) == [0] + ramp.dropLast())
        // The blocks change nothing, and each channel has a memory of its own.
        for blockSize in [1, 7, 64, 1_000] {
            #expect(try Pipeline().despiked().process(signal, format: mono48, blockSize: blockSize) == output, "blocks of \(blockSize)")
        }
        let stereo = try Pipeline { Despike() }.process(channels: [signal, ramp + [Float](repeating: 1, count: 3_500)], format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        #expect(stereo[0] == output && Array(stereo[1][..<500]) == [0] + ramp.dropLast())
    }

    @Test func itsLatencyIsInTheEnvironmentAndItsBypassKeepsTheSignalInPlace() async throws {
        // REAL-5: the stage states one frame of latency, and the session reports it.
        let engine = DSPEngine(blockSize: 64)
        let session = try await engine.attach(Pipeline { Despike(); Despike() }, to: BufferSource([0, 1, 2, 3], sampleRate: 48_000))
        #expect(session.environment.latency == 2.0 / 48_000)
        session.detach()

        // ACT-8: switched off, the signal passes through a delay line of the stage's latency, so
        // nothing downstream moves in time; ACT-7: off and on are cross-fades of 10 ms.
        let box = StateBox(true)
        let noise = TestSignal.whiteNoise(count: 120 * 64, seed: 21, amplitude: 0.5)
        let run = try await HandFedRun(Pipeline { Despike(isActive: box.binding) })
        try #require(await run.feed(Array(noise[..<1_280])))
        await run.set(box, to: false)
        try #require(await run.feed(Array(noise[1_280 ..< 2_560])))
        await run.set(box, to: true)
        try #require(await run.feed(Array(noise[2_560...])))
        try #require(await run.finish())
        let output = run.output.samples, delayed = [0] + noise.dropLast(), always = SampleStageInSwiftTests.reference(noise)
        try #require(output.count == noise.count)
        #expect(Array(output[..<1_280]) == Array(always[..<1_280]))
        #expect(Array(output[(1_280 + 480) ..< 2_560]) == Array(delayed[(1_280 + 480) ..< 2_560]), "bypassed, the signal is one frame late, like the processed one")
        // Back on: the processor is reset and pre-rolled for its three frames of latency and
        // settling, which is one block, with the delayed signal still passing; then the fade.
        #expect(Array(output[2_560 ..< (2_560 + 64)]) == Array(delayed[2_560 ..< (2_560 + 64)]), "pre-rolled for one block")
        var mixed = 0
        for index in (2_560 + 64) ..< (2_560 + 64 + 480) where output[index] != delayed[index] { mixed += 1 }
        #expect(mixed > 100, "then it is faded in: \(mixed) of 480 frames are no longer the delayed signal")
        #expect(Array(output[(2_560 + 64 + 480)...]) == Array(always[(2_560 + 64 + 480)...]))
        #expect(box.writes == 0)
    }
}

/// Row 3, a sample-domain stage in C: `FeedbackComb`, a `SequenceStage` on a `ztd_kernel_t`.
@Suite("Guide 3: a sample-domain stage in C")
struct SampleStageInCTests {
    @Test func anImpulseComesBackEveryDelayAtHalfTheLevel() throws {
        let impulse = TestSignal.impulse(count: 48 * 100)
        let output = try Pipeline { FeedbackComb(delay: 0.001, feedback: 0.5) }.process(impulse, format: mono48, blockSize: 100)
        for echo in 0 ..< 20 {
            #expect(output[48 * echo] == Float(pow(0.5, Double(echo))), "echo \(echo)")
        }
        #expect(output.enumerated().allSatisfy { $0.offset % 48 == 0 || $0.element == 0 })
        // RT-6: an echo that has decayed below the floor enters the ring as zero; nothing denormal is left.
        #expect(output[48 * 66] > 0 && output[48 * 68] == 0 && output[48 * 99] == 0)
        #expect(Pipeline { FeedbackComb(delay: 0.001, feedback: 0.5) } == Pipeline().feedbackComb(delay: 0.001, feedback: 0.5))
        // Seconds become frames at the sample rate of the stage's position: half the rate, half the frames.
        let slower = try Pipeline { FeedbackComb(delay: 0.001, feedback: 0.5) }.process(impulse, format: SignalFormat(sampleRate: 24_000))
        #expect(slower[24] == 0.5 && slower[48] == 0.25)
    }

    @Test func theKernelSaysWhatItDelaysAndHowLongItSettles() throws {
        var kernel = extg_comb_create(2, 48, 0.5)
        defer { ztd_kernel_destroy(&kernel) }
        try #require(!ztd_kernel_is_null(&kernel))
        // 0.5^17 is the first power below 100 dB down: 17 echoes of 48 frames.
        #expect(kernel.latency_frames == 0 && kernel.settling_frames == 17 * 48)
        var silent = extg_comb_create(1, 48, 0)
        defer { ztd_kernel_destroy(&silent) }
        #expect(silent.settling_frames == 0)
        // A reset is a cold start that keeps the feedback.
        let input = try AudioBuffer(channels: [TestSignal.impulse(count: 64), TestSignal.impulse(count: 64, at: 5)])
        let output = try AudioBuffer(channelCount: 2, capacity: 64)
        #expect(kernel.process?(kernel.state, input.block().constantChannelTable, output.block().channelTable, 2, 64) == 64)
        let first = output.array(ofChannel: 1)
        kernel.reset?(kernel.state)
        _ = kernel.process?(kernel.state, input.block().constantChannelTable, output.block().channelTable, 2, 64)
        #expect(output.array(ofChannel: 1) == first && first[5] == 1 && first[53] == 0.5 && output.array(ofChannel: 0)[48] == 0.5)
    }

    @Test func wrongArgumentsAreErrorsThatNameTheStage() throws {
        let noise = TestSignal.whiteNoise(count: 1_000, seed: 1)
        for (stage, parameter) in [(FeedbackComb(delay: 0.000_001, feedback: 0.5), "delay"), (FeedbackComb(delay: 0.01, feedback: 1), "feedback"),
                                   (FeedbackComb(delay: 0.01, feedback: .nan), "feedback"), (FeedbackComb(delay: -1, feedback: 0.5), "delay")] {
            let error = #expect(throws: DSPError.self) { try Pipeline { stage }.process(noise, format: mono48) }
            guard case .invalidParameter(let path, let named, _)? = error else {
                Issue.record("\(stage): \(String(describing: error))")
                continue
            }
            #expect(named == parameter && path.stageName == "FeedbackComb")
        }
        func isNull(_ kernel: ztd_kernel_t) -> Bool {
            var copy = kernel
            defer { ztd_kernel_destroy(&copy) }
            return ztd_kernel_is_null(&copy)
        }
        #expect(isNull(extg_comb_create(0, 48, 0.5)) && isNull(extg_comb_create(1, 0, 0.5)) && isNull(extg_comb_create(1, 48, 1)))
        #expect(isNull(extg_comb_create(1, 48, .nan)) && isNull(extg_comb_create(1, 48, -1.5)) && !isNull(extg_comb_create(1, 48, -0.5)))
    }

    @Test func restoredItIsPrerolledForTheSettlingTimeItDeclares() async throws {
        // ACT-7: switched on, the kernel is reset and runs with its output discarded for its
        // latency plus its settling time, in whole blocks, and only then is it faded in.
        let box = StateBox(false)
        let noise = TestSignal.whiteNoise(count: 80 * 64, seed: 8, amplitude: 0.5)
        let run = try await HandFedRun(Pipeline { FeedbackComb(delay: 0.001, feedback: 0.5, isActive: box.binding) })
        try #require(await run.feed(Array(noise[..<1_280])))
        await run.set(box, to: true)
        try #require(await run.feed(Array(noise[1_280...])))
        try #require(await run.finish())
        let output = run.output.samples
        let preroll = (17 * 48 + 63) / 64 * 64
        #expect(Array(output[..<(1_280 + preroll)]) == Array(noise[..<(1_280 + preroll)]), "off, and while it is pre-rolled, the unprocessed signal passes")
        // The comb started cold at the switch; what it had not heard has decayed by 100 dB when it is heard.
        let always = try Pipeline { FeedbackComb(delay: 0.001, feedback: 0.5) }.process(noise, format: mono48, blockSize: 64)
        let heard = 1_280 + preroll + 480
        #expect(output[1_280 + preroll + 240] != noise[1_280 + preroll + 240] && output[heard] != noise[heard], "then it is faded in")
        expectClose(Array(output[heard...]), Array(always[heard...]), .absolute(2.0e-5))
    }
}

/// Row 4, a context-dependent family: `PeakNormalize`, with extensions of `PipelineBuilder` and `Pipeline`.
@Suite("Guide 4: a context-dependent family")
struct ContextDependentFamilyTests {
    let noise = TestSignal.whiteNoise(count: 12_000, seed: 4, amplitude: 0.3) + TestSignal.silence(count: 4_096)

    @Test func everyFramePeaksAtOneAndSilenceStaysSilence() throws {
        let frames: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); PeakNormalize() }.process(noise, format: mono48)
        let plain: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude() }.process(noise, format: mono48)
        try #require(frames.count == plain.count && frames.count > 40)
        for (frame, magnitudes) in zip(frames, plain) {
            let peak = magnitudes.max() ?? 0
            #expect(frame.allSatisfy { $0.isFinite && $0 >= 0 })
            if peak > 1e-12 {
                expectClose(frame.max() ?? 0, 1.0, .absolute(1.0e-6))
                expectClose(frame, magnitudes.map { $0 / peak }, .absolute(1.0e-6))
            } else {
                #expect(frame.allSatisfy { $0 == 0 }, "a frame of silence is zeros, not a division by nothing")
            }
        }
        #expect(frames.last?.allSatisfy { $0 == 0 } == true)
    }

    @Test func itKeepsWhateverDomainItFollows() throws {
        // The family: magnitudes or powers on any axis, and the domain is kept.
        let linear = Pipeline { STFT(frame: 1_024, hop: 256); Power(); PeakNormalize() }
        let mel = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 40); PeakNormalize(); Decibels() }
        #expect(linear.outputTag == .spectrum(axis: .linear, values: .power) && mel.outputTag == .spectrum(axis: .mel, values: .decibel))
        let bands: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 40); PeakNormalize() }.process(noise, format: mono48)
        #expect(bands.first?.count == 40)
        expectClose(bands.first?.max() ?? 0, 1.0, .absolute(1.0e-6))
        // Both spellings give one description (API-1).
        #expect(linear == Pipeline().stft(frame: 1_024, hop: 256).power().peakNormalized())
        #expect(linear != Pipeline().stft(frame: 1_024, hop: 256).power().peakNormalized(floor: 0.5))
        // Tier 2: the rule the description carries (ORD-1). It says what the overload says (ORD-2):
        // magnitudes or powers on any axis, kept; nothing else.
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.magnitude, .power] {
                #expect(PeakNormalize.rule(.spectrum(axis: axis, values: values)) == .spectrum(axis: axis, values: values), "\(axis), \(values)")
            }
            for values in [DomainTag.Values.complex, .decibel] {
                #expect(PeakNormalize.rule(.spectrum(axis: axis, values: values)) == nil, "\(axis), \(values)")
            }
        }
        for refused in [DomainTag.samples, .quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum, .envelope, .novelty, .scalar] {
            #expect(PeakNormalize.rule(refused) == nil, "\(refused)")
        }
        var dynamic = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        #expect(throws: DSPError.self) { try dynamic.append(PeakNormalize().stageDescription) }
        try dynamic.append(Magnitude().stageDescription)
        try dynamic.append(PeakNormalize().stageDescription)
        #expect(dynamic.outputTag == .spectrum(axis: .linear, values: .magnitude))
    }

    @MainActor
    @Test func switchedOffTheFramesPassAsTheyAre() throws {
        // ACT-3: a stage that keeps the domain and the rate is bypassed, not suspended.
        let plain: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude() }.process(noise, format: mono48)
        let constant: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); PeakNormalize(isActive: false) }.process(noise, format: mono48)
        #expect(constant == plain)
        // A bound switch, read on the main actor when `process` is called there.
        let box = StateBox(false)
        let pipeline = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); PeakNormalize(isActive: box.binding) }
        let off: [[Float]] = try pipeline.process(noise, format: mono48)
        box.value = true
        let on: [[Float]] = try pipeline.process(noise, format: mono48)
        #expect(off == plain && on != plain)
        expectClose(on.first?.max() ?? 0, 1.0, .absolute(1.0e-6))
    }
}
