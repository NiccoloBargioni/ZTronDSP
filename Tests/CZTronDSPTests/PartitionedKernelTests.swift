import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

private func partitioned(_ taps: [Float], partition: Int, channels: Int = 1, latency: Int = 0) -> KernelRig {
    KernelRig(ztd_partitioned_create(UInt32(channels), taps, UInt32(taps.count), UInt32(partition), UInt32(latency)), channels: channels)
}

private func direct(_ taps: [Float], channels: Int = 1) -> KernelRig {
    KernelRig(ztd_fir_create(UInt32(channels), taps, UInt32(taps.count), 0, 0), channels: channels)
}

/// The spectrum the kernel holds for partition `index`: partition + 1 bins, real and imaginary.
private func spectrum(_ rig: KernelRig, _ index: Int, partition: Int) -> (count: Int, real: [Float], imaginary: [Float]) {
    var real = [Float](repeating: .nan, count: partition + 1), imaginary = [Float](repeating: .nan, count: partition + 1)
    let count = rig.withKernel { ztd_partitioned_spectrum($0, UInt32(index), &real, &imaginary) }
    return (Int(count), real, imaginary)
}

@Suite("Partitioned convolution: structure and kernel spectra (WP-214)")
struct PartitionedStructureTests {
    /// The transform of one partition from its definition, in double precision: the partition's
    /// taps, zero-padded to twice the partition length; bins 0 … partition.
    private func transform(_ taps: [Float], partition: Int, index: Int) -> (real: [Double], imaginary: [Double]) {
        let length = 2 * partition
        let part = (0 ..< partition).map { tap -> Double in
            let source = index * partition + tap
            return source < taps.count ? Double(taps[source]) : 0
        }
        var real = [Double](repeating: 0, count: partition + 1), imaginary = [Double](repeating: 0, count: partition + 1)
        for bin in 0 ... partition {
            for (n, value) in part.enumerated() where value != 0 {
                let angle = -2 * Double.pi * Double((bin * n) % length) / Double(length)
                real[bin] += value * cos(angle)
                imaginary[bin] += value * sin(angle)
            }
        }
        return (real, imaginary)
    }

    @Test(arguments: [(1, 8), (5, 8), (8, 8), (9, 8), (300, 64), (1_000, 64), (1_000, 256), (2_001, 512)])
    func theSpectraEqualTheTransformOfEachPartition(count: Int, partition: Int) {
        let taps = noiseTaps(count)
        let rig = partitioned(taps, partition: partition)
        #expect(!rig.isNull)
        let partitions = (count + partition - 1) / partition
        var worst = 0.0
        for index in 0 ..< partitions {
            let held = spectrum(rig, index, partition: partition)
            #expect(held.count == partitions, "as many spectra as the taps fill partitions")
            let expected = transform(taps, partition: partition, index: index)
            // Tolerances on spectra are relative to the largest bin of the frame (§6.1); the Float32
            // transform has a floor of about 1e-7 there (E-30).
            let largest = zip(expected.real, expected.imaginary).map { ($0 * $0 + $1 * $1).squareRoot() }.max()!
            for (name, actual, reference) in [("real", held.real, expected.real), ("imaginary", held.imaginary, expected.imaginary)] {
                let error = zip(actual, reference).map { abs(Double($0) - $1) }.max()! / largest
                #expect(error <= 1e-6, "\(name) part of partition \(index): \(error) of the largest bin")
                worst = max(worst, error)
            }
            #expect(held.imaginary[0] == 0 && held.imaginary[partition] == 0, "the first and the last bin of a real signal are real")
        }
        note("WP-214 \(count) taps in partitions of \(partition): largest spectrum error relative to the largest bin", worst)
    }

    /// The stress test of the stability note. Taps taken from the signals of WP-016 put a
    /// spectrum's energy where a transform's conventions are easiest to get wrong: a constant in
    /// bin 0, the alternating signal in the last bin (the two real bins that share one index in
    /// vDSP's packed layout), an impulse evenly in all of them. There the kernel's spectra are
    /// not merely close: the values are small integers, and exact.
    @Test func theSpectraOfTheStressSignalsAreExactWhereTheirEnergyIs() throws {
        let partition = 32
        let signals = StressFixture.signals(count: 2 * partition)
        func spectra(_ name: String) throws -> [(real: [Float], imaginary: [Float])] {
            let taps = try #require(signals.first { $0.name == name }).samples
            let rig = partitioned(taps, partition: partition)
            return (0 ..< 2).map { index in
                let held = spectrum(rig, index, partition: partition)
                return (held.real, held.imaginary)
            }
        }
        // A constant: 32 in bin 0, nothing in the last bin, in both partitions.
        for held in try spectra("dc") {
            #expect(held.real[0] == 32 && held.real[partition] == 0 && held.imaginary[0] == 0 && held.imaginary[partition] == 0)
        }
        // +1, −1, …: nothing in bin 0, 32 in the last bin.
        for held in try spectra("nyquist") {
            #expect(held.real[0] == 0 && held.real[partition] == 32 && held.imaginary[0] == 0 && held.imaginary[partition] == 0)
        }
        // An impulse: 1 in every bin of the first partition, and the second partition is empty.
        let impulse = try spectra("impulse")
        #expect(impulse[0].real.allSatisfy { $0 == 1 } && impulse[0].imaginary.allSatisfy { $0 == 0 })
        #expect(impulse[1].real.allSatisfy { $0 == 0 } && impulse[1].imaginary.allSatisfy { $0 == 0 })
        // Noise: the definition, to the transform's floor.
        let noise = try #require(signals.first { $0.name == "white-noise" }).samples
        let rig = partitioned(noise, partition: partition)
        for index in 0 ..< 2 {
            let held = spectrum(rig, index, partition: partition), expected = transform(noise, partition: partition, index: index)
            let largest = zip(expected.real, expected.imaginary).map { ($0 * $0 + $1 * $1).squareRoot() }.max()!
            #expect(zip(held.real, expected.real).allSatisfy { abs(Double($0) - $1) <= 1e-6 * largest })
            #expect(zip(held.imaginary, expected.imaginary).allSatisfy { abs(Double($0) - $1) <= 1e-6 * largest })
        }
    }

    @Test func theAccessorAnswersOnlyForWhatExists() {
        let taps = noiseTaps(100)
        let rig = partitioned(taps, partition: 32)
        var real = [Float](repeating: 7, count: 33), imaginary = [Float](repeating: 7, count: 33)
        let past = rig.withKernel { ztd_partitioned_spectrum($0, 4, &real, &imaginary) }
        #expect(past == 4, "four partitions, numbered 0 to 3")
        #expect(real.allSatisfy { $0 == 7 } && imaginary.allSatisfy { $0 == 7 }, "an index past the last copies nothing")
        let counted = rig.withKernel { ztd_partitioned_spectrum($0, 0, nil, nil) }
        #expect(counted == 4, "without buffers it still says how many there are")
        let missing = ztd_partitioned_spectrum(nil, 0, &real, &imaginary)
        #expect(missing == 0)
        // Any other kernel has no such spectra.
        let other = direct(taps).withKernel { ztd_partitioned_spectrum($0, 0, &real, &imaginary) }
        var identity = ztd_kernel_identity()
        let plain = ztd_partitioned_spectrum(&identity, 0, &real, &imaginary)
        var failed = ztd_partitioned_create(1, taps, 100, 33, 0)
        let never = ztd_partitioned_spectrum(&failed, 0, &real, &imaginary)
        #expect(other == 0 && plain == 0 && never == 0)
        #expect(real.allSatisfy { $0 == 7 })
    }

    @Test func thePartitionMustBeAPowerOfTwoFromEightUp() {
        let taps = noiseTaps(100)
        for partition in [8, 16, 64, 1_024] { #expect(!partitioned(taps, partition: partition).isNull, "\(partition)") }
        // 2 · partition is the transform length; only documented lengths are admitted (E-09).
        for partition in [0, 1, 2, 4, 7, 9, 12, 24, 100, 1_000, 3 << 20, 1 << 21] { #expect(partitioned(taps, partition: partition).isNull, "\(partition)") }
        #expect(KernelRig(ztd_partitioned_create(0, taps, 100, 64, 0), channels: 0).isNull, "no channels")
        #expect(KernelRig(ztd_partitioned_create(1, taps, 0, 64, 0), channels: 1).isNull, "no taps")
        #expect(KernelRig(ztd_partitioned_create(1, nil, 100, 64, 0), channels: 1).isNull, "no tap array")
        #expect(KernelRig(ztd_partitioned_create(1, [1, .nan], 2, 64, 0), channels: 1).isNull, "a tap that is not a number")
    }
}

@Suite("Partitioned convolution: processing (WP-215)")
struct PartitionedKernelTests {
    /// Blocks that are whole partitions take the frequency-domain path; everything else also
    /// takes the direct head with the tail from the delay line.
    private func cuts(_ partition: Int) -> [(String, Blocks)] {
        [("whole partitions", .fixed(partition)), ("several partitions", .fixed(3 * partition)), ("half partitions", .fixed(partition / 2)),
         ("a partition and a frame", .fixed(partition + 1)), ("frame by frame", .fixed(1)), ("7", .fixed(7)),
         ("irregular up to 100", .irregular(seed: 51, upTo: 100)), ("irregular up to 3 partitions", .irregular(seed: 52, upTo: 3 * partition)),
         ("everything at once", .whole)]
    }

    @Test(arguments: [(2_001, 512), (2_001, 64), (1_000, 256), (300, 8), (100, 128), (64, 64), (65, 64), (1, 16)])
    func theOutputIsWithinMinus100dBOfTheDirectKernel(count: Int, partition: Int) {
        let taps = count == 2_001 ? windowedSinc(count: 2_001, cutoff: 0.05) : noiseTaps(count)
        let input = [TestSignal.whiteNoise(count: 7_000, seed: 215), TestSignal.whiteNoise(count: 7_000, seed: 2_150)]
        let reference = direct(taps, channels: 2).run(input, .fixed(512))
        var worst = -Double.infinity
        for (name, blocks) in cuts(partition) {
            let output = partitioned(taps, partition: partition, channels: 2).run(input, blocks)
            for channel in 0 ..< 2 {
                expectClose(output[channel], reference[channel], .deviationBelow(decibels: -100), "\(count) taps, partitions of \(partition), \(name), channel \(channel)")
                worst = max(worst, Reference.deviation(output[channel], reference[channel]))
            }
        }
        note("WP-215 \(count) taps in partitions of \(partition): largest deviation from the direct kernel over all block sizes", worst, "dB")
    }

    @Test func noLatencyIsAddedWhateverTheBlockSize() {
        // A linear-phase filter: the impulse comes out centred on the frame the caller states, the
        // same frame as from the direct kernel, for blocks that are whole partitions and for
        // blocks that are not.
        let taps = windowedSinc(count: 2_001, cutoff: 0.05)
        let impulse = TestSignal.impulse(count: 5_000, at: 333, amplitude: 1)
        let expected = TestSignal.silence(count: 333) + taps + TestSignal.silence(count: 5_000 - 333 - 2_001)
        for (name, blocks) in cuts(256) {
            let rig = partitioned(taps, partition: 256, latency: 1_000)
            #expect(rig.latency == 1_000 && rig.settling == 2_000 && !rig.hasCommand)
            let response = rig.run(impulse, blocks)
            let peak = response.indices.max { abs(response[$0]) < abs(response[$1]) }!
            #expect(peak == 333 + 1_000, "\(name): the peak is where the stated latency puts it")
            expectClose(response, expected, .deviationBelow(decibels: -100), "\(name)")
        }
    }

    /// The stress signals of WP-016, against the direct kernel: the transform floor does not
    /// accumulate (each partition is recomputed from the input history), full scale included.
    @Test func theStressSignalsStayWithinMinus100dBAndSilenceStaysSilent() {
        let taps = windowedSinc(count: 1_001, cutoff: 0.1)
        for signal in StressFixture.signals(count: 8_192) {
            let reference = direct(taps).run(signal.samples, .fixed(512))
            for blocks in [Blocks.fixed(256), .irregular(seed: 53, upTo: 400)] {
                let output = partitioned(taps, partition: 256).run(signal.samples, blocks)
                #expect(!output.contains { $0.isSubnormal }, "\(signal.name): a subnormal value came out")
                if signal.name == "silence" || signal.name == "denormal" {
                    #expect(output.allSatisfy { $0 == 0 }, "\(signal.name): nothing in, exactly nothing out")
                } else {
                    // −100 dB of the larger of the two peaks: where the filter removes the signal
                    // (the tone at Nyquist) the transform's floor is that of the input.
                    let scale = max(reference.map { abs(Double($0)) }.max()!, signal.samples.map { abs(Double($0)) }.max()!)
                    expectClose(output, reference, .absolute(scale * 1e-5), "\(signal.name)")
                }
            }
        }
        // After a long full-scale passage the error is what it was at the start.
        let long = (0 ..< 120_000).map { Float(($0 / 24) % 2 == 0 ? 1 : -1) }
        let output = partitioned(taps, partition: 256).run(long, .fixed(256)), reference = direct(taps).run(long, .fixed(512))
        expectClose(Array(output[110_000...]), Array(reference[110_000...]), .deviationBelow(decibels: -100))
        // And once the input has ended, the output is exactly zero as soon as the filter has run out.
        let burst = TestSignal.whiteNoise(count: 2_000, seed: 2_151) + TestSignal.silence(count: 4_000)
        let tail = partitioned(taps, partition: 256).run(burst, .irregular(seed: 54, upTo: 300))
        #expect(tail[(2_000 + 1_001 + 512)...].allSatisfy { $0 == 0 }, "no round-off lingers in the delay line")
    }

    /// RT-6 on both paths (register audit, WP-905b). Above, the head of the filter holds its
    /// smallest taps, and a product of them with the `denormal` signal is already zero. Here the
    /// filter's largest taps are in its head, so a block that is not whole partitions convolves
    /// what came in with taps that keep a subnormal value subnormal. The input is cleaned as it
    /// enters: with the `denormal` and `decaying-tail` signals of WP-016, nothing subnormal
    /// comes out, and subnormal input gives exact zeros, on either path.
    @Test func subnormalInputGivesExactZerosOnBothPaths() throws {
        let taps = windowedSinc(count: 255, cutoff: 0.1)
        #expect(taps[..<128].contains { $0 > 0.1 }, "the largest taps are in the head of 128")
        for name in ["denormal", "decaying-tail"] {
            let signal = try #require(StressFixture.signals(count: 4_096).first { $0.name == name })
            for (cut, blocks) in [("whole partitions", Blocks.fixed(128)), ("frame by frame", .fixed(1)), ("7", .fixed(7)), ("irregular up to 300", .irregular(seed: 56, upTo: 300))] {
                let output = partitioned(taps, partition: 128).run(signal.samples, blocks)
                #expect(!output.contains { $0.isSubnormal }, "\(name), \(cut): a subnormal value came out")
                if name == "denormal" { #expect(output.allSatisfy { $0 == 0 }, "\(name), \(cut): nothing in, exactly nothing out") }
            }
        }
    }

    @Test func aResetIsAColdStart() {
        let taps = noiseTaps(700)
        let input = TestSignal.whiteNoise(count: 3_000, seed: 2_152)
        let rig = partitioned(taps, partition: 128)
        let first = rig.run(input, .irregular(seed: 55, upTo: 200))
        rig.reset()
        // The same blocks again: the same floats. (Other blocks give the same signal within the
        // kernel's tolerance, not the same floats: whole partitions and parts take two paths.)
        #expect(bits(rig.run(input, .irregular(seed: 55, upTo: 200))) == bits(first))
        rig.reset()
        expectClose(rig.run(input, .fixed(128)), first, .deviationBelow(decibels: -100))
    }

    @Test func processingIsAllocationFree() {
        let rig = partitioned(windowedSinc(count: 2_001, cutoff: 0.05), partition: 256, channels: 2)
        let call = rig.arena(frames: 512)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                // Whole partitions, parts of one, and the frames that complete one.
                call.run(round % 4 == 0 ? 512 : (round % 4 == 1 ? 37 : (round % 4 == 2 ? 219 : 256)))
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        let taps = windowedSinc(count: 2_001, cutoff: 0.05)
        var results: [BenchmarkResult] = []
        let whole = partitioned(taps, partition: 512), wholeCall = whole.arena(frames: 512)
        results.append(Benchmark.measure("kernel.partitioned.2001-taps.partition-512.512", iterations: 50) { wholeCall.run(512) })
        let parts = partitioned(taps, partition: 512), partsCall = parts.arena(frames: 480)
        results.append(Benchmark.measure("kernel.partitioned.2001-taps.partition-512.480", iterations: 50) { partsCall.run(480) })
        let plain = direct(taps), plainCall = plain.arena(frames: 512)
        results.append(Benchmark.measure("kernel.fir.2001-taps.512", iterations: 50) { plainCall.run(512) })
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 3 && results.allSatisfy { $0.minimum > 0 })
    }
}
