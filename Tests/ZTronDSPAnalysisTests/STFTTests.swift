import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `STFT` step (WP-504): complex frames, window normalisations, zero-padding, the two
/// alignments, and what a stage package delivers with it (STG-1).
@Suite("STFT")
struct STFTTests {
    typealias ComplexSpectrum = Spectrum<LinearFrequency, ComplexValues>

    private func window(named name: String) -> Window {
        name == "hamming" ? .hamming : .hann
    }

    // MARK: Golden (STG-2)

    @Test(arguments: ["16-causal", "16-centered", "48-causal", "48-centered", "80-causal", "80-centered", "240-causal", "240-centered",
                      "1024-causal", "1024-centered", "4096-causal", "4096-centered", "padded", "amplitude", "power"])
    func theFramesEqualTheGoldenVectors(name: String) throws {
        let file = try GoldenFile(named: "stft", in: .module)
        let golden = try file.require(name), data = try file.require("data")
        let frame = try golden.integer("frame"), hop = try golden.integer("hop"), length = try golden.integer("length")
        let frames = try golden.integer("frames"), bins = try golden.integer("bins")
        let signalOffset = try golden.integer("signalOffset"), signalCount = try golden.integer("signalCount")
        let spectrumOffset = try golden.integer("spectrumOffset")
        let signal = Array(try data.floats("signals")[signalOffset ..< signalOffset + signalCount])
        let real = try data.real("real"), imaginary = try data.real("imaginary")
        let normalization: WindowNormalization = switch try golden.string("normalization") {
        case "amplitude": .amplitude
        case "power": .power
        default: .none
        }
        let stft = STFT(frame: frame, hop: hop, window: window(named: try golden.string("window")), paddedTo: length == frame ? nil : length,
                        normalization: normalization, alignment: try golden.integer("centered") == 1 ? .centered : .causal)
        let sink = try complexFrames(of: Pipeline { stft }, on: signal, blockSize: 333)

        #expect(sink.frameCount == frames, "\(name): \(sink.frameCount) frames, \(frames) in the reference")
        #expect(bins == length / 2 + 1 && sink.reals.allSatisfy { $0.count == bins })
        var worst = 0.0
        for index in 0 ..< min(frames, sink.frameCount) {
            let start = spectrumOffset + index * bins
            worst = max(worst, complexDeviation(sink.reals[index], sink.imaginaries[index], Array(real[start ..< start + bins]), Array(imaginary[start ..< start + bins])))
        }
        #expect(worst < 1e-5, "\(name): the worst frame deviates by \(worst) of its maximum; the tolerance is 1e-5")
    }

    // MARK: Offline ≡ reference, whatever the blocks

    @Test(arguments: [FrameAlignment.causal, .centered])
    func theFramesDoNotDependOnTheBlockSize(alignment: FrameAlignment) throws {
        let signal = TestSignal.whiteNoise(count: 9_000, seed: 21, amplitude: 0.7)
        let pipeline = Pipeline { STFT(frame: 1_024, hop: 300, window: .blackmanHarris, paddedTo: 2_048, alignment: alignment) }
        let reference = try complexFrames(of: pipeline, on: signal, blockSize: 512)
        #expect(reference.frameCount > 20)
        for blockSize in [1, 7, 64, 480, 4_096, 9_000] {
            let frames = try complexFrames(of: pipeline, on: signal, blockSize: blockSize)
            #expect(frames.reals == reference.reals && frames.imaginaries == reference.imaginaries, "blocks of \(blockSize): bit for bit")
            expectClose(frames.times, reference.times, .absolute(1e-9))
            #expect(frames.indices == reference.indices)
        }
    }

    // MARK: Times, latency, environment (ENV-1, REAL-5)

    @Test func aFrameIsStampedWithTheTimeOfThePointItIsAlignedTo() throws {
        let signal = TestSignal.whiteNoise(count: 4_800, seed: 5)
        let causal = try complexFrames(of: Pipeline { STFT(frame: 256, hop: 64) }, on: signal, blockSize: 100)
        #expect(causal.frameCount == (4_800 - 256) / 64 + 1)
        expectClose(causal.times, (0 ..< causal.frameCount).map { Double($0 * 64 + 255) / 48_000 }, .absolute(1e-12))
        #expect(causal.indices == Array(0 ..< causal.frameCount))
        #expect(causal.environment?.latency == 0, "a causal frame ends at the newest sample: no latency")

        let centered = try complexFrames(of: Pipeline { STFT(frame: 256, hop: 64, alignment: .centered) }, on: signal, blockSize: 100)
        #expect(centered.frameCount == (4_800 - 128) / 64 + 1, "frame k exists once sample k·hop + frame / 2 − 1 has arrived")
        expectClose(centered.times, (0 ..< centered.frameCount).map { Double($0 * 64) / 48_000 }, .absolute(1e-12))
        #expect(centered.environment?.latency == 128.0 / 48_000, "a centred frame is known half a frame after its centre")
    }

    @Test func downstreamIsASpectralScope() throws {
        let sink = CollectingSink<ComplexSpectrum>()
        try run(Pipeline { STFT(frame: 1_024, hop: 256, paddedTo: 4_096); Emit(to: sink) },
                channels: [TestSignal.silence(count: 2_000), TestSignal.silence(count: 2_000)], format: SignalFormat(sampleRate: 44_100, channelCount: 2))
        let environment = try #require(sink.environment)
        #expect(sink.axis == .linearFrequency(binCount: 2_049, nyquist: 22_050))
        #expect(environment.frameSize == 1_024 && environment.hopSize == 256, "the frame, not the padded length, sets the resolution")
        #expect(environment.frequencyResolution == 44_100.0 / 1_024 && environment.featureRate == 44_100.0 / 256)
        #expect(environment.sampleRate == 44_100 && environment.channelCount == 1 && environment.isInSpectralScope)
        #expect(sink.reals.allSatisfy { $0.count == 2_049 })
    }

    // MARK: Values

    @Test func amplitudeNormalisationReadsAFullScaleSineAsOne() throws {
        // 3 kHz at 48 kHz with a frame of 1 024: bin 64 exactly.
        let sine = TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 8_192)
        for window in [Window.hann, .hamming, .blackmanHarris, .flatTop, .rectangular, .kaiser(beta: 9)] {
            let frames: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512, window: window, normalization: .amplitude); Magnitude() }
                .process(sine, format: mono48)
            let frame = try #require(frames.last)
            expectClose(frame[64], 1, .absolute(2e-5), "\(window)")
            #expect(frame.firstIndex(of: frame.max() ?? 0) == 64)
        }
    }

    @Test func powerNormalisationMakesTheBinsAddUpToTheMeanSquare() throws {
        let noise = TestSignal.gaussianNoise(count: 200_000, seed: 77, standardDeviation: 0.25)
        for (window, padded) in [(Window.hann, nil as Int?), (.blackman, 4_096), (.rectangular, nil)] {
            let frames: [[Float]] = try Pipeline { STFT(frame: 2_048, hop: 2_048, window: window, paddedTo: padded, normalization: .power); Power() }
                .process(noise, format: mono48)
            let total = frames.map { $0.reduce(0) { $0 + Double($1) } }.reduce(0, +) / Double(frames.count)
            expectClose(total, 0.0625, .relative(0.03), "\(window), padded to \(padded ?? 2_048): Σ|X|² over the bins is the signal's power")
        }
    }

    @Test func zeroPaddingInterpolatesTheSameSpectrum() throws {
        let signal = TestSignal.whiteNoise(count: 2_048, seed: 3)
        let plain = try complexFrames(of: Pipeline { STFT(frame: 512, hop: 512) }, on: signal)
        let padded = try complexFrames(of: Pipeline { STFT(frame: 512, hop: 512, paddedTo: 2_048) }, on: signal)
        #expect(plain.frameCount == padded.frameCount && padded.reals[0].count == 1_025)
        for frame in 0 ..< plain.frameCount {
            // Every fourth bin of the padded transform is a bin of the plain one.
            let every4thReal = stride(from: 0, to: 1_025, by: 4).map { padded.reals[frame][$0] }
            let every4thImaginary = stride(from: 0, to: 1_025, by: 4).map { padded.imaginaries[frame][$0] }
            #expect(complexDeviation(every4thReal, every4thImaginary, plain.reals[frame].map(Double.init), plain.imaginaries[frame].map(Double.init)) < 1e-5)
        }
    }

    // MARK: Channels (MIC-6)

    @Test func aMultichannelSignalIsReducedByTheChannelPolicy() throws {
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let left = TestSignal.whiteNoise(count: 4_000, seed: 1), right = TestSignal.whiteNoise(count: 4_000, seed: 2)
        func frames(_ policy: ChannelPolicy, _ channels: [[Float]], _ format: SignalFormat) throws -> CollectingSink<ComplexSpectrum> {
            let sink = CollectingSink<ComplexSpectrum>()
            try run(Pipeline { STFT(frame: 256, hop: 64, channels: policy); Emit(to: sink) }, channels: channels, format: format, blockSize: 300)
            return sink
        }
        let mean = zip(left, right).map { ($0 + $1) / 2 }
        let mixed = try frames(.mixdown, [left, right], stereo)
        let reference = try frames(.mixdown, [mean], mono48)
        for index in 0 ..< reference.frameCount {
            #expect(complexDeviation(mixed.reals[index], mixed.imaginaries[index], reference.reals[index].map(Double.init),
                                     reference.imaginaries[index].map(Double.init)) < 1e-6, "the default is the mean of the channels")
        }
        #expect(try frames(.channel(1), [left, right], stereo).reals == frames(.mixdown, [right], mono48).reals)
        #expect(try frames(.channel(0), [left, right], stereo).reals == frames(.perChannel, [left], mono48).reals, "one channel is every channel")
        #expect(throws: DSPError.self) { _ = try frames(.channel(2), [left, right], stereo) }
        #expect(throws: DSPError.self) { _ = try frames(.channel(-1), [left, right], stereo) }
        let refused = errorMessage { _ = try frames(.perChannel, [left, right], stereo) }
        #expect(refused?.contains("one Tap per channel") == true, "\(refused ?? "no error")")
    }

    // MARK: Attach-time checks (O-17, WIN-3)

    @Test func illegalValuesAreRefusedWhenThePipelineIsAttachedWithTheStageInTheError() throws {
        let signal = TestSignal.silence(count: 100)
        func failure(_ stft: STFT) -> DSPError? {
            do {
                try Pipeline { TestGain(1); Tap { stft } }.run(on: signal, format: mono48)
                return nil
            } catch {
                return error
            }
        }
        let length = try #require(failure(STFT(frame: 1_000, hop: 250)))
        #expect("\(length)".contains("960") && "\(length)".contains("1024"), "the error names the nearest legal lengths: \(length)")
        #expect(length.stage?.description == "Tap[1] › STFT[0]", "and the stage: \(length)")
        guard case .invalidParameter(_, let parameter, _) = length else {
            Issue.record("not an invalid parameter: \(length)")
            return
        }
        #expect(parameter == "frame")

        #expect(failure(STFT(frame: 1_024, hop: 0)) != nil && failure(STFT(frame: 1_024, hop: 1_025)) != nil)
        #expect(failure(STFT(frame: 0, hop: 1)) != nil && failure(STFT(frame: -16, hop: 4)) != nil)
        #expect(failure(STFT(frame: 1_024, hop: 256, paddedTo: 512)) != nil, "padding makes the transform longer")
        #expect("\(String(describing: failure(STFT(frame: 1_024, hop: 256, paddedTo: 3_000))))".contains("paddedTo"))
        #expect(failure(STFT(frame: 1_024, hop: 256, window: .hann.half)) != nil)
        #expect(failure(STFT(frame: 1_024, hop: 256, window: .custom { _ in 0 })) != nil, "a window that is zero everywhere (WIN-3)")
        #expect(failure(STFT(frame: 1_024, hop: 256, window: .custom { $0 > 0.5 ? .nan : 1 })) != nil, "a sample that is not finite (WIN-3)")
        #expect(failure(STFT(frame: 1_024, hop: 256, window: .custom { $0 < 0.5 ? 1 : -1 }, normalization: .amplitude)) != nil,
                "a window without a sum has no amplitude normalisation")
        #expect(failure(STFT(frame: 1_024, hop: 256, window: .custom { $0 < 0.5 ? 1 : -1 })) == nil)
        #expect(failure(STFT(frame: 1_024, hop: 256, backend: UnwillingBackend())) != nil)
        #expect(failure(STFT(frame: 1_024, hop: 1_024, window: .hann.symmetric, paddedTo: 1_536)) == nil)
    }

    // MARK: Description, order, activation (STG-1)

    @Test func theFluentSpellingAndTheBuilderGiveEqualDescriptions() {
        let built = Pipeline { STFT(frame: 512, hop: 128, window: .hamming, paddedTo: 1_024, normalization: .power, alignment: .centered, channels: .channel(0)) }
        let fluent = Pipeline().stft(frame: 512, hop: 128, window: .hamming, paddedTo: 1_024, normalization: .power, alignment: .centered, channels: .channel(0))
        #expect(built == fluent)
        #expect(Pipeline { STFT(frame: 512, hop: 128) } == Pipeline().stft(frame: 512, hop: 128, window: .hann, backend: .vDSP, isActive: true))
        #expect(Pipeline { STFT(frame: 512, hop: 128) } != Pipeline { STFT(frame: 512, hop: 64) })
        #expect(Pipeline { STFT(frame: 512, hop: 128) } != Pipeline { STFT(frame: 512, hop: 128, window: .hann.logged()) }, "logging is part of the description")
        #expect(Pipeline { STFT(frame: 512, hop: 128) } != Pipeline { STFT(frame: 512, hop: 128, backend: UnwillingBackend()) })
        #expect(STFT(frame: 512, hop: 128, paddedTo: 2_048).transformLength == 2_048 && STFT(frame: 512, hop: 128).transformLength == 512)
        #expect(STFT.stageName == "STFT" && STFT(frame: 16, hop: 4).backend is VDSPFFTBackend)
    }

    @Test func theRuleOfTheDescriptionAcceptsSamplesOnly() throws {
        let description = try #require(STFT(frame: 512, hop: 128).stageDescriptions.first)
        #expect(description.rule(.samples) == .spectrum(axis: .linear, values: .complex))
        for tag in [DomainTag.scalar, .novelty, .quefrency, .spectrum(axis: .linear, values: .complex), .spectrum(axis: .mel, values: .power), .envelope] {
            #expect(description.rule(tag) == nil, "\(tag)")
        }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(STFT(frame: 512, hop: 128)).appending(STFT(frame: 512, hop: 128)) }
    }

    @Test func equalFramingInSeveralTapsIsComputedOnce() throws {
        let a = CountingSink<ComplexSpectrum>(), b = CountingSink<ComplexSpectrum>(), c = CountingSink<ComplexSpectrum>()
        let shared = Pipeline {
            Tap { STFT(frame: 512, hop: 128); Emit(to: a) }
            Tap { STFT(frame: 512, hop: 128, window: .hann, paddedTo: nil, normalization: .none, alignment: .causal); Emit(to: b) }
            Tap { STFT(frame: 512, hop: 128, channels: .perChannel); Emit(to: c) }
        }
        #expect(nodeNames(try lowered(shared).steps) == ["STFT"], "three taps, one framing and one transform per hop (F5)")
        try shared.run(on: TestSignal.whiteNoise(count: 5_000, seed: 1), format: mono48)
        #expect(a.frames == 36 && b.frames == 36 && c.frames == 36 && a.checksum == b.checksum, "every tap still gets every frame")

        let different = Pipeline {
            Tap { STFT(frame: 512, hop: 128); Emit(to: CountingSink<ComplexSpectrum>()) }
            Tap { STFT(frame: 512, hop: 128, window: .hamming); Emit(to: CountingSink<ComplexSpectrum>()) }
            Tap { STFT(frame: 512, hop: 128, normalization: .amplitude); Emit(to: CountingSink<ComplexSpectrum>()) }
            Tap { STFT(frame: 512, hop: 128, alignment: .centered); Emit(to: CountingSink<ComplexSpectrum>()) }
            Tap { STFT(frame: 512, hop: 128, paddedTo: 1_024); Emit(to: CountingSink<ComplexSpectrum>()) }
        }
        #expect(nodeNames(try lowered(different).steps).count == 5, "what changes the result keeps the framings apart")
    }

    @Test @MainActor func switchedOffItSuspendsTheRestOfItsBranch() throws {
        let signal = TestSignal.whiteNoise(count: 4_000, seed: 2)
        let constant = CollectingSink<ComplexSpectrum>(), bound = CollectingSink<ComplexSpectrum>(), live = CollectingSink<ComplexSpectrum>()
        let off = StateBox(false), on = StateBox(true)
        let output = try Pipeline {
            TestGain(2)
            Tap { STFT(frame: 256, hop: 64, isActive: false); Emit(to: constant) }
            Tap { STFT(frame: 256, hop: 64, isActive: off.binding); Emit(to: bound) }
            Tap { STFT(frame: 256, hop: 64, isActive: on.binding); Emit(to: live) }
        }.process(signal, format: mono48)
        #expect(output == signal.map { $0 * 2 }, "the main line does not notice")
        #expect(constant.frameCount == 0 && constant.claims == 0, "a constant switch removes the branch when the plan is compiled (ACT-4)")
        #expect(bound.frameCount == 0 && bound.claims == 1, "a bound switch suspends it at run time (ACT-3)")
        #expect(live.frameCount == (4_000 - 256) / 64 + 1)
        #expect(STFT(frame: 256, hop: 64, isActive: off.binding).activation.isBound && STFT(frame: 256, hop: 64).activation == .active)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let frames = CountingSink<ComplexSpectrum>(), centered = CountingSink<ComplexSpectrum>(), mixed = CountingSink<ComplexSpectrum>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Emit(to: frames) }
            Tap { STFT(frame: 1_024, hop: 256, window: .kaiser(beta: 8), paddedTo: 4_096, normalization: .power, alignment: .centered); Emit(to: centered) }
        })
        #expect(frames.frames > 990 && centered.frames > 1_990)
        try expectNoAllocationsRunning(Pipeline { STFT(frame: 480, hop: 160, channels: .mixdown); Emit(to: mixed) },
                                       format: SignalFormat(sampleRate: 48_000, channelCount: 3), blockSize: 441)
        #expect(mixed.frames > 2_700)
    }
}

/// A backend that transforms nothing: a strategy written outside the package is passed the
/// same way as a stock one (§5.3).
struct UnwillingBackend: FFTBackend {
    func supports(length: Int) -> Bool { false }
    func makePlan(length: Int) throws(DSPError) -> any FFTPlan {
        throw .backendUnavailable(reason: "this backend transforms nothing")
    }
}
