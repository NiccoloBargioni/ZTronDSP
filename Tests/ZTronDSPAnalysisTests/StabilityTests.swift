import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The stress tests of the stability notes of the spectral front-end (NUMS-2): one per `ALG`
/// package, each on fixtures of the stress library (WP-016), each failing when the mitigation
/// its note names is removed. The notes are `Docs/Numerics/real-fft.md`,
/// `spectral-centroid.md`, `mel-filter-bank.md`, `mel-projection.md`, `cepstrum.md`,
/// `complex-cepstrum.md`, `window-gains.md`, `window-smoothness.md`, `window-spectrum.md` and
/// `inversion-analysis.md`.
@Suite("Numerical stability")
struct StabilityTests {
    private static let signalNames = ["silence", "full-scale-sine", "full-scale-square", "dc", "nyquist", "decaying-tail", "denormal", "impulse", "white-noise"]

    private func signal(_ name: String, count: Int) throws -> [Float] {
        try #require(StressFixture.signals(count: count).first { $0.name == name }, "the stress library has no signal called \(name)").samples
    }

    // MARK: Row 1, the real FFT (WP-502)

    private func transform(_ signal: [Float]) throws -> (real: [Float], imaginary: [Float], back: [Float]) {
        let plan = try VDSPFFTBackend().makePlan(length: signal.count)
        var real = [Float](repeating: -1, count: plan.binCount), imaginary = real
        var back = [Float](repeating: -1, count: signal.count)
        signal.withUnsafeBufferPointer { source in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    plan.forward(source.baseAddress!, real: re.baseAddress!, imaginary: im.baseAddress!)
                    back.withUnsafeMutableBufferPointer { plan.inverse(real: re.baseAddress!, imaginary: im.baseAddress!, into: $0.baseAddress!) }
                }
            }
        }
        return (real, imaginary, back)
    }

    @Test(arguments: [16, 48, 80, 240, 1_024, 4_096, 16_384])
    func theErrorOfASinglePrecisionTransformIsAFloorUnderTheFrameMaximum(length: Int) throws {
        #expect(StressFixture.signals(count: length).map { $0.name } == StabilityTests.signalNames, "the library these tests were written against")
        var worstForward = 0.0, worstBack = 0.0
        for fixture in StressFixture.signals(count: length) {
            let spectrum = try transform(fixture.samples)
            let expected = try DSP.realDFT(fixture.samples.map(Double.init))
            #expect(spectrum.real.allSatisfy { $0.isFinite } && spectrum.imaginary.allSatisfy { $0.isFinite }, "\(fixture.name)")
            let deviation = complexDeviation(spectrum.real, spectrum.imaginary, expected.real, expected.imaginary)
            #expect(deviation <= 2.5e-7, "\(fixture.name), \(length) points: off by \(deviation) of the frame's largest bin")
            // And back: the signal, to a floor under its own peak.
            var worst = 0.0, peak = 0.0
            for (restored, sample) in zip(spectrum.back, fixture.samples) {
                worst = max(worst, abs(Double(restored) - Double(sample)))
                peak = max(peak, abs(Double(sample)))
            }
            #expect(worst <= 1.5e-6 * peak, "\(fixture.name), \(length) points: the round trip is off by \(peak > 0 ? worst / peak : worst) of the peak")
            worstForward = max(worstForward, deviation)
            worstBack = max(worstBack, peak > 0 ? worst / peak : worst)
        }
        print("measured stability row 1: \(length) points, worst over the stress signals: forward \(worstForward) of the frame's largest bin (bound 2.5e-7), forward then inverse \(worstBack) of the signal's peak (bound 1.5e-6)")
    }

    @Test func aBinFarBelowTheFrameMaximumIsKnownToAFloorOnly() throws {
        // A Hann-windowed full-scale sine has bins from its peak down to nothing.
        let length = 4_096
        let window = try Window.hann.samples(count: length)
        let frame = zip(try signal("full-scale-sine", count: length), window).map { $0 * $1 }
        let spectrum = try transform(frame)
        let expected = try DSP.realDFT(frame.map(Double.init))
        let peak = peakMagnitude(expected.real, expected.imaginary)
        var nearThePeak = 0.0, farBelow = 0.0
        // The largest error of a bin, of itself, by how far the bin lies below the frame maximum:
        // 0–60, 60–80, …, 140–160 dB and beyond (the table of the stability note).
        let bands: [Double] = [60, 80, 100, 120, 140, 160, .infinity]
        var byBand = [Double](repeating: 0, count: bands.count)
        for bin in spectrum.real.indices {
            let magnitude = hypot(expected.real[bin], expected.imaginary[bin])
            let error = hypot(Double(spectrum.real[bin]) - expected.real[bin], Double(spectrum.imaginary[bin]) - expected.imaginary[bin])
            #expect(error <= 2.5e-7 * peak, "bin \(bin)")
            if magnitude >= 1e-3 * peak { nearThePeak = max(nearThePeak, error / magnitude) }
            if magnitude <= 1e-7 * peak, magnitude > 0 { farBelow = max(farBelow, error / magnitude) }
            if magnitude > 0, let band = bands.firstIndex(where: { -20 * log10(magnitude / peak) <= $0 }) {
                byBand[band] = max(byBand[band], error / magnitude)
            }
        }
        #expect(nearThePeak <= 1e-4, "within 60 dB of the frame maximum a bin is right to \(nearThePeak) of itself")
        #expect(farBelow >= 0.5, "140 dB below it a bin is wrong by \(farBelow) of itself: a tolerance per bin would mean nothing (§6.1)")
        let table = zip([0.0] + bands.dropLast(), byBand).map { "\(Int($0.0)) dB and more below: \($0.1)" }
        print("measured stability row 1: a Hann-windowed full-scale sine of \(length) points, the largest error of a bin of itself, by distance below the frame maximum: \(table.joined(separator: "; "))")
    }

    @Test func decibelsOfEveryStressSignalAreNumbersAtOrAboveTheirFloor() throws {
        let window = try Window.hann.doubleSamples(count: 1_024)
        let factor = 2 / window.reduce(0, +)
        var worstOverall = 0.0
        defer { print("measured stability row 1: decibels of amplitude-normalised Hann frames of 1 024 samples of every stress signal, floor −80 dB: within \(worstOverall) dB of the definition in double precision (bound 0.05 dB)") }
        for fixture in StressFixture.signals(count: 8_192) {
            let powers = Pipeline { STFT(frame: 1_024, hop: 256, normalization: .amplitude); Power() }
            let plain: [[Float]] = try powers.decibels().process(fixture.samples, format: mono48)
            #expect(plain.count == 29 && plain.allSatisfy { $0.allSatisfy { $0.isFinite && Double($0) >= DSP.decibelFloor } },
                    "\(fixture.name): no value below the floor asked for, and none that is not a number (NUM-1)")

            // A floor 80 dB under full scale lies above the floor of the transform: single
            // precision then reads what the definition gives in double precision.
            let floored: [[Float]] = try powers.decibels(floor: -80).process(fixture.samples, format: mono48)
            var worst = 0.0
            for (index, frame) in floored.enumerated() {
                let windowed = (0 ..< 1_024).map { Double(fixture.samples[index * 256 + $0]) * window[$0] * factor }
                let spectrum = try DSP.realDFT(windowed)
                for bin in frame.indices {
                    let power = spectrum.real[bin] * spectrum.real[bin] + spectrum.imaginary[bin] * spectrum.imaginary[bin]
                    worst = max(worst, abs(Double(frame[bin]) - max(10 * log10(max(power, 1e-300)), -80)))
                }
            }
            #expect(floored.count == 29 && worst <= 0.05, "\(fixture.name): off by \(worst) dB at worst")
            worstOverall = max(worstOverall, worst)
        }
    }

    // MARK: Row 17, the spectral centroid (WP-507)

    @Test func theCentroidOfEveryStressSignalIsAFrequencyOrNothing() throws {
        let nyquist = 24_000.0, width = nyquist / 512
        var confident = 0, withoutEnergy = 0
        var worst: [String] = []
        for fixture in StressFixture.signals(count: 8_192) {
            let magnitudes = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), centroids = CollectingSink<Scalar>()
            try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); Emit(to: magnitudes); SpectralCentroid() }
                .emit(to: centroids).run(on: fixture.samples, format: mono48)
            #expect(centroids.scalars.count == 29 && magnitudes.reals.count == 29)
            var last: Float = 0
            var largest = 0.0, ofTheCentroid = 0.0
            for (index, frame) in centroids.scalars.enumerated() {
                let weights = magnitudes.reals[index].map(Double.init)
                let total = weights.reduce(0, +)
                if total > 1e-10 {
                    // The centroid of the same magnitudes in double precision: the two differ
                    // by round-off of sums of non-negative terms.
                    let expected = weights.enumerated().reduce(0) { $0 + Double($1.offset) * width * $1.element } / total
                    #expect(frame.confidence == 1 && frame.value >= 0 && Double(frame.value) <= nyquist, "\(fixture.name), frame \(index)")
                    #expect(abs(Double(frame.value) - expected) <= 8 * Double(Float.ulpOfOne) * nyquist,
                            "\(fixture.name), frame \(index): \(frame.value) Hz against \(expected) Hz")
                    if abs(Double(frame.value) - expected) >= largest {
                        largest = abs(Double(frame.value) - expected)
                        ofTheCentroid = expected > 0 ? largest / expected : 0
                    }
                    last = frame.value
                    confident += 1
                } else {
                    #expect(frame.confidence == 0 && frame.value == last && frame.value.isFinite,
                            "\(fixture.name), frame \(index): nothing to divide by, so the last value with confidence 0, not \(frame)")
                    withoutEnergy += 1
                }
            }
            // The same signal 180 dB down, under a floor its frames do not reach: no centroid.
            let quiet = CollectingSink<Scalar>()
            try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); SpectralCentroid(floor: 1e-3) }
                .emit(to: quiet).run(on: fixture.samples.map { $0 * 1e-9 }, format: mono48)
            #expect(quiet.scalars.count == 29 && quiet.scalars.allSatisfy { $0.confidence == 0 && $0.value == 0 },
                    "\(fixture.name) at −180 dB: a sum of weights under the floor is not divided by")
            if largest > 0 { worst.append("\(fixture.name) \(largest) Hz (\(ofTheCentroid) of the centroid)") }
        }
        #expect(confident > 100 && withoutEnergy > 100, "the library exercises both: \(confident) frames with a centroid, \(withoutEnergy) without")
        print("measured stability row 17: \(confident) frames with a centroid, \(withoutEnergy) without; the largest error against double precision: \(worst.joined(separator: "; "))")
    }

    @Test func theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing() throws {
        // Every signal of the library read as a spectrum of 513 magnitudes, |x| bin by bin, and
        // scaled by powers of two up to 2¹²⁶: weights that are all finite. The centroid does not
        // depend on the scale, but the sums do: the sum weighted by frequency (bins up to 24 kHz)
        // overflows a float before the sum of the weights does. A frame whose ratio is not
        // finite is not divided: the last value, with confidence 0 (NUM-1).
        let nyquist = 24_000.0, width = nyquist / 512, largestFloat = Double(Float.greatestFiniteMagnitude)
        func centroids(_ frames: [[Float]]) throws -> [ScalarFrame] {
            try Pipeline { FrameSequence<Spectrum<LinearFrequency, MagnitudeValues>>(frames, hop: 512, nyquist: nyquist); SpectralCentroid() }
                .process(FrameSequence<Spectrum<LinearFrequency, MagnitudeValues>>.drive(frames.count), format: mono48)
        }
        let library = StressFixture.signals(count: 513)
        let plain = library.map { $0.samples.map { abs($0) } }
        let unscaled = try centroids(plain)
        var lost: [String] = [], identical = 0, compared = 0, onlyTheRatio = 0, lostAtTheTop = 0
        for exponent in [0, 40, 80, 100, 110, 116, 120, 126] {
            let scale = Float(sign: .plus, exponent: exponent, significand: 1)
            let frames = plain.map { $0.map { $0 * scale } }
            #expect(frames.allSatisfy { $0.allSatisfy { $0.isFinite } }, "2^\(exponent): every weight is finite")
            let values = try centroids(frames)
            #expect(values.count == library.count && unscaled.count == library.count)
            guard values.count == library.count, unscaled.count == library.count else { continue }
            var last: Float = 0, without = 0
            for (index, frame) in values.enumerated() {
                let name = "\(library[index].name) × 2^\(exponent)"
                // Frames whose weighted sum is past the largest float while the sum of the weights
                // is not: there, only the guard on the ratio keeps the centroid finite.
                let scaled = frames[index].map(Double.init)
                if scaled.reduce(0, +) < largestFloat / 2, scaled.enumerated().reduce(0, { $0 + Double($1.offset) * width * $1.element }) > 2 * largestFloat {
                    onlyTheRatio += 1
                }
                #expect(frame.value.isFinite, "\(name): \(frame.value) Hz, confidence \(frame.confidence) (NUM-1)")
                if frame.confidence == 1 {
                    // Weights scaled by a power of two have the centroid of the weights.
                    let weights = plain[index].map(Double.init), total = weights.reduce(0, +)
                    let expected = weights.enumerated().reduce(0) { $0 + Double($1.offset) * width * $1.element } / total
                    #expect(frame.value >= 0 && Double(frame.value) <= nyquist && abs(Double(frame.value) - expected) <= 8 * Double(Float.ulpOfOne) * nyquist,
                            "\(name): \(frame.value) Hz against \(expected) Hz")
                    if unscaled[index].confidence == 1 {
                        compared += 1
                        if frame.value.bitPattern == unscaled[index].value.bitPattern { identical += 1 }
                    }
                    last = frame.value
                } else {
                    #expect(frame.confidence == 0 && frame.value == last, "\(name): no centroid, so the last value with confidence 0, not \(frame)")
                    if unscaled[index].confidence == 1 { without += 1 }
                }
            }
            lost.append("2^\(exponent): \(without)")
            lostAtTheTop = without
        }
        // The library reaches both overflows: frames that only the guard on the ratio keeps
        // finite, and frames with a centroid unscaled that have none at the top.
        #expect(onlyTheRatio > 0 && lostAtTheTop > 0, "\(onlyTheRatio) frames past the largest float in the weighted sum alone; \(lost)")
        print("measured stability row 17: the library scaled by powers of two up to 2^126: \(identical) of \(compared) centroids bit for bit those of the unscaled weights; \(onlyTheRatio) frames with the weighted sum past the largest float and the sum of the weights not; frames that had a centroid and have none, by scale: \(lost.joined(separator: ", "))")
    }

    // MARK: Row 18, the mel filter bank (WP-508)

    @Test func aBandThatCoversNoBinIsFoundAtEveryRateOfTheLibrary() throws {
        var found = 0, complete = 0
        var table: [String] = [], slopes = 0.0
        for filter in StressFixture.filtersNearZero + StressFixture.filtersNearNyquist {
            let nyquist = filter.sampleRate / 2
            // From the fixture's corner up for the corners near 0 Hz; up to it for those near Nyquist.
            let range = filter.cutoff < nyquist / 2 ? filter.cutoff ... nyquist : 0 ... filter.cutoff
            var row: [String] = []
            for frame in [256, 1_024, 4_096] {
                let bank = try MelFilterBank(bands: 128, binCount: frame / 2 + 1, nyquist: nyquist, range: range)
                row.append("\(frame): \(bank.bands.filter { $0.weights.isEmpty }.count) empty")
                // Hazard 3: a slope is a difference of nearby numbers over a half-width, a relative
                // error of about ε·f / width in double precision.
                for band in 0 ..< 128 {
                    let halfWidth = min(bank.edges[band + 1] - bank.edges[band], bank.edges[band + 2] - bank.edges[band + 1])
                    slopes = max(slopes, Double.ulpOfOne * bank.edges[band + 2] / halfWidth)
                }
                let width = filter.sampleRate / Double(frame)
                // By the definition: a band is empty when no bin lies strictly between its outer edges.
                let expected = (0 ..< 128).first { band in
                    !(0 ... frame / 2).contains { Double($0) * width > bank.edges[band] && Double($0) * width < bank.edges[band + 2] }
                }
                #expect(bank.firstEmptyBand == expected, "\(filter.name), \(frame) points")
                let dense = bank.denseWeights()
                #expect(dense.allSatisfy { $0 >= 0 && $0.isFinite }, "\(filter.name), \(frame) points: every weight is a non-negative number")
                for band in 0 ..< 128 {
                    let row = dense[band * bank.binCount ..< (band + 1) * bank.binCount]
                    #expect(row.allSatisfy { $0 == 0 } == bank.bands[band].weights.isEmpty, "\(filter.name), \(frame) points, band \(band)")
                }
                guard expected != nil else {
                    complete += 1
                    continue
                }
                found += 1
                // The advice the attach-time error gives is right: that length fills every band,
                // and the transform length before it does not.
                let filling = try #require(MelFilterBank.smallestFillingLength(edges: bank.edges, sampleRate: filter.sampleRate, above: frame))
                let shorter = try #require(DSP.previousFastLength(filling - 1))
                #expect(try MelFilterBank(bands: 128, binCount: filling / 2 + 1, nyquist: nyquist, range: range).firstEmptyBand == nil,
                        "\(filter.name): \(filling) points fill every band")
                #expect(try MelFilterBank(bands: 128, binCount: shorter / 2 + 1, nyquist: nyquist, range: range).firstEmptyBand != nil,
                        "\(filter.name): \(shorter) points do not")
            }
            let edges = try MelFilterBank(bands: 128, binCount: 129, nyquist: nyquist, range: range).edges
            let filling = MelFilterBank.smallestFillingLength(edges: edges, sampleRate: filter.sampleRate, above: 256).map(String.init) ?? "none"
            table.append("\(filter.name) \(range.lowerBound) … \(range.upperBound) Hz: \(row.joined(separator: ", ")), filled from \(filling)")
        }
        #expect(found >= 7 && complete >= 7, "the library exercises both: \(found) banks with an empty band, \(complete) without")
        print("measured WP-508: 128 bands, \(found) of \(found + complete) banks with an empty band; \(table.joined(separator: "; ")); the largest ε·f / half-width of a slope: \(slopes)")
    }

    @Test func theEdgesEndOnTheRangeItselfAtEveryRateOfTheLibrary() throws {
        // Hazard 2: hertz → mel → hertz does not give the ends of the range back exactly. The
        // bank sets them to the range itself: an upper edge above the Nyquist frequency would give
        // the last bin a weight, a lower edge below the range a bin under it.
        var banks = 0, inexact = 0
        func ends(_ formula: some MelFormula, _ name: String) throws {
            for filter in StressFixture.filtersNearZero + StressFixture.filtersNearNyquist {
                let nyquist = filter.sampleRate / 2
                for range in [0 ... nyquist, filter.cutoff ... nyquist, 0 ... filter.cutoff] {
                    for (bands, frame) in [(40, 4_096), (128, 16_384)] {
                        let bank = try MelFilterBank(bands: bands, binCount: frame / 2 + 1, nyquist: nyquist, range: range, formula: formula)
                        banks += 1
                        let label = "\(filter.name), \(name), \(bands) bands on \(range.lowerBound) … \(range.upperBound) Hz"
                        #expect(bank.edges.first == range.lowerBound && bank.edges.last == range.upperBound,
                                "\(label): the edges run from \(bank.edges.first ?? .nan) Hz to \(bank.edges.last ?? .nan) Hz")
                        // A bank that ends at the Nyquist frequency gives the last bin to no band;
                        // one that starts at 0 Hz gives bin 0 to none (hazard 4).
                        if range.upperBound == nyquist {
                            #expect(bank.bands.allSatisfy { $0.firstBin + $0.weights.count < bank.binCount }, "\(label): a band owns the bin at the Nyquist frequency")
                        }
                        if range.lowerBound == 0 {
                            #expect(bank.bands.allSatisfy { $0.weights.isEmpty || $0.firstBin > 0 }, "\(label): a band owns bin 0")
                        }
                        // What the round trip through the formula alone gives at the two ends.
                        let first = formula.mel(fromHertz: range.lowerBound), last = formula.mel(fromHertz: range.upperBound)
                        if formula.hertz(fromMel: first) != range.lowerBound { inexact += 1 }
                        if formula.hertz(fromMel: first + (last - first) * Double(bands + 1) / Double(bands + 1)) != range.upperBound { inexact += 1 }
                    }
                }
            }
        }
        try ends(SlaneyMelFormula(), "Slaney")
        try ends(HTKMelFormula(), "HTK")
        // The test can tell: the round trip alone misses some of these ends.
        #expect(inexact > 0, "the round trip alone misses \(inexact) of \(2 * banks) ends")
        print("measured WP-508: \(banks) banks at the rates and corners of the stress library, both formulas: each ends on its range; the round trip through the formula alone misses \(inexact) of their \(2 * banks) ends")
    }

    // MARK: Row 18, the mel projection (WP-535)

    @Test func theMelBandsOfEveryStressSignalAreSumsOfNonNegativeTerms() throws {
        let bank = try MelFilterBank(bands: 64, binCount: 513, nyquist: 24_000)
        let longest = bank.bands.map { $0.weights.count }.max() ?? 0
        var table: [String] = []
        for fixture in StressFixture.signals(count: 8_192) {
            let powers = Pipeline { STFT(frame: 1_024, hop: 256); Power() }
            let spectra: [[Float]] = try powers.process(fixture.samples, format: mono48)
            for implementation in [Implementation.native, .accelerate] {
                let mel: [[Float]] = try powers.melScale(bands: 64).environment(\.implementation, implementation).process(fixture.samples, format: mono48)
                #expect(mel.count == spectra.count && mel.count == 29)
                var worst = 0.0, wrong = 0
                for (index, frame) in mel.enumerated() {
                    for (band, run) in bank.bands.enumerated() {
                        var sum = 0.0
                        for (offset, weight) in run.weights.enumerated() { sum += Double(weight) * Double(spectra[index][run.firstBin + offset]) }
                        if !(frame[band] >= 0) || !frame[band].isFinite { wrong += 1 }
                        // Held against the band's own value: sums of non-negative terms do not cancel.
                        if sum > 0 { worst = max(worst, abs(Double(frame[band]) - sum) / sum) } else if frame[band] != 0 { wrong += 1 }
                    }
                }
                #expect(wrong == 0, "\(fixture.name), \(implementation): \(wrong) bands negative, not a number, or not zero where the spectrum is")
                #expect(worst <= Double(longest) * Double(Float.ulpOfOne), "\(fixture.name), \(implementation): off by \(worst) of the band, ε·bins is \(Double(longest) * Double(Float.ulpOfOne))")
                table.append("\(fixture.name) \(implementation) \(worst)")
            }
        }
        print("measured WP-535: 64 bands, the longest of \(longest) bins (ε·bins \(Double(longest) * Double(Float.ulpOfOne))); the largest error of a band, of the band: \(table.joined(separator: "; "))")

        // The hazard itself: a band without a bin, refused when the pipeline is attached, at
        // every sample rate of the library.
        for filter in StressFixture.filtersNearZero {
            let format = SignalFormat(sampleRate: filter.sampleRate)
            let edges = try MelFilterBank(bands: 128, binCount: 129, nyquist: filter.sampleRate / 2).edges
            let filling = try #require(MelFilterBank.smallestFillingLength(edges: edges, sampleRate: filter.sampleRate, above: 256))
            func attach(frame: Int) -> String? {
                errorMessage { let _: [[Float]] = try Pipeline { STFT(frame: frame, hop: frame / 4); Power(); MelScale(bands: 128) }.process(TestSignal.silence(count: 2 * frame), format: format) }
            }
            let message = try #require(attach(frame: 256), "\(filter.name): 128 bands on a frame of 256 samples leave a band without a bin")
            #expect(message.contains("band 0 of 128") && message.contains("a transform of \(filling) points is the smallest that fills every band"), "\(message)")
            #expect(attach(frame: filling) == nil, "\(filter.name): and \(filling) points do attach")
        }
    }

    // MARK: Row 19, the real and the power cepstrum (WP-509)

    /// The real cepstrum by its definition, in double precision, of the causal Hann frames: for
    /// each of `floors`, the frames of `samples`.
    private func cepstra(of samples: [Float], frame: Int, hop: Int, floors: [Double]) throws -> [[[Double]]] {
        let window = try Window.hann.doubleSamples(count: frame)
        var result = [[[Double]]](repeating: [], count: floors.count)
        var start = 0
        while start + frame <= samples.count {
            let spectrum = try DSP.realDFT((0 ..< frame).map { Double(samples[start + $0]) * window[$0] })
            let magnitudes = zip(spectrum.real, spectrum.imaginary).map { hypot($0, $1) }
            for (index, floor) in floors.enumerated() {
                let values = try DSP.inverseRealDFT(real: magnitudes.map { log(max($0, floor)) }, imaginary: [Double](repeating: 0, count: magnitudes.count))
                result[index].append(Array(values.prefix(frame / 2 + 1)))
            }
            start += hop
        }
        return result
    }

    @Test func theCepstrumOfEveryStressSignalIsBoundedByItsFloor() throws {
        let bound = -log(1e-10)         // |ln floor|: a frame is at most 512 at any bin, and ln 512 is less
        let floors = [1e-10, 1e-4, 1e-2, 1]
        var table: [String] = []
        var largestReal = 0.0, largestPower = 0.0
        for fixture in StressFixture.signals(count: 8_192) {
            let framing = Pipeline { STFT(frame: 1_024, hop: 256) }
            let real: [[Float]] = try framing.cepstrum(.real).process(fixture.samples, format: mono48)
            let power: [[Float]] = try framing.cepstrum(.power).process(fixture.samples, format: mono48)
            #expect(real.count == 29 && real.allSatisfy { $0.allSatisfy { $0.isFinite && abs(Double($0)) <= bound * (1 + 1e-6) } },
                    "\(fixture.name): a mean of logarithms that are at most |ln floor| each")
            #expect(power.count == 29 && power.allSatisfy { $0.allSatisfy { $0.isFinite && $0 >= 0 && Double($0) <= bound * bound * (1 + 1e-6) } }, "\(fixture.name)")
            largestReal = max(largestReal, real.joined().reduce(0) { max($0, abs(Double($1))) })
            largestPower = max(largestPower, power.joined().reduce(0) { max($0, Double($1)) })

            // Hazard 2, by the floor: single precision against the definition in double, of the
            // frame maximum. With the floor above the floor of the transform (10⁻² is 2·10⁻⁵ of
            // a full-scale frame's largest bin) single precision gives what the definition gives.
            let expected = try cepstra(of: fixture.samples, frame: 1_024, hop: 256, floors: floors)
            var row: [String] = []
            for (floor, reference) in zip(floors, expected) {
                let computed: [[Float]] = try framing.cepstrum(.real, floor: floor).process(fixture.samples, format: mono48)
                var worst = 0.0
                for (frame, exact) in zip(computed, reference) {
                    let peak = exact.reduce(0) { max($0, abs($1)) }
                    for (value, truth) in zip(frame, exact) where peak > 0 { worst = max(worst, abs(Double(value) - truth) / peak) }
                }
                #expect(computed.count == reference.count, "\(fixture.name), floor \(floor)")
                if floor >= 1e-2 { #expect(worst <= 1e-5, "\(fixture.name), floor \(floor): off by \(worst) of the frame maximum") }
                row.append("\(worst)")
            }
            table.append("\(fixture.name) \(row.joined(separator: " "))")
        }
        // Silence is the floor itself: its logarithm at quefrency 0 and nothing else.
        let silence: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Cepstrum(.real) }.process(try signal("silence", count: 8_192), format: mono48)
        #expect(silence.allSatisfy { abs(Double($0[0]) + bound) <= 1e-5 && $0.dropFirst().allSatisfy { abs($0) <= 1e-6 } })
        print("measured WP-509: the largest |value| of the real cepstrum \(largestReal) (|ln 1e-10| = \(bound)), of the power cepstrum \(largestPower); "
              + "hazard 2, of the frame maximum, at floors 1e-10, 1e-4, 1e-2 and 1: \(table.joined(separator: "; "))")
    }

    /// Hazard 2, the arithmetic: the logarithm and the transform back are double precision,
    /// and a value is rounded to single precision once, at the end. Handed the single-precision
    /// spectra of the stress library (WP-016), every value of the real cepstrum is its
    /// definition in double precision, from those spectra, rounded once.
    @Test func theRealCepstrumOfTheStressSpectraIsItsDefinitionRoundedOnce() throws {
        let window = try Window.hann.doubleSamples(count: 1_024)
        var real: [[Float]] = [], imaginary: [[Float]] = [], names: [String] = []
        for fixture in StressFixture.signals(count: 1_024) {
            let spectrum = try DSP.realDFT((0 ..< 1_024).map { Double(fixture.samples[$0]) * window[$0] })
            real.append(spectrum.real.map { Float($0) })
            imaginary.append(spectrum.imaginary.map { Float($0) })
            names.append(fixture.name)
        }
        var worst = 0.0, values = 0
        var beyond: Set<String> = []
        for floor in [1e-10, 1e-2] {
            let frames: [[Float]] = try Pipeline { ComplexFrameSequence(real: real, imaginary: imaginary, hop: 512); Cepstrum(.real, floor: floor) }
                .process([Float](repeating: 0, count: real.count * 512), format: mono48)
            #expect(frames.count == real.count && frames.allSatisfy { $0.count == 513 }, "floor \(floor): \(frames.count) frames")
            for (index, frame) in frames.enumerated() where index < real.count {
                let logarithm = zip(real[index], imaginary[index]).map { log(max(hypot(Double($0), Double($1)), floor)) }
                let exact = try DSP.inverseRealDFT(real: logarithm, imaginary: [Double](repeating: 0, count: logarithm.count))
                let scale = logarithm.reduce(0) { max($0, abs($1)) }
                for (value, truth) in zip(frame, exact) {
                    values += 1
                    // Half a unit in the last place of the value, and what two double-precision
                    // transforms may differ by.
                    let error = abs(Double(value) - truth), bound = Double(value.ulp) / 2 + 1e-13 * scale
                    worst = max(worst, error / bound)
                    if error > bound { beyond.insert("\(names[index]), floor \(floor)") }
                }
            }
        }
        #expect(beyond.isEmpty, "not the definition rounded once: \(beyond.sorted())")
        print("measured WP-509: \(values) values of the real cepstrum of the stress spectra, each its double-precision definition rounded once; "
              + "the largest error \(worst) of half a unit in the last place plus 1e-13 of the largest logarithm")
    }

    // MARK: Row 19, the complex cepstrum (WP-510)

    @Test func theComplexCepstrumOfEveryStressSignalInvertsOrSaysWhyNot() async throws {
        // Rectangular frames centred on every 64th sample: the impulse of the library sits at
        // sample 128, 64 and 0 of the first three.
        let framing = Pipeline { STFT(frame: 256, hop: 64, window: .rectangular, alignment: .centered) }
        var reports: [String: InversionReport] = [:]
        var table: [String] = []
        for fixture in StressFixture.signals(count: 4_096) {
            let frames: [[Float]] = try framing.cepstrum(.complex).process(fixture.samples, format: mono48)
            #expect(frames.count > 60 && frames.allSatisfy { $0.count == 258 && $0.allSatisfy { $0.isFinite } }, "\(fixture.name): no NaN, no infinity (NUM-1)")
            #expect(frames.allSatisfy { abs($0[256]) <= 0.5 && abs($0[257]) == 1 }, "\(fixture.name): a delay within the frame, and a sign")

            let report = try await Cepstrum(.complex).inversionReport(for: fixture.samples, sampleRate: 48_000, after: framing)
            let measured = try #require(report.measuredError)
            #expect(!measured.largestError.isNaN && !measured.relativeError.isNaN && measured.count == frames.count * 2 * 129, "\(fixture.name)")
            #expect(measured.relativeError <= report.predictedError,
                    "\(fixture.name): measured \(measured.relativeError), predicted \(report.predictedError)")
            if report.isExactlyInvertible {
                #expect(measured.relativeError <= 1e-5, "\(fixture.name): \(measured.relativeError) of the frame maximum")
            }
            reports[fixture.name] = report
            table.append("\(fixture.name) \(measured.relativeError) \(report.predictedError) [\(report.conditions.filter { !$0.holds }.map(\.name).joined(separator: ", "))]")
        }

        // What cannot come back is flagged, not hidden.
        for name in ["silence", "denormal", "dc"] {
            let report = try #require(reports[name])
            #expect(!report.isExactlyInvertible && report.conditions[1].name == "a finite log spectrum" && !report.conditions[1].holds, "\(name): bins at the floor")
        }
        #expect(reports["silence"]?.predictedError == .infinity, "nothing but the floor comes back from silence, and there is nothing to hold it against")
        let noise = try #require(reports["white-noise"])
        #expect(noise.isExactlyInvertible && !noise.conditions[2].holds && !noise.conditions[2].isNecessary, "the phase of noise has no one unwrapping: flagged, and still inverted")

        // The linear phase of a delay is taken out before the transform: what is left of an
        // impulse is nothing, wherever it sits in the frame, and the delay travels beside it.
        let impulse: [[Float]] = try framing.cepstrum(.complex).process(try signal("impulse", count: 4_096), format: mono48)
        for (frame, delay) in [(1, -64.0), (2, 0.0)] {
            #expect(impulse[frame][0 ..< 256].allSatisfy { abs($0) <= 1e-6 }, "frame \(frame): ln 1 at quefrency 0 and no ramp anywhere")
            #expect(abs(Double(impulse[frame][256]) * 256 - delay) <= 1e-3 && impulse[frame][257] == 1, "frame \(frame): a delay of \(delay) samples")
            table.append("impulse, frame \(frame): largest |value| \(impulse[frame][0 ..< 256].map { abs($0) }.max() ?? -1), delay \(Double(impulse[frame][256]) * 256), sign \(impulse[frame][257])")
        }
        table.append("impulse, frame 0: delay \(Double(impulse[0][256]) * 256), largest |value| \(impulse[0][0 ..< 256].map { abs($0) }.max() ?? -1)")
        print("measured WP-510: measured, predicted, conditions that fail: \(table.joined(separator: "; "))")
    }

    // MARK: Row 21, window analysis

    /// A stress signal as a window: sample `n` of the signal from `n / count` of the frame on.
    private func held(_ samples: [Double]) -> Window {
        let count = Double(samples.count)
        return .custom { time in samples[min(max(Int((time * count + 1e-9).rounded(.down)), 0), samples.count - 1)] }
    }

    private func held(_ name: String) throws -> Window {
        held(try signal(name, count: 1_024).map(Double.init))
    }

    /// Part 1, gains (WP-501d).
    @Test func theGainsOfEveryStressWindowAreNumbersOrNothing() async throws {
        var roundedOff = 0
        var sums: [String] = []
        for fixture in StressFixture.signals(count: 1_024) {
            let samples = fixture.samples.map(Double.init)
            let sum = samples.reduce(0, +), energy = samples.reduce(0) { $0 + $1 * $1 }, peak = samples.reduce(0) { max($0, abs($1)) }
            guard peak > 0 else {
                await #expect(throws: DSPError.self, "\(fixture.name): a window that is zero everywhere is a typed error (WIN-3)") {
                    _ = try await held(samples).analysis(frame: 1_024)
                }
                continue
            }
            let report = try await held(samples).analysis(frame: 1_024)
            #expect(report.samples == samples && report.peak == peak && report.isFinite, "\(fixture.name)")
            expectClose(report.coherentGain, sum / 1_024, .absolute(1e-15 * peak), "\(fixture.name)")
            expectClose(report.noiseGain, energy / 1_024, .relative(1e-12), "\(fixture.name)")
            expectClose(report.powerNormalization, (2 / (1_024 * energy)).squareRoot(), .relative(1e-12), "\(fixture.name)")
            #expect(report.leadingEdgeValue.isFinite && report.trailingEdgeValue.isFinite && report.tailLimit == nil)
            if abs(sum) > 1e-9 * 1_024 * peak {
                expectClose(try #require(report.equivalentNoiseBandwidth), 1_024 * energy / (sum * sum), .relative(1e-12), "\(fixture.name)")
                expectClose(try #require(report.amplitudeNormalization), 2 / abs(sum), .relative(1e-12), "\(fixture.name)")
            } else {
                #expect(report.equivalentNoiseBandwidth == nil && report.amplitudeNormalization == nil, "\(fixture.name): no sum, no figure that divides by it")
            }

            // The same window with its mean taken out, a tenth as high, sums to the round-off
            // of its samples, not to zero: still nothing to divide by, in the report and where
            // a framing step is attached.
            let mean = sum / 1_024
            let balanced = samples.map { ($0 - mean) * 0.1 }
            guard balanced.contains(where: { $0 != 0 }) else { continue }
            if balanced.reduce(0, +) != 0 { roundedOff += 1 }
            let window = held(balanced)
            let analysis = try await window.analysis(frame: 1_024)
            #expect(analysis.equivalentNoiseBandwidth == nil && analysis.amplitudeNormalization == nil && analysis.powerNormalization.isFinite,
                    "\(fixture.name) without its mean sums to \(analysis.coherentGain * 1_024)")
            #expect(throws: DSPError.self) { _ = try WindowNormalization.amplitude.factor(window: balanced, transformLength: 1_024) }
            #expect(try WindowNormalization.power.factor(window: balanced, transformLength: 1_024) == analysis.powerNormalization)
            let attached = errorMessage {
                let _: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256, window: window, normalization: .amplitude); Magnitude() }.process(TestSignal.silence(count: 2_048), format: mono48)
            }
            #expect(attached?.contains("no coherent gain") == true, "\(fixture.name): \(attached ?? "attached")")
            sums.append("\(fixture.name) \(analysis.coherentGain * 1_024)")
        }
        #expect(roundedOff >= 4, "the library exercises a sum that is round-off and not zero: \(roundedOff) windows")
        // The gains of a rectangle do not depend on its height, down to the subnormal range.
        let rectangle = try await held("dc").analysis(frame: 1_024), faint = try await held("denormal").analysis(frame: 1_024)
        #expect(faint.equivalentNoiseBandwidth == 1 && rectangle.equivalentNoiseBandwidth == 1 && faint.isSymmetric && faint.peak < 1e-40)
        print("measured WP-501d: \(roundedOff) windows without their mean sum to round-off, not to zero; the sums: \(sums.joined(separator: "; ")); "
              + "denormal: peak \(faint.peak), noise bandwidth \(String(describing: faint.equivalentNoiseBandwidth)), symmetric \(faint.isSymmetric)")
    }

    /// Part 1, outside the frame (WP-501d): the verdicts on the tail do not depend on the
    /// height of the function. A limit is told from zero against the function's own peak, so
    /// one shape gets one verdict from the subnormal height of the library (WP-016) up to 10³⁰.
    @Test func theTailOfAStressWindowIsJudgedAtEveryHeight() async throws {
        let faint = Double(try signal("denormal", count: 1_024).reduce(0) { max($0, abs($1)) })
        #expect(faint > 0 && faint < 1e-40, "the subnormal height of the library: \(faint)")
        let shapes: [(name: String, function: @Sendable (Double) -> Double)] = [
            ("Gaussian", { exp(-18 * ($0 - 0.5) * ($0 - 0.5)) }), ("constant", { _ in 1 }), ("settling", { 1 + 1 / (1 + abs($0)) }),
            ("1/|t|", { 1 / (1 + abs($0 - 0.5)) }), ("a hundredth outside", { (0 ... 1).contains($0) ? 1 : 0.01 }),
        ]
        func kind(_ limit: WindowAnalysis.TailLimit?) -> String {
            switch limit {
            case .zero?: "zero"
            case .value(let value)?: "value \(value)"
            case .unbounded?: "unbounded"
            case .undefined?: "undefined"
            case nil: "none"
            }
        }
        var table: [String] = [], verdicts: [String] = []
        for shape in shapes {
            let function = shape.function
            let reference = try await Window.custom(function).analysis(frame: 128, tail: function)
            verdicts.append(String(kind(reference.tailLimit).prefix { $0 != " " }))
            for scale in [faint, 1e-20, 1e20, 1e30] {
                let scaled: @Sendable (Double) -> Double = { function($0) * scale }
                let report = try await Window.custom(scaled).analysis(frame: 128, tail: scaled)
                let same: Bool
                switch (reference.tailLimit, report.tailLimit) {
                case (.value(let unscaled)?, .value(let value)?): same = abs(value - unscaled * scale) <= 1e-9 * abs(unscaled * scale)
                default: same = reference.tailLimit == report.tailLimit
                }
                #expect(same, "\(shape.name) × \(scale): \(kind(report.tailLimit)), not \(kind(reference.tailLimit)) scaled")
                let integrable = "\(String(describing: report.isAbsolutelyIntegrableOnLine)), square \(String(describing: report.isSquareIntegrableOnLine))"
                #expect(report.isAbsolutelyIntegrableOnLine == reference.isAbsolutelyIntegrableOnLine
                        && report.isSquareIntegrableOnLine == reference.isSquareIntegrableOnLine,
                        "\(shape.name) × \(scale): integrable on the line \(integrable)")
            }
            table.append("\(shape.name): \(kind(reference.tailLimit)), integrable \(String(describing: reference.isAbsolutelyIntegrableOnLine)), "
                         + "square integrable \(String(describing: reference.isSquareIntegrableOnLine))")
        }
        #expect(verdicts == ["zero", "value", "value", "zero", "value"], "the shapes tend to 0 or to a value: \(table)")
        print("measured WP-501d: the tail, the same verdict at \(faint), 1e-20, 1e20 and 1e30 of the height: \(table.joined(separator: "; "))")
    }

    /// Part 2, continuity and smoothness (WP-501e).
    @Test func theJumpsOfEveryStressWindowAreFoundWhereTheyAre() async throws {
        func jumps(_ name: String) async throws -> (smoothness: Int, places: [Double], sizes: [Double]) {
            let report = try await held(name).analysis(frame: 1_024)
            return (report.smoothness, report.discontinuities.map { $0.position * 1_024 }, report.discontinuities.map { $0.size })
        }
        func expectJumps(_ name: String, at places: [Double], of sizes: [Double], scale: Double = 1) async throws -> String {
            let found = try await jumps(name)
            #expect(found.smoothness == 0 && found.places.count == places.count, "\(name): \(found.places.count) jumps, not \(places.count)")
            var steps = 0.0, ends = 0.0
            for (index, place) in places.enumerated() where index < found.places.count {
                // Within the half step of the finest grid a jump is placed at: an eighth of a sample here.
                #expect(abs(found.places[index] - place) <= 0.125 + 1e-9 && abs(found.sizes[index] - sizes[index] * scale) <= 1e-9 * scale,
                        "\(name): a jump of \(found.sizes[index]) at sample \(found.places[index]), not of \(sizes[index] * scale) at \(place)")
                if place == 0 || place == 1_024 { ends = max(ends, abs(found.places[index] - place)) } else { steps = max(steps, abs(found.places[index] - place)) }
            }
            return "\(name) \(found.places.count) jumps (smoothness \(found.smoothness)), steps within \(steps), edges within \(ends) samples"
        }
        var table: [String] = []
        // The largest step a signal can take, every 24 samples; the edges of the frame count.
        let edges = stride(from: 24.0, to: 1_024, by: 24)
        table.append(try await expectJumps("full-scale-square", at: [0] + Array(edges) + [1_024], of: [1] + edges.map { _ in 2.0 } + [1]))
        table.append(try await expectJumps("dc", at: [0, 1_024], of: [1, 1]))
        table.append(try await expectJumps("impulse", at: [0, 1], of: [1, 1]))
        // Every sample a jump, each reported once and where it is.
        let alternating = stride(from: 1.0, to: 1_024, by: 1)
        table.append(try await expectJumps("nyquist", at: [0] + Array(alternating) + [1_024], of: [1] + alternating.map { _ in 2.0 } + [1]))
        // The same rectangle 860 dB down: a jump is a jump relative to the window, not to 1.
        let faint = Double(Float.leastNonzeroMagnitude) * 64
        table.append(try await expectJumps("denormal", at: [0, 1_024], of: [1, 1], scale: faint))

        // What the grids cannot resolve is not reported (WIN-6): a staircase whose steps are
        // small against the stencil of the next grid, and steps that each halve the one before.
        table.append(try await expectJumps("full-scale-sine", at: [1_024], of: [Double(try signal("full-scale-sine", count: 1_024)[1_023])]))
        table.append(try await expectJumps("decaying-tail", at: [0], of: [1]))
        print("measured WP-501e: \(table.joined(separator: "; "))")

        // The verdicts do not depend on the scale of the window: round-off is held against
        // the window's own peak and the step of the grid.
        let shapes: [(name: String, smoothness: Int, function: @Sendable (Double) -> Double)] = [
            ("Hann", 2, { 0.5 - 0.5 * cos(2 * .pi * $0) }), ("sin⁴", 4, { pow(sin(.pi * $0), 4) }), ("triangle", 1, { 1 - abs(2 * $0 - 1) }),
            ("step", 0, { $0 < 0.3 ? 1 : 0.25 }),
        ]
        for scale in [faint, 1e-20, 1, 1e20, 1e30] {
            for shape in shapes {
                let report = try await Window.custom { shape.function($0) * scale }.analysis(frame: 1_024)
                #expect(report.smoothness == shape.smoothness, "\(shape.name) × \(scale): smoothness \(report.smoothness), not \(shape.smoothness)")
                // The mirror image is judged against the window's own peak as well.
                #expect(report.isSymmetric == (shape.name != "step"), "\(shape.name) × \(scale): symmetric \(report.isSymmetric)")
                if shape.name == "step" {
                    #expect(report.discontinuities.count == 3 && abs(report.discontinuities[1].position - 0.3) <= 1.0 / 1_024
                            && abs(report.discontinuities[1].size / scale - 0.75) <= 1e-9, "× \(scale): \(report.discontinuities)")
                } else {
                    #expect(report.discontinuities.isEmpty, "\(shape.name) × \(scale): \(report.discontinuities)")
                }
            }
        }
    }

    /// Part 3, the spectrum and the overlap-add sums (WP-501f).
    @Test func theSpectralFiguresOfEveryStressWindowAreNumbersOrNothing() async throws {
        var reports: [String: [Int: WindowAnalysis]] = [:]
        for fixture in StressFixture.signals(count: 1_024) where fixture.name != "silence" {
            for hop in [1, 256, 1_024] {
                let report = try await held(fixture.samples.map(Double.init)).analysis(frame: 1_024, hop: hop)
                #expect(report.spectrum.count == 8_193 && report.spectrum.allSatisfy { $0.isFinite && $0 >= -400 }, "\(fixture.name): the spectrum has a floor, 400 dB down")
                #expect(report.mainLobeWidthAtHalfPower.isFinite && report.mainLobeWidthAtHalfPower > 0 && report.scallopingLoss.isFinite, "\(fixture.name)")
                for figure in [report.mainLobeWidthNullToNull, report.peakSideLobe, report.sideLobeFallOff, report.overlapRipple, report.frameBoundRatio] {
                    #expect(figure?.isFinite != false, "\(fixture.name), hop \(hop): a figure is a number or nothing, not \(String(describing: figure))")
                }
                #expect(report.overlapRipple != nil && report.isConstantOverlapAdd != nil)
                #expect((report.frameBoundRatio == nil) == (report.isNonZeroOverlapAdd == false), "\(fixture.name), hop \(hop): a ratio exactly when no sum is zero")
                #expect((report.frameBoundRatio ?? 1) >= 1)
                reports[fixture.name, default: [:]][hop] = report
            }
        }
        // One sample: a flat spectrum. No null, no side lobe, nothing lost off a bin centre.
        let impulse = try #require(reports["impulse"]?[1])
        #expect(impulse.mainLobeWidthNullToNull == nil && impulse.peakSideLobe == nil && impulse.sideLobeFallOff == nil && impulse.scallopingLoss == 0)
        #expect(impulse.spectrum.allSatisfy { abs($0) <= 1e-9 } && impulse.isNonZeroOverlapAdd == true && impulse.isConstantOverlapAdd == true && impulse.frameBoundRatio == 1)
        #expect(reports["impulse"]?[256]?.isNonZeroOverlapAdd == false, "at any longer hop most samples are weighed by nothing")
        // No sum: no power at 0 Hz to refer to. The spectrum is then relative to its largest value.
        let alternating = try #require(reports["nyquist"]?[256])
        #expect(alternating.spectrum[0] == -400 && alternating.spectrum.max() == 0 && alternating.spectrum[8_192] == 0)
        // A rectangle, and the same rectangle 860 dB down: the figures are those of the shape.
        let rectangle = try #require(reports["dc"]?[256]), faint = try #require(reports["denormal"]?[256])
        expectClose(try #require(rectangle.peakSideLobe), -13.26, .absolute(0.01))
        expectClose(try #require(rectangle.mainLobeWidthNullToNull), 2, .absolute(1e-9))
        expectClose(faint.spectrum, rectangle.spectrum, .absolute(1e-6))
        #expect(faint.peakSideLobe == rectangle.peakSideLobe && faint.mainLobeWidthNullToNull == rectangle.mainLobeWidthNullToNull
                && faint.scallopingLoss == rectangle.scallopingLoss && faint.isConstantOverlapAdd == true && faint.frameBoundRatio == 1)
        // A tail that decays to exact zeros inside the frame: at a hop of the frame some
        // samples are weighed by nothing; at a hop of one sample every sum is the same.
        #expect(reports["decaying-tail"]?[1_024]?.isNonZeroOverlapAdd == false && reports["decaying-tail"]?[1_024]?.frameBoundRatio == nil)
        #expect(reports["decaying-tail"]?[1]?.isNonZeroOverlapAdd == true && reports["decaying-tail"]?[1]?.frameBoundRatio == 1)
        let apart = zip(faint.spectrum, rectangle.spectrum).map { abs($0 - $1) }.max() ?? -1
        print("measured WP-501f: \(reports.count) windows, \(reports.values.map(\.count).reduce(0, +)) reports; dc: peak side lobe \(String(describing: rectangle.peakSideLobe)) dB, "
              + "\(String(describing: rectangle.mainLobeWidthNullToNull)) bins between the nulls; denormal within \(apart) dB of it; impulse: largest |level| \(impulse.spectrum.map { abs($0) }.max() ?? -1) dB; "
              + "nyquist: \(alternating.spectrum[0]) dB at 0 Hz, \(alternating.spectrum[8_192]) dB at the Nyquist bin; the lowest level of any spectrum "
              + "\(reports.values.flatMap { $0.values }.map { $0.spectrum.min() ?? 0 }.min() ?? 0) dB")
    }

    /// Part 3, the first null (WP-501f), placed between the points of the padded transform.
    /// The rectangle of the library (`dc`, WP-016) cut short to `n` of the frame's 1 024
    /// samples has its first null 1 024 / n bins out, between two points of the transform
    /// padded sixteen times; the nearest point lies up to half a step, 1/32 of a bin, away.
    @Test func theNullOfATruncatedRectangleIsFoundBetweenThePointsOfTheGrid() async throws {
        let dc = try signal("dc", count: 1_024).map(Double.init)
        var table: [String] = []
        for ones in [1_000, 999, 900, 700, 513] {
            let report = try await held(Array(dc.prefix(ones)) + [Double](repeating: 0, count: 1_024 - ones)).analysis(frame: 1_024)
            let width = try #require(report.mainLobeWidthNullToNull, "\(ones) samples: a null")
            let truth = 2 * 1_024 / Double(ones)
            #expect(abs(width - truth) <= 2.5e-3, "\(ones) samples: \(width) bins between the nulls, not \(truth)")
            table.append("\(ones) samples \(width) (\(truth))")
        }
        print("measured WP-501f: the null-to-null width of the library's rectangle cut short, in bins (the truth): \(table.joined(separator: "; "))")
    }

    // MARK: Row 22, inversion analysis (WP-537, WP-538)

    @Test func whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal() async throws {
        // Frame-bound ratios B/A from 1 to 10⁸: a Hann window on a pedestal, at a hop of one
        // frame, has Σ w² between pedestal² and 1.
        func pedestal(_ level: Double) -> Window { .custom { level + (1 - level) * (0.5 - 0.5 * cos(2 * .pi * $0)) } }
        let analyses: [(stft: STFT, ratio: Double)] = [
            (STFT(frame: 1_024, hop: 256), 1), (STFT(frame: 1_024, hop: 700), 9.6745),
            (STFT(frame: 1_024, hop: 1_024, window: pedestal(1e-2)), 1e4), (STFT(frame: 1_024, hop: 1_024, window: pedestal(1e-4)), 1e8),
        ]
        var worst: [Double] = []
        var table: [String] = []
        for analysis in analyses {
            var largest = 0.0
            var ratios: [Double] = [], predicted: Set<Double> = [], exact: [String] = [], units = 0.0, ofPeak = 0.0, reported = 0.0
            for fixture in StressFixture.signals(count: 16_384) {
                let report = try await analysis.stft.inversionReport(for: fixture.samples, sampleRate: 48_000)
                let condition = report.conditions[0]
                #expect(condition.name == "non-zero overlap-add" && condition.holds && report.isExactlyInvertible)
                expectClose(1 / condition.observed, analysis.ratio, .relative(1e-3), "the frame-bound ratio B/A is reported")
                reported = 1 / condition.observed
                let measured = try #require(report.measuredError)
                #expect(measured.largestError.isFinite && measured.relativeError.isFinite && !measured.signalToNoiseRatio.isNaN, "\(fixture.name)")
                if fixture.name == "denormal" {
                    // A signal of subnormal numbers lies below what a relative bound speaks of:
                    // its error is a few units of the smallest number there is.
                    #expect(measured.largestError <= 128 * Double(Float.leastNonzeroMagnitude), "\(measured.largestError)")
                    units = measured.largestError / Double(Float.leastNonzeroMagnitude)
                    ofPeak = measured.relativeError
                } else {
                    #expect(measured.relativeError <= report.predictedError,
                            "\(fixture.name), B/A \(analysis.ratio): measured \(measured.relativeError), predicted \(report.predictedError)")
                    // The prediction is the note's: 16·ε·log₂ M of round-off for the transform and
                    // its inverse, amplified by B/A, and never more than everything.
                    expectClose(report.predictedError, min(16 * Double(Float.ulpOfOne) * log2(1_024) / condition.observed, 1), .relative(1e-9),
                                "\(fixture.name), B/A \(analysis.ratio): the prediction of inversion-analysis.md")
                    largest = max(largest, measured.relativeError)
                    predicted.insert(report.predictedError)
                    if measured.signalToNoiseRatio.isFinite { ratios.append(measured.signalToNoiseRatio) } else { exact.append(fixture.name) }
                }
            }
            worst.append(largest)
            table.append("B/A \(reported): measured \(largest), "
                         + "SNR \(ratios.min() ?? -1) to \(ratios.max() ?? -1) dB, predicted \(predicted.sorted()), exact \(exact), denormal \(units) units (\(ofPeak) of its peak)")
        }
        // The hazard is there: the error grows with the ratio, a hundredfold from end to end.
        #expect(worst[0] <= 1e-6 && worst[3] >= 100 * worst[0], "measured, by ratio: \(worst)")

        // Where Σ w² falls below the floor the samples are reported lost: nothing is divided
        // by next to nothing, and the measured error is that of losing them.
        let lost = STFT(frame: 1_024, hop: 1_024, window: pedestal(1e-6))
        for name in ["full-scale-sine", "dc", "white-noise", "silence"] {
            let report = try await lost.inversionReport(for: try signal(name, count: 16_384), sampleRate: 48_000)
            let measured = try #require(report.measuredError)
            #expect(!report.conditions[0].holds && report.conditions[0].margin < 0 && !report.isExactlyInvertible && report.predictedError == 1)
            #expect(measured.relativeError <= 1 && measured.largestError <= 1, "\(name): \(measured.relativeError)")
            table.append("lost, \(name): \(measured.relativeError) of the peak, margin \(report.conditions[0].margin)")
        }

        // What a round trip can show at all: about 140 dB on a tight frame.
        let tight = try await STFT(frame: 1_024, hop: 256).inversionReport(for: try signal("full-scale-sine", count: 16_384), sampleRate: 48_000)
        #expect((tight.measuredError?.signalToNoiseRatio ?? 0) >= 130)
        print("measured WP-537: \(table.joined(separator: "; ")); a tight frame, full-scale-sine: \(tight.measuredError?.signalToNoiseRatio ?? -1) dB")
    }
}
