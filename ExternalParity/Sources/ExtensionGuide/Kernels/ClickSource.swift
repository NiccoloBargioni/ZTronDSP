import Foundation
import ZTronDSP

// The extension guide, row 6 of §5.11.1: a source (Docs/ExtensionGuide.md).

// snippet:begin click-source
/// A metronome: one channel of clicks at a tempo, for a time. A source clocked by the engine.
///
/// Threading: `prepare`, `start` and `stop` run on the control context, one at a time, while
/// the source does not render. `render` runs on the thread the engine paces the source on and
/// is bound by RT-2: memory and arithmetic only. `position` is touched by `prepare` and by
/// `render`, never at the same time: that is why the class may say `@unchecked Sendable`.
public final class ClickSource: PullSampleSource, @unchecked Sendable {
    public let format: SignalFormat
    /// `.realTime`: one block per block duration; `.asFastAsPossible`: as fast as it is processed.
    public let pacing: Pacing
    public var events: AsyncStream<SourceEvent> { channel.stream }

    private let channel = SourceEventChannel()
    private let period: Int
    private let clickFrames: Int
    private let frameCount: Int
    private var position = 0

    /// - Parameters:
    ///   - beatsPerMinute: the tempo of the clicks.
    ///   - duration: how long the source delivers, in seconds.
    ///
    /// Any thread.
    public init(beatsPerMinute: Double, sampleRate: Double = 48_000, duration: TimeInterval, pacing: Pacing = .realTime) {
        format = SignalFormat(sampleRate: sampleRate)
        self.pacing = pacing
        let framesPerBeat = beatsPerMinute > 0 && sampleRate > 0 ? 60 * sampleRate / beatsPerMinute : 0
        period = framesPerBeat >= 1 && framesPerBeat < 1e9 ? Int(framesPerBeat.rounded()) : 0
        clickFrames = max(min(Int((0.005 * sampleRate).rounded()), period / 2), 1)
        let total = duration * sampleRate
        frameCount = total.isFinite && total > 0 && total < 1e12 ? Int(total.rounded()) : 0
    }

    /// Checks what the source was given and starts the clicks over. Control context.
    public func prepare() async throws(DSPError) {
        guard format.isValid, period >= 1 else {
            throw .sourceUnavailable(reason: "a metronome needs a positive tempo and a sample rate, not \(period) frames per beat at \(format)")
        }
        position = 0
    }

    /// Nothing to start: the engine asks for blocks. Control context.
    public func start() throws(DSPError) {}

    /// Nothing to stop. Control context.
    public func stop() {}

    /// Fills `block`, says how many frames it wrote, and returns that number; 0 ends the stream.
    public func render(into block: inout AudioBlock) -> Int {
        let frames = min(block.capacity, frameCount - position)
        guard frames > 0, block.channelCount >= 1 else {
            block.setFrameCount(0)
            return 0
        }
        let samples = block.channel(0)
        var frame = 0
        while frame < frames {
            let phase = (position &+ frame) % period
            // A click falls from 1 to 0 over 5 ms.
            samples[frame] = phase < clickFrames ? 1 - Float(phase) / Float(clickFrames) : 0
            frame &+= 1
        }
        position &+= frames
        block.setFrameCount(frames)
        return frames
    }
}
// snippet:end click-source
