import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// The `Convolve` stage of the design target (WP-516). Its acceptance, "≡ one-shot
/// convolution", lives here because the one-shot function does.
@Suite("Convolve stage")
struct ConvolveStageTests {
    private let noise = TestSignal.whiteNoise(count: 4_000, seed: 516, amplitude: 0.5)

    /// A kernel of `count` taps of seeded noise with about unit energy.
    private func kernel(_ count: Int) -> [Float] {
        TestSignal.whiteNoise(count: count, seed: UInt64(1_000 + count)).map { $0 / Float(count).squareRoot() }
    }

    // MARK: ≡ one-shot convolution (WP-516)

    @Test(arguments: [1, 2, 5, 64, 255, 256, 700])
    func theStageEqualsTheOneShotConvolution(taps: Int) throws {
        let h = kernel(taps)
        let full = try DSP.convolve(noise, h, strategy: .direct)
        // The stream, and room for the tail of the kernel: N + K − 1 samples in and out.
        let input = noise + [Float](repeating: 0, count: taps - 1)
        var worst = 0.0
        let peak = Double(full.map { abs($0) }.max() ?? 1)
        for strategy in ConvolutionStrategy.allCases {
            for blockSize in [512, 64, 441] {
                let output = try Pipeline { Convolve(kernel: h, strategy: strategy) }.process(input, format: mono48, blockSize: blockSize)
                #expect(output.count == full.count, "\(taps) taps, \(strategy), blocks of \(blockSize)")
                expectClose(output, full, .relativeToMaximum(1e-5), "\(taps) taps, \(strategy), blocks of \(blockSize)")
                for (a, b) in zip(output, full) { worst = max(worst, abs(Double(a) - Double(b)) / peak) }
            }
        }
        print("measured WP-516: Convolve of \(taps) taps against DSP.convolve, of the largest output: \(worst) (tolerance 1e-5, −100 dB)")
        // After N samples the stage has given the first N values of the full convolution.
        let head = try Pipeline { Convolve(kernel: h) }.process(noise, format: mono48)
        expectClose(head, Array(full[..<noise.count]), .relativeToMaximum(1e-5))
        // The automatic one-shot method, whichever it is here, is the same convolution.
        expectClose(try Pipeline { Convolve(kernel: h) }.process(input, format: mono48), try DSP.convolve(noise, h), .relativeToMaximum(1e-5))
    }

    @Test func aFeatureRateSequenceIsConvolvedValueByValue() throws {
        let track: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.004, hop: 0.001) }.process(noise, format: mono48)
        let smoothed: [ScalarFrame] = try Pipeline { Level(.rms, window: 0.004, hop: 0.001); Convolve(kernel: [0.25, 0.5, 0.25]) }.process(noise, format: mono48)
        let expected = try DSP.convolve(track.map { $0.value }, [0.25, 0.5, 0.25], strategy: .direct)
        #expect(smoothed.count == track.count && track.count == 80)
        expectClose(smoothed.map { $0.value }, Array(expected[..<track.count]), .absolute(1e-4), "a scalar track is a sampled sequence (O-1)")
        #expect(smoothed.allSatisfy { $0.confidence == 1 }, "the confidence of a measurement stays its own")
        #expect(Pipeline().level(.rms).convolve(kernel: [1, 1]) == Pipeline { Level(.rms); Convolve(kernel: [1, 1]) })
    }

    // MARK: The strategy

    @Test func theStrategyNamesTheKernel() throws {
        let short = kernel(31), long = kernel(300)
        // Automatic: the plan's own FIR, direct below the crossover length and partitioned from it on (REAL-4).
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: short) }) == [.fir(taps: short, latency: 0)])
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: long) }) == [.fir(taps: long, latency: 0)])
        // A choice the table agrees with is the same kernel.
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: short, strategy: .direct) }) == [.fir(taps: short, latency: 0)])
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: long, strategy: .partitioned) }) == [.fir(taps: long, latency: 0)])
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: long, strategy: .fft) }) == [.fir(taps: long, latency: 0)], "on a stream the FFT method is the partitioned kernel")

        // A choice against the table is a kernel made by name: the partitioned one for a short
        // kernel, the direct one for a long kernel.
        func forced(_ pipeline: Pipeline<Samples, Samples>, crossovers: CrossoverTable = .shipped) throws -> CustomKernel {
            guard case .custom(let kernel)? = try loweredKernelSpecs(pipeline, crossovers: crossovers).first else {
                throw DSPError.unsupportedConfiguration(reason: "a kernel made by name was due")
            }
            return kernel
        }
        func partitions(_ custom: CustomKernel, blockSize: Int = 512) -> Int {
            var made = custom.make(1, 48_000, blockSize)
            defer { ztd_kernel_destroy(&made) }
            return Int(ztd_partitioned_spectrum(&made, 0, nil, nil))
        }
        let partitionedShort = try forced(Pipeline { Convolve(kernel: short, strategy: .partitioned) })
        #expect(partitionedShort.name == "Convolve" && partitionedShort.latencyFrames == 0 && partitionedShort.interpolation == 1 && partitionedShort.decimation == 1)
        #expect(partitions(partitionedShort) == 1, "31 taps in one partition of 512: the partitioned kernel")
        #expect(partitions(try forced(Pipeline { Convolve(kernel: short, strategy: .fft) })) == 1)
        let directLong = try forced(Pipeline { Convolve(kernel: long, strategy: .direct) })
        #expect(directLong.name == "Convolve" && partitions(directLong) == 0, "not a partitioned kernel: the direct one")
        let again = try forced(Pipeline { Convolve(kernel: short, strategy: .partitioned) })
        #expect(partitionedShort != directLong && partitionedShort == again, "equal stages are one kernel: an update keeps its state (SWAP-1)")
        // The partition is the largest power of two the block holds, so no latency is added.
        #expect(partitions(try forced(Pipeline { Convolve(kernel: long, strategy: .partitioned) }, crossovers: CrossoverTable(firPartitioned: 1_000)), blockSize: 64) == 5)
        #expect(Convolve.partition(forBlocksOf: 512) == 512 && Convolve.partition(forBlocksOf: 441) == 256 && Convolve.partition(forBlocksOf: 1) == 8)
        #expect(Convolve.partition(forBlocksOf: 1 << 22) == 1 << 20)

        // The crossover is the table's, and the environment may force either side (SEL-2).
        let low = CrossoverTable(firPartitioned: 16)
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: short) }, crossovers: low) == [.fir(taps: short, latency: 0)])
        #expect(partitions(try forced(Pipeline { Convolve(kernel: short, strategy: .direct) }, crossovers: low)) == 0, "31 taps are past a crossover of 16: direct is now the choice against the table")
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: short, strategy: .partitioned) }.environment(\.implementation, .accelerate))
            == [.fir(taps: short, latency: 0)], "forced partitioned by the environment, the plan's FIR is already the kernel asked for")
        #expect(partitions(try forced(Pipeline { Convolve(kernel: long, strategy: .direct) }.environment(\.implementation, .accelerate))) == 0)
    }

    @Test func adjacentKernelsFuseAndAnIdentityIsRemoved() throws {
        // F3: two direct kernels in series are their convolution.
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: [1, 1]); Convolve(kernel: [1, -1]) }) == [.fir(taps: [1, 0, -1], latency: 0)])
        let fused = try Pipeline { Convolve(kernel: [1, 1]); Convolve(kernel: [1, -1]) }.process(noise, format: mono48)
        expectClose(fused, Array(try DSP.convolve(noise, [1, 0, -1])[..<noise.count]), .absolute(1e-6))
        // F4: the single tap 1 is no stage at all.
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: [1]) }).isEmpty)
        #expect(try Pipeline { Convolve(kernel: [1]) }.process(noise, format: mono48) == noise)
        // A kernel made by name is a fusion barrier (EXT-2).
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: [1, 1]); Convolve(kernel: [1, -1], strategy: .partitioned) }).count == 2)
        // No latency is declared, and the rate is kept.
        let environment = try environmentAtTheEnd(of: Pipeline { Convolve(kernel: kernel(300)); Convolve(kernel: kernel(31), strategy: .partitioned) })
        #expect(environment.latency == 0 && environment.sampleRate == 48_000)
    }

    // MARK: Descriptions, activation, validation (STG-1)

    @Test func descriptionsAndSpellings() {
        let h = kernel(8)
        #expect(Pipeline { Convolve(kernel: h) } == Pipeline().convolve(kernel: h))
        #expect(Pipeline { Convolve(kernel: h, strategy: .partitioned, isActive: false) } == Pipeline().convolve(kernel: h, strategy: .partitioned, isActive: false))
        #expect(Pipeline().convolve(kernel: h) == Pipeline().convolve(kernel: h, strategy: .automatic, isActive: true))
        #expect(Pipeline().convolve(kernel: h) != Pipeline().convolve(kernel: h, strategy: .direct) && Pipeline().convolve(kernel: h) != Pipeline().convolve(kernel: kernel(9)))
        #expect(Convolve(kernel: h).kernel == h && Convolve(kernel: h).strategy == .automatic && Convolve(kernel: h).activation == .active)
        #expect(Convolve(kernel: h).parameters.isEmpty && Convolve.stageName == "Convolve")
        #expect(Convolve(kernel: h).stageDescriptions.first?.rule == .sequence, "a sequence stage: any sampled sequence, kept (O-1)")
    }

    @Test func aKernelThatIsNoneIsRefused() {
        func refusal(_ stage: Convolve) -> String? { errorMessage { _ = try Pipeline { stage }.process(noise, format: mono48) } }
        #expect(refusal(Convolve(kernel: []))?.contains("Invalid parameter kernel: a convolution needs a kernel of at least one tap") == true)
        #expect(refusal(Convolve(kernel: [1, .nan]))?.contains("every tap of a kernel is a finite number") == true)
        #expect(refusal(Convolve(kernel: [.infinity], strategy: .partitioned))?.contains("Invalid parameter kernel") == true)
        #expect(refusal(Convolve(kernel: [0.5])) == nil, "a gain of one half is a kernel")
    }

    @Test func switchedOffTheSignalPassesAndABoundSwitchMakesNoClick() async throws {
        let h: [Float] = [0.5, 0.3, -0.2]
        #expect(try Pipeline { Convolve(kernel: h, isActive: false) }.process(noise, format: mono48) == noise, "bypassed (ACT-3)")
        #expect(try loweredKernelSpecs(Pipeline { Convolve(kernel: h, isActive: false) }).isEmpty, "a constant leaves no trace (ACT-4)")

        // A bound switch: a faded bypass at the next block boundary, for the plan's kernel and
        // for one made by name alike (ACT-5, ACT-7).
        for strategy in [ConvolutionStrategy.automatic, .partitioned] {
            let rig = SessionRig()
            let on = StateBox(true)
            let (session, output) = try await rig.run(Pipeline { Convolve(kernel: h, strategy: strategy, isActive: on.binding) })
            let sine = Click.probeSignal(count: 64 * 150)
            let wet = Array(try DSP.convolve(sine, h, strategy: .direct)[..<sine.count])
            rig.feed(Array(sine[..<(64 * 50)]))
            expectClose(output.samples, Array(wet[..<(64 * 50)]), .absolute(1e-5), "\(strategy): active, the convolution")
            on.value = false
            await session.syncBindings()
            rig.feed(Array(sine[(64 * 50) ..< (64 * 100)]))
            #expect(Array(output.samples[(64 * 60) ..< (64 * 100)]) == Array(sine[(64 * 60) ..< (64 * 100)]), "\(strategy): off, the signal passes")
            on.value = true
            await session.syncBindings()
            rig.feed(Array(sine[(64 * 100)...]))
            expectClose(Array(output.samples[(64 * 120)...]), Array(wet[(64 * 120)...]), .absolute(1e-5), "\(strategy): on again")
            let off = Click.measure(output.samples, change: 64 * 50 ..< 64 * 60, settle: 64)
            let back = Click.measure(output.samples, change: 64 * 100 ..< 64 * 112, settle: 64)
            #expect(off.passes && back.passes, "\(strategy): CLICK-1 off: \(off); on: \(back)")
            #expect(session.core.generation == 1, "nothing was compiled")
            session.detach()
        }
    }

    @Test func aKernelOfTheSameLengthTakesOverWithoutAClick() async throws {
        let rig = SessionRig()
        let first: [Float] = [0.6, 0.2, 0.1], second: [Float] = [0.1, -0.5, 0.3]
        let (session, output) = try await rig.run(Pipeline { Convolve(kernel: first) })
        let plan = session.core.plan
        let sine = Click.probeSignal(count: 64 * 120)
        rig.feed(Array(sine[..<(64 * 40)]))
        try await session.update(Pipeline { Convolve(kernel: second) })
        rig.feed(Array(sine[(64 * 40)...]))
        #expect(session.core.plan === plan && session.core.generation == 1, "taps of the same length are values: no new plan (§5.5.4)")
        let before = Array(try DSP.convolve(sine, first, strategy: .direct)[..<sine.count]), after = Array(try DSP.convolve(sine, second, strategy: .direct)[..<sine.count])
        expectClose(Array(output.samples[..<(64 * 40)]), Array(before[..<(64 * 40)]), .absolute(1e-5))
        expectClose(Array(output.samples[(64 * 60)...]), Array(after[(64 * 60)...]), .absolute(1e-5), "the new kernel, 10 ms later")
        let change = Click.measure(output.samples, change: 64 * 40 ..< 64 * 50, settle: 64)
        #expect(change.passes, "CLICK-1: \(change)")
        // Another length is another kernel: a new plan.
        try await session.update(Pipeline { Convolve(kernel: [0.5, 0.5]) })
        rig.feed(Array(sine[..<(64 * 40)]))
        #expect(session.core.generation == 2)
        session.detach()
    }

    // MARK: Cold start (ACT-10)

    @Test func aColdStartForgetsTheHistoryOfTheKernel() throws {
        let short = Array(noise[..<3_000])
        try expectAFreshStreamAfterAColdStart(of: Pipeline { Convolve(kernel: kernel(40)) }, on: short, "a direct Convolve")
        try expectAFreshStreamAfterAColdStart(of: Pipeline { Convolve(kernel: kernel(300)) }, on: short, "a partitioned Convolve")
        try expectAFreshStreamAfterAColdStart(of: Pipeline { Convolve(kernel: kernel(40), strategy: .partitioned) }, on: short, "a Convolve made by name")
    }

    // MARK: The real-time audit (RT-7)

    @Test func theStageRunsWithoutAllocating() throws {
        try expectNoAllocationsRunning(Pipeline {
            Convolve(kernel: kernel(63))
            Convolve(kernel: kernel(1_024))
            Convolve(kernel: kernel(63), strategy: .partitioned)
            Convolve(kernel: kernel(600), strategy: .direct)
        })
        // Blocks that are not whole partitions, and a feature-rate sequence.
        try expectNoAllocationsRunning(Pipeline { Convolve(kernel: kernel(300)); Convolve(kernel: kernel(20), strategy: .fft) }, blockSize: 441)
        let track = CountingSink<Scalar>()
        try expectNoAllocationsRunning(Pipeline { Level(.rms, window: 0.004, hop: 0.001); Convolve(kernel: [0.25, 0.5, 0.25]); Emit(to: track) })
        #expect(track.frames > 10_000)
    }
}
