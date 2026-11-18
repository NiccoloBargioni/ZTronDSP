import CZTronDSP
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

private func decimator(_ factor: Int, _ taps: [Float], channels: Int = 1, latency: Int = 0) -> KernelRig {
    KernelRig(ztd_decimator_create(UInt32(channels), UInt32(factor), taps, UInt32(taps.count), UInt32(latency)), channels: channels)
}

private func interpolator(_ factor: Int, _ taps: [Float], channels: Int = 1, latency: Int = 0) -> KernelRig {
    KernelRig(ztd_interpolator_create(UInt32(channels), UInt32(factor), taps, UInt32(taps.count), UInt32(latency)), channels: channels)
}

/// The low-pass a rate change by `factor` is tested with: SciPy's Kaiser design where the
/// generator made one, seeded taps without structure otherwise.
private func lowPass(for factor: Int) -> [Float] {
    KernelFixtures.lowPass.contains { $0.factor == factor } ? kaiserLowPass(factor) : noiseTaps(40 + 3 * factor)
}

private let cuts: [(String, Blocks)] = [
    ("frame by frame", .fixed(1)), ("2", .fixed(2)), ("7", .fixed(7)), ("64", .fixed(64)), ("65", .fixed(65)), ("512", .fixed(512)),
    ("irregular up to 5", .irregular(seed: 41, upTo: 5)), ("irregular up to 300", .irregular(seed: 42, upTo: 300)),
    ("irregular up to 3 000", .irregular(seed: 43, upTo: 3_000)), ("1, 127, 64, 0, 200", .cycle([1, 127, 64, 0, 200])),
]

@Suite("Decimator kernel (WP-213)")
struct DecimatorKernelTests {
    @Test(arguments: [1, 2, 3, 4, 7])
    func theOutputEqualsFilterThenSubsampleForIrregularBlockSizes(factor: Int) {
        let taps = lowPass(for: factor)
        let input = TestSignal.whiteNoise(count: 6_001, seed: 213)
        // Filter at the full rate, in double precision; then keep every `factor`-th sample, with the toolkit.
        let reference = subsampled(Reference.convolve(input, taps), by: factor)
        let bound = Reference.convolutionBound(input, taps)
        for (name, blocks) in cuts {
            let rig = decimator(factor, taps)
            let output = rig.run(input, blocks)
            #expect(output.count == (input.count + factor - 1) / factor, "every \(factor)-th frame of \(input.count), \(name)")
            expectClose(output, reference, .absolute(bound), "factor \(factor), \(name)")
            // Each call returns frames / factor frames, give or take one.
            for block in rig.lastBlocks {
                #expect(block.produced == block.frames / factor || block.produced == block.frames / factor + 1, "\(block.frames) frames gave \(block.produced)")
            }
        }
    }

    @Test(arguments: [1, 2, 3, 4, 7])
    func theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes(factor: Int) {
        let taps = lowPass(for: factor)
        let input = [TestSignal.whiteNoise(count: 6_001, seed: 2_130), TestSignal.whiteNoise(count: 6_001, seed: 2_131), TestSignal.whiteNoise(count: 6_001, seed: 2_132)]
        let whole = decimator(factor, taps, channels: 3).run(input, .whole)
        for (name, blocks) in cuts + [("a whole cell", .fixed(16 * factor)), ("a cell and a frame", .fixed(16 * factor + 1))] {
            #expect(decimator(factor, taps, channels: 3).run(input, blocks).map(bits) == whole.map(bits), "factor \(factor), \(name)")
        }
        let same = decimator(factor, taps, channels: 3).run([input[0], input[0], input[0]], .irregular(seed: 44, upTo: 200))
        #expect(bits(same[1]) == bits(same[0]) && bits(same[2]) == bits(same[0]) && bits(same[0]) == bits(whole[0]))
    }

    /// The stress test of the stability note (register row 9): what a decimator has to fear is
    /// aliasing, and the filter before the subsampling is what keeps it out. A full-scale tone at
    /// the old Nyquist frequency, the stress signal for decimators, lands on 0 Hz when every
    /// second sample is kept. Through the kernel it is at least 80 dB down; through plain
    /// subsampling it is a full-scale constant.
    @Test func aFullScaleToneAtNyquistDoesNotAliasIntoTheBand() throws {
        let fixture = try #require(KernelFixtures.lowPass.first { $0.factor == 2 })
        #expect(fixture.rejection >= 80, "the fixture is the default filter of §6.12: 80 dB from the new Nyquist frequency up")
        let taps = kaiserLowPass(2)
        let nyquist = try #require(StressFixture.signals(count: 8_192).first { $0.name == "nyquist" }).samples
        let output = decimator(2, taps).run(nyquist, .irregular(seed: 45, upTo: 300))
        let settled = output[taps.count...]   // past the filter's own start
        let alias = settled.map { abs(Double($0)) }.max()!
        #expect(alias <= pow(10, -80.0 / 20), "the alias is \(20 * log10(alias)) dB")
        note("WP-213 full-scale Nyquist tone, decimated by 2: alias level", 20 * log10(alias), "dB")
        // Without the filter: every second sample of +1, −1, … is +1.
        let bare = KernelRig(ztd_subsample_create(1, 2, 0), channels: 1).run(nyquist, .fixed(64))
        #expect(bare.allSatisfy { $0 == 1 }, "plain subsampling folds the tone onto 0 Hz at full scale")
        // What belongs in the band passes: a constant comes out as the same constant.
        let level = try #require(StressFixture.signals(count: 8_192).first { $0.name == "dc" }).samples
        let passed = decimator(2, taps).run(level, .fixed(512))
        expectClose(Array(passed[taps.count...]), [Float](repeating: 1, count: passed.count - taps.count), .absolute(1e-6))
    }

    @Test func latencySettlingTimeAndTheFirstFrameAreAsStated() {
        let taps = kaiserLowPass(3)
        let rig = decimator(3, taps, latency: (taps.count - 1) / 2)
        #expect(!rig.isNull && rig.latency == (taps.count - 1) / 2 && rig.settling == taps.count - 1 && !rig.hasCommand)
        // The first input frame is kept: an impulse there comes out as tap 0, 3, 6, …
        let response = rig.run(TestSignal.impulse(count: 300), .fixed(7))
        #expect(response == subsampled(taps + TestSignal.silence(count: 300 - taps.count), by: 3))
        // A reset starts the phase again as well as the history.
        _ = rig.run(TestSignal.whiteNoise(count: 100, seed: 1))
        rig.reset()
        #expect(rig.run(TestSignal.impulse(count: 300), .fixed(7)) == response)
    }

    @Test func subnormalInputGivesExactZeros() throws {
        let quiet = try #require(StressFixture.signals(count: 2_048).first { $0.name == "denormal" }).samples
        let output = decimator(2, kaiserLowPass(2)).run(quiet, .fixed(64))
        #expect(output.count == 1_024 && output.allSatisfy { $0 == 0 }, "nothing below 1e-20 enters the history (RT-6)")
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let taps = noiseTaps(8)
        #expect(KernelRig(ztd_decimator_create(0, 2, taps, 8, 0), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_decimator_create(1, 0, taps, 8, 0), channels: 1).isNull, "a factor of zero")
        #expect(KernelRig(ztd_decimator_create(1, 100_000, taps, 8, 0), channels: 1).isNull, "a factor beyond all reason")
        #expect(KernelRig(ztd_decimator_create(1, 2, taps, 0, 0), channels: 1).isNull, "no taps")
        #expect(KernelRig(ztd_decimator_create(1, 2, nil, 8, 0), channels: 1).isNull, "no tap array")
        #expect(KernelRig(ztd_decimator_create(1, 2, [1, .nan], 2, 0), channels: 1).isNull, "a tap that is not a number")
    }

    @Test func processingIsAllocationFree() {
        let rig = decimator(3, kaiserLowPass(3), channels: 2)
        let call = rig.arena(frames: 512)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                call.run(round % 3 == 0 ? 37 : (round % 3 == 1 ? 512 : 48))
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        var results: [BenchmarkResult] = []
        for factor in [2, 4] {
            let rig = decimator(factor, kaiserLowPass(factor))
            let call = rig.arena(frames: 512)
            results.append(Benchmark.measure("kernel.decimator.by-\(factor).512", iterations: 200) { call.run(512) })
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 2 && results.allSatisfy { $0.minimum > 0 })
    }
}

@Suite("Interpolator kernel (WP-223)")
struct InterpolatorKernelTests {
    /// Zero-stuff with the toolkit, then filter in double precision, with gain `factor`.
    private func reference(_ input: [Float], _ taps: [Float], _ factor: Int) -> [Double] {
        Reference.convolve(upsampled(input, by: factor), taps).map { Double(factor) * $0 }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func theOutputEqualsZeroStuffThenFilter(factor: Int) {
        let taps = lowPass(for: factor)
        let input = TestSignal.whiteNoise(count: 3_000, seed: 223)
        let expected = reference(input, taps, factor)
        // The register's bound for the sum behind each output, with the gain the kernel applies.
        let bound = Double(factor) * Reference.convolutionBound(input, taps)
        for (name, blocks) in cuts {
            let rig = interpolator(factor, taps)
            let output = rig.run(input, blocks, expansion: factor)
            #expect(output.count == input.count * factor)
            expectClose(output, expected, .absolute(bound), "factor \(factor), \(name)")
            for block in rig.lastBlocks { #expect(block.produced == block.frames * factor) }
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes(factor: Int) {
        let taps = lowPass(for: factor)
        let input = [TestSignal.whiteNoise(count: 3_000, seed: 2_230), TestSignal.whiteNoise(count: 3_000, seed: 2_231), TestSignal.whiteNoise(count: 3_000, seed: 2_232)]
        let whole = interpolator(factor, taps, channels: 3).run(input, .whole, expansion: factor)
        for (name, blocks) in cuts {
            #expect(interpolator(factor, taps, channels: 3).run(input, blocks, expansion: factor).map(bits) == whole.map(bits), "factor \(factor), \(name)")
        }
        let same = interpolator(factor, taps, channels: 3).run([input[0], input[0], input[0]], .irregular(seed: 46, upTo: 200), expansion: factor)
        #expect(bits(same[1]) == bits(same[0]) && bits(same[2]) == bits(same[0]) && bits(same[0]) == bits(whole[0]))
    }

    /// Also the stress test of the stability note (register row 9): the constant of the stress
    /// library through the interpolator. Without the gain it comes out at 1 / factor; without
    /// the filter, as one sample in `factor` at full strength.
    @Test(arguments: [2, 3, 4])
    func theGainIsTheFactor(factor: Int) throws {
        let taps = kaiserLowPass(factor)   // unity gain at 0 Hz
        let constant = try #require(StressFixture.signals(count: 400).first { $0.name == "dc" }).samples
        let unit = interpolator(factor, taps).run(constant, .irregular(seed: 71, upTo: 90), expansion: factor)
        expectClose(Array(unit[(taps.count + factor)...]), [Float](repeating: 1, count: unit.count - taps.count - factor), .absolute(Double(factor) * 1e-4),
                    "factor \(factor): full scale in, full scale out")
        expectClose(taps.reduce(0.0) { $0 + Double($1) }, 1, .absolute(1e-6))
        // An impulse comes out as the taps times the factor: the response sums to the factor.
        let response = interpolator(factor, taps).run(TestSignal.impulse(count: 200), .fixed(7), expansion: factor)
        #expect(Array(response[..<taps.count]) == taps.map { Float(factor) * $0 }, "factor \(factor): the taps, times the factor")
        expectClose(response.reduce(0.0) { $0 + Double($1) }, Double(factor), .relative(1e-6))
        // So a constant stays the constant it was: the zeros inserted between its samples take
        // nothing from its level. (Without the gain it would come out at 1 / factor.)
        let level = interpolator(factor, taps).run(TestSignal.constant(0.75, count: 400), .fixed(64), expansion: factor)
        let settled = Array(level[(taps.count + factor)...])
        expectClose(settled.reduce(0.0) { $0 + Double($1) } / Double(settled.count), 0.75, .relative(1e-5), "factor \(factor): the mean level")
        // …and the images of the constant, at multiples of the old sample rate, are in the stop
        // band: at least 80 dB down. Unfiltered zero-stuffing leaves them at full strength.
        let ripple = settled.map { abs(Double($0) - 0.75) }.max()! / 0.75
        #expect(ripple <= Double(factor) * pow(10, -80.0 / 20), "factor \(factor): images at \(20 * log10(ripple)) dB")
        note("WP-223 a constant interpolated by \(factor): images", 20 * log10(ripple), "dB")
        let bare = KernelRig(ztd_zero_stuff_create(1, UInt32(factor)), channels: 1).run(TestSignal.constant(0.75, count: 64), expansion: factor)
        #expect(bare.enumerated().allSatisfy { $0.element == ($0.offset % factor == 0 ? 0.75 : 0) })
    }

    @Test func latencySettlingTimeAndResetAreAsStated() {
        let taps = kaiserLowPass(4)
        let rig = interpolator(4, taps, latency: 12)
        #expect(!rig.isNull && rig.latency == 12 && !rig.hasCommand)
        #expect(rig.settling == (taps.count + 3) / 4 - 1, "the history holds one phase of the filter, less one frame")
        let input = TestSignal.whiteNoise(count: 500, seed: 2_233)
        let first = rig.run(input, .fixed(100), expansion: 4)
        rig.reset()
        #expect(bits(rig.run(input, .fixed(33), expansion: 4)) == bits(first), "a cold start gives the same output again")
        // More taps than a multiple of the factor, and fewer taps than the factor: every phase still gets its own.
        for count in [1, 2, 3, 5, 9] {
            let short = noiseTaps(count)
            let output = interpolator(4, short).run(input, .irregular(seed: 47, upTo: 60), expansion: 4)
            expectClose(output, reference(input, short, 4), .absolute(4 * Reference.convolutionBound(input, short) + 1e-12), "\(count) taps")
        }
    }

    @Test func subnormalInputGivesExactZeros() throws {
        let quiet = try #require(StressFixture.signals(count: 1_024).first { $0.name == "denormal" }).samples
        let output = interpolator(3, kaiserLowPass(3)).run(quiet, .fixed(64), expansion: 3)
        #expect(output.count == 3_072 && output.allSatisfy { $0 == 0 }, "nothing below 1e-20 enters the history (RT-6)")
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let taps = noiseTaps(8)
        #expect(KernelRig(ztd_interpolator_create(0, 2, taps, 8, 0), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_interpolator_create(1, 0, taps, 8, 0), channels: 1).isNull, "a factor of zero")
        #expect(KernelRig(ztd_interpolator_create(1, 100_000, taps, 8, 0), channels: 1).isNull, "a factor beyond all reason")
        #expect(KernelRig(ztd_interpolator_create(1, 2, taps, 0, 0), channels: 1).isNull, "no taps")
        #expect(KernelRig(ztd_interpolator_create(1, 2, nil, 8, 0), channels: 1).isNull, "no tap array")
        #expect(KernelRig(ztd_interpolator_create(1, 2, [.infinity, 1], 2, 0), channels: 1).isNull, "a tap that is not a number")
    }

    @Test func processingIsAllocationFree() {
        let rig = interpolator(3, kaiserLowPass(3), channels: 2)
        let call = rig.arena(frames: 512, expansion: 3)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                call.run(round % 3 == 0 ? 37 : (round % 3 == 1 ? 512 : 64))
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        var results: [BenchmarkResult] = []
        for factor in [2, 4] {
            let rig = interpolator(factor, kaiserLowPass(factor))
            let call = rig.arena(frames: 512, expansion: factor)
            results.append(Benchmark.measure("kernel.interpolator.by-\(factor).512", iterations: 200) { call.run(512) })
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 2 && results.allSatisfy { $0.minimum > 0 })
    }
}

@Suite("Subsample and zero-stuff kernels (WP-227)")
struct SubsampleKernelTests {
    @Test(arguments: [1, 2, 3, 5, 8])
    func subsamplingIsTheToolkitFunctionForIrregularBlockSizes(factor: Int) {
        let input = [TestSignal.whiteNoise(count: 4_001, seed: 227), TestSignal.whiteNoise(count: 4_001, seed: 2_270)]
        for phase in [0, 1, factor - 1, factor, factor + 2, 1_000_003] {
            for (name, blocks) in cuts {
                let rig = KernelRig(ztd_subsample_create(2, UInt32(factor), UInt32(phase)), channels: 2)
                #expect(!rig.isNull && rig.latency == 0 && rig.settling == 0 && !rig.hasCommand)
                let output = rig.run(input, blocks)
                for channel in 0 ..< 2 {
                    #expect(bits(output[channel]) == bits(subsampled(input[channel], by: factor, phase: phase)), "factor \(factor), phase \(phase), \(name)")
                }
                for block in rig.lastBlocks {
                    #expect(block.produced == block.frames / factor || block.produced == block.frames / factor + 1)
                }
            }
        }
    }

    @Test(arguments: [1, 2, 3, 5, 8])
    func zeroStuffingIsTheToolkitFunctionForIrregularBlockSizes(factor: Int) {
        let input = [TestSignal.whiteNoise(count: 2_001, seed: 2_271), TestSignal.whiteNoise(count: 2_001, seed: 2_272)]
        for (name, blocks) in cuts {
            let rig = KernelRig(ztd_zero_stuff_create(2, UInt32(factor)), channels: 2)
            #expect(!rig.isNull && rig.latency == 0 && rig.settling == 0 && !rig.hasCommand)
            let output = rig.run(input, blocks, expansion: factor)
            for channel in 0 ..< 2 {
                #expect(bits(output[channel]) == bits(upsampled(input[channel], by: factor)), "factor \(factor), \(name)")
            }
            for block in rig.lastBlocks { #expect(block.produced == block.frames * factor) }
        }
    }

    @Test func upThenDownByOneFactorIsTheIdentity() {
        let input = TestSignal.whiteNoise(count: 1_000, seed: 2_273)
        for factor in 1 ... 6 {
            let up = KernelRig(ztd_zero_stuff_create(1, UInt32(factor)), channels: 1).run(input, .irregular(seed: 48, upTo: 90), expansion: factor)
            let down = KernelRig(ztd_subsample_create(1, UInt32(factor), 0), channels: 1).run(up, .irregular(seed: 49, upTo: 90))
            #expect(bits(down) == bits(input), "factor \(factor)")
        }
    }

    @Test func aResetStartsThePhaseAgain() {
        let input = (0 ..< 100).map(Float.init)
        let rig = KernelRig(ztd_subsample_create(1, 4, 3), channels: 1)
        let first = rig.run(Array(input[..<50]), .fixed(7))
        #expect(first == subsampled(Array(input[..<50]), by: 4, phase: 3))
        // Carried on, the phase is carried too; after a reset it is the one the kernel was created with.
        #expect(rig.run(Array(input[50...]), .fixed(7)) == Array(subsampled(input, by: 4, phase: 3)[first.count...]))
        rig.reset()
        #expect(rig.run(input, .fixed(9)) == subsampled(input, by: 4, phase: 3))
        let stuff = KernelRig(ztd_zero_stuff_create(1, 3), channels: 1)
        _ = stuff.run(input, expansion: 3)
        stuff.reset()
        #expect(stuff.run(input, expansion: 3) == upsampled(input, by: 3), "zero-stuffing has no memory to reset")
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        #expect(KernelRig(ztd_subsample_create(0, 2, 0), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_subsample_create(1, 0, 0), channels: 1).isNull, "a factor of zero")
        #expect(KernelRig(ztd_subsample_create(1, 100_000, 0), channels: 1).isNull, "a factor beyond all reason")
        #expect(KernelRig(ztd_zero_stuff_create(0, 2), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_zero_stuff_create(1, 0), channels: 1).isNull, "a factor of zero")
        #expect(KernelRig(ztd_zero_stuff_create(1, 100_000), channels: 1).isNull)
    }

    @Test func processingIsAllocationFree() {
        let down = KernelRig(ztd_subsample_create(2, 3, 1), channels: 2), up = KernelRig(ztd_zero_stuff_create(2, 3), channels: 2)
        let downCall = down.arena(frames: 512), upCall = up.arena(frames: 512, expansion: 3)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                downCall.run(round % 2 == 0 ? 509 : 512)
                upCall.run(round % 2 == 0 ? 509 : 512)
                round += 1
            }
            downCall.reset(downCall.state)
            upCall.reset(upCall.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        let down = KernelRig(ztd_subsample_create(1, 3, 0), channels: 1), up = KernelRig(ztd_zero_stuff_create(1, 3), channels: 1)
        let downCall = down.arena(frames: 512), upCall = up.arena(frames: 512, expansion: 3)
        let results = [
            Benchmark.measure("kernel.subsample.by-3.512", iterations: 2_000) { downCall.run(512) },
            Benchmark.measure("kernel.zero-stuff.by-3.512", iterations: 2_000) { upCall.run(512) },
        ]
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.allSatisfy { $0.minimum > 0 })
    }
}
