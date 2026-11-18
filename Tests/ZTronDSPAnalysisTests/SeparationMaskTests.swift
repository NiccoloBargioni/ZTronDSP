import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The mask of a strategy for a list of (component, competitor) pairs.
func shares(_ strategy: any MaskStrategy, _ pairs: [(Float, Float)], floor: Float = 1e-10) -> [Float] {
    let component = pairs.map { $0.0 }, competitor = pairs.map { $0.1 }
    var mask = [Float](repeating: -1, count: pairs.count)
    component.withUnsafeBufferPointer { own in
        competitor.withUnsafeBufferPointer { other in
            mask.withUnsafeMutableBufferPointer { strategy.mask(own.baseAddress!, against: other.baseAddress!, floor: floor, into: $0.baseAddress!, count: pairs.count) }
        }
    }
    return mask
}

/// The magnitude spectrogram of a fixture as the golden vectors of the separation frame it:
/// a Hann window of 1 024 samples, centred frames.
func separationSpectrogram(of fixture: String, hop: Int) throws -> (frames: [[Float]], format: SignalFormat) {
    let golden = try GoldenFile(named: "fixtures", in: .module).require(fixture)
    let format = SignalFormat(sampleRate: try golden.number("sampleRate"))
    let frames: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: hop, alignment: .centered); Magnitude() }
        .process(try golden.floats("samples"), format: format, blockSize: 441)
    return (frames, format)
}

/// The HPSS masks: hard, soft, margins, the zero-denominator rule (WP-530).
@Suite("Separation masks")
struct SeparationMaskTests {
    // MARK: The strategies

    @Test func theSoftMaskIsAShareOfPowers() {
        let pairs: [(Float, Float)] = [(1, 1), (3, 4), (4, 3), (1, 0), (0, 1), (2, 0.5), (1e-3, 1e-6), (10, 1e-9)]
        for power in [1.0, 2.0, 3.5, 0.5, 8] {
            let mask = shares(SoftMask(power: power), pairs)
            let expected = pairs.map { pair -> Double in
                let own = pow(Double(pair.0), power), other = pow(Double(pair.1), power)
                return own / (own + other)
            }
            expectClose(mask, expected, .absolute(2e-6), "power \(power)")
            #expect(mask.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        expectClose(shares(.soft(power: 2), [(3, 4)]), [0.36], .absolute(1e-7))
        #expect(shares(.soft(power: 1), [(1, 3)]) == [0.25] && shares(SoftMask(), [(1, 1)]) == [0.5])
        #expect(SoftMask().power == 2 && SoftMask.soft(power: 3).power == 3 && SoftMask(power: 2) == .soft(power: 2) && SoftMask(power: 2) != SoftMask(power: 1))
        // The two masks of a bin add up to 1 at unit margins.
        let harmonic = shares(.soft(power: 2), pairs), percussive = shares(.soft(power: 2), pairs.map { ($0.1, $0.0) })
        expectClose(zip(harmonic, percussive).map { $0 + $1 }, [Double](repeating: 1, count: pairs.count), .absolute(1e-6))
    }

    @Test func theHardMaskIsTheLimitOfTheSoftOne() {
        let pairs: [(Float, Float)] = [(1, 1), (3, 4), (4, 3), (1, 0), (0, 1), (2, 2.000_001), (1e-12, 1e-13), (0, 0)]
        #expect(shares(.hard, pairs) == [0, 0, 1, 1, 0, 0, 0, 0], "1 where the component exceeds the competitor; a tie goes to neither; nothing under the floor")
        // A large power is nearly there, wherever the two differ.
        let steep = shares(.soft(power: 200), pairs)
        for (index, share) in shares(.hard, pairs).enumerated() where pairs[index].0 != pairs[index].1 && index < 5 {
            expectClose(steep[index], share, .absolute(1e-6))
        }
        #expect(HardMask() == .hard)
    }

    @Test func whereNeitherMedianReachesTheFloorBothMasksAreZero() {
        let silent: [(Float, Float)] = [(0, 0), (1e-12, 1e-11), (1e-11, 0), (.leastNonzeroMagnitude, .leastNonzeroMagnitude)]
        for strategy in [SoftMask(power: 2) as any MaskStrategy, SoftMask(power: 1), SoftMask(power: 3), HardMask()] {
            #expect(shares(strategy, silent) == [0, 0, 0, 0], "\(strategy): 0/0 is no share (NUM-1)")
            // One side at the floor is known.
            #expect(shares(strategy, [(1e-10, 0), (0, 1e-10)]) == [1, 0], "\(strategy)")
        }
        // A floor of 0 is no floor: a soft mask then shares a bin without medians equally.
        #expect(shares(.soft(power: 2), [(0, 0)], floor: 0) == [0.5] && shares(.hard, [(0, 0)], floor: 0) == [0])
        // The caller moves the floor.
        #expect(shares(.soft(power: 2), [(0.5, 0.5)], floor: 1) == [0] && shares(.soft(power: 2), [(0.5, 0.5)], floor: 0.5) == [0.5])
    }

    @Test func noShareIsEverNotANumber() {
        // Levels at which a power overflows or underflows, infinities, and values that are not numbers.
        let wild: [(Float, Float)] = [(1e30, 1e30), (3e38, 1), (1, 3e38), (1e-30, 1e-30), (1e-30, 1e-35), (.infinity, .infinity), (.infinity, 1), (1, .infinity),
                                      (.nan, 1), (1, .nan), (.nan, .nan), (.greatestFiniteMagnitude, .greatestFiniteMagnitude)]
        for power in [1.0, 2.0, 3.0, 40] {
            for floor in [Float(0), 1e-10] {
                let mask = shares(SoftMask(power: power), wild, floor: floor)
                #expect(mask.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "power \(power), floor \(floor): \(mask)")
                #expect(mask[0] == 0.5 && mask[1] == 1 && mask[2] < 1e-30 && mask[5] == 0.5 && mask[6] == 1 && mask[7] == 0)
            }
        }
        let hard = shares(.hard, wild)
        #expect(hard.allSatisfy { $0 == 0 || $0 == 1 } && hard[1] == 1 && hard[6] == 1 && hard[8] == 0 && hard[9] == 0 && hard[10] == 0)
        // The ratio is taken before the power: the mask does not depend on the level.
        let pairs: [(Float, Float)] = [(1, 2), (3, 1), (5, 5), (0.01, 7)]
        let reference = shares(.soft(power: 2), pairs)
        for scale in [Float(1e18), 1e-18, 1e25] {
            expectClose(shares(.soft(power: 2), pairs.map { ($0.0 * scale, $0.1 * scale) }, floor: 0), reference, .absolute(1e-6), "a spectrum \(scale) times as large")
        }
    }

    @Test func aMaskThatIsNoneIsRefused() {
        for power in [0.0, -1, .nan, .infinity] {
            #expect(throws: DSPError.self, "\(power)") { try SoftMask(power: power).validate() }
        }
        #expect(throws: Never.self) { try SoftMask(power: 0.1).validate() }
        #expect(throws: Never.self) { try HardMask().validate() }
        #expect(errorMessage { try SoftMask(power: 0).validate() }?.contains("the power of a soft mask is positive and finite") == true)
    }

    // MARK: Margins and the residual

    @Test func marginsLeaveAResidual() throws {
        let time: [Float] = [4, 1, 3, 3, 0, 2, 1e-12], frequency: [Float] = [1, 4, 3, 2, 0, 0, 1e-12]
        func masks(_ strategy: any MaskStrategy, _ harmonicMargin: Float, _ percussiveMargin: Float) throws -> [HarmonicPercussiveComponent: [Float]] {
            let separation = try SeparationMasks(binCount: 7, strategy: strategy, harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: 1e-10)
            var result: [HarmonicPercussiveComponent: [Float]] = [:]
            for component in HarmonicPercussiveComponent.allCases {
                var mask = [Float](repeating: -1, count: 7)
                time.withUnsafeBufferPointer { h in frequency.withUnsafeBufferPointer { p in
                    mask.withUnsafeMutableBufferPointer { separation.mask(component, timeMedian: h.baseAddress!, frequencyMedian: p.baseAddress!, into: $0.baseAddress!) }
                } }
                result[component] = mask
            }
            return result
        }
        // Unit margins, soft: the two masks share every bin that has a median; nothing is left but the bins that have none.
        let plain = try masks(SoftMask(power: 2), 1, 1)
        let seventeenth = 1.0 / 17, thirteenth = 1.0 / 13
        let plainHarmonic: [Double] = [16 * seventeenth, seventeenth, 0.5, 9 * thirteenth, 0, 1, 0]
        let plainPercussive: [Double] = [seventeenth, 16 * seventeenth, 0.5, 4 * thirteenth, 0, 0, 0]
        let plainResidual: [Double] = [0, 0, 0, 0, 1, 0, 1]
        expectClose(try #require(plain[.harmonic]), plainHarmonic, .absolute(1e-6))
        expectClose(try #require(plain[.percussive]), plainPercussive, .absolute(1e-6))
        expectClose(try #require(plain[.residual]), plainResidual, .absolute(1e-6), "what has no median is nobody's")
        // Margins: M_H = H² / (H² + (m_H·P)²), M_P = P² / (P² + (m_P·H)²).
        let wide = try masks(SoftMask(power: 2), 2, 3)
        let wideHarmonic: [Double] = [0.8, 0.015_384_615_384_615_385, 0.2, 0.36, 0, 1, 0]
        let widePercussive: [Double] = [0.006_896_551_724_137_931, 0.64, 0.1, 0.047_058_823_529_411_764, 0, 0, 0]
        expectClose(try #require(wide[.harmonic]), wideHarmonic, .absolute(1e-6), "16/20, 1/65, 9/45, 9/25")
        expectClose(try #require(wide[.percussive]), widePercussive, .absolute(1e-6), "1/145, 16/25, 9/90, 4/85")
        for component in [wide, plain, try masks(HardMask(), 1, 1), try masks(HardMask(), 2, 2), try masks(SoftMask(power: 1), 1.5, 1)] {
            let harmonic = try #require(component[.harmonic]), percussive = try #require(component[.percussive]), residual = try #require(component[.residual])
            for bin in 0 ..< 7 {
                expectClose(harmonic[bin] + percussive[bin] + residual[bin], 1, .absolute(1e-6), "the three shares of a bin add up to 1")
                #expect(residual[bin] >= 0 && harmonic[bin] >= 0 && percussive[bin] >= 0)
            }
        }
        // Hard, with a margin of 2: a bin goes to a side only where that side leads by the margin.
        let hard = try masks(HardMask(), 2, 2)
        #expect(hard[.harmonic] == [1, 0, 0, 0, 0, 1, 0] && hard[.percussive] == [0, 1, 0, 0, 0, 0, 0] && hard[.residual] == [0, 0, 1, 1, 1, 0, 1])
        #expect(HarmonicPercussiveComponent.allCases == [.harmonic, .percussive, .residual])
    }

    // MARK: Golden (§6.10): soft within 10⁻³, hard on 99.9 % of the bins above −60 dB of the frame maximum

    @Test(arguments: ["music-soft2-31-31", "music-hard-31-31", "music-soft1-17-17-margins", "speech-soft2-17-31"])
    func theMasksOfTheFixturesEqualTheReference(name: String) async throws {
        let golden = try GoldenFile(named: "hpss", in: .module).require(name)
        let hop = try golden.integer("hop"), bins = try golden.integer("bins"), count = try golden.integer("frames")
        let spectrogram = try separationSpectrogram(of: try golden.string("fixture"), hop: hop).frames
        #expect(spectrogram.count == count && spectrogram.allSatisfy { $0.count == bins })
        let isHard = try golden.integer("hard") == 1, power = try golden.number("power")
        let magnitudes = spectrogram.flatMap { $0 }
        let timeKernel = try golden.integer("timeKernel"), frequencyKernel = try golden.integer("frequencyKernel")
        let harmonicMargin = try golden.number("harmonicMargin"), percussiveMargin = try golden.number("percussiveMargin"), floor = try golden.number("floor")
        let masks: (harmonic: [Float], percussive: [Float])
        if isHard {
            masks = try await DSP.harmonicPercussiveMasks(
                of: magnitudes, binCount: bins, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: .hard, harmonicMargin: harmonicMargin,
                percussiveMargin: percussiveMargin, floor: floor, median: .selectionNetwork)
        } else {
            masks = try await DSP.harmonicPercussiveMasks(
                of: magnitudes, binCount: bins, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: .soft(power: power),
                harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: floor, median: .selectionNetwork)
        }
        let references = [try golden.floats("harmonic"), try golden.floats("percussive")]
        var compared = 0, differing = 0, worst = 0.0
        for (mask, reference) in zip([masks.harmonic, masks.percussive], references) {
            #expect(mask.count == reference.count && mask.allSatisfy { $0 >= 0 && $0 <= 1 })
            for frame in 0 ..< count {
                let maximum = spectrogram[frame].max() ?? 0
                for bin in 0 ..< bins where spectrogram[frame][bin] > 1e-3 * maximum {
                    let deviation = abs(Double(mask[frame * bins + bin]) - Double(reference[frame * bins + bin]))
                    compared += 1
                    worst = max(worst, deviation)
                    if deviation > (isHard ? 0.5 : 1e-3) { differing += 1 }
                }
            }
        }
        #expect(compared > 10_000, "\(compared) bins above −60 dB of their frame's maximum")
        if isHard {
            let agreement = 1 - Double(differing) / Double(compared)
            print("measured WP-530: \(name): hard masks agree on \(agreement * 100) % of \(compared) bins (tolerance 99.9 %)")
            #expect(agreement >= 0.999, "\(name): \(differing) of \(compared) bins differ")
        } else {
            print("measured WP-530: \(name): soft masks within \(worst) of the reference on \(compared) bins (tolerance 1e-3)")
            #expect(differing == 0, "\(name): \(differing) of \(compared) bins are off by more than 1e-3; the worst by \(worst)")
        }
    }
}
