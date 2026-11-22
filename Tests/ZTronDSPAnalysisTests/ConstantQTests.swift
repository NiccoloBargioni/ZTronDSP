import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The `ConstantQ` step: its highest octave (WP-521), the octave recursion (WP-522a), and what
/// a stage package delivers with it (STG-1).
@Suite("ConstantQ")
struct ConstantQTests {
    typealias ConstantQSpectrum = Spectrum<ConstantQFrequency, ComplexValues>

    private let rate = 22_050.0
    private var format: SignalFormat { SignalFormat(sampleRate: rate) }

    /// The magnitudes of the last frame of a transform.
    private func lastMagnitudes(_ step: ConstantQ, of signal: [Float], format: SignalFormat) throws -> [Double] {
        let sink = try complexFrames(of: Pipeline { step }, on: signal, format: format)
        let last = try #require(sink.reals.indices.last, "no frame from \(signal.count) samples")
        return magnitudes(sink.reals[last], sink.imaginaries[last])
    }

    // MARK: Bin-centre tones (§6.8)

    @Test func aToneAtABinCentreOfTheHighestOctaveReadsItsAmplitude() throws {
        // One octave: no decimator, one kernel. C7 … C8 at three sample rates.
        for rate in [22_050.0, 44_100, 48_000] {
            let step = ConstantQ(fmin: .midiNote(96), octaves: 1, hop: 256)
            let geometry = try step.geometry(in: try lowering(sampleRate: rate))
            var worst = 0.0
            for bin in 0 ..< 36 {
                let tone = TestSignal.sine(frequency: geometry.frequency(ofBin: bin), sampleRate: rate, count: 4_096, amplitude: 0.5, phase: Double(bin))
                let read = try lastMagnitudes(step, of: tone, format: SignalFormat(sampleRate: rate))
                #expect(indexOfMaximum(read) == bin, "\(rate) Hz, bin \(bin)")
                worst = max(worst, abs(20 * log10(read[bin] / 0.5)))
            }
            #expect(worst <= 0.5, "\(rate) Hz: a tone at a bin centre is off by \(worst) dB; 0.5 dB is allowed (§6.8)")
            #expect(worst <= 0.05, "\(rate) Hz: … and measures \(worst) dB")
            print("measured WP-521: at \(rate) Hz a tone at a bin centre of the highest octave is off by \(worst) dB at worst")
        }
    }

    @Test func aToneAtEveryBinCentreOfEveryOctaveReadsItsAmplitude() throws {
        // C1 up, 7 octaves of 36 bins: the defaults. Twenty-one tones at once, three in each
        // octave and four semitones apart; twelve signals cover all 252 bins. A signal is
        // long enough for the last frame to lie wholly inside it, the longest atom included.
        // Each octave has an amplitude of its own, so an octave read in another's place shows.
        func amplitude(_ bin: Int) -> Double { 0.02 + 0.005 * Double(bin / 36) }
        let step = ConstantQ()
        let geometry = try step.geometry(in: try lowering(sampleRate: rate))
        #expect(geometry.binCount == 252 && geometry.atomLength(ofBin: 0) < 36_000)
        var worst = 0.0
        for position in 0 ..< 12 {
            var signal = [Float](repeating: 0, count: 40_000)
            let bins = (0 ..< 7).flatMap { octave in [0, 12, 24].map { octave * 36 + position + $0 } }
            for bin in bins {
                let tone = TestSignal.sine(frequency: geometry.frequency(ofBin: bin), sampleRate: rate, count: signal.count, amplitude: amplitude(bin), phase: Double(bin))
                for index in signal.indices { signal[index] += tone[index] }
            }
            let read = try lastMagnitudes(step, of: signal, format: format)
            for bin in bins {
                let level = 20 * log10(read[bin] / amplitude(bin))
                worst = max(worst, abs(level))
                #expect(abs(level) <= 0.5, "bin \(bin), at \(geometry.frequency(ofBin: bin)) Hz: \(level) dB")
                // The tone's own bin is the largest within a semitone and a half of it.
                let range = max(bin - 5, 0) ... min(bin + 5, 251)
                #expect(range.lowerBound + indexOfMaximum(Array(read[range])) == bin, "bin \(bin)")
            }
        }
        #expect(worst <= 0.05, "the worst of 252 bins is off by \(worst) dB")
        print("measured WP-522a: a tone at the centre of each of the 252 bins of the defaults at \(rate) Hz is off by \(worst) dB at worst")
    }

    @Test func aToneBetweenTwoBinsIsSharedByThem() throws {
        let step = ConstantQ(fmin: .midiNote(48), octaves: 4, binsPerOctave: 12, hop: 64)
        let geometry = try step.geometry(in: try lowering(sampleRate: rate))
        for bin in [3, 20, 40] {
            let between = (geometry.frequency(ofBin: bin) * geometry.frequency(ofBin: bin + 1)).squareRoot()
            let read = try lastMagnitudes(step, of: TestSignal.sine(frequency: between, sampleRate: rate, count: 9_000, amplitude: 0.5), format: format)
            let sorted = read.enumerated().sorted { $0.element > $1.element }
            #expect(Set([sorted[0].offset, sorted[1].offset]) == [bin, bin + 1], "between bins \(bin) and \(bin + 1)")
            expectClose(read[bin], read[bin + 1], .relative(0.05))
            #expect(read[bin] < 0.5 && read[bin] > 0.3, "half a bin off its centre a tone reads \(read[bin])")
        }
    }

    // MARK: Against the definition (STG-2)

    @Test(arguments: ["music-defaults", "speech-semitones", "music-variable-q", "music-top-octave"])
    func theTransformOfTheFixturesIsThatOfTheDefinition(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("transform-\(name)")
        let signal = try fixture(of: golden)
        let bins = try golden.integer("bins"), frames = try golden.integer("frames")
        let real = try golden.real("real"), imaginary = try golden.real("imaginary")
        let peak = peakMagnitude(real, imaginary)

        /// The largest distance from the definition, as a share of the largest magnitude of the excerpt.
        func distance(_ sink: CollectingSink<ConstantQSpectrum>) -> Double {
            var worst = 0.0
            for frame in 0 ..< sink.frameCount {
                for bin in 0 ..< bins {
                    worst = max(worst, hypot(Double(sink.reals[frame][bin]) - real[frame * bins + bin], Double(sink.imaginaries[frame][bin]) - imaginary[frame * bins + bin]))
                }
            }
            return worst / peak
        }

        let step = try constantQ(of: golden), whole = try constantQ(of: golden, sparsity: 0)
        let sink = try complexFrames(of: Pipeline { step }, on: signal.samples, format: signal.format, blockSize: 441)
        // A stream waits for its filters as well as for its atoms: a few frames fewer than
        // the definition has, and each of them one of the definition's.
        #expect(sink.frameCount > frames * 3 / 4 && sink.frameCount <= frames && sink.reals.allSatisfy { $0.count == bins }, "\(sink.frameCount) of \(frames) frames")
        let thinned = distance(sink)
        #expect(thinned <= 0.01, "\(name): off by \(thinned) of the largest magnitude of the excerpt")
        let perFrame = worstDeviation(sink, real: real, imaginary: imaginary, bins: bins, frames: sink.frameCount)
        #expect(perFrame.mean <= 0.01, "\(name): a frame is off by \(perFrame.mean) of its own maximum in the mean, \(perFrame.worst) at worst")

        // With nothing dropped from the kernel, what is left is the decimators and the
        // rounding of the atom lengths at each octave's own rate; in one octave, nothing.
        let dense = try complexFrames(of: Pipeline { whole }, on: signal.samples, format: signal.format, blockSize: 441)
        let unthinned = distance(dense)
        let octaves = try golden.integer("octaves")
        #expect(unthinned <= (octaves == 1 ? 1e-4 : 0.01) && unthinned < thinned, "\(name), sparsity 0: off by \(unthinned)")
        let densePerFrame = worstDeviation(dense, real: real, imaginary: imaginary, bins: bins, frames: dense.frameCount)
        print("measured WP-521/522a: \(name): sparsity 0.01 off by \(thinned) of the largest magnitude of the excerpt (a frame against its own maximum: \(perFrame.worst) at worst, \(perFrame.mean) in the mean); sparsity 0 off by \(unthinned) (a frame: \(densePerFrame.worst) at worst)")
    }

    @Test func theHighestOctaveIsTheDefinitionWithoutTheSparsity() throws {
        // An oracle of the test's own, on noise, for atoms under other windows. A kernel
        // reads the bins of a one-sided spectrum: what the transform of an atom has at
        // negative frequencies is not in it. Under a window with low side lobes that is
        // nothing; under a Hann window, whose side lobes fall by 18 dB an octave, a ten
        // thousandth; under one that does not reach zero at its edges it is the best part of
        // the 0.1 % of its energy a row may lose.
        let shapes: [(Window, (Double) -> Double, Double)] = [
            (.hann, hannShape, 5e-4),
            (.blackmanHarris, { 0.35875 - 0.48829 * cos(2 * .pi * $0) + 0.14128 * cos(4 * .pi * $0) - 0.01168 * cos(6 * .pi * $0) }, 2e-5),
            (.hamming, { 0.54 - 0.46 * cos(2 * .pi * $0) }, 0.032),
        ]
        let noise = TestSignal.whiteNoise(count: 3_000, seed: 521, amplitude: 0.5)
        for (window, shape, tolerance) in shapes {
            let step = ConstantQ(fmin: .hertz(1_500), octaves: 1, binsPerOctave: 8, tuning: -0.3, filterScale: 1.5, hop: 50, window: window, sparsity: 0)
            let geometry = try step.geometry(in: try lowering(sampleRate: 16_000))
            let sink = try complexFrames(of: Pipeline { step }, on: noise, format: SignalFormat(sampleRate: 16_000), blockSize: 97)
            let reference = referenceConstantQ(noise, geometry: geometry, hop: 50, frames: sink.frameCount, window: shape)
            #expect(sink.frameCount == (3_000 - (geometry.atomLength(ofBin: 0) + 1) / 2) / 50 + 1)
            var worst = 0.0
            for frame in 0 ..< sink.frameCount {
                worst = max(worst, complexDeviation(sink.reals[frame], sink.imaginaries[frame], reference.real[frame], reference.imaginary[frame]))
            }
            #expect(worst <= tolerance, "\(window): a frame is off by \(worst) of its maximum")
            let kernel = try ConstantQKernel(geometry: geometry, octave: 0, window: window, sparsity: 0)
            let mirrored = 1 - (kernel.keptEnergy.min() ?? 0)
            print("measured WP-521: the highest octave under \(window), sparsity 0, against the definition: a frame is off by \(worst) of its maximum; the share of an atom's energy at negative frequencies is \(mirrored) at most")
            if window == .hamming { #expect(worst >= 1e-3, "the mirror image of a Hamming atom is not nothing: \(worst)") }
        }
    }

    // MARK: Offline ≡ reference, whatever the blocks

    @Test(arguments: [0.0, 4.0])
    func theFramesDoNotDependOnTheBlockSize(gamma: Double) throws {
        let signal = TestSignal.whiteNoise(count: 20_000, seed: 21, amplitude: 0.7)
        let pipeline = Pipeline { ConstantQ(fmin: .hertz(110), octaves: 5, binsPerOctave: 24, gamma: gamma, hop: 64) }
        let reference = try complexFrames(of: pipeline, on: signal, format: format, blockSize: 512)
        #expect(reference.frameCount > 150, "\(reference.frameCount) frames")
        for blockSize in [1, 7, 64, 480, 1_024, 1_025, 4_096, 20_000] {
            let frames = try complexFrames(of: pipeline, on: signal, format: format, blockSize: blockSize)
            #expect(frames.reals == reference.reals && frames.imaginaries == reference.imaginaries, "blocks of \(blockSize): bit for bit")
            expectClose(frames.times, reference.times, .absolute(1e-9))
            #expect(frames.indices == reference.indices)
        }
    }

    // MARK: Silence, and numbers a signal would not give

    @Test func silenceGivesZeros() throws {
        let sink = try complexFrames(of: Pipeline { ConstantQ() }, on: TestSignal.silence(count: 25_000), format: format)
        #expect(sink.frameCount > 5 && sink.reals.allSatisfy { $0.allSatisfy { $0 == 0 } } && sink.imaginaries.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    // MARK: Times, latency, environment (ENV-1, REAL-5)

    @Test func downstreamIsASpectralScopeOnAConstantQAxis() throws {
        let sink = CollectingSink<ConstantQSpectrum>()
        let feed = HeatmapFeed(history: 32)
        try run(Pipeline { ConstantQ(fmin: .hertz(55), octaves: 6, binsPerOctave: 24, tuning: 0.5, hop: 256); Emit(to: sink); Magnitude(); Decibels(); Emit(to: feed) },
                channels: [TestSignal.whiteNoise(count: 30_000, seed: 1), TestSignal.whiteNoise(count: 30_000, seed: 2)],
                format: SignalFormat(sampleRate: 44_100, channelCount: 2))
        let environment = try #require(sink.environment)
        let geometry = try ConstantQGeometry(minimumFrequency: 55, octaves: 6, binsPerOctave: 24, tuning: 0.5, sampleRate: 44_100)
        #expect(sink.axis == .constantQ(minimumFrequency: 55 * pow(2, 0.5 / 24), binsPerOctave: 24, binCount: 144) && sink.axis == geometry.axis)
        #expect(environment.frequencyAxis == sink.axis && environment.hopSize == 256 && environment.featureRate == 44_100.0 / 256)
        #expect(environment.frameSize == geometry.atomLength(ofBin: 0), "the frame of the scope is the longest atom")
        #expect(environment.sampleRate == 44_100 && environment.channelCount == 1 && environment.isInSpectralScope)
        #expect(environment.latency > 0.5 * Double(geometry.atomLength(ofBin: 0)) / 44_100 && environment.latency < 0.6 * Double(geometry.atomLength(ofBin: 0)) / 44_100)
        #expect(sink.frameCount > 20 && sink.reals.allSatisfy { $0.count == 144 })
        // A feed of the magnitudes carries the same axis: a view labels its rows from it.
        #expect(feed.axis == sink.axis && feed.rowCount == 144 && feed.columnCount == min(sink.frameCount, 32))
        #expect(feed.snapshot().environment?.latency == environment.latency, "the latency reaches the sink")
    }

    // MARK: Channels (MIC-6)

    @Test func aMultichannelSignalIsReducedByTheChannelPolicy() throws {
        let stereo = SignalFormat(sampleRate: 22_050, channelCount: 2)
        let left = TestSignal.whiteNoise(count: 6_000, seed: 1), right = TestSignal.whiteNoise(count: 6_000, seed: 2)
        func frames(_ policy: ChannelPolicy, _ channels: [[Float]], _ format: SignalFormat) throws -> CollectingSink<ConstantQSpectrum> {
            let sink = CollectingSink<ConstantQSpectrum>()
            try run(Pipeline { ConstantQ(fmin: .hertz(440), octaves: 3, binsPerOctave: 12, hop: 128, channels: policy); Emit(to: sink) },
                    channels: channels, format: format, blockSize: 300)
            return sink
        }
        let mean = zip(left, right).map { ($0 + $1) / 2 }
        let mixed = try frames(.mixdown, [left, right], stereo), reference = try frames(.mixdown, [mean], format)
        #expect(reference.frameCount > 30 && mixed.frameCount == reference.frameCount)
        for index in 0 ..< reference.frameCount {
            #expect(complexDeviation(mixed.reals[index], mixed.imaginaries[index], reference.reals[index].map(Double.init),
                                     reference.imaginaries[index].map(Double.init)) < 1e-5, "the default is the mean of the channels")
        }
        #expect(try frames(.channel(1), [left, right], stereo).reals == frames(.mixdown, [right], format).reals)
        #expect(try frames(.channel(0), [left, right], stereo).reals == frames(.perChannel, [left], format).reals, "one channel is every channel")
        #expect(throws: DSPError.self) { _ = try frames(.channel(2), [left, right], stereo) }
        let refused = errorMessage { _ = try frames(.perChannel, [left, right], stereo) }
        #expect(refused?.contains("one Tap per channel") == true, "\(refused ?? "no error")")
    }

    // MARK: Attach-time checks (O-16, O-17)

    @Test func valuesTheTransformCannotBeMadeForAreRefusedWhenThePipelineIsAttached() throws {
        func failure(_ step: ConstantQ, rate: Double = 48_000) -> DSPError? {
            do {
                try Pipeline { step }.run(on: TestSignal.silence(count: 64), format: SignalFormat(sampleRate: rate))
                return nil
            } catch {
                return error
            }
        }
        func parameter(_ error: DSPError?) -> String? {
            if case .invalidParameter(_, let parameter, _)? = error { return parameter }
            return nil
        }
        #expect(failure(ConstantQ()) == nil && failure(ConstantQ(), rate: 44_100) == nil && failure(ConstantQ(), rate: 22_050) == nil)
        // Bins that reach the Nyquist frequency at the step's position (O-16).
        let nyquist = try #require(failure(ConstantQ(), rate: 8_000))
        #expect(parameter(nyquist) == "octaves" && "\(nyquist)".contains("Nyquist frequency of 4000.0 Hz") && "\(nyquist)".contains("6 octaves above") && nyquist.stage?.description == "ConstantQ[0]", "\(nyquist)")
        #expect(failure(ConstantQ(octaves: 6), rate: 8_000) == nil)
        #expect(parameter(failure(ConstantQ(fmin: .hertz(30_000)))) == "fmin" && parameter(failure(ConstantQ(fmin: .hertz(0)))) == "fmin")
        #expect(parameter(failure(ConstantQ(fmin: .fractionOfNyquist(0.5), octaves: 2))) == "octaves")
        #expect(failure(ConstantQ(fmin: .fractionOfNyquist(0.2), octaves: 1)) == nil, "a frequency in any unit")
        // Bins the decimators do not keep clean: above 0.8 of the Nyquist frequency.
        let unclean = try #require(failure(ConstantQ(fmin: .hertz(4_900), octaves: 2, binsPerOctave: 12)))
        #expect(parameter(unclean) == "octaves" && "\(unclean)".contains("half-band decimators"), "\(unclean)")
        #expect(failure(ConstantQ(fmin: .hertz(9_800), octaves: 1, binsPerOctave: 12)) == nil, "one octave has no decimator")
        // Counts, scales and shares out of range; atoms too short to have a frequency.
        #expect(parameter(failure(ConstantQ(octaves: 0))) == "octaves" && parameter(failure(ConstantQ(binsPerOctave: 0))) == "binsPerOctave")
        #expect(parameter(failure(ConstantQ(tuning: 2))) == "tuning" && parameter(failure(ConstantQ(filterScale: 0))) == "filterScale")
        #expect(parameter(failure(ConstantQ(gamma: -1))) == "gamma" && parameter(failure(ConstantQ(sparsity: 1))) == "sparsity" && parameter(failure(ConstantQ(sparsity: -0.5))) == "sparsity")
        #expect(parameter(failure(ConstantQ(binsPerOctave: 1))) == "binsPerOctave" && "\(String(describing: failure(ConstantQ(binsPerOctave: 1))))".contains("mirror image"))
        #expect(parameter(failure(ConstantQ(gamma: 60))) == "binsPerOctave", "a gamma that leaves the lowest atoms a period or two")
        // Windows (WIN-3).
        #expect(parameter(failure(ConstantQ(window: .hann.half))) == "window" && failure(ConstantQ(window: .custom { _ in 0 })) != nil)
        #expect(failure(ConstantQ(window: .custom { $0 > 0.5 ? .nan : 1 })) != nil && failure(ConstantQ(window: .blackmanHarris)) == nil)
        // A strategy that cannot be had, and one that states a latency that is none.
        #expect(parameter(failure(ConstantQ(strategy: .multirateSparseKernel(backend: UnwillingBackend())))) == "strategy")
        #expect(parameter(failure(ConstantQ(strategy: SilentStrategy(delay: -1)))) == "strategy" && failure(ConstantQ(strategy: SilentStrategy(delay: 7))) == nil)
    }

    // MARK: Description, order, activation (STG-1)

    @Test func theFluentSpellingAndTheBuilderGiveEqualDescriptions() {
        let built = Pipeline { ConstantQ(fmin: .hertz(55), octaves: 6, binsPerOctave: 24, tuning: 0.25, filterScale: 2, gamma: 3, hop: 256, window: .hamming, sparsity: 0.02, channels: .channel(0)) }
        let fluent = Pipeline().constantQ(fmin: .hertz(55), octaves: 6, binsPerOctave: 24, tuning: 0.25, filterScale: 2, gamma: 3, hop: 256, window: .hamming, sparsity: 0.02, channels: .channel(0))
        #expect(built == fluent)
        #expect(Pipeline { ConstantQ() } == Pipeline().constantQ(fmin: .midiNote(24), octaves: 7, binsPerOctave: 36, tuning: 0, filterScale: 1, gamma: 0, hop: 512, window: .hann,
                                                                 sparsity: 0.01, strategy: .multirateSparseKernel, channels: .mixdown, isActive: true), "the defaults of §6.8")
        let different: [ConstantQ] = [
            ConstantQ(fmin: .midiNote(25)), ConstantQ(octaves: 6), ConstantQ(binsPerOctave: 24), ConstantQ(tuning: 0.1), ConstantQ(filterScale: 2), ConstantQ(gamma: 1),
            ConstantQ(hop: 256), ConstantQ(window: .hamming), ConstantQ(sparsity: 0.02), ConstantQ(strategy: SilentStrategy(delay: 0)), ConstantQ(channels: .channel(0)),
            ConstantQ(isActive: false), ConstantQ(strategy: .multirateSparseKernel(backend: UnwillingBackend())),
        ]
        for step in different { #expect(Pipeline { step } != Pipeline { ConstantQ() }) }
        #expect(ConstantQ.stageName == "ConstantQ" && ConstantQ().strategy is MultirateSparseKernelStrategy && ConstantQ(strategy: SilentStrategy(delay: 3)).strategy is SilentStrategy)
        #expect(MultirateSparseKernelStrategy().backend is VDSPFFTBackend && MultirateSparseKernelStrategy(backend: UnwillingBackend()).backend is UnwillingBackend)
        #expect(MultirateSparseKernelStrategy() == .multirateSparseKernel && MultirateSparseKernelStrategy() != .multirateSparseKernel(backend: UnwillingBackend()))
        let defaults = ConstantQ()
        #expect(defaults.fmin == .midiNote(24) && defaults.octaves == 7 && defaults.binsPerOctave == 36 && defaults.tuning == 0 && defaults.filterScale == 1 && defaults.gamma == 0)
        #expect(defaults.hop == 512 && defaults.window == .hann && defaults.sparsity == 0.01 && defaults.channels == .mixdown && defaults.activation == .active)
    }

    @Test func theRuleOfTheDescriptionAcceptsSamplesOnly() throws {
        let description = try #require(ConstantQ().stageDescriptions.first)
        #expect(description.rule(.samples) == .spectrum(axis: .constantQ, values: .complex))
        for tag in OrderMatrixTests.domains where tag != .samples { #expect(description.rule(tag) == nil, "\(tag)") }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(ConstantQ()).appending(ConstantQ()) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256)).appending(ConstantQ()) }
        #expect(try DynamicPipeline().appending(ConstantQ()).appending(Magnitude().stageDescription).outputTag == .spectrum(axis: .constantQ, values: .magnitude))
    }

    @Test func equalTransformsInSeveralTapsAreComputedOnce() throws {
        let a = CountingSink<ConstantQSpectrum>(), b = CountingSink<ConstantQSpectrum>(), c = CountingSink<ConstantQSpectrum>()
        let shared = Pipeline {
            Tap { ConstantQ(fmin: .midiNote(48), octaves: 5); Emit(to: a) }
            // The same bins stated in another unit and with every default written out: the
            // descriptions differ, the transform does not.
            Tap { ConstantQ(fmin: .hertz(noteFrequency(48)), octaves: 5, binsPerOctave: 36, tuning: 0, filterScale: 1, gamma: 0, hop: 512, window: .hann, sparsity: 0.01); Emit(to: b) }
            Tap { ConstantQ(fmin: .midiNote(48), octaves: 5, channels: .perChannel); Emit(to: c) }
        }
        #expect(nodeNames(try lowered(shared, sampleRate: rate).steps) == ["ConstantQ"], "three taps, one transform (F5)")
        try shared.run(on: TestSignal.whiteNoise(count: 12_000, seed: 1), format: format)
        #expect(a.frames > 10 && b.frames == a.frames && c.frames == a.frames && a.checksum == b.checksum, "every tap still gets every frame")

        let different = Pipeline {
            Tap { ConstantQ(octaves: 5); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, tuning: 0.1); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, gamma: 2); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, hop: 256); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, window: .blackmanHarris); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, sparsity: 0.001); Emit(to: CountingSink<ConstantQSpectrum>()) }
            Tap { ConstantQ(octaves: 5, filterScale: 1.5); Emit(to: CountingSink<ConstantQSpectrum>()) }
        }
        #expect(nodeNames(try lowered(different, sampleRate: rate).steps).count == 7, "what changes the result keeps the transforms apart")
    }

    @Test @MainActor func switchedOffItSuspendsTheRestOfItsBranch() throws {
        let signal = TestSignal.whiteNoise(count: 9_000, seed: 2)
        let constant = CollectingSink<ConstantQSpectrum>(), bound = CollectingSink<ConstantQSpectrum>(), live = CollectingSink<ConstantQSpectrum>()
        let off = StateBox(false), on = StateBox(true)
        let output = try Pipeline {
            TestGain(2)
            Tap { ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, hop: 64, isActive: false); Emit(to: constant) }
            Tap { ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, hop: 64, isActive: off.binding); Emit(to: bound) }
            Tap { ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, hop: 64, isActive: on.binding); Emit(to: live) }
        }.process(signal, format: format)
        #expect(output == signal.map { $0 * 2 }, "the main line does not notice")
        #expect(constant.frameCount == 0 && constant.claims == 0, "a constant switch removes the branch when the plan is compiled (ACT-4)")
        #expect(bound.frameCount == 0 && bound.claims == 1, "a bound switch suspends it at run time (ACT-3)")
        #expect(live.frameCount > 100)
        #expect(ConstantQ(isActive: off.binding).activation.isBound && ConstantQ().activation == .active)
    }

    // MARK: Cold start, settling (ACT-10, SWAP-2)

    @Test(arguments: [0.0, 3.0])
    func afterAColdStartTheFramesAreThoseOfAFreshStream(gamma: Double) throws {
        // 9 000 samples are no whole number of hops, of blocks or of decimator cells.
        let noise = TestSignal.whiteNoise(count: 9_000, seed: 77, amplitude: 0.5)
        let pipeline = Pipeline { ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, gamma: gamma, hop: 64) }
        let cold = try twoPasses(of: pipeline, on: noise, coldStart: true, format: format)
        let warm = try twoPasses(of: pipeline, on: noise, coldStart: false, format: format)
        let half = cold.frameCount / 2
        #expect(half > 100 && cold.frameCount == 2 * half)
        #expect(Array(cold.reals[..<half]) == Array(cold.reals[half...]) && Array(cold.imaginaries[..<half]) == Array(cold.imaginaries[half...]),
                "the second pass has the values of a fresh stream")
        #expect(Array(cold.times[..<half]) == Array(cold.times[half...]) && Array(cold.indices[..<half]) == Array(cold.indices[half...]), "and its times")
        #expect(warm.reals != cold.reals && warm.frameCount > cold.frameCount, "without a cold start the second pass goes on from the first")
    }

    @Test func whatCameBeforeNoLongerShowsOnceTheSettlingTimeHasPassed() throws {
        // Loud noise, then a tone, on one plan; and the tone alone. Frames centred later than
        // the settling time after the change are those of the tone alone.
        let step = ConstantQ(fmin: .hertz(220), octaves: 4, binsPerOctave: 12, hop: 64)
        let geometry = try step.geometry(in: try lowering(sampleRate: rate))
        let node = try step.strategy.makeNode(of: geometry, hop: 64, window: .hann, sparsity: 0.01, channel: nil, channelCount: 1, maximumBlockFrames: 512)
        let settling = node.settlingFrames, latency = node.latencyFrames
        #expect(settling > geometry.atomLength(ofBin: 0) / 2 && settling < geometry.atomLength(ofBin: 0) && latency > 0)
        let before = 6_400            // a whole number of hops, and of the cells the decimators compute in
        let tone = TestSignal.sine(frequency: 880, sampleRate: rate, count: 6_000, amplitude: 0.25)
        let joined = try complexFrames(of: Pipeline { step }, on: TestSignal.whiteNoise(count: before, seed: 9) + tone, format: format)
        let alone = try complexFrames(of: Pipeline { step }, on: tone, format: format)
        var settled = 0, unsettled = 0
        for frame in 0 ..< alone.frameCount {
            let deviation = complexDeviation(joined.reals[frame + before / 64], joined.imaginaries[frame + before / 64],
                                             alone.reals[frame].map(Double.init), alone.imaginaries[frame].map(Double.init))
            if frame * 64 >= settling {
                #expect(deviation <= 1e-4, "frame \(frame), \(frame * 64) samples after the change: off by \(deviation)")
                settled += 1
            } else if deviation > 0.01 {
                unsettled += 1
            }
        }
        #expect(settled > 20 && unsettled > 5, "\(settled) frames after the settling time, \(unsettled) before it that still hold the noise")
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let frames = CountingSink<ConstantQSpectrum>(), variable = CountingSink<ConstantQSpectrum>(), mixed = CountingSink<ConstantQSpectrum>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { ConstantQ(); Emit(to: frames) }
            Tap { ConstantQ(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, gamma: 4, hop: 128, window: .blackmanHarris); Emit(to: variable) }
        })
        #expect(frames.frames > 900 && variable.frames > 3_900, "\(frames.frames) and \(variable.frames) frames")
        try expectNoAllocationsRunning(Pipeline { ConstantQ(fmin: .hertz(440), octaves: 1, binsPerOctave: 12, hop: 160, channels: .mixdown); Emit(to: mixed) },
                                       format: SignalFormat(sampleRate: 48_000, channelCount: 3), blockSize: 441)
        #expect(mixed.frames > 2_700)
    }
}
