import Accelerate
import ZTronDSPCore

/// The node of `Level` (WP-506): frames the signal with its own window and hop and reduces
/// each frame to one value in dBFS.
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class LevelNode: AnalysisNode {
    private let kind: LevelKind
    private let window: Int
    private let sampleRate: Double
    private let framer: Framer
    private let mixer: ChannelMixer
    private let bound: Vector.Bound
    private var position = 0

    var latencyFrames: Int { 0 }
    let settlingFrames: Int

    init(kind: LevelKind, window: Int, hop: Int, bound: Vector.Bound, mixer: ChannelMixer, sampleRate: Double) throws(DSPError) {
        self.kind = kind
        self.window = window
        self.sampleRate = sampleRate
        self.bound = bound
        self.mixer = mixer
        framer = try Framer(frameSize: window, hopSize: hop, alignment: .causal)
        settlingFrames = window
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
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
                    let decibels: Double
                    switch kind {
                    case .rms:
                        decibels = DSP.decibels(fromPower: Double(bound.meanSquare(view, window)))
                    case .peak:
                        var peak: Float = 0
                        vDSP_maxmgv(view, 1, &peak, vDSP_Length(window))
                        decibels = DSP.decibels(fromAmplitude: Double(peak))
                    }
                    // A value describes the window that ends at its newest sample.
                    output.emit(scalar: ScalarFrame(value: Float(decibels), confidence: 1),
                                time: input.time + Double(framer.framePosition - origin) / sampleRate)
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

/// The node of `Waveform` (WP-536): the least and the greatest sample of every stretch of
/// `bucket` samples, carried across blocks.
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class WaveformNode: AnalysisNode {
    private let bucket: Int
    private let sampleRate: Double
    private let mixer: ChannelMixer
    /// Samples of the open stretch seen so far, and their extremes.
    private var filled = 0
    private var low: Float = 0
    private var high: Float = 0
    /// Stretches completed since the last reset.
    private var completed = 0
    private var position = 0

    var latencyFrames: Int { 0 }
    let settlingFrames: Int

    init(bucket: Int, mixer: ChannelMixer, sampleRate: Double) throws(DSPError) {
        self.bucket = bucket
        self.mixer = mixer
        self.sampleRate = sampleRate
        settlingFrames = bucket
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, let minima = output.minima.baseAddress, let maxima = output.maxima.baseAddress else { return }
        let capacity = output.minima.count
        let total = block.frameCount
        let origin = position
        var pairs = 0
        var firstTime = input.time
        var done = 0
        while done < total {
            let count = min(total - done, mixer.chunk)
            let samples = mixer.sequence(of: block, from: done, count: count)
            var offset = 0
            while offset < count {
                let take = min(bucket - filled, count - offset)
                var least: Float = 0, greatest: Float = 0
                vDSP_minv(samples + offset, 1, &least, vDSP_Length(take))
                vDSP_maxv(samples + offset, 1, &greatest, vDSP_Length(take))
                if filled == 0 {
                    low = least
                    high = greatest
                } else {
                    if least < low { low = least }
                    if greatest > high { high = greatest }
                }
                filled += take
                offset += take
                if filled == bucket {
                    // A frame is sized for the stretches of the largest block the plan delivers;
                    // a longer block would still stay inside it.
                    // coverage:ignore(the plan never delivers a block above the size the frame was made for)
                    if pairs == capacity {
                        output.emit(count: pairs, time: firstTime)
                        pairs = 0
                    }
                    // A pair's time is the time of the first sample of its stretch.
                    if pairs == 0 { firstTime = input.time + Double(completed &* bucket - origin) / sampleRate }
                    minima[pairs] = low
                    maxima[pairs] = high
                    pairs += 1
                    completed &+= 1
                    filled = 0
                }
            }
            done += count
        }
        if pairs > 0 { output.emit(count: pairs, time: firstTime) }
        position &+= total
    }

    func reset() {
        filled = 0
        low = 0
        high = 0
        completed = 0
        position = 0
    }
}
