import CZTronDSP
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

/// The two implementations a kernel can be bound to when it is created (SEL-3).
enum Bound: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case native, accelerate

    var implementation: ztd_implementation_t {
        self == .native ? ZTD_IMPLEMENTATION_NATIVE : ZTD_IMPLEMENTATION_ACCELERATE
    }

    var testDescription: String { rawValue }
}

/// The gain kernel's definition, one frame at a time: the scalar loop both implementations are
/// held to, bit for bit. With `left` frames of a move still to come after a frame, its gain is
/// `target − increment · left`, and exactly `target` when `left` is 0.
private struct ScalarGain {
    var current: Float
    var target: Float
    var increment: Float = 0
    var remaining = 0
    let ramp: Int

    init(_ value: Float, ramp: Int) {
        current = value
        target = value
        self.ramp = ramp
    }

    mutating func move(to newTarget: Float) {
        target = newTarget
        if ramp == 0 || newTarget == current {
            current = newTarget
            increment = 0
            remaining = 0
        } else {
            increment = (newTarget - current) / Float(ramp)
            remaining = ramp
        }
    }

    mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            current = remaining == 0 ? target : target - increment * Float(remaining)
        }
        return current
    }
}

@Suite("Gain kernel (WP-207)")
struct GainKernelTests {
    private func noise(_ channels: Int, _ frames: Int, seed: UInt64) -> [[Float]] {
        (0 ..< channels).map { TestSignal.whiteNoise(count: frames, seed: seed &+ UInt64($0)) }
    }

    /// A script of moves: the gains to ask for, then how many frames to run, cut how.
    private struct Step {
        let gains: [Float]?      // per channel
        let scalar: Double?      // or one for every channel
        let frames: Int
        let blocks: Blocks
    }

    @Test(arguments: Bound.allCases, [0, 1, 7, 480, 3_000])
    func bothImplementationsAreBitExactWithAScalarLoop(bound: Bound, ramp: Int) {
        let initial: [Float] = [0.5, -1.25, 2]
        let rig = KernelRig(ztd_gain_create(3, initial, UInt32(ramp), bound.implementation), channels: 3)
        #expect(!rig.isNull && rig.latency == 0 && rig.settling == 0 && rig.hasCommand)
        var reference = initial.map { ScalarGain($0, ramp: ramp) }

        let script = [
            Step(gains: nil, scalar: nil, frames: 700, blocks: .irregular(seed: 1, upTo: 90)),           // constant
            Step(gains: [1, 0.25, -0.5], scalar: nil, frames: 1_300, blocks: .irregular(seed: 2, upTo: 700)), // a move, finished
            Step(gains: nil, scalar: 0.125, frames: 200, blocks: .fixed(64)),                             // one gain for all…
            Step(gains: [3, 3, -3], scalar: nil, frames: 900, blocks: .cycle([1, 7, 513])),               // …cut short by another
            Step(gains: [3, 3, -3], scalar: nil, frames: 300, blocks: .whole),                            // the same target again
        ]
        var seed: UInt64 = 207
        for (index, step) in script.enumerated() {
            if let gains = step.gains {
                rig.setValues(gains)
                for channel in 0 ..< 3 { reference[channel].move(to: gains[channel]) }
            } else if let scalar = step.scalar {
                rig.setScalar(scalar)
                for channel in 0 ..< 3 { reference[channel].move(to: Float(scalar)) }
            }
            let input = noise(3, step.frames, seed: seed)
            seed &+= 10
            let output = rig.run(input, step.blocks)
            for channel in 0 ..< 3 {
                let expected = input[channel].map { $0 * reference[channel].next() }
                #expect(bits(output[channel]) == bits(expected), "step \(index), channel \(channel), \(bound), ramp \(ramp)")
            }
        }
    }

    @Test(arguments: Bound.allCases)
    func theRampIsContinuousAcrossBlocksAndLandsOnItsTargetExactly(bound: Bound) {
        // An input of ones: the output is the gain curve itself.
        let ramp = 480, frames = 1_200
        let ones = TestSignal.constant(1, count: frames)
        func curve(_ blocks: Blocks, from start: Float, to target: Float) -> [Float] {
            let rig = KernelRig(ztd_gain_create(1, [start], UInt32(ramp), bound.implementation), channels: 1)
            rig.setScalar(Double(target))
            return rig.run(ones, blocks)
        }
        for (start, target) in [(Float(0.25), Float(1)), (1, 0.1), (-0.3, 0.7), (0, 1e-7)] {
            let whole = curve(.whole, from: start, to: target)
            // Any cut of the same frames gives the same floats: the ramp does not know where blocks end.
            for blocks in [Blocks.fixed(1), .fixed(7), .fixed(64), .fixed(479), .fixed(480), .fixed(512), .irregular(seed: 3, upTo: 200)] {
                #expect(bits(curve(blocks, from: start, to: target)) == bits(whole), "\(bound), \(start) → \(target)")
            }
            // It lands on the target at its last frame and stays there.
            #expect(whole[ramp - 1] == target, "the last frame of the move is the target itself")
            #expect(whole[ramp - 2] != target)
            #expect(whole[ramp...].allSatisfy { $0 == target })
            // It is one straight line: every step is the increment, within the rounding of a Float.
            let increment = (Double(target) - Double(start)) / Double(ramp)
            let slack = 4 * Double(Float.ulpOfOne) * max(abs(Double(start)), abs(Double(target)), 1e-30)
            for frame in 0 ..< ramp {
                let previous = frame == 0 ? Double(start) : Double(whole[frame - 1])
                #expect(abs((Double(whole[frame]) - previous) - increment) <= slack, "frame \(frame): no step out of line, \(start) → \(target)")
            }
        }
    }

    @Test(arguments: Bound.allCases)
    func theKernelMatchesTheToolkitsRamp(bound: Bound) {
        // The toolkit's `Ramp` (WP-119) is the same definition; the kernel and it agree bit for bit.
        let rig = KernelRig(ztd_gain_create(1, [0.2], 441, bound.implementation), channels: 1)
        var ramp = Ramp(value: 0.2, duration: 441)
        var seed: UInt64 = 2_070
        for target in [Float(0.9), 0.1, 0.1, 1.5] {
            rig.setScalar(Double(target))
            ramp.setTarget(target)
            let input = TestSignal.whiteNoise(count: 300, seed: seed)
            seed += 1
            let output = rig.run(input, .irregular(seed: seed, upTo: 50))
            #expect(bits(output) == bits(input.map { $0 * ramp.next() }), "towards \(target)")
        }
    }

    @Test(arguments: Bound.allCases)
    func withoutGainsTheKernelIsUnity(bound: Bound) {
        let rig = KernelRig(ztd_gain_create(2, nil, 64, bound.implementation), channels: 2)
        let input = noise(2, 777, seed: 5)
        #expect(rig.run(input, .fixed(100)).map(bits) == input.map(bits))
    }

    @Test(arguments: Bound.allCases)
    func commandsThatAreNotForItChangeNothing(bound: Bound) {
        let rig = KernelRig(ztd_gain_create(2, [0.5, 0.25], 0, bound.implementation), channels: 2)
        let input = noise(2, 64, seed: 6)
        let expected = [input[0].map { $0 * 0.5 }, input[1].map { $0 * 0.25 }]
        let three: [Float] = [9, 9, 9]
        three.withUnsafeBufferPointer { rig.send(count: 3, values: UnsafeRawPointer($0.baseAddress)) }   // neither 1 nor the channel count
        rig.send(count: 2, values: nil)                                                                 // per-channel gains without a payload
        rig.send(kind: UInt32(ZTD_COMMAND_SET_ACTIVE), count: 1, values: nil, scalar: 9)                  // the plan's, not the kernel's
        rig.send(kind: UInt32(ZTD_COMMAND_CUSTOM), count: 1, values: nil, scalar: 9)
        rig.send(count: 0, values: nil)
        rig.sendNothing()
        #expect(rig.run(input).map(bits) == expected.map(bits))
        // And the forms that are for it do: one value for every channel, or one per channel.
        rig.setScalar(2)
        #expect(rig.run(input).map(bits) == input.map { bits($0.map { $0 * 2 }) })
        rig.setValues([Float(3), -1])
        #expect(rig.run(input).map(bits) == [bits(input[0].map { $0 * 3 }), bits(input[1].map { $0 * -1 })])
    }

    @Test(arguments: Bound.allCases)
    func aResetKeepsTheGainAskedForAndDropsTheMove(bound: Bound) {
        let rig = KernelRig(ztd_gain_create(1, [1], 1_000, bound.implementation), channels: 1)
        rig.setScalar(0.5)
        let ones = TestSignal.constant(1, count: 100)
        let moving = rig.run(ones)
        #expect(moving[99] < 1 && moving[99] > 0.5, "on its way")
        rig.reset()
        #expect(rig.run(ones).allSatisfy { $0 == 0.5 }, "a cold start is at the gain last asked for")
    }

    @Test func creationFailsWithoutChannelsOrWithAnUnknownImplementation() {
        #expect(KernelRig(ztd_gain_create(0, nil, 0, ZTD_IMPLEMENTATION_NATIVE), channels: 0).isNull)
        #expect(KernelRig(ztd_gain_create(0, [1], 0, ZTD_IMPLEMENTATION_ACCELERATE), channels: 0).isNull)
        #expect(KernelRig(ztd_gain_create(1, [1], 0, ztd_implementation_t(rawValue: 7)), channels: 1).isNull)
        #expect(KernelRig(ztd_gain_create(1 << 30, nil, 0, ZTD_IMPLEMENTATION_NATIVE), channels: 0).isNull, "an absurd channel count is refused, not attempted")
        // A gain that is not a number makes no kernel, in any channel and with either implementation.
        for bad in [Float.nan, .infinity, -.infinity] {
            #expect(KernelRig(ztd_gain_create(1, [bad], 0, ZTD_IMPLEMENTATION_NATIVE), channels: 1).isNull)
            #expect(KernelRig(ztd_gain_create(3, [1, 0.5, bad], 0, ZTD_IMPLEMENTATION_ACCELERATE), channels: 3).isNull)
        }
        var failed = ztd_gain_create(0, nil, 0, ZTD_IMPLEMENTATION_NATIVE)
        #expect(failed.state == nil && failed.destroy == nil)
        ztd_kernel_destroy(&failed)   // destroying a kernel that never was is harmless
        #expect(ztd_kernel_is_null(&failed))
    }

    @Test(arguments: Bound.allCases)
    func processingAndCommandsAreAllocationFree(bound: Bound) {
        let rig = KernelRig(ztd_gain_create(2, [0.5, 0.25], 480, bound.implementation), channels: 2)
        let call = rig.arena(frames: 512)
        let up = rig.preparedCommand(scalar: 1), down = rig.preparedCommand(floats: [0.1, 0.2])
        let command = call.command!
        expectNoAllocations("\(bound)") {
            var round = 0
            while round < 1_000 {
                // A move every 40 blocks, so both the ramped and the constant path are audited.
                if round % 80 == 0 { command(call.state, up) }
                if round % 80 == 40 { command(call.state, down) }
                call.run(round % 3 == 0 ? 37 : 512)
                round += 1
            }
            call.reset(call.state)
        }
    }

    @Test func aBenchmarkIsRecordedForEachImplementation() {
        var results: [BenchmarkResult] = []
        for bound in Bound.allCases {
            for frames in [64, 512] {
                let rig = KernelRig(ztd_gain_create(1, [0.5], 480, bound.implementation), channels: 1)
                let call = rig.arena(frames: frames)
                results.append(Benchmark.measure("kernel.gain.\(bound.rawValue).\(frames)", iterations: 2_000) { call.run(UInt32(frames)) })
            }
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 4 && results.allSatisfy { $0.minimum > 0 })
    }
}
