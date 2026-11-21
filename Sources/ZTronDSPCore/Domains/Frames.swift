/// One value with a confidence in `0 … 1` (§5.2).
///
/// A step that has no value for a frame (the centroid of silence, a pitch with no peak)
/// repeats its last value, or 0 before the first, with confidence 0. No step emits NaN.
/// Unlike the other frames this one is a plain value, because it is what a
/// `Binding<ScalarFrame>` holds; its index and time travel on the `FrameView` that carries it.
///
/// Usable on any thread, the analysis thread included; it does not allocate.
public struct ScalarFrame: Hashable, Sendable {
    /// The value.
    public let value: Float
    /// How sure the step is of the value, in `0 … 1`: 0 when it has none and repeats its last one.
    public let confidence: Float

    /// A value with its confidence, 1 unless told otherwise.
    @inlinable
    public init(value: Float, confidence: Float = 1) {
        self.value = value
        self.confidence = confidence
    }

    /// The frame before any value exists: 0 with confidence 0.
    public static let none = ScalarFrame(value: 0, confidence: 0)
}

/// A vector of real numbers: a real-valued spectrum, a cepstrum, chroma, lags, a tempogram
/// column. A borrowed view, valid for the call that delivers it; copy what must outlive it.
///
/// Usable on any thread for the length of that call, the analysis thread included; it does
/// not allocate.
public struct RealFrame {
    /// The values.
    public let values: UnsafeBufferPointer<Float>
    /// The frame's position in its stream, from 0.
    public let index: Int
    /// The time the frame describes, in seconds since the session started.
    public let time: Double

    /// A view of `values`: the frame at `index` in its stream, describing `time`.
    @inlinable
    public init(values: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.values = values
        self.index = index
        self.time = time
    }

    /// The number of values.
    @inlinable public var count: Int { values.count }
}

/// A vector of complex numbers in split form: a complex spectrum. A borrowed view, valid for
/// the call that delivers it.
///
/// Usable on any thread for the length of that call, the analysis thread included; it does
/// not allocate.
public struct ComplexFrame {
    /// The real parts.
    public let real: UnsafeBufferPointer<Float>
    /// The imaginary parts.
    public let imaginary: UnsafeBufferPointer<Float>
    /// The frame's position in its stream, from 0.
    public let index: Int
    /// The time the frame describes, in seconds since the session started.
    public let time: Double

    /// A view of the split parts: the frame at `index` in its stream, describing `time`.
    @inlinable
    public init(real: UnsafeBufferPointer<Float>, imaginary: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.real = real
        self.imaginary = imaginary
        self.index = index
        self.time = time
    }

    /// The number of bins.
    @inlinable public var count: Int { real.count }
}

/// (min, max) pairs of a waveform, one pair per reduction bucket. A borrowed view, valid for
/// the call that delivers it.
///
/// Usable on any thread for the length of that call, the analysis thread included; it does
/// not allocate.
public struct EnvelopeFrame {
    /// The smallest sample of each bucket.
    public let minima: UnsafeBufferPointer<Float>
    /// The largest sample of each bucket.
    public let maxima: UnsafeBufferPointer<Float>
    /// The frame's position in its stream, from 0.
    public let index: Int
    /// The time the frame describes, in seconds since the session started.
    public let time: Double

    /// A view of the pairs: the frame at `index` in its stream, describing `time`.
    @inlinable
    public init(minima: UnsafeBufferPointer<Float>, maxima: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.minima = minima
        self.maxima = maxima
        self.index = index
        self.time = time
    }

    /// The number of pairs.
    @inlinable public var count: Int { minima.count }
}

/// The shape of the frames a node writes: what the plan allocates its output storage for.
///
/// A value, usable on any thread; it does not allocate.
public enum FrameFormat: Hashable, Sendable {
    /// Blocks of audio: `channelCount` channels of at most `maximumFrames` frames.
    case samples(channelCount: Int, maximumFrames: Int)
    /// Real vectors of `count` values.
    case real(count: Int)
    /// Complex vectors of `count` bins.
    case complex(count: Int)
    /// One value with a confidence.
    case scalar
    /// Up to `maximumCount` (min, max) pairs.
    case envelope(maximumCount: Int)

    /// How a frame of this format is delivered.
    public var kind: DomainTag.FrameKind {
        switch self {
        case .samples: .samples
        case .real: .real
        case .complex: .complex
        case .scalar: .scalar
        case .envelope: .envelope
        }
    }
}

/// One frame travelling down a pipeline, whatever its domain: what an `AnalysisNode` and a
/// `FeatureSink` receive (§5.11.1).
///
/// A frame is a borrowed view, valid for the call that delivers it, with its index and its
/// time in seconds since the session started (§5.2). The typed accessors return `nil` when
/// the frame is of another kind. Reading a frame allocates nothing; it may be read on any
/// thread for the length of that call, the analysis thread included.
public struct FrameView {
    /// What the frame holds, which decides the accessor that returns it.
    public let kind: DomainTag.FrameKind
    /// The frame's position in its stream, from 0. For a block of samples: the index of its
    /// first sample.
    public let index: Int
    /// The time the frame describes, in seconds since the session started: for a block of
    /// samples, the time of its first sample; for a frame cut from the signal, the time of the
    /// point it is aligned to (its centre when the framing is centred, its end when causal).
    public let time: Double

    @usableFromInline let first: UnsafeMutableRawPointer?
    @usableFromInline let second: UnsafeMutableRawPointer?
    /// Frames of a block, values or bins of a vector, pairs of an envelope; 1 for a scalar.
    public let count: Int
    /// Channels of a block of samples; 1 otherwise.
    public let channelCount: Int
    @usableFromInline let capacity: Int
    @usableFromInline let scalarValue: ScalarFrame

    @inlinable
    init(kind: DomainTag.FrameKind, index: Int, time: Double, first: UnsafeMutableRawPointer?, second: UnsafeMutableRawPointer?,
         count: Int, channelCount: Int, capacity: Int, scalar: ScalarFrame) {
        self.kind = kind
        self.index = index
        self.time = time
        self.first = first
        self.second = second
        self.count = count
        self.channelCount = channelCount
        self.capacity = capacity
        self.scalarValue = scalar
    }

    /// A frame holding a block of samples.
    @inlinable
    public init(samples block: AudioBlock, index: Int, time: Double) {
        self.init(kind: .samples, index: index, time: time, first: UnsafeMutableRawPointer(mutating: block.channelTable),
                  second: nil, count: block.frameCount, channelCount: block.channelCount, capacity: block.capacity, scalar: .none)
    }

    /// A frame holding a real vector.
    @inlinable
    public init(real values: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.init(kind: .real, index: index, time: time, first: UnsafeMutableRawPointer(mutating: values.baseAddress),
                  second: nil, count: values.count, channelCount: 1, capacity: values.count, scalar: .none)
    }

    /// A frame holding a complex vector in split form.
    @inlinable
    public init(real: UnsafeBufferPointer<Float>, imaginary: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.init(kind: .complex, index: index, time: time, first: UnsafeMutableRawPointer(mutating: real.baseAddress),
                  second: UnsafeMutableRawPointer(mutating: imaginary.baseAddress), count: min(real.count, imaginary.count),
                  channelCount: 1, capacity: min(real.count, imaginary.count), scalar: .none)
    }

    /// A frame holding one value with a confidence.
    @inlinable
    public init(scalar: ScalarFrame, index: Int, time: Double) {
        self.init(kind: .scalar, index: index, time: time, first: nil, second: nil, count: 1, channelCount: 1, capacity: 1, scalar: scalar)
    }

    /// A frame holding (min, max) pairs.
    @inlinable
    public init(minima: UnsafeBufferPointer<Float>, maxima: UnsafeBufferPointer<Float>, index: Int, time: Double) {
        self.init(kind: .envelope, index: index, time: time, first: UnsafeMutableRawPointer(mutating: minima.baseAddress),
                  second: UnsafeMutableRawPointer(mutating: maxima.baseAddress), count: min(minima.count, maxima.count),
                  channelCount: 1, capacity: min(minima.count, maxima.count), scalar: .none)
    }

    /// The block of samples, when the frame holds one.
    @inlinable public var samples: AudioBlock? {
        guard kind == .samples, let first else { return nil }
        return AudioBlock(channels: UnsafePointer(first.assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)),
                          channelCount: channelCount, capacity: capacity, frameCount: count)
    }

    /// The real vector, when the frame holds one.
    @inlinable public var real: RealFrame? {
        guard kind == .real else { return nil }
        return RealFrame(values: UnsafeBufferPointer(start: first?.assumingMemoryBound(to: Float.self), count: count), index: index, time: time)
    }

    /// The complex vector, when the frame holds one.
    @inlinable public var complex: ComplexFrame? {
        guard kind == .complex else { return nil }
        return ComplexFrame(real: UnsafeBufferPointer(start: first?.assumingMemoryBound(to: Float.self), count: count),
                            imaginary: UnsafeBufferPointer(start: second?.assumingMemoryBound(to: Float.self), count: count),
                            index: index, time: time)
    }

    /// The value and confidence, when the frame holds a scalar.
    @inlinable public var scalar: ScalarFrame? {
        kind == .scalar ? scalarValue : nil
    }

    /// The (min, max) pairs, when the frame holds an envelope.
    @inlinable public var envelope: EnvelopeFrame? {
        guard kind == .envelope else { return nil }
        return EnvelopeFrame(minima: UnsafeBufferPointer(start: first?.assumingMemoryBound(to: Float.self), count: count),
                             maxima: UnsafeBufferPointer(start: second?.assumingMemoryBound(to: Float.self), count: count),
                             index: index, time: time)
    }
}
