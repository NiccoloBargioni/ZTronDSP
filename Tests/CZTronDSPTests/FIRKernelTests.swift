import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

private func fir(_ taps: [Float], channels: Int = 1, latency: Int = 0, fade: Int = 480) -> KernelRig {
    KernelRig(ztd_fir_create(UInt32(channels), taps, UInt32(taps.count), UInt32(latency), UInt32(fade)), channels: channels)
}

/// Every way of cutting a stream that a kernel working in cells of 64 frames could care about.
private let cuts: [(String, Blocks)] = [
    ("frame by frame", .fixed(1)), ("7", .fixed(7)), ("63", .fixed(63)), ("64", .fixed(64)), ("65", .fixed(65)),
    ("512", .fixed(512)), ("irregular up to 3", .irregular(seed: 31, upTo: 3)), ("irregular up to 300", .irregular(seed: 32, upTo: 300)),
    ("irregular up to 3 000", .irregular(seed: 33, upTo: 3_000)), ("1, 127, 64, 0, 200", .cycle([1, 127, 64, 0, 200])),
]

@Suite("Direct FIR kernel (WP-212)")
struct FIRKernelTests {
    @Test(arguments: [1, 2, 5, 31, 64, 255, 257, 1_500])
    func theKernelEqualsOfflineConvolution(count: Int) {
        let taps = noiseTaps(count)
        let input = TestSignal.whiteNoise(count: 5_000, seed: 212)
        let reference = Reference.convolve(input, taps)
        // The bound of the stability register, row 7: K · ε · Σ|h| · max|x|.
        let bound = Reference.convolutionBound(input, taps)
        let output = fir(taps).run(input, .irregular(seed: UInt64(count), upTo: 400))
        expectClose(output, reference, .absolute(bound), "\(count) taps")
        let error = zip(output, reference).map { abs(Double($0) - $1) }.max()!
        note("WP-212 \(count) taps: largest error over the register's bound", error / bound)
    }

    @Test(arguments: [1, 5, 64, 255, 1_500])
    func theOutputIsTheSameBitForBitForAnySequenceOfBlockSizes(count: Int) {
        let taps = noiseTaps(count)
        let input = [TestSignal.whiteNoise(count: 5_000, seed: 2_120), TestSignal.whiteNoise(count: 5_000, seed: 2_121), TestSignal.whiteNoise(count: 5_000, seed: 2_122)]
        let whole = fir(taps, channels: 3).run(input, .whole)
        for (name, blocks) in cuts {
            #expect(fir(taps, channels: 3).run(input, blocks).map(bits) == whole.map(bits), "\(count) taps, \(name)")
        }
        // Three channels with the same signal give the same output, wherever their buffers lie.
        let same = fir(taps, channels: 3).run([input[0], input[0], input[0]], .irregular(seed: 34, upTo: 200))
        #expect(bits(same[1]) == bits(same[0]) && bits(same[2]) == bits(same[0]) && bits(same[0]) == bits(whole[0]))
    }

    @Test func latencyAndSettlingTimeAreReported() {
        // A linear-phase low-pass: its delay is (count − 1) / 2, and the caller says so.
        let taps = kaiserLowPass(2)
        #expect(taps.count % 2 == 1 && zip(taps, taps.reversed()).allSatisfy { $0 == $1 }, "symmetric: linear phase")
        let delay = (taps.count - 1) / 2
        let rig = fir(taps, latency: delay)
        #expect(!rig.isNull && rig.latency == delay && rig.settling == taps.count - 1 && rig.hasCommand)
        // The stated latency is where an impulse comes out: the kernel reports it, it does not add it.
        let response = rig.run(TestSignal.impulse(count: 400, at: 100, amplitude: 1), .fixed(64))
        let peak = response.indices.max { abs(response[$0]) < abs(response[$1]) }!
        #expect(peak == 100 + delay)
        #expect(response == TestSignal.silence(count: 100) + taps + TestSignal.silence(count: 300 - taps.count), "the impulse response is the taps, from the frame of the impulse")
        #expect(fir(taps, latency: 0).latency == 0 && fir(taps, latency: 7).latency == 7)

        // The settling time: `count − 1` frames after a cold start the output is what a kernel that
        // had always been running gives.
        let input = TestSignal.whiteNoise(count: 2_000, seed: 2_123)
        let running = fir(taps).run(input)
        let start = 700
        rig.reset()
        let late = rig.run(Array(input[start...]))
        let settled = rig.settling
        expectClose(Array(late[settled...]), Array(running[(start + settled)...]), .absolute(Reference.convolutionBound(input, taps)))
        #expect(Reference.deviation(Array(late[..<settled]), Array(running[start ..< start + settled])) > -40, "before that it is not")
    }

    /// §5.5.4: FIR taps of equal length are cross-faded. For the frames of the fade the output is
    /// from + (to − from) · g with g = (frame + 1) / fade; afterwards it is the new filter's.
    @Test(arguments: [(480, Blocks.fixed(64)), (480, .irregular(seed: 35, upTo: 300)), (1, .fixed(64)), (0, .fixed(512)), (100, .fixed(1)), (5_000, .fixed(512))])
    func newTapsAreCrossFadedIn(fade: Int, blocks: Blocks) {
        let old = windowedSinc(count: 63, cutoff: 0.10), new = windowedSinc(count: 63, cutoff: 0.30)
        let input = TestSignal.whiteNoise(count: 4_000, seed: 2_124)
        let change = 1_024
        let rig = fir(old, fade: fade)
        let before = rig.run(Array(input[..<change]), blocks)
        rig.setValues(new)
        let output = before + rig.run(Array(input[change...]), blocks)

        let from = Reference.convolve(input, old), to = Reference.convolve(input, new)
        let length = max(fade, 1)
        let expected = (0 ..< input.count).map { n -> Double in
            guard n >= change else { return from[n] }
            let gain = min(Double(n - change + 1) / Double(length), 1)
            return from[n] + (to[n] - from[n]) * gain
        }
        // Two convolutions and a blend: twice the register's bound, and the rounding of the blend.
        let tolerance = 2 * Reference.convolutionBound(input, old) + 4 * Double(Float.ulpOfOne)
        expectClose(output, expected, .absolute(tolerance), "a fade of \(fade) frames")
        if change + length < input.count {
            // After the fade the kernel is the new filter and nothing else: what a kernel created with it gives.
            let fresh = fir(new).run(input, blocks)
            expectClose(Array(output[(change + length)...]), Array(fresh[(change + length)...]), .absolute(Reference.convolutionBound(input, new)))
        }
        #expect(Reference.deviation(Array(output[change...]), Array(from[change...])) > -40, "the filter did change")
    }

    @Test func aChangeDuringAFadeStartsFromWhatSoundsNow() {
        let first = windowedSinc(count: 63, cutoff: 0.10), second = windowedSinc(count: 63, cutoff: 0.30), third = windowedSinc(count: 63, cutoff: 0.20)
        let input = TestSignal.whiteNoise(count: 4_000, seed: 2_125)
        let fade = 400, begin = 512, again = 512 + 150   // the second change arrives 150 frames into the first fade
        let rig = fir(first, fade: fade)
        var output = rig.run(Array(input[..<begin]), .fixed(64))
        rig.setValues(second)
        output += rig.run(Array(input[begin ..< again]), .fixed(50))
        rig.setValues(third)
        output += rig.run(Array(input[again...]), .irregular(seed: 36, upTo: 100))

        let a = Reference.convolve(input, first), b = Reference.convolve(input, second), c = Reference.convolve(input, third)
        let reached = Double(again - begin) / Double(fade)   // how far the first fade had come
        let expected = (0 ..< input.count).map { n -> Double in
            if n < begin { return a[n] }
            if n < again { return a[n] + (b[n] - a[n]) * Double(n - begin + 1) / Double(fade) }
            let blend = a[n] + (b[n] - a[n]) * reached   // the two filters as they were mixed: one filter
            return blend + (c[n] - blend) * min(Double(n - again + 1) / Double(fade), 1)
        }
        expectClose(output, expected, .absolute(3 * Reference.convolutionBound(input, first) + 1e-6))
        // No jump at either change: the steps there are no larger than the signal's own.
        let usual = Reference.largestStep(output, 0 ..< begin)
        #expect(Reference.largestStep(output, begin ..< begin + 2) <= usual && Reference.largestStep(output, again ..< again + 2) <= usual)
    }

    /// CLICK-1 for a change of taps: a full-scale 1 kHz sine at 48 kHz, cross-faded over 10 ms.
    @Test(arguments: [64, 512])
    func aChangeOfTapsMakesNoClick(block: Int) {
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 40 * 512)
        let change = 20 * 512
        // Two low-passes at 3 kHz and at 600 Hz: the sine passes the first and is attenuated by the second.
        let wide = windowedSinc(count: 255, cutoff: 3_000.0 / 48_000), narrow = windowedSinc(count: 255, cutoff: 600.0 / 48_000)
        for (from, to, direction) in [(wide, narrow, "narrowing"), (narrow, wide, "widening")] {
            let rig = fir(from, fade: 480)
            let before = rig.run(Array(sine[..<change]), .fixed(block))
            rig.setValues(to)
            let output = before + rig.run(Array(sine[change...]), .fixed(block))
            let ratio = clickRatio(output, change: change, block: max(block, 480), steadyBefore: change - 2_048 ..< change, steadyAfter: sine.count - 2_048 ..< sine.count)
            #expect(ratio <= 1.5, "\(direction), blocks of \(block): the largest step is \(ratio) times the steady one")
            if block == 512 { note("WP-212 CLICK-1, taps cross-faded over 480 frames, \(direction)", ratio) }
        }
    }

    @Test func commandsThatAreNotForItChangeNothingAndAResetIsAColdStart() {
        let taps = noiseTaps(40)
        let input = TestSignal.whiteNoise(count: 600, seed: 2_126)
        let rig = fir(taps)
        let expected = rig.run(input, .fixed(100))
        rig.reset()
        noiseTaps(39).withUnsafeBufferPointer { rig.send(count: 39, values: UnsafeRawPointer($0.baseAddress)) }   // another length
        rig.send(count: 40, values: nil)                                                                         // no payload
        noiseTaps(41).withUnsafeBufferPointer { rig.send(kind: UInt32(ZTD_COMMAND_SET_ACTIVE), count: 40, values: UnsafeRawPointer($0.baseAddress)) }
        rig.sendNothing()
        #expect(bits(rig.run(input, .fixed(100))) == bits(expected))
        // A reset in the middle of a fade lands on the taps last asked for.
        let other = noiseTaps(40).reversed().map { $0 * 0.5 }
        rig.setValues(Array(other))
        _ = rig.run(Array(input[..<100]))
        rig.reset()
        #expect(bits(rig.run(input, .fixed(100))) == bits(fir(Array(other)).run(input, .fixed(100))))
    }

    /// The stress signals of WP-016 against the bound of the stability register (row 7). The
    /// kernel computes on the input with everything below 1e-20 taken as zero (RT-6), so no
    /// subnormal value ever enters its history, and none comes out.
    @Test func theErrorStaysWithinTheRegistersBoundOnTheStressSignals() {
        for taps in [kaiserLowPass(2), noiseTaps(255)] {
            for signal in StressFixture.signals(count: 2_048) {
                let input = cleaned(signal.samples)
                let output = fir(taps).run(signal.samples, .irregular(seed: 37, upTo: 500))
                let bound = Reference.convolutionBound(input, taps)
                expectClose(output, Reference.convolve(input, taps), .absolute(bound), "\(signal.name), \(taps.count) taps")
                #expect(!output.contains { $0.isSubnormal }, "\(signal.name): a subnormal value came out")
                if signal.name == "denormal" || signal.name == "silence" {
                    #expect(output.allSatisfy { $0 == 0 }, "\(signal.name): nothing in, exactly nothing out")
                }
            }
        }
        // Full scale for a long time: the error does not grow. Each output is computed afresh from
        // the input history, so nothing accumulates.
        let taps = kaiserLowPass(2)
        let long = (0 ..< 200_000).map { Float(($0 / 24) % 2 == 0 ? 1 : -1) }
        let output = fir(taps).run(long, .fixed(512))
        let tail = Array(long[190_000...]), bound = Reference.convolutionBound(tail, taps)
        let reference = Reference.convolve(Array(long[(190_000 - taps.count)...]), taps)
        expectClose(Array(output[190_000...]), Array(reference[taps.count...]), .absolute(bound))
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let taps = noiseTaps(8)
        #expect(KernelRig(ztd_fir_create(0, taps, 8, 0, 0), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_fir_create(1, taps, 0, 0, 0), channels: 1).isNull, "no taps")
        #expect(KernelRig(ztd_fir_create(1, nil, 8, 0, 0), channels: 1).isNull, "no tap array")
        #expect(KernelRig(ztd_fir_create(1, [1, .nan, 0], 3, 0, 0), channels: 1).isNull, "a tap that is not a number")
        #expect(KernelRig(ztd_fir_create(1, [1, .infinity, 0], 3, 0, 0), channels: 1).isNull)
        #expect(KernelRig(ztd_fir_create(1, taps, 1 << 30, 0, 0), channels: 1).isNull, "an absurd length is refused before it is read")
    }

    @Test func processingAndTapChangesAreAllocationFree() {
        let taps = noiseTaps(255)
        let rig = fir(taps, channels: 2, fade: 480)
        let call = rig.arena(frames: 512)
        let other = rig.preparedCommand(floats: noiseTaps(255).map { -$0 }), back = rig.preparedCommand(floats: taps)
        let command = call.command!
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                if round % 50 == 0 { command(call.state, round % 100 == 0 ? other : back) }   // fades, and changes inside fades
                call.run(round % 3 == 0 ? 37 : 512)
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        var results: [BenchmarkResult] = []
        for count in [16, 64, 255] {
            let rig = fir(noiseTaps(count))
            let call = rig.arena(frames: 512)
            results.append(Benchmark.measure("kernel.fir.\(count)-taps.512", iterations: 200) { call.run(512) })
        }
        // What blocks that are not whole cells cost: the same 512 frames as ten blocks of 48 and one of 32.
        let rig = fir(noiseTaps(255))
        let call = rig.arena(frames: 48)
        results.append(Benchmark.measure("kernel.fir.255-taps.512-in-blocks-of-48", iterations: 100) {
            var block = 0
            while block < 11 {
                call.run(block == 10 ? 32 : 48)
                block += 1
            }
        })
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 4 && results.allSatisfy { $0.minimum > 0 })
    }
}
