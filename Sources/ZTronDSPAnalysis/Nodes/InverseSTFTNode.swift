import Accelerate
import ZTronDSPCore

/// The node of `InverseSTFT`: each spectrum back to a frame, overlap-added, one hop of
/// finished samples out per frame in (WP-505).
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class InverseSTFTNode: AnalysisNode {
    private let frame: Int
    private let hop: Int
    private let bins: Int
    private let scale: Float
    private let sampleRate: Double
    private let plan: any FFTPlan
    private let adder: OverlapAdder
    private let signal: AlignedBuffer<Float>
    private let finished: AlignedBuffer<Float>
    /// Zeros the output begins with: the delay of the round trip, in samples.
    private let preroll: Int
    /// Samples the analysis put before the signal by reflection: they are synthesised and
    /// dropped.
    private let reflected: Int
    /// Samples between the first sample of a frame and the sample its time names.
    private let lead: Int
    private var toDrop: Int
    private var hasStarted = false

    let latencyFrames: Int
    let settlingFrames: Int

    init(frame: Int, hop: Int, window: [Float], scale: Float, alignment: FrameAlignment, preroll: Int, ownDelay: Int,
         plan: any FFTPlan, sampleRate: Double) throws(DSPError) {
        self.frame = frame
        self.hop = hop
        self.scale = scale
        self.sampleRate = sampleRate
        self.plan = plan
        self.preroll = preroll
        bins = plan.length / 2 + 1
        adder = try OverlapAdder(frameSize: frame, hopSize: hop, window: window)
        signal = try AlignedBuffer<Float>(count: max(plan.length, frame))
        finished = try AlignedBuffer<Float>(count: hop)
        reflected = alignment == .centered ? frame / 2 : 0
        lead = alignment == .centered ? frame / 2 : frame - 1
        toDrop = reflected
        // In frames of its input: the hops a sample waits, and the hops until every sample is
        // covered by all the frames that reach it.
        latencyFrames = (ownDelay + hop - 1) / hop
        settlingFrames = (frame + hop - 1) / hop
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let spectrum = input.complex, spectrum.count >= bins, let real = spectrum.real.baseAddress,
              let imaginary = spectrum.imaginary.baseAddress, let block = output.samples
        else { return }
        plan.inverse(real: real, imaginary: imaginary, into: signal.baseAddress)
        if scale != 1 {
            var factor = scale
            vDSP_vsmul(signal.baseAddress, 1, &factor, signal.baseAddress, 1, vDSP_Length(frame))
        }
        adder.add(UnsafePointer(signal.baseAddress), into: finished.baseAddress)

        // The hop this frame completes starts at the frame's first sample.
        var first = 0
        if toDrop > 0 {
            first = min(toDrop, hop)
            toDrop -= first
        }
        let count = hop - first
        guard count > 0 else { return }
        let start = input.time - Double(lead - first) / sampleRate
        let target = block.channel(0)
        let stride = MemoryLayout<Float>.stride
        if !hasStarted {
            hasStarted = true
            var remaining = preroll
            while remaining > 0 {
                let zeros = min(remaining, hop)
                memset(target, 0, zeros * stride)
                output.emit(count: zeros, time: start - Double(remaining) / sampleRate)
                remaining -= zeros
            }
        }
        memcpy(target, finished.baseAddress + first, count * stride)
        output.emit(count: count, time: start)
    }

    func reset() {
        adder.reset()
        toDrop = reflected
        hasStarted = false
    }
}
