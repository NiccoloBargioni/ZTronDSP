import Accelerate
import ZTronDSPCore

// The analysis-thread half of the framing steps (WP-503, WP-504). Nothing here allocates,
// locks or logs after its initialiser returns; loops are `while` loops (RT-2, CR-002).

/// Brings the channels of a block to the one sequence a framing step reads: one channel as it
/// is, or the mean of all of them.
final class ChannelMixer {
    private let channel: Int?
    private let scratch: AlignedBuffer<Float>?
    /// The most frames one call of `sequence` takes.
    let chunk: Int

    /// - Parameter channel: the channel to read, or `nil` for the mean of all channels.
    init(channel: Int?, channelCount: Int, maximumFrames: Int) throws(DSPError) {
        self.channel = channel
        if channel == nil, channelCount > 1 {
            chunk = max(maximumFrames, 1)
            scratch = try AlignedBuffer<Float>(count: chunk)
        } else {
            chunk = Int.max
            scratch = nil
        }
    }

    /// `count` frames of `block` from `start` on, as one sequence. Valid until the next call.
    func sequence(of block: AudioBlock, from start: Int, count: Int) -> UnsafePointer<Float> {
        if let channel { return UnsafePointer(block.channel(channel) + start) }
        guard let scratch, block.channelCount > 1 else { return UnsafePointer(block.channel(0) + start) }
        let mix = scratch.baseAddress
        let length = vDSP_Length(count)
        vDSP_vadd(block.channel(0) + start, 1, block.channel(1) + start, 1, mix, 1, length)
        var index = 2
        while index < block.channelCount {
            vDSP_vadd(mix, 1, block.channel(index) + start, 1, mix, 1, length)
            index &+= 1
        }
        var scale = 1 / Float(block.channelCount)
        vDSP_vsmul(mix, 1, &scale, mix, 1, length)
        return UnsafePointer(mix)
    }
}

/// The node of `STFT`: frames the signal, windows each frame, transforms it.
final class STFTNode: AnalysisNode {
    private let frame: Int
    private let sampleRate: Double
    private let framer: Framer
    private let plan: any FFTPlan
    private let mixer: ChannelMixer
    private let taper: AlignedBuffer<Float>
    /// The windowed frame, followed by the zeros that pad it to the transform length.
    private let windowed: AlignedBuffer<Float>
    /// Samples taken since the last reset: the position of the next one.
    private var position = 0

    let latencyFrames: Int
    let settlingFrames: Int

    init(frame: Int, hop: Int, taper: [Float], alignment: FrameAlignment, plan: any FFTPlan, mixer: ChannelMixer, sampleRate: Double) throws(DSPError) {
        self.frame = frame
        self.sampleRate = sampleRate
        self.plan = plan
        self.mixer = mixer
        framer = try Framer(frameSize: frame, hopSize: hop, alignment: alignment)
        self.taper = try AlignedBuffer<Float>(copying: taper)
        windowed = try AlignedBuffer<Float>(count: max(plan.length, frame))
        // A centred frame is known half a frame after the sample it is centred on. Either way a
        // frame holds only what arrived since the reset once a whole frame has arrived.
        latencyFrames = alignment == .centered ? frame / 2 : 0
        settlingFrames = frame - latencyFrames
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, let real = output.real.baseAddress, let imaginary = output.imaginary.baseAddress else { return }
        let total = block.frameCount
        let origin = position
        var done = 0
        while done < total {
            let count = min(total - done, mixer.chunk)
            let samples = mixer.sequence(of: block, from: done, count: count)
            var offset = 0
            while offset < count {
                offset += framer.append(samples + offset, count: count - offset)
                while let view = framer.frame {
                    vDSP_vmul(view, 1, taper.baseAddress, 1, windowed.baseAddress, 1, vDSP_Length(frame))
                    plan.forward(windowed.baseAddress, real: real, imaginary: imaginary)
                    // The frame's time is the time of the sample it is aligned to.
                    output.emit(time: input.time + Double(framer.framePosition - origin) / sampleRate)
                    framer.advance()
                }
            }
            done += count
        }
        position &+= total
    }

    func reset() {
        framer.reset()
        position = 0
    }
}
