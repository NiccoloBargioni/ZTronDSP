import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// The stress tests of the stability notes of convolution, autocorrelation, the onset strength,
/// the tempograms, the median lanes, the masks and the streaming separation (NUMS-2): one per
/// `ALG` package of WP-513 … WP-531a, each on fixtures of the stress library (WP-016), each
/// failing when the mitigation its note names is removed. The notes are
/// `Docs/Numerics/one-shot-convolution.md`, `autocorrelation.md`, `onset-strength.md`,
/// `tempogram.md`, `median-lanes.md`, `separation-masks.md` and `harmonic-percussive.md`.
@Suite("Numerical stability of convolution, rhythm and separation")
struct RhythmSeparationStabilityTests {
    private static let epsilon = Double(Float.ulpOfOne)
    private static let tiny = Double(Float.leastNonzeroMagnitude)

    // MARK: Row 10, one-shot convolution (WP-513)

    @Test func aConvolutionBelowTheCrossoverKeepsItsSmallOutputs() throws {
        let count = 4_096
        let kernels: [[Float]] = [[1], [0.5, 0.5], [1, -2, 3, -2, 1], TestSignal.whiteNoise(count: 16, seed: 513)]
        var worstDirect = 0.0, worstTransform = 0.0, worstOfLargest = 0.0, small = 0, keptByDirect = 0, keptByTransform = 0, strayZeros = 0
        var worstCase = "", worstOfLargestCase = ""
        for fixture in StressFixture.signals(count: count) {
            for h in kernels {
                let taps = Double(h.count)
                let exact = naiveConvolution(fixture.samples, h)
                // What each output is a sum of: the magnitudes of its products.
                let scale = naiveConvolution(fixture.samples.map { abs($0) }, h.map { abs($0) })
                let largest = exact.map { abs($0) }.max() ?? 0
                // The largest output the two inputs can give: the largest sample times the sum of the taps' magnitudes.
                let reach = Double(fixture.samples.map { abs($0) }.max() ?? 0) * h.reduce(0.0) { $0 + abs(Double($1)) }
                #expect(OneShotConvolution.method(.automatic, count, h.count, crossovers: .shipped) == .direct, "\(h.count) taps lie below the crossover")
                let automatic = try DSP.convolve(fixture.samples, h)
                let transformed = try DSP.convolve(fixture.samples, h, strategy: .fft)
                #expect(automatic.count == exact.count && transformed.count == exact.count)
                guard automatic.count == exact.count, transformed.count == exact.count else { continue }

                // The direct method: every output right to K·ε of its own products, however far it
                // lies under the largest one (and to half a step of the subnormal range per product).
                var outside = 0, farOff = 0.0
                for index in exact.indices {
                    let error = abs(Double(automatic[index]) - exact[index])
                    if !(error <= taps * Self.epsilon * scale[index] + taps * Self.tiny) { outside += 1 }
                    if scale[index] > 1e-30 { worstDirect = max(worstDirect, error / (Self.epsilon * scale[index])) }
                    farOff = max(farOff, abs(Double(transformed[index]) - exact[index]))
                    // Outputs 180 dB and more under the largest, and still normal numbers: which
                    // method knows them to half of themselves?
                    if abs(exact[index]) >= 1e-30, abs(exact[index]) <= 1e-9 * largest {
                        small += 1
                        if error <= 0.5 * abs(exact[index]) { keptByDirect += 1 }
                        if abs(Double(transformed[index]) - exact[index]) <= 0.5 * abs(exact[index]) { keptByTransform += 1 }
                    }
                    if exact[index] == 0, scale[index] == 0, transformed[index] != 0 { strayZeros += 1 }
                }
                #expect(outside == 0, "\(fixture.name), \(h.count) taps: \(outside) outputs of the automatic method are further than K·ε from the sum of their products")
                // The FFT method: every output right to a floor under the largest the inputs can give.
                #expect(farOff <= 2e-6 * reach + 16 * Self.tiny, "\(fixture.name), \(h.count) taps: the FFT method is off by \(reach > 0 ? farOff / reach : farOff) of the largest output the inputs can give")
                if reach > 1e-30, farOff / reach > worstTransform {
                    worstTransform = farOff / reach
                    worstCase = "\(fixture.name), \(h.count) taps"
                }
                if largest > 1e-30, farOff / largest > worstOfLargest {
                    worstOfLargest = farOff / largest
                    worstOfLargestCase = "\(fixture.name), \(h.count) taps"
                }
            }
        }
        print("measured stability row 10: direct, worst error \(worstDirect) ε of the sum of an output's products (bound: K ε, K ≤ 16); FFT, worst error \(worstTransform) of the largest output the inputs can give (the largest sample times the sum of the taps' magnitudes; \(worstCase)), \(worstOfLargest) of the largest output there is (\(worstOfLargestCase)); of \(small) outputs 180 dB and more under the largest the direct method keeps \(keptByDirect) to half of themselves, the FFT method \(keptByTransform); \(strayZeros) outputs that are exactly zero read something by the FFT method")
        // The hazard is real, and the direct method does not have it.
        #expect(small > 250 && keptByDirect == small, "the library has outputs far under the largest (\(small)), and the direct method keeps every one (\(keptByDirect))")
        #expect(keptByTransform < small / 10, "the FFT method loses them: it keeps \(keptByTransform) of \(small)")
        #expect(strayZeros > 1_000, "and writes its floor where the result is exactly zero: \(strayZeros) such outputs")
    }

    // MARK: Row 11, autocorrelation (WP-515)

    /// The linear autocorrelation of `frame` by its definition, in double precision: lags `0 ..< lags`.
    private func linearAutocorrelation(_ frame: [Float], lags: Int) -> [Double] {
        let values = frame.map(Double.init)
        var result = [Double](repeating: 0, count: lags)
        values.withUnsafeBufferPointer { x in
            for lag in 0 ..< min(lags, x.count) {
                var sum = 0.0
                var index = 0
                while index + lag < x.count {
                    sum += x[index] * x[index + lag]
                    index += 1
                }
                result[lag] = sum
            }
        }
        return result
    }

    @Test func theAutocorrelationOfEveryStressSignalIsLinearAndGuarded() throws {
        let window = 1_024, hop = 512
        var worst = 0.0, worstCoefficient = 0.0, wrongSign = 0, withEnergy = 0, without = 0
        for fixture in StressFixture.signals(count: 4_096) {
            let frames: [[Float]] = try Pipeline { Autocorrelation(window: window, hop: hop) }.process(fixture.samples, format: mono48)
            let coefficients: [[Float]] = try Pipeline { Autocorrelation(window: window, hop: hop, normalization: .coefficient) }
                .process(fixture.samples, format: mono48)
            #expect(frames.count == 7 && coefficients.count == 7 && frames.allSatisfy { $0.count == window }, "\(fixture.name): \(frames.count) frames")
            guard frames.count == 7, coefficients.count == 7 else { continue }
            for (index, frame) in frames.enumerated() {
                let exact = linearAutocorrelation(Array(fixture.samples[index * hop ..< index * hop + window]), lags: window)
                let energy = exact[0]
                // Linear, not circular: every lag at the floor of the transform under lag 0.
                var off = 0.0
                for lag in 0 ..< window {
                    off = max(off, abs(Double(frame[lag]) - exact[lag]))
                    if exact[lag] == 0, frame[lag] < 0 { wrongSign += 1 }
                }
                #expect(frame.allSatisfy { $0.isFinite } && off <= 1e-6 * energy + 16 * Self.tiny,
                        "\(fixture.name), frame \(index): off by \(energy > 0 ? off / energy : off) of the value at lag 0")
                if energy > 1e-30 { worst = max(worst, off / energy) }

                // The coefficient: 1 at lag 0 and within the floor of 1 elsewhere, or nothing at all.
                let normalized = coefficients[index]
                if energy > DSP.correlationFloor {
                    var offCoefficient = 0.0
                    for lag in 0 ..< window { offCoefficient = max(offCoefficient, abs(Double(normalized[lag]) - exact[lag] / energy)) }
                    #expect(normalized[0] == 1 && offCoefficient <= 1e-6 && normalized.allSatisfy { abs($0) <= 1 + 1e-6 },
                            "\(fixture.name), frame \(index): a coefficient off by \(offCoefficient)")
                    worstCoefficient = max(worstCoefficient, offCoefficient)
                    withEnergy += 1
                } else {
                    #expect(normalized.allSatisfy { $0 == 0 }, "\(fixture.name), frame \(index): no energy, no coefficient: zeros, not 0/0 (NUM-1)")
                    without += 1
                }
            }
            // The one-shot function by the same relation, and its guard.
            let whole = try DSP.autocorrelate(fixture.samples, maxLag: 1_500, normalization: .coefficient, strategy: .fft)
            #expect(whole.count == 1_501 && whole.allSatisfy { $0.isFinite && abs($0) <= 1 + 1e-6 }, "\(fixture.name): the one-shot coefficients")
        }
        #expect(withEnergy > 25 && without > 25, "the library exercises both: \(withEnergy) frames with energy, \(without) without")

        // A frame so smooth that lag 0 and lag 1 differ by less than the floor of the transform:
        // a Hann window over a constant. Which of the two reads larger is then round-off.
        let smooth = try Window.hann.samples(count: 16_384)
        let exact = linearAutocorrelation(smooth, lags: 2)
        let transformed = try DSP.autocorrelate(smooth, maxLag: 1, strategy: .fft)
        let coefficient = try DSP.autocorrelate(smooth, maxLag: 1, normalization: .coefficient, strategy: .fft)
        let gap = (exact[0] - exact[1]) / exact[0]
        print("measured stability row 11: \(withEnergy) frames with energy, \(without) without; worst error \(worst) of the value at lag 0; worst coefficient error \(worstCoefficient); \(wrongSign) lags that are exactly zero read below zero; a Hann frame of 16 384: lag 1 lies \(gap) of lag 0 under it, and reads \((Double(transformed[0]) - Double(transformed[1])) / exact[0]) under it by the transform (coefficient at lag 1: \(coefficient[1]))")
        #expect(gap < 1e-7, "the fixture is as smooth as that: \(gap)")
        #expect(abs(Double(transformed[1]) - exact[1]) <= 1e-6 * exact[0] && coefficient[0] == 1 && coefficient[1] <= 1 + 1e-6)
    }

    // MARK: Row 14, the onset strength (WP-525)

    @Test func theOnsetStrengthOfEveryStressSignalIsBoundedByItsFloor() throws {
        let floor = -80.0
        // Levels re full scale, floored far under the floor of the step: what the step does
        // with them is then its own.
        func curve(_ samples: [Float], floor: Double) throws -> (levels: [[Float]], onsets: [ScalarFrame]) {
            let levels = CollectingSink<Spectrum<MelFrequency, DecibelValues>>()
            let onsets: [ScalarFrame] = try Pipeline {
                STFT(frame: 1_024, hop: 256, normalization: .amplitude); Power(); MelScale(bands: 40); Decibels(floor: -400)
                Emit(to: levels)
                OnsetStrength(floor: floor)
            }.process(samples, format: mono48)
            return (levels.reals, onsets)
        }
        var largest = 0.0, worst = 0.0, counted = 0.0
        for fixture in StressFixture.signals(count: 8_192) {
            let loud = try curve(fixture.samples, floor: floor)
            #expect(loud.onsets.count == 29 && loud.levels.count == 29, "\(fixture.name): \(loud.onsets.count) values")
            guard loud.onsets.count == 29, loud.levels.count == 29 else { continue }
            #expect(loud.onsets[0].value == 0 && loud.onsets[0].confidence == 0, "\(fixture.name): the first frame has nothing to be compared with")
            for index in 1 ..< 29 {
                // The definition on the levels the step was given, raised to the floor, in double precision.
                var sum = 0.0, peak = -Double.infinity
                for band in 0 ..< 40 {
                    let now = max(Double(loud.levels[index][band]), floor), before = max(Double(loud.levels[index - 1][band]), floor)
                    sum += max(now - before, 0)
                    peak = max(peak, now)
                }
                let value = Double(loud.onsets[index].value)
                worst = max(worst, abs(value - sum / 40))
                largest = max(largest, value)
                // No band can rise from further down than the floor.
                #expect(loud.onsets[index].confidence == 1 && value.isFinite && value >= 0 && value <= peak - floor + 1e-3 && abs(value - sum / 40) <= 1e-3,
                        "\(fixture.name), frame \(index): \(value) against \(sum / 40), the highest band \(peak - floor) dB over the floor")
            }

            // The same signal 180 dB down lies under the floor everywhere: nothing rises.
            let quiet = try curve(fixture.samples.map { $0 * 1e-9 }, floor: floor)
            #expect(quiet.levels.allSatisfy { $0.allSatisfy { Double($0) < floor } }, "\(fixture.name) at −180 dB lies under the floor")
            #expect(quiet.onsets.count == 29 && quiet.onsets.allSatisfy { $0.value == 0 }, "\(fixture.name) at −180 dB: nothing under the floor counts as an onset")

            // Without a floor that reaches it, the noise floor counts: a difference of logarithms
            // does not know how far down it is taken.
            let unfloored = try curve(fixture.samples.map { $0 * 1e-9 }, floor: -1_000)
            let reference = try curve(fixture.samples, floor: -1_000)
            let quietMean = unfloored.onsets.dropFirst().reduce(0.0) { $0 + Double($1.value) } / 28
            let loudMean = reference.onsets.dropFirst().reduce(0.0) { $0 + Double($1.value) } / 28
            if fixture.name == "white-noise" {
                counted = quietMean
                #expect(quietMean > 0.5 && abs(quietMean - loudMean) < 0.05,
                        "noise 180 dB down rises by \(quietMean) dB a frame on average, as much as at full scale (\(loudMean) dB)")
            }
            #expect(unfloored.onsets.allSatisfy { $0.value.isFinite }, "\(fixture.name): still numbers, whatever the floor")
        }
        print("measured stability row 14: off the definition by at most \(worst) dB; largest onset strength \(largest) dB; white noise 180 dB under full scale, floor −80 dB: 0 dB a frame; the same with a floor of −1 000 dB: \(counted) dB a frame")
    }

    // MARK: Row 15, the tempograms (WP-526, WP-527)

    @Test func theTempogramOfEveryStressCurveShowsWhatMovesAndNothingElse() throws {
        let rate = 93.75        // 48 kHz in hops of 512
        func columns(_ curve: [Float], _ step: Tempogram) throws -> [[Float]] {
            try Pipeline { SamplesAsNovelty(); step }.process(curve, format: SignalFormat(sampleRate: rate), blockSize: 64)
        }
        func tempi(_ step: Tempogram) throws -> [Double] {
            guard case .tempo(let rows)? = try environmentAtTheEnd(of: Pipeline { SamplesAsNovelty(); step }, sampleRate: rate).frequencyAxis else { return [] }
            return rows
        }
        let window = 384
        let taper = try Window.hann.samples(count: window).reduce(0.0) { $0 + Double($1) }
        let lagTempi = try tempi(Tempogram(.autocorrelation)), binTempi = try tempi(Tempogram(.fourier))
        // Only the rows of the range: the lags 19 … 187 at this rate, lag 0 and its 1 not among them.
        #expect(lagTempi.count == 169 && lagTempi.allSatisfy { (30 ... 300).contains($0) } && binTempi.allSatisfy { (30 ... 300).contains($0) })
        #expect(zip(lagTempi, lagTempi.dropFirst()).allSatisfy { $0 < $1 } && zip(binTempi, binTempi.dropFirst()).allSatisfy { $0 < $1 })

        var worstPedestal = 0.0, worstBound = 0.0, still = 0, moving = 0
        for fixture in StressFixture.signals(count: 1_024) {
            let lags = try columns(fixture.samples, Tempogram(.autocorrelation)), bins = try columns(fixture.samples, Tempogram(.fourier))
            #expect(lags.count == 1_024 - window + 1 && bins.count == lags.count, "\(fixture.name): \(lags.count) columns")
            let spread = Double((fixture.samples.max() ?? 0) - (fixture.samples.min() ?? 0))
            // Numbers, and bounded: a coefficient by 1, a magnitude by the window's sum times the spread of the curve.
            for column in lags {
                let peak = column.map { abs($0) }.max() ?? 0
                worstBound = max(worstBound, Double(peak))
                #expect(column.allSatisfy { $0.isFinite } && peak <= 1 + 1e-5, "\(fixture.name): an autocorrelation coefficient of \(peak)")
            }
            #expect(bins.allSatisfy { $0.allSatisfy { $0.isFinite && $0 >= 0 && Double($0) <= taper * spread * (1 + 1e-5) + 1e-30 } }, "\(fixture.name): the Fourier rows")

            // The same curve on a pedestal a thousand times the height of its largest value:
            // the mean is removed, so what moves is still all that shows.
            let height = 1_000 * (fixture.samples.map { abs($0) }.max() ?? 0)
            let lifted = fixture.samples.map { $0 + height }
            let liftedLags = try columns(lifted, Tempogram(.autocorrelation)), liftedBins = try columns(lifted, Tempogram(.fourier))
            if ["silence", "dc", "denormal"].contains(fixture.name) {
                // Nothing moves: 0/0 at lag 0, and zeros by rule (NUM-1).
                #expect(lags.allSatisfy { $0.allSatisfy { $0 == 0 } } && liftedLags.allSatisfy { $0.allSatisfy { $0 == 0 } }, "\(fixture.name): a curve that does not move has no tempo")
                #expect(bins.allSatisfy { $0.allSatisfy { $0 == 0 } } && liftedBins.allSatisfy { $0.allSatisfy { $0 == 0 } }, "\(fixture.name): nor a spectrum once its mean is out")
                still += 1
            } else if ["full-scale-sine", "full-scale-square", "nyquist", "white-noise"].contains(fixture.name) {
                // What moves all along the curve: the pedestal changes the picture by its round-off
                // only. A coefficient is held against 1, a magnitude against the bound of a row.
                var moved = 0.0
                for (plain, raised) in zip(lags, liftedLags) { for (a, b) in zip(plain, raised) { moved = max(moved, abs(Double(a) - Double(b))) } }
                for (plain, raised) in zip(bins, liftedBins) { for (a, b) in zip(plain, raised) { moved = max(moved, abs(Double(a) - Double(b)) / (taper * spread)) } }
                #expect(moved <= 5e-3, "\(fixture.name): the pedestal moves a row by \(moved)")
                worstPedestal = max(worstPedestal, moved)
                moving += 1
            }
            if fixture.name == "full-scale-square" {
                // 24 values up, 24 down: a period of 48 values is 60 · 93.75 / 48 = 117.19 beats per minute.
                let beat = try #require(lagTempi.firstIndex { abs($0 - 60 * rate / 48) < 1e-9 })
                let nearest = try #require(binTempi.indices.min { abs(binTempi[$0] - 60 * rate / 48) < abs(binTempi[$1] - 60 * rate / 48) })
                for (plain, raised) in zip(lags, liftedLags) {
                    #expect(plain.indices.max { plain[$0] < plain[$1] } == beat && raised.indices.max { raised[$0] < raised[$1] } == beat,
                            "the largest coefficient is at the period of the square, with and without the pedestal")
                }
                for (plain, raised) in zip(bins, liftedBins) {
                    let top = try #require(plain.indices.max { plain[$0] < plain[$1] }), raisedTop = try #require(raised.indices.max { raised[$0] < raised[$1] })
                    #expect(abs(top - nearest) <= 1 && abs(raisedTop - nearest) <= 1, "the largest magnitude is at the tempo of the square, with and without the pedestal")
                }
            }
        }
        #expect(still == 3 && moving == 4)
        print("measured stability row 15: largest autocorrelation coefficient \(worstBound); a pedestal of 1 000 times the curve's largest value moves a row by at most \(worstPedestal) (of 1 for a coefficient, of the bound of a row for a magnitude)")
    }

    // MARK: Row 16, the median on CPU lanes (WP-529)

    @Test func theMedianLanesOfEveryStressSignalAreTheSortedMiddle() throws {
        let bins = 33
        var compared = 0, subnormal = 0, negativeZeros = 0
        // Twelve frames: kernels of 31 and 63 reach further than the stream is long, and reflect more than once.
        for frameCount in [12, 40] {
            for fixture in StressFixture.signals(count: bins * frameCount) {
                for signed in [false, true] {
                    // Magnitudes; or the signal as it is, with every third value's sign turned, zeros included.
                    let values: [Float] = signed
                        ? fixture.samples.enumerated().map { $0.offset % 3 == 0 ? -$0.element : $0.element }
                        : fixture.samples.map { abs($0) }
                    let frames = (0 ..< frameCount).map { Array(values[$0 * bins ..< ($0 + 1) * bins]) }
                    for kernel in [3, 17, 31, 63] {
                        let alongTime = MedianOracle.filter(values, rowCount: bins, kernel: kernel, along: .time)
                        let alongFrequency = MedianOracle.filter(values, rowCount: bins, kernel: kernel, along: .frequency)
                        let running = MedianOracle.running(frames, kernel: kernel)
                        subnormal += alongTime.filter { $0 != 0 && abs($0) < .leastNormalMagnitude }.count
                        negativeZeros += alongTime.filter { $0 == 0 && $0.sign == .minus }.count
                        // Both lane exchanges: the C loop and vDSP.
                        for table in [CrossoverTable(laneExchange: .max), CrossoverTable(laneExchange: 1)] {
                            let name = "\(fixture.name)\(signed ? ", signed" : ""), \(frameCount) frames, kernel \(kernel), lane exchange from \(table.laneExchange)"
                            let lanes = SelectionNetworkMedian()
                            #expect(try lanes.filter(values, rowCount: bins, kernel: kernel, along: .time, crossovers: table).map { $0.bitPattern }
                                    == alongTime.map { $0.bitPattern }, "\(name): along time, bit for bit")
                            #expect(try lanes.filter(values, rowCount: bins, kernel: kernel, along: .frequency, crossovers: table).map { $0.bitPattern }
                                    == alongFrequency.map { $0.bitPattern }, "\(name): along frequency, bit for bit")
                            // As a stream: every frame the median of the frames so far, reflected at the start.
                            let filter = try lanes.makeFilter(kernel: kernel, binCount: bins, along: .time, implementation: .automatic, crossovers: table)
                            #expect(bitPatterns(filtered(frames, by: filter)) == bitPatterns(running), "\(name): as a stream")
                            compared += 3 * values.count
                        }
                    }
                }
            }
        }
        let exchanges = try [3, 17, 31, 63].map { "\($0) lanes: \(try MedianNetwork(count: $0).exchanges.count)" }.joined(separator: ", ")
        print("measured stability row 16: \(compared) medians of the stress library equal the sort-based oracle bit for bit; among those along time \(subnormal) are subnormal and \(negativeZeros) are −0; exchanges per frame: \(exchanges)")
        #expect(subnormal > 1_000 && negativeZeros > 1_000, "the library exercises both: \(subnormal) subnormal medians, \(negativeZeros) zeros with a sign")

        // A value that is not a number never reaches a lane: it is replaced where the signal
        // enters (NUM-1), and the medians are those of the signal without it.
        let fixture = StressFixture.nonFiniteSignal(count: 4_096)
        let cleaned = fixture.samples.map { $0.isFinite ? $0 : 0 }
        let separation = Pipeline { STFT(frame: 64, hop: 32); Magnitude(); HarmonicPercussive(select: .harmonic, timeKernel: 5, frequencyKernel: 5) }
        let harmonic: [[Float]] = try separation.process(fixture.samples, format: mono48)
        #expect(fixture.nonFiniteCount == 3 && harmonic.count == 127 && harmonic.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(try separation.process(cleaned, format: mono48) == harmonic, "the frames of the signal with its three values replaced")
    }

    // MARK: The masks of the separation (WP-530)

    @Test func theMasksOfEveryStressSpectrogramAreSharesAtAnyLevel() async throws {
        let bins = 513, floor = 1e-10
        let strategies: [(name: String, mask: any MaskStrategy, power: Double?)] = [
            ("soft, power 2", SoftMask(power: 2), 2), ("soft, power 1", SoftMask(power: 1), 1), ("soft, power 4.5", SoftMask(power: 4.5), 4.5), ("hard", HardMask(), nil),
        ]
        func masks(_ magnitudes: [Float], _ mask: any MaskStrategy, _ margins: (Double, Double), floor: Double) async throws -> (harmonic: [Float], percussive: [Float]) {
            func run<M: MaskStrategy>(_ strategy: M) async throws -> (harmonic: [Float], percussive: [Float]) {
                try await DSP.harmonicPercussiveMasks(
                    of: magnitudes, binCount: bins, timeKernel: 17, frequencyKernel: 17, mask: strategy, harmonicMargin: margins.0, percussiveMargin: margins.1,
                    floor: floor, median: .selectionNetwork)
            }
            return try await run(mask)
        }
        var worst = 0.0, undivided = 0, lostToPowers = 0, checked = 0
        for fixture in StressFixture.signals(count: 8_192) {
            let frames: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude() }.process(fixture.samples, format: mono48)
            let magnitudes = frames.flatMap { $0 }
            #expect(frames.count == 29)
            let alongTime = MedianOracle.filter(magnitudes, rowCount: bins, kernel: 17, along: .time).map(Double.init)
            let alongFrequency = MedianOracle.filter(magnitudes, rowCount: bins, kernel: 17, along: .frequency).map(Double.init)
            for strategy in strategies {
                for margins in [(1.0, 1.0), (2.0, 3.0)] {
                    let name = "\(fixture.name), \(strategy.name), margins \(margins.0) and \(margins.1)"
                    let reference = try await masks(magnitudes, strategy.mask, margins, floor: floor)
                    // Shares: numbers between 0 and 1 that never claim more than there is; by
                    // their definition in double precision; nothing where nothing is known.
                    var outside = 0, claimed = 0, off = 0.0
                    for index in magnitudes.indices {
                        let h = alongTime[index], p = alongFrequency[index]
                        let harmonic = Double(reference.harmonic[index]), percussive = Double(reference.percussive[index])
                        if !(harmonic >= 0 && harmonic <= 1 && percussive >= 0 && percussive <= 1 && harmonic + percussive <= 1 + 4 * Self.epsilon) { outside += 1 }
                        let expected: (Double, Double)
                        if let power = strategy.power {
                            // Neither median reaches the floor: no share for either side.
                            let expectedHarmonic = h >= floor || margins.0 * p >= floor ? 1 / (1 + pow(margins.0 * p / h, power)) : 0
                            let expectedPercussive = p >= floor || margins.1 * h >= floor ? 1 / (1 + pow(margins.1 * h / p, power)) : 0
                            expected = (expectedHarmonic.isNaN ? 0.5 : expectedHarmonic, expectedPercussive.isNaN ? 0.5 : expectedPercussive)
                        } else {
                            expected = (h > margins.0 * p && h >= floor ? 1 : 0, p > margins.1 * h && p >= floor ? 1 : 0)
                        }
                        // A hard mask flips where a median times its margin, rounded to single precision, ties with the other.
                        let tie = strategy.power == nil && (abs(h - margins.0 * p) <= 2 * Self.epsilon * h || abs(p - margins.1 * h) <= 2 * Self.epsilon * p)
                        if !tie { off = max(off, max(abs(harmonic - expected.0), abs(percussive - expected.1))) }
                        // Neither median reaches the floor, the competitor's times its margin
                        // included: exactly nothing for either side.
                        if margins.0 * p < floor, margins.1 * h < floor {
                            undivided += 1
                            if reference.harmonic[index] != 0 || reference.percussive[index] != 0 { claimed += 1 }
                        }
                        checked += 1
                    }
                    #expect(outside == 0, "\(name): \(outside) shares outside 0 … 1, not numbers, or claiming more than the bin")
                    #expect(claimed == 0, "\(name): \(claimed) shares of bins whose medians do not reach the floor")
                    #expect(off <= 1e-5, "\(name): a share off its definition by \(off)")
                    worst = max(worst, off)

                    // At any level: the ratio of the two medians is taken before any power, so a
                    // spectrogram 2⁷⁰ times smaller or 2⁹⁰ times larger has the same masks, bit for bit.
                    for exponent in [-70, 90] {
                        let factor = Float(sign: .plus, exponent: exponent, significand: 1)
                        let scaled = try await masks(magnitudes.map { $0 * factor }, strategy.mask, margins, floor: floor * Double(factor))
                        #expect(scaled.harmonic.map { $0.bitPattern } == reference.harmonic.map { $0.bitPattern }
                                && scaled.percussive.map { $0.bitPattern } == reference.percussive.map { $0.bitPattern }, "\(name): at 2^\(exponent) of the level")
                    }
                }
            }
            // What the definition gives when its powers are taken first, in single precision, at 2⁻⁷⁰ of the level.
            let factor = Float(sign: .plus, exponent: -70, significand: 1)
            for index in magnitudes.indices where alongTime[index] >= floor || alongFrequency[index] >= floor {
                let h = Float(alongTime[index]) * factor, p = Float(alongFrequency[index]) * factor
                let share = h * h / (h * h + p * p)
                if !(abs(Double(share) - 1 / (1 + pow(alongFrequency[index] / alongTime[index], 2))) <= 1e-3) { lostToPowers += 1 }
            }
        }
        print("measured stability WP-530: \(checked) pairs of shares within \(worst) of their definition; \(undivided) of them where neither median reaches the floor: exact zeros; at 2⁻⁷⁰ of the level \(lostToPowers) bins of the nine spectrograms are lost when the powers are taken before the ratio")
        #expect(undivided > 100_000 && lostToPowers > 10_000, "the library exercises both: \(undivided) shares without a denominator, \(lostToPowers) bins whose powers underflow")
    }

    // MARK: The streaming separation and its way back to samples (WP-531a, WP-532)

    @Test func theSeparationOfEveryStressSignalStaysWithinTheSpectrumAndStartsCold() throws {
        let bins = 513, kernel = 17
        var worstSum = 0.0, worstDefinition = 0.0, frameTotal = 0
        for fixture in StressFixture.signals(count: 8_192) {
            typealias Complex = Spectrum<LinearFrequency, ComplexValues>
            let spectrum = CollectingSink<Complex>(), harmonic = CollectingSink<Complex>(), percussive = CollectingSink<Complex>(), residual = CollectingSink<Complex>()
            let separation = Pipeline().stft(frame: 1_024, hop: 256).emit(to: spectrum)
                .tap { $0.harmonicPercussive(select: .harmonic, timeKernel: kernel, frequencyKernel: kernel, harmonicMargin: 2, percussiveMargin: 2).emit(to: harmonic) }
                .tap { $0.harmonicPercussive(select: .percussive, timeKernel: kernel, frequencyKernel: kernel, harmonicMargin: 2, percussiveMargin: 2).emit(to: percussive) }
                .harmonicPercussive(select: .residual, timeKernel: kernel, frequencyKernel: kernel, harmonicMargin: 2, percussiveMargin: 2).emit(to: residual)
            try separation.run(on: fixture.samples, format: mono48)
            #expect(spectrum.frameCount == 29 && harmonic.frameCount == 29 && percussive.frameCount == 29 && residual.frameCount == 29, "\(fixture.name): a frame out for every frame in")
            guard spectrum.frameCount == 29, harmonic.frameCount == 29, percussive.frameCount == 29, residual.frameCount == 29 else { continue }
            #expect(harmonic.times == spectrum.times && residual.times == spectrum.times, "\(fixture.name): causal, every frame keeps its time")

            // The causal medians by the oracle: of the frames so far, reflected at the start.
            let magnitudes = (0 ..< 29).map { frame in (0 ..< bins).map { hypotf(spectrum.reals[frame][$0], spectrum.imaginaries[frame][$0]) } }
            let alongTime = MedianOracle.running(magnitudes, kernel: kernel)
            var outside = 0, offSum = 0.0, offDefinition = 0.0
            for frame in 0 ..< 29 {
                let alongFrequency = MedianOracle.filter(magnitudes[frame], rowCount: bins, kernel: kernel, along: .frequency)
                let peak = Double(magnitudes[frame].max() ?? 0)
                for bin in 0 ..< bins {
                    let re = Double(spectrum.reals[frame][bin]), im = Double(spectrum.imaginaries[frame][bin]), size = hypot(re, im)
                    let parts = [harmonic, percussive, residual].map { (Double($0.reals[frame][bin]), Double($0.imaginaries[frame][bin])) }
                    // A share of the bin: never larger than it, never not a number; the three add up to it.
                    for part in parts where !(hypot(part.0, part.1) <= size * (1 + 4 * Self.epsilon) + Self.tiny) { outside += 1 }
                    let sum = hypot(parts[0].0 + parts[1].0 + parts[2].0 - re, parts[0].1 + parts[1].1 + parts[2].1 - im)
                    if size > 0 { offSum = max(offSum, sum / size) } else if sum != 0 { outside += 1 }
                    // The harmonic part by its definition: the bin times H² / (H² + (2·P)²), nothing under the floor.
                    let h = Double(alongTime[frame][bin]), p = 2 * Double(alongFrequency[bin])
                    let share = h >= 1e-10 || p >= 1e-10 ? 1 / (1 + (p / h) * (p / h)) : 0
                    if peak > 0 { offDefinition = max(offDefinition, hypot(parts[0].0 - share * re, parts[0].1 - share * im) / peak) }
                }
            }
            frameTotal += 29
            #expect(outside == 0, "\(fixture.name): \(outside) bins of a component larger than the bin they are a share of, or not numbers")
            #expect(offSum <= 8 * Self.epsilon && offDefinition <= 1e-5, "\(fixture.name): the components add up within \(offSum) of a bin; the harmonic part is within \(offDefinition) of the frame maximum of its definition")
            worstSum = max(worstSum, offSum)
            worstDefinition = max(worstDefinition, offDefinition)

            // A cold start forgets the frames the median was taken over (ACT-10).
            let once: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); HarmonicPercussive(select: .harmonic, timeKernel: kernel, frequencyKernel: kernel) }
                .process(fixture.samples, format: mono48)
            let twice = try twoPasses(
                of: Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); HarmonicPercussive(select: .harmonic, timeKernel: kernel, frequencyKernel: kernel) },
                on: fixture.samples, coldStart: true)
            #expect(twice.reals.count == 58 && Array(twice.reals[..<29]) == once && Array(twice.reals[29...]) == once, "\(fixture.name): after a cold start, the frames of a fresh stream")
        }
        print("measured stability WP-531a: \(frameTotal) frames of \(bins) bins: harmonic + percussive + residual within \(worstSum) of each bin; the harmonic part within \(worstDefinition) of the frame maximum of its definition")
    }

    @Test func theComponentsOfEveryStressSignalComeBackNoLargerThanTheSignal() throws {
        var worst = 0.0, worstName = ""
        for fixture in StressFixture.signals(count: 8_192) {
            let peak = Double(fixture.samples.map { abs($0) }.max() ?? 0)
            for alignment in [FrameAlignment.causal, .centered] {
                for component in HarmonicPercussiveComponent.allCases {
                    let output = try Pipeline { HPSS(select: component, frame: 1_024, hop: 256, timeKernel: 17, frequencyKernel: 17, alignment: alignment) }
                        .process(fixture.samples, format: mono48)
                    let largest = Double(output.map { abs($0) }.max() ?? 0)
                    #expect(output.count == 8_192 && output.allSatisfy { $0.isFinite }, "\(fixture.name), \(component), \(alignment)")
                    // A component is a share of every bin of every frame: resynthesised, it does
                    // not leave the range of the signal by more than the overshoot of a masked edge.
                    #expect(largest <= 1.5 * peak + 1e-30, "\(fixture.name), \(component), \(alignment): the component peaks at \(largest), the signal at \(peak)")
                    if peak > 1e-30, largest / peak > worst {
                        worst = largest / peak
                        worstName = "\(fixture.name), \(component), \(alignment)"
                    }
                }
            }
        }
        print("measured stability WP-532: the largest sample of a component is at most \(worst) times that of the signal (\(worstName))")
    }
}
