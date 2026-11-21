import Foundation
import ZTronDSP

/// The mock signals of the gallery. Every example runs on one of them, never on the
/// microphone: a signal that is computed (`GeneratorSource`), one that is held in memory
/// (`BufferSource`), or one that follows a script (`ScriptedSource`).
///
/// Each function makes a new source. A source is something a screen keeps in `@State`, not
/// something made in a `body`.
enum MockSignals {
    static let sampleRate = 48_000.0

    // MARK: Computed

    /// A tone that climbs seven octaves from 80 Hz in six seconds and starts over, with its
    /// third harmonic above it.
    static func sweep() -> GeneratorSource {
        GeneratorSource(.function { _, time in
            let period = 6.0, lowest = 80.0, ratio = 128.0
            let elapsed = time.truncatingRemainder(dividingBy: period)
            // The phase of a sweep that is linear in the logarithm of its frequency.
            let phase = 2 * Double.pi * lowest * period / log(ratio) * (pow(ratio, elapsed / period) - 1)
            return Float(0.6 * sin(phase) + 0.2 * sin(3 * phase))
        }, sampleRate: sampleRate)
    }

    /// A broken C major chord, one note every 0.4 s, each with its octave: something for a
    /// chromagram to show.
    static func arpeggio() -> GeneratorSource {
        GeneratorSource(.function { _, time in
            let length = 0.4
            let index = Int(time / length)
            let elapsed = time - Double(index) * length
            let semitones: Double
            switch index % 6 {
            case 0: semitones = 0
            case 1: semitones = 4
            case 2: semitones = 7
            case 3: semitones = 12
            case 4: semitones = 7
            default: semitones = 4
            }
            let frequency = 261.625_565 * pow(2, semitones / 12)
            let envelope = min(elapsed / 0.01, 1) * exp(-3 * elapsed)
            let phase = 2 * Double.pi * frequency * elapsed
            return Float(envelope * (0.6 * sin(phase) + 0.3 * sin(2 * phase)))
        }, sampleRate: sampleRate)
    }

    /// A short beep twice a second, 120 beats per minute, every fourth one louder: something
    /// for a tempogram to show.
    static func clicks() -> GeneratorSource {
        GeneratorSource(.function { _, time in
            let beat = 0.5
            let index = Int(time / beat)
            let elapsed = time - Double(index) * beat
            let accent = index % 4 == 0 ? 1.0 : 0.6
            return Float(accent * exp(-40 * elapsed) * sin(2 * Double.pi * 880 * elapsed))
        }, sampleRate: sampleRate)
    }

    /// White noise at half of full scale: every frequency at once, for a filter to shape.
    static func noise() -> GeneratorSource {
        GeneratorSource(.whiteNoise(amplitude: 0.5, seed: 7), sampleRate: sampleRate)
    }

    // MARK: Held in memory

    /// Four seconds of a tone that wanders between 200 Hz and 1 kHz while it swells and
    /// fades, played in a loop at the sample rate.
    static func phrase() -> BufferSource {
        let count = Int(4 * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0 ..< count {
            let time = Double(index) / sampleRate
            let frequency = 600 + 400 * sin(2 * Double.pi * 0.5 * time)
            phase += 2 * Double.pi * frequency / sampleRate
            let swell = 0.5 - 0.5 * cos(2 * Double.pi * time / 4)
            samples[index] = Float(swell * (0.7 * sin(phase) + 0.2 * sin(2 * phase)))
        }
        return BufferSource(samples, sampleRate: sampleRate, pacing: .realTime, loops: true)
    }

    // MARK: Scripted

    /// Three seconds of decaying bursts, delivered in batches of uneven sizes as fast as they
    /// are processed, and then the stream ends: what a still overview of a recording is made
    /// from.
    static func recording() -> ScriptedSource {
        let count = Int(3 * sampleRate)
        let samples = (0 ..< count).map { index -> Float in
            let time = Double(index) / sampleRate
            let elapsed = time.truncatingRemainder(dividingBy: 0.75)
            return Float(exp(-6 * elapsed) * sin(2 * Double.pi * 330 * time))
        }
        return ScriptedSource(samples, sampleRate: sampleRate, batchSizes: [480, 1_024, 333])
    }
}
