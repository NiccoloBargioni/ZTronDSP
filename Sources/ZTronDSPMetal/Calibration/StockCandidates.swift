import Foundation
import ZTronDSPCore

/// The implementations `Calibration.measure()` times (WP-611b…d): every pair of the table of
/// §7.4 whose two sides exist below this target, each bound exactly as the plan compiler and
/// the toolkit bind it.
enum StockCandidates {
    /// One entry of the table, its size grid and its implementations.
    struct Pair: Sendable {
        let entry: CrossoverEntry
        let sizes: [Int]
        let lighter: CalibrationCandidate
        let heavier: CalibrationCandidate?
    }

    /// Powers of two from `first` to `last`.
    static func octaves(from first: Int, through last: Int) -> [Int] {
        var sizes: [Int] = []
        var size = first
        while size <= last {
            sizes.append(size)
            size *= 2
        }
        return sizes
    }

    /// The pairs, in the order of the table. The GPU median, which has no partner below this
    /// target yet, is added where there is a context.
    static func pairs(context: MetalContext?) -> [Pair] {
        var pairs = [
            Pair(entry: .elementwise, sizes: octaves(from: 8, through: 8_192), lighter: scale(.native), heavier: scale(.accelerate)),
            Pair(entry: .reductionSIMD, sizes: octaves(from: 4, through: 4_096), lighter: dot("Swift scalar loop", Vector.Native.dot),
                 heavier: dot("Swift 8-lane loop", Vector.Native.dotSIMD)),
            Pair(entry: .reductionAccelerate, sizes: octaves(from: 4, through: 4_096), lighter: dot("Swift 8-lane loop", Vector.Native.dotSIMD),
                 heavier: dot("vDSP_dotpr", Vector.Accelerated.dot, .accelerate)),
            Pair(entry: .laneExchange, sizes: octaves(from: 8, through: 8_192), lighter: laneExchange(.native), heavier: laneExchange(.accelerate)),
            Pair(entry: .gainKernel, sizes: octaves(from: 8, through: 4_096), lighter: gain(ZTD_IMPLEMENTATION_NATIVE),
                 heavier: gain(ZTD_IMPLEMENTATION_ACCELERATE)),
            Pair(entry: .biquadKernel, sizes: octaves(from: 1, through: 1_024), lighter: biquad(ZTD_IMPLEMENTATION_NATIVE),
                 heavier: biquad(ZTD_IMPLEMENTATION_ACCELERATE)),
            Pair(entry: .firPartitioned, sizes: octaves(from: 16, through: 4_096), lighter: fir(partitioned: false), heavier: fir(partitioned: true)),
        ]
        if let context {
            pairs.append(Pair(entry: .medianGPU, sizes: medianColumns.map { $0 * medianRows * medianKernel }, lighter: median(context), heavier: nil))
        }
        return pairs
    }

    // MARK: Workloads

    /// Two lanes of `count` values of seeded noise in −0.5 … 0.5, for the length of `body`.
    static func withLanes<Value>(_ count: Int, _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Value) -> Value {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * max(count, 1))
        defer { storage.deallocate() }
        var state: UInt32 = 0x2545_F491
        var index = 0
        while index < 2 * max(count, 1) {
            state = state &* 1_664_525 &+ 1_013_904_223
            storage[index] = Float(state >> 8) / Float(1 << 24) - 0.5
            index += 1
        }
        return body(storage, storage + max(count, 1))
    }

    /// Scaling a vector: the element-wise operation of E-26.
    static func scale(_ implementation: Implementation) -> CalibrationCandidate {
        CalibrationCandidate(implementation, label: implementation == .native ? "Swift loop" : "vDSP_vsmul") { size, time in
            withLanes(size) { input, output in
                if implementation == .native {
                    return time { Vector.Native.scale(input, by: 0.5, into: output, count: size) }
                }
                return time { Vector.Accelerated.scale(input, by: 0.5, into: output, count: size) }
            }
        }
    }

    /// A dot product: the reduction whose answer changes twice (E-26). The result is stored,
    /// so the call cannot be optimised away.
    static func dot(
        _ label: String, _ function: @escaping @Sendable (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Float,
        _ implementation: Implementation = .native
    ) -> CalibrationCandidate {
        CalibrationCandidate(implementation, label: label) { size, time in
            withLanes(size) { a, b in
                let sink = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                defer { sink.deallocate() }
                return time { sink.pointee = function(a, b, size) }
            }
        }
    }

    /// The minimum / maximum exchange of two lanes (WP-219).
    static func laneExchange(_ implementation: Implementation) -> CalibrationCandidate {
        CalibrationCandidate(implementation, label: implementation == .native ? "C loop" : "vDSP_vmin, vDSP_vmax") { size, time in
            withLanes(size) { a, b in
                if implementation == .native {
                    return time { ztd_lane_exchange_native(a, b, UInt32(size)) }
                }
                return time { ztd_lane_exchange_accelerate(a, b, UInt32(size)) }
            }
        }
    }

    /// Times one block of `frames` frames through a mono kernel, and frees the kernel. A
    /// kernel that could not be made is not a number of nanoseconds.
    static func timeKernel(_ kernel: ztd_kernel_t, frames: Int, _ time: (() -> Void) -> Double) -> Double {
        var kernel = kernel
        defer { ztd_kernel_destroy(&kernel) }
        guard let process = kernel.process else { return .nan }
        return withLanes(frames) { input, output in
            var inputChannel: UnsafePointer<Float>? = UnsafePointer(input)
            var outputChannel: UnsafeMutablePointer<Float>? = output
            return withUnsafePointer(to: &inputChannel) { inputs in
                withUnsafePointer(to: &outputChannel) { outputs in
                    time { _ = process(kernel.state, inputs, outputs, 1, UInt32(frames)) }
                }
            }
        }
    }

    /// The gain kernel at a steady gain (WP-207).
    static func gain(_ implementation: ztd_implementation_t) -> CalibrationCandidate {
        let native = implementation == ZTD_IMPLEMENTATION_NATIVE
        return CalibrationCandidate(native ? .native : .accelerate, label: native ? "C loop" : "vDSP_vsmul") { size, time in
            var factor: Float = 0.5
            return timeKernel(ztd_gain_create(1, &factor, 0, implementation), frames: size, time)
        }
    }

    /// Four second-order sections: an IIR of order 8.
    static let biquadSections = 4

    /// A single-precision biquad cascade (WP-208).
    static func biquad(_ implementation: ztd_implementation_t) -> CalibrationCandidate {
        let native = implementation == ZTD_IMPLEMENTATION_NATIVE
        return CalibrationCandidate(native ? .native : .accelerate, label: native ? "C loop" : "vDSP_biquad") { size, time in
            // A stable section, poles at a radius of 0.32, four times over.
            let coefficients: [Double] = (0 ..< biquadSections).flatMap { _ in [0.2, 0.4, 0.2, -0.3, 0.1] }
            return timeKernel(ztd_biquad_create(1, UInt32(biquadSections), coefficients, implementation), frames: size, time)
        }
    }

    /// The block an FIR is timed with.
    static let firBlock = 512

    /// An FIR of `size` taps: the direct kernel, or the partitioned one with the partition the
    /// plan compiler gives it, the largest power of two the block holds (WP-212, WP-215).
    static func fir(partitioned: Bool) -> CalibrationCandidate {
        CalibrationCandidate(partitioned ? .accelerate : .native, label: partitioned ? "Partitioned" : "Direct") { size, time in
            let taps = (0 ..< size).map { Float(1) / Float(size + $0) }
            let kernel = partitioned
                ? ztd_partitioned_create(1, taps, UInt32(size), UInt32(firBlock), 0)
                : ztd_fir_create(1, taps, UInt32(size), 0, 0)
            return timeKernel(kernel, frames: firBlock, time)
        }
    }

    /// The spectrograms the GPU median is timed on: the low-latency kernel of §6.10 over the
    /// bins of a 1 024-point transform, for these numbers of frames.
    static let medianKernel = 17
    static let medianRows = 513
    static let medianColumns = [8, 32, 128, 512]

    /// The median of a whole spectrogram along time, on the GPU (WP-610), end to end: the copy
    /// to the device, the kernel, the copy back (GPU-1).
    static func median(_ context: MetalContext) -> CalibrationCandidate {
        CalibrationCandidate(.metal, label: "Metal") { size, time in
            let columns = max(size / (medianRows * medianKernel), 1)
            let filter = MetalMedianFilter(context: context)
            var state: UInt32 = 0x9E37_79B9
            let values = (0 ..< medianRows * columns).map { _ -> Float in
                state = state &* 1_664_525 &+ 1_013_904_223
                return Float(state >> 8) / Float(1 << 24)
            }
            var failed = false
            let elapsed = time {
                if (try? filter.filter(values, rowCount: medianRows, kernel: medianKernel, along: .time)) == nil { failed = true }
            }
            return failed ? .nan : elapsed
        }
    }
}
