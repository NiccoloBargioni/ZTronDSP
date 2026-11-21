import Foundation

/// A source that delivers samples the caller holds (§4.4): a recording already in memory, the
/// output of another computation, a fixture in a test.
///
/// Threading: the samples are copied when the source is created and never change; creating
/// one allocates that copy. `render` runs on the thread the engine paces the source on and
/// does not allocate; `prepare` runs on the control context while the source is not running,
/// and starts the samples over.
public final class BufferSource: PullSampleSource, @unchecked Sendable {
    /// How the engine paces the source: `.asFastAsPossible` unless told otherwise.
    public let pacing: Pacing
    /// The sample rate and the channel count of the samples.
    public let format: SignalFormat
    /// The source's events; a buffer source sends none.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    private let channels: [ContiguousArray<Float>]
    private let frameCount: Int
    private let loops: Bool
    private let channel = SourceEventChannel()
    private var position = 0

    /// A source of one channel.
    ///
    /// - Parameters:
    ///   - samples: the samples, copied.
    ///   - sampleRate: their sample rate, in hertz.
    ///   - pacing: `.asFastAsPossible`, the default, hands the samples over as fast as they are
    ///     processed; `.realTime` plays them at the sample rate.
    ///   - loops: start over at the end instead of ending.
    public convenience init(_ samples: [Float], sampleRate: Double, pacing: Pacing = .asFastAsPossible, loops: Bool = false) {
        self.init(channels: [samples], sampleRate: sampleRate, pacing: pacing, loops: loops)
    }

    /// A source of several channels, one array per channel, all of one length.
    public init(channels: [[Float]], sampleRate: Double, pacing: Pacing = .asFastAsPossible, loops: Bool = false) {
        self.channels = channels.map { ContiguousArray($0) }
        self.frameCount = channels.map(\.count).min() ?? 0
        self.format = SignalFormat(sampleRate: sampleRate, channelCount: channels.count)
        self.pacing = pacing
        self.loops = loops
    }

    /// Checks the format and the lengths of the channels, and starts the samples over. Control
    /// context.
    public func prepare() async throws(DSPError) {
        guard format.isValid else {
            throw .invalidParameter(stage: .none, parameter: "samples", reason: "\(format) is not a signal format")
        }
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            throw .invalidParameter(stage: .none, parameter: "channels", reason: "the channels of a buffer are of one length")
        }
        position = 0
    }

    /// Does nothing: the engine's requests drive the source.
    public func start() throws(DSPError) {}

    /// Does nothing.
    public func stop() {}

    /// Copies the next frames, as many as fit; at the end it starts over when the source loops
    /// and returns 0 otherwise. Does not allocate.
    public func render(into block: inout AudioBlock) -> Int {
        if position >= frameCount, loops { position = 0 }
        let frames = min(block.capacity, frameCount - position)
        guard frames > 0 else {
            block.setFrameCount(0)
            return 0
        }
        var index = 0
        while index < block.channelCount, index < channels.count {
            let target = block.channel(index)
            channels[index].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                memcpy(target, base + position, frames * MemoryLayout<Float>.stride)
            }
            index += 1
        }
        position += frames
        block.setFrameCount(frames)
        return frames
    }
}
