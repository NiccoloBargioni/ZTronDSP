import CZTronDSP
import Foundation

// Kernels written in Swift for the tests of the plan runner. A kernel's functions are C function
// pointers without captures; everything they need is in the state they are handed.

typealias KernelProcess = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>?>?, UnsafePointer<UnsafeMutablePointer<Float>?>?, UInt32, UInt32) -> UInt32
typealias KernelCommand = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<ztd_command_t>?) -> Void
typealias KernelReset = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias KernelDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// The state of the general-purpose test kernel: per channel, `y[n] = gain · x[n − delay]`
/// passed through a one-pole smoother, `s ← s + (1 − pole)·(v − s)`. With `delay` 0 and `pole`
/// 0 it is a plain gain.
struct TestKernelState {
    var gain: Float = 1
    var pole: Float = 0
    var delay: Int32 = 0
    var position: Int32 = 0
    var line: UnsafeMutablePointer<Float>?      // `delay` samples, mono
    var smoothed: Float = 0
    var calls: Int32 = 0
    var resets: Int32 = 0
    var commands: Int32 = 0
    var framesSeen: Int64 = 0
    var destroyed: UnsafeMutablePointer<Int32>?  // incremented when the kernel is destroyed
}

private let testProcess: KernelProcess = { state, input, output, channels, frames in
    let s = state!.assumingMemoryBound(to: TestKernelState.self)
    s.pointee.calls += 1
    s.pointee.framesSeen += Int64(frames)
    var channel = 0
    while channel < Int(channels) {
        let source = input![channel]!, target = output![channel]!
        var frame = 0
        while frame < Int(frames) {
            var value = source[frame]
            if s.pointee.delay > 0, channel == 0, let line = s.pointee.line {
                let position = Int(s.pointee.position)
                let delayed = line[position]
                line[position] = value
                s.pointee.position = Int32((position + 1) % Int(s.pointee.delay))
                value = delayed
            }
            value *= s.pointee.gain
            if s.pointee.pole != 0, channel == 0 {
                s.pointee.smoothed += (1 - s.pointee.pole) * (value - s.pointee.smoothed)
                value = s.pointee.smoothed
            }
            target[frame] = value
            frame += 1
        }
        channel += 1
    }
    return frames
}

private let testCommand: KernelCommand = { state, command in
    let s = state!.assumingMemoryBound(to: TestKernelState.self)
    s.pointee.commands += 1
    if command!.pointee.kind == UInt32(ZTD_COMMAND_SET_VALUES) { s.pointee.gain = Float(command!.pointee.scalar.0) }
}

private let testReset: KernelReset = { state in
    let s = state!.assumingMemoryBound(to: TestKernelState.self)
    s.pointee.resets += 1
    s.pointee.smoothed = 0
    s.pointee.position = 0
    if let line = s.pointee.line { line.update(repeating: 0, count: Int(s.pointee.delay)) }
}

private let testDestroy: KernelDestroy = { state in
    let s = state!.assumingMemoryBound(to: TestKernelState.self)
    s.pointee.destroyed?.pointee += 1
    s.pointee.line?.deallocate()
    s.deallocate()
}

/// A halving kernel: keeps every second frame, to exercise a rate change in a plan.
private let halvingProcess: KernelProcess = { state, input, output, channels, frames in
    let s = state!.assumingMemoryBound(to: TestKernelState.self)
    s.pointee.calls += 1
    var phase = Int(s.pointee.position)
    var written = 0
    var channel = 0
    while channel < Int(channels) {
        let source = input![channel]!, target = output![channel]!
        var frame = Int(s.pointee.position)
        written = 0
        while frame < Int(frames) {
            target[written] = source[frame]
            written += 1
            frame += 2
        }
        phase = frame - Int(frames)
        channel += 1
    }
    s.pointee.position = Int32(phase)
    return UInt32(written)
}

enum TestKernel {
    /// Creates the general-purpose test kernel and returns it with a pointer to its state, which
    /// stays valid until the kernel is destroyed.
    static func make(
        gain: Float = 1, pole: Float = 0, delay: Int = 0, latency: Int = 0, settling: Int = 0,
        destroyed: UnsafeMutablePointer<Int32>? = nil
    ) -> (kernel: ztd_kernel_t, state: UnsafeMutablePointer<TestKernelState>) {
        let state = UnsafeMutablePointer<TestKernelState>.allocate(capacity: 1)
        state.initialize(to: TestKernelState(gain: gain, pole: pole, delay: Int32(delay), destroyed: destroyed))
        if delay > 0 {
            state.pointee.line = .allocate(capacity: delay)
            state.pointee.line!.initialize(repeating: 0, count: delay)
        }
        let kernel = ztd_kernel_t(
            process: testProcess, command: testCommand, reset: testReset, destroy: testDestroy,
            state: UnsafeMutableRawPointer(state), latency_frames: UInt32(latency), settling_frames: UInt32(settling))
        return (kernel, state)
    }

    /// A kernel that keeps every second frame.
    static func makeHalving(destroyed: UnsafeMutablePointer<Int32>? = nil) -> (kernel: ztd_kernel_t, state: UnsafeMutablePointer<TestKernelState>) {
        let state = UnsafeMutablePointer<TestKernelState>.allocate(capacity: 1)
        state.initialize(to: TestKernelState(destroyed: destroyed))
        let kernel = ztd_kernel_t(
            process: halvingProcess, command: nil, reset: testReset, destroy: testDestroy,
            state: UnsafeMutableRawPointer(state), latency_frames: 0, settling_frames: 0)
        return (kernel, state)
    }
}

/// Mono channel tables around two buffers, for calling a plan.
final class MonoBuffers {
    let capacity: Int
    let input: UnsafeMutablePointer<Float>
    let output: UnsafeMutablePointer<Float>
    private let inputTable: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outputTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    init(capacity: Int) {
        self.capacity = capacity
        input = .allocate(capacity: capacity)
        output = .allocate(capacity: capacity)
        input.initialize(repeating: 0, count: capacity)
        output.initialize(repeating: 0, count: capacity)
        inputTable = .allocate(capacity: 1)
        outputTable = .allocate(capacity: 1)
        inputTable.initialize(to: UnsafePointer(input))
        outputTable.initialize(to: output)
    }

    deinit {
        input.deallocate()
        output.deallocate()
        inputTable.deallocate()
        outputTable.deallocate()
    }

    var inTable: UnsafePointer<UnsafePointer<Float>?> { UnsafePointer(inputTable) }
    var outTable: UnsafePointer<UnsafeMutablePointer<Float>?> { UnsafePointer(outputTable) }

    /// Runs `signal` through `plan` in blocks of the given sizes (cycled) and returns everything
    /// the plan wrote. `beforeBlock` is called with the index of the first sample of each block.
    func run(_ plan: OpaquePointer, _ signal: [Float], blocks: [Int], beforeBlock: (Int) -> Void = { _ in }) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(signal.count)
        var position = 0
        var turn = 0
        while position < signal.count {
            let count = min(blocks[turn % blocks.count], signal.count - position, capacity)
            turn += 1
            beforeBlock(position)
            signal.withUnsafeBufferPointer { input.update(from: $0.baseAddress! + position, count: count) }
            let written = Int(ztd_plan_run(plan, inTable, outTable, 1, UInt32(count)))
            result.append(contentsOf: UnsafeBufferPointer(start: output, count: written))
            position += count
        }
        return result
    }
}

func setActive(_ plan: OpaquePointer, _ index: Int, _ active: Bool) {
    var command = ztd_command_t()
    command.target = UInt32(index)
    command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
    command.scalar.0 = active ? 1 : 0
    ztd_plan_command(plan, &command)
}
