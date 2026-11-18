import Foundation
import Testing
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// A family that records where its prototype was asked for: what shows on which context a
/// stage is designed.
private struct WitnessedButterworth: FilterFamily {
    let witness: Witness

    final class Witness: Hashable, @unchecked Sendable {
        // Threading: written on the context that designs, read by the test afterwards.
        var calls = 0
        var onMainThread = false
        static func == (lhs: Witness, rhs: Witness) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        witness.calls += 1
        if Thread.isMainThread { witness.onMainThread = true }
        return try AnalogPrototype.butterworth(order: order)
    }
}

/// WP-433. `BiquadPrecision.automatic`, by measurement when the plan is compiled (REAL-3).
/// Acceptance: over a grid of cutoffs from 10 Hz to 0.45·f_s at 44.1, 48, 96 and 192 kHz and
/// orders 2…8, the chosen path is within −100 dB of the double reference; the measurement runs
/// on the control context.
@Suite("BiquadPrecision.automatic (WP-433)")
struct PrecisionTests {
    /// The precision a pipeline of one filter stage lowers to.
    private func chosenPrecision(_ pipeline: Pipeline<Samples, Samples>, sampleRate: Double, channelCount: Int = 1) throws -> BiquadPrecision {
        guard case .biquad(_, let precision)? = try loweredKernels(pipeline, sampleRate: sampleRate, channelCount: channelCount).first else {
            Issue.record("a cascade was due")
            return .automatic
        }
        return precision
    }

    @Test func overTheGridTheChosenPathIsWithinMinus100DecibelsOfTheDoubleReference() throws {
        let signals = PrecisionMeasurement.signals()                 // the impulse and the seeded noise of §6.3.8
        let other = TestSignal.whiteNoise(count: 4_096, seed: 433)   // a signal the measurement has not seen
        var single = 0, double = 0
        var worstMeasured = -Double.infinity, worstOther = -Double.infinity
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let format = SignalFormat(sampleRate: rate)
            for step in 0 ..< 8 {
                let cutoff = 10 * pow(0.45 * rate / 10, Double(step) / 7)
                for order in 2 ... 8 {
                    let stages: [(String, Pipeline<Samples, Samples>)] = [
                        ("low-pass", Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: order) }),
                        ("high-pass", Pipeline { HighPass(.butterworth, cutoff: .hertz(cutoff), order: order) }),
                    ]
                    for (name, pipeline) in stages {
                        let label = "\(name), \(cutoff) Hz at \(rate) Hz, order \(order)"
                        let chosen = try chosenPrecision(pipeline, sampleRate: rate)
                        #expect(chosen == .single || chosen == .double, "\(label): `.automatic` is resolved by the stage")
                        if chosen == .single { single += 1 } else { double += 1 }
                        let reference = pipeline.environment(\.biquadPrecision, .double)
                        for signal in signals {
                            let deviation = deviationInDecibels(try pipeline.process(signal, format: format), try reference.process(signal, format: format))
                            worstMeasured = max(worstMeasured, deviation)
                            #expect(deviation <= -100, "\(label): the chosen path (\(chosen)) is \(deviation) dB from the double reference")
                        }
                        let deviation = deviationInDecibels(try pipeline.process(other, format: format), try reference.process(other, format: format))
                        worstOther = max(worstOther, deviation)
                        // What was measured is what the analysis reports for the same cascade.
                        if step == 3, order == 4 {
                            let sections = try IIRDesign(.butterworth, name == "low-pass" ? .lowPass(cutoff: cutoff) : .highPass(cutoff: cutoff), order: order,
                                                         domain: .digital(sampleRate: rate)).secondOrderSections
                            let recommended = try sections.recommendedPrecision()
                            #expect(recommended == chosen, "\(label)")
                        }
                    }
                }
            }
        }
        #expect(single + double == 4 * 8 * 7 * 2)
        Measurements.shared.record("WP-433 chosen path against the double reference on the signals of the measurement, dB", worstMeasured, bound: -100)
        Measurements.shared.record("WP-433 chosen path against the double reference on noise the measurement has not seen, dB (held to −95)", worstOther, bound: -95)
        Measurements.shared.record("WP-433 designs of the grid that run in single precision (of 448)", Double(single), bound: 448)
        // The measurement decides on two signals. On a third the single path it chose is not
        // held to the threshold itself: it stays within a few decibels of it.
        #expect(worstOther <= -95, "on noise the measurement has not seen: \(worstOther) dB")
        #expect(single > 0 && double > 0, "the grid holds filters of both kinds: \(single) single, \(double) double")
    }

    @Test func theEnvironmentDecidesWhenItNamesAPrecision() throws {
        let stage = Pipeline { HighPass(.butterworth, cutoff: .hertz(20), order: 8) }
        #expect(try chosenPrecision(stage, sampleRate: 96_000) == .double, "the acceptance fixture of the double kernel")
        #expect(try chosenPrecision(stage.environment(\.biquadPrecision, .single), sampleRate: 96_000) == .single)
        #expect(try chosenPrecision(stage.environment(\.biquadPrecision, .double), sampleRate: 96_000) == .double)
        #expect(try chosenPrecision(stage.environment(\.biquadPrecision, .automatic), sampleRate: 96_000) == .double)
        let gentle = Pipeline { LowPass(.butterworth, cutoff: .hertz(21_600), order: 8) }
        #expect(try chosenPrecision(gentle, sampleRate: 48_000) == .single, "lp-0.45fs-48k-order8 of the stress library: −107.6 dB")
        #expect(try chosenPrecision(gentle.environment(\.biquadPrecision, .double), sampleRate: 48_000) == .double)
        // A scope decides for the stages inside it.
        let kernels = try loweredKernels(Pipeline {
            Group { LowPass(.butterworth, cutoff: .hertz(21_600), order: 2) }.environment(\.biquadPrecision, .double)
            Gain(.decibels(-3))
            LowPass(.butterworth, cutoff: .hertz(21_600), order: 2)
        })
        guard kernels.count == 3, case .biquad(_, .double) = kernels[0], case .biquad(_, .single) = kernels[2] else { Issue.record("\(kernels)"); return }
    }

    @Test func theMeasurementIsThatOfTheKernelThePlanCreates() throws {
        // The single path differs with the block size and the channel count; the measurement follows.
        let sections = try IIRDesign(.butterworth, .highPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate: 48_000)).secondOrderSections.spreadingGain().biquadSections
        let vDSP = try PrecisionMeasurement.deviation(of: sections, accelerated: true, channelCount: 1, blockFrames: 512)
        let loop = try PrecisionMeasurement.deviation(of: sections, accelerated: false, channelCount: 1, blockFrames: 1)
        let many = try PrecisionMeasurement.deviation(of: sections, accelerated: true, channelCount: 4, blockFrames: 512)
        Measurements.shared.record("WP-433 hp-1kHz-48k-order4, single against double on vDSP_biquad, dB", vDSP, bound: 0)
        Measurements.shared.record("WP-433 hp-1kHz-48k-order4, single against double on the C loop, dB", loop, bound: 0)
        Measurements.shared.record("WP-433 hp-1kHz-48k-order4, single against double on vDSP_biquadm, dB", many, bound: 0)
        #expect(vDSP < -90 && vDSP > -105 && loop < vDSP && many < vDSP, "vDSP \(vDSP) dB, C loop \(loop) dB, four channels \(many) dB")
        // The public figure is the mono vDSP one, and the recommendation follows its threshold.
        let cascade = try IIRDesign(.butterworth, .highPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate: 48_000)).secondOrderSections
        #expect(try cascade.singleVersusDoubleDeviation() == vDSP)
        #expect(try cascade.recommendedPrecision() == (vDSP > -100 ? .double : .single))
        #expect(PrecisionMeasurement.precision(for: -100) == .single && PrecisionMeasurement.precision(for: -99.999) == .double)
        // A plan of four channels, and one on a feature-rate track, measure their own kernels and run.
        let stage = Pipeline { HighPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
        #expect(try chosenPrecision(stage, sampleRate: 48_000, channelCount: 4) == PrecisionMeasurement.precision(for: many))
        let noise = TestSignal.whiteNoise(count: 2_048, seed: 4)
        let wide = SignalFormat(sampleRate: 48_000, channelCount: 4)
        let chosen = try stage.process(channels: [[Float]](repeating: noise, count: 4), format: wide)
        let reference = try stage.environment(\.biquadPrecision, .double).process(channels: [[Float]](repeating: noise, count: 4), format: wide)
        for channel in 0 ..< 4 { #expect(deviationInDecibels(chosen[channel], reference[channel]) <= -99) }
        // The same signal, the same seed: the measurement is the same on every run.
        #expect(try PrecisionMeasurement.deviation(of: sections, accelerated: true, channelCount: 1, blockFrames: 512) == vDSP)
        #expect(PrecisionMeasurement.signals()[0].first == 1 && PrecisionMeasurement.signals()[1].count == 4_096)
        // What cannot be measured is a typed error.
        #expect(thrownError { _ = try PrecisionMeasurement.deviation(of: [], accelerated: true, channelCount: 1, blockFrames: 512) }?.invalidParameterName == "sections")
        #expect(thrownError { _ = try SecondOrderSections(sections: [.identity], domain: .analog).singleVersusDoubleDeviation() }?.isUnsupportedConfiguration == true)
        #expect(thrownError { _ = try SecondOrderSections(sections: [.init(b0: 1, b1: 0, b2: 0, a1: 0, a2: 1.5)]).recommendedPrecision() }?.isUnsupportedConfiguration == true)
        #expect(try SecondOrderSections(sections: []).singleVersusDoubleDeviation() == DSP.decibelFloor)
    }

    @Test @MainActor func theMeasurementRunsOnTheControlContextNotOnTheMainThread() async throws {
        // `attach` is called on the main actor; the design and the measurement happen where the
        // plan is compiled.
        let witness = WitnessedButterworth.Witness()
        let rig = StageRig(blockSize: 512)
        let session = try await rig.engine.attach(Pipeline { LowPass(WitnessedButterworth(witness: witness), cutoff: .hertz(90), order: 8) }, to: rig.source)
        #expect(witness.calls >= 1 && !witness.onMainThread, "the stage was lowered off the main thread")
        // The plan holds the precision that was chosen there: nothing is measured while it runs.
        let chosen = try #require(IRStep.kernels(of: session.core.plan.lowered.steps).first)
        guard case .biquad(let sections, let precision) = chosen.spec else { Issue.record("a cascade was due"); return }
        #expect(sections.count == 4 && precision == .double)
        try session.start()
        let noise = TestSignal.whiteNoise(count: 512, seed: 6)
        rig.feed(noise)
        await rig.drain()
        let designs = witness.calls
        try rig.auditAllocations(blocks: 1_000, of: noise, "1 000 blocks of a filter whose precision was measured")
        #expect(witness.calls == designs, "nothing is designed or measured on the thread that runs the plan")
        session.detach()
    }

    @Test func anUpdateThatChoosesTheOtherPrecisionIsATopologyChange() async throws {
        // REAL-3, SWAP-2: the kernel of the other precision replaces the one that runs.
        let rig = StageRig(blockSize: 64)
        func pipeline(_ cutoff: Double) -> Pipeline<Samples, Samples> { Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 2) } }
        #expect(try chosenPrecision(pipeline(21_600), sampleRate: 48_000) == .single)
        #expect(try chosenPrecision(pipeline(200), sampleRate: 48_000) == .double)
        let (session, probe) = try await rig.run(pipeline(21_600))
        let sine = Click.probeSignal(count: 48_000)
        rig.feed(Array(sine[..<9_600]))
        #expect(session.core.generation == 1)
        try await session.update(pipeline(200))
        rig.feed(Array(sine[9_600...]))
        #expect(session.core.generation == 2, "the other precision is another kernel: a new plan")
        let settled = try pipeline(200).process(sine, format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        expectClose(Array(probe.samples[40_000...]), Array(settled[40_000...]), .deviationBelow(decibels: -80), "the new filter took over")
        let click = Click.measure(probe.samples, change: 9_600 ..< 9_600 + 4_800, settle: 480)
        #expect(click.passes, "CLICK-1 across the exchange: \(click)")
        session.detach()
    }

    /// The stress test of the realisation (NUMS-2): the lowest corner of the precision grid,
    /// `lp-10Hz-192k-order8` of the stress-fixture library (WP-016). Its gain is 5·10⁻³¹; in the
    /// first section alone it puts that section twenty decades below the signal, where the
    /// kernels clear its memory at the end of every block (RT-6).
    @Test func stressALowCutoffAtAHighRateRunsBecauseItsGainIsSpread() throws {
        let fixture = try #require(StressFixture.filtersNearZero.first { $0.name == "lp-10Hz-192k-order8" })
        let design = try IIRDesign(.butterworth, .lowPass(cutoff: fixture.cutoff), order: fixture.order, domain: .digital(sampleRate: fixture.sampleRate))
        let paired = try design.secondOrderSections
        #expect(abs(paired.sections[0].b0) < 1e-28, "the pairing puts the whole gain into the first section: \(paired.sections[0].b0)")
        let spread = paired.spreadingGain()
        #expect(spread.sections.allSatisfy { abs($0.b0) > 1e-12 }, "spread, no section works far below the signal")

        // A step: the output of a low-pass climbs to the level of its input.
        let step = TestSignal.constant(1, count: 192_000)
        let format = SignalFormat(sampleRate: fixture.sampleRate)
        let output = try Pipeline { LowPass(.butterworth, cutoff: .hertz(fixture.cutoff), order: fixture.order) }.process(step, format: format)
        let reference = cascadeReference(step, spread)
        let deviation = deviationInDecibels(output, reference)
        Measurements.shared.record("WP-433 stress lp-10Hz-192k-order8: the stage against the recurrence in double precision, dB", deviation, bound: -100)
        #expect(deviation <= -100, "\(deviation) dB")
        expectClose(Double(try #require(output.last)), 1.0, .absolute(1e-3), "one second in, the step has arrived")
    }

    @Test func spreadingTheGainLeavesTheSystemAndLevelsItsSections() throws {
        let designs: [SecondOrderSections] = [
            try IIRDesign(.butterworth, .lowPass(cutoff: 10), order: 8, domain: .digital(sampleRate: 192_000)).secondOrderSections,
            try IIRDesign(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), .bandPass(from: 2_000, to: 5_000), order: 5, domain: .digital(sampleRate: 48_000)).secondOrderSections,
            try IIRDesign(.chebyshev2(stopband: .decibels(60)), .bandStop(from: 45, to: 55), order: 3, domain: .digital(sampleRate: 48_000)).secondOrderSections,
            try EqualizerDesign.bandBoost(center: 100, gain: .decibels(24), bandwidth: .octaves(0.3), order: 6, sampleRate: 96_000).secondOrderSections,
            SecondOrderSections(sections: [.init(b0: 1e-25, b1: 0, b2: 0, a1: -0.5, a2: 0), .init(b0: 1e25, b1: 1e25, b2: 0, a1: 0.2, a2: 0.1)]),
        ]
        let grid = (0 ... 2_000).map { Double.pi * Double($0) / 2_000 }
        for (index, cascade) in designs.enumerated() {
            let spread = cascade.spreadingGain()
            #expect(spread.sections.count == cascade.sections.count && spread.domain == .digital)
            // The same system: the same response, the same poles.
            let before = try cascade.frequencyResponse(at: grid), after = try spread.frequencyResponse(at: grid)
            let peak = before.map(\.magnitude).max() ?? 1
            let worst = zip(before, after).map { ($0 - $1).magnitude }.max() ?? 0
            #expect(worst <= 1e-9 * peak, "design \(index): the response moved by \(worst / peak) of its peak")
            #expect(zip(cascade.sections, spread.sections).allSatisfy { $0.a1 == $1.a1 && $0.a2 == $1.a2 })
            // Up to every section but the last, the response peaks at 1: within 1 dB on a grid
            // of its own, which is fine around every pole, where a resonance has its peak.
            for count in 1 ..< spread.sections.count {
                let prefix = SecondOrderSections(sections: Array(spread.sections.prefix(count)))
                var fine = grid
                for pole in prefix.poles where pole.imaginary > 0 {
                    for step in -200 ... 200 { fine.append(min(max(pole.phase + Double(step) * (1 - pole.magnitude) / 20, 0), .pi)) }
                }
                let level = try prefix.magnitudeResponse(at: fine, in: .decibels).max() ?? 0
                Measurements.shared.record("WP-433 gain spreading: peak of the response up to a section, distance from 0 dB", abs(level), bound: 1)
                #expect(abs(level) <= 1, "design \(index), up to section \(count): \(level) dB")
            }
        }
        // What is not a digital cascade of several sections is returned as it is.
        let one = SecondOrderSections(sections: [.init(b0: 0.5, b1: 0, b2: 0, a1: -0.5, a2: 0)])
        #expect(one.spreadingGain() == one && SecondOrderSections(sections: []).spreadingGain().sections.isEmpty)
        let analog = SecondOrderSections(sections: [.identity, .identity], domain: .analog)
        #expect(analog.spreadingGain() == analog)
        let silent = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0), .identity])
        #expect(silent.spreadingGain() == silent, "a cascade that passes nothing has no level to spread")
    }

    @Test func aCascadeBeyondSinglePrecisionIsMeasuredAsSuchAndRunsInDouble() throws {
        // Eight resonators within 10⁻⁷ of the unit circle. Spread, the last section carries a
        // gain of some 10⁵³, which no single-precision coefficient holds; the response itself
        // stays in range for a while.
        let resonators = IIRSystem { for _ in 0 ..< 8 { Pole(radius: 0.9999999, frequency: .hertz(1_000)) } }
        let sections = try resonators.secondOrderSections(sampleRate: 48_000).spreadingGain()
        #expect(sections.sections.contains { !Float($0.b0).isFinite } && sections.sections.allSatisfy { $0.b0.isFinite })
        // Measured: what is not a finite number in single precision is an infinite deviation,
        // not one that is passed by.
        #expect(try sections.singleVersusDoubleDeviation() == .infinity)
        #expect(try sections.recommendedPrecision() == .double)
        // `.automatic` therefore runs it in double precision, and `.single` is refused where the plan is compiled.
        let stage = Pipeline { Filter(resonators) }
        #expect(try chosenPrecision(stage, sampleRate: 48_000) == .double)
        let refused = thrownError { _ = try loweredKernels(stage.environment(\.biquadPrecision, .single)) }
        #expect(refused?.invalidParameterName == "sections", "\(String(describing: refused))")
        // In double precision it runs, and its output is the recurrence's.
        let input = TestSignal.impulse(count: 256)
        let output = try stage.process(input, format: SignalFormat(sampleRate: 48_000))
        #expect(output.allSatisfy(\.isFinite) && (output.map(abs).max() ?? 0) > 1e6)
        expectClose(output, cascadeReference(input, sections), .deviationBelow(decibels: -100))
        // A gain no sample holds: both outputs leave the range, and the figure says so.
        let loud = SecondOrderSections(sections: [.init(b0: 1e39, b1: 0, b2: 0, a1: -0.5, a2: 0)])
        #expect(try loud.singleVersusDoubleDeviation() == .infinity && loud.recommendedPrecision() == .double)
        let report = try SystemAnalysis.analyse(loud, sampleRate: 48_000)
        #expect(report.singleVersusDoubleDeviation == .infinity && report.recommendedPrecision == .double)
        #expect(report.roundOffNoiseGain(precision: .single) != nil, "the node of the section is followed by nothing: its gain is that of the poles alone")
        // A response that leaves the range of a sample on its way to the output: no finite round-off figure.
        let beyond = try SystemAnalysis.analyse(resonators, sampleRate: 48_000)
        #expect(beyond.isStable && beyond.roundOffNoiseGain(precision: .double) == .infinity && beyond.singleVersusDoubleDeviation == .infinity)
    }
}
