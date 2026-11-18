import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The fixture of WP-208: a Butterworth high-pass, 1 kHz, order 4, at 48 kHz, from SciPy.
private let fixture = KernelFixtures.acceptance[0]
/// The same filter a tenth of an octave up (WP-209).
private let raised = KernelFixtures.acceptance[1]

private func biquad(_ cascade: KernelFixtures.Cascade, channels: Int = 1, _ bound: Bound) -> KernelRig {
    KernelRig(ztd_biquad_create(UInt32(channels), UInt32(cascade.sections), cascade.coefficients, bound.implementation), channels: channels)
}

@Suite("Biquad cascade, single precision (WP-208)")
struct BiquadKernelTests {
    @Test func theFixtureIsTheOneTheAcceptanceNames() {
        #expect(fixture.name == "hp-1kHz-48k-order4" && fixture.response == .highPass)
        #expect(fixture.sampleRate == 48_000 && fixture.cutoff == 1_000 && fixture.order == 4 && fixture.sections == 2)
        // A Butterworth high-pass: −3.01 dB at the cutoff, unity at Nyquist, nothing at 0 Hz.
        expectClose(Reference.magnitude(fixture.coefficients, at: 1_000, sampleRate: 48_000), 0.5.squareRoot(), .relative(1e-9))
        expectClose(Reference.magnitude(fixture.coefficients, at: 24_000, sampleRate: 48_000), 1, .relative(1e-9))
        #expect(Reference.magnitude(fixture.coefficients, at: 0, sampleRate: 48_000) < 1e-12)
    }

    @Test(arguments: Bound.allCases)
    func theImpulseResponseIsWithinTenToTheMinusFiveOfADoublePrecisionReference(bound: Bound) {
        let impulse = TestSignal.impulse(count: 4_096)
        let rig = biquad(fixture, bound)
        #expect(!rig.isNull && rig.latency == 0 && rig.hasCommand)
        let response = rig.run(impulse, .fixed(512))
        let reference = Reference.cascade(impulse, fixture.coefficients)
        expectClose(response, reference, .absolute(1e-5), "\(bound)")
        note("WP-208 \(bound) impulse response, largest error against the double reference",
             zip(response, reference).map { abs(Double($0) - $1) }.max()!)
    }

    @Test func blockSizesFrom64To512AreBitIdentical() {
        // On noise, every frame.
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 208)
        let reference = biquad(fixture, .accelerate).run(noise, .fixed(512))
        for size in [64, 128, 256] {
            #expect(bits(biquad(fixture, .accelerate).run(noise, .fixed(size))) == bits(reference), "noise, blocks of \(size)")
        }
        // On the impulse response, every frame for as long as the response is one. RT-6 clears
        // the filter's memory at the end of the block in which it has fallen below 1e-20 (−400 dB),
        // and where a block ends depends on its size: from there on the responses are zero or
        // below that floor, not equal bit for bit.
        let impulse = TestSignal.impulse(count: 8_192)
        let response = biquad(fixture, .accelerate).run(impulse, .fixed(512))
        let alive = response.lastIndex { abs($0) >= 1e-15 }! + 1
        #expect(alive > 512, "the comparison spans more than one block of every size")
        for size in [64, 128, 256] {
            let other = biquad(fixture, .accelerate).run(impulse, .fixed(size))
            #expect(bits(Array(other[..<alive])) == bits(Array(response[..<alive])), "impulse response, blocks of \(size)")
            #expect(zip(other[alive...], response[alive...]).allSatisfy { abs($0 - $1) < 1e-15 })
        }
    }

    /// vDSP_biquad rounds differently into an output that is not 16-byte aligned. The kernel
    /// does not: where the caller keeps its buffer changes nothing.
    @Test func theOutputDoesNotDependOnWhereTheCallersBufferLies() {
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 2_084)
        let reference = biquad(fixture, .accelerate).run(noise, .fixed(512))
        // The rig starts the output of channel c of a run c frames past a 64-byte boundary: four
        // channels are 0, 1, 2 and 3 frames off.
        let four = [noise, noise, noise, noise]
        let together = biquad(fixture, channels: 4, .accelerate).run(four, .fixed(512))
        for channel in 0 ..< 4 { #expect(bits(together[channel]) == bits(reference), "channel \(channel)") }
        // With blocks of any size, which also end anywhere, the four still agree with one another.
        for blocks in [Blocks.cycle([512, 1, 2, 3]), .whole, .cycle([1_025, 1_027, 1_024, 1_020]), .irregular(seed: 11, upTo: 3_000)] {
            let cut = biquad(fixture, channels: 4, .accelerate).run(four, blocks)
            for channel in 1 ..< 4 { #expect(bits(cut[channel]) == bits(cut[0]), "channel \(channel)") }
        }
        // Blocks of any multiple of four frames, long ones included, give the reference itself.
        let multiples = biquad(fixture, channels: 4, .accelerate).run(four, .cycle([512, 4, 1_024, 8, 2_048, 500]))
        for channel in 0 ..< 4 { #expect(bits(multiples[channel]) == bits(reference), "channel \(channel)") }
    }

    @Test func blockSizes1And7AreWithinMinus100dB() {
        let impulse = TestSignal.impulse(count: 8_192)
        let reference = biquad(fixture, .accelerate).run(impulse, .fixed(512))
        for size in [1, 7] {
            let response = biquad(fixture, .accelerate).run(impulse, .fixed(size))
            expectClose(response, reference, .deviationBelow(decibels: -100), "blocks of \(size)")
            note("WP-208 impulse response, blocks of \(size) against 512", Reference.deviation(response, reference), "dB")
        }
    }

    /// Not the acceptance, which is stated on the impulse response: the same comparison on
    /// full-scale noise, where vDSP_biquad's remainder path shows more. Measured on the host of
    /// §3: −100.3 dB for blocks of 1 and −98.2 dB for blocks of 7 (E-30 has −61 dB for a 90 Hz,
    /// order 8 filter). The bound here keeps that behaviour from getting worse unnoticed.
    @Test func onFullScaleNoiseOddBlockSizesDifferByRoundOffOnly() {
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 208)
        let reference = biquad(fixture, .accelerate).run(noise, .fixed(512))
        for size in [1, 7] {
            let output = biquad(fixture, .accelerate).run(noise, .fixed(size))
            expectClose(output, reference, .deviationBelow(decibels: -96), "blocks of \(size)")
            note("WP-208 full-scale noise, blocks of \(size) against 512", Reference.deviation(output, reference), "dB")
        }
        // E-30's figure, measured again: the 90 Hz, order 8 high-pass of the stress library.
        let low = stressCascade("hp-90Hz-48k-order8")
        let wide = biquad(low, .accelerate).run(noise, .fixed(512)), narrow = biquad(low, .accelerate).run(noise, .fixed(7))
        note("E-30 hp-90Hz-48k-order8 on noise, blocks of 7 against 512", Reference.deviation(narrow, wide), "dB")
        expectClose(narrow, wide, .deviationBelow(decibels: -50))
    }

    @Test func theNativeLoopIsBitExactWithTheScalarRecurrence() {
        // Two channels, any block sizes: the C loop is the recurrence, frame by frame.
        let input = [TestSignal.whiteNoise(count: 5_000, seed: 2_081), TestSignal.whiteNoise(count: 5_000, seed: 2_082)]
        for cascade in KernelFixtures.acceptance {
            let rig = biquad(cascade, channels: 2, .native)
            let output = rig.run(input, .irregular(seed: 9, upTo: 300))
            for channel in 0 ..< 2 {
                #expect(bits(output[channel]) == bits(Reference.cascadeSingle(input[channel], cascade.coefficients)), "\(cascade.name), channel \(channel)")
            }
        }
    }

    /// E-30's first figure, measured again: Float32 against double precision for a 1 kHz
    /// high-pass of orders 2 to 8 at 48 kHz, on full-scale noise. E-30 has 2e-6; measured here,
    /// relative to the output's peak: 8.0e-6 to 1.7e-5 on vDSP_biquad, 2.0e-6 to 4.8e-6 in the C
    /// loop (the acceptance figure, 1e-5 on the impulse response, is a different test). The bound
    /// keeps the measured behaviour from getting worse unnoticed.
    @Test(arguments: Bound.allCases)
    func bothImplementationsFollowTheDoubleReferenceOnNoise(bound: Bound) {
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 2_083)
        for cascade in KernelFixtures.acceptance where cascade.cutoff == 1_000 {
            let output = biquad(cascade, bound).run(noise, .fixed(512))
            let reference = Reference.cascade(noise, cascade.coefficients)
            expectClose(output, reference, .relativeToMaximum(bound == .native ? 1e-5 : 5e-5), "\(cascade.name), \(bound)")
            let peak = reference.map { abs($0) }.max()!
            note("E-30 \(cascade.name) \(bound) on noise, error relative to the peak", zip(output, reference).map { abs(Double($0) - $1) }.max()! / peak)
        }
    }

    @Test(arguments: Bound.allCases)
    func channelsAreFilteredIndependentlyAndStateIsCarriedAcrossCalls(bound: Bound) {
        let input = (0 ..< 3).map { TestSignal.whiteNoise(count: 2_048, seed: 300 + UInt64($0)) }
        let together = biquad(fixture, channels: 3, bound).run(input, .fixed(256))
        #expect(together[0] != together[1] && together[1] != together[2])
        for channel in 0 ..< 3 {
            #expect(bits(together[channel]) == bits(biquad(fixture, bound).run(input[channel], .fixed(256))), "channel \(channel), \(bound)")
        }
        // Two calls give what one call gives: the delay line bridges them.
        let rig = biquad(fixture, bound)
        let first = rig.run(Array(input[0][..<1_024]), .fixed(256)), second = rig.run(Array(input[0][1_024...]), .fixed(256))
        #expect(bits(first + second) == bits(together[0]))
        // A reset is a cold start: the same input gives the same output again.
        rig.reset()
        #expect(bits(rig.run(input[0], .fixed(256))) == bits(together[0]))
    }

    /// RT-6. The stress signals of WP-016 that end in silence: once the tail has fallen below
    /// 1e-20 the state is cleared, so the output reaches exact zero and never passes through the
    /// subnormal range on its way there. Without the flush at the end of each block the tail
    /// decays through some three hundred subnormal samples.
    @Test(arguments: Bound.allCases)
    func aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind(bound: Bound) throws {
        let count = 16_384, block = 64
        for name in ["impulse", "decaying-tail"] {
            let signal = try #require(StressFixture.signals(count: count).first { $0.name == name }).samples
            let lastInput = signal.lastIndex { $0 != 0 }!
            // From the first block boundary after the input has ended, only the kernel's state speaks.
            let quiet = (lastInput / block + 1) * block
            let output = biquad(fixture, bound).run(signal, .fixed(block))
            let tail = output[quiet...]
            #expect(!tail.contains { $0.isSubnormal }, "\(name), \(bound): a subnormal value came out of the kernel's memory")
            let firstZero = try #require(tail.firstIndex { $0 == 0 }, "\(name): the tail never reaches zero")
            #expect(output[firstZero...].allSatisfy { $0 == 0 }, "\(name): once at zero, the output stays there")
            #expect(firstZero < quiet + 2_000, "\(name): zero is reached while the tail is still above the subnormal range")
            // The tail was a real one: it started far above the floor.
            #expect(abs(output[quiet]) > 1e-12 || name == "decaying-tail")
            let lastAbove = output.lastIndex { abs($0) >= 1e-20 }!
            #expect(firstZero - lastAbove <= 2 * block, "\(name): zero within a block of falling below 1e-20, at most one more for the sections before the last")
        }
    }

    @Test func theSettlingTimeIsTheSlowestPolesDecayByAHundredDecibels() {
        // Both sections of the fixture have complex poles: the radius is √a2.
        let radius = fixture.coefficients[9].squareRoot()
        #expect(radius > fixture.coefficients[4].squareRoot())
        #expect(biquad(fixture, .accelerate).settling == Int((log(1e-5) / log(radius)).rounded(.up)))
        #expect(biquad(fixture, .native).settling == biquad(fixture, .accelerate).settling)
        // Real poles at 0.5 and 0.25: (1 − 0.5 z⁻¹)(1 − 0.25 z⁻¹).
        let real = KernelRig(ztd_biquad_create(1, 1, [1, 0, 0, -0.75, 0.125], ZTD_IMPLEMENTATION_NATIVE), channels: 1)
        #expect(real.settling == Int((log(1e-5) / log(0.5)).rounded(.up)))
        // No poles, no memory to settle; a pole on the unit circle never does.
        #expect(KernelRig(ztd_biquad_create(1, 1, [1, 2, 1, 0, 0], ZTD_IMPLEMENTATION_NATIVE), channels: 1).settling == 0)
        #expect(KernelRig(ztd_biquad_create(1, 1, [1, 0, 0, -2, 1], ZTD_IMPLEMENTATION_NATIVE), channels: 1).settling == 1 << 24)
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let good = fixture.coefficients
        for implementation in [ZTD_IMPLEMENTATION_NATIVE, ZTD_IMPLEMENTATION_ACCELERATE] {
            #expect(KernelRig(ztd_biquad_create(0, 2, good, implementation), channels: 0).isNull, "no channels")
            #expect(KernelRig(ztd_biquad_create(1, 0, good, implementation), channels: 1).isNull, "no sections")
            #expect(KernelRig(ztd_biquad_create(1, 2, nil, implementation), channels: 1).isNull, "no coefficients")
            var broken = good
            broken[7] = .nan
            #expect(KernelRig(ztd_biquad_create(1, 2, broken, implementation), channels: 1).isNull, "a coefficient that is not a number")
            broken[7] = .infinity
            #expect(KernelRig(ztd_biquad_create(1, 2, broken, implementation), channels: 1).isNull)
            #expect(KernelRig(ztd_biquad_create(1 << 20, 1 << 20, nil, implementation), channels: 1).isNull)
        }
        #expect(KernelRig(ztd_biquad_create(1, 2, good, ztd_implementation_t(rawValue: 5)), channels: 1).isNull, "an unknown implementation")
    }

    @Test func aBenchmarkIsRecordedForEachImplementation() {
        let eight = KernelFixtures.acceptance.first { $0.order == 8 }!   // four sections
        var results: [BenchmarkResult] = []
        for bound in Bound.allCases {
            for frames in [4, 512] {
                let rig = biquad(eight, bound)
                let call = rig.arena(frames: frames)
                results.append(Benchmark.measure("kernel.biquad.\(bound.rawValue).4-sections.\(frames)", iterations: frames == 4 ? 4_000 : 300) {
                    call.run(UInt32(frames))
                })
            }
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 4 && results.allSatisfy { $0.minimum > 0 })
    }
}

@Suite("Biquad cascade, single precision: live coefficients (WP-209)")
struct BiquadCoefficientUpdateTests {
    @Test(arguments: Bound.allCases)
    func aCoefficientUpdateKeepsTheFiltersMemory(bound: Bound) {
        let noise = TestSignal.whiteNoise(count: 2_048, seed: 209)
        let change = 1_024
        func run(resetting: Bool) -> [Float] {
            let rig = biquad(fixture, bound)
            let before = rig.run(Array(noise[..<change]), .fixed(256))
            if resetting { rig.reset() }
            rig.setValues(raised.coefficients)
            return before + rig.run(Array(noise[change...]), .fixed(256))
        }
        // The reference changes its coefficients at the same frame and keeps its two-sample memory.
        // On noise the kernel follows it as closely as it follows any double-precision reference
        // (see the E-30 figures in the suite above).
        let reference = Reference.cascade(noise, fixture.coefficients, change: (change, raised.coefficients))
        let peak = reference.map { abs($0) }.max()!
        let kept = run(resetting: false)
        expectClose(kept, reference, .relativeToMaximum(bound == .native ? 1e-5 : 5e-5), "\(bound)")
        let error = zip(kept, reference).map { abs(Double($0) - $1) }.max()! / peak
        note("WP-209 \(bound) noise across the update, error relative to the peak", error)
        // The control: with the memory cleared at the change the output is something else by four
        // orders of magnitude more, so the comparison above does tell the two apart.
        let cleared = run(resetting: true)
        let difference = zip(cleared[change...], reference[change...]).map { abs(Double($0) - $1) }.max()! / peak
        note("WP-209 \(bound) the same with the memory cleared at the update", difference)
        #expect(difference > 1_000 * error && difference > 1e-2, "\(bound): a filter that forgot its memory differs by \(difference)")
    }

    /// The same in the terms of WP-208's fixture: the impulse response, with the coefficients
    /// replaced while it rings, within 1e-5 of the double-precision reference.
    @Test(arguments: Bound.allCases, [3, 16, 64])
    func anUpdateInsideTheImpulseResponseKeepsItRinging(bound: Bound, change: Int) {
        let impulse = TestSignal.impulse(count: 2_048)
        let rig = biquad(fixture, bound)
        let before = rig.run(Array(impulse[..<change]))
        rig.setValues(raised.coefficients)
        let response = before + rig.run(Array(impulse[change...]), .fixed(512))
        let reference = Reference.cascade(impulse, fixture.coefficients, change: (change, raised.coefficients))
        expectClose(response, reference, .absolute(1e-5), "\(bound), changed at frame \(change)")
        // It is neither filter's own response: the memory of the first shapes the tail of the second.
        // (Sixty-four frames in, the response has decayed too far for the difference to show at −60 dB.)
        if change <= 16 {
            #expect(Reference.deviation(response, Reference.cascade(impulse, raised.coefficients)) > -60)
            #expect(Reference.deviation(response, Reference.cascade(impulse, fixture.coefficients)) > -60)
        }
    }

    @Test(arguments: Bound.allCases)
    func settingTheSameCoefficientsChangesNothing(bound: Bound) {
        let noise = TestSignal.whiteNoise(count: 2_048, seed: 2_090)
        let rig = biquad(fixture, bound)
        let first = rig.run(Array(noise[..<1_024]), .fixed(256))
        rig.setValues(fixture.coefficients)
        let second = rig.run(Array(noise[1_024...]), .fixed(256))
        #expect(bits(first + second) == bits(biquad(fixture, bound).run(noise, .fixed(256))), "\(bound): the delay line was not touched")
    }

    /// CLICK-1: a full-scale 1 kHz sine at 48 kHz runs through a cutoff step of a tenth of an octave.
    @Test(arguments: Bound.allCases, [512, 64])
    func aCutoffStepOfATenthOfAnOctaveMakesNoClick(bound: Bound, block: Int) {
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 40 * 512)
        let change = 20 * 512
        for (from, to, direction) in [(fixture, raised, "up"), (raised, fixture, "down")] {
            let rig = biquad(from, bound)
            let before = rig.run(Array(sine[..<change]), .fixed(block))
            rig.setValues(to.coefficients)
            let output = before + rig.run(Array(sine[change...]), .fixed(block))
            let ratio = clickRatio(output, change: change, block: block,
                                   steadyBefore: change - 4 * 512 ..< change, steadyAfter: sine.count - 4 * 512 ..< sine.count)
            #expect(ratio <= 1.5, "\(bound), \(direction), blocks of \(block): the largest step is \(ratio) times the steady one")
            if block == 512 { note("WP-209 CLICK-1 \(bound), a tenth of an octave \(direction): largest step over the steady one", ratio) }
            // The step did change the filter: the level after it is the new filter's. Ten whole
            // periods of the sine: its amplitude is √2 times its root mean square.
            let meanSquare = output[(sine.count - 480)...].reduce(0.0) { $0 + Double($1) * Double($1) } / 480
            expectClose((2 * meanSquare).squareRoot(), Reference.magnitude(to.coefficients, at: 1_000, sampleRate: 48_000), .relative(1e-4))
        }
    }

    @Test(arguments: Bound.allCases)
    func commandsThatAreNotForItChangeNothing(bound: Bound) {
        let noise = TestSignal.whiteNoise(count: 512, seed: 2_091)
        let rig = biquad(fixture, bound)
        let four = [Double](repeating: 0.5, count: 4)
        four.withUnsafeBufferPointer { rig.send(count: 4, values: UnsafeRawPointer($0.baseAddress)) }                 // not 5 · sections values
        rig.send(count: 10, values: nil)                                                                              // the right count, no payload
        raised.coefficients.withUnsafeBufferPointer {
            rig.send(kind: UInt32(ZTD_COMMAND_SET_ACTIVE), count: 10, values: UnsafeRawPointer($0.baseAddress))        // the plan's
            rig.send(kind: UInt32(ZTD_COMMAND_CUSTOM) + 3, count: 10, values: UnsafeRawPointer($0.baseAddress))        // somebody else's
        }
        rig.sendNothing()
        #expect(bits(rig.run(noise)) == bits(biquad(fixture, bound).run(noise)))
    }

    @Test(arguments: Bound.allCases)
    func processingAndCoefficientUpdatesAreAllocationFree(bound: Bound) {
        let rig = biquad(fixture, channels: 2, bound)
        let call = rig.arena(frames: 512)
        let up = rig.preparedCommand(doubles: raised.coefficients), down = rig.preparedCommand(doubles: fixture.coefficients)
        let command = call.command!
        expectNoAllocations("\(bound)") {
            var round = 0
            while round < 1_000 {
                if round % 20 == 0 { command(call.state, round % 40 == 0 ? up : down) }
                call.run(round % 5 == 0 ? 7 : 512)
                round += 1
            }
            call.reset(call.state)
        }
    }
}
