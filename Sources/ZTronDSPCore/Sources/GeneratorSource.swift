import Foundation

/// A source that computes its samples: a sine, a chirp, noise, an impulse, a step, silence or a
/// function of the sample index (§4.4). It stands in for a microphone in previews and tests,
/// and it is seeded and deterministic: the same generator gives the same samples on every
/// run, whatever the block size.
///
/// ```swift
/// let mock = try await engine.attach(analysis, to: GeneratorSource(.sine(frequency: .hertz(440))))
/// ```
///
/// Threading: `render` runs on the thread the engine paces the source on and does not
/// allocate; `prepare` runs on the control context while the source is not running, and
/// starts the signal over. Creating a generator allocates its state.
public final class GeneratorSource: PullSampleSource, @unchecked Sendable {
    /// What a generator computes. Every signal is the same on all channels, except noise,
    /// which is independent per channel.
    ///
    /// A value, usable on any thread; making one may allocate (a mel frequency, a closure).
    public struct Signal: Sendable {
        enum Kind: Sendable {
            case sine(frequency: Frequency, amplitude: Float, phase: Double)
            case chirp(from: Frequency, to: Frequency, duration: TimeInterval, amplitude: Float, logarithmic: Bool)
            case whiteNoise(amplitude: Float, seed: UInt64)
            case pinkNoise(amplitude: Float, seed: UInt64)
            case impulse(amplitude: Float, frame: Int, period: Int?)
            case step(amplitude: Float, frame: Int)
            case silence
            case function(@Sendable (_ frame: Int, _ time: Double) -> Float)
        }

        let kind: Kind

        /// `amplitude · sin(2π·frequency·t + phase)`.
        public static func sine(frequency: Frequency, amplitude: Float = 1, phase: Double = 0) -> Signal {
            Signal(kind: .sine(frequency: frequency, amplitude: amplitude, phase: phase))
        }

        /// A sweep from one frequency to another over `duration`, linear in hertz; after it the
        /// signal stays at the end frequency, with its phase unbroken.
        public static func chirp(from start: Frequency, to end: Frequency, duration: TimeInterval, amplitude: Float = 1) -> Signal {
            Signal(kind: .chirp(from: start, to: end, duration: duration, amplitude: amplitude, logarithmic: false))
        }

        /// A sweep that covers equal musical intervals in equal times: linear in the logarithm
        /// of the frequency. Both ends must be above 0 Hz.
        public static func logarithmicChirp(from start: Frequency, to end: Frequency, duration: TimeInterval, amplitude: Float = 1) -> Signal {
            Signal(kind: .chirp(from: start, to: end, duration: duration, amplitude: amplitude, logarithmic: true))
        }

        /// Uniform white noise in `−amplitude ..< amplitude`.
        public static func whiteNoise(amplitude: Float = 1, seed: UInt64 = 0) -> Signal {
            Signal(kind: .whiteNoise(amplitude: amplitude, seed: seed))
        }

        /// Pink noise: power falling by 3 dB per octave. `amplitude` scales a signal whose
        /// samples stay within about ±1.
        public static func pinkNoise(amplitude: Float = 1, seed: UInt64 = 0) -> Signal {
            Signal(kind: .pinkNoise(amplitude: amplitude, seed: seed))
        }

        /// One sample of `amplitude` at `frame`, zeros elsewhere.
        public static func impulse(amplitude: Float = 1, at frame: Int = 0) -> Signal {
            Signal(kind: .impulse(amplitude: amplitude, frame: frame, period: nil))
        }

        /// One sample of `amplitude` every `period` frames, the first at frame 0.
        public static func impulseTrain(period: Int, amplitude: Float = 1) -> Signal {
            Signal(kind: .impulse(amplitude: amplitude, frame: 0, period: period))
        }

        /// Zeros before `frame`, `amplitude` from it on.
        public static func step(amplitude: Float = 1, at frame: Int = 0) -> Signal {
            Signal(kind: .step(amplitude: amplitude, frame: frame))
        }

        /// Zeros.
        public static var silence: Signal { Signal(kind: .silence) }

        /// Any signal, as a function of the sample's index and of its time in seconds. The
        /// closure runs once per sample on the thread that renders, so it is bound by RT-2:
        /// memory and arithmetic only.
        public static func function(_ value: @escaping @Sendable (_ frame: Int, _ time: Double) -> Float) -> Signal {
            Signal(kind: .function(value))
        }
    }

    /// How the engine paces the generator: `.realTime` unless told otherwise.
    public let pacing: Pacing
    /// The sample rate and the channel count the generator was made with.
    public let format: SignalFormat
    /// The source's events; a generator sends none.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    private let signal: Signal
    private let duration: TimeInterval?
    private let channel = SourceEventChannel()

    // What `prepare` resolves, and what `render` advances.
    private var resolved: Resolved = .silence
    private var frameLimit = Int.max
    private var position = 0
    /// Per channel: one word of generator state, then seven words of pink-filter state.
    private let noise: UnsafeMutablePointer<Double>
    private let seeds: UnsafeMutablePointer<UInt64>

    private enum Resolved {
        case sine(step: Double, amplitude: Double, phase: Double)
        case chirp(start: Double, end: Double, frames: Double, amplitude: Double, logarithmic: Bool)
        case whiteNoise(amplitude: Float, seed: UInt64)
        case pinkNoise(amplitude: Float, seed: UInt64)
        case impulse(amplitude: Float, frame: Int, period: Int)
        case step(amplitude: Float, frame: Int)
        case silence
        case function(@Sendable (Int, Double) -> Float)
    }

    /// A generator of `signal`.
    ///
    /// - Parameters:
    ///   - signal: what the generator computes.
    ///   - sampleRate: samples per second, 48 kHz unless told otherwise.
    ///   - channelCount: the channels, all alike except for noise; one unless told otherwise.
    ///   - duration: how long the signal lasts; `nil` for a signal without an end.
    ///   - pacing: `.realTime` behaves like a microphone; `.asFastAsPossible` is for analysis
    ///     and tests, and wants a `duration`.
    public init(
        _ signal: Signal, sampleRate: Double = 48_000, channelCount: Int = 1, duration: TimeInterval? = nil,
        pacing: Pacing = .realTime
    ) {
        self.signal = signal
        self.format = SignalFormat(sampleRate: sampleRate, channelCount: channelCount)
        self.duration = duration
        self.pacing = pacing
        // The state is sized for a format that can exist; `prepare()` refuses one that cannot.
        let channels = min(max(channelCount, 1), GeneratorSource.maximumChannelCount)
        noise = .allocate(capacity: channels * 7)
        noise.initialize(repeating: 0, count: channels * 7)
        seeds = .allocate(capacity: channels)
        seeds.initialize(repeating: 0, count: channels)
    }

    deinit {
        noise.deallocate()
        seeds.deallocate()
    }

    /// The most channels a generator delivers.
    public static let maximumChannelCount = 1_024

    /// Checks the format, the duration and the signal's parameters, resolves its frequencies
    /// against the sample rate, and starts the signal over. Control context.
    public func prepare() async throws(DSPError) {
        guard format.isValid, format.channelCount <= GeneratorSource.maximumChannelCount, format.sampleRate <= 1e9 else {
            throw .invalidParameter(stage: .none, parameter: "format", reason: "\(format) is not a signal format a generator can deliver")
        }
        if let duration {
            guard duration.isFinite, duration >= 0 else {
                throw .invalidParameter(stage: .none, parameter: "duration", reason: "a duration is finite and not negative, not \(duration)")
            }
            // A duration beyond what a frame count can hold is a signal without an end.
            let frames = (duration * format.sampleRate).rounded()
            frameLimit = frames < 9.0e18 ? Int(frames) : .max
        } else {
            frameLimit = .max
        }
        let rate = format.sampleRate
        switch signal.kind {
        case .sine(let frequency, let amplitude, let phase):
            let hertz = try GeneratorSource.audible(frequency, rate)
            resolved = .sine(step: 2 * .pi * hertz / rate, amplitude: Double(amplitude), phase: phase)
        case .chirp(let from, let to, let length, let amplitude, let logarithmic):
            let start = try GeneratorSource.audible(from, rate), end = try GeneratorSource.audible(to, rate)
            guard length.isFinite, length > 0 else {
                throw .invalidParameter(stage: .none, parameter: "duration", reason: "a chirp lasts a positive, finite time, not \(length)")
            }
            guard !logarithmic || (start > 0 && end > 0) else {
                throw .invalidParameter(stage: .none, parameter: "frequency", reason: "a logarithmic chirp cannot start or end at 0 Hz")
            }
            resolved = .chirp(start: start, end: end, frames: max(length * rate, 1), amplitude: Double(amplitude), logarithmic: logarithmic)
        case .whiteNoise(let amplitude, let seed):
            resolved = .whiteNoise(amplitude: amplitude, seed: seed)
        case .pinkNoise(let amplitude, let seed):
            resolved = .pinkNoise(amplitude: amplitude, seed: seed)
        case .impulse(let amplitude, let frame, let period):
            if let period, period < 1 {
                throw .invalidParameter(stage: .none, parameter: "period", reason: "an impulse train repeats every 1 or more frames, not \(period)")
            }
            resolved = .impulse(amplitude: amplitude, frame: frame, period: period ?? 0)
        case .step(let amplitude, let frame):
            resolved = .step(amplitude: amplitude, frame: frame)
        case .silence:
            resolved = .silence
        case .function(let value):
            resolved = .function(value)
        }
        rewind()
    }

    private static func audible(_ frequency: Frequency, _ rate: Double) throws(DSPError) -> Double {
        let hertz = try frequency.hertz(sampleRate: rate)
        guard hertz <= rate / 2 else {
            throw .invalidParameter(
                stage: .none, parameter: "frequency",
                reason: "\(frequency) is above the Nyquist frequency \(rate / 2) Hz and would alias")
        }
        return hertz
    }

    private func rewind() {
        position = 0
        var channel = 0
        while channel < format.channelCount {
            var filter = 0
            while filter < 7 {
                noise[channel * 7 + filter] = 0
                filter += 1
            }
            channel += 1
        }
        let seed: UInt64 = switch resolved {
        case .whiteNoise(_, let seed), .pinkNoise(_, let seed): seed
        default: 0
        }
        channel = 0
        while channel < format.channelCount {
            // Every channel draws from its own stream.
            seeds[channel] = seed &+ UInt64(channel) &* 0xD6E8_FEB8_6659_FD93
            channel += 1
        }
    }

    /// Does nothing: the engine's requests drive the generator.
    public func start() throws(DSPError) {}

    /// Does nothing.
    public func stop() {}

    /// Computes the next frames, as many as fit, until the duration is reached. Does not
    /// allocate; the closure of a `.function` signal is bound by RT-2.
    public func render(into block: inout AudioBlock) -> Int {
        let frames = min(block.capacity, frameLimit - position)
        guard frames > 0 else {
            block.setFrameCount(0)
            return 0
        }
        let rate = format.sampleRate
        let first = block.channel(0)
        var independent = false

        switch resolved {
        case .sine(let step, let amplitude, let phase):
            var index = 0
            while index < frames {
                first[index] = Float(amplitude * sin(step * Double(position + index) + phase))
                index += 1
            }
        case .chirp(let start, let end, let length, let amplitude, let logarithmic):
            var index = 0
            while index < frames {
                let n = Double(position + index)
                let phase: Double
                if n >= length {
                    let atEnd = logarithmic && end != start
                        ? 2 * Double.pi * start * (length / rate) / log(end / start) * (end / start - 1)
                        : 2 * Double.pi * (start * length / rate + (end - start) * length / (2 * rate))
                    phase = atEnd + 2 * .pi * end * (n - length) / rate
                } else if logarithmic {
                    let ratio = end / start
                    phase = ratio == 1
                        ? 2 * .pi * start * n / rate
                        : 2 * .pi * start * (length / rate) / log(ratio) * (pow(ratio, n / length) - 1)
                } else {
                    phase = 2 * .pi * (start * n / rate + (end - start) * n * n / (2 * length * rate))
                }
                first[index] = Float(amplitude * sin(phase))
                index += 1
            }
        case .whiteNoise(let amplitude, _):
            independent = true
            var channel = 0
            while channel < block.channelCount {
                let samples = block.channel(channel)
                var state = seeds[channel]
                var index = 0
                while index < frames {
                    samples[index] = amplitude * GeneratorSource.uniform(&state)
                    index += 1
                }
                seeds[channel] = state
                channel += 1
            }
        case .pinkNoise(let amplitude, _):
            independent = true
            var channel = 0
            while channel < block.channelCount {
                let samples = block.channel(channel)
                let filter = noise + channel * 7
                var state = seeds[channel]
                var index = 0
                while index < frames {
                    // Paul Kellet's refinement of the Voss–McCartney method: six one-pole filters
                    // whose sum falls by 3 dB per octave to within ±0.05 dB above 10 Hz.
                    let white = Double(GeneratorSource.uniform(&state))
                    filter[0] = 0.99886 * filter[0] + white * 0.0555179
                    filter[1] = 0.99332 * filter[1] + white * 0.0750759
                    filter[2] = 0.96900 * filter[2] + white * 0.1538520
                    filter[3] = 0.86650 * filter[3] + white * 0.3104856
                    filter[4] = 0.55000 * filter[4] + white * 0.5329522
                    filter[5] = -0.7616 * filter[5] - white * 0.0168980
                    let pink = filter[0] + filter[1] + filter[2] + filter[3] + filter[4] + filter[5] + filter[6] + white * 0.5362
                    filter[6] = white * 0.115926
                    samples[index] = amplitude * Float(pink * 0.11)
                    index += 1
                }
                seeds[channel] = state
                channel += 1
            }
        case .impulse(let amplitude, let frame, let period):
            var index = 0
            while index < frames {
                let n = position + index
                let hit = period > 0 ? n % period == 0 : n == frame
                first[index] = hit ? amplitude : 0
                index += 1
            }
        case .step(let amplitude, let frame):
            var index = 0
            while index < frames {
                first[index] = position + index >= frame ? amplitude : 0
                index += 1
            }
        case .silence:
            memset(first, 0, frames * MemoryLayout<Float>.stride)
        case .function(let value):
            var index = 0
            while index < frames {
                let n = position + index
                first[index] = value(n, Double(n) / rate)
                index += 1
            }
        }

        if !independent {
            var channel = 1
            while channel < block.channelCount {
                memcpy(block.channel(channel), first, frames * MemoryLayout<Float>.stride)
                channel += 1
            }
        }
        position += frames
        block.setFrameCount(frames)
        return frames
    }

    /// The next value of a SplitMix64 stream, as a uniform sample in `−1 ..< 1`.
    @inline(__always)
    private static func uniform(_ state: inout UInt64) -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        // 24 random bits make a Float in 0 ..< 1 exactly.
        return Float(z >> 40) * 0x1.0p-23 - 1
    }
}
