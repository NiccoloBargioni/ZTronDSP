import Darwin

/// A `SampleProcessor` behind the kernel ABI, so that a stage written in Swift runs in a C
/// plan like any other: it is fused around, switched, pre-rolled and moved by the same code
/// (EXT-2).
final class ProcessorBox {
    let processor: any SampleProcessor

    init(_ processor: any SampleProcessor) {
        self.processor = processor
    }
}

enum ProcessorKernel {
    /// Wraps `processor`. The kernel owns it and releases it through its `destroy`.
    ///
    /// - Parameters:
    ///   - latencyFrames: the processor's latency, as the kernel states it: counted by the
    ///     caller, who refuses a figure a kernel's 32 bits do not hold.
    ///   - settlingFrames: its settling time, likewise.
    static func make(_ processor: any SampleProcessor, latencyFrames: UInt32, settlingFrames: UInt32) -> ztd_kernel_t {
        let state = Unmanaged.passRetained(ProcessorBox(processor)).toOpaque()
        return ztd_kernel_t(
            process: { state, input, output, channels, frames in
                guard let state, let input, let output else { return 0 }
                let box = Unmanaged<ProcessorBox>.fromOpaque(state).takeUnretainedValue()
                // A processor works in place: bring the input to the output, then let it run.
                var channel = 0
                while channel < Int(channels) {
                    if let source = input[channel], let target = output[channel] {
                        memcpy(target, source, Int(frames) * MemoryLayout<Float>.stride)
                    }
                    channel += 1
                }
                var block = AudioBlock(channels: output, channelCount: Int(channels), capacity: Int(frames), frameCount: Int(frames))
                box.processor.process(&block)
                return frames
            },
            command: nil,
            reset: { state in
                guard let state else { return }
                Unmanaged<ProcessorBox>.fromOpaque(state).takeUnretainedValue().processor.reset()
            },
            destroy: { state in
                guard let state else { return }
                Unmanaged<ProcessorBox>.fromOpaque(state).release()
            },
            state: state,
            latency_frames: latencyFrames,
            settling_frames: settlingFrames)
    }
}
