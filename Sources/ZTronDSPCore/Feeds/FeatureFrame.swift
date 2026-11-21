/// A frame a consumer may keep: an owned copy of what a `FrameView` showed for the length of
/// one call (§5.2). It is what a `FeatureStream` delivers.
///
/// An immutable value, usable on any thread. Creating one copies the frame and allocates, so
/// it is not for the analysis thread.
public struct FeatureFrame: Sendable, Hashable {
    /// How the frame is laid out.
    public let kind: DomainTag.FrameKind
    /// The frame's position in its stream, from 0.
    public let index: Int
    /// The time the frame describes, in seconds since the session started.
    public let time: Double
    /// The values of a real vector; the real parts of a complex vector; the minima of an
    /// envelope; the samples of a block, one channel after another. Empty for a scalar.
    public let values: [Float]
    /// The imaginary parts of a complex vector; the maxima of an envelope. Empty otherwise.
    public let secondary: [Float]
    /// The value and confidence of a scalar frame; `.none` otherwise.
    public let scalar: ScalarFrame
    /// Channels of a block of samples; 1 otherwise.
    public let channelCount: Int

    /// A frame from its parts, as ``init(_:)`` makes it from a view; the values are the caller's
    /// arrays.
    public init(kind: DomainTag.FrameKind, index: Int, time: Double, values: [Float] = [], secondary: [Float] = [],
                scalar: ScalarFrame = .none, channelCount: Int = 1) {
        self.kind = kind
        self.index = index
        self.time = time
        self.values = values
        self.secondary = secondary
        self.scalar = scalar
        self.channelCount = channelCount
    }

    /// A copy of `frame`.
    public init(_ frame: FrameView) {
        var values: [Float] = [], secondary: [Float] = []
        var channels = 1
        if let real = frame.real {
            values = Array(real.values)
        } else if let complex = frame.complex {
            values = Array(complex.real)
            secondary = Array(complex.imaginary)
        } else if let envelope = frame.envelope {
            values = Array(envelope.minima)
            secondary = Array(envelope.maxima)
        } else if let block = frame.samples {
            channels = block.channelCount
            values.reserveCapacity(block.channelCount * block.frameCount)
            for channel in 0 ..< block.channelCount { values.append(contentsOf: block.samples(ofChannel: channel)) }
        }
        self.init(kind: frame.kind, index: frame.index, time: frame.time, values: values, secondary: secondary,
                  scalar: frame.scalar ?? .none, channelCount: channels)
    }

    /// Frames of a block, values or bins of a vector, pairs of an envelope; 1 for a scalar.
    public var count: Int {
        kind == .scalar ? 1 : (channelCount > 0 ? values.count / channelCount : values.count)
    }

    /// The samples of one channel of a block. Empty for another kind of frame or a channel
    /// that does not exist.
    public func samples(ofChannel channel: Int) -> ArraySlice<Float> {
        guard kind == .samples, channel >= 0, channel < channelCount else { return [] }
        let frames = count
        return values[(channel * frames) ..< ((channel + 1) * frames)]
    }
}
