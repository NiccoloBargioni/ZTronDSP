import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The fixture of WP-208, and the same filter a tenth of an octave up.
private let fixture = KernelFixtures.acceptance[0]
private let raised = KernelFixtures.acceptance[1]

private func multichannel(_ cascade: KernelFixtures.Cascade, channels: Int) -> KernelRig {
    KernelRig(ztd_biquadm_create(UInt32(channels), UInt32(cascade.sections), cascade.coefficients), channels: channels)
}

private func mono(_ cascade: KernelFixtures.Cascade, _ bound: Bound) -> KernelRig {
    KernelRig(ztd_biquad_create(1, UInt32(cascade.sections), cascade.coefficients, bound.implementation), channels: 1)
}

@Suite("Biquad cascade, single precision, many channels (WP-210)")
struct MultichannelBiquadKernelTests {
    /// vDSP_biquadm and vDSP_biquad are two routines: they agree to the accuracy either has
    /// against a double-precision reference, not bit for bit (vDSP_biquadm does not even round a
    /// channel the same way in every position: it filters channels in pairs and an odd one by
    /// another path). "Equals" is therefore held to the tolerance of the fixture: 1e-5 on the
    /// impulse response, as WP-208 states it. On full-scale noise the multichannel kernel is
    /// within 1e-5 of the peak of the double-precision reference and of the C-loop kernel; the
    /// vDSP_biquad kernel is itself up to 1.7e-5 from that reference there (E-30, measured again
    /// in the suite of WP-208), so against it the bound is the one that suite uses, 5e-5.
    @Test(arguments: [1, 2, 3, 5, 8])
    func eachChannelEqualsTheMonoKernel(channels: Int) {
        let rig = multichannel(fixture, channels: channels)
        #expect(!rig.isNull && rig.latency == 0 && rig.hasCommand)
        #expect(rig.settling == mono(fixture, .accelerate).settling)

        // The impulse response, one channel at a time so that every channel is seen to be its own.
        for channel in 0 ..< channels {
            var input = [[Float]](repeating: TestSignal.silence(count: 2_048), count: channels)
            input[channel] = TestSignal.impulse(count: 2_048)
            let output = multichannel(fixture, channels: channels).run(input, .fixed(512))
            for bound in Bound.allCases {
                expectClose(output[channel], mono(fixture, bound).run(input[channel], .fixed(512)), .absolute(1e-5), "channel \(channel) of \(channels), mono \(bound)")
            }
            expectClose(output[channel], Reference.cascade(input[channel], fixture.coefficients), .absolute(1e-5))
            for other in 0 ..< channels where other != channel {
                #expect(output[other].allSatisfy { $0 == 0 }, "nothing leaks from channel \(channel) into channel \(other)")
            }
        }

        // Noise, a different one in every channel.
        let input = (0 ..< channels).map { TestSignal.whiteNoise(count: 4_096, seed: 210 + UInt64($0)) }
        let output = rig.run(input, .fixed(512))
        var worst = (accelerate: -Double.infinity, native: -Double.infinity, reference: -Double.infinity)
        for channel in 0 ..< channels {
            let vector = mono(fixture, .accelerate).run(input[channel], .fixed(512))
            let loop = mono(fixture, .native).run(input[channel], .fixed(512))
            let reference = Reference.cascade(input[channel], fixture.coefficients)
            expectClose(output[channel], vector, .relativeToMaximum(5e-5), "channel \(channel) of \(channels) against the vDSP_biquad kernel")
            expectClose(output[channel], loop, .relativeToMaximum(1e-5), "channel \(channel) of \(channels) against the C-loop kernel")
            expectClose(output[channel], reference, .relativeToMaximum(1e-5), "channel \(channel) of \(channels) against the double reference")
            worst.accelerate = max(worst.accelerate, Reference.deviation(output[channel], vector))
            worst.native = max(worst.native, Reference.deviation(output[channel], loop))
            worst.reference = max(worst.reference, Reference.deviation(output[channel], reference))
        }
        note("WP-210 \(channels) channels on noise against the mono vDSP_biquad kernel", worst.accelerate, "dB")
        note("WP-210 \(channels) channels on noise against the mono C-loop kernel", worst.native, "dB")
        note("WP-210 \(channels) channels on noise against the double reference", worst.reference, "dB")
    }

    @Test func aChannelsOutputDoesNotDependOnTheOtherChannels() {
        let a = TestSignal.whiteNoise(count: 2_048, seed: 2_101), b = TestSignal.whiteNoise(count: 2_048, seed: 2_102)
        let c = TestSignal.whiteNoise(count: 2_048, seed: 2_103), silence = TestSignal.silence(count: 2_048)
        // Four channels are two pairs to vDSP_biquadm: what shares a pair with a channel changes nothing.
        let first = multichannel(fixture, channels: 4).run([a, b, c, a], .fixed(256))
        let second = multichannel(fixture, channels: 4).run([a, silence, c, b], .fixed(256))
        #expect(bits(first[0]) == bits(second[0]) && bits(first[2]) == bits(second[2]))
        #expect(bits(first[0]) == bits(first[3]), "the same signal in two channels gives the same output")
        #expect(second[1].allSatisfy { $0 == 0 })
    }

    @Test(arguments: [2, 3])
    func blockSizesFrom64To512AreBitIdenticalAnd1And7WithinMinus100dB(channels: Int) {
        for (name, signal) in [("impulse", TestSignal.impulse(count: 1_024)), ("noise", TestSignal.whiteNoise(count: 8_192, seed: 2_104))] {
            let input = [[Float]](repeating: signal, count: channels)
            let reference = multichannel(fixture, channels: channels).run(input, .fixed(512))
            // As for the mono kernel: bit for bit while the response is one. Once it has fallen
            // below 1e-20 the memory is cleared at the end of a block, wherever that is.
            let alive = reference[0].lastIndex { abs($0) >= 1e-15 }! + 1
            #expect(alive > 512)
            for size in [64, 128, 256] {
                let output = multichannel(fixture, channels: channels).run(input, .fixed(size))
                #expect(output.map { bits(Array($0[..<alive])) } == reference.map { bits(Array($0[..<alive])) }, "\(name), \(channels) channels, blocks of \(size)")
            }
            for size in [1, 7] {
                let output = multichannel(fixture, channels: channels).run(input, .fixed(size))
                for channel in 0 ..< channels {
                    expectClose(output[channel], reference[channel], .deviationBelow(decibels: -100), "\(name), channel \(channel), blocks of \(size)")
                }
                note("WP-210 \(name), \(channels) channels, blocks of \(size) against 512", output.indices.map { Reference.deviation(output[$0], reference[$0]) }.max()!, "dB")
            }
        }
    }

    @Test(arguments: [1, 2, 3])
    func aCoefficientUpdateKeepsTheFiltersMemory(channels: Int) {
        let noise = (0 ..< channels).map { TestSignal.whiteNoise(count: 2_048, seed: 2_105 + UInt64($0)) }
        let change = 1_024
        func run(resetting: Bool) -> [[Float]] {
            let rig = multichannel(fixture, channels: channels)
            let before = rig.run(noise.map { Array($0[..<change]) }, .fixed(256))
            if resetting { rig.reset() }
            rig.setValues(raised.coefficients)
            let after = rig.run(noise.map { Array($0[change...]) }, .fixed(256))
            return (0 ..< channels).map { before[$0] + after[$0] }
        }
        let kept = run(resetting: false), cleared = run(resetting: true)
        for channel in 0 ..< channels {
            let reference = Reference.cascade(noise[channel], fixture.coefficients, change: (change, raised.coefficients))
            let peak = reference.map { abs($0) }.max()!
            expectClose(kept[channel], reference, .relativeToMaximum(1e-5), "channel \(channel) of \(channels)")
            let error = zip(kept[channel], reference).map { abs(Double($0) - $1) }.max()! / peak
            let difference = zip(cleared[channel][change...], reference[change...]).map { abs(Double($0) - $1) }.max()! / peak
            #expect(difference > 1_000 * error && difference > 1e-2, "a filter that forgot its memory differs by \(difference)")
        }
        // The same coefficients again change nothing that can be heard. (Not "bit for bit": once
        // its setter has been called, vDSP_biquadm rounds a little differently.)
        let rig = multichannel(fixture, channels: channels)
        let first = rig.run(noise.map { Array($0[..<change]) }, .fixed(256))
        rig.setValues(fixture.coefficients)
        let second = rig.run(noise.map { Array($0[change...]) }, .fixed(256))
        let whole = multichannel(fixture, channels: channels).run(noise, .fixed(256))
        for channel in 0 ..< channels {
            expectClose(first[channel] + second[channel], whole[channel], .deviationBelow(decibels: -100), "channel \(channel) of \(channels)")
            if channel == 0 { note("WP-210 \(channels) channels, the same coefficients set again, against an undisturbed run", Reference.deviation(first[channel] + second[channel], whole[channel]), "dB") }
        }
    }

    @Test func aCutoffStepOfATenthOfAnOctaveMakesNoClick() {
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 40 * 512)
        let change = 20 * 512
        let rig = multichannel(fixture, channels: 3)
        let before = rig.run([[Float]](repeating: Array(sine[..<change]), count: 3), .fixed(512))
        rig.setValues(raised.coefficients)
        let after = rig.run([[Float]](repeating: Array(sine[change...]), count: 3), .fixed(512))
        for channel in 0 ..< 3 {
            let ratio = clickRatio(before[channel] + after[channel], change: change, block: 512,
                                   steadyBefore: change - 2_048 ..< change, steadyAfter: sine.count - 2_048 ..< sine.count)
            #expect(ratio <= 1.5, "channel \(channel): the largest step is \(ratio) times the steady one")
        }
    }

    /// RT-6. vDSP_biquadm keeps its memory inside the setup, where it cannot be flushed value by
    /// value: the kernel clears it as a whole once input and output have been below 1e-20 for as
    /// long as the cascade has memory. The tail reaches exact zero and passes no subnormal value.
    @Test(arguments: [1, 2, 3])
    func aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind(channels: Int) throws {
        let count = 16_384, block = 64
        for name in ["impulse", "decaying-tail"] {
            let signal = try #require(StressFixture.signals(count: count).first { $0.name == name }).samples
            let quiet = (signal.lastIndex { $0 != 0 }! / block + 1) * block
            let output = multichannel(fixture, channels: channels).run([[Float]](repeating: signal, count: channels), .fixed(block))
            for channel in 0 ..< channels {
                let tail = output[channel][quiet...]
                #expect(!tail.contains { $0.isSubnormal }, "\(name), channel \(channel) of \(channels): a subnormal value came out of the kernel's memory")
                let firstZero = try #require(tail.firstIndex { $0 == 0 }, "\(name): the tail never reaches zero")
                #expect(output[channel][firstZero...].allSatisfy { $0 == 0 })
                let lastAbove = output[channel].lastIndex { abs($0) >= 1e-20 }!
                #expect(firstZero - lastAbove <= 2 * block, "\(name): zero within two blocks of falling below 1e-20")
            }
        }
    }

    /// RT-6 for one channel among others: a channel that falls silent while the others carry
    /// signal leaves nothing behind either, and comes back as a filter that starts from rest.
    @Test(arguments: [2, 3, 4, 8])
    func aChannelThatFallsSilentAloneLeavesNothingBehind(channels: Int) {
        let count = 20_480, block = 512
        var input = (0 ..< channels).map { TestSignal.whiteNoise(count: count, seed: 400 + UInt64($0)).map { $0 * 0.5 } }
        input[0] = TestSignal.impulse(count: count)                       // one impulse, then silence
        let output = multichannel(fixture, channels: channels).run(input, .fixed(block))
        let lastAbove = output[0].lastIndex { abs($0) >= 1e-20 }!
        #expect(!output[0].contains { $0.isSubnormal }, "\(channels) channels: \(output[0].filter { $0.isSubnormal }.count) subnormal samples came out of the silent channel")
        let firstZero = output[0][lastAbove...].firstIndex { $0 == 0 }!
        #expect(output[0][firstZero...].allSatisfy { $0 == 0 }, "once it is zero it stays zero")
        #expect(firstZero - lastAbove <= 3 * block, "zero within three blocks of falling below 1e-20: \(firstZero - lastAbove) frames")
        // The channels that carry signal are what they are without the silent one beside them.
        for channel in 1 ..< channels {
            expectClose(output[channel], mono(fixture, .native).run(input[channel], .fixed(block)), .relativeToMaximum(1e-5), "channel \(channel) of \(channels)")
        }

        // The silent channel is given signal again, at a block boundary and in the middle of
        // one: it answers as a kernel that starts from rest, to the last bit.
        for offset in [0, 100] {
            let rig = multichannel(fixture, channels: channels)
            var first = input
            for channel in 0 ..< channels { first[channel] = Array(first[channel][..<8_192]) }
            _ = rig.run(first, .fixed(block))
            let burst = TestSignal.whiteNoise(count: 4_096, seed: 9).map { $0 * 0.25 }
            var second = (0 ..< channels).map { Array(input[$0][8_192 ..< 8_192 + 4_096]) }
            second[0] = [Float](repeating: 0, count: offset) + burst.dropLast(offset)
            let woken = rig.run(second, .fixed(block))
            var fresh = [[Float]](repeating: TestSignal.silence(count: 4_096), count: channels)
            fresh[0] = second[0]
            let rested = multichannel(fixture, channels: channels).run(fresh, .fixed(block))
            #expect(woken[0] == rested[0], "\(channels) channels, signal back \(offset) frames into a block: the channel starts from rest")
        }
    }

    /// A parked channel takes a change of coefficients when it wakes.
    @Test func aParkedChannelWakesOnTheCoefficientsOfTheDay() {
        let rig = multichannel(fixture, channels: 3)
        var input = (0 ..< 3).map { TestSignal.whiteNoise(count: 4_096, seed: 500 + UInt64($0)).map { $0 * 0.5 } }
        input[1] = TestSignal.silence(count: 4_096)
        _ = rig.run(input, .fixed(512))                                    // channel 1 is parked by now
        rig.setValues(raised.coefficients)
        let burst = TestSignal.whiteNoise(count: 2_048, seed: 11)
        let output = rig.run([Array(input[0][..<2_048]), burst, Array(input[2][..<2_048])], .fixed(512))
        var alone = [[Float]](repeating: TestSignal.silence(count: 2_048), count: 3)
        alone[1] = burst
        let expected = multichannel(raised, channels: 3).run(alone, .fixed(512))
        #expect(output[1] == expected[1], "the channel that was parked runs on the new coefficients")
        // And a reset brings every channel back to rest on the coefficients in force.
        rig.reset()
        #expect(rig.run(alone, .fixed(512))[1] == expected[1])
    }

    /// The other side of that rule: a response that is silent for a moment while the cascade
    /// still holds something must not be cut off.
    @Test(arguments: [1, 2, 3], [1, 2, 5, 64])
    func aQuietStretchInsideAResponseIsNotTakenForSilence(channels: Int, block: Int) {
        // Three sections that each delay by two frames: an impulse leaves six frames later, and for
        // the five frames between, input and output are both exactly zero.
        let delay: [Double] = [0, 0, 1, 0, 0]
        let rig = KernelRig(ztd_biquadm_create(UInt32(channels), 3, delay + delay + delay), channels: channels)
        let impulse = TestSignal.impulse(count: 200, at: 40, amplitude: 0.75)
        let output = rig.run([[Float]](repeating: impulse, count: channels), .fixed(block))
        for channel in 0 ..< channels {
            #expect(output[channel] == TestSignal.impulse(count: 200, at: 46, amplitude: 0.75), "channel \(channel), blocks of \(block)")
        }
        // (1 + z⁻²)² rings 1, 0, 2, 0, 1: a single quiet frame between loud ones, twice.
        let comb: [Double] = [1, 0, 1, 0, 0]
        let ringing = KernelRig(ztd_biquadm_create(UInt32(channels), 2, comb + comb), channels: channels)
        let response = ringing.run([[Float]](repeating: TestSignal.impulse(count: 64), count: channels), .fixed(block))
        for channel in 0 ..< channels { #expect(Array(response[channel][..<6]) == [1, 0, 2, 0, 1, 0]) }
    }

    @Test func commandsThatAreNotForItChangeNothingAndAResetIsAColdStart() {
        let noise = [TestSignal.whiteNoise(count: 512, seed: 2_106), TestSignal.whiteNoise(count: 512, seed: 2_107)]
        let rig = multichannel(fixture, channels: 2)
        let expected = rig.run(noise)
        rig.reset()
        let four = [Double](repeating: 0.5, count: 4)
        four.withUnsafeBufferPointer { rig.send(count: 4, values: UnsafeRawPointer($0.baseAddress)) }
        rig.send(count: 10, values: nil)
        raised.coefficients.withUnsafeBufferPointer { rig.send(kind: UInt32(ZTD_COMMAND_SET_ACTIVE), count: 10, values: UnsafeRawPointer($0.baseAddress)) }
        rig.sendNothing()
        #expect(rig.run(noise).map(bits) == expected.map(bits), "after a reset the same input gives the same output; no stray command changed the filter")
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let good = fixture.coefficients
        #expect(KernelRig(ztd_biquadm_create(0, 2, good), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_biquadm_create(2, 0, good), channels: 2).isNull, "no sections")
        #expect(KernelRig(ztd_biquadm_create(2, 2, nil), channels: 2).isNull, "no coefficients")
        var broken = good
        broken[2] = .nan
        #expect(KernelRig(ztd_biquadm_create(2, 2, broken), channels: 2).isNull, "a coefficient that is not a number")
    }

    @Test func processingUpdatesAndResetsAreAllocationFree() {
        let rig = multichannel(fixture, channels: 3)
        let loud = rig.arena(frames: 512), silent = rig.arena(frames: 512, amplitude: 0)
        let up = rig.preparedCommand(doubles: raised.coefficients), down = rig.preparedCommand(doubles: fixture.coefficients)
        let command = loud.command!
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                if round % 20 == 0 { command(loud.state, round % 40 == 0 ? up : down) }
                // Three blocks of silence in every eight: long enough for the tail to fall below
                // the floor, so the reset of the state that the hygiene rule makes is audited too.
                if round % 8 >= 5 { silent.run(512) } else { loud.run(round % 5 == 0 ? 7 : 512) }
                round += 1
            }
            loud.reset(loud.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        let eight = KernelFixtures.acceptance.first { $0.order == 8 }!
        var results: [BenchmarkResult] = []
        for channels in [2, 8] {
            let rig = multichannel(eight, channels: channels)
            let call = rig.arena(frames: 512)
            results.append(Benchmark.measure("kernel.biquadm.4-sections.\(channels)-channels.512", iterations: 200) { call.run(512) })
            // The same again once coefficients have been set live: the setter must not leave the kernel on a slower path.
            rig.setValues(eight.coefficients)
            results.append(Benchmark.measure("kernel.biquadm.4-sections.\(channels)-channels.512.after-update", iterations: 200) { call.run(512) })
            // The same work on the mono-setup kernel, for the comparison the register's alternative is about.
            let each = KernelRig(ztd_biquad_create(UInt32(channels), 4, eight.coefficients, ZTD_IMPLEMENTATION_ACCELERATE), channels: channels)
            let other = each.arena(frames: 512)
            results.append(Benchmark.measure("kernel.biquad.accelerate.4-sections.\(channels)-channels.512", iterations: 200) { other.run(512) })
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 6 && results.allSatisfy { $0.minimum > 0 })
    }
}
