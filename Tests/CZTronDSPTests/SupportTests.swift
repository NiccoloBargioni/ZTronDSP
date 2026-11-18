import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

@Suite("State hygiene (WP-216)")
struct StateHygieneTests {
    @Test func valuesBelowTheFloorBecomeZero() {
        var single: [Float] = [1, 1e-19, 9.9e-21, -9.9e-21, 1e-30, -1e-38, .leastNonzeroMagnitude, 0, -1e-19, -2]
        single.withUnsafeMutableBufferPointer { ztd_flush_state($0.baseAddress, UInt32($0.count)) }
        #expect(single == [1, 1e-19, 0, 0, 0, 0, 0, 0, -1e-19, -2])
        var double: [Double] = [1, 1e-19, 9.9e-21, -9.9e-21, 1e-300, .leastNonzeroMagnitude, -3]
        double.withUnsafeMutableBufferPointer { ztd_flush_state_double($0.baseAddress, UInt32($0.count)) }
        #expect(double == [1, 1e-19, 0, 0, 0, 0, -3])
        #expect(ZTD_STATE_FLOOR == 1e-20)
    }

    @Test func aDecayingTailReachesExactZeroWithinOneBlockOfFallingBelowTheFloor() {
        // A one-pole decay whose state is flushed at the end of each block, as a kernel does.
        for ratio in [Float(0.5), 0.9, 0.99] {
            var state: Float = 1
            var blocksBelow = 0
            var reachedZero = false
            for _ in 0 ..< 20_000 {
                for _ in 0 ..< 64 { state *= ratio }
                if state != 0 && abs(state) < 1e-20 { blocksBelow += 1 }
                withUnsafeMutablePointer(to: &state) { ztd_flush_state($0, 1) }
                #expect(!state.isSubnormal, "no denormal state is left behind")
                if state == 0 { reachedZero = true; break }
            }
            #expect(reachedZero, "ratio \(ratio)")
            #expect(blocksBelow <= 1, "ratio \(ratio): zero within one block of falling below the floor")
        }
    }

    @Test func theFloatingPointEnvironmentIsLeftAlone() {
        var state: [Float] = [1e-30, 1, .leastNonzeroMagnitude]
        var wide: [Double] = [1e-300, 1]
        let before = floatingPointEnvironmentDigest()
        state.withUnsafeMutableBufferPointer { ztd_flush_state($0.baseAddress, 3) }
        wide.withUnsafeMutableBufferPointer { ztd_flush_state_double($0.baseAddress, 2) }
        #expect(floatingPointEnvironmentDigest() == before, "neither the rounding mode, nor flush-to-zero, nor the exception flags changed")
    }

    @Test func flushingIsAllocationFree() {
        let state = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let wide = UnsafeMutablePointer<Double>.allocate(capacity: 256)
        defer { state.deallocate(); wide.deallocate() }
        state.initialize(repeating: 1e-30, count: 256)
        wide.initialize(repeating: 1e-30, count: 256)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                ztd_flush_state(state, 256)
                ztd_flush_state_double(wide, 256)
                ztd_flush_state(state, 0)
                round += 1
            }
        }
        #expect(state[255] == 0 && wide[255] == 0)
    }
}

@Suite("Cross-fade (WP-217)")
struct CrossfadeTests {
    /// Fades `from` into `to` in blocks of the given sizes and returns the result.
    private func fade(_ from: [Float], _ to: [Float], frames: Int, blocks: [Int]) -> [Float] {
        var fade = ztd_crossfade_t()
        ztd_crossfade_begin(&fade, UInt32(frames))
        var result = [Float](repeating: .nan, count: from.count)
        var position = 0, turn = 0
        while position < from.count {
            let count = min(blocks[turn % blocks.count], from.count - position)
            turn += 1
            from.withUnsafeBufferPointer { a in
                to.withUnsafeBufferPointer { b in
                    result.withUnsafeMutableBufferPointer { out in
                        ztd_crossfade_mix(&fade, a.baseAddress! + position, b.baseAddress! + position, out.baseAddress! + position, UInt32(count))
                    }
                }
            }
            position += count
        }
        #expect(ztd_crossfade_is_done(&fade) == (from.count >= frames))
        return result
    }

    @Test func theTwoFadesSumToOneAtEverySample() {
        // Fading 1 → 0 gives the weight of `from`; fading 0 → 1 gives the weight of `to`.
        let ones = [Float](repeating: 1, count: 600), zeros = [Float](repeating: 0, count: 600)
        let down = fade(ones, zeros, frames: 480, blocks: [64])
        let up = fade(zeros, ones, frames: 480, blocks: [64])
        for index in 0 ..< 600 {
            #expect(abs(down[index] + up[index] - 1) <= 1.2e-7, "sample \(index)")
        }
        // Fading a signal into itself changes nothing, at any weight.
        let signal = TestSignal.whiteNoise(count: 600, seed: 217)
        expectClose(fade(signal, signal, frames: 480, blocks: [37]), signal, .absolute(1e-7))
    }

    @Test func theFadeIsLinearAndEndsExactlyOnItsTarget() {
        let from = [Float](repeating: 2, count: 12), to = [Float](repeating: 6, count: 12)
        let result = fade(from, to, frames: 8, blocks: [12])
        #expect(result == [2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6, 6, 6, 6])
    }

    @Test(arguments: [[1], [7], [64], [480], [512], [1, 7, 300, 2, 480], [479, 1], [481]])
    func theDurationDoesNotDependOnTheBlockSize(blocks: [Int]) {
        let from = TestSignal.whiteNoise(count: 1_000, seed: 1), to = TestSignal.whiteNoise(count: 1_000, seed: 2)
        let reference = fade(from, to, frames: 480, blocks: [1_000])
        #expect(fade(from, to, frames: 480, blocks: blocks) == reference, "bit-identical for blocks of \(blocks)")
        #expect(Array(reference[479...]) == Array(to[479...]), "from the fade's last frame on, the output is the target")
        #expect(reference[478] != to[478])
    }

    @Test func theOutputMayBeEitherInput() {
        let from = TestSignal.whiteNoise(count: 200, seed: 3), to = TestSignal.whiteNoise(count: 200, seed: 4)
        let reference = fade(from, to, frames: 100, blocks: [200])
        var inFrom = from
        var first = ztd_crossfade_t()
        ztd_crossfade_begin(&first, 100)
        inFrom.withUnsafeMutableBufferPointer { out in to.withUnsafeBufferPointer { b in ztd_crossfade_mix(&first, out.baseAddress, b.baseAddress, out.baseAddress, 200) } }
        #expect(inFrom == reference)
        var inTo = to
        var second = ztd_crossfade_t()
        ztd_crossfade_begin(&second, 100)
        inTo.withUnsafeMutableBufferPointer { out in from.withUnsafeBufferPointer { a in ztd_crossfade_mix(&second, a.baseAddress, out.baseAddress, out.baseAddress, 200) } }
        #expect(inTo == reference)
    }

    @Test func aFadeOfZeroFramesIsOneFrameLong() {
        var fade = ztd_crossfade_t()
        ztd_crossfade_begin(&fade, 0)
        #expect(fade.total == 1 && !ztd_crossfade_is_done(&fade))
        var out: [Float] = [0, 0]
        ztd_crossfade_mix(&fade, [1, 1], [5, 5], &out, 2)
        #expect(out == [5, 5] && ztd_crossfade_is_done(&fade))
        ztd_crossfade_mix(&fade, [1, 1], [7, 7], &out, 2)
        #expect(out == [7, 7], "a finished fade passes its target")
        ztd_crossfade_mix(&fade, [1, 1], [9, 9], &out, 0)
        #expect(out == [7, 7])
    }

    @Test func mixingIsAllocationFree() {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: 512), b = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { a.deallocate(); b.deallocate(); out.deallocate() }
        a.initialize(repeating: 1, count: 512); b.initialize(repeating: 0, count: 512); out.initialize(repeating: 0, count: 512)
        expectNoAllocations {
            var fade = ztd_crossfade_t()
            var round = 0
            while round < 1_000 {
                if round % 4 == 0 { ztd_crossfade_begin(&fade, 480) }
                ztd_crossfade_mix(&fade, a, b, out, 512)
                round += 1
            }
        }
    }
}
