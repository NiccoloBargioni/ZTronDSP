import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

// What the kernel suites share: a rig that drives a kernel through planar buffers in any block
// sizes, the references the kernels are held to (computed here, in double precision, from the
// definitions), and a thread that can be joined.

// MARK: Block sizes

/// The block sizes a kernel is driven with: a rule that cuts a number of frames into blocks.
struct Blocks: Sendable {
    let cut: @Sendable (Int) -> [Int]

    /// Everything in one block.
    static let whole = Blocks { [$0] }

    /// Blocks of one size; the last one takes what is left.
    static func fixed(_ size: Int) -> Blocks {
        Blocks { total in
            var sizes: [Int] = []
            var left = total
            while left > 0 {
                sizes.append(min(size, left))
                left -= sizes[sizes.count - 1]
            }
            return sizes
        }
    }

    /// Seeded blocks of 0 … `limit` frames: empty blocks, single frames and sizes that share no
    /// factor with anything a kernel does inside.
    static func irregular(seed: UInt64, upTo limit: Int) -> Blocks {
        Blocks { total in
            var generator = SeededGenerator(seed: seed)
            var sizes: [Int] = []
            var left = total
            while left > 0 {
                let size = min(Int(generator.next() % UInt64(limit + 1)), left)
                sizes.append(size)
                left -= size
            }
            return sizes
        }
    }

    /// The given sizes, over and over.
    static func cycle(_ pattern: [Int]) -> Blocks {
        Blocks { total in
            var sizes: [Int] = []
            var left = total
            var index = 0
            while left > 0 {
                let size = min(pattern[index % pattern.count], left)
                sizes.append(size)
                left -= size
                index += 1
            }
            return sizes
        }
    }
}

// MARK: The rig

/// Everything an audited or timed loop needs to call a kernel, as plain values: nothing in it is
/// reference-counted, so using it inside `expectNoAllocations` allocates nothing.
struct KernelCall {
    typealias Process = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>?>?, UnsafePointer<UnsafeMutablePointer<Float>?>?, UInt32, UInt32
    ) -> UInt32
    typealias Command = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<ztd_command_t>?) -> Void
    typealias Reset = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let process: Process
    let command: Command?
    let reset: Reset
    let state: UnsafeMutableRawPointer?
    let input: UnsafePointer<UnsafePointer<Float>?>
    let output: UnsafePointer<UnsafeMutablePointer<Float>?>
    let channels: UInt32

    /// One block of `frames` frames from the arena's input to its output.
    @discardableResult
    func run(_ frames: UInt32) -> UInt32 {
        process(state, input, output, channels, frames)
    }
}

/// A kernel with the buffers to drive it. It owns the kernel and destroys it.
final class KernelRig {
    private var kernel: ztd_kernel_t
    let channels: Int
    private var arenas: [UnsafeMutableRawPointer] = []
    private var pendingCommands: [UnsafeMutablePointer<ztd_command_t>] = []
    /// What each block of the last `run` took and gave: the block sizes and the frames `process` returned.
    private(set) var lastBlocks: [(frames: Int, produced: Int)] = []

    init(_ kernel: ztd_kernel_t, channels: Int) {
        self.kernel = kernel
        self.channels = channels
    }

    deinit {
        ztd_kernel_destroy(&kernel)
        for arena in arenas { arena.deallocate() }
        for command in pendingCommands { command.deallocate() }
    }

    /// True when the constructor could not make the kernel.
    var isNull: Bool { withUnsafePointer(to: kernel) { ztd_kernel_is_null($0) } }
    var latency: Int { Int(kernel.latency_frames) }
    var settling: Int { Int(kernel.settling_frames) }
    var hasCommand: Bool { kernel.command != nil }
    /// The kernel itself, for a function that takes one.
    func withKernel<T>(_ body: (UnsafePointer<ztd_kernel_t>) -> T) -> T { withUnsafePointer(to: kernel, body) }

    /// Runs `input` (one array per channel, of equal length) through the kernel, cut into blocks,
    /// and returns what it wrote, per channel. `expansion` is the most output frames one input
    /// frame can become. The output buffer starts as NaN, so a frame the kernel claims to have
    /// written but did not is seen.
    ///
    /// The output of channel c starts c frames past a 64-byte boundary: a kernel whose result
    /// depended on how the caller's buffers are aligned would give different channels different
    /// answers for the same signal.
    func run(_ input: [[Float]], _ blocks: Blocks = .whole, expansion: Int = 1) -> [[Float]] {
        precondition(input.count == channels && Set(input.map(\.count)).count == 1)
        let frames = input[0].count
        let capacity = (frames * expansion + 2 * expansion + 16 + 15) / 16 * 16 + 1   // a 64-byte multiple, plus one frame
        let source = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1) * channels)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity * channels * MemoryLayout<Float>.stride, alignment: 64)
        let destination = storage.bindMemory(to: Float.self, capacity: capacity * channels)
        let inputs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channels)
        let outputs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        defer {
            source.deallocate()
            storage.deallocate()
            inputs.deallocate()
            outputs.deallocate()
        }
        for channel in 0 ..< channels {
            for frame in 0 ..< frames { source[channel * max(frames, 1) + frame] = input[channel][frame] }
        }
        destination.initialize(repeating: .nan, count: capacity * channels)

        var position = 0, written = 0
        lastBlocks = []
        for size in blocks.cut(frames) {
            for channel in 0 ..< channels {
                inputs[channel] = UnsafePointer(source + channel * max(frames, 1) + position)
                outputs[channel] = destination + channel * capacity + written
            }
            let produced = Int(kernel.process!(kernel.state, inputs, outputs, UInt32(channels), UInt32(size)))
            precondition(written + produced <= capacity, "the kernel wrote more than `expansion` allows")
            lastBlocks.append((size, produced))
            position += size
            written += produced
        }
        return (0 ..< channels).map { Array(UnsafeBufferPointer(start: destination + $0 * capacity, count: written)) }
    }

    /// The mono form of ``run(_:_:expansion:)-swift.method``.
    func run(_ input: [Float], _ blocks: Blocks = .whole, expansion: Int = 1) -> [Float] {
        run([input], blocks, expansion: expansion)[0]
    }

    /// ZTD_COMMAND_SET_VALUES with doubles at `values` (a cascade's coefficients).
    func setValues(_ values: [Double]) {
        values.withUnsafeBufferPointer { send(count: values.count, values: UnsafeRawPointer($0.baseAddress)) }
    }

    /// ZTD_COMMAND_SET_VALUES with floats at `values` (gains, taps).
    func setValues(_ values: [Float]) {
        values.withUnsafeBufferPointer { send(count: values.count, values: UnsafeRawPointer($0.baseAddress)) }
    }

    /// ZTD_COMMAND_SET_VALUES with one value carried in the message.
    func setScalar(_ value: Double) {
        send(count: 1, values: nil, scalar: value)
    }

    /// Any command at all, for the negative paths.
    func send(kind: UInt32 = UInt32(ZTD_COMMAND_SET_VALUES), count: Int, values: UnsafeRawPointer?, scalar: Double = 0) {
        var command = ztd_command_t()
        command.kind = kind
        command.count = UInt32(count)
        command.values = values
        command.scalar.0 = scalar
        kernel.command?(kernel.state, &command)
    }

    /// A NULL command: a kernel must shrug it off.
    func sendNothing() {
        kernel.command?(kernel.state, nil)
    }

    func reset() {
        kernel.reset!(kernel.state)
    }

    /// Buffers that live as long as the rig, filled with seeded noise, and the kernel's entry
    /// points: what a loop inside `expectNoAllocations` or `Benchmark.measure` calls.
    func arena(frames: Int, expansion: Int = 1, seed: UInt64 = 0xA4E7A, amplitude: Double = 0.5) -> KernelCall {
        let floatBytes = MemoryLayout<Float>.stride, pointerBytes = MemoryLayout<UnsafeRawPointer?>.stride
        let outputFrames = frames * expansion + 2 * expansion + 16
        let samples = UnsafeMutableRawPointer.allocate(byteCount: channels * (frames + outputFrames) * floatBytes, alignment: 64)
        let pointers = UnsafeMutableRawPointer.allocate(byteCount: 2 * channels * pointerBytes, alignment: 16)
        arenas.append(samples)
        arenas.append(pointers)
        let floats = samples.bindMemory(to: Float.self, capacity: channels * (frames + outputFrames))
        floats.initialize(repeating: 0, count: channels * (frames + outputFrames))
        let inputs = pointers.bindMemory(to: UnsafePointer<Float>?.self, capacity: channels)
        let outputs = (pointers + channels * pointerBytes).bindMemory(to: UnsafeMutablePointer<Float>?.self, capacity: channels)
        for channel in 0 ..< channels {
            let noise = TestSignal.whiteNoise(count: frames, seed: seed &+ UInt64(channel), amplitude: amplitude)
            let base = floats + channel * (frames + outputFrames)
            for frame in 0 ..< frames { base[frame] = noise[frame] }
            inputs[channel] = UnsafePointer(base)
            outputs[channel] = base + frames
        }
        return KernelCall(
            process: kernel.process!, command: kernel.command, reset: kernel.reset!, state: kernel.state,
            input: UnsafePointer(inputs), output: UnsafePointer(outputs), channels: UInt32(channels))
    }

    /// A ZTD_COMMAND_SET_VALUES command whose payload lives as long as the rig, for a loop that
    /// sends it from inside an audit.
    func preparedCommand(doubles values: [Double]) -> UnsafePointer<ztd_command_t> {
        let payload = UnsafeMutableRawPointer.allocate(byteCount: max(values.count, 1) * MemoryLayout<Double>.stride, alignment: 16)
        arenas.append(payload)
        payload.bindMemory(to: Double.self, capacity: max(values.count, 1)).initialize(from: values, count: values.count)
        return prepared(count: values.count, values: UnsafeRawPointer(payload), scalar: 0)
    }

    func preparedCommand(floats values: [Float]) -> UnsafePointer<ztd_command_t> {
        let payload = UnsafeMutableRawPointer.allocate(byteCount: max(values.count, 1) * MemoryLayout<Float>.stride, alignment: 16)
        arenas.append(payload)
        payload.bindMemory(to: Float.self, capacity: max(values.count, 1)).initialize(from: values, count: values.count)
        return prepared(count: values.count, values: UnsafeRawPointer(payload), scalar: 0)
    }

    func preparedCommand(scalar: Double) -> UnsafePointer<ztd_command_t> {
        prepared(count: 1, values: nil, scalar: scalar)
    }

    private func prepared(count: Int, values: UnsafeRawPointer?, scalar: Double) -> UnsafePointer<ztd_command_t> {
        let command = UnsafeMutablePointer<ztd_command_t>.allocate(capacity: 1)
        command.initialize(to: ztd_command_t())
        command.pointee.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        command.pointee.count = UInt32(count)
        command.pointee.values = values
        command.pointee.scalar.0 = scalar
        pendingCommands.append(command)
        return UnsafePointer(command)
    }
}

// MARK: References

/// What the kernels are held to, computed in double precision from the definitions.
enum Reference {
    /// y[n] = Σ taps[k] · x[n − k], with x zero before its first sample: the first `x.count` outputs.
    static func convolve(_ x: [Float], _ taps: [Float]) -> [Double] {
        var result = [Double](repeating: 0, count: x.count)
        for n in 0 ..< x.count {
            var sum = 0.0
            var k = 0
            while k < taps.count && k <= n {
                sum += Double(taps[k]) * Double(x[n - k])
                k += 1
            }
            result[n] = sum
        }
        return result
    }

    /// The bound of the stability register (row 7) on a K-term sum of products in Float32:
    /// K · ε · Σ|h| · max|x|.
    static func convolutionBound(_ x: [Float], _ taps: [Float]) -> Double {
        let magnitude = taps.reduce(0.0) { $0 + abs(Double($1)) }
        let peak = x.reduce(0.0) { max($0, abs(Double($1))) }
        return Double(taps.count) * Double(Float.ulpOfOne) * magnitude * peak
    }

    /// A cascade of second-order sections in direct form I, the recurrence of the kernel header:
    /// y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]. `coefficients` holds
    /// b0 b1 b2 a1 a2 per section. `change`, when given, replaces the coefficients before the
    /// frame it names and keeps the memory, as a live update does.
    static func cascade(_ x: [Float], _ coefficients: [Double], change: (frame: Int, coefficients: [Double])? = nil) -> [Double] {
        let sections = coefficients.count / 5
        var k = coefficients
        // history[s] is the last two values of the signal entering section s; history[sections] of the output.
        var history = [[Double]](repeating: [0, 0], count: sections + 1)
        var result = [Double](repeating: 0, count: x.count)
        for n in 0 ..< x.count {
            if let change, change.frame == n { k = change.coefficients }
            var value = Double(x[n])
            for s in 0 ..< sections {
                let output = k[5 * s] * value + k[5 * s + 1] * history[s][1] + k[5 * s + 2] * history[s][0]
                    - k[5 * s + 3] * history[s + 1][1] - k[5 * s + 4] * history[s + 1][0]
                history[s][0] = history[s][1]
                history[s][1] = value
                value = output
            }
            history[sections][0] = history[sections][1]
            history[sections][1] = value
            result[n] = value
        }
        return result
    }

    /// The same recurrence in Float32, every product and sum rounded on its own, left to right:
    /// what the native single-precision kernel computes, bit for bit.
    static func cascadeSingle(_ x: [Float], _ coefficients: [Double]) -> [Float] {
        let sections = coefficients.count / 5
        let k = coefficients.map { Float($0) }
        var history = [[Float]](repeating: [0, 0], count: sections + 1)
        var result = [Float](repeating: 0, count: x.count)
        for n in 0 ..< x.count {
            var value = x[n]
            for s in 0 ..< sections {
                let output = k[5 * s] * value + k[5 * s + 1] * history[s][1] + k[5 * s + 2] * history[s][0]
                    - k[5 * s + 3] * history[s + 1][1] - k[5 * s + 4] * history[s + 1][0]
                history[s][0] = history[s][1]
                history[s][1] = value
                value = output
            }
            history[sections][0] = history[sections][1]
            history[sections][1] = value
            result[n] = value
        }
        return result
    }

    /// The cascade in transposed direct form II with double state, rounded to Float32 on the way
    /// out: what the double-precision kernel computes, bit for bit.
    static func cascadeTransposed(_ x: [Float], _ coefficients: [Double], change: (frame: Int, coefficients: [Double])? = nil) -> [Float] {
        let sections = coefficients.count / 5
        var k = coefficients
        var state = [Double](repeating: 0, count: 2 * sections)
        var result = [Float](repeating: 0, count: x.count)
        for n in 0 ..< x.count {
            if let change, change.frame == n { k = change.coefficients }
            var value = Double(x[n])
            for s in 0 ..< sections {
                let output = k[5 * s] * value + state[2 * s]
                state[2 * s] = k[5 * s + 1] * value - k[5 * s + 3] * output + state[2 * s + 1]
                state[2 * s + 1] = k[5 * s + 2] * value - k[5 * s + 4] * output
                value = output
            }
            result[n] = Float(value)
        }
        return result
    }

    /// |H(e^{jω})| of a cascade at `frequency`, from its coefficients.
    static func magnitude(_ coefficients: [Double], at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let (c1, s1) = (cos(omega), -sin(omega)), (c2, s2) = (cos(2 * omega), -sin(2 * omega))
        var magnitude = 1.0
        for s in 0 ..< coefficients.count / 5 {
            let (b0, b1, b2, a1, a2) = (coefficients[5 * s], coefficients[5 * s + 1], coefficients[5 * s + 2], coefficients[5 * s + 3], coefficients[5 * s + 4])
            let numerator = ((b0 + b1 * c1 + b2 * c2), (b1 * s1 + b2 * s2))
            let denominator = ((1 + a1 * c1 + a2 * c2), (a1 * s1 + a2 * s2))
            magnitude *= (numerator.0 * numerator.0 + numerator.1 * numerator.1).squareRoot()
                / (denominator.0 * denominator.0 + denominator.1 * denominator.1).squareRoot()
        }
        return magnitude
    }

    /// |Σ x[n] · e^{−jωn}|: one bin of the transform of a signal, at any frequency.
    static func spectrumMagnitude(_ x: [Float], at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        var real = 0.0, imaginary = 0.0
        for n in 0 ..< x.count {
            real += Double(x[n]) * cos(omega * Double(n))
            imaginary -= Double(x[n]) * sin(omega * Double(n))
        }
        return (real * real + imaginary * imaginary).squareRoot()
    }

    /// The largest deviation of `actual` from `expected`, in dB relative to the peak of `expected`.
    /// −∞ when they are equal.
    static func deviation<A: Collection, E: Collection>(_ actual: A, _ expected: E) -> Double
    where A.Element: BinaryFloatingPoint, E.Element: BinaryFloatingPoint {
        var peak = 0.0, worst = 0.0
        var iterator = expected.makeIterator()
        for value in actual {
            let reference = Double(iterator.next() ?? 0)
            peak = max(peak, abs(reference))
            worst = max(worst, abs(Double(value) - reference))
        }
        guard worst > 0 else { return -.infinity }
        return 20 * log10(worst / peak)
    }

    /// The largest sample-to-sample difference in `range`: the measure of CLICK-1.
    static func largestStep(_ x: [Float], _ range: Range<Int>) -> Double {
        var largest = 0.0
        for n in range where n > 0 { largest = max(largest, abs(Double(x[n]) - Double(x[n - 1]))) }
        return largest
    }
}

/// Bit patterns, for comparisons that must tell −0 from +0 and must not trip over NaN ≠ NaN.
func bits(_ values: [Float]) -> [UInt32] { values.map(\.bitPattern) }

/// Prints a figure a test measured, so the log of a run carries the numbers the stability notes
/// and the package reports quote. Search the log for `[measured]`. (An equals sign, not a
/// colon: a label may end in "error", and the build helper's summary picks up "error:".)
func note(_ label: String, _ value: Double, _ unit: String = "") {
    print("[measured] \(label) = \(String(format: "%.5g", value))\(unit.isEmpty ? "" : " " + unit)")
}

/// CLICK-1 (§5.5.4): the largest sample-to-sample difference of the output from the change to
/// the end of the block after the one it was applied in, over the largest such difference in
/// steady state on either side. A change makes no click when this is at most 1.5.
func clickRatio(_ output: [Float], change: Int, block: Int, steadyBefore: Range<Int>, steadyAfter: Range<Int>) -> Double {
    let during = Reference.largestStep(output, change ..< min(change + 2 * block, output.count))
    let steady = max(Reference.largestStep(output, steadyBefore), Reference.largestStep(output, steadyAfter))
    return during / steady
}

/// The fixtures of the stress library (WP-016) and the cascades the generator made for them.
func stressCascade(_ name: String) -> KernelFixtures.Cascade {
    KernelFixtures.stress.first { $0.name == name }!
}

/// A windowed sinc: a low-pass with unity gain at 0 Hz and its cutoff at `cutoff` (in cycles per
/// sample, below 0.5), `count` taps under a Hann window. For tests that need two filters of one
/// length.
func windowedSinc(count: Int, cutoff: Double) -> [Float] {
    let centre = Double(count - 1) / 2
    var taps = (0 ..< count).map { index -> Double in
        let t = Double(index) - centre
        let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
        return sinc * (0.5 - 0.5 * cos(2 * .pi * (Double(index) + 0.5) / Double(count)))
    }
    let sum = taps.reduce(0, +)
    taps = taps.map { $0 / sum }
    return taps.map { Float($0) }
}

/// The Kaiser low-pass SciPy designed for a rate change by `factor`, as the Float32 taps a kernel takes.
func kaiserLowPass(_ factor: Int) -> [Float] {
    KernelFixtures.lowPass.first { $0.factor == factor }!.taps.map { Float($0) }
}

/// Seeded taps without any structure: every tap matters, none is zero.
func noiseTaps(_ count: Int) -> [Float] {
    TestSignal.whiteNoise(count: count, seed: 0x7A95 &+ UInt64(count), amplitude: 1).map { $0 == 0 ? 0.5 : $0 }
}

/// What a history kernel computes on: the input with every sample below 1e-20 in magnitude
/// taken as zero (RT-6, applied as the samples enter).
func cleaned(_ signal: [Float]) -> [Float] {
    signal.map { abs($0) < 1e-20 ? 0 : $0 }
}

/// The gain of one section at 0 Hz.
func gainAtZero(_ coefficients: [Double], section: Int) -> Double {
    let k = coefficients[5 * section ..< 5 * section + 5].map { $0 }
    return (k[0] + k[1] + k[2]) / (1 + k[3] + k[4])
}

/// The same low-pass cascade with its gain spread over the sections: each numerator is scaled so
/// that its section has unity gain at 0 Hz. For a cascade whose gain at 0 Hz is 1 the scale
/// factors multiply to 1, so the filter is the same; only the level between the sections changes.
func withUnityGainSections(_ coefficients: [Double]) -> [Double] {
    var result = coefficients
    for section in 0 ..< coefficients.count / 5 {
        let gain = gainAtZero(coefficients, section: section)
        for index in 0 ..< 3 { result[5 * section + index] /= gain }
    }
    return result
}

// MARK: Threads

/// A thread that can be joined: the two-thread tests hand work to one and wait for it without
/// sleeping.
final class JoinableThread {
    private final class Box { let body: () -> Void; init(_ body: @escaping () -> Void) { self.body = body } }
    private var thread: pthread_t?

    /// Starts `body` on a new thread.
    init(_ body: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(body))
        var handle: pthread_t?
        let result = pthread_create(&handle, nil, { context in
            let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
            box.body()
            return nil
        }, box.toOpaque())
        if result == 0 { thread = handle } else { box.release() }
    }

    var started: Bool { thread != nil }

    /// Waits for the thread to finish.
    func join() {
        if let thread { pthread_join(thread, nil) }
        thread = nil
    }
}

/// A value two threads may touch: the tests hand results across threads through it. Access is
/// guarded by a lock, so the Thread Sanitizer has nothing to say about the tests themselves.
final class Shared<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}
