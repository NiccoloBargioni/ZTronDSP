import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The stress tests of the stability notes of the constant-Q transform (NUMS-2): one per `ALG`
/// package of WP-518 … WP-523, each on fixtures of the stress library (WP-016), each failing
/// when the mitigation its note names is removed. The notes are
/// `Docs/Numerics/constant-q-kernel.md`, `half-band-decimator.md`, `sparse-kernel-product.md`,
/// `constant-q-transform.md` and `constant-q-scale.md`.
@Suite("Numerical stability of the constant-Q transform")
struct ConstantQStabilityTests {
    typealias ConstantQSpectrum = Spectrum<ConstantQFrequency, ComplexValues>

    private static let signalNames = ["silence", "full-scale-sine", "full-scale-square", "dc", "nyquist", "decaying-tail", "denormal", "impulse", "white-noise"]

    /// How many octaves from `fmin` keep the highest bin below 0.74 of the Nyquist frequency,
    /// where its kernel is clear of what the decimators do not keep clean.
    private func octaves(above fmin: Double, sampleRate: Double) -> Int {
        var octaves = 1
        while fmin * pow(2, Double(octaves + 1)) < 0.74 * sampleRate / 2 { octaves += 1 }
        return octaves
    }

    // MARK: Row 13, the sparse kernel (WP-518)

    @Test func aKernelKeepsItsEnergyAtEveryCornerOfTheStressLibrary() throws {
        // From each corner near 0 Hz up: as many octaves as fit, at each sample rate of the library.
        var rows = 0
        for filter in StressFixture.filtersNearZero {
            let count = octaves(above: filter.cutoff, sampleRate: filter.sampleRate)
            let geometry = try ConstantQGeometry(minimumFrequency: filter.cutoff, octaves: count, sampleRate: filter.sampleRate)
            #expect(count >= 7 && geometry.atomLength(ofBin: 0) > 25_000, "\(filter.name): \(count) octaves, the lowest atom \(geometry.atomLength(ofBin: 0)) samples")
            var entries: [Int] = []
            var leastKept = 1.0
            for sparsity in [0, 0.01, 0.3, 0.9, 0.999] {
                let kernel = try ConstantQKernel(geometry: geometry, octave: 0, sparsity: sparsity)
                let least = kernel.keptEnergy.min() ?? 0
                leastKept = min(leastKept, least)
                #expect(least >= ConstantQKernel.keptEnergyFloor, "\(filter.name), sparsity \(sparsity): a row keeps \(least) of its energy")
                #expect(kernel.span < 2_048 && kernel.real.allSatisfy { $0.isFinite } && kernel.imaginary.allSatisfy { $0.isFinite }, "\(filter.name): the recursion keeps every atom short")
                entries.append(kernel.nonZeroCount)
                rows += kernel.rowCount
            }
            #expect(entries == entries.sorted(by: >) && entries[4] == entries[2], "\(filter.name): from 0.3 on the energy decides: \(entries)")
            print("measured WP-518: \(filter.name): \(count) octaves from \(filter.cutoff) Hz at \(filter.sampleRate) Hz, the lowest atom \(geometry.atomLength(ofBin: 0)) samples; entries kept at sparsities 0, 0.01, 0.3, 0.9, 0.999: \(entries); the least share of its energy a row keeps: \(leastKept)")
            // An octave more, and the highest bins lie where the decimators do not keep the band clean.
            let above = try ConstantQGeometry(minimumFrequency: filter.cutoff, octaves: count + 1, sampleRate: filter.sampleRate)
            let refused = errorMessage { _ = try ConstantQKernel(geometry: above, octave: count) }
            #expect(refused?.contains("0.8 of the Nyquist frequency") == true, "\(filter.name), \(count + 1) octaves: \(refused ?? "accepted")")
        }
        #expect(rows == 4 * 5 * 36)

        // The corners near the Nyquist frequency, as the highest bin of one octave, which has no decimator.
        for filter in StressFixture.filtersNearNyquist {
            let share = filter.cutoff / filter.sampleRate
            let geometry = try ConstantQGeometry(minimumFrequency: filter.cutoff / pow(2, 35.0 / 36), octaves: 1, sampleRate: filter.sampleRate)
            let refused = errorMessage { _ = try ConstantQKernel(geometry: geometry, octave: 0) }
            if share <= 0.45 {
                #expect(refused == nil, "\(filter.name): \(refused ?? "")")
                let least = try ConstantQKernel(geometry: geometry, octave: 0, sparsity: 0.9).keptEnergy.min() ?? 0
                #expect(least >= ConstantQKernel.keptEnergyFloor, "\(filter.name): a row keeps \(least)")
                print("measured WP-518: \(filter.name): the highest bin of one octave at \(share) of the sample rate is kept; at sparsity 0.9 the least share of its energy a row keeps is \(least)")
            } else {
                // At 0.49 of the sample rate the transform of the atom reaches across the Nyquist frequency.
                #expect(refused?.contains("too close to the Nyquist frequency") == true, "\(filter.name): \(refused ?? "accepted")")
            }
            // Two octaves have a decimator, which keeps the band clean up to 0.8 of it only.
            let halved = try ConstantQGeometry(minimumFrequency: filter.cutoff / pow(2, 71.0 / 36), octaves: 2, sampleRate: filter.sampleRate)
            #expect(errorMessage { _ = try ConstantQKernel(geometry: halved, octave: 1) }?.contains("half-band decimators") == true, "\(filter.name)")
        }
    }

    /// The kernel is computed in double precision and rounded to single once (register audit,
    /// WP-905c). At every corner of `StressFixture.filtersNearZero` each part of a kept entry is
    /// within half a unit in the last place of single precision of its value by the definition,
    /// the transform of its atom summed here in double precision. An entry rounded twice, once
    /// to single and once more after the scaling by 1/N, is off by up to a unit.
    @Test func everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary() throws {
        var parts = 0, worst = 0.0
        for filter in StressFixture.filtersNearZero {
            let count = octaves(above: filter.cutoff, sampleRate: filter.sampleRate)
            let geometry = try ConstantQGeometry(minimumFrequency: filter.cutoff, octaves: count, sampleRate: filter.sampleRate)
            let kernel = try ConstantQKernel(geometry: geometry, octave: 0)
            let length = kernel.transformLength
            var outside = 0
            for row in 0 ..< kernel.rowCount {
                let atom = referenceAtom(length: kernel.atomLengths[row], cyclesPerSample: geometry.normalizedFrequency(atPosition: row))
                let range = kernel.rowStarts[row] ..< kernel.rowStarts[row + 1]
                var exact: [(real: Double, imaginary: Double)] = []
                for index in range {
                    // conj(Σ a[i] e^(−j2πbi/N)) / N with the atom centred on sample `center`.
                    let bin = kernel.columns[index]
                    var sumReal = 0.0, sumImaginary = 0.0
                    for sample in 0 ..< atom.real.count {
                        let position = kernel.center + atom.first + sample
                        let angle = -2 * Double.pi * Double((bin * position) % length) / Double(length)
                        sumReal += atom.real[sample] * cos(angle) - atom.imaginary[sample] * sin(angle)
                        sumImaginary += atom.real[sample] * sin(angle) + atom.imaginary[sample] * cos(angle)
                    }
                    exact.append((sumReal / Double(length), -sumImaginary / Double(length)))
                }
                let peak = exact.reduce(0) { max($0, hypot($1.real, $1.imaginary)) }
                for (offset, index) in range.enumerated() {
                    for (stored, value) in [(kernel.real[index], exact[offset].real), (kernel.imaginary[index], exact[offset].imaginary)] {
                        // Half a unit, and what two sums in double precision may differ by.
                        let error = abs(Double(stored) - value), slack = 1e-12 * peak
                        if error > 0.5 * Double(stored.ulp) + slack { outside += 1 }
                        if 0.5 * Double(stored.ulp) > slack { worst = max(worst, error / Double(stored.ulp)) }
                        parts += 1
                    }
                }
            }
            #expect(outside == 0, "\(filter.name), a transform of \(length) points: \(outside) of \(2 * kernel.nonZeroCount) parts are not their value rounded once")
        }
        print("measured WP-518: \(parts) parts of the kept entries at the corners of the library; the worst is \(worst) of a unit in the last place of single precision from its value by the definition")
    }

    // MARK: Row 13, the half-band decimators (WP-519)

    @Test func noStressSignalAliasesThroughTheDecimators() throws {
        let taps = try HalfBand.taps().map { Float($0) }
        let reach = taps.reduce(0) { $0 + abs(Double($1)) }
        #expect(StressFixture.signals(count: 16).map { $0.name } == ConstantQStabilityTests.signalNames, "the library these tests were written against")
        for fixture in StressFixture.signals(count: 32_768) {
            var signal = fixture.samples
            var bound = Double(signal.reduce(0) { max($0, abs($1)) })
            var levels: [Double] = []
            for depth in 0 ..< 6 {
                signal = halved(signal, by: try HalfBandDecimator(taps: taps))
                // An output is a sum of taps times samples: no larger than Σ|h| times the largest sample.
                bound *= reach
                #expect(signal.count == 32_768 >> (depth + 1), "\(fixture.name), depth \(depth)")
                #expect(signal.allSatisfy { $0.isFinite && Double(abs($0)) <= bound * (1 + 1e-6) }, "\(fixture.name), depth \(depth): finite and bounded")
                let settled = signal[min(taps.count, signal.count)...]
                levels.append(Double(settled.reduce(0) { max($0, abs($1)) }))
                switch fixture.name {
                case "silence", "denormal":
                    #expect(signal.allSatisfy { $0 == 0 }, "\(fixture.name), depth \(depth): zeros")
                case "dc":
                    #expect(settled.allSatisfy { abs($0 - 1) <= 1e-5 }, "depth \(depth): a constant passes at its own level")
                case "nyquist":
                    let leak = Double(settled.reduce(0) { max($0, abs($1)) })
                    #expect(leak <= 1e-4, "depth \(depth): a full-scale tone at the Nyquist frequency leaves at \(20 * log10(max(leak, 1e-30))) dB; 80 dB down is asked for")
                case "full-scale-sine", "full-scale-square":
                    // A tone of 997 Hz, and a square wave of 1 kHz with its odd harmonics. They
                    // lie in the pass band of the first four decimators; the fifth halves a
                    // signal sampled at 3 kHz, whose stop band begins at 900 Hz: there the tone
                    // and the fundamental of the square wave fold onto 500 Hz unless they are
                    // removed, and the harmonics have gone the same way before.
                    let level = Double(settled.reduce(0) { max($0, abs($1)) })
                    let fundamental = fixture.name == "full-scale-sine" ? 1 : 4 / Double.pi
                    if depth >= 4 {
                        #expect(level <= 1e-4 * fundamental, "\(fixture.name), depth \(depth): what would fold leaves at \(20 * log10(max(level / fundamental, 1e-30))) dB; 80 dB down is asked for")
                    } else if fixture.name == "full-scale-sine" {
                        #expect(level >= 0.995 && level <= 1.001, "depth \(depth): a tone in the pass band passes at its own level, not at \(level)")
                    }
                default:
                    break
                }
            }
            print("measured WP-519: \(fixture.name) through six decimators, the largest settled sample after each: \(levels.map { $0 > 0 ? String(format: "%.2f dB", 20 * log10($0)) : "0" })")
        }
    }

    @Test func aToneThatWouldFoldOntoABinOfALowerOctaveIsNotSeen() throws {
        // The decimator that makes the octave at `depth` halves the rate fs / 2^(depth − 1). A
        // tone at half that rate less the frequency of a bin would fold onto the bin, in that
        // octave and in every octave below it, if the filter let it through. The signal is
        // long enough for the frame read to lie wholly inside the tone: its onset is no alias.
        let rate = 22_050.0
        let step = ConstantQ()
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: rate)
        var worst = 0.0
        for depth in 1 ... 6 {
            for position in [0, 17, 35] {
                let bin = (6 - depth) * 36 + position
                let alias = rate / pow(2, Double(depth)) - geometry.frequency(ofBin: bin)
                #expect(alias > 0.6 * rate / pow(2, Double(depth)), "the stop band of that decimator")
                let tone = TestSignal.sine(frequency: alias, sampleRate: rate, count: 60_000, phase: 0.2)
                let sink = try complexFrames(of: Pipeline { step }, on: tone, format: SignalFormat(sampleRate: rate))
                let last = try #require(sink.reals.indices.last)
                // The octaves from this depth down: the tone lies above all they can hold.
                let read = Array(magnitudes(sink.reals[last], sink.imaginaries[last])[..<((7 - depth) * 36)])
                worst = max(worst, read.max() ?? 0)
                #expect(read[bin] <= 1e-4, "a full-scale tone at \(alias) Hz reads \(20 * log10(max(read[bin], 1e-30))) dB in bin \(bin), which it would fold onto")
            }
        }
        #expect(worst <= 1e-4, "no bin below a stop band reads more than \(20 * log10(max(worst, 1e-30))) dB of a tone in it; 80 dB down is asked for (§7.5 row 13)")
        print("measured WP-519: a full-scale tone that would fold onto a bin of the octave at depth 1 … 6 reads at most \(20 * log10(max(worst, 1e-30))) dB in any bin of that octave or one below it")
    }

    // MARK: Row 13, the product (WP-520)

    @Test func theProductOfEveryStressSpectrumIsWithinTheBoundOfItsTerms() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        let kernel = try ConstantQKernel(geometry: geometry, octave: 6)
        let product = try SparseKernelProduct(kernel)
        let plan = try VDSPFFTBackend().makePlan(length: kernel.transformLength)
        let bins = kernel.columnCount
        let rowLengths = (0 ..< kernel.rowCount).map { kernel.rowStarts[$0 + 1] - kernel.rowStarts[$0] }
        print("measured WP-520: the kernel of the defaults at 48 kHz: \(kernel.rowCount) rows, \(kernel.nonZeroCount) entries, \(rowLengths.min() ?? 0) to \(rowLengths.max() ?? 0) a row, columns \(kernel.columns.min() ?? 0) … \(kernel.columns.max() ?? 0)")
        var worstShare = 0.0
        for fixture in StressFixture.signals(count: kernel.transformLength) {
            var fixtureWorst = 0.0
            var real = [Float](repeating: 0, count: bins), imaginary = real
            fixture.samples.withUnsafeBufferPointer { source in
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in plan.forward(source.baseAddress!, real: re.baseAddress!, imaginary: im.baseAddress!) }
                }
            }
            for scale in [Float(1), 0x1p-40, 0x1p40] {
                let scaledReal = real.map { $0 * scale }, scaledImaginary = imaginary.map { $0 * scale }
                var resultReal = [Float](repeating: .nan, count: kernel.rowCount), resultImaginary = resultReal
                scaledReal.withUnsafeBufferPointer { xr in
                    scaledImaginary.withUnsafeBufferPointer { xi in
                        resultReal.withUnsafeMutableBufferPointer { re in
                            resultImaginary.withUnsafeMutableBufferPointer { im in
                                product.apply(real: xr.baseAddress!, imaginary: xi.baseAddress!, intoReal: re.baseAddress!, imaginary: im.baseAddress!)
                            }
                        }
                    }
                }
                #expect(resultReal.allSatisfy { $0.isFinite } && resultImaginary.allSatisfy { $0.isFinite }, "\(fixture.name) × \(scale): no NaN, no infinity (NUM-1)")
                for row in 0 ..< kernel.rowCount {
                    // The same sum in double precision, and the sum of the magnitudes of its terms.
                    var exactReal = 0.0, exactImaginary = 0.0, terms = 0.0
                    let range = kernel.rowStarts[row] ..< kernel.rowStarts[row + 1]
                    for index in range {
                        let a = Double(kernel.real[index]), b = Double(kernel.imaginary[index])
                        let x = Double(scaledReal[kernel.columns[index]]), y = Double(scaledImaginary[kernel.columns[index]])
                        exactReal += a * x - b * y
                        exactImaginary += a * y + b * x
                        terms += (abs(a) + abs(b)) * (abs(x) + abs(y))
                    }
                    let error = max(abs(Double(resultReal[row]) - exactReal), abs(Double(resultImaginary[row]) - exactImaginary))
                    // 2n products and 2n − 1 additions a part: (2n + 1) · ε of the terms, and what a subnormal result rounds by.
                    let bound = Double(2 * range.count + 1) * Double(Float.ulpOfOne) * terms + 8 * Double(Float.leastNonzeroMagnitude)
                    #expect(error <= bound, "\(fixture.name) × \(scale), row \(row): off by \(error), the bound is \(bound)")
                    if terms > 1e-30 {
                        worstShare = max(worstShare, error / (Double(Float.ulpOfOne) * terms))
                        fixtureWorst = max(fixtureWorst, error / (Double(Float.ulpOfOne) * terms))
                    }
                }
                if fixture.name == "silence" { #expect(resultReal.allSatisfy { $0 == 0 } && resultImaginary.allSatisfy { $0 == 0 }) }
            }
            print("measured WP-520: \(fixture.name): the worst row, at the scales 1, 2⁻⁴⁰ and 2⁴⁰, is off by \(fixtureWorst) ε of the sum of its terms")
        }
        #expect(worstShare > 0 && worstShare <= 2, "the worst row is off by \(worstShare) ε of the sum of its terms")
    }

    // MARK: Row 13, the transform (WP-521, WP-522a)

    @Test func theTransformOfEveryStressSignalIsFiniteAndThatOfTheDefinition() throws {
        // Five octaves of semitones from A3 at the rate of the library's signals.
        let step = ConstantQ(fmin: .hertz(220), octaves: 5, binsPerOctave: 12, hop: 256)
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 5, binsPerOctave: 12, sampleRate: 48_000)
        for fixture in StressFixture.signals(count: 16_384) {
            let sink = try complexFrames(of: Pipeline { step }, on: fixture.samples, format: mono48, blockSize: 480)
            #expect(sink.frameCount > 50 && sink.reals.allSatisfy { $0.allSatisfy { $0.isFinite } } && sink.imaginaries.allSatisfy { $0.allSatisfy { $0.isFinite } },
                    "\(fixture.name): no NaN, no infinity (NUM-1)")
            let reference = referenceConstantQ(fixture.samples, geometry: geometry, hop: 256, frames: sink.frameCount)
            // Frames from this one on lie wholly behind the onset of the signal.
            let settled = geometry.atomLength(ofBin: 0) / 256 + 1
            var worst = 0.0, peak = 0.0, largest = 0.0, lateReference = 0.0, lateTransform = 0.0
            for frame in 0 ..< sink.frameCount {
                for bin in 0 ..< 60 {
                    let expected = hypot(reference.real[frame][bin], reference.imaginary[frame][bin])
                    let read = hypot(Double(sink.reals[frame][bin]), Double(sink.imaginaries[frame][bin]))
                    peak = max(peak, expected)
                    largest = max(largest, read)
                    worst = max(worst, hypot(Double(sink.reals[frame][bin]) - reference.real[frame][bin], Double(sink.imaginaries[frame][bin]) - reference.imaginary[frame][bin]))
                    if frame >= settled {
                        lateReference = max(lateReference, expected)
                        lateTransform = max(lateTransform, read)
                    }
                }
            }
            switch fixture.name {
            case "silence":
                #expect(largest == 0, "zeros")
            case "denormal":
                #expect(largest <= 1e-36, "nothing but what subnormal numbers round to: \(largest)")
            default:
                // The onset of every signal is in the first frames: none is nothing to the definition.
                #expect(peak > 1e-3 && worst <= 0.03 * peak, "\(fixture.name): off by \(worst / peak) of the largest magnitude of the excerpt, \(peak)")
            }
            print("measured WP-521/522a: \(fixture.name): the largest magnitude of the definition \(peak), off by \(peak > 0 ? worst / peak : worst) of it (\(worst) absolute); behind the onset the definition reads \(lateReference), the transform \(lateTransform); the largest magnitude read \(largest)")
            if fixture.name == "nyquist" {
                // Behind its onset a tone at the Nyquist frequency lies in no bin, and folds into none.
                #expect(lateReference <= 1e-5 && lateTransform <= 1e-4, "the definition reads \(lateReference), the transform \(lateTransform): 80 dB down at least")
            }
            if fixture.name == "dc" {
                // What a constant at full scale leaves in a bin: the skirt of the bin's window for
                // the definition, and for a thinned kernel what it dropped of that skirt's cancellation.
                #expect(lateReference <= 1e-4 && lateTransform <= 1e-3, "the definition reads \(lateReference), the transform \(lateTransform): 60 dB down at least")
            }
        }
    }

    /// NUM-1 where the signal enters (register audit, WP-905c): a sample that is not a number is
    /// replaced by 0 before any octave sees it. The frames of `StressFixture.nonFiniteSignal` are
    /// numbers, and are those of the same signal with its non-finite samples replaced, bit for
    /// bit: no coefficient reads a NaN through the decimators or the product.
    @Test func theTransformOfTheNonFiniteFixtureIsThatOfTheSignalWithItsValuesReplaced() throws {
        let step = ConstantQ(fmin: .hertz(220), octaves: 5, binsPerOctave: 12, hop: 256)
        let fixture = StressFixture.nonFiniteSignal(count: 16_384)
        let replaced = fixture.samples.map { $0.isFinite ? $0 : 0 }
        let poisoned = try complexFrames(of: Pipeline { step }, on: fixture.samples, format: mono48, blockSize: 480)
        let clean = try complexFrames(of: Pipeline { step }, on: replaced, format: mono48, blockSize: 480)
        #expect(fixture.nonFiniteCount == 3 && poisoned.frameCount == clean.frameCount && poisoned.frameCount > 50)
        #expect(poisoned.reals.allSatisfy { $0.allSatisfy { $0.isFinite } } && poisoned.imaginaries.allSatisfy { $0.allSatisfy { $0.isFinite } }, "no NaN, no infinity (NUM-1)")
        #expect(poisoned.reals == clean.reals && poisoned.imaginaries == clean.imaginaries, "the frames are those of the signal with its \(fixture.nonFiniteCount) values replaced")
    }

    @Test(arguments: [0, 1, 2, 3])
    func theLongestAtomsOfTheLibraryAreReadFromSignalsHalvedAThousandTimesOver(index: Int) throws {
        // The corners near 0 Hz as the lowest bin: atoms of up to a million samples, which no
        // transform here is ever as long as. A tone at the lowest bin and one at the highest
        // read their amplitudes.
        let filter = StressFixture.filtersNearZero[index]
        let count = octaves(above: filter.cutoff, sampleRate: filter.sampleRate)
        let hop = 8 << (count - 1)
        let step = ConstantQ(fmin: .hertz(filter.cutoff), octaves: count, hop: hop)
        let geometry = try ConstantQGeometry(minimumFrequency: filter.cutoff, octaves: count, sampleRate: filter.sampleRate)
        let longest = geometry.atomLength(ofBin: 0)
        let length = longest + longest / 4 + 4 * hop
        let low = TestSignal.sine(frequency: geometry.frequency(ofBin: 0), sampleRate: filter.sampleRate, count: length, amplitude: 0.25)
        let high = TestSignal.sine(frequency: geometry.frequency(ofBin: geometry.binCount - 1), sampleRate: filter.sampleRate, count: length, amplitude: 0.25, phase: 1)
        let signal = zip(low, high).map { $0 + $1 }
        let sink = try complexFrames(of: Pipeline { step }, on: signal, format: SignalFormat(sampleRate: filter.sampleRate), blockSize: 4_096)
        // The last frame whose longest atom lies wholly inside the signal.
        let frame = min((length - longest / 2 - 1) / hop, sink.frameCount - 1)
        #expect(frame * hop >= longest / 2, "\(filter.name): \(sink.frameCount) frames of \(length) samples, the longest atom \(longest)")
        let read = magnitudes(sink.reals[frame], sink.imaginaries[frame])
        for bin in [0, geometry.binCount - 1] {
            let level = 20 * log10(read[bin] / 0.25)
            #expect(abs(level) <= 0.5, "\(filter.name), \(count) octaves, bin \(bin) at \(geometry.frequency(ofBin: bin)) Hz: \(level) dB")
            print("measured WP-521/522a: \(filter.name), \(count) octaves, the longest atom \(longest) samples: bin \(bin) at \(geometry.frequency(ofBin: bin)) Hz reads \(level) dB")
        }
        #expect(indexOfMaximum(Array(read[..<36])) == 0 && indexOfMaximum(Array(read[(geometry.binCount - 36)...])) == 35)
        #expect(sink.reals.allSatisfy { $0.allSatisfy { $0.isFinite } })
    }

    // MARK: The pseudo constant-Q (WP-523)

    @Test func theBandsOfEveryStressSignalAreSumsOfNonNegativeTerms() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 440, octaves: 5, binsPerOctave: 12, sampleRate: 48_000)
        let scale = ConstantQScale(fmin: .hertz(440), octaves: 5, binsPerOctave: 12)
        for squared in [false, true] {
            let projection = try ConstantQProjection(geometry: geometry, binCount: 2_049, window: .hann, sparsity: 0.01, squared: squared)
            let longest = projection.bands.map { $0.weights.count }.max() ?? 0
            print("measured WP-523: \(projection.bands.count) bands of \(projection.bands.map { $0.weights.count }.min() ?? 0) to \(longest) bins, \(projection.bands.reduce(0) { $0 + $1.weights.count }) weights in all, \(squared ? "powers" : "magnitudes")")
            #expect(projection.bands.allSatisfy { $0.weights.allSatisfy { $0 >= 0 && $0.isFinite } }, "every weight is a non-negative number")
            for fixture in StressFixture.signals(count: 16_384) {
                let magnitudes: Pipeline<Samples, Spectrum<LinearFrequency, MagnitudeValues>> = Pipeline { STFT(frame: 4_096, hop: 1_024); Magnitude() }
                let powers: Pipeline<Samples, Spectrum<LinearFrequency, PowerValues>> = Pipeline { STFT(frame: 4_096, hop: 1_024); Power() }
                let spectra: [[Float]] = squared ? try powers.process(fixture.samples, format: mono48) : try magnitudes.process(fixture.samples, format: mono48)
                for implementation in [Implementation.native, .accelerate] {
                    let scaled: [[Float]] = squared
                        ? try powers.constantQScale(fmin: .hertz(440), octaves: 5, binsPerOctave: 12).environment(\.implementation, implementation).process(fixture.samples, format: mono48)
                        : try magnitudes.appending(scale.stageDescription, producing: Spectrum<ConstantQFrequency, MagnitudeValues>.self)
                            .environment(\.implementation, implementation).process(fixture.samples, format: mono48)
                    #expect(scaled.count == spectra.count && scaled.count == 13)
                    var worst = 0.0, wrong = 0
                    for (index, frame) in scaled.enumerated() {
                        for (band, run) in projection.bands.enumerated() {
                            var sum = 0.0
                            for (offset, weight) in run.weights.enumerated() { sum += Double(weight) * Double(spectra[index][run.firstBin + offset]) }
                            if !(frame[band] >= 0) || !frame[band].isFinite { wrong += 1 }
                            // Held against the band's own value: sums of non-negative terms do not cancel.
                            if sum > 1e-30 { worst = max(worst, abs(Double(frame[band]) - sum) / sum) } else if Double(frame[band]) > 1e-30 { wrong += 1 }
                        }
                    }
                    #expect(wrong == 0, "\(fixture.name), \(implementation): \(wrong) bands negative, not a number, or not zero where the spectrum is")
                    #expect(worst <= Double(longest) * Double(Float.ulpOfOne), "\(fixture.name), \(implementation), \(squared ? "powers" : "magnitudes"): off by \(worst) of the band; ε·bins is \(Double(longest) * Double(Float.ulpOfOne))")
                    print("measured WP-523: \(fixture.name), \(implementation), \(squared ? "powers" : "magnitudes"): off by \(worst) of the band, \(worst / Double(Float.ulpOfOne)) ε; \(wrong) bands wrong")
                }
            }
        }

        // The hazard itself: a bin the frame does not resolve, refused when the pipeline is
        // attached, at every sample rate of the library.
        for filter in StressFixture.filtersNearZero {
            let format = SignalFormat(sampleRate: filter.sampleRate)
            func attach(_ step: ConstantQScale) -> String? {
                errorMessage { let _: [[Float]] = try Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); step }.process(TestSignal.silence(count: 4_096), format: format) }
            }
            // A frame of 2 048 samples holds an atom of Q periods from this frequency up.
            let resolved = try ConstantQGeometry(minimumFrequency: filter.cutoff, octaves: 1, binsPerOctave: 12, sampleRate: filter.sampleRate).q * filter.sampleRate / 2_048
            let message = try #require(attach(ConstantQScale(fmin: .hertz(filter.cutoff), octaves: 1, binsPerOctave: 12)), "\(filter.name): a frame of 2 048 samples does not hold an atom at \(filter.cutoff) Hz")
            #expect(message.contains("longer than the frame of 2048 samples") && message.contains("this frame holds the bins from \(resolved)"), "\(message)")
            #expect(attach(ConstantQScale(fmin: .hertz(resolved * 1.0001), octaves: 1, binsPerOctave: 12)) == nil, "\(filter.name): and from \(resolved) Hz up it attaches")
            #expect(attach(ConstantQScale(fmin: .hertz(resolved * 0.99), octaves: 1, binsPerOctave: 12)) != nil)
        }
    }
}
