import Accelerate
import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Plans made of the stock kernels (WP-308, WP-309, WP-311a, WP-313, WP-324, WP-330b, the M2
/// exit test): what a stage that lowers to a stock spec gets.
@Suite("Stock kernels in a plan")
struct StockKernelTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 4_096, seed: 31)
    let section = BiquadSection(b0: 0.2, b1: 0.4, b2: 0.2, a1: -0.3, a2: 0.1)

    /// The recurrence of a biquad cascade in double precision, rounded to Float32 at the end.
    private func cascade(_ input: [Float], _ sections: [BiquadSection]) -> [Float] {
        var signal = input.map(Double.init)
        for section in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for index in signal.indices {
                let x = signal[index]
                let y = section.b0 * x + section.b1 * x1 + section.b2 * x2 - section.a1 * y1 - section.a2 * y2
                (x2, x1, y2, y1) = (x1, x, y1, y)
                signal[index] = y
            }
        }
        return signal.map { Float($0) }
    }

    private func convolved(_ input: [Float], _ taps: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for n in input.indices {
            var sum = 0.0
            for (k, tap) in taps.enumerated() where n - k >= 0 { sum += Double(tap) * Double(input[n - k]) }
            output[n] = Float(sum)
        }
        return output
    }

    private func lowPassTaps(_ count: Int, cutoff: Double = 0.2) -> [Float] {
        (0 ..< count).map { index in
            let m = Double(index) - Double(count - 1) / 2
            let ideal = m == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * m) / (.pi * m)
            return Float(ideal * (0.54 - 0.46 * cos(2 * .pi * Double(index) / Double(count - 1))))
        }
    }

    // MARK: The emitted plan runs the fixtures (WP-311a)

    @Test func biquadCascadesMatchTheRecurrence() throws {
        let reference = cascade(noise, [section, section, section])
        for precision in [BiquadPrecision.single, .double] {
            for blockSize in [1, 3, 64, 512] {
                let output = try Pipeline { TestBiquad(section, count: 3, precision: precision) }.process(noise, format: format, blockSize: blockSize)
                expectClose(output, reference, precision == .double ? .absolute(1e-6) : .deviationBelow(decibels: -95), "\(precision), blocks of \(blockSize)")
            }
        }
        let stereo = try Pipeline { TestBiquad(section, count: 2) }
            .process(channels: [noise, noise.reversed()], format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        expectClose(stereo[0], cascade(noise, [section, section]), .deviationBelow(decibels: -95))
        expectClose(stereo[1], cascade(noise.reversed(), [section, section]), .deviationBelow(decibels: -95), "each channel has its own memory")
        let wide = try Pipeline { TestBiquad(section) }.process(channels: [[Float]](repeating: noise, count: 4), format: SignalFormat(sampleRate: 48_000, channelCount: 4))
        for channel in wide { expectClose(channel, cascade(noise, [section]), .deviationBelow(decibels: -95), "one setup for many channels") }
    }

    @Test func firFiltersMatchTheConvolutionDirectAndPartitioned() throws {
        for count in [1, 31, 255, 257, 1_025] {
            let taps = lowPassTaps(max(count, 2)).prefix(count).map { $0 }
            let reference = convolved(noise, taps)
            for blockSize in [64, 512, 100] {
                let output = try Pipeline { TestFIR(taps) }.process(noise, format: format, blockSize: blockSize)
                expectClose(output, reference, .deviationBelow(decibels: -100), "\(count) taps, blocks of \(blockSize)")
            }
        }
        // The implementation follows the table: direct below the crossover, partitioned from it on (SEL-3, REAL-4).
        let forcedDirect = try Pipeline { TestFIR(lowPassTaps(1_025)) }.environment(\.implementation, .native).process(noise, format: format)
        let automatic = try Pipeline { TestFIR(lowPassTaps(1_025)) }.process(noise, format: format)
        expectClose(automatic, forcedDirect, .deviationBelow(decibels: -100))
        #expect(automatic != forcedDirect, "the two implementations round differently: both ran")
        #expect(throws: DSPError.self) { try Pipeline { TestFIR([]) }.process(noise, format: format) }
        #expect(throws: DSPError.self) { try Pipeline { TestFIR([1, .nan]) }.process(noise, format: format) }
    }

    @Test func rateChangersMatchFilterThenResample() throws {
        let taps = lowPassTaps(63, cutoff: 0.1)
        let filtered = convolved(noise, taps)
        let decimated = try Pipeline { TestDecimate(factor: 3, taps: taps) }.process(noise, format: format, blockSize: 100)
        expectClose(decimated, subsampled(filtered, by: 3), .deviationBelow(decibels: -100))
        #expect(try Pipeline { TestSubsample(by: 4) }.process(noise, format: format, blockSize: 100) == subsampled(noise, by: 4))
        #expect(try Pipeline { TestZeroStuff(factor: 3) }.process(noise, format: format, blockSize: 100) == upsampled(noise, by: 3))
        let interpolated = try Pipeline { TestInterpolate(factor: 2, taps: taps) }.process(noise, format: format, blockSize: 100)
        expectClose(interpolated, convolved(upsampled(noise, by: 2), taps).map { $0 * 2 }, .deviationBelow(decibels: -100))
        // The environment downstream of a rate change is the new rate's (ENV-1).
        let sink = CollectingSink<Samples>()
        try Pipeline { TestDecimate(factor: 3, taps: taps) }.emit(to: sink).run(on: noise, format: format)
        #expect(sink.environment?.sampleRate == 16_000)
        #expect(throws: DSPError.self) { try Pipeline { TestDecimate(factor: 0, taps: taps) }.process(noise, format: format) }
    }

    @Test func trackersAndChannelGains() throws {
        let alpha: Float = 0.5, beta: Float = 0.1
        let tracked = try Pipeline { TestTracker(alpha: alpha, beta: beta) }.process(noise, format: format)
        var x = 0.0, v = 0.0
        let dt = Double(Float(1.0 / 48_000))
        let reference = noise.map { sample -> Float in
            let residual = Double(sample) - (x + dt * v)
            x = x + dt * v + Double(alpha) * residual
            v = v + Double(beta) / dt * residual
            return Float(x)
        }
        expectClose(tracked, reference, .absolute(1e-6))
        let scaled = try Pipeline { TestChannelGains(factors: [2, -1]) }
            .process(channels: [noise, noise], format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        #expect(scaled[0] == noise.map { $0 * 2 } && scaled[1] == noise.map { -$0 })
        #expect(throws: DSPError.self) { try Pipeline { TestChannelGains(factors: [2]) }.process(channels: [noise, noise], format: SignalFormat(sampleRate: 48_000, channelCount: 2)) }
    }

    // MARK: Fusion (WP-308, WP-309)

    @Test func adjacentCascadesFuseIntoOneAndStayBitIdentical() throws {
        let other = BiquadSection(b0: 0.5, b1: -0.2, b2: 0.1, a1: 0.4, a2: 0.2)
        let fused = Pipeline { TestBiquad(section, count: 2); TestBiquad(other, count: 2) }
        let unfused = Pipeline { TestBiquad(section, count: 2); TestBarrier(); TestBiquad(other, count: 2) }
        let lowered = try PlanCompiler(crossovers: .shipped).lower(fused.stages, environment: DSPEnvironment(), blockSize: 512)
        #expect(IRStep.kernels(of: lowered.steps).count == 1, "one cascade is emitted (F2)")
        for blockSize in [64, 512] {
            #expect(try fused.process(noise, format: format, blockSize: blockSize) == unfused.process(noise, format: format, blockSize: blockSize),
                    "fused ≡ unfused, bit for bit, in blocks of \(blockSize)")
        }
        // Cascades of different precision are two kernels.
        let mixed = try PlanCompiler(crossovers: .shipped).lower(
            Pipeline { TestBiquad(section); TestBiquad(other, precision: .double) }.stages, environment: DSPEnvironment(), blockSize: 512)
        #expect(IRStep.kernels(of: mixed.steps).count == 2)
    }

    @Test func adjacentFIRFiltersFuseBelowTheCrossover() throws {
        let a = lowPassTaps(63), b = lowPassTaps(101, cutoff: 0.3)
        let fused = Pipeline { TestFIR(a); TestFIR(b) }
        let unfused = Pipeline { TestFIR(a); TestBarrier(); TestFIR(b) }
        let lowered = try PlanCompiler(crossovers: .shipped).lower(fused.stages, environment: DSPEnvironment(), blockSize: 512)
        let kernels = IRStep.kernels(of: lowered.steps)
        guard kernels.count == 1, case .fir(let taps, let latency) = kernels[0].spec else { Issue.record("one kernel was due (F3)"); return }
        #expect(taps.count == 163 && latency == 31 + 50)
        expectClose(try fused.process(noise, format: format), try unfused.process(noise, format: format), .deviationBelow(decibels: -100))
        // The combined length stays under the direct / partitioned crossover, or nothing is fused.
        let long = try PlanCompiler(crossovers: .shipped).lower(
            Pipeline { TestFIR(lowPassTaps(200)); TestFIR(lowPassTaps(101)) }.stages, environment: DSPEnvironment(), blockSize: 512)
        #expect(IRStep.kernels(of: long.steps).count == 2, "200 + 101 − 1 taps reach the crossover of 256")
    }

    // MARK: Bound switches on stock kernels (WP-330b, ACT-7, ACT-8)

    @Test func aSwitchedFilterWithLatencyKeepsTheSignalAligned() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let taps = lowPassTaps(63)
        let session = try await rig.engine.attach(Pipeline { TestFIR(taps, isActive: on.binding) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        #expect(session.environment.latency == 31.0 / 48_000)
        let sine = Click.probeSignal(count: 64 * 120)
        rig.feed(Array(sine[..<(64 * 40)]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 40) ..< (64 * 80)]))
        #expect(session.environment.latency == 31.0 / 48_000, "switching never changes the session's latency (ACT-8)")
        // Bypassed, the signal passes delayed by the stage's latency: the unprocessed path is a delay line.
        #expect(Array(probe.samples[(64 * 60) ..< (64 * 80)]) == Array(sine[(64 * 60 - 31) ..< (64 * 80 - 31)]))
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 80)...]))
        let filtered = convolved(sine, taps)
        expectClose(Array(probe.samples[(64 * 100)...]), Array(filtered[(64 * 100)...]), .deviationBelow(decibels: -100),
                    "back on, the stage is pre-rolled and faded in; then the output is the filter's")
        let off = Click.measure(probe.samples, change: (64 * 40) ..< (64 * 50), settle: 64)
        let back = Click.measure(probe.samples, change: (64 * 80) ..< (64 * 92), settle: 64)
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
    }

    // MARK: The M2 exit test, on a session: a plan of stock kernels survives a change around it

    @Test func stockKernelsKeepTheirStateAcrossAPlanChange() async throws {
        func run(changing: Bool) async throws -> [Float] {
            let rig = Rig()
            let extra = CollectingSink<Samples>()
            let chain = Pipeline { TestGain(0.5); TestBiquad(section, count: 4); TestFIR(lowPassTaps(63)) }
            let session = try await rig.engine.attach(chain, to: rig.source)
            let probe = OutputProbe()
            rig.engine.core.addProbe(probe, to: session.core)
            try session.start()
            rig.feed(Array(noise[..<2_048]))
            if changing { try await session.update(chain.tap { $0.emit(to: extra) }) }
            rig.feed(Array(noise[2_048...]))
            if changing { #expect(extra.samples == Array(probe.samples[2_048...]) && session.core.generation == 2) }
            return probe.samples
        }
        #expect(try await run(changing: true) == run(changing: false), "gain, cascade and FIR are moved into the new plan with their state (SWAP-1)")
    }

    // MARK: Values on a running session (WP-313)

    @Test func aCutoffSweptOneOctaveMakesNoClickAndAllocatesNothing() async throws {
        let rig = Rig(blockSize: 64)
        let session = try await rig.engine.attach(Pipeline { TestCookbookLowPass(cutoff: 2_000) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        let sine = Click.probeSignal(count: 480 * 60)
        rig.feed(Array(sine[..<(480 * 10)]))
        let plan = session.core.plan
        // One octave down in 40 steps of 10 ms.
        for step in 1 ... 40 {
            try await session.update(Pipeline { TestCookbookLowPass(cutoff: 2_000 * pow(0.5, Double(step) / 40)) })
            rig.feed(Array(sine[(480 * (9 + step)) ..< (480 * (10 + step))]))
        }
        rig.feed(Array(sine[(480 * 50)...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "forty value updates and no new plan")
        let click = Click.measure(probe.samples, change: (480 * 10) ..< (480 * 51), settle: 480)
        #expect(click.passes, "CLICK-1 over the sweep: \(click)")
        let settled = try Pipeline { TestCookbookLowPass(cutoff: 1_000) }.process(sine, format: format, blockSize: 64)
        expectClose(Array(probe.samples[(480 * 56)...]), Array(settled[(480 * 56)...]), .deviationBelow(decibels: -80), "the filter kept its memory and ended at the new cutoff")

        // The analysis side of a value update allocates nothing: commands are applied from memory the control side owns.
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [[Float](repeating: 0.25, count: 64)])
        var cutoff = 1_000.0
        for _ in 0 ..< 50 {
            cutoff *= 1.01
            try await session.update(Pipeline { TestCookbookLowPass(cutoff: cutoff) })
            expectNoAllocations {
                rig.source.write(block.block())
                _ = runner.turn(now: 0)
            }
        }
    }

    // MARK: The allocation audit and the overhead budget (WP-324, §5.7)

    @Test func tenThousandBlocksOfALiveSessionAllocateNothing() async throws {
        let rig = Rig(blockSize: 512)
        let feed = HeatmapFeed(history: 64)
        let level = StateBox(Float(0))
        let on = StateBox(true)
        let stream = FeatureStream<Samples>(capacity: 8)
        let pipeline = Pipeline {
            TestGain(0.5)
            TestBiquad(section, count: 4)
            TestBiquad(section, count: 4, isActive: on.binding)
            TestFIR(lowPassTaps(63))
            TestGain(1.5)
        }
        .tap { $0.testFramer(frame: 1_024, hop: 256).testMagnitude().emit(to: feed).appending(TestMean()).emit(to: level.binding) }
        .emit(to: stream)
        let session = try await rig.engine.attach(pipeline, to: rig.source)
        try session.start()
        await rig.drain()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [Array(noise[..<512])])
        expectNoAllocations("10⁴ blocks through gain, two cascades, an FIR, a framer, a feed, a result slot and a stream") {
            var count = 0
            while count < 10_000 {
                rig.source.write(block.block())
                _ = runner.turn(now: 0)
                count += 1
            }
        }
        #expect(feed.columnCount == 64 && stream.droppedFrames > 0)
        session.detach()
    }
}
