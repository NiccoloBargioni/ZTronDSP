import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The cepstral steps (WP-509, WP-510, WP-511): `Cepstrum`, `InverseCepstrum`, `Lifter`,
/// `CepstralPitch`.
@Suite("Cepstrum")
struct CepstrumTests {
    typealias ComplexSpectrum = Spectrum<LinearFrequency, ComplexValues>
    private let noise = TestSignal.gaussianNoise(count: 16_384, seed: 509, standardDeviation: 0.2)

    // MARK: Real and power cepstrum (WP-509)

    @Test(arguments: ["speech", "music"])
    func theRealAndThePowerCepstrumEqualTheGoldenVectors(name: String) throws {
        let fixture = try GoldenFile(named: "fixtures", in: .module).require(name)
        let golden = try GoldenFile(named: "cepstrum", in: .module).require("cepstrum-\(name)")
        let samples = try fixture.floats("samples"), format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        let frame = try golden.integer("frame"), hop = try golden.integer("hop"), floor = try golden.number("floor"), count = try golden.integer("frames")
        let quefrencies = frame / 2 + 1
        for (kind, key) in [(CepstrumKind.real, "real"), (.power, "power")] {
            let reference = try golden.real(key)
            let frames: [[Float]] = try Pipeline { STFT(frame: frame, hop: hop); Cepstrum(kind, floor: floor) }.process(samples, format: format, blockSize: 300)
            #expect(frames.count == count && frames.allSatisfy { $0.count == quefrencies }, "a real or power cepstrum is even: quefrencies 0 … N / 2")
            for (index, values) in frames.enumerated() {
                expectClose(values, Array(reference[index * quefrencies ..< (index + 1) * quefrencies]), .relativeToMaximum(1e-4), "\(name), \(key), frame \(index)")
            }
        }
    }

    @Test func anEchoAppearsAtItsDelay() throws {
        let delay = 150
        var echoed = noise
        for index in delay ..< noise.count { echoed[index] += 0.5 * noise[index - delay] }
        for kind in [CepstrumKind.real, .power] {
            let frames: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 2_048, window: .hann); Cepstrum(kind) }.process(echoed, format: mono48)
            for values in frames.dropFirst() {
                let peak = try #require(values[40 ..< 1_000].enumerated().max { $0.element < $1.element })
                #expect(peak.offset + 40 == delay, "\(kind): the largest quefrency is \(peak.offset + 40) samples")
            }
            // ln |1 + a·e^(−jωD)| = a·cos(ωD) − …: half of a at the delay, for the real cepstrum.
            if kind == .real { expectClose(frames[2][delay], 0.25, .absolute(0.05)) }
        }
    }

    @Test func theComplexCepstrumOfAnEchoIsATrainAtItsDelay() throws {
        // A decaying exponential and its echo, whole inside one frame: a signal whose phase
        // unwraps without ambiguity. ln(1 + a·z^(−D)) = Σ (−1)^(k+1)·(a^k / k)·z^(−kD).
        var signal = TestSignal.silence(count: 4_096)
        for index in 0 ..< 400 { signal[index] = Float(pow(0.9, Double(index))) }
        for index in 0 ..< 400 { signal[index + 64] += 0.5 * Float(pow(0.9, Double(index))) }
        let frames: [[Float]] = try Pipeline { STFT(frame: 4_096, hop: 4_096, window: .rectangular); Cepstrum(.complex) }.process(signal, format: mono48)
        let values = try #require(frames.first)
        expectClose(values[64], 0.5, .absolute(1e-4))
        expectClose(values[128], -0.125, .absolute(1e-4))
        expectClose(values[192], 0.125 / 3, .absolute(1e-4))
        // The exponential itself: ln(1 / (1 − 0.9·z⁻¹)) = Σ (0.9^n / n)·z^(−n), causal.
        expectClose(values[1], 0.9, .absolute(1e-4))
        expectClose(values[2], 0.405, .absolute(1e-4))
        #expect(values[2_048 ..< 4_096].allSatisfy { abs($0) < 1e-4 }, "a minimum-phase signal has no negative quefrencies")
        #expect(values[4_096] == 0 && values[4_097] == 1, "no delay to take out, and a positive bin 0")
    }

    @Test func theLogarithmIsFloored() throws {
        let silence = TestSignal.silence(count: 4_096)
        let real: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.real, floor: 1e-6) }.process(silence, format: mono48)
        let power: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.power, floor: 1e-6) }.process(silence, format: mono48)
        let complex: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.complex) }.process(silence, format: mono48)
        // A flat log spectrum at the floor: its cepstrum is the floor's logarithm at quefrency 0.
        expectClose(real[0][0], log(1e-6), .relative(1e-6))
        expectClose(power[0][0], log(1e-6) * log(1e-6), .relative(1e-6))
        expectClose(complex[0][0], log(1e-10), .relative(1e-6))
        #expect(real.allSatisfy { $0.dropFirst().allSatisfy { abs($0) < 1e-6 } } && (real + power + complex).allSatisfy { $0.allSatisfy { $0.isFinite } }, "no NaN, no infinity (NUM-1)")
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.real, floor: 0) }.process(silence, format: mono48) }
        #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.real, floor: -.infinity) }.process(silence, format: mono48) }
    }

    @Test func downstreamTheAxisIsQuefrency() throws {
        let real = CollectingSink<Quefrency>(), complex = CollectingSink<Quefrency>()
        try Pipeline {
            Tap { STFT(frame: 512, hop: 128, paddedTo: 1_024); Cepstrum(.real); Emit(to: real) }
            Tap { STFT(frame: 512, hop: 128, paddedTo: 1_024); Cepstrum(.complex); Emit(to: complex) }
        }.run(on: noise, format: mono48)
        #expect(real.axis == .quefrency(count: 513, sampleRate: 48_000) && real.reals.allSatisfy { $0.count == 513 })
        #expect(complex.axis == .quefrency(count: 1_026, sampleRate: 48_000) && complex.reals.allSatisfy { $0.count == 1_026 }, "the transform length and two values that are not quefrencies")
        #expect(real.environment?.frameSize == 512 && real.environment?.hopSize == 128 && real.environment?.sampleRate == 48_000)
        expectClose(real.times.first ?? -1, 511.0 / 48_000, .absolute(1e-12))
        #expect(CepstrumLayout(rowCount: 513) == .oneSided(length: 1_024) && CepstrumLayout(rowCount: 1_026) == .complex(length: 1_024))
        #expect(CepstrumLayout(rowCount: 500) == .plain(count: 500) && CepstrumLayout(rowCount: 1) == .plain(count: 1))
        #expect(CepstrumLayout.complex(length: 64).quefrency(at: 63) == 1 && CepstrumLayout.complex(length: 64).quefrency(at: 64) == nil)
        #expect(CepstrumLayout.plain(count: 9).frameCount == 9 && CepstrumLayout.plain(count: 9).positiveCount == 9 && CepstrumLayout.oneSided(length: 64).frameCount == 33)
    }

    // MARK: Complex cepstrum and back (WP-510)

    @Test func theComplexCepstrumOfADelayedImpulseIsItsDelay() throws {
        // A unit impulse at sample d of a frame has a flat magnitude and a phase that is all
        // delay: the cepstrum is zero, and the delay taken out is d samples.
        for (position, amplitude) in [(37, Float(1)), (700, -1), (0, 0.5)] {
            var impulse = TestSignal.silence(count: 1_024)
            impulse[position] = amplitude
            let frames: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 1_024, window: .rectangular); Cepstrum(.complex) }.process(impulse, format: mono48)
            let values = try #require(frames.first)
            expectClose(values[0], log(Double(abs(amplitude))), .absolute(1e-6))
            #expect(values[1 ..< 1_024].allSatisfy { abs($0) < 1e-6 }, "nothing but the level is left")
            // A delay is known within the frame: past its middle it reads as an advance.
            expectClose(Double(values[1_024]) * 1_024, Double(position <= 512 ? -position : 1_024 - position), .absolute(1e-3), "the linear-phase term, in samples")
            #expect(values[1_025] == (amplitude < 0 ? -1 : 1), "the sign of bin 0")
        }
    }

    @Test(arguments: ["speech", "music", "noise"])
    func theInverseReturnsTheSpectrum(name: String) throws {
        var samples = noise
        var format = mono48
        if name != "noise" {
            let fixture = try GoldenFile(named: "fixtures", in: .module).require(name)
            samples = try fixture.floats("samples")
            format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        }
        let stft = STFT(frame: 1_024, hop: 512)
        let original = try complexFrames(of: Pipeline { stft }, on: samples, format: format)
        let restored = try complexFrames(of: Pipeline { stft; Cepstrum(.complex); InverseCepstrum() }, on: samples, format: format)
        #expect(restored.frameCount == original.frameCount && restored.axis == original.axis && restored.times == original.times)
        var worst = 0.0, compared = 0
        for index in 0 ..< original.frameCount {
            let reals = original.reals[index].map(Double.init), imaginaries = original.imaginaries[index].map(Double.init)
            // A frame of silence has nothing above the floor to return.
            guard peakMagnitude(reals, imaginaries) > 1e-3 else { continue }
            worst = max(worst, complexDeviation(restored.reals[index], restored.imaginaries[index], reals, imaginaries))
            compared += 1
        }
        #expect(compared > 10 && worst <= 1e-5, "\(name): the round trip is off by \(worst) of the frame maximum at worst over \(compared) frames")
    }

    @Test func theRoundTripRunsThroughAnInverseSTFT() throws {
        let stft = STFT(frame: 1_024, hop: 256)
        let plain = try Pipeline { stft; stft.inverse }.process(noise, format: mono48)
        let through = try Pipeline { stft; Cepstrum(.complex); Lifter(.highTime(0)); InverseCepstrum(); stft.inverse }.process(noise, format: mono48)
        #expect(through.count == plain.count)
        #expect(signalToNoise(Array(through[2_048...]), Array(plain[2_048...])) > 90, "a lifter that keeps everything changes nothing")
    }

    @Test func onlyAComplexCepstrumCanBeInverted() {
        for kind in [CepstrumKind.real, .power] {
            let message = errorMessage { _ = try complexFrames(of: Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(kind); InverseCepstrum() }, on: noise) }
            #expect(message?.contains("has no phase to return") == true && message?.contains("InverseCepstrum") == true, "\(message ?? "no error")")
        }
    }

    // MARK: Lifter (WP-511)

    @Test func aLifterWindowsTheQuefrencies() throws {
        let stft = STFT(frame: 1_024, hop: 512)
        let cepstrum: [[Float]] = try Pipeline { stft; Cepstrum(.real) }.process(noise, format: mono48)
        let low: [[Float]] = try Pipeline { stft; Cepstrum(.real); Lifter(.lowTime(0.001)) }.process(noise, format: mono48)
        let high: [[Float]] = try Pipeline { stft; Cepstrum(.real); Lifter(.highTime(0.001)) }.process(noise, format: mono48)
        let sinusoidal: [[Float]] = try Pipeline { stft; Cepstrum(.real); Lifter(.sinusoidal(22)) }.process(noise, format: mono48)
        // 1 ms at 48 kHz: quefrencies 0 … 47 are below the cutoff.
        for index in cepstrum.indices {
            #expect(Array(low[index][..<48]) == Array(cepstrum[index][..<48]) && low[index][48...].allSatisfy { $0 == 0 })
            #expect(high[index][..<48].allSatisfy { $0 == 0 } && Array(high[index][48...]) == Array(cepstrum[index][48...]))
            #expect(zip(low[index], high[index]).map { $0 + $1 } == cepstrum[index], "the two parts add up to the cepstrum")
            expectClose(sinusoidal[index], cepstrum[index].enumerated().map { Double($1) * (1 + 11 * sin(.pi * Double($0) / 22)) }, .relativeToMaximum(1e-6))
        }
    }

    @Test func aLifterTreatsNegativeQuefrenciesAsPositiveAndLeavesTheTrailerAlone() throws {
        let stft = STFT(frame: 256, hop: 256)
        let cepstrum: [[Float]] = try Pipeline { stft; Cepstrum(.complex) }.process(noise, format: mono48)
        let low: [[Float]] = try Pipeline { stft; Cepstrum(.complex); Lifter(.lowTime(0.0005)) }.process(noise, format: mono48)
        // 0.5 ms at 48 kHz: |quefrency| below 24 samples, on either side.
        for index in cepstrum.indices {
            let kept = (0 ..< 256).map { Swift.min($0, 256 - $0) < 24 }
            #expect((0 ..< 256).allSatisfy { low[index][$0] == (kept[$0] ? cepstrum[index][$0] : 0) })
            #expect(Array(low[index][256...]) == Array(cepstrum[index][256...]), "the delay and the sign travel on")
        }
    }

    @Test func aLifterNeedsACepstrumAndSensibleValues() throws {
        let stft = STFT(frame: 256, hop: 256)
        for shape in [Lifter.Shape.lowTime(-1), .highTime(.nan), .sinusoidal(0)] {
            #expect(throws: DSPError.self) { let _: [[Float]] = try Pipeline { stft; Cepstrum(.real); Lifter(shape) }.process(noise, format: mono48) }
        }
        #expect(Pipeline { stft; Cepstrum(.real); Lifter(.lowTime(0.002)) } == Pipeline().appending(stft).cepstrum(.real).lifter(.lowTime(0.002)))
        #expect(Pipeline { stft; Cepstrum(.real); Lifter(.lowTime(0.002)) } != Pipeline { stft; Cepstrum(.real); Lifter(.highTime(0.002)) })
        // Switched off, the cepstrum passes unchanged: a lifter keeps the domain (ACT-3).
        let bypassed: [[Float]] = try Pipeline { stft; Cepstrum(.real); Lifter(.lowTime(0), isActive: false) }.process(noise, format: mono48)
        #expect(bypassed == (try Pipeline { stft; Cepstrum(.real) }.process(noise, format: mono48)))
    }

    // MARK: Pitch (WP-511)

    @Test(arguments: [110.0, 220, 329.63, 440])
    func thePitchOfAHarmonicFixtureIsWithinOnePerCent(fundamental: Double) throws {
        let fixture = TestSignal.harmonic(fundamental: fundamental, amplitudes: (1 ... 20).map { 1 / Double($0) }, sampleRate: 48_000, count: 16_384)
            .map { $0 * 0.3 }
        let pitches: [ScalarFrame] = try Pipeline { STFT(frame: 4_096, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(80 ... 600)) }
            .process(fixture, format: mono48)
        #expect(pitches.count == 25)
        #expect(pitches.allSatisfy { abs(Double($0.value) - fundamental) <= 0.01 * fundamental },
                "\(fundamental) Hz: \(pitches.map { $0.value }.min() ?? 0) … \(pitches.map { $0.value }.max() ?? 0)")
        #expect(pitches.allSatisfy { $0.confidence > 0.5 && $0.confidence <= 1 })
    }

    @Test func theConfidenceIsHigherOnAHarmonicFixtureThanOnWhiteNoise() throws {
        let harmonic = TestSignal.harmonic(fundamental: 196, amplitudes: (1 ... 24).map { 1 / Double($0) }, sampleRate: 48_000, count: 32_768).map { $0 * 0.3 }
        let pipeline = Pipeline { STFT(frame: 2_048, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(60 ... 500)) }
        let voiced: [ScalarFrame] = try pipeline.process(harmonic, format: mono48)
        let unvoiced: [ScalarFrame] = try pipeline.process(TestSignal.gaussianNoise(count: 32_768, seed: 511, standardDeviation: 0.2), format: mono48)
        let voicedMean = voiced.reduce(0) { $0 + Double($1.confidence) } / Double(voiced.count)
        let unvoicedMean = unvoiced.reduce(0) { $0 + Double($1.confidence) } / Double(unvoiced.count)
        #expect(voicedMean > unvoicedMean + 0.05, "mean confidence \(voicedMean) on the harmonic fixture, \(unvoicedMean) on noise")
        #expect((voiced + unvoiced).allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 && $0.value.isFinite })
    }

    @Test func aFrameWithoutAPeakHasNoPitch() throws {
        let pipeline = Pipeline { STFT(frame: 1_024, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(100 ... 400)) }
        let silent: [ScalarFrame] = try pipeline.process(TestSignal.silence(count: 4_096), format: mono48)
        #expect(silent.count == 7 && silent.allSatisfy { $0 == ScalarFrame(value: 0, confidence: 0) }, "0 before the first value, with confidence 0")
        // After a voiced stretch, silence repeats the last pitch with confidence 0.
        let voiced = TestSignal.harmonic(fundamental: 200, amplitudes: (1 ... 10).map { 1 / Double($0) }, sampleRate: 48_000, count: 8_192).map { $0 * 0.3 }
        let values: [ScalarFrame] = try pipeline.process(voiced + TestSignal.silence(count: 8_192), format: mono48)
        let lastHeard = try #require(values.last { $0.confidence > 0 })
        #expect(values.suffix(10).allSatisfy { $0 == ScalarFrame(value: lastHeard.value, confidence: 0) })
    }

    @Test func theFrameMustReachTheLongestPeriod() throws {
        func failure(_ range: FrequencyRange, frame: Int = 1_024) -> String? {
            errorMessage { let _: [ScalarFrame] = try Pipeline { STFT(frame: frame, hop: frame / 2); Cepstrum(.real); CepstralPitch(range: range) }.process(noise, format: mono48) }
        }
        let short = try #require(failure(.hertz(50 ... 400)), "a period of 960 samples in a cepstrum of 513 quefrencies")
        #expect(short.contains("a transform of 2048 points reaches it") && short.contains("CepstralPitch"), "\(short)")
        #expect(failure(.hertz(50 ... 400), frame: 2_048) == nil && failure(.hertz(50 ... 400), frame: 1_920) != nil && failure(.hertz(100 ... 400)) == nil)
        #expect(failure(.hertz(0 ... 400)) != nil && failure(.hertz(100 ... 30_000)) != nil)
        #expect(failure(FrequencyRange(from: .hertz(300), to: .hertz(200))) != nil)
        #expect(failure(.hertz(17_000 ... 23_000)) != nil, "no whole quefrency lies between 1 / 23 kHz and 1 / 17 kHz")
        #expect(failure(.hertz(23_000 ... 24_000)) == nil, "two samples is a period")
    }

    @Test func thePitchWorksOnAnyCepstrum() throws {
        let fixture = TestSignal.harmonic(fundamental: 220, amplitudes: (1 ... 20).map { 1 / Double($0) }, sampleRate: 48_000, count: 16_384).map { $0 * 0.3 }
        let stft = STFT(frame: 2_048, hop: 1_024)
        for pipeline in [Pipeline { stft; Cepstrum(.real); CepstralPitch(range: .hertz(100 ... 500)) },
                         Pipeline { stft; Cepstrum(.power); CepstralPitch(range: .hertz(100 ... 500)) },
                         Pipeline { stft; Cepstrum(.real); Lifter(.highTime(0.001)); CepstralPitch(range: .hertz(100 ... 500)) }] {
            let pitches: [ScalarFrame] = try pipeline.process(fixture, format: mono48)
            #expect(pitches.count == 15 && pitches.allSatisfy { abs($0.value - 220) < 2.2 }, "\(pitches.map { $0.value })")
        }
        // The positive quefrencies of a complex cepstrum are searched the same way; what its
        // phase adds there depends on the signal, so only the form of the result is asserted.
        let complex: [ScalarFrame] = try Pipeline { stft; Cepstrum(.complex); CepstralPitch(range: .hertz(100 ... 500)) }.process(fixture, format: mono48)
        #expect(complex.count == 15 && complex.allSatisfy { $0.value.isFinite && $0.value >= 100 && $0.value <= 500.5 && $0.confidence >= 0 && $0.confidence <= 1 })
    }

    // MARK: The measuring spelling (OUT-1)

    @Test func theMeasuringSpellingIsItsTapExpansion() {
        let box = StateBox(Float(0))
        let stft = STFT(frame: 2_048, hop: 512)
        #expect(Pipeline { stft; Cepstrum(.real); CepstralPitch(range: .hertz(60 ... 400), to: box.binding) }
            == Pipeline { stft; Cepstrum(.real); Tap { CepstralPitch(range: .hertz(60 ... 400)); Emit(to: box.binding) } })
        #expect(Pipeline().appending(stft).cepstrum().cepstralPitch(range: .hertz(60 ... 400), to: box.binding)
            == Pipeline { stft; Cepstrum(); CepstralPitch(range: .hertz(60 ... 400), to: box.binding) })
        #expect(Pipeline().appending(stft).cepstrum(.power, floor: 1e-8).cepstralPitch() == Pipeline { stft; Cepstrum(.power, floor: 1e-8); CepstralPitch() })
        #expect(Pipeline { stft; Cepstrum(); CepstralPitch(to: box.binding, isActive: false) } == Pipeline { stft; Cepstrum(); Tap(isActive: false) { CepstralPitch(); Emit(to: box.binding) } })
        #expect(CepstralPitch<Quefrency>.stageName == "CepstralPitch" && Cepstrum.stageName == "Cepstrum" && Lifter.stageName == "Lifter")
        #expect(throws: DSPError.self) { var context = try lowering(); try CepstralPitch(to: box.binding).lower(&context) }
    }

    @Test @MainActor func aMeasuringPitchPassesTheCepstrumOnAndWritesItsBinding() throws {
        let pitch = StateBox(ScalarFrame.none), feed = HeatmapFeed(history: 64), plain = HeatmapFeed(history: 64)
        let fixture = TestSignal.harmonic(fundamental: 220, amplitudes: (1 ... 20).map { 1 / Double($0) }, sampleRate: 48_000, count: 16_384).map { $0 * 0.3 }
        try Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(100 ... 500), to: pitch.binding); Emit(to: feed) }
            Tap { STFT(frame: 2_048, hop: 512); Cepstrum(.real); Emit(to: plain) }
        }.run(on: fixture, format: mono48)
        #expect(abs(pitch.value.value - 220) < 2.2 && pitch.value.confidence > 0.5 && pitch.writes == 1)
        #expect(feed.snapshot().values == plain.snapshot().values && feed.axis == .quefrency(count: 1_025, sampleRate: 48_000))
    }

    // MARK: Order (O-10), both tiers

    @Test func theRulesOfTheDescriptions() throws {
        let cepstrum = try #require(Cepstrum().stageDescriptions.first), inverse = try #require(InverseCepstrum().stageDescriptions.first)
        let lifter = try #require(Lifter(.lowTime(0.001)).stageDescriptions.first), pitch = try #require(CepstralPitch().stageDescriptions.first)
        let complex = DomainTag.spectrum(axis: .linear, values: .complex)
        #expect(cepstrum.rule(complex) == .quefrency && inverse.rule(.quefrency) == complex && lifter.rule(.quefrency) == .quefrency && pitch.rule(.quefrency) == .scalar)
        for tag in [DomainTag.samples, .scalar, .melCepstrum, .spectrum(axis: .linear, values: .magnitude), .spectrum(axis: .mel, values: .complex)] {
            #expect(cepstrum.rule(tag) == nil && inverse.rule(tag) == nil && lifter.rule(tag) == nil && pitch.rule(tag) == nil, "\(tag)")
        }
        #expect(cepstrum.rule(.quefrency) == nil && lifter.rule(complex) == nil)
        let spectrum = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 512))
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Lifter(.lowTime(0.001))) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Magnitude().stageDescription).appending(Cepstrum()) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(CepstralPitch()) }
        #expect(try spectrum.appending(Cepstrum()).appending(Lifter(.lowTime(0.001))).appending(CepstralPitch()).outputTag == .scalar)
        #expect(try spectrum.appending(Cepstrum(.complex)).appending(InverseCepstrum()).appending(InverseSTFT()).outputTag == .samples)
        #expect(try spectrum.appending(Cepstrum()).appending(CepstralPitch(to: StateBox(Float(0)).binding)).outputTag == .quefrency)
    }

    @Test func switchedOffTheyBypassOrSuspend() throws {
        let dark = CollectingSink<Quefrency>(), spectrum = CollectingSink<ComplexSpectrum>(), pitch = CollectingSink<Scalar>()
        try Pipeline {
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(isActive: false); Emit(to: dark) }
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(.complex); InverseCepstrum(isActive: false); Emit(to: spectrum) }
            Tap { STFT(frame: 2_048, hop: 512); Cepstrum(); CepstralPitch(isActive: false); Emit(to: pitch) }
        }.run(on: noise, format: mono48)
        #expect(dark.frameCount == 0 && spectrum.frameCount == 0 && pitch.frameCount == 0, "a step that changes the domain suspends what follows it (ACT-3)")
        // A lifter keeps the domain: switched off, the cepstrum passes it unchanged.
        let plain = CollectingSink<Quefrency>(), bypassed = CollectingSink<Quefrency>(), liftered = CollectingSink<Quefrency>()
        try Pipeline {
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(); Emit(to: plain) }
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(); Lifter(.lowTime(0.002), isActive: false); Emit(to: bypassed) }
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(); Lifter(.lowTime(0.002)); Emit(to: liftered) }
        }.run(on: noise, format: mono48)
        #expect(plain.frameCount > 10 && bypassed.reals == plain.reals && liftered.reals != plain.reals && liftered.frameCount == plain.frameCount)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodesRunWithoutAllocating() throws {
        let real = CountingSink<Quefrency>(), power = CountingSink<Quefrency>(), restored = CountingSink<ComplexSpectrum>(), pitch = CountingSink<Scalar>()
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Cepstrum(.real); Lifter(.lowTime(0.002)); Emit(to: real); CepstralPitch(range: .hertz(60 ... 400)); Emit(to: pitch) }
            Tap { STFT(frame: 1_024, hop: 512, paddedTo: 1_920); Cepstrum(.power); Lifter(.sinusoidal(22)); Emit(to: power) }
            Tap { STFT(frame: 1_024, hop: 512); Cepstrum(.complex); Lifter(.highTime(0.0001)); InverseCepstrum(); Emit(to: restored) }
        })
        #expect(real.frames > 990 && power.frames > 990 && restored.frames > 990 && pitch.frames == real.frames)
    }
}
