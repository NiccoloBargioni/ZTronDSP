import Foundation
import Testing
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-432b. `BandBoost`, `LowShelf`, `HighShelf` stages. Acceptance: as WP-432a: the running
/// pipeline's measured response is within 0.1 dB of the analysis.
@Suite("Equaliser stages (WP-432b)")
struct EqualizerStageTests {
    let format = SignalFormat(sampleRate: 48_000)

    @Test func theMeasuredResponseOfTheRunningPipelineIsTheAnalysis() throws {
        var compared = 0
        func check(_ name: String, _ pipeline: Pipeline<Samples, Samples>, _ system: ZeroPoleGain) throws {
            let analysed = try system.magnitudeResponse(at: angular(comparisonFrequencies), in: .decibels(floor: -400))
            // The pipeline as it runs, and in double precision: within 0.1 dB of the analysis.
            for precision in [BiquadPrecision.automatic, .double] {
                let measured = try measuredResponse(of: pipeline.environment(\.biquadPrecision, precision), at: comparisonFrequencies)
                let worst = expectResponse(measured, matches: analysed, "\(name), \(precision)")
                Measurements.shared.record("WP-432b measured response of the running pipeline against the analysis, dB", worst, bound: 0.1)
                compared += 1
            }
            // Forced into single precision the filter is held to the analysis where the
            // measurement of REAL-3 recommends single precision; elsewhere the figure is what
            // that measurement is for, and is recorded.
            let single = try measuredResponse(of: pipeline.environment(\.biquadPrecision, .single), at: comparisonFrequencies)
            if try system.secondOrderSections().recommendedPrecision() == .single {
                let worst = expectResponse(single, matches: analysed, "\(name), single precision, as recommended")
                Measurements.shared.record("WP-432b measured response of the running pipeline against the analysis, dB", worst, bound: 0.1)
            } else {
                var worst = 0.0
                for (actual, expected) in zip(single, analysed) where expected >= -60 { worst = max(worst, abs(actual - expected)) }
                Measurements.shared.record("WP-432b forced single precision where double is recommended: response against the analysis, dB (not held)", worst, bound: .infinity)
            }
            compared += 1
        }
        for order in 1 ... 8 {
            for gain in [-24.0, -6, 1, 12] {
                for (center, bandwidth) in [(300.0, Bandwidth.octaves(1)), (2_800, .hertz(700)), (9_000, .q(2))] {
                    let stage = BandBoost(center: .hertz(center), gain: .decibels(gain), bandwidth: bandwidth, order: order)
                    try check("band-boost of order \(order), \(gain) dB at \(center) Hz", Pipeline { stage }, try stage.design(sampleRate: 48_000).zeroPoleGain)
                }
            }
        }
        for gain in [-12.0, 3, 9] {
            for slope in [ShelfSlope.slope(1), .slope(0.5), .q(0.9)] {
                let low = LowShelf(midpoint: .hertz(200), gain: .decibels(gain), slope: slope)
                try check("low shelf, \(gain) dB, \(slope)", Pipeline { low }, try low.design(sampleRate: 48_000).zeroPoleGain)
                let high = HighShelf(midpoint: .hertz(6_000), gain: .decibels(gain), slope: slope)
                try check("high shelf, \(gain) dB, \(slope)", Pipeline { high }, try high.design(sampleRate: 48_000).zeroPoleGain)
            }
            let matched = MatchedPeak(center: .hertz(15_000), gain: .decibels(gain), bandwidth: .octaves(0.5))
            try check("matched peak, \(gain) dB", Pipeline { matched }, try matched.design(sampleRate: 48_000).zeroPoleGain)
        }
        #expect(compared == (8 * 4 * 3 + 3 * 3 * 2 + 3) * 3)
    }

    @Test func aBoostAndItsCutInSeriesAreTheIdentity() throws {
        // Property 6 of §6.3.5, on the running pipeline: the two fuse into one cascade and undo one another.
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 21, amplitude: 0.5)
        for order in [1, 4, 8] {
            let pipeline = Pipeline {
                BandBoost(center: .hertz(1_000), gain: .decibels(12), bandwidth: .octaves(1), order: order)
                BandBoost(center: .hertz(1_000), gain: .decibels(-12), bandwidth: .octaves(1), order: order)
            }.environment(\.biquadPrecision, .double)
            #expect(try loweredKernels(pipeline).count == 1)
            expectClose(try pipeline.process(noise, format: format), noise, .deviationBelow(decibels: -110), "order \(order)")
        }
    }

    @Test func theStagesEmitTheirDesignAndFollowTheRules() throws {
        // One biquad for the peak and for each shelf, N for order N; no latency.
        func sections(_ pipeline: Pipeline<Samples, Samples>) throws -> Int {
            guard case .biquad(let sections, _)? = try loweredKernels(pipeline).first else { return -1 }
            return sections.count
        }
        #expect(try sections(Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1)) }) == 1)
        #expect(try sections(Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), rollOff: .decibelsPerOctave(36)) }) == 6)
        #expect(try sections(Pipeline { LowShelf(midpoint: .hertz(200), gain: .decibels(3)) }) == 1)
        #expect(try sections(Pipeline { HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3)) }) == 1)
        #expect(try sections(Pipeline { MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .q(2)) }) == 1)
        let latency = try outputEnvironment(Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 4); LowShelf(midpoint: .hertz(200), gain: .decibels(3)) }).latency
        #expect(latency == 0)
        // O-16, with the stage's path; a switched-off stage is compiled away and still validated.
        func rejected(_ pipeline: Pipeline<Samples, Samples>) -> DSPError? {
            thrownError { _ = try pipeline.process(TestSignal.silence(count: 64), format: format) }
        }
        let behind = rejected(Pipeline { Decimate(by: 8); BandBoost(center: .hertz(4_000), gain: .decibels(4), bandwidth: .q(2)) })
        #expect(behind?.invalidParameterName == "center" && behind?.stage?.description == "BandBoost[1]")
        #expect(rejected(Pipeline { LowShelf(midpoint: .hertz(24_000), gain: .decibels(3)) })?.invalidParameterName == "midpoint")
        #expect(rejected(Pipeline { HighShelf(midpoint: .hertz(0), gain: .decibels(3), isActive: false) })?.invalidParameterName == "midpoint")
        #expect(rejected(Pipeline { MatchedPeak(center: .hertz(30_000), gain: .decibels(3), bandwidth: .q(2)) })?.invalidParameterName == "center")
        #expect(try loweredKernels(Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), isActive: false) }).isEmpty)
        // A gain of 0 dB is a filter that does nothing, and still a filter of that many sections:
        // the topology does not change when a gain passes through zero.
        #expect(try sections(Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(0), bandwidth: .octaves(1), order: 3) }) == 3)
        // On a scalar track the frequencies are the track's.
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 480) }.bandBoost(center: .hertz(10), gain: .decibels(6), bandwidth: .q(1)).lowShelf(midpoint: .hertz(5), gain: .decibels(-3))
            .highShelf(midpoint: .hertz(30), gain: .decibels(3)).matchedPeak(center: .hertz(20), gain: .decibels(2), bandwidth: .q(2)).emit(to: track)
            .run(on: TestSignal.whiteNoise(count: 48_000, seed: 2), format: format)
        #expect(track.scalars.count == 100 && track.scalars.allSatisfy { $0.value.isFinite })
    }

    @Test func aGainAnimatedThroughZeroKeepsThePlanAndMakesNoClick() async throws {
        let rig = StageRig(blockSize: 64)
        func pipeline(_ gain: Double) -> Pipeline<Samples, Samples> {
            Pipeline { BandBoost(center: .hertz(1_000), gain: .decibels(gain), bandwidth: .octaves(1), order: 2) }.environment(\.biquadPrecision, .double)
        }
        let (session, probe) = try await rig.run(pipeline(-12))
        let sine = Click.probeSignal(count: 480 * 60)
        rig.feed(Array(sine[..<(480 * 10)]))
        let plan = session.core.plan
        for step in 1 ... 40 {
            try await session.update(pipeline(-12 + 24 * Double(step) / 40))
            rig.feed(Array(sine[(480 * (9 + step)) ..< (480 * (10 + step))]))
        }
        rig.feed(Array(sine[(480 * 50)...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "forty value updates, a cut that becomes a boost, and no new plan")
        // The steps of the output grow with the gain: the largest step during the change is held
        // to the steady state after it.
        let click = Click.measure(probe.samples, change: (480 * 10) ..< (480 * 51), settle: 480)
        #expect(click.passes, "CLICK-1 over the sweep: \(click)")
        let settled = try pipeline(12).process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(480 * 56)...]), Array(settled[(480 * 56)...]), .deviationBelow(decibels: -80))
        session.detach()
    }

    @Test func aThousandBlocksOfEachEqualiserAllocateNothing() async throws {
        let noise = TestSignal.whiteNoise(count: 512, seed: 78)
        let on = StateBox(true)
        let rig = StageRig(blockSize: 512)
        let session = try await rig.start(Pipeline {
            BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 4)
            LowShelf(midpoint: .hertz(200), gain: .decibels(3), isActive: on.binding)
            HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3))
            MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .q(2))
        })
        rig.feed(noise)
        await rig.drain()
        try rig.auditAllocations(blocks: 1_000, of: noise, "1 000 blocks through a band-boost, two shelves and a matched peak")
        session.detach()
    }
}

/// WP-432c. `Filter(_:)` for an `IIRSystem` or an `FIRSystem`; the FIR response stages; FIR
/// lowering (REAL-4) and latency. Acceptance: measured response within 0.1 dB; the direct and
/// partitioned paths agree within −100 dB; latency reported.
@Suite("Filter and the FIR response stages (WP-432c)")
struct FilterStageTests {
    let format = SignalFormat(sampleRate: 48_000)
    let rate = 48_000.0

    private var hum: IIRSystem {
        IIRSystem {
            Zero(onUnitCircleAt: .hertz(50))
            Pole(radius: 0.985, frequency: .hertz(50))
            HighPass(.butterworth, cutoff: .hertz(30), rollOff: .decibelsPerOctave(12))
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
        }
    }

    @Test func theMeasuredResponseOfAnIIRSystemIsItsAnalysis() async throws {
        // The system of §6.3.7 and three more: the response of the running pipeline against the
        // report of the analysis.
        let systems: [(String, IIRSystem)] = [
            ("the hum filter of the specification", hum),
            ("a notch", IIRSystem { Zero(onUnitCircleAt: .hertz(1_000)); Pole(radius: 0.95, frequency: .hertz(1_000)) }),
            ("three equalisers and a low-pass", IIRSystem {
                BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 3)
                LowShelf(midpoint: .hertz(200), gain: .decibels(3))
                HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3))
                LowPass(.elliptic(ripple: .decibels(0.5), stopband: .decibels(50)), cutoff: .hertz(15_000), order: 5)
            }),
            ("a difference equation and a delay", IIRSystem { DifferenceEquation(b: [0.2, 0.3, 0.2], a: [1, -0.4, 0.25]); Section(b: [0, 1]) }),
        ]
        for (name, system) in systems {
            let report = try await system.analysis(sampleRate: rate)
            let analysed = try report.magnitudeResponse(at: comparisonFrequencies.map { .hertz($0) }, in: .decibels(floor: -400))
            // The pipeline as it runs, and in double precision; in single precision where the
            // analysis recommends it (REAL-3). The impulse response is taken long: a high-pass at
            // 30 Hz rings for a while.
            var precisions = [BiquadPrecision.automatic, .double]
            if report.recommendedPrecision == .single { precisions.append(.single) }
            for precision in precisions {
                let measured = try measuredResponse(of: Pipeline { Filter(system) }.environment(\.biquadPrecision, precision), at: comparisonFrequencies, count: 131_072)
                let worst = expectResponse(measured, matches: analysed, "\(name), \(precision)")
                Measurements.shared.record("WP-432c measured response of Filter(IIRSystem) against the analysis, dB", worst, bound: 0.1)
            }
            // What the analysis says the system runs as is what the stage emits.
            guard case .biquad(let sections, let chosen)? = try loweredKernels(Pipeline { Filter(system) }).first else { Issue.record("\(name): a cascade was due"); continue }
            #expect(sections == report.sections?.biquadSections, "\(name)")
            #expect(chosen == report.recommendedPrecision, "\(name): the precision the plan chose is the one the analysis recommends")
        }
    }

    @Test func theMeasuredResponseOfAnFIRFilterIsItsAnalysis() async throws {
        let stages: [(String, Pipeline<Samples, Samples>, FIRSystem)] = [
            ("a Kaiser low-pass by length", Pipeline { LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255) },
             FIRSystem { LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255) }),
            ("a low-pass by roll-off", Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80)) },
             FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80)) }),
            ("a least-squares band-pass", Pipeline { BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401) },
             FIRSystem { BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401) }),
            ("a high-pass by scheme", Pipeline { HighPass(.windowedSinc(), passband: .hertz(5_000), stopband: .hertz(4_000), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(70)) },
             FIRSystem { HighPass(.windowedSinc(), passband: .hertz(5_000), stopband: .hertz(4_000), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(70)) }),
            ("a band-stop above the crossover", Pipeline { BandStop(.windowedSinc(window: .blackmanHarris), from: .hertz(3_000), to: .hertz(9_000), length: 1_025) },
             FIRSystem { BandStop(.windowedSinc(window: .blackmanHarris), from: .hertz(3_000), to: .hertz(9_000), length: 1_025) }),
            ("the system of the specification", Pipeline { Filter(FIRSystem {
                LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
                Taps([0.25, 0.5, 0.25])
            }) }, FIRSystem {
                LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
                Taps([0.25, 0.5, 0.25])
            }),
        ]
        for (name, pipeline, system) in stages {
            let taps = try system.taps(sampleRate: rate)
            // The analysis: the transform of the taps (§6.3.8).
            let analysed = comparisonFrequencies.map { DSP.decibels(fromAmplitude: TapMeasure.response(taps, at: $0, sampleRate: rate).magnitude, floor: -400) }
            let measured = try measuredResponse(of: pipeline, at: comparisonFrequencies)
            // Float32 taps hold a stop band to about −140 dB; the comparison stops at −100 dB.
            let worst = expectResponse(measured, matches: analysed, above: -100, name)
            Measurements.shared.record("WP-432c measured response of an FIR stage against the analysis, dB", worst, bound: 0.1)
            // The stage emits the design's taps, in single precision, with the latency of a linear-phase filter.
            guard case .fir(let emitted, let latency)? = try loweredKernels(pipeline).first else { Issue.record("\(name): an FIR kernel was due"); continue }
            #expect(emitted == taps.map { Float($0) } && latency == (taps.count - 1) / 2, "\(name)")
        }
    }

    @Test func theDirectAndThePartitionedPathAgree() throws {
        // REAL-4: direct below the crossover of the engine's table (256 taps), partitioned from it on.
        let noise = TestSignal.whiteNoise(count: 16_384, seed: 432)
        for length in [255, 257, 1_025, 2_001] {
            let stage = Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: length) }
            let direct = try stage.environment(\.implementation, .native).process(noise, format: format)
            let partitioned = try stage.environment(\.implementation, .accelerate).process(noise, format: format)
            let automatic = try stage.process(noise, format: format)
            let deviation = deviationInDecibels(partitioned, direct)
            Measurements.shared.record("WP-432c partitioned against direct FIR path, dB", deviation, bound: -100)
            #expect(deviation <= -100, "\(length) taps: \(deviation) dB")
            #expect(direct != partitioned, "\(length) taps: the two paths round differently, so both ran")
            #expect(automatic == (length < 256 ? direct : partitioned), "\(length) taps: the plan chose by the length")
            // And both are the convolution with the taps the stage emits.
            if length < 300 {
                let taps = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), length: length, sampleRate: rate).taps.map { Double(Float($0)) }
                expectClose(direct, TapMeasure.convolved(noise, taps), .deviationBelow(decibels: -110), "\(length) taps, direct")
            }
        }
    }

    @Test func theLatencyOfALinearPhaseFilterIsReported() async throws {
        // REAL-5: (K − 1) / 2 samples, in the environment downstream and in the session's.
        let pipeline = Pipeline {
            LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 255)                          // 127
            Filter(FIRSystem { Taps([0.25, 0.5, 0.25]) })                                         // 1
            HighPass(.butterworth, cutoff: .hertz(90), order: 4)                                  // 0
            Filter(FIRSystem { Taps([1, 0.5, 0.2]) })                                             // not linear-phase: 0
            Filter(FIRSystem { Taps([0, 0, 1]) })                                                 // a delay of 2
        }
        let sink = Collector<Samples>()
        try pipeline.emit(to: sink).run(on: TestSignal.silence(count: 512), format: format)
        expectClose(try #require(sink.environment?.latency), 130.0 / 48_000, .absolute(1e-15))
        let rig = StageRig()
        let session = try await rig.engine.attach(pipeline, to: rig.source)
        expectClose(session.environment.latency, 130.0 / 48_000, .absolute(1e-15))
        session.detach()
        // The output is the input, filtered, that many samples late: an impulse through the
        // first stage peaks at its latency.
        let impulse = try Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 255) }.process(TestSignal.impulse(count: 512), format: format)
        #expect(impulse.firstIndex(of: impulse.max() ?? 0) == 127)
        // An even length has a delay of half a sample more than its latency says: K = 100 reports 49.
        let even = try outputEnvironment(Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 100) }).latency
        #expect(even == 49.0 / 48_000)
    }

    @Test func offlineOutputEqualsTheConvolutionWithTheDesign() throws {
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 12)
        let design = try FIRDesign(.leastSquares, .bandPass(from: 300, to: 3_400), length: 101, transition: 200, sampleRate: rate)
        let reference = TapMeasure.convolved(noise, design.taps.map { Double(Float($0)) })
        let stage = Pipeline { BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 101) }
        for blockSize in [1, 64, 100, 512] {
            expectClose(try stage.process(noise, format: format, blockSize: blockSize), reference, .deviationBelow(decibels: -120), "blocks of \(blockSize)")
        }
        // Stereo: each channel has its own history.
        let stereo = try stage.process(channels: [noise, noise.reversed()], format: SignalFormat(sampleRate: rate, channelCount: 2))
        expectClose(stereo[1], TapMeasure.convolved(noise.reversed(), design.taps.map { Double(Float($0)) }), .deviationBelow(decibels: -120))
        // Adjacent FIR stages are convolved into one kernel below the crossover (F3).
        let fused = Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(8_000), length: 63); Filter(FIRSystem { Taps([0.25, 0.5, 0.25]) }) }
        let kernels = try loweredKernels(fused)
        guard kernels.count == 1, case .fir(let taps, let latency) = kernels[0] else { Issue.record("one kernel was due (F3), not \(kernels)"); return }
        #expect(taps.count == 65 && latency == 32)
    }

    @Test func whatMakesNoFilterIsRejectedWhenThePlanIsCompiled() throws {
        func rejected(_ pipeline: Pipeline<Samples, Samples>) -> DSPError? {
            thrownError { _ = try pipeline.process(TestSignal.silence(count: 64), format: format) }
        }
        // O-17: an FIR slope that would put the stop-band edge past Nyquist, naming the smallest that fits.
        let slope = rejected(Pipeline { Gain(.decibels(-3)); LowPass(.windowedSinc(), cutoff: .hertz(10_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(80)) })
        #expect(slope?.invalidParameterName == "rollOff" && slope?.stage?.description == "LowPass[1]")
        #expect(slope?.invalidParameterReason?.contains(String(format: "%.2f", 80 / log2(2.4))) == true)
        // The same filter fits where the rate is higher (ENV-1).
        #expect(try Pipeline { Interpolate(by: 2); LowPass(.windowedSinc(), cutoff: .hertz(10_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(80)) }
            .process(TestSignal.silence(count: 64), format: format).count == 128)
        #expect(rejected(Pipeline { HighPass(.windowedSinc(), cutoff: .hertz(4_000), length: 100) })?.invalidParameterName == "length")
        #expect(rejected(Pipeline { LowPass(.leastSquares, cutoff: .hertz(4_000), length: 101) })?.invalidParameterName == "transition")
        #expect(rejected(Pipeline { BandPass(.windowedSinc(), from: .hertz(300), to: .hertz(30_000), length: 101) })?.invalidParameterName == "to")
        #expect(rejected(Pipeline { LowPass(.windowedSinc(window: .hann), passband: .hertz(4_000), stopband: .hertz(5_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(80)) })?.invalidParameterName == "minimumAttenuation")
        // The stop band of an FIR scheme may end at the Nyquist frequency or start at 0 Hz.
        #expect(rejected(Pipeline { LowPass(.windowedSinc(), passband: .hertz(4_000), stopband: .hertz(24_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) }) == nil)
        #expect(rejected(Pipeline { HighPass(.windowedSinc(), passband: .hertz(4_000), stopband: .hertz(0), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) }) == nil)
        // A system is resolved against the rate at its position: 50 Hz is beyond the Nyquist frequency of a 60 Hz track.
        let track = thrownError { try Pipeline { MeanTrack(hop: 800) }.filter(hum).run(on: TestSignal.silence(count: 4_800), format: format) }
        #expect(track?.invalidParameterName == "frequency" && track?.stage?.description == "Filter[1]")
        // A system without elements is no stage at all; an identity filter is removed (F4).
        #expect(try loweredKernels(Pipeline { Filter(IIRSystem {}); Filter(FIRSystem {}) }).isEmpty)
        // A pure gain is one section.
        let gain = try Pipeline { Filter(IIRSystem { Section(b: [0.5]) }) }.process([1, 2, -4], format: format)
        #expect(gain == [0.5, 1, -2])
    }

    @Test func aTapChangeAtOneLengthKeepsThePlanAndIsCrossFaded() async throws {
        // §5.5.4: FIR taps of equal length are cross-faded over 10 ms; the topology does not change.
        let rig = StageRig(blockSize: 64)
        func pipeline(_ cutoff: Double) -> Pipeline<Samples, Samples> {
            Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(cutoff), length: 127) }
        }
        let (session, probe) = try await rig.run(pipeline(2_000))
        let sine = Click.probeSignal(count: 480 * 60)
        rig.feed(Array(sine[..<(480 * 10)]))
        let plan = session.core.plan
        for step in 1 ... 20 {
            try await session.update(pipeline(2_000 * pow(0.25, Double(step) / 20)))
            rig.feed(Array(sine[(480 * (9 + step)) ..< (480 * (10 + step))]))
        }
        rig.feed(Array(sine[(480 * 30)...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "twenty value updates and no new plan")
        let click = Click.measure(probe.samples, change: (480 * 10) ..< (480 * 32), settle: 480)
        #expect(click.passes, "CLICK-1 over the sweep: \(click)")
        let settled = try pipeline(500).process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(480 * 40)...]), Array(settled[(480 * 40)...]), .deviationBelow(decibels: -100))
        // Another length is another topology: a new plan.
        try await session.update(Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(500), length: 129) })
        rig.feed(Array(sine[..<4_800]))
        #expect(session.core.generation == 2)
        session.detach()
    }

    @Test func aSwitchedFilterWithLatencyKeepsTheSignalAligned() async throws {
        // ACT-7, ACT-8: bypassed, the signal passes delayed by the stage's latency.
        let rig = StageRig(blockSize: 64)
        let on = StateBox(true)
        let system = FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 63) }
        let (session, probe) = try await rig.run(Pipeline { Filter(system, isActive: on.binding) })
        #expect(session.environment.latency == 31.0 / 48_000)
        let sine = Click.probeSignal(count: 64 * 120)
        rig.feed(Array(sine[..<(64 * 40)]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 40) ..< (64 * 80)]))
        #expect(session.environment.latency == 31.0 / 48_000, "switching never changes the session's latency")
        #expect(Array(probe.samples[(64 * 60) ..< (64 * 80)]) == Array(sine[(64 * 60 - 31) ..< (64 * 80 - 31)]))
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 80)...]))
        let filtered = try Pipeline { Filter(system) }.process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(64 * 100)...]), Array(filtered[(64 * 100)...]), .deviationBelow(decibels: -100))
        let off = Click.measure(probe.samples, change: (64 * 40) ..< (64 * 50), settle: 64)
        let back = Click.measure(probe.samples, change: (64 * 80) ..< (64 * 92), settle: 64)
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
        session.detach()
    }

    @Test func aThousandBlocksOfEachFilterAllocateNothing() async throws {
        let noise = TestSignal.whiteNoise(count: 512, seed: 79)
        let on = StateBox(true)
        let pipelines: [(String, Pipeline<Samples, Samples>)] = [
            ("an IIR system", Pipeline { Filter(hum) }),
            ("a direct FIR filter", Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 255) }),
            ("a partitioned FIR filter", Pipeline { HighPass(.windowedSinc(), cutoff: .hertz(4_000), length: 2_001) }),
            ("a bound FIR system with latency", Pipeline { Filter(FIRSystem { BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 101) }, isActive: on.binding) }),
        ]
        for (name, pipeline) in pipelines {
            let rig = StageRig(blockSize: 512)
            let session = try await rig.start(pipeline)
            rig.feed(noise)
            await rig.drain()
            try rig.auditAllocations(blocks: 1_000, of: noise, "1 000 blocks through \(name)")
            session.detach()
        }
    }
}
