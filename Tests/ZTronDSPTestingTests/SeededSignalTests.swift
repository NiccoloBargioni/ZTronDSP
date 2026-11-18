import Foundation
import Testing
import ZTronDSPTesting

@Suite("Seeded signals")
struct SeededSignalTests {
    @Test func theGeneratorIsDeterministicAndSeedDependent() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        var other = SeededGenerator(seed: 43)
        let a = (0 ..< 64).map { _ in first.next() }
        let b = (0 ..< 64).map { _ in second.next() }
        let c = (0 ..< 64).map { _ in other.next() }
        #expect(a == b)
        #expect(a != c)
        // SplitMix64, seed 0: the published first outputs.
        var reference = SeededGenerator(seed: 0)
        #expect(reference.next() == 0xE220_A839_7B1D_CDAF)
        #expect(reference.next() == 0x6E78_9E6A_A1B9_65F4)
    }

    @Test func unitValuesStayInRangeAndGaussiansHaveUnitVariance() {
        var generator = SeededGenerator(seed: 7)
        var sum = 0.0, sumOfSquares = 0.0
        for _ in 0 ..< 20_000 {
            let unit = generator.nextUnit()
            #expect(unit >= 0 && unit < 1)
            let gaussian = generator.nextGaussian()
            sum += gaussian
            sumOfSquares += gaussian * gaussian
        }
        let mean = sum / 20_000
        let variance = sumOfSquares / 20_000 - mean * mean
        #expect(abs(mean) < 0.03)
        #expect(abs(variance - 1) < 0.05)
    }

    @Test func sineMatchesItsDefinition() {
        let signal = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 96, amplitude: 0.5, phase: 0.25)
        for n in 0 ..< 96 {
            let expected = Float(0.5 * sin(2 * .pi * 1_000 * Double(n) / 48_000 + 0.25))
            #expect(signal[n] == expected)
        }
        // 48 samples are one period: the signal repeats.
        expectClose(Array(signal[48...]), Array(signal[..<48]), .absolute(1e-6))
    }

    @Test func noiseIsSeededAndBounded() {
        let first = TestSignal.whiteNoise(count: 4_096, seed: 1, amplitude: 0.25)
        #expect(first == TestSignal.whiteNoise(count: 4_096, seed: 1, amplitude: 0.25))
        #expect(first != TestSignal.whiteNoise(count: 4_096, seed: 2, amplitude: 0.25))
        #expect(first.allSatisfy { abs($0) <= 0.25 })
        let mean = first.reduce(0, +) / Float(first.count)
        #expect(abs(mean) < 0.01)
    }

    @Test func shapesAreExact() {
        #expect(TestSignal.impulse(count: 5, at: 2, amplitude: 3) == [0, 0, 3, 0, 0])
        #expect(TestSignal.impulse(count: 3, at: 9) == [0, 0, 0])
        #expect(TestSignal.step(count: 5, at: 3) == [0, 0, 0, 1, 1])
        #expect(TestSignal.silence(count: 4) == [0, 0, 0, 0])
        #expect(TestSignal.nyquist(count: 4, amplitude: 0.5) == [0.5, -0.5, 0.5, -0.5])
        #expect(TestSignal.constant(2, count: 2) == [2, 2])
        #expect(TestSignal.sum([1, 2, 3], [10, 20, 30], [100, 200, 300]) == [111, 222, 333])
        #expect(TestSignal.sum().isEmpty)
        #expect(TestSignal.chirp(from: 100, to: 200, sampleRate: 48_000, count: 0).isEmpty)
    }

    @Test func chirpSweepsItsInstantaneousFrequency() {
        // The zero-crossing rate at the end is twice that at the start for a one-octave sweep.
        let signal = TestSignal.chirp(from: 500, to: 1_000, sampleRate: 48_000, count: 48_000)
        func crossings(_ range: Range<Int>) -> Int {
            var count = 0
            for n in range.dropFirst() where (signal[n - 1] < 0) != (signal[n] < 0) { count += 1 }
            return count
        }
        let head = crossings(0 ..< 4_800)
        let tail = crossings(43_200 ..< 48_000)
        #expect(Double(tail) / Double(head) > 1.7)
        #expect(Double(tail) / Double(head) < 2.0)
    }

    @Test func clickTrackPlacesOneClickPerBeat() {
        let sampleRate = 48_000.0
        let signal = TestSignal.clickTrack(beatsPerMinute: 120, sampleRate: sampleRate, count: 96_000)
        // 120 BPM is one click every 24 000 samples: four clicks in two seconds.
        for beat in 0 ..< 4 {
            let start = beat * 24_000
            let energy = signal[start ..< start + 256].reduce(Float(0)) { $0 + $1 * $1 }
            #expect(energy > 1)
            let quiet = signal[start + 1_000 ..< start + 23_000].reduce(Float(0)) { $0 + $1 * $1 }
            #expect(quiet == 0)
        }
    }

    @Test func harmonicToneSumsItsPartials() {
        let tone = TestSignal.harmonic(fundamental: 100, amplitudes: [1, 0.5], sampleRate: 8_000, count: 80)
        let first = TestSignal.sine(frequency: 100, sampleRate: 8_000, count: 80)
        let second = TestSignal.sine(frequency: 200, sampleRate: 8_000, count: 80, amplitude: 0.5)
        expectClose(tone, TestSignal.sum(first, second), .absolute(1e-6))
    }

    @Test func decayingTailReachesZero() {
        let tail = TestSignal.decayingTail(count: 200, ratio: 0.5)
        #expect(tail[0] == 1)
        #expect(tail[10] == 0x1p-10)
        #expect(tail[199] == 0)
        #expect(tail.contains { $0 != 0 && $0.isSubnormal })
    }
}
