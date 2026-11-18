import Foundation
import Testing
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// The response of a running pipeline, measured: the pipeline is given an impulse, and the
/// transform of what comes out is taken at each frequency. In decibels.
func measuredResponse(
    of pipeline: Pipeline<Samples, Samples>, at frequencies: [Double], sampleRate: Double = 48_000, count: Int = 32_768, blockSize: Int = 512
) throws -> [Double] {
    let output = try pipeline.process(TestSignal.impulse(count: count), format: SignalFormat(sampleRate: sampleRate), blockSize: blockSize)
    // One transform of the whole impulse response; the frequencies are bins of it.
    let magnitudes = TapMeasure.magnitudes(output.map(Double.init), oversampling: 1)
    let bins = Double(2 * (magnitudes.count - 1))
    return frequencies.map { DSP.decibels(fromAmplitude: magnitudes[Int(($0 / sampleRate * bins).rounded())], floor: -400) }
}

/// The frequencies a response is compared at: sixty bins of a 32 768-point transform at
/// 48 kHz, evenly spaced in pitch, from 40 Hz to 22 kHz.
let comparisonFrequencies: [Double] = (0 ..< 60).map { index -> Double in
    let wanted = 40 * pow(22_000.0 / 40, Double(index) / 59)
    return (wanted / 48_000 * 32_768).rounded() * 48_000 / 32_768
}

func angular(_ frequencies: [Double], sampleRate: Double = 48_000) -> [Double] {
    frequencies.map { 2 * Double.pi * $0 / sampleRate }
}

/// Holds a measured response to an analysed one wherever the analysis is above `floor`
/// decibels, and returns the worst difference in decibels.
@discardableResult
func expectResponse(
    _ measured: [Double], matches analysed: [Double], within tolerance: Double = 0.1, above floor: Double = -60,
    _ comment: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation
) -> Double {
    var worst = 0.0
    var compared = 0
    for (actual, expected) in zip(measured, analysed) where expected >= floor {
        worst = max(worst, abs(actual - expected))
        compared += 1
    }
    if !(worst <= tolerance) || compared < 4 {
        Issue.record("\(comment()): the measured response is \(worst) dB from the analysis over \(compared) frequencies; the bound is \(tolerance) dB",
                     sourceLocation: sourceLocation)
    }
    return worst
}

/// WP-432a. IIR filter stages: `LowPass` … `BandStop` as sequence stages, lowered to the
/// cascade. Acceptance: the running pipeline's measured response is within 0.1 dB of the
/// analysis.
@Suite("IIR filter stages (WP-432a)")
struct IIRFilterStageTests {
    let format = SignalFormat(sampleRate: 48_000)

    private func families() -> [(name: String, family: any FilterFamily)] {
        [("butterworth", ButterworthFamily()), ("chebyshev1", Chebyshev1Family(ripple: .decibels(1))),
         ("chebyshev2", Chebyshev2Family(stopband: .decibels(60))), ("elliptic", EllipticFamily(ripple: .decibels(1), stopband: .decibels(60))),
         ("bessel", BesselFamily())]
    }

    private func stages(_ family: some FilterFamily, order: Int) -> [(name: String, pipeline: Pipeline<Samples, Samples>, response: FilterResponse)] {
        [("low-pass", Pipeline { LowPass(family, cutoff: .hertz(3_000), order: order) }, .lowPass(cutoff: 3_000)),
         ("high-pass", Pipeline { HighPass(family, cutoff: .hertz(3_000), order: order) }, .highPass(cutoff: 3_000)),
         ("band-pass", Pipeline { BandPass(family, from: .hertz(2_000), to: .hertz(5_000), order: order) }, .bandPass(from: 2_000, to: 5_000)),
         ("band-stop", Pipeline { BandStop(family, from: .hertz(2_000), to: .hertz(5_000), order: order) }, .bandStop(from: 2_000, to: 5_000))]
    }

    @Test func theMeasuredResponseOfTheRunningPipelineIsTheAnalysis() throws {
        var compared = 0
        for (name, family) in families() {
            for order in [1, 2, 5, 8] {
                func check(_ family: some FilterFamily) throws {
                    for stage in stages(family, order: order) {
                        let design = try IIRDesign(family, stage.response, order: order, domain: .digital(sampleRate: 48_000))
                        // The analysis: the response of the design, from its zeros and poles.
                        let analysed = try design.zeroPoleGain.magnitudeResponse(at: angular(comparisonFrequencies), in: .decibels(floor: -400))
                        for precision in [BiquadPrecision.automatic, .single, .double] {
                            let measured = try measuredResponse(of: stage.pipeline.environment(\.biquadPrecision, precision), at: comparisonFrequencies)
                            let worst = expectResponse(measured, matches: analysed, "\(name) \(stage.name), order \(order), \(precision)")
                            Measurements.shared.record("WP-432a measured response of the running pipeline against the analysis, dB", worst, bound: 0.1)
                            compared += 1
                        }
                    }
                }
                try check(family)
            }
        }
        #expect(compared == 5 * 4 * 4 * 3)
    }

    @Test func aLiveSessionMeasuresAsTheAnalysisPredictsOnSines() async throws {
        // The exit criterion of M4: a designed filter running in a pipeline measures as its
        // analysis predicts. Here on a session, block by block, with sines.
        let rig = StageRig(blockSize: 64)
        let pipeline = Pipeline { BandPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), from: .hertz(2_000), to: .hertz(5_000), order: 4) }
        let design = try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 4, domain: .digital(sampleRate: 48_000))
        let (session, probe) = try await rig.run(pipeline)
        var fed = 0
        for frequency in [500.0, 1_500, 2_000, 2_400, 3_000, 4_000, 5_000, 6_000, 12_000] {
            let sine = TestSignal.sine(frequency: frequency, sampleRate: 48_000, count: 48_000, amplitude: 0.5)
            rig.feed(sine)
            let output = Array(probe.samples[fed ..< fed + sine.count])
            fed += sine.count
            let measured = 20 * log10(measuredGain(of: output, frequency: frequency, sampleRate: 48_000, skipping: 24_000) / 0.5)
            let predicted = try design.secondOrderSections.magnitudeResponse(at: [2 * .pi * frequency / 48_000], in: .decibels)[0]
            expectClose(measured, predicted, .absolute(0.1), "\(frequency) Hz: measured \(measured) dB, the analysis says \(predicted) dB")
            Measurements.shared.record("WP-432a live session on sines against the analysis, dB", abs(measured - predicted), bound: 0.1)
        }
        session.detach()
    }

    @Test func theStageEmitsOneCascadeWithItsGainSpreadAndNoLatency() throws {
        let pipeline = Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 8) }
        let kernels = try loweredKernels(pipeline.environment(\.biquadPrecision, .double))
        guard kernels.count == 1, case .biquad(let sections, let precision) = kernels[0] else {
            Issue.record("one cascade was due, not \(kernels)")
            return
        }
        #expect(sections.count == 4 && precision == .double)
        // REAL-1: what runs is the design's sections, with the gain spread.
        let design = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 8, domain: .digital(sampleRate: 48_000))
        let spread = try design.secondOrderSections.spreadingGain()
        #expect(sections == spread.biquadSections)
        let latency = try outputEnvironment(pipeline).latency
        #expect(latency == 0, "an IIR filter adds no latency (REAL-5)")
        // A band filter has twice the order: as many sections as the prototype has poles.
        let band = try loweredKernels(Pipeline { BandStop(.chebyshev1(ripple: .decibels(1)), from: .hertz(300), to: .hertz(900), order: 3) })
        guard case .biquad(let bandSections, _) = band[0] else { Issue.record("a cascade was due"); return }
        #expect(bandSections.count == 3)
        // An odd order: the last section is of first order.
        guard case .biquad(let odd, _) = try loweredKernels(Pipeline { HighPass(.butterworth, cutoff: .hertz(300), order: 5) })[0] else { Issue.record("a cascade was due"); return }
        #expect(odd.count == 3)
    }

    @Test func offlineOutputEqualsTheRecurrenceOfTheDesign() throws {
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 432)
        for order in [2, 5, 8] {
            let design = try IIRDesign(.chebyshev1(ripple: .decibels(0.5)), .highPass(cutoff: 800), order: order, domain: .digital(sampleRate: 48_000))
            let reference = cascadeReference(noise, try design.secondOrderSections.spreadingGain())
            let stage = Pipeline { HighPass(.chebyshev1(ripple: .decibels(0.5)), cutoff: .hertz(800), order: order) }
            for blockSize in [1, 64, 512, 4_096] {
                let double = try stage.environment(\.biquadPrecision, .double).process(noise, format: format, blockSize: blockSize)
                expectClose(double, reference, .deviationBelow(decibels: -130), "order \(order), double precision, blocks of \(blockSize)")
                let single = try stage.environment(\.biquadPrecision, .single).process(noise, format: format, blockSize: blockSize)
                // Single precision on vDSP_biquad: 4e-5 for an order-8 filter with a low corner (E-30).
                expectClose(single, reference, .deviationBelow(decibels: -70), "order \(order), single precision, blocks of \(blockSize)")
            }
        }
        // The fluent spelling is the same stage (API-1).
        let fluent = Pipeline().highPass(.chebyshev1(ripple: .decibels(0.5)), cutoff: .hertz(800), order: 5)
        #expect(fluent == Pipeline { HighPass(.chebyshev1(ripple: .decibels(0.5)), cutoff: .hertz(800), order: 5) })
        // Every channel has its own memory.
        let stereo = try fluent.process(channels: [noise, noise.reversed()], format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        let left = try fluent.process(noise, format: format), right = try fluent.process(noise.reversed(), format: format)
        #expect(stereo[0] == left && stereo[1] == right)
    }

    @Test func anEdgeIsCheckedAgainstTheNyquistFrequencyAtTheStagesPosition() throws {
        // O-16, ENV-1: legal at 48 kHz, rejected behind a decimator, with the stage's path.
        let legal = Pipeline { LowPass(.butterworth, cutoff: .hertz(10_000), order: 4) }
        #expect(try legal.process(TestSignal.silence(count: 64), format: format).count == 64)
        let behind = Pipeline { Decimate(by: 4); LowPass(.butterworth, cutoff: .hertz(10_000), order: 4) }
        let error = thrownError { _ = try behind.process(TestSignal.silence(count: 64), format: format) }
        #expect(error?.invalidParameterName == "cutoff")
        #expect(error?.stage?.description == "LowPass[1]")
        #expect(error?.invalidParameterReason?.contains("6000") == true, "\(String(describing: error))")
        // The same value in a unit that follows the rate is legal anywhere.
        #expect(try Pipeline { Decimate(by: 4); LowPass(.butterworth, cutoff: .fractionOfNyquist(0.5), order: 4) }
            .process(TestSignal.silence(count: 64), format: format).count == 16)
        func rejected(_ pipeline: Pipeline<Samples, Samples>) -> DSPError? {
            thrownError { _ = try pipeline.process(TestSignal.silence(count: 64), format: format) }
        }
        #expect(rejected(Pipeline { HighPass(.butterworth, cutoff: .hertz(0), order: 2) })?.invalidParameterName == "cutoff")
        #expect(rejected(Pipeline { BandPass(.butterworth, from: .hertz(300), to: .hertz(24_000), order: 2) })?.invalidParameterName == "to")
        #expect(rejected(Pipeline { BandStop(.butterworth, from: .hertz(900), to: .hertz(300), order: 2) })?.invalidParameterName == "to")
        #expect(rejected(Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 0) })?.invalidParameterName == "order")
        #expect(rejected(Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(25)) })?.invalidParameterName == "rollOff")
        #expect(rejected(Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(25), rounding: .up) }) == nil)
        #expect(rejected(Pipeline { LowPass(.bessel(), passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })?.isUnsupportedConfiguration == true)
        #expect(rejected(Pipeline { LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(30_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })?.invalidParameterName == "stopband")
        // Every error of a stage carries its path.
        #expect(rejected(Pipeline { Gain(.decibels(-3)); Tap { HighPass(.butterworth, cutoff: .hertz(0), order: 2) } })?.stage?.description == "Tap[1] › HighPass[0]")
    }

    @Test func theOrderRulesHoldInBothTiers() throws {
        // Tier 2 (ORD-5, ORD-6): on a sampled sequence a filter is accepted, after frames of bins it is not.
        let stage = LowPass(.butterworth, cutoff: .hertz(4), order: 2)
        let accepted = try DynamicPipeline().appending(stage).appending(MeanTrack(hop: 480)).appending(stage)
        #expect(accepted.outputTag == .scalar)
        let wrong = thrownError { _ = try DynamicPipeline().appending(FrameStub()).appending(stage) }
        guard case .invalidStageOrder(let path, let found)? = wrong else { Issue.record("an order error was due, not \(String(describing: wrong))"); return }
        #expect(path.description == "LowPass[1]" && found == FrameStub.Output.tag)
        // On a scalar track the frequencies are those of the track (§5.2): 4 Hz of a 100 Hz sequence.
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 480) }.lowPass(.butterworth, cutoff: .hertz(4), order: 2).emit(to: track)
            .run(on: TestSignal.constant(1, count: 48_000), format: format)
        #expect(track.environment?.sampleRate == 100 && track.scalars.count == 100)
        let last = try #require(track.scalars.last)
        expectClose(last.value, 1, .absolute(1e-3), "a low-pass settles on the constant it is fed")
        let tooHigh = thrownError {
            try Pipeline { MeanTrack(hop: 480) }.lowPass(.butterworth, cutoff: .hertz(60), order: 2).run(on: TestSignal.silence(count: 4_800), format: format)
        }
        #expect(tooHigh?.invalidParameterName == "cutoff", "60 Hz is above the Nyquist frequency of a 100 Hz track")
    }

    @Test func aStageThatIsSwitchedOffForGoodLeavesNoKernel() throws {
        let noise = TestSignal.whiteNoise(count: 1_024, seed: 5)
        for off in [Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false) },
                    Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: .bypassed) },
                    Pipeline().lowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false)] {
            #expect(try loweredKernels(off).isEmpty, "ACT-4: a constant bypass is compiled away")
            #expect(try off.process(noise, format: format) == noise)
        }
        // ACT-12: the default, `true` and `.active` are one description.
        let stage = LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
        #expect(stage == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: true))
        #expect(stage == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: .active))
        #expect(stage != LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false))
        #expect(stage.activation == .active)
        // A stage that is switched off is still validated.
        #expect(thrownError { _ = try Pipeline { LowPass(.butterworth, cutoff: .hertz(30_000), order: 4, isActive: false) }.process(noise, format: format) }?.invalidParameterName == "cutoff")
    }

    @Test func adjacentFiltersOfOnePrecisionFuseAndStayBitIdentical() throws {
        // F2: two stages, one cascade; with a gain between them, two.
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 9)
        let fused = Pipeline {
            HighPass(.butterworth, cutoff: .hertz(90), order: 4)
            LowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
        }.environment(\.biquadPrecision, .single)
        let kernels = try loweredKernels(fused)
        guard kernels.count == 1, case .biquad(let sections, .single) = kernels[0] else { Issue.record("one cascade was due (F2), not \(kernels)"); return }
        #expect(sections.count == 4)
        // A tap between the two is a point fusion does not cross: two cascades, the same samples.
        let apart = Pipeline {
            HighPass(.butterworth, cutoff: .hertz(90), order: 4)
            Tap { Gain(.decibels(-3)) }
            LowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
        }.environment(\.biquadPrecision, .single)
        #expect(try loweredKernels(apart).count == 3)
        let together = try fused.process(noise, format: format), separately = try apart.process(noise, format: format)
        #expect(together == separately, "fused ≡ unfused, bit for bit")
        // Stages that resolve `.automatic` to different precisions are two kernels.
        let mixed = try loweredKernels(Pipeline {
            HighPass(.butterworth, cutoff: .hertz(20), order: 8)
            LowPass(.butterworth, cutoff: .hertz(21_000), order: 2)
        })
        #expect(mixed.count == 2, "\(mixed)")
    }

    @Test func aPoleOnOrOutsideTheUnitCircleDoesNotCompile() throws {
        // REAL-2, through the one stage that can state such a pole.
        let unstable = Pipeline { Filter(IIRSystem { Pole(radius: 1.02, frequency: .hertz(1_000)) }) }
        let error = thrownError { _ = try unstable.process(TestSignal.silence(count: 64), format: format) }
        expectClose(try #require(error?.unstableRadius), 1.02, .absolute(1e-12))
        #expect(error?.stage?.description == "Filter[0]")
        let marginal = thrownError { _ = try Pipeline { Filter(IIRSystem { Pole(radius: 1, frequency: .hertz(1_000)) }) }.process(TestSignal.silence(count: 64), format: format) }
        #expect(marginal?.unstableRadius == 1)
    }

    @Test func aCutoffAnimatedOverAnOctaveKeepsThePlanAndMakesNoClick() async throws {
        // §5.5.4, CLICK-1, fact 4 of CR-013: animating a cutoff does not change the topology.
        let rig = StageRig(blockSize: 64)
        func pipeline(_ cutoff: Double) -> Pipeline<Samples, Samples> {
            Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }.environment(\.biquadPrecision, .single)
        }
        let (session, probe) = try await rig.run(pipeline(2_000))
        let sine = Click.probeSignal(count: 480 * 60)
        rig.feed(Array(sine[..<(480 * 10)]))
        let plan = session.core.plan
        // One octave down in forty steps of 10 ms, each an interpolated parameter vector as a host sends them (ANI-3).
        let from = pipeline(2_000).parameters, to = pipeline(1_000).parameters
        #expect(from.count == 1 && from.values[0] == log2(2_000))
        for step in 1 ... 40 {
            let vector = from + (to - from).scaled(by: Double(step) / 40)
            try await session.update(pipeline(2_000).replacingParameters(vector))
            rig.feed(Array(sine[(480 * (9 + step)) ..< (480 * (10 + step))]))
        }
        rig.feed(Array(sine[(480 * 50)...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "forty value updates and no new plan")
        let click = Click.measure(probe.samples, change: (480 * 10) ..< (480 * 51), settle: 480)
        #expect(click.passes, "CLICK-1 over the sweep: \(click)")
        let settled = try pipeline(1_000).process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(480 * 56)...]), Array(settled[(480 * 56)...]), .deviationBelow(decibels: -80), "the filter kept its memory and ended at the new cutoff")
        session.detach()
    }

    @Test func aBoundSwitchBypassesTheFilterWithoutAClick() async throws {
        let rig = StageRig(blockSize: 64)
        let on = StateBox(true)
        let (session, probe) = try await rig.run(Pipeline { HighPass(.butterworth, cutoff: .hertz(4_000), order: 4, isActive: on.binding) })
        let sine = Click.probeSignal(count: 64 * 240)
        rig.feed(Array(sine[..<(64 * 80)]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 80) ..< (64 * 160)]))
        #expect(Array(probe.samples[(64 * 120) ..< (64 * 160)]) == Array(sine[(64 * 120) ..< (64 * 160)]), "bypassed, the signal passes unchanged (ACT-3)")
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 160)...]))
        let filtered = try Pipeline { HighPass(.butterworth, cutoff: .hertz(4_000), order: 4) }.process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(64 * 220)...]), Array(filtered[(64 * 220)...]), .deviationBelow(decibels: -80), "back on, the output is the filter's")
        let off = Click.measure(probe.samples, change: (64 * 80) ..< (64 * 92), settle: 64)
        let back = Click.measure(probe.samples, change: (64 * 160) ..< (64 * 180), settle: 64)
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
        session.detach()
    }

    @Test func aThousandBlocksOfEachResponseAllocateNothing() async throws {
        let noise = TestSignal.whiteNoise(count: 512, seed: 77)
        let on = StateBox(true)
        let pipelines: [(String, Pipeline<Samples, Samples>)] = [
            ("a low-pass in double precision", Pipeline { LowPass(.butterworth, cutoff: .hertz(90), order: 8) }),
            ("a high-pass in single precision", Pipeline { HighPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), cutoff: .hertz(9_000), order: 5) }.environment(\.biquadPrecision, .single)),
            ("a band-pass and a band-stop, fused", Pipeline {
                BandPass(.chebyshev1(ripple: .decibels(1)), from: .hertz(300), to: .hertz(3_400), order: 3)
                BandStop(.chebyshev2(stopband: .decibels(40)), from: .hertz(900), to: .hertz(1_100), order: 2)
            }),
            ("a bound low-pass", Pipeline { LowPass(.bessel(), cutoff: .hertz(2_000), order: 4, isActive: on.binding) }),
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

/// A step from samples to a spectrum that is never run: what puts a frame of bins in front of
/// a sequence stage for the tier-2 order rule.
struct FrameStub: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}
