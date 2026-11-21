import Foundation

/// Plan emission: from a kernel of the intermediate representation to a C kernel (WP-311a).
/// Control context. Every implementation is chosen here, by size, once (SEL-3).
enum KernelFactory {
    /// Creates the kernel a step describes. The caller owns it.
    static func make(_ step: IRKernel, crossovers: CrossoverTable) throws(DSPError) -> ztd_kernel_t {
        let position = step.position
        // More channels than 32 bits count are more than any constructor accepts: it refuses.
        let channels = UInt32(clamping: position.kernelChannels)
        let rate = position.environment.sampleRate
        let frames = position.maximumFrames
        let requested = position.environment.implementation

        func bound(_ primitive: Primitive, size: Int) -> ztd_implementation_t {
            crossovers.implementation(for: primitive, size: size, requested: requested) == .accelerate
                ? ZTD_IMPLEMENTATION_ACCELERATE : ZTD_IMPLEMENTATION_NATIVE
        }
        /// A ramp in frames at this place. One that is over before it begins is no ramp; one
        /// that is no time at all, or more frames than a kernel counts, is refused (§9.3).
        func rampFrames(_ seconds: TimeInterval) throws(DSPError) -> UInt32 {
            guard let frames = FrameCount.ramp(seconds, at: rate) else {
                throw .invalidParameter(
                    stage: step.path, parameter: "ramp", reason: "a ramp of \(seconds) s at \(rate) Hz is not a number of frames a kernel can count")
            }
            return frames
        }

        var kernel: ztd_kernel_t
        switch step.spec {
        case .gain(let factor, let ramp):
            kernel = ztd_gain_cascade_create(channels, [factor], 1, try rampFrames(ramp), bound(.gainKernel, size: frames))
        case .gainCascade(let factors, let ramp):
            kernel = ztd_gain_cascade_create(channels, factors, UInt32(clamping: factors.count), try rampFrames(ramp), bound(.gainKernel, size: frames))
        case .custom(let custom):
            kernel = custom.make(Int(channels), rate, frames)
            try agree(custom.latencyFrames, Int(kernel.latency_frames), custom.name, &kernel, step)
            // Values reach a kernel that runs through its `command` entry (§5.5.4). A stage that
            // states values and makes a kernel without one could never be given other values.
            if !custom.values.isEmpty, !ztd_kernel_is_null(&kernel), kernel.command == nil {
                ztd_kernel_destroy(&kernel)
                throw .unsupportedConfiguration(
                    reason: "\(custom.name) states \(custom.values.count) value(s), and its kernel has no `command` entry to take them", stage: step.path)
            }
        case .processor(let custom):
            let processor: any SampleProcessor
            // The processor as the one that takes values, when it was made as one: known here,
            // so nothing is asked of the processor's type on the thread that runs it.
            let adjustable: (any AdjustableSampleProcessor)?
            if let makeAdjustable = custom.makeAdjustable {
                let made = try makeAdjustable(position.environment)
                processor = made
                adjustable = made
            } else {
                processor = try custom.make(position.environment)
                adjustable = nil
            }
            // What the processor says of itself goes into the 32 bits a kernel counts in. A
            // figure they do not hold is refused, not cut: the delay of everything behind the
            // stage is counted from it (REAL-5, §9.3).
            guard let latency = UInt32(exactly: max(processor.latencyFrames, 0)) else {
                throw .invalidParameter(
                    stage: step.path, parameter: "latencyFrames",
                    reason: "\(custom.name) runs with a latency of \(processor.latencyFrames) frames, more than a kernel can count")
            }
            guard let settling = UInt32(exactly: max(processor.settlingFrames, 0)) else {
                throw .invalidParameter(
                    stage: step.path, parameter: "settlingFrames",
                    reason: "\(custom.name) runs with a settling time of \(processor.settlingFrames) frames, more than a kernel can count")
            }
            kernel = ProcessorKernel.make(processor, adjustable: adjustable, latencyFrames: latency, settlingFrames: settling)
            try agree(custom.latencyFrames, Int(kernel.latency_frames), custom.name, &kernel, step)
        case .analysis:
            throw .unsupportedConfiguration(reason: "an analysis step is a node, not a kernel", stage: step.path)
        default:
            kernel = try StockKernels.make(step, channels: channels, sampleRate: rate, maximumFrames: frames, bound: bound, rampFrames: rampFrames)
        }
        guard !ztd_kernel_is_null(&kernel) else {
            throw .resourceAllocationFailed(what: "the kernel of \(step.path.stageName ?? "a stage")", stage: step.path)
        }
        return kernel
    }

    /// A stage written outside the package states its latency twice: in its description, which
    /// the environment downstream is computed from, and in the object that runs. The two must
    /// be one figure, or everything behind the stage is stamped with the wrong time (REAL-5).
    private static func agree(
        _ described: Int, _ actual: Int, _ name: String, _ kernel: inout ztd_kernel_t, _ step: IRKernel
    ) throws(DSPError) {
        guard !ztd_kernel_is_null(&kernel), described != actual else { return }
        ztd_kernel_destroy(&kernel)
        throw .unsupportedConfiguration(
            reason: "\(name) is described with a latency of \(described) frames and runs with one of \(actual): the two must be equal", stage: step.path)
    }
}
