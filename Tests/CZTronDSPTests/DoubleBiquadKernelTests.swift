import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The fixture of WP-211, from the stress library: a Butterworth high-pass, 20 Hz, order 8, at
/// 96 kHz. Its poles lie within 1.3e-3 of z = 1.
private let lowCut = stressCascade("hp-20Hz-96k-order8")
private let fixture = KernelFixtures.acceptance[0]
private let raised = KernelFixtures.acceptance[1]

private func double(_ cascade: KernelFixtures.Cascade, channels: Int = 1) -> KernelRig {
    KernelRig(ztd_biquad_double_create(UInt32(channels), UInt32(cascade.sections), cascade.coefficients), channels: channels)
}

private func single(_ cascade: KernelFixtures.Cascade, _ bound: Bound) -> KernelRig {
    KernelRig(ztd_biquad_create(1, UInt32(cascade.sections), cascade.coefficients, bound.implementation), channels: 1)
}

/// The response of a kernel at the fixture's check frequencies, from its impulse response, in dB
/// against SciPy's `sosfreqz`. The impulse response is long enough to have died away (the slowest
/// pole decays by 100 dB in under 46 000 frames).
private func responseErrors(_ rig: KernelRig) -> [(frequency: Double, decibels: Double)] {
    let response = rig.run(TestSignal.impulse(count: 131_072), .fixed(512))
    return zip(KernelFixtures.highPass20HzResponseFrequencies, KernelFixtures.highPass20HzResponseMagnitudes).map { frequency, magnitude in
        (frequency, 20 * log10(Reference.spectrumMagnitude(response, at: frequency, sampleRate: 96_000) / magnitude))
    }
}

@Suite("Biquad cascade, double precision (WP-211)")
struct DoubleBiquadKernelTests {
    @Test func theStressLibraryAndTheGeneratorDescribeTheSameFilters() {
        // The generator's table is a copy of the library's; this keeps the two from drifting apart.
        let library = StressFixture.filtersNearZero + StressFixture.filtersNearNyquist
        #expect(library.count == KernelFixtures.stress.count)
        for filter in library {
            let cascade = KernelFixtures.stress.first { $0.name == filter.name }
            #expect(cascade != nil, "\(filter.name) has no cascade")
            guard let cascade else { continue }
            #expect(cascade.sampleRate == filter.sampleRate && cascade.cutoff == filter.cutoff && cascade.order == filter.order)
            #expect((cascade.response == .highPass) == (filter.response == .highPass))
            #expect(cascade.sections == (filter.order + 1) / 2)
            // What SciPy designed is that filter: −3.01 dB at the cutoff.
            expectClose(Reference.magnitude(cascade.coefficients, at: filter.cutoff, sampleRate: filter.sampleRate), 0.5.squareRoot(), .relative(1e-6), filter.name)
        }
        // SciPy's response and the one computed here from the coefficients are the same function.
        for (frequency, magnitude) in zip(KernelFixtures.highPass20HzResponseFrequencies, KernelFixtures.highPass20HzResponseMagnitudes) {
            expectClose(Reference.magnitude(lowCut.coefficients, at: frequency, sampleRate: 96_000), magnitude, .relative(1e-6), "\(frequency) Hz")
        }
    }

    @Test func theTwentyHertzHighPassIsWithinAHundredthOfADecibelOfTheReference() {
        let rig = double(lowCut)
        #expect(!rig.isNull && rig.latency == 0 && rig.hasCommand)
        let errors = responseErrors(rig)
        for (frequency, decibels) in errors {
            #expect(abs(decibels) <= 0.01, "\(frequency) Hz: \(decibels) dB from the reference")
        }
        note("WP-211 double kernel, hp-20Hz-96k-order8: largest response error", errors.map { abs($0.decibels) }.max()!, "dB")
    }

    /// The stress test of the stability note. The same fixture on the single-precision kernels
    /// misses the hundredth of a decibel: double state is what meets it. If the double kernel's
    /// state or arithmetic were narrowed to Float32, the test above would fail as these do.
    @Test(arguments: Bound.allCases)
    func singlePrecisionMissesThatMarkOnTheSameFixture(bound: Bound) {
        let errors = responseErrors(single(lowCut, bound))
        let worst = errors.map { abs($0.decibels) }.max()!
        note("WP-211 single kernel (\(bound)), hp-20Hz-96k-order8: largest response error", worst, "dB")
        #expect(worst > 0.01, "\(bound): Float32 would have been enough, and the double kernel would have no reason to exist")
    }

    /// REAL-3 decides by this figure (§6.3.8): the cascade in both precisions on an impulse and on
    /// seeded noise, 4 096 samples each; the larger deviation in dB relative to the output's peak.
    /// Above −100 dB the double path is chosen.
    @Test func theDeviationOfSingleFromDoubleSaysWhichFiltersNeedIt() {
        func deviation(_ cascade: KernelFixtures.Cascade) -> Double {
            [TestSignal.impulse(count: 4_096), TestSignal.whiteNoise(count: 4_096, seed: 0x5EED)].map { signal in
                Reference.deviation(single(cascade, .accelerate).run(signal, .fixed(512)), double(cascade).run(signal, .fixed(512)))
            }.max()!
        }
        for cascade in KernelFixtures.stress + [fixture] where cascade.name != "lp-10Hz-192k-order8" {
            note("single against double, \(cascade.name)", deviation(cascade), "dB")
        }
        // The 10 Hz low-pass in the form state hygiene can live with (see the test at the end of the suite).
        let lowest = stressCascade("lp-10Hz-192k-order8")
        let spread = KernelFixtures.Cascade(name: lowest.name, response: lowest.response, sampleRate: lowest.sampleRate, cutoff: lowest.cutoff,
                                            order: lowest.order, coefficients: withUnityGainSections(lowest.coefficients))
        note("single against double, lp-10Hz-192k-order8 with its gain spread over the sections", deviation(spread), "dB")
        #expect(deviation(spread) > -100)
        #expect(deviation(lowCut) > -100, "the fixture of WP-211 is one REAL-3 sends to the double kernel")
        #expect(deviation(stressCascade("hp-90Hz-48k-order8")) > -100, "and so is E-30's 90 Hz filter")
        #expect(deviation(stressCascade("lp-0.45fs-48k-order8")) < -100, "a filter far from z = 1 stays in single precision")
    }

    @Test func theKernelIsItsDefinitionBitForBitForAnyBlockSizes() {
        let input = [TestSignal.whiteNoise(count: 6_000, seed: 211), TestSignal.whiteNoise(count: 6_000, seed: 2_110)]
        for cascade in [lowCut, fixture, stressCascade("hp-90Hz-48k-order8"), stressCascade("lp-0.45fs-48k-order8")] {
            let expected = input.map { bits(Reference.cascadeTransposed($0, cascade.coefficients)) }
            for blocks in [Blocks.whole, .fixed(1), .fixed(7), .fixed(512), .irregular(seed: 21, upTo: 700)] {
                #expect(double(cascade, channels: 2).run(input, blocks).map(bits) == expected, "\(cascade.name)")
            }
        }
    }

    @Test func aLiveExchangeKeepsTheState() {
        let noise = TestSignal.whiteNoise(count: 4_096, seed: 2_111)
        let change = 2_048
        for (from, to) in [(fixture, raised), (raised, fixture)] {
            let rig = double(from)
            let before = rig.run(Array(noise[..<change]), .irregular(seed: 3, upTo: 300))
            rig.setValues(to.coefficients)
            let output = before + rig.run(Array(noise[change...]), .irregular(seed: 4, upTo: 300))
            // The reference exchanges its coefficients at the same frame and keeps s1 and s2.
            #expect(bits(output) == bits(Reference.cascadeTransposed(noise, from.coefficients, change: (change, to.coefficients))))

            // The control: a kernel whose state was cleared at the exchange gives something else.
            let cleared = double(from)
            let first = cleared.run(Array(noise[..<change]))
            cleared.reset()
            cleared.setValues(to.coefficients)
            let other = first + cleared.run(Array(noise[change...]))
            #expect(Reference.deviation(other, output) > -40, "state kept and state lost are far apart")
        }
        // An exchange for the same coefficients changes nothing.
        let rig = double(lowCut)
        let first = rig.run(Array(noise[..<change]))
        rig.setValues(lowCut.coefficients)
        #expect(bits(first + rig.run(Array(noise[change...]))) == bits(double(lowCut).run(noise)))
    }

    @Test func theExchangeMakesNoClickForATenthOfAnOctave() {
        let sine = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 40 * 512)
        let change = 20 * 512
        let rig = double(fixture)
        let before = rig.run(Array(sine[..<change]), .fixed(512))
        rig.setValues(raised.coefficients)
        let output = before + rig.run(Array(sine[change...]), .fixed(512))
        let ratio = clickRatio(output, change: change, block: 512, steadyBefore: change - 2_048 ..< change, steadyAfter: sine.count - 2_048 ..< sine.count)
        #expect(ratio <= 1.5, "the largest step is \(ratio) times the steady one")
        note("WP-211 CLICK-1, a tenth of an octave up: largest step over the steady one", ratio)
    }

    /// RT-6. The state is double, so without the flush it would decay through 300 decades before
    /// reaching zero, and the Float32 output would pass through its whole subnormal range.
    @Test func aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind() throws {
        let count = 16_384, block = 64
        for name in ["impulse", "decaying-tail"] {
            let signal = try #require(StressFixture.signals(count: count).first { $0.name == name }).samples
            let quiet = (signal.lastIndex { $0 != 0 }! / block + 1) * block
            let output = double(fixture).run(signal, .fixed(block))
            let tail = output[quiet...]
            #expect(!tail.contains { $0.isSubnormal }, "\(name): a subnormal value came out of the kernel's memory")
            let firstZero = try #require(tail.firstIndex { $0 == 0 }, "\(name): the tail never reaches zero")
            #expect(output[firstZero...].allSatisfy { $0 == 0 })
            let lastAbove = output.lastIndex { abs($0) >= 1e-20 }!
            #expect(firstZero - lastAbove <= 2 * block, "\(name): zero within two blocks of falling below 1e-20")
        }
    }

    /// A limit of RT-6, shown on the lowest corner of the stress library. The rule clears every
    /// state value below 1e-20, whatever the section it belongs to. SciPy gives the whole gain of
    /// a cascade to its first section: for a 10 Hz low-pass of order 8 at 192 kHz that is 5e-31,
    /// and the first section works some 23 decades below the signal. Its state is legitimate and
    /// far from subnormal, and it is cleared at the end of every block: the filter is destroyed.
    /// With the same gain spread over the sections the kernel follows its definition. State
    /// hygiene therefore needs a cascade whose sections all work near the level of the signal;
    /// that is the designer's to guarantee (see Docs/Numerics/biquad-double.md).
    @Test func stateHygieneNeedsEverySectionToWorkNearTheLevelOfTheSignal() {
        let lowest = stressCascade("lp-10Hz-192k-order8")
        #expect(abs(gainAtZero(lowest.coefficients, section: 0)) < 1e-20, "the first section alone attenuates by more than the floor")
        let spread = withUnityGainSections(lowest.coefficients)
        for section in 0 ..< 4 { expectClose(gainAtZero(spread, section: section), 1, .relative(1e-12)) }
        for frequency in [0.0, 5, 10, 20, 100] {
            expectClose(Reference.magnitude(spread, at: frequency, sampleRate: 192_000), Reference.magnitude(lowest.coefficients, at: frequency, sampleRate: 192_000), .relative(1e-9), "the same filter at \(frequency) Hz")
        }
        let noise = TestSignal.whiteNoise(count: 40_000, seed: 0x10F)
        // With the gain spread: the definition, within what clearing a start-up state below 1e-20 can cost.
        let good = KernelRig(ztd_biquad_double_create(1, 4, spread), channels: 1).run(noise, .fixed(512))
        let goodReference = Reference.cascadeTransposed(noise, spread)
        expectClose(good, goodReference, .deviationBelow(decibels: -140))
        note("lp-10Hz-192k-order8, gain spread over the sections: double kernel against its definition", Reference.deviation(good, goodReference), "dB")
        // As SciPy returns it: every kernel that flushes value by value loses the filter.
        let reference = Reference.cascadeTransposed(noise, lowest.coefficients)
        expectClose(reference, goodReference, .deviationBelow(decibels: -100), "without the flush the two forms agree")
        let lost = KernelRig(ztd_biquad_double_create(1, 4, lowest.coefficients), channels: 1).run(noise, .fixed(512))
        let single = KernelRig(ztd_biquad_create(1, 4, lowest.coefficients, ZTD_IMPLEMENTATION_ACCELERATE), channels: 1).run(noise, .fixed(512))
        note("lp-10Hz-192k-order8 as SciPy returns it: double kernel against its definition", Reference.deviation(lost, reference), "dB")
        note("lp-10Hz-192k-order8 as SciPy returns it: vDSP_biquad kernel against the double definition", Reference.deviation(single, reference), "dB")
        #expect(Reference.deviation(lost, reference) > -20 && Reference.deviation(single, reference) > -20, "the hazard is real")
        // vDSP_biquadm's memory is cleared as a whole, and only in silence: it is not affected.
        let whole = KernelRig(ztd_biquadm_create(1, 4, lowest.coefficients), channels: 1).run(noise, .fixed(512))
        note("lp-10Hz-192k-order8 as SciPy returns it: vDSP_biquadm kernel against the double definition", Reference.deviation(whole, reference), "dB")
    }

    @Test func commandsThatAreNotForItChangeNothingAndAResetIsAColdStart() {
        let noise = TestSignal.whiteNoise(count: 512, seed: 2_112)
        let rig = double(fixture)
        let expected = rig.run(noise)
        rig.reset()
        let four = [Double](repeating: 0.5, count: 4)
        four.withUnsafeBufferPointer { rig.send(count: 4, values: UnsafeRawPointer($0.baseAddress)) }
        rig.send(count: 10, values: nil)
        raised.coefficients.withUnsafeBufferPointer { rig.send(kind: UInt32(ZTD_COMMAND_CUSTOM), count: 10, values: UnsafeRawPointer($0.baseAddress)) }
        rig.sendNothing()
        #expect(bits(rig.run(noise)) == bits(expected))
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        let good = fixture.coefficients
        #expect(KernelRig(ztd_biquad_double_create(0, 2, good), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_biquad_double_create(1, 0, good), channels: 1).isNull, "no sections")
        #expect(KernelRig(ztd_biquad_double_create(1, 2, nil), channels: 1).isNull, "no coefficients")
        var broken = good
        broken[0] = -.infinity
        #expect(KernelRig(ztd_biquad_double_create(1, 2, broken), channels: 1).isNull, "a coefficient that is not a number")
        #expect(double(lowCut).settling == 1 << 24 || double(lowCut).settling > 40_000, "a 20 Hz corner takes long to settle")
    }

    @Test func processingAndExchangesAreAllocationFree() {
        let rig = double(lowCut, channels: 2)
        let call = rig.arena(frames: 512)
        let other = rig.preparedCommand(doubles: stressCascade("hp-90Hz-48k-order8").coefficients)
        let back = rig.preparedCommand(doubles: lowCut.coefficients)
        let command = call.command!
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                if round % 20 == 0 { command(call.state, round % 40 == 0 ? other : back) }
                call.run(round % 5 == 0 ? 7 : 512)
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        let eight = KernelFixtures.acceptance.first { $0.order == 8 }!
        let rig = double(eight)
        let call = rig.arena(frames: 512)
        let result = Benchmark.measure("kernel.biquad-double.4-sections.512", iterations: 200) { call.run(512) }
        Benchmark.record([result])
        note(result.name, result.minimum, "ns")
        #expect(result.minimum > 0)
    }

    /// RT-6 and the block size (ztd_kernels.h, "What that means for block sizes"). RT-6 fixes
    /// the flush "at the end of each block", so the kernel is its recurrence with every state
    /// value below the floor set to zero where its blocks end: bit for bit that, for any cut.
    /// The header said "block-size invariant bit for bit" without the condition. The case that
    /// shows it is the lowest corner of the precision grid with its gain spread: its later
    /// sections start from silence through values far below the floor, and blocks of 1 clear
    /// what blocks of 512 keep. Two cuts agree, bit for bit, as long as neither has cleared a
    /// value the other kept: a cut that shares the blocks of another until every section has
    /// left the floor behind gives the other's output.
    @Test func theKernelIsItsRecurrenceWithTheFlushWhereItsBlocksEnd() {
        let spread = withUnityGainSections(stressCascade("lp-10Hz-192k-order8").coefficients)
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 0x10F)
        /// The recurrence of the header, in double precision, with RT-6 at the end of each block.
        func recurrence(_ sizes: [Int]) -> [Float] {
            var state = [Double](repeating: 0, count: 8)
            var result: [Float] = []
            var position = 0
            for size in sizes {
                for frame in position ..< position + size {
                    var value = Double(noise[frame])
                    for section in 0 ..< 4 {
                        let output = spread[5 * section] * value + state[2 * section]
                        state[2 * section] = spread[5 * section + 1] * value - spread[5 * section + 3] * output + state[2 * section + 1]
                        state[2 * section + 1] = spread[5 * section + 2] * value - spread[5 * section + 4] * output
                        value = output
                    }
                    result.append(Float(value))
                }
                position += size
                for index in state.indices where state[index] < 1e-20 && state[index] > -1e-20 { state[index] = 0 }
            }
            return result
        }
        let single = Blocks.fixed(1), large = Blocks.fixed(512)
        // Blocks of one frame for the first 2 048 frames, of 512 from there on.
        let settled = 2_048
        let shared = Blocks { total in [Int](repeating: 1, count: min(settled, total)) + Blocks.fixed(512).cut(max(total - settled, 0)) }
        for blocks in [single, large, shared, .fixed(7), .irregular(seed: 6, upTo: 300)] {
            let kernel = KernelRig(ztd_biquad_double_create(1, 4, spread), channels: 1).run(noise, blocks)
            #expect(bits(kernel) == bits(recurrence(blocks.cut(noise.count))), "the kernel is the recurrence with the flush where its blocks end")
        }

        // The cuts differ while a section starts below the floor …
        let framewise = recurrence(single.cut(noise.count)), blockwise = recurrence(large.cut(noise.count))
        let first = framewise.indices.first { (index: Int) -> Bool in framewise[index] != blockwise[index] }
        let peak = Double(framewise.map { abs($0) }.max() ?? 0)
        let difference = zip(framewise, blockwise).map { (pair: (Float, Float)) -> Double in abs(Double(pair.0) - Double(pair.1)) }.max() ?? 0
        note("lp-10Hz-192k-order8, gain spread: blocks of 1 against 512, first frame that differs", Double(first ?? -1))
        note("lp-10Hz-192k-order8, gain spread: blocks of 1 against 512, largest difference", difference)
        note("lp-10Hz-192k-order8, gain spread: blocks of 1 against 512, peak of the output", peak)
        #expect(first != nil && (first ?? 512) < 512, "blocks of 1 clear what blocks of 512 keep: \(String(describing: first))")
        #expect(difference > 0 && difference < 1e-6 * peak, "by little: \(difference) at a peak of \(peak)")
        // … and not once every section has left the floor behind: the cut that shares the first 2 048 blocks.
        #expect(bits(recurrence(shared.cut(noise.count))) == bits(framewise), "the same blocks while a state value is below the floor: the same output")
    }
}
