import Foundation

/// A small, fast, reproducible random number generator (SplitMix64). Tests are seeded and
/// deterministic: the same seed gives the same signal on every run and every machine.
///
/// A value, usable on any thread, where each copy draws a sequence of its own; it does not
/// allocate.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    @usableFromInline var state: UInt64

    /// A generator whose sequence is fixed by `seed`.
    public init(seed: UInt64) {
        state = seed
    }

    /// The next 64 bits of the sequence: one SplitMix64 step.
    @inlinable
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `0 ..< 1` with 53 random bits.
    @inlinable
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// A standard normal value (Box–Muller).
    public mutating func nextGaussian() -> Double {
        var u = nextUnit()
        while u <= .leastNonzeroMagnitude { u = nextUnit() }
        let v = nextUnit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Deterministic test signals. Every function returns a new array of `Float` samples.
///
/// Plain functions, usable on any thread; each allocates the samples it returns.
public enum TestSignal {
    /// `amplitude · sin(2π·frequency·n / sampleRate + phase)`.
    public static func sine(
        frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 1, phase: Double = 0
    ) -> [Float] {
        let step = 2 * Double.pi * frequency / sampleRate
        return (0 ..< count).map { Float(amplitude * sin(step * Double($0) + phase)) }
    }

    /// A sum of sines at whole multiples of `fundamental`; partial `k` has amplitude
    /// `amplitudes[k − 1]`.
    public static func harmonic(
        fundamental: Double, amplitudes: [Double], sampleRate: Double, count: Int
    ) -> [Float] {
        var result = [Double](repeating: 0, count: count)
        for (k, amplitude) in amplitudes.enumerated() {
            let step = 2 * Double.pi * fundamental * Double(k + 1) / sampleRate
            for n in 0 ..< count { result[n] += amplitude * sin(step * Double(n)) }
        }
        return result.map(Float.init)
    }

    /// A linear sweep from `start` to `end` hertz across the whole signal.
    public static func chirp(
        from start: Double, to end: Double, sampleRate: Double, count: Int, amplitude: Double = 1
    ) -> [Float] {
        guard count > 0 else { return [] }
        let duration = Double(count) / sampleRate
        let rate = (end - start) / duration
        return (0 ..< count).map {
            let t = Double($0) / sampleRate
            return Float(amplitude * sin(2 * .pi * (start * t + 0.5 * rate * t * t)))
        }
    }

    /// Uniform white noise in `−amplitude … amplitude`.
    public static func whiteNoise(count: Int, seed: UInt64, amplitude: Double = 1) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count).map { _ in Float(amplitude * (2 * generator.nextUnit() - 1)) }
    }

    /// Gaussian white noise with the given standard deviation.
    public static func gaussianNoise(count: Int, seed: UInt64, standardDeviation: Double = 1) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count).map { _ in Float(standardDeviation * generator.nextGaussian()) }
    }

    /// Zeros with a single sample of `amplitude` at `position`.
    public static func impulse(count: Int, at position: Int = 0, amplitude: Float = 1) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        if position >= 0 && position < count { result[position] = amplitude }
        return result
    }

    /// Zeros before `position`, `amplitude` from it on.
    public static func step(count: Int, at position: Int = 0, amplitude: Float = 1) -> [Float] {
        (0 ..< count).map { $0 >= position ? amplitude : 0 }
    }

    /// Digital silence.
    public static func silence(count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    /// A constant.
    public static func constant(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    /// The fastest signal a sample rate can carry: `+amplitude, −amplitude, …`.
    public static func nyquist(count: Int, amplitude: Float = 1) -> [Float] {
        (0 ..< count).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    /// One short decaying burst per beat, for tempo fixtures. A click is `clickLength` samples
    /// of a 1 kHz sine under an exponential envelope.
    public static func clickTrack(
        beatsPerMinute: Double, sampleRate: Double, count: Int, clickLength: Int = 256, amplitude: Double = 1
    ) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let period = 60 * sampleRate / beatsPerMinute
        var beat = 0
        while true {
            let start = Int((Double(beat) * period).rounded())
            if start >= count { break }
            for n in 0 ..< clickLength where start + n < count {
                let envelope = exp(-6 * Double(n) / Double(clickLength))
                result[start + n] += Float(amplitude * envelope * sin(2 * .pi * 1_000 * Double(n) / sampleRate))
            }
            beat += 1
        }
        return result
    }

    /// `amplitude · ratioⁿ`: a tail that decays into the denormal range and below, for the
    /// state-hygiene tests (RT-6).
    public static func decayingTail(count: Int, ratio: Float, amplitude: Float = 1) -> [Float] {
        var value = amplitude
        return (0 ..< count).map { _ in defer { value *= ratio }; return value }
    }

    /// The element-wise sum of signals of equal length.
    public static func sum(_ signals: [Float]...) -> [Float] {
        guard let first = signals.first else { return [] }
        var result = first
        for signal in signals.dropFirst() {
            for n in 0 ..< min(result.count, signal.count) { result[n] += signal[n] }
        }
        return result
    }
}
