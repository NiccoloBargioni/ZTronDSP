import Darwin

/// A `SampleProcessor` behind the kernel ABI, so that a stage written in Swift runs in a C
/// plan like any other: it is fused around, switched, pre-rolled and moved by the same code
/// (EXT-2).
final class ProcessorBox {
    let processor: any SampleProcessor
    /// The same processor, when it takes values while it runs (§5.5.4).
    let adjustable: (any AdjustableSampleProcessor)?
    /// The same processor, when it reads one block and writes another (EXT-4).
    let outOfPlace: (any OutOfPlaceSampleProcessor)?

    init(_ processor: any SampleProcessor, adjustable: (any AdjustableSampleProcessor)?, outOfPlace: (any OutOfPlaceSampleProcessor)?) {
        self.processor = processor
        self.adjustable = adjustable
        self.outOfPlace = outOfPlace
    }
}

enum ProcessorKernel {
    private typealias Process = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>?>?, UnsafePointer<UnsafeMutablePointer<Float>?>?, UInt32, UInt32
    ) -> UInt32

    /// Wraps `processor`. The kernel owns it and releases it through its `destroy`.
    ///
    /// What the processor is, one that works in place or one that writes another block, is
    /// asked here, on the control context, once: the kernel is given the entry that fits, and
    /// nothing is asked of the processor's type on the thread that runs it.
    ///
    /// - Parameters:
    ///   - adjustable: `processor` as the one that takes values, or `nil` for one without:
    ///     its kernel has no `command` entry then.
    ///   - latencyFrames: the processor's latency, as the kernel states it: counted by the
    ///     caller, who refuses a figure a kernel's 32 bits do not hold.
    ///   - settlingFrames: its settling time, likewise.
    static func make(
        _ processor: any SampleProcessor, adjustable: (any AdjustableSampleProcessor)?, latencyFrames: UInt32, settlingFrames: UInt32
    ) -> ztd_kernel_t {
        let outOfPlace = processor as? any OutOfPlaceSampleProcessor
        let state = Unmanaged.passRetained(ProcessorBox(processor, adjustable: adjustable, outOfPlace: outOfPlace)).toOpaque()
        return ztd_kernel_t(
            process: outOfPlace == nil ? inPlace : blockToBlock,
            // `ZTD_COMMAND_SET_VALUES`: `count` doubles at `values`, handed to the processor
            // as they are (§5.5.4). Any other command is not for a processor.
            command: adjustable == nil ? nil : { state, command in
                guard let state, let command, command.pointee.kind == UInt32(ZTD_COMMAND_SET_VALUES),
                      let values = command.pointee.values else { return }
                let count = Int(command.pointee.count)
                Unmanaged<ProcessorBox>.fromOpaque(state)._withUnsafeGuaranteedRef { box in
                    box.adjustable?.setValues(UnsafeBufferPointer(start: values.assumingMemoryBound(to: Double.self), count: count))
                }
            },
            reset: { state in
                guard let state else { return }
                Unmanaged<ProcessorBox>.fromOpaque(state)._withUnsafeGuaranteedRef { $0.processor.reset() }
            },
            destroy: { state in
                guard let state else { return }
                Unmanaged<ProcessorBox>.fromOpaque(state).release()
            },
            state: state,
            latency_frames: latencyFrames,
            settling_frames: settlingFrames)
    }

    // The plan keeps the box alive for as long as it calls these: the box is used as it
    // stands, without a retain and a release around every block.

    /// A processor that works in place: the input is brought to the output, where it runs.
    /// The copy cannot be saved: the block a plan reads is not the plan's to write (it is the
    /// source's, which every session on the source reads).
    private static let inPlace: Process = { state, input, output, channels, frames in
        guard let state, let input, let output else { return 0 }
        var channel = 0
        while channel < Int(channels) {
            if let source = input[channel], let target = output[channel] {
                memcpy(target, source, Int(frames) * MemoryLayout<Float>.stride)
            }
            channel += 1
        }
        var block = AudioBlock(channels: output, channelCount: Int(channels), capacity: Int(frames), frameCount: Int(frames))
        Unmanaged<ProcessorBox>.fromOpaque(state)._withUnsafeGuaranteedRef { $0.processor.process(&block) }
        return frames
    }

    /// A processor that reads one block and writes another: it is handed the plan's two
    /// blocks, and nothing is copied in front of it (EXT-4).
    private static let blockToBlock: Process = { state, input, output, channels, frames in
        guard let state, let input, let output else { return 0 }
        // The same table, read as the channels of a block: a block does not write through
        // itself, and the processor is told not to write its input.
        let source = AudioBlock(
            channels: UnsafeRawPointer(input).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self),
            channelCount: Int(channels), capacity: Int(frames), frameCount: Int(frames))
        var target = AudioBlock(channels: output, channelCount: Int(channels), capacity: Int(frames), frameCount: Int(frames))
        Unmanaged<ProcessorBox>.fromOpaque(state)._withUnsafeGuaranteedRef { $0.outOfPlace?.process(source, into: &target) }
        return frames
    }
}
