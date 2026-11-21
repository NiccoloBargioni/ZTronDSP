// §5.5.4, EXT-1: a kernel and a processor written outside the package state their values apart
// from their structure, as the stock stages do, so that a changed value is sent to the one that
// runs instead of making another. `make` is given the values of the description; a processor
// that states values is one that takes new values while it runs. (This fixture replaced the
// finding that a CustomKernel had no place for its values.)
import ExternalStages
import ZTronDSP

/// A factor, taken while it runs: what a processor with values is.
final class Scaler: AdjustableSampleProcessor, OutOfPlaceSampleProcessor {
    private var factor: Float

    init(factor: Float) { self.factor = factor }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ block: inout AudioBlock) {
        var channel = 0
        while channel < block.channelCount {
            Vector.scale(UnsafePointer(block.channel(channel)), by: factor, into: block.channel(channel), count: block.frameCount)
            channel += 1
        }
    }

    func process(_ input: AudioBlock, into output: inout AudioBlock) {
        var channel = 0
        while channel < min(input.channelCount, output.channelCount) {
            Vector.scale(UnsafePointer(input.channel(channel)), by: factor, into: output.channel(channel), count: input.frameCount)
            channel += 1
        }
    }

    func setValues(_ values: UnsafeBufferPointer<Double>) {
        if let first = values.first { factor = Float(first) }
    }

    func reset() {}
}

/// A comb on a kernel of its own and a scaler, each with its value apart from its key.
struct CombAndScaler: SequenceStage {
    let feedback: Double
    let factor: Double

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "Comb", key: 480, values: [feedback]) { _, _, _, values in
            values.count == 1 ? ztd_kernel_identity() : ztd_kernel_t()
        }))
        context.emit(.processor(CustomProcessor(name: "Scaler", key: 0, values: [factor]) { _, values throws(DSPError) -> any AdjustableSampleProcessor in
            Scaler(factor: Float(values.first ?? 1))
        }))
    }
}

// The values are what the descriptions carry; the structure is what tells one kernel from another.
let before = CustomKernel(name: "Comb", key: 480, values: [0.5]) { _, _, _, _ in ztd_kernel_identity() }
let after = CustomKernel(name: "Comb", key: 480, values: [0.7]) { _, _, _, _ in ztd_kernel_identity() }
let stated: [Double] = before.values + after.values
let processor = CustomProcessor(name: "Scaler", key: 0, values: [0.25]) { _, values throws(DSPError) -> any AdjustableSampleProcessor in
    Scaler(factor: Float(values[0]))
}
let processorValues: [Double] = processor.values
let pipeline: Pipeline<Samples, Samples> = Pipeline { CombAndScaler(feedback: 0.5, factor: 0.25); ExternalGain(.decibels(-6), ramp: 0.020) }
