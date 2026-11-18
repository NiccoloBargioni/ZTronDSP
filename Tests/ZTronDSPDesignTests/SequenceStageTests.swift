import Foundation
import Testing
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// The level of one frequency in a signal, by correlation with a quadrature pair over the
/// whole of `samples`, as an amplitude.
private func amplitude(of samples: ArraySlice<Float>, at frequency: Double, sampleRate: Double) -> Double {
    var inPhase = 0.0, quadrature = 0.0
    for (index, sample) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        inPhase += Double(sample) * sin(phase)
        quadrature += Double(sample) * cos(phase)
    }
    return 2 * (inPhase * inPhase + quadrature * quadrature).squareRoot() / Double(samples.count)
}

/// WP-437. `Gain` stage (§6.2). Acceptance: ≡ scalar reference; a changed amount ramps
/// (CLICK-1); adjacent gains merge (F1).
@Suite("Gain stage (WP-437)")
struct GainStageTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 4_096, seed: 437)

    @Test func theOutputIsTheScalarReference() throws {
        for amount in [Amplification.decibels(-3), .decibels(6), .linear(0.5), .linear(-1), .linear(0), .decibels(-160), .unity] {
            let factor = Float(amount.linear)
            for blockSize in [1, 7, 64, 512, 4_096] {
                let output = try Pipeline { Gain(amount) }.process(noise, format: format, blockSize: blockSize)
                #expect(output == noise.map { $0 * factor }, "\(amount), blocks of \(blockSize): one multiplication per sample, bit for bit")
            }
        }
        // Per channel.
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let scaled = try Pipeline { Gain(channels: [.decibels(0), .linear(-0.25)]) }.process(channels: [noise, noise], format: stereo)
        #expect(scaled[0] == noise && scaled[1] == noise.map { $0 * -0.25 })
        let both = try Pipeline { Gain(.linear(2)) }.process(channels: [noise, noise.reversed()], format: stereo)
        #expect(both[0] == noise.map { $0 * 2 } && both[1] == noise.reversed().map { $0 * 2 })
        // The fluent spelling is the same stage.
        #expect(Pipeline().gain(.decibels(-3)) == Pipeline { Gain(.decibels(-3)) })
        #expect(Pipeline().gain(.decibels(-3), ramp: 0.05, isActive: false) == Pipeline { Gain(.decibels(-3), ramp: 0.05, isActive: false) })
        #expect(Pipeline().gain(channels: [.unity, .linear(0.5)], ramp: 0) == Pipeline { Gain(channels: [.unity, .linear(0.5)], ramp: 0) })
        #expect(Gain(.decibels(-3)).ramp == 0.010 && Gain(.decibels(-3)).amounts == [.decibels(-3)])
        // On a scalar track there is one channel.
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 480) }.gain(.linear(4)).emit(to: track).run(on: TestSignal.constant(0.25, count: 4_800), format: format)
        #expect(track.scalars.map(\.value) == [Float](repeating: 1, count: 10))
    }

    @Test func adjacentGainsAreOneKernelAndAUnityGainIsNone() throws {
        // F1: three gains, one kernel, the factors applied one after another.
        let chain = Pipeline { Gain(.decibels(-3)); Gain(.linear(0.5)); Gain(.decibels(6), ramp: 0.02) }
        let kernels = try loweredKernels(chain)
        guard kernels.count == 1, case .gainCascade(let factors, let ramp) = kernels[0] else { Issue.record("one gain kernel was due, not \(kernels)"); return }
        #expect(factors == [Float(Amplification.decibels(-3).linear), 0.5, Float(Amplification.decibels(6).linear)] && ramp == 0.02)
        // Merged and unmerged give the same samples, bit for bit.
        let apart = Pipeline { Gain(.decibels(-3)); Tap { Gain(.linear(2)) }; Gain(.linear(0.5)); Tap { Gain(.linear(2)) }; Gain(.decibels(6), ramp: 0.02) }
        #expect(try loweredKernels(apart).count == 5)
        let merged = try chain.process(noise, format: format), separate = try apart.process(noise, format: format)
        #expect(merged == separate)
        // A gain is never folded into a filter: it must still be able to ramp.
        #expect(try loweredKernels(Pipeline { Gain(.decibels(-3)); LowPass(.butterworth, cutoff: .hertz(1_000), order: 2); Gain(.decibels(3)) }).count == 3)
        // F4: unity is no kernel; so is a gain that is switched off for good.
        #expect(try loweredKernels(Pipeline { Gain(.unity); Gain(.decibels(0)) }).isEmpty)
        #expect(try loweredKernels(Pipeline { Gain(.decibels(-3), isActive: false) }).isEmpty)
        // Per-channel gains keep a kernel of their own.
        guard case .channelGains(let perChannel, _)? = try loweredKernels(Pipeline { Gain(channels: [.linear(1), .linear(0.5)]) }, channelCount: 2).first else {
            Issue.record("a per-channel kernel was due")
            return
        }
        #expect(perChannel == [1, 0.5])
    }

    @Test func theAmountIsTheContinuousValueInDecibels() throws {
        #expect(Gain(.decibels(-3)).parameters == [-3])
        expectClose(Gain(.linear(0.5)).parameters, [20 * log10(0.5)], .absolute(1e-12))
        #expect(Gain(channels: [.decibels(1), .decibels(-2)]).parameters == [1, -2])
        let gain = Gain(.linear(0.3), ramp: 0.05, isActive: false)
        #expect(gain.replacingParameters(gain.parameters[...]) == gain)
        #expect(Gain(.decibels(-3)).replacingParameters([6][...]) == Gain(.decibels(6)))
        #expect(Gain(channels: [.decibels(1), .decibels(-2)]).replacingParameters([0, 3][...]) == Gain(channels: [.decibels(0), .decibels(3)]))
        #expect(Gain(.decibels(-3)).replacingParameters([1, 2][...]) == Gain(.decibels(-3)))
        // A negative factor keeps its sign when its level moves.
        expectClose(Gain(.linear(-0.5)).replacingParameters([0][...]).amounts[0].linear, -1.0, .absolute(1e-12))
    }

    @Test func whatIsNoGainIsRejectedWhenThePlanIsCompiled() throws {
        func rejected(_ pipeline: Pipeline<Samples, Samples>, channels: Int = 1) -> DSPError? {
            thrownError { _ = try pipeline.process(channels: [[Float]](repeating: [0, 0], count: channels), format: SignalFormat(sampleRate: 48_000, channelCount: channels)) }
        }
        #expect(rejected(Pipeline { Gain(.linear(.infinity)) })?.invalidParameterName == "amount")
        #expect(rejected(Pipeline { Gain(.decibels(.nan)) })?.invalidParameterName == "amount")
        #expect(rejected(Pipeline { Gain(.decibels(-3), ramp: -1) })?.invalidParameterName == "ramp")
        let count = rejected(Pipeline { Gain(.unity); Gain(channels: [.unity, .unity, .unity]) }, channels: 2)
        #expect(count?.invalidParameterName == "channels" && count?.stage?.description == "Gain[1]")
        #expect(rejected(Pipeline { Gain(channels: [.unity, .linear(.nan)]) }, channels: 2)?.invalidParameterName == "channels")
        #expect(rejected(Pipeline { Gain(channels: [.unity, .linear(0.5)]) }, channels: 2) == nil)
    }

    @Test func aChangedAmountRampsAndMakesNoClick() async throws {
        // CLICK-1: 14 dB up under a full-scale sine, over the 10 ms of the default ramp.
        let rig = StageRig(blockSize: 64)
        let (session, probe) = try await rig.run(Pipeline { Gain(.decibels(-20)) })
        let sine = Click.probeSignal(count: 9_600)
        rig.feed(Array(sine[..<4_800]))
        let plan = session.core.plan
        try await session.update(Pipeline { Gain(.linear(0.5)) })
        rig.feed(Array(sine[4_800...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "a new amount is a value: no new plan")
        // The gain moves linearly from 0.1 to 0.5 over 480 frames and lands on the target exactly.
        let output = probe.samples
        #expect(Array(output[..<4_800]) == sine[..<4_800].map { $0 * 0.1 })
        #expect(Array(output[5_280...]) == sine[5_280...].map { $0 * 0.5 }, "after the ramp the gain is the new one, exactly")
        var worst = 0.0
        for frame in 0 ..< 480 where abs(sine[4_800 + frame]) > 0.05 {
            let gain = Double(output[4_800 + frame] / sine[4_800 + frame])
            worst = max(worst, abs(gain - (0.1 + 0.4 * Double(frame + 1) / 480)))
        }
        Measurements.shared.record("WP-437 gain during a ramp against the straight line, absolute", worst, bound: 1e-5)
        #expect(worst <= 1e-5)
        let click = Click.measure(output, change: 4_800 ..< 5_344, settle: 64)
        #expect(click.passes, "CLICK-1: \(click)")
        session.detach()
        // A ramp of 0 jumps: the step is there, because it was asked for.
        let jumpRig = StageRig(blockSize: 64)
        let (jumping, jumped) = try await jumpRig.run(Pipeline { Gain(.decibels(-20), ramp: 0) })
        jumpRig.feed(Array(sine[..<640]))
        try await jumping.update(Pipeline { Gain(.linear(0.5), ramp: 0) })
        jumpRig.feed(Array(sine[640 ..< 1_280]))
        #expect(Array(jumped.samples[640...]) == sine[640 ..< 1_280].map { $0 * 0.5 })
        jumping.detach()
    }

    @Test func aBoundSwitchFadesTheGainInAndOut() async throws {
        let rig = StageRig(blockSize: 64)
        let on = StateBox(true)
        let (session, probe) = try await rig.run(Pipeline { Gain(.linear(0.25), isActive: on.binding) })
        let sine = Click.probeSignal(count: 64 * 120)
        rig.feed(Array(sine[..<(64 * 40)]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 40) ..< (64 * 80)]))
        #expect(Array(probe.samples[(64 * 60) ..< (64 * 80)]) == Array(sine[(64 * 60) ..< (64 * 80)]), "bypassed, the signal passes unchanged")
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 80)...]))
        #expect(Array(probe.samples[(64 * 110)...]) == sine[(64 * 110)...].map { $0 * 0.25 })
        let off = Click.measure(probe.samples, change: (64 * 40) ..< (64 * 50), settle: 64)
        let back = Click.measure(probe.samples, change: (64 * 80) ..< (64 * 92), settle: 64)
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
        session.detach()
    }

    @Test func aThousandBlocksOfGainsAllocateNothing() async throws {
        let block = Array(noise[..<512])
        let on = StateBox(true)
        let rig = StageRig(blockSize: 512, channelCount: 2)
        let session = try await rig.start(Pipeline { Gain(.decibels(-3)); Gain(.linear(0.5), isActive: on.binding); Gain(channels: [.decibels(1), .decibels(-1)]) })
        rig.feed(block)
        await rig.drain()
        try rig.auditAllocations(blocks: 1_000, of: block, "1 000 blocks through three gains")
        // A value update is applied from memory the control side owns.
        for step in 1 ... 20 {
            try await session.update(Pipeline { Gain(.decibels(-3 - Double(step))); Gain(.linear(0.5), isActive: on.binding); Gain(channels: [.decibels(1), .decibels(-1)]) })
            try rig.auditAllocations(blocks: 4, of: block, "the blocks after a value update")
        }
        session.detach()
    }
}

/// WP-434. `SavitzkyGolay` and `AlphaBeta` stages. Acceptance: stage output ≡ offline
/// function.
@Suite("Smoothing stages (WP-434)")
struct SmoothingStageTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 2_048, seed: 434)

    @Test func theSavitzkyGolayStageIsTheOfflineFunctionDelayedByItsLatency() throws {
        for (window, order, derivative) in [(5, 2, 0), (11, 3, 0), (11, 3, 1), (31, 4, 2), (1, 0, 0), (255, 5, 0)] {
            let half = (window - 1) / 2
            for blockSize in [64, 100, 512] {
                // A stream starts from silence: with `.constant(0)` the stage is the offline
                // function at every sample it has produced.
                let stage = Pipeline { SavitzkyGolay(window: window, polynomialOrder: order, derivative: derivative, edge: .constant(0)) }
                let output = try stage.process(noise, format: format, blockSize: blockSize)
                let offline = try DSP.savitzkyGolay(noise, window: window, polynomialOrder: order, derivative: derivative, edge: .constant(0))
                #expect(output.count == noise.count)
                let worst = zip(output[half...], offline).map { abs($0 - $1) }.max() ?? 0
                Measurements.shared.record("WP-434 SavitzkyGolay stage against the offline function, absolute", Double(worst), bound: 1e-5)
                expectClose(Array(output[half...]), Array(offline[..<(noise.count - half)]), .absolute(1e-5), "window \(window), order \(order), derivative \(derivative), blocks of \(blockSize)")
            }
            // Whatever the edge mode, the stage is the offline function wherever the window
            // lies inside the signal: output n + half is offline n, for n from half on.
            for edge in [SavitzkyGolayEdge.interpolate, .mirror, .nearest, .constant(0.5), .wrap] where window <= noise.count {
                let output = try Pipeline { SavitzkyGolay(window: window, polynomialOrder: order, derivative: derivative, edge: edge) }.process(noise, format: format)
                let offline = try DSP.savitzkyGolay(noise, window: window, polynomialOrder: order, derivative: derivative, edge: edge)
                expectClose(Array(output[(2 * half)...]), Array(offline[half ..< (noise.count - half)]), .absolute(1e-5), "window \(window), \(edge), inside the signal")
            }
        }
    }

    @Test func theSavitzkyGolayStageIsACentredFilterWithItsLatency() throws {
        let stage = Pipeline { SavitzkyGolay(window: 11, polynomialOrder: 3, derivative: 1) }
        guard case .fir(let taps, let latency)? = try loweredKernels(stage).first else { Issue.record("an FIR kernel was due"); return }
        let coefficients = try DSP.savitzkyGolayCoefficients(window: 11, polynomialOrder: 3, derivative: 1)
        #expect(taps == coefficients.map { Float($0) } && latency == 5)
        let reported = try outputEnvironment(stage).latency
        #expect(reported == 5.0 / 48_000, "REAL-5: (window − 1) / 2 samples")
        // A ramp has the slope 1 per sample: the first derivative returns it, five samples late.
        let ramp = (0 ..< 64).map { Float($0) }
        let slope = try stage.process(ramp, format: format)
        expectClose(Array(slope[10...]), [Float](repeating: 1, count: 54), .absolute(1e-4))
        // Fluent ≡ builder; the stage has no continuous values; the edge is part of the value.
        #expect(Pipeline().savitzkyGolay(window: 11, polynomialOrder: 3, derivative: 1) == stage)
        #expect(Pipeline().savitzkyGolay(window: 11, polynomialOrder: 3, derivative: 1, edge: .mirror, isActive: false)
            == Pipeline { SavitzkyGolay(window: 11, polynomialOrder: 3, derivative: 1, edge: .mirror, isActive: false) })
        #expect(SavitzkyGolay(window: 11, polynomialOrder: 3).parameters.isEmpty)
        #expect(SavitzkyGolay(window: 11, polynomialOrder: 3, edge: .mirror) != SavitzkyGolay(window: 11, polynomialOrder: 3, edge: .nearest))
        #expect(SavitzkyGolay(window: 11, polynomialOrder: 3).edge == .interpolate && SavitzkyGolay(window: 11, polynomialOrder: 3).derivative == 0)
        // It fuses with a neighbouring FIR filter (F3), and it is switched off like any stage.
        #expect(try loweredKernels(Pipeline { SavitzkyGolay(window: 5, polynomialOrder: 2); Filter(FIRSystem { Taps([0.5, 0.5]) }) }).count == 1)
        #expect(try loweredKernels(Pipeline { SavitzkyGolay(window: 5, polynomialOrder: 2, isActive: false) }).isEmpty)
        // What makes no fit is rejected when the plan is compiled, with the stage's path.
        func rejected(_ stage: SavitzkyGolay) -> DSPError? { thrownError { _ = try Pipeline { Gain(.unity); stage }.process([0, 0], format: format) } }
        let even = rejected(SavitzkyGolay(window: 10, polynomialOrder: 3))
        #expect(even?.invalidParameterName == "window" && even?.stage?.description == "SavitzkyGolay[1]")
        #expect(rejected(SavitzkyGolay(window: 5, polynomialOrder: 5))?.invalidParameterName == "polynomialOrder")
        #expect(rejected(SavitzkyGolay(window: 5, polynomialOrder: 2, derivative: -1))?.invalidParameterName == "derivative")
        #expect(rejected(SavitzkyGolay(window: 5, polynomialOrder: 2, edge: .constant(.infinity)))?.invalidParameterName == "edge")
        // On a scalar track it smooths the track.
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 48) }.savitzkyGolay(window: 5, polynomialOrder: 0).emit(to: track).run(on: TestSignal.constant(1, count: 4_800), format: format)
        #expect(track.scalars.count == 100)
        expectClose(track.scalars[10].value, 1, .absolute(1e-6))
    }

    @Test func theAlphaBetaStageIsTheOfflineFunction() throws {
        let step = 1.0 / 48_000
        for (alpha, beta) in [(0.5, 0.1), (0.85, 0.005), (1.0, 0.0), (0.2, 0.02)] {
            for output in [AlphaBeta.Output.position, .velocity] {
                for blockSize in [1, 64, 512] {
                    let stage = Pipeline { AlphaBeta(alpha: alpha, beta: beta, initialPosition: 0.25, initialVelocity: -3, output: output) }
                    let tracked = try stage.process(noise, format: format, blockSize: blockSize)
                    let offline = try DSP.alphaBeta(noise, alpha: alpha, beta: beta, timeStep: step, initialPosition: 0.25, initialVelocity: -3, output: output)
                    let scale = Double(offline.map { abs($0) }.max() ?? 1)
                    let worst = Double(zip(tracked, offline).map { abs($0 - $1) }.max() ?? 0) / max(scale, 1)
                    Measurements.shared.record("WP-434 AlphaBeta stage against the offline function, relative to the largest output", worst, bound: 1e-6)
                    #expect(worst <= 1e-6, "alpha \(alpha), beta \(beta), \(output), blocks of \(blockSize): \(worst)")
                }
            }
        }
        // The offline function is the defining recurrence (Appendix A).
        var x = 0.0, v = 0.0
        let dt = Double(Float(step)), a = Double(Float(0.5)), b = Double(Float(0.1))
        let reference = noise.map { sample -> Float in
            let residual = Double(sample) - (x + dt * v)
            x = x + dt * v + a * residual
            v = v + b / dt * residual
            return Float(x)
        }
        #expect(try DSP.alphaBeta(noise, alpha: 0.5, beta: 0.1, timeStep: step) == reference)
        // With alpha 1 and beta 0 the position is the input.
        #expect(try Pipeline { AlphaBeta(alpha: 1, beta: 0) }.process(noise, format: format) == noise)
    }

    @Test func theTimeStepOfTheTrackerIsThatOfItsPosition() throws {
        // On a scalar track the step is the feature rate's: a ramp of 1 per value is a velocity of 100 per second at 100 values per second.
        let ramp = (0 ..< 48_000).map { Float($0 / 480) }
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 480) }.alphaBeta(alpha: 0.5, beta: 0.1, output: .velocity).emit(to: track).run(on: ramp, format: format)
        #expect(track.environment?.sampleRate == 100)
        expectClose(Double(try #require(track.scalars.last).value), 100, .relative(1e-2), "the velocity is per second")
        let offline = try DSP.alphaBeta((0 ..< 100).map { Float($0) }, alpha: 0.5, beta: 0.1, timeStep: 0.01, output: .velocity)
        expectClose(track.scalars.map(\.value), offline, .relative(1e-5))
        // Behind a decimator the step doubles.
        let halved = try Pipeline { Subsample(by: 2); AlphaBeta(alpha: 0.5, beta: 0.1, output: .velocity) }.process(noise, format: format)
        expectClose(halved, try DSP.alphaBeta(subsampled(noise, by: 2), alpha: 0.5, beta: 0.1, timeStep: 2.0 / 48_000, output: .velocity), .relative(1e-5))
        // Fluent ≡ builder; structure only; values that are no tracker.
        #expect(Pipeline().alphaBeta(alpha: 0.5, beta: 0.1) == Pipeline { AlphaBeta(alpha: 0.5, beta: 0.1) })
        #expect(Pipeline().alphaBeta(alpha: 0.5, beta: 0.1, initialPosition: 1, initialVelocity: 2, output: .velocity, isActive: false)
            == Pipeline { AlphaBeta(alpha: 0.5, beta: 0.1, initialPosition: 1, initialVelocity: 2, output: .velocity, isActive: false) })
        #expect(AlphaBeta(alpha: 0.5, beta: 0.1).parameters.isEmpty && AlphaBeta(alpha: 0.5, beta: 0.1).output == .position)
        #expect(AlphaBeta(alpha: 0.5, beta: 0.1) != AlphaBeta(alpha: 0.5, beta: 0.2))
        #expect(thrownError { _ = try Pipeline { AlphaBeta(alpha: .nan, beta: 0.1) }.process(noise, format: format) }?.invalidParameterName == "alpha")
        #expect(thrownError { _ = try Pipeline { AlphaBeta(alpha: 0.5, beta: 1e60) }.process(noise, format: format) }?.invalidParameterName == "beta")
        #expect(thrownError { _ = try DSP.alphaBeta(noise, alpha: 0.5, beta: 0.1, timeStep: 0) }?.invalidParameterName == "timeStep")
        #expect(thrownError { _ = try DSP.alphaBeta(noise, alpha: .infinity, beta: 0.1, timeStep: 1) }?.invalidParameterName == "alpha")
        #expect(try outputEnvironment(Pipeline { AlphaBeta(alpha: 0.5, beta: 0.1) }).latency == 0)
    }

    @Test func aThousandBlocksOfTheSmoothersAllocateNothing() async throws {
        let block = Array(noise[..<512])
        let on = StateBox(true)
        let rig = StageRig(blockSize: 512)
        let session = try await rig.start(Pipeline {
            SavitzkyGolay(window: 31, polynomialOrder: 3)
            SavitzkyGolay(window: 11, polynomialOrder: 2, derivative: 1, isActive: on.binding)
            AlphaBeta(alpha: 0.5, beta: 0.1)
            AlphaBeta(alpha: 0.85, beta: 0.005, output: .velocity, isActive: on.binding)
        })
        rig.feed(block)
        await rig.drain()
        try rig.auditAllocations(blocks: 1_000, of: block, "1 000 blocks through two Savitzky–Golay filters and two trackers")
        session.detach()
    }
}

/// WP-436, WP-438a, WP-438b. The four rate changers of §6.12.
@Suite("Rate changers (WP-436, WP-438a, WP-438b)")
struct RateStageTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 6_000, seed: 436)

    // MARK: Decimate (WP-436): ≡ filter-then-subsample; alias rejection ≥ 80 dB; downstream stages see the reduced rate

    @Test func decimationIsFilterThenSubsample() throws {
        for factor in [2, 3, 4, 8] {
            let taps = try DSP.rateChangeTaps(by: factor).map { Double(Float($0)) }
            let reference = subsampled(TapMeasure.convolved(noise, taps), by: factor)
            for blockSize in [64, 100, 512] {
                let output = try Pipeline { Decimate(by: factor) }.process(noise, format: format, blockSize: blockSize)
                let deviation = deviationInDecibels(output, reference)
                Measurements.shared.record("WP-436 Decimate against filter-then-subsample, dB", deviation, bound: -100)
                #expect(output.count == reference.count && deviation <= -100, "by \(factor), blocks of \(blockSize): \(deviation) dB")
            }
            // The offline function is the stage.
            #expect(try DSP.decimate(noise, by: factor) == Pipeline { Decimate(by: factor) }.process(noise, format: format))
        }
        // A factor of 1 is no stage at all.
        let none = try loweredKernels(Pipeline { Decimate(by: 1) }), unit = try DSP.rateChangeTaps(by: 1)
        #expect(none.isEmpty && unit == [1])
        #expect(try Pipeline { Decimate(by: 1) }.process(noise, format: format) == noise)
    }

    @Test func theDefaultFilterRejectsWhatWouldAliasByEightyDecibels() throws {
        for factor in [2, 3, 4, 8, 16] {
            let taps = try DSP.rateChangeTaps(by: factor)
            #expect(taps.count % (2 * factor) == 1, "by \(factor): \(taps.count) taps, a delay that is whole at both rates")
            #expect(FIRMath.asymmetry(of: taps).symmetric == 0)
            // The design: from the new Nyquist frequency up, at least 80 dB down; unity at 0 Hz;
            // the pass band, up to 0.8 of the new Nyquist frequency, within a hundredth of a decibel.
            let grid = TapMeasure.magnitudes(taps)
            let stop = TapMeasure.extremes(taps, from: 24_000 / Double(factor), to: 24_000, sampleRate: 48_000, grid: grid).greatest
            let pass = TapMeasure.extremes(taps, from: 0, to: 0.8 * 24_000 / Double(factor), sampleRate: 48_000, grid: grid)
            Measurements.shared.record("WP-436 default filter: rejection short of 80 dB from the new Nyquist frequency up (negative: surplus)", 80 + 20 * log10(stop), bound: 0)
            #expect(-20 * log10(stop) >= 80, "by \(factor): \(-20 * log10(stop)) dB")
            #expect(abs(20 * log10(pass.least)) < 0.01 && abs(20 * log10(pass.greatest)) < 0.01, "by \(factor): the pass band")
            expectClose(taps.reduce(0, +), 1.0, .absolute(1e-12), "unity gain at 0 Hz")
        }
        // On the running stage: a full-scale tone above the new Nyquist frequency comes out at
        // least 80 dB down, wherever it aliases to.
        for (factor, tone) in [(2, 12_500.0), (2, 17_000), (2, 23_000), (4, 6_100), (4, 9_000), (4, 20_000)] {
            let output = try Pipeline { Decimate(by: factor) }.process(TestSignal.sine(frequency: tone, sampleRate: 48_000, count: 24_000), format: format)
            let settled = output[(output.count / 2)...]
            let level = settled.map { abs($0) }.max() ?? 1
            Measurements.shared.record("WP-436 alias of a full-scale tone above the new Nyquist frequency, dB", Double(20 * log10(level)), bound: -80)
            #expect(20 * log10(level) <= -80, "by \(factor), \(tone) Hz: \(20 * log10(level)) dB")
        }
        // A tone in the pass band comes out at its own level.
        let passed = try Pipeline { Decimate(by: 4) }.process(TestSignal.sine(frequency: 3_000, sampleRate: 48_000, count: 24_000), format: format)
        expectClose(amplitude(of: passed[3_000...], at: 3_000, sampleRate: 12_000), 1.0, .absolute(1e-3))
        // Another rejection and another pass band are another filter.
        let deep = try DSP.rateChangeTaps(by: 4, rejection: .decibels(100), passband: 0.9)
        let deepStop = TapMeasure.extremes(deep, from: 6_000, to: 24_000, sampleRate: 48_000, grid: TapMeasure.magnitudes(deep)).greatest
        let plain = try DSP.rateChangeTaps(by: 4)
        #expect(-20 * log10(deepStop) >= 100 && deep.count > plain.count)
        guard case .decimator(_, let taps, _)? = try loweredKernels(Pipeline { Decimate(by: 4, rejection: .decibels(100), passband: 0.9) }).first else { Issue.record("a decimator was due"); return }
        #expect(taps == deep.map { Float($0) })
    }

    @Test func downstreamOfADecimatorTheRateIsTheReducedOne() throws {
        // ENV-1: the sample rate, the Nyquist frequency and the latency at the next stage.
        let sink = Collector<Samples>()
        try Pipeline { Decimate(by: 4) }.emit(to: sink).run(on: noise, format: format)
        let environment = try #require(sink.environment)
        let taps = try DSP.rateChangeTaps(by: 4)
        #expect(environment.sampleRate == 12_000 && environment.nyquistFrequency == 6_000)
        expectClose(environment.latency, Double((taps.count - 1) / 2) / 48_000, .absolute(1e-15), "(K − 1) / 2 input samples")
        #expect((taps.count - 1) / 2 % 4 == 0, "a whole number of output samples")
        #expect(sink.samples.count == 1_500)
        // O-16 at the reduced rate: 10 kHz is no cutoff at 12 kHz; 5 kHz is.
        #expect(thrownError { _ = try Pipeline { Decimate(by: 4); LowPass(.butterworth, cutoff: .hertz(10_000), order: 4) }.process(noise, format: format) }?.invalidParameterName == "cutoff")
        #expect(try Pipeline { Decimate(by: 4); LowPass(.butterworth, cutoff: .hertz(5_000), order: 4) }.process(noise, format: format).count == 1_500)
        // The same filter after the decimator is the filter designed for the reduced rate.
        let chained = try Pipeline { Decimate(by: 4); HighPass(.butterworth, cutoff: .hertz(300), order: 2) }.environment(\.biquadPrecision, .double).process(noise, format: format)
        let decimated = try Pipeline { Decimate(by: 4) }.process(noise, format: format)
        let reference = cascadeReference(decimated, try IIRDesign(.butterworth, .highPass(cutoff: 300), order: 2, domain: .digital(sampleRate: 12_000)).secondOrderSections.spreadingGain())
        expectClose(chained, reference, .deviationBelow(decibels: -120))
        // Fluent ≡ builder; no continuous values; what is no factor.
        #expect(Pipeline().decimate(by: 4) == Pipeline { Decimate(by: 4) })
        #expect(Pipeline().decimate(by: 4, rejection: .decibels(96), passband: 0.9, isActive: false) == Pipeline { Decimate(by: 4, rejection: .decibels(96), passband: 0.9, isActive: false) })
        #expect(Decimate(by: 4).parameters.isEmpty && Decimate(by: 4).rejection == .decibels(80) && Decimate(by: 4).passband == 0.8)
        func rejected(_ stage: Decimate) -> String? { thrownError { _ = try Pipeline { stage }.process(noise, format: format) }?.invalidParameterName }
        #expect(rejected(Decimate(by: 0)) == "factor" && rejected(Decimate(by: 5_000)) == "factor")
        #expect(rejected(Decimate(by: 2, rejection: .linear(0))) == "rejection" && rejected(Decimate(by: 2, passband: 1)) == "passband" && rejected(Decimate(by: 2, passband: 0)) == "passband")
    }

    @Test func aRateChangerThatIsSwitchedOffSuspendsWhatFollows() async throws {
        // ACT-3: the signal cannot pass a stage that changes the rate.
        let off = Collector<Samples>()
        try Pipeline { Decimate(by: 2, isActive: false) }.emit(to: off).run(on: noise, format: format)
        #expect(off.samples.isEmpty, "a constant `false` removes the rest of the branch (ACT-4)")
        // A bound switch: the branch resumes when the binding says so.
        let rig = StageRig(blockSize: 64)
        let on = StateBox(false)
        let sink = Collector<Samples>()
        let session = try await rig.start(Pipeline { Tap { Decimate(by: 2, isActive: on.binding); Emit(to: sink) } })
        rig.feed(Array(noise[..<1_280]))
        #expect(sink.samples.isEmpty)
        on.value = true
        await session.syncBindings()
        rig.feed(Array(noise[1_280 ..< 3_840]))
        #expect(!sink.samples.isEmpty && sink.environment?.sampleRate == 24_000)
        session.detach()
    }

    // MARK: Subsample and Upsample (WP-438a): ≡ the toolkit functions; the rates in the environment follow

    @Test func subsampleAndUpsampleAreTheToolkitFunctions() throws {
        for factor in [1, 2, 3, 7] {
            for blockSize in [1, 64, 100, 512] {
                for phase in [0, 1, factor - 1, factor + 1, -1] {
                    let output = try Pipeline { Subsample(by: factor, phase: phase) }.process(noise, format: format, blockSize: blockSize)
                    #expect(output == subsampled(noise, by: factor, phase: phase), "Subsample by \(factor), phase \(phase), blocks of \(blockSize)")
                }
                #expect(try Pipeline { Upsample(by: factor) }.process(noise, format: format, blockSize: blockSize) == upsampled(noise, by: factor),
                        "Upsample by \(factor), blocks of \(blockSize)")
                // Up, then down by the same factor: the identity, bit for bit.
                #expect(try Pipeline { Upsample(by: factor); Subsample(by: factor) }.process(noise, format: format, blockSize: blockSize) == noise)
            }
        }
        // The rates in the environment follow (ENV-1); neither adds latency.
        let down = Collector<Samples>(), up = Collector<Samples>(), both = Collector<Samples>()
        try Pipeline { Subsample(by: 3) }.emit(to: down).run(on: noise, format: format)
        try Pipeline { Upsample(by: 4) }.emit(to: up).run(on: noise, format: format)
        try Pipeline { Upsample(by: 3); Subsample(by: 2) }.emit(to: both).run(on: noise, format: format)
        #expect(down.environment?.sampleRate == 16_000 && down.environment?.latency == 0 && down.samples.count == 2_000)
        #expect(up.environment?.sampleRate == 192_000 && up.environment?.latency == 0 && up.samples.count == 24_000)
        #expect(both.environment?.sampleRate == 72_000 && both.samples.count == 9_000)
        // A cutoff that is legal behind the upsampler is not legal in front of it.
        #expect(try Pipeline { Upsample(by: 2); LowPass(.butterworth, cutoff: .hertz(30_000), order: 2) }.process(noise, format: format).count == 12_000)
        #expect(thrownError { _ = try Pipeline { LowPass(.butterworth, cutoff: .hertz(30_000), order: 2); Upsample(by: 2) }.process(noise, format: format) }?.invalidParameterName == "cutoff")
        // Fluent ≡ builder; kernels; no continuous values; what is no factor.
        #expect(Pipeline().subsample(by: 3) == Pipeline { Subsample(by: 3) } && Pipeline().subsample(by: 3, phase: 2, isActive: false) == Pipeline { Subsample(by: 3, phase: 2, isActive: false) })
        #expect(Pipeline().upsample(by: 3) == Pipeline { Upsample(by: 3) } && Pipeline().upsample(by: 3, isActive: false) == Pipeline { Upsample(by: 3, isActive: false) })
        #expect(try loweredKernels(Pipeline { Subsample(by: 3, phase: 5) }) == [.subsample(factor: 3, phase: 2)])
        #expect(try loweredKernels(Pipeline { Upsample(by: 3) }) == [.zeroStuff(factor: 3)])
        #expect(try loweredKernels(Pipeline { Subsample(by: 1); Upsample(by: 1) }).isEmpty)
        #expect(Subsample(by: 3).parameters.isEmpty && Upsample(by: 3).parameters.isEmpty && Subsample(by: 3).phase == 0)
        for wrong in [0, -2, 4_097] {
            #expect(thrownError { _ = try Pipeline { Subsample(by: wrong) }.process(noise, format: format) }?.invalidParameterName == "factor")
            #expect(thrownError { _ = try Pipeline { Upsample(by: wrong) }.process(noise, format: format) }?.invalidParameterName == "factor")
        }
        // On a scalar track: every second value.
        let track = Collector<Scalar>()
        try Pipeline { MeanTrack(hop: 480) }.subsample(by: 2).emit(to: track).run(on: noise, format: format)
        #expect(track.environment?.sampleRate == 50 && track.scalars.count == 6)
    }

    // MARK: Interpolate (WP-438b): image rejection ≥ 80 dB; Interpolate after Decimate restores a band-limited fixture to SNR ≥ 80 dB

    @Test func interpolationIsZeroStuffingThenTheFilterWithGainTheFactor() throws {
        for factor in [2, 3, 4] {
            let taps = try DSP.rateChangeTaps(by: factor).map { Double(Float($0)) }
            let reference = TapMeasure.convolved(upsampled(noise, by: factor), taps).map { $0 * Double(factor) }
            for blockSize in [64, 100, 512] {
                let output = try Pipeline { Interpolate(by: factor) }.process(noise, format: format, blockSize: blockSize)
                let deviation = deviationInDecibels(output, reference)
                Measurements.shared.record("WP-438b Interpolate against zero-stuff-then-filter, dB", deviation, bound: -100)
                #expect(output.count == noise.count * factor && deviation <= -100, "by \(factor), blocks of \(blockSize): \(deviation) dB")
            }
            #expect(try DSP.interpolate(noise, by: factor) == Pipeline { Interpolate(by: factor) }.process(noise, format: format))
            // A constant comes out at its own level.
            let constant = try Pipeline { Interpolate(by: factor) }.process(TestSignal.constant(0.5, count: 2_000), format: format)
            expectClose(Array(constant[(constant.count / 2)...]), [Float](repeating: 0.5, count: constant.count - constant.count / 2), .absolute(1e-4))
        }
        #expect(try loweredKernels(Pipeline { Interpolate(by: 1) }).isEmpty)
        // The rate and the latency downstream (ENV-1, REAL-5): (K − 1) / 2 output samples, a whole number of input samples.
        let sink = Collector<Samples>()
        try Pipeline { Interpolate(by: 4) }.emit(to: sink).run(on: noise, format: format)
        let taps = try DSP.rateChangeTaps(by: 4)
        #expect(sink.environment?.sampleRate == 192_000 && sink.samples.count == 24_000)
        expectClose(try #require(sink.environment?.latency), Double(taps.count - 1) / 2 / 192_000, .absolute(1e-15))
        guard case .interpolator(4, _, let latency)? = try loweredKernels(Pipeline { Interpolate(by: 4) }).first else { Issue.record("an interpolator was due"); return }
        #expect(latency * 8 == taps.count - 1)
        // Fluent ≡ builder; no continuous values; what is no factor.
        #expect(Pipeline().interpolate(by: 4) == Pipeline { Interpolate(by: 4) })
        #expect(Pipeline().interpolate(by: 4, rejection: .decibels(96), passband: 0.9, isActive: false) == Pipeline { Interpolate(by: 4, rejection: .decibels(96), passband: 0.9, isActive: false) })
        #expect(Interpolate(by: 4).parameters.isEmpty && Interpolate(by: 4).rejection == .decibels(80) && Interpolate(by: 4).passband == 0.8)
        #expect(thrownError { _ = try Pipeline { Interpolate(by: 0) }.process(noise, format: format) }?.invalidParameterName == "factor")
        #expect(thrownError { _ = try Pipeline { Interpolate(by: 2, passband: 1.5) }.process(noise, format: format) }?.invalidParameterName == "passband")
    }

    @Test func theImagesOfAnInterpolatedToneAreEightyDecibelsDown() throws {
        // A tone at f comes out at f, and its images, at k·fs ± f, at least 80 dB below it.
        for (factor, tone) in [(2, 1_000.0), (2, 9_000), (2, 19_000), (4, 3_000), (4, 15_000), (3, 18_000)] {
            let rate = 48_000 * Double(factor)
            let output = try Pipeline { Interpolate(by: factor) }.process(TestSignal.sine(frequency: tone, sampleRate: 48_000, count: 9_600), format: format)
            let settled = output[(output.count / 2)...]
            let level = amplitude(of: settled, at: tone, sampleRate: rate)
            expectClose(level, 1.0, .absolute(2e-3), "by \(factor), \(tone) Hz: the tone itself")
            var worst = 0.0
            for image in 1 ..< factor {
                for frequency in [48_000 * Double(image) - tone, 48_000 * Double(image) + tone] where frequency < rate / 2 {
                    worst = max(worst, amplitude(of: settled, at: frequency, sampleRate: rate) / level)
                }
            }
            if factor % 2 == 0 { worst = max(worst, amplitude(of: settled, at: rate / 2 - tone, sampleRate: rate) / level) }
            Measurements.shared.record("WP-438b image of an interpolated tone, dB below the tone (negative: more than 80)", 80 + 20 * log10(max(worst, 1e-12)), bound: 0)
            #expect(20 * log10(max(worst, 1e-12)) <= -80, "by \(factor), \(tone) Hz: images at \(20 * log10(worst)) dB")
        }
    }

    @Test func interpolationAfterDecimationRestoresABandLimitedSignal() throws {
        // A fixture inside the pass band of both filters: twelve sines below three quarters of
        // the reduced Nyquist frequency.
        for factor in [2, 3, 4, 8] {
            var generator = SeededGenerator(seed: UInt64(438 + factor))
            var fixture = [Float](repeating: 0, count: 48_000)
            let top = 0.75 * 24_000 / Double(factor)
            for _ in 0 ..< 12 {
                let frequency = top * (0.02 + 0.98 * generator.nextUnit()), phase = 2 * Double.pi * generator.nextUnit()
                for index in fixture.indices { fixture[index] += Float(sin(2 * .pi * frequency * Double(index) / 48_000 + phase) / 12) }
            }
            let pipeline = Pipeline { Decimate(by: factor); Interpolate(by: factor) }
            let output = try pipeline.process(fixture, format: format)
            // The delay of the pair is whole and is what the environment reports.
            let delay = Int((try outputEnvironment(pipeline).latency * 48_000).rounded())
            let length = try DSP.rateChangeTaps(by: factor).count
            #expect(delay == length - 1)
            var signal = 0.0, error = 0.0
            for index in (4 * delay) ..< (output.count - delay) {
                let expected = Double(fixture[index - delay])
                signal += expected * expected
                error += (Double(output[index]) - expected) * (Double(output[index]) - expected)
            }
            let ratio = 10 * log10(signal / error)
            Measurements.shared.record("WP-438b Interpolate after Decimate, SNR short of 80 dB (negative: surplus)", 80 - ratio, bound: 0)
            #expect(ratio >= 80, "by \(factor): SNR \(ratio) dB")
        }
    }

    @Test func aThousandBlocksOfTheRateChangersAllocateNothing() async throws {
        let block = Array(noise[..<512])
        let rig = StageRig(blockSize: 512)
        let session = try await rig.start(Pipeline {
            Decimate(by: 4)
            Interpolate(by: 2)
            Upsample(by: 3)
            Subsample(by: 3, phase: 1)
            Tap { Subsample(by: 2); Upsample(by: 2); Decimate(by: 2) }
        })
        rig.feed(block)
        await rig.drain()
        try rig.auditAllocations(blocks: 1_000, of: block, "1 000 blocks through the four rate changers")
        session.detach()
    }
}

/// STG-1, RT-7: every stock pipeline runs 10 000 blocks inside the allocation audit.
@Suite("A pipeline of every sequence stage of the target")
struct StockPipelineAuditTests {
    @Test func tenThousandBlocksOfALiveSessionAllocateNothing() async throws {
        let noise = TestSignal.whiteNoise(count: 512, seed: 10_000)
        let on = StateBox(true)
        let rig = StageRig(blockSize: 512)
        let pipeline = Pipeline {
            Gain(.decibels(-3))
            HighPass(.butterworth, cutoff: .hertz(90), order: 4)
            BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 2, isActive: on.binding)
            LowShelf(midpoint: .hertz(200), gain: .decibels(3))
            HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3))
            MatchedPeak(center: .hertz(12_000), gain: .decibels(2), bandwidth: .q(2))
            Filter(IIRSystem { Zero(onUnitCircleAt: .hertz(50)); Pole(radius: 0.985, frequency: .hertz(50)) })
            LowPass(.windowedSinc(), cutoff: .hertz(8_000), length: 127)
            Filter(FIRSystem { Taps([0.25, 0.5, 0.25]) }, isActive: on.binding)
            BandPass(.windowedSinc(), from: .hertz(100), to: .hertz(10_000), length: 1_025)
            BandStop(.chebyshev2(stopband: .decibels(40)), from: .hertz(900), to: .hertz(1_100), order: 2)
            SavitzkyGolay(window: 11, polynomialOrder: 3)
            AlphaBeta(alpha: 0.9, beta: 0.01)
            Decimate(by: 2)
            Subsample(by: 2)
            Upsample(by: 2)
            Interpolate(by: 2)
            Gain(.decibels(3))
        }
        let session = try await rig.start(pipeline)
        rig.feed(noise)
        await rig.drain()
        try rig.auditAllocations(blocks: 10_000, of: noise, "10⁴ blocks through every sequence stage of the target")
        session.detach()
    }
}
