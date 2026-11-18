import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The constant-Q geometry (WP-517): the frequencies and the atom lengths of §6.8, with
/// tuning.
@Suite("Constant-Q geometry")
struct ConstantQGeometryTests {
    static let cases = ["defaults-48000", "defaults-44100", "defaults-22050", "semitones-tuned", "quarter-tones-long", "variable-q-short", "variable-q-fine"]

    // MARK: The definitions (§6.8)

    @Test(arguments: cases)
    func frequenciesAndAtomLengthsMatchTheDefinitions(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("geometry-\(name)")
        let geometry = try geometry(of: golden)
        let frequencies = try golden.real("frequencies"), lengths = try golden.real("atomLengths").map { Int($0) }
        #expect(geometry.binCount == frequencies.count && geometry.binCount == geometry.octaves * geometry.binsPerOctave)
        expectClose(geometry.frequencies, frequencies, .relative(1e-12), name)
        #expect(geometry.atomLengths == lengths, "\(name): the atom lengths are those of the definition, sample for sample")
        expectClose(geometry.alpha, try golden.number("alpha"), .relative(1e-14))
        expectClose(geometry.q, try golden.number("q"), .relative(1e-14))
        for bin in [0, 1, geometry.binCount / 2, geometry.binCount - 1] {
            #expect(geometry.frequency(ofBin: bin) == geometry.frequencies[bin] && geometry.atomLength(ofBin: bin) == lengths[bin])
        }
        #expect(lengths == lengths.sorted(by: >), "the lower the bin, the longer its atom")
    }

    @Test func theDefinitionsWrittenOut() throws {
        // C1 up, 7 octaves of 36 bins, at 48 kHz: the defaults of §6.8.
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        #expect(geometry.octaves == 7 && geometry.binsPerOctave == 36 && geometry.tuning == 0 && geometry.filterScale == 1 && geometry.gamma == 0)
        expectClose(geometry.minimumFrequency, 32.7032, .absolute(5e-5), "C1")
        let alpha = pow(2, 1.0 / 36) - 1
        #expect(geometry.alpha == alpha && geometry.q == 1 / alpha)
        for bin in 0 ..< 252 {
            let frequency = noteFrequency(24) * pow(2, Double(bin) / 36)
            expectClose(geometry.frequency(ofBin: bin), frequency, .relative(1e-13), "bin \(bin)")
            #expect(geometry.atomLength(ofBin: bin) == Int((geometry.q * 48_000 / geometry.frequency(ofBin: bin)).rounded(.up)), "bin \(bin)")
        }
        #expect(geometry.atomLength(ofBin: 0) == 75_499 && geometry.atomLength(ofBin: 251) == 602, "1.57 s at the bottom, 12.5 ms at the top")
        // Q periods of its own frequency in every atom, give or take the rounding up.
        for bin in stride(from: 0, to: 252, by: 17) {
            let periods = Double(geometry.atomLength(ofBin: bin)) * geometry.frequency(ofBin: bin) / 48_000
            #expect(periods >= geometry.q && periods < geometry.q * (1 + 1.0 / 600), "bin \(bin) holds \(periods) periods")
        }
    }

    @Test func binsAnOctaveApartAreAFactorOfExactlyTwoApart() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 27.5, octaves: 9, binsPerOctave: 24, tuning: -0.4, sampleRate: 44_100)
        for bin in 0 ..< geometry.binCount - 24 {
            #expect(geometry.frequency(ofBin: bin + 24) == 2 * geometry.frequency(ofBin: bin), "bin \(bin)")
        }
        // The formula holds outside the bins of the transform as well.
        #expect(geometry.frequency(ofBin: -24) == geometry.frequency(ofBin: 0) / 2 && geometry.frequency(ofBin: geometry.binCount) == 512 * geometry.frequency(ofBin: 0))
    }

    // MARK: Tuning and gamma

    @Test func tuningMovesEveryCentreByAFractionOfABin() throws {
        func geometry(_ tuning: Double) throws -> ConstantQGeometry {
            try ConstantQGeometry(minimumFrequency: 55, octaves: 6, binsPerOctave: 12, tuning: tuning, sampleRate: 48_000)
        }
        let plain = try geometry(0)
        for tuning in [-1, -0.5, -0.25, 0.1, 0.5, 1] {
            let tuned = try geometry(tuning)
            #expect(tuned.tuning == tuning && tuned.minimumFrequency == 55, "fmin is the centre of bin 0 before tuning")
            for bin in [0, 7, 40, 71] {
                expectClose(tuned.frequency(ofBin: bin), plain.frequency(ofBin: bin) * pow(2, tuning / 12), .relative(1e-13), "tuning \(tuning), bin \(bin)")
            }
            // A higher centre has a shorter atom: tuning belongs to the transform.
            #expect(tuning > 0 ? tuned.atomLength(ofBin: 0) < plain.atomLength(ofBin: 0) : tuned.atomLength(ofBin: 0) > plain.atomLength(ofBin: 0))
        }
        // A whole bin of tuning is the next bin.
        let next = try geometry(1)
        for bin in 0 ..< 71 { expectClose(next.frequency(ofBin: bin), plain.frequency(ofBin: bin + 1), .relative(1e-13)) }
        #expect(try geometry(0.25).axis == .constantQ(minimumFrequency: 55 * pow(2, 0.25 / 12), binsPerOctave: 12, binCount: 72), "row 0 of the axis is where bin 0 is")
    }

    @Test func gammaShortensTheAtomsOfTheLowBins() throws {
        let constant = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        let variable = try ConstantQGeometry(minimumFrequency: noteFrequency(24), gamma: 6.6, sampleRate: 48_000)
        #expect(variable.frequencies == constant.frequencies, "gamma moves no bin")
        for bin in 0 ..< 252 {
            // N = Q · rate / (f + γ/α) = filterScale · rate / (α·f + γ): the bandwidth grows by γ.
            let expected = Int((48_000 / (variable.alpha * variable.frequency(ofBin: bin) + 6.6)).rounded(.up))
            #expect(abs(variable.atomLength(ofBin: bin) - expected) <= 1 && variable.atomLength(ofBin: bin) < constant.atomLength(ofBin: bin), "bin \(bin)")
        }
        let low = Double(variable.atomLength(ofBin: 0)) / Double(constant.atomLength(ofBin: 0))
        let high = Double(variable.atomLength(ofBin: 251)) / Double(constant.atomLength(ofBin: 251))
        #expect(low < 0.1 && high > 0.9, "the lowest atom is \(low) of its constant-Q length, the highest \(high): the lever on latency")
    }

    // MARK: The octaves as the recursion reads them

    @Test func withoutGammaEveryOctaveHasTheAtomsOfTheHighestAtItsOwnRate() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 44_100)
        let top = Array(geometry.atomLengths[216...])
        for depth in 0 ..< 7 {
            #expect(geometry.atomLengths(atDepth: depth) == top && geometry.span(atDepth: depth) == 1_084, "depth \(depth)")
        }
        for position in [0, 17, 35] {
            #expect(geometry.normalizedFrequency(atPosition: position) == geometry.frequency(ofBin: 216 + position) / 44_100)
        }
    }

    @Test func withGammaEveryOctaveHasTheDefinitionAtItsOwnRate() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), octaves: 7, binsPerOctave: 24, gamma: 5, sampleRate: 22_050)
        var spans: [Int] = []
        for depth in 0 ..< 7 {
            let rate = 22_050 / pow(2, Double(depth))
            let first = (6 - depth) * 24
            let expected = (0 ..< 24).map { Int((geometry.q * rate / (geometry.frequency(ofBin: first + $0) + 5 / geometry.alpha)).rounded(.up)) }
            #expect(geometry.atomLengths(atDepth: depth) == expected, "depth \(depth)")
            spans.append(geometry.span(atDepth: depth))
            #expect(geometry.span(atDepth: depth) == expected[0], "the lowest bin of an octave has its longest atom")
        }
        #expect(spans == spans.sorted(by: >) && spans[6] < spans[0] / 4, "the lower the octave, the shorter its atoms in samples of its own rate: \(spans)")
    }

    // MARK: Values that make no geometry

    @Test func valuesOutOfRangeAreRefusedWithAReason() {
        func refusal(
            fmin: Double = 55, octaves: Int = 4, bins: Int = 12, tuning: Double = 0, scale: Double = 1, gamma: Double = 0, rate: Double = 48_000
        ) -> String? {
            errorMessage {
                _ = try ConstantQGeometry(minimumFrequency: fmin, octaves: octaves, binsPerOctave: bins, tuning: tuning, filterScale: scale, gamma: gamma, sampleRate: rate)
            }
        }
        #expect(refusal() == nil)
        #expect(refusal(rate: 0)?.contains("sampleRate") == true && refusal(rate: .infinity) != nil && refusal(rate: -48_000) != nil)
        #expect(refusal(fmin: 0)?.contains("fmin") == true && refusal(fmin: -5) != nil && refusal(fmin: .nan) != nil)
        #expect(refusal(octaves: 0)?.contains("octaves") == true && refusal(octaves: 33) != nil && refusal(octaves: -1) != nil)
        #expect(refusal(bins: 0)?.contains("binsPerOctave") == true && refusal(bins: 1_201) != nil && refusal(bins: 1_200) == nil && refusal(bins: 1) == nil)
        #expect(refusal(tuning: 1.5)?.contains("tuning") == true && refusal(tuning: -1.01) != nil && refusal(tuning: .nan) != nil && refusal(tuning: -1) == nil)
        #expect(refusal(scale: 0)?.contains("filterScale") == true && refusal(scale: -1) != nil && refusal(scale: .infinity) != nil && refusal(scale: 0.25) == nil)
        #expect(refusal(gamma: -1)?.contains("gamma") == true && refusal(gamma: .nan) != nil && refusal(gamma: 24.7) == nil)
        #expect(refusal(fmin: 1e-9, octaves: 1)?.contains("longer than 10¹² samples") == true, "an atom that cannot be counted")
    }

    @Test func binsThatReachTheNyquistFrequencyAreRefusedAndTheErrorSaysHowManyOctavesFit() throws {
        // 55 Hz at 48 kHz: the highest bin of n octaves of 12 is 55 · 2^(n − 1/12).
        for (octaves, fits) in [(8, true), (9, false), (12, false)] {
            let message = errorMessage { _ = try ConstantQGeometry(minimumFrequency: 55, octaves: octaves, binsPerOctave: 12, sampleRate: 48_000) }
            #expect((message == nil) == fits, "\(octaves) octaves: \(message ?? "accepted")")
            if !fits {
                #expect(message?.contains("octaves") == true && message?.contains("Nyquist frequency of 24000.0 Hz") == true && message?.contains("8 octaves above 55.0 Hz fit") == true, "\(message ?? "")")
            }
        }
        // A bin exactly on the Nyquist frequency does not lie below it.
        #expect(throws: DSPError.self) { _ = try ConstantQGeometry(minimumFrequency: 12_000, octaves: 2, binsPerOctave: 1, sampleRate: 48_000) }
        #expect(try ConstantQGeometry(minimumFrequency: 11_999, octaves: 2, binsPerOctave: 1, sampleRate: 48_000).binCount == 2)
        let none = errorMessage { _ = try ConstantQGeometry(minimumFrequency: 30_000, octaves: 1, binsPerOctave: 1, sampleRate: 48_000) }
        #expect(none?.contains("not one octave") == true, "\(none ?? "")")
        let one = errorMessage { _ = try ConstantQGeometry(minimumFrequency: 8_000, octaves: 2, binsPerOctave: 12, sampleRate: 48_000) }
        #expect(one?.contains("1 octave above 8000.0 Hz fit") == true, "\(one ?? "")")
    }

    @Test func aGeometryIsAValue() throws {
        let a = try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, sampleRate: 44_100)
        let b = try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, tuning: 0, filterScale: 1, gamma: 0, sampleRate: 44_100)
        #expect(a == b && a.hashValue == b.hashValue && a.sampleRate == 44_100)
        let others = [
            try ConstantQGeometry(minimumFrequency: 111, octaves: 5, binsPerOctave: 24, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 4, binsPerOctave: 24, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 12, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, tuning: 0.1, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, filterScale: 2, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, gamma: 3, sampleRate: 44_100),
            try ConstantQGeometry(minimumFrequency: 110, octaves: 5, binsPerOctave: 24, sampleRate: 48_000),
        ]
        #expect(others.allSatisfy { $0 != a })
        #expect(a.axis == .constantQ(minimumFrequency: 110, binsPerOctave: 24, binCount: 120) && a.axis.rowCount == 120 && a.axis.unit == .hertz)
        for bin in [0, 23, 119] { expectClose(a.axis.value(ofRow: bin), a.frequency(ofBin: bin), .relative(1e-13)) }
    }
}
