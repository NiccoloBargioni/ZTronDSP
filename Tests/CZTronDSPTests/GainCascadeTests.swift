import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The gain cascade of the engine (`ztd_gain_cascade_create`, F1): what one gain stage lowers
/// to and what adjacent gain stages fuse into. Its factors are applied one after another, a
/// changed factor ramps, and a factor that rests at 1 is not applied at all (F4).
@Suite("Gain cascade (F1, F4)")
struct GainCascadeTests {
    private func plan(_ factors: [Float], ramp: UInt32 = 0, _ implementation: ztd_implementation_t = ZTD_IMPLEMENTATION_NATIVE) throws -> OpaquePointer {
        let plan = try #require(ztd_plan_create(1, 1, 64))
        #expect(ztd_plan_append(plan, ztd_gain_cascade_create(1, factors, UInt32(factors.count), ramp, implementation), true) == 0)
        return plan
    }

    private func send(_ factors: [Float], to plan: OpaquePointer) {
        factors.withUnsafeBufferPointer { values in
            var command = ztd_command_t()
            command.target = 0
            command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
            command.count = UInt32(values.count)
            command.values = UnsafeRawPointer(values.baseAddress)
            ztd_plan_command(plan, &command)
        }
    }

    /// F1: the factors are applied in sequence, not multiplied into one, in both
    /// implementations. F4: a factor of 1 among them changes no sample, wherever it stands, so
    /// a cascade that holds one gives, bit for bit, what the cascade without it gives; and a
    /// cascade of nothing but ones, or of no factor at all, hands its input on.
    @Test func factorsAreAppliedInSequenceAndAFactorOfOneIsNotApplied() throws {
        let signal = TestSignal.whiteNoise(count: 64 * 6 + 7, seed: 9_001)
        let buffers = MonoBuffers(capacity: 64)
        for implementation in [ZTD_IMPLEMENTATION_NATIVE, ZTD_IMPLEMENTATION_ACCELERATE] {
            let reference = signal.map { (sample: Float) -> Float in ((sample * 0.37) * 2.9) * 0.11 }
            let plain = try plan([0.37, 2.9, 0.11], implementation)
            defer { ztd_plan_destroy(plain) }
            #expect(buffers.run(plain, signal, blocks: [64, 7, 33]) == reference)
            for unity in [[1, 0.37, 2.9, 0.11], [0.37, 1, 2.9, 0.11], [0.37, 2.9, 0.11, 1], [1, 0.37, 1, 2.9, 1, 0.11, 1]] as [[Float]] {
                let cascade = try plan(unity, implementation)
                defer { ztd_plan_destroy(cascade) }
                #expect(buffers.run(cascade, signal, blocks: [64, 7, 33]) == reference, "\(unity)")
            }
            for identity in [[1], [1, 1, 1], []] as [[Float]] {
                let cascade = try plan(identity, implementation)
                defer { ztd_plan_destroy(cascade) }
                #expect(buffers.run(cascade, signal, blocks: [64, 7, 33]) == signal, "\(identity): the input, untouched")
            }
        }
    }

    /// §5.5.4: "A gain ramps over 10 ms." A factor that is sent 1 ramps to it and lands on it
    /// exactly, and from there the cascade hands its input on; sent another value, it ramps
    /// away from 1 again. A ramp passes through 1 like through any value.
    @Test func aFactorRampsToOneRestsThereAndRampsAwayAgain() throws {
        let ones = [Float](repeating: 1, count: 64 * 12)
        let buffers = MonoBuffers(capacity: 64)
        let cascade = try plan([2], ramp: 96)
        defer { ztd_plan_destroy(cascade) }
        #expect(buffers.run(cascade, Array(ones[..<64]), blocks: [64]) == [Float](repeating: 2, count: 64))

        send([1], to: cascade)
        let down = buffers.run(cascade, Array(ones[..<192]), blocks: [64])
        let falling = (0 ..< 96).map { (frame: Int) -> Float in frame == 95 ? 1 : 1 - (-1.0 / 96) * Float(95 - frame) }
        expectClose(Array(down[..<96]), falling, .absolute(1e-6), "96 frames from 2 to 1")
        #expect(down[95] == 1 && down[96...].allSatisfy { $0 == 1 }, "and then 1 exactly")

        // At rest on 1 the signal passes untouched, sample for sample.
        let signal = TestSignal.whiteNoise(count: 128, seed: 9_002)
        #expect(buffers.run(cascade, signal, blocks: [64]) == signal)

        // Through 1, from 0.5 to 1.5: no frame of the ramp is skipped for standing near 1.
        send([0.5], to: cascade)
        _ = buffers.run(cascade, Array(ones[..<128]), blocks: [64])
        send([1.5], to: cascade)
        let through = buffers.run(cascade, Array(ones[..<128]), blocks: [64])
        let rising = (0 ..< 96).map { (frame: Int) -> Float in frame == 95 ? 1.5 : 1.5 - (1.0 / 96) * Float(95 - frame) }
        expectClose(Array(through[..<96]), rising, .absolute(1e-6), "96 frames from 0.5 to 1.5")
        #expect(abs(through[47] - 1) < 1e-6 && through[95] == 1.5 && through[96...].allSatisfy { $0 == 1.5 }, "through 1 in mid-ramp, and on to 1.5 exactly")

        // A reset lets a ramp in flight land: a cold start keeps the value last asked for.
        send([1], to: cascade)
        _ = buffers.run(cascade, Array(ones[..<32]), blocks: [32])
        ztd_plan_reset(cascade)
        #expect(buffers.run(cascade, signal, blocks: [64]) == signal, "landed on 1: the input, untouched")
    }

    /// ztd_engine.h: the ramp is the closed form of the gain kernel (ztd_kernels.h), rounded as
    /// it is written, one operation at a time: with `left` frames of the move still to come after
    /// a frame, its factor is target − increment·left, the product rounded and then the
    /// difference. A product and a difference fused into one rounding would give other floats on
    /// part of the ramp (measured: 72 frames of a 10 ms ramp from −6 dB to −12 dB). So one gain
    /// stage (this cascade) and a gain per channel (the gain kernel) ramp to the same floats,
    /// whatever the blocks, in both implementations.
    @Test func theRampIsTheGainKernelsRampRoundedStepByStep() throws {
        let start = Float(0.501_187_2), goal = Float(0.251_188_64)     // −6 dB and −12 dB
        let signal = TestSignal.whiteNoise(count: 64 * 12, seed: 9_004, amplitude: 0.9)
        let increment = (goal - start) / 480
        let ramp = (0 ..< 480).map { (frame: Int) -> Float in
            let left = 479 - frame
            let product = increment * Float(left)
            return signal[frame] * (left == 0 ? goal : goal - product)
        }
        for implementation in [ZTD_IMPLEMENTATION_NATIVE, ZTD_IMPLEMENTATION_ACCELERATE] {
            for blocks in [[64], [7, 33, 64], [1]] {
                let buffers = MonoBuffers(capacity: 64)
                let cascade = try plan([start], ramp: 480, implementation)
                defer { ztd_plan_destroy(cascade) }
                let gain = try #require(ztd_plan_create(1, 1, 64))
                defer { ztd_plan_destroy(gain) }
                #expect(ztd_plan_append(gain, [start].withUnsafeBufferPointer { ztd_gain_create(1, $0.baseAddress, 480, implementation) }, true) == 0)
                send([goal], to: cascade)
                send([goal], to: gain)
                let fromTheCascade = buffers.run(cascade, signal, blocks: blocks)
                let fromTheKernel = buffers.run(gain, signal, blocks: blocks)
                let differing = zip(fromTheCascade, ramp).filter { $0 != $1 }.count
                #expect(Array(fromTheCascade[..<480]) == ramp, "\(implementation), blocks of \(blocks): \(differing) frames of the ramp differ from the closed form")
                #expect(fromTheCascade == fromTheKernel, "\(implementation), blocks of \(blocks): the cascade and the gain kernel")
                #expect(Array(fromTheCascade[480...]) == signal[480...].map { $0 * goal }, "and then the goal, exactly")
            }
        }
    }

    /// ztd_engine.h: a cascade needs channels, and factors for the count it names. A command
    /// that is not a change of values, or that carries none, changes nothing; one that carries
    /// fewer values than the cascade has factors sets the first of them.
    @Test func creationAndCommandsThatMakeNoSense() throws {
        var none = ztd_gain_cascade_create(0, [1], 1, 0, ZTD_IMPLEMENTATION_NATIVE)
        #expect(ztd_kernel_is_null(&none), "no channels: no kernel")
        var missing = ztd_gain_cascade_create(1, nil, 2, 0, ZTD_IMPLEMENTATION_NATIVE)
        #expect(ztd_kernel_is_null(&missing), "two factors and none given: no kernel")
        var absurd = ztd_gain_cascade_create(1, [1], UInt32.max, 0, ZTD_IMPLEMENTATION_NATIVE)
        #expect(ztd_kernel_is_null(&absurd), "more factors than any cascade has: no kernel")

        let ones = [Float](repeating: 1, count: 64)
        let buffers = MonoBuffers(capacity: 64)
        let cascade = try plan([2, 3])
        defer { ztd_plan_destroy(cascade) }
        var command = ztd_command_t()
        command.target = 0
        command.kind = UInt32(ZTD_COMMAND_CUSTOM)
        ztd_plan_command(cascade, &command)
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        ztd_plan_command(cascade, &command)             // no payload
        #expect(buffers.run(cascade, ones, blocks: [64]).allSatisfy { $0 == 6 }, "neither changed a factor")
        send([5], to: cascade)
        #expect(buffers.run(cascade, ones, blocks: [64]).allSatisfy { $0 == 15 }, "one value: the first factor")
        send([1, 1, 9], to: cascade)
        #expect(buffers.run(cascade, ones, blocks: [64]) == ones, "more values than factors: the cascade's own count is taken")
    }
}
