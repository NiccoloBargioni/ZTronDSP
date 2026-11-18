import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

private struct Tracker: Sendable, CustomTestStringConvertible {
    var alpha: Float = 0.85
    var beta: Float = 0.005
    var step: Float = 1 / 48_000
    var position: Float = 0
    var velocity: Float = 0

    var testDescription: String { "alpha \(alpha), beta \(beta), step \(step), from \(position) at \(velocity)" }

    func kernel(channels: Int = 1, velocityOut: Bool = false) -> KernelRig {
        KernelRig(ztd_alpha_beta_create(UInt32(channels), alpha, beta, step, position, velocity, velocityOut), channels: channels)
    }

    /// The defining recurrence (§6.3.6, and the kernel header), in double precision:
    /// r = z − (x + dt·v);  x ← x + dt·v + alpha·r;  v ← v + (beta / dt)·r.
    func reference(_ input: [Float]) -> (position: [Double], velocity: [Double]) {
        let a = Double(alpha), dt = Double(step), gain = Double(beta) / Double(step)
        var x = Double(position), v = Double(velocity)
        var positions: [Double] = [], velocities: [Double] = []
        for sample in input {
            let predicted = x + dt * v
            let residual = Double(sample) - predicted
            x = predicted + a * residual
            v = v + gain * residual
            positions.append(x)
            velocities.append(v)
        }
        return (positions, velocities)
    }
}

@Suite("Alpha–beta kernel (WP-218)")
struct AlphaBetaKernelTests {
    private static let trackers = [
        Tracker(),
        Tracker(alpha: 0.5, beta: 0.1, step: 1 / 44_100, position: 0.25, velocity: -300),
        Tracker(alpha: 0.05, beta: 0.0005, step: 0.01, position: -1, velocity: 2),
        Tracker(alpha: 1, beta: 0, step: 1),            // follows the measurement exactly
        Tracker(alpha: 0, beta: 0, step: 1 / 48_000, position: 0.5, velocity: 480),   // ignores it: a straight line
    ]

    /// A measurement with a slope, a tone and some noise: something to track.
    private func measurement(_ count: Int, seed: UInt64) -> [Float] {
        let noise = TestSignal.whiteNoise(count: count, seed: seed, amplitude: 0.05)
        let tone = TestSignal.sine(frequency: 220, sampleRate: 48_000, count: count, amplitude: 0.3)
        return (0 ..< count).map { 0.4 * Float($0) / Float(count) + tone[$0] + noise[$0] }
    }

    @Test(arguments: trackers)
    fileprivate func theKernelMatchesTheDefiningRecurrenceWithinTenToTheMinusSix(tracker: Tracker) {
        let input = measurement(6_000, seed: 218)
        let expected = tracker.reference(input)
        let position = tracker.kernel().run(input, .irregular(seed: 61, upTo: 300))
        let velocity = tracker.kernel(velocityOut: true).run(input, .irregular(seed: 62, upTo: 300))
        expectClose(position, expected.position, .relativeToMaximum(1e-6), "position")
        expectClose(velocity, expected.velocity, .relativeToMaximum(1e-6), "velocity")
        // The states are double, as the recurrence is: what comes out is the reference rounded to Float32.
        #expect(bits(position) == bits(expected.position.map { Float($0) }) && bits(velocity) == bits(expected.velocity.map { Float($0) }))
    }

    @Test(arguments: trackers)
    fileprivate func theOutputIsTheSameForAnyBlockSizesAndEveryChannelIsItsOwn(tracker: Tracker) {
        let input = [measurement(3_000, seed: 2_180), measurement(3_000, seed: 2_181), measurement(3_000, seed: 2_182)]
        for velocityOut in [false, true] {
            let whole = tracker.kernel(channels: 3, velocityOut: velocityOut).run(input, .whole)
            for blocks in [Blocks.fixed(1), .fixed(7), .fixed(512), .irregular(seed: 63, upTo: 100), .cycle([0, 3, 1_000])] {
                #expect(tracker.kernel(channels: 3, velocityOut: velocityOut).run(input, blocks).map(bits) == whole.map(bits))
            }
            for channel in 0 ..< 3 {
                #expect(bits(whole[channel]) == bits(tracker.kernel(velocityOut: velocityOut).run(input[channel])), "channel \(channel)")
            }
        }
    }

    @Test func itTracksALevelAndASlope() {
        let tracker = Tracker(alpha: 0.2, beta: 0.02, step: 1 / 1_000)
        // A level: the position settles on it, the velocity on zero.
        let level = TestSignal.constant(0.6, count: 4_000)
        #expect(abs(tracker.kernel().run(level)[3_999] - 0.6) < 1e-6)
        #expect(abs(tracker.kernel(velocityOut: true).run(level)[3_999]) < 1e-3)
        // A slope of 2 units per second: no lag in the position once settled, and the velocity is the slope.
        let slope = (0 ..< 4_000).map { Float(2 * Double($0) / 1_000) }
        #expect(abs(tracker.kernel().run(slope)[3_999] - slope[3_999]) < 1e-5)
        #expect(abs(tracker.kernel(velocityOut: true).run(slope)[3_999] - 2) < 1e-3)
    }

    @Test func aResetReturnsToTheInitialState() {
        let tracker = Tracker(alpha: 0.3, beta: 0.01, step: 1 / 48_000, position: 0.7, velocity: -20)
        let input = measurement(1_000, seed: 2_183)
        let rig = tracker.kernel()
        #expect(!rig.isNull && rig.latency == 0 && rig.settling == 0 && !rig.hasCommand)
        let first = rig.run(input)
        #expect(first[0] != 0.7, "the first output is the state after the first measurement")
        rig.reset()
        #expect(bits(rig.run(input, .fixed(64))) == bits(first))
        rig.sendNothing()   // the kernel takes no commands; there is nothing to call
    }

    /// RT-6: fed silence, the tracker's states decay; once below 1e-20 they are cleared, and the
    /// output is exact zero without having passed through the subnormal range.
    @Test func aDecayingTrackReachesExactZeroAndLeavesNoSubnormalBehind() throws {
        let tracker = Tracker(alpha: 0.3, beta: 0.02, step: 1 / 48_000, position: 1, velocity: 0)
        for velocityOut in [false, true] {
            let output = tracker.kernel(velocityOut: velocityOut).run(TestSignal.silence(count: 16_384), .fixed(64))
            #expect(!output.contains { $0.isSubnormal })
            let firstZero = try #require(output.firstIndex { $0 == 0 }, "the track never reaches zero")
            #expect(output[firstZero...].allSatisfy { $0 == 0 })
            #expect(abs(output[0]) > 0.1 && firstZero > 64, "it did decay from somewhere")
        }
    }

    @Test func creationFailsForMissingOrMeaninglessArguments() {
        #expect(Tracker().kernel(channels: 0).isNull, "no channels")
        #expect(Tracker(step: 0).kernel().isNull, "no time step: beta / dt does not exist")
        #expect(Tracker(step: -0.001).kernel().isNull, "time does not run backwards")
        #expect(Tracker(step: .nan).kernel().isNull && Tracker(step: .infinity).kernel().isNull)
        #expect(Tracker(alpha: .nan).kernel().isNull && Tracker(beta: .infinity).kernel().isNull)
        #expect(Tracker(position: .nan).kernel().isNull && Tracker(velocity: -.infinity).kernel().isNull)
    }

    @Test func processingIsAllocationFree() {
        let position = Tracker().kernel(channels: 2), velocity = Tracker().kernel(channels: 2, velocityOut: true)
        let first = position.arena(frames: 512), second = velocity.arena(frames: 512)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                first.run(round % 2 == 0 ? 512 : 37)
                second.run(round % 2 == 0 ? 512 : 37)
                round += 1
            }
            first.reset(first.state)
        }
    }

    @Test func aBenchmarkIsRecorded() {
        let rig = Tracker().kernel()
        let call = rig.arena(frames: 512)
        let result = Benchmark.measure("kernel.alpha-beta.512", iterations: 500) { call.run(512) }
        Benchmark.record([result])
        note(result.name, result.minimum, "ns")
        #expect(result.minimum > 0)
    }
}
