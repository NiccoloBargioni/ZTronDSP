import Accelerate
import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The one-octave sparse spectral kernel (WP-518) and its product with a spectrum (WP-520).
@Suite("Constant-Q kernel")
struct ConstantQKernelTests {
    static let cases = ["defaults-22050", "semitones-tuned", "variable-q"]

    /// The dense kernel of a golden case: `rows × bins` complex entries, and the energy of
    /// each whole row.
    private struct Dense {
        let real: [Double]
        let imaginary: [Double]
        let energy: [Double]
        let bins: Int

        func magnitude(_ row: Int, _ bin: Int) -> Double { hypot(real[row * bins + bin], imaginary[row * bins + bin]) }
        func peak(_ row: Int) -> Double { (0 ..< bins).reduce(0) { max($0, magnitude(row, $1)) } }
    }

    private func dense(_ golden: GoldenCase) throws -> Dense {
        Dense(real: try golden.real("real"), imaginary: try golden.real("imaginary"), energy: try golden.real("energy"),
              bins: try golden.integer("transformLength") / 2 + 1)
    }

    // MARK: Parity with the dense kernel, and the energy kept (WP-518)

    @Test(arguments: cases)
    func theSparseKernelIsTheDenseKernelWhereItKeepsIt(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("kernel-\(name)")
        let geometry = try geometry(of: golden), reference = try dense(golden)
        let kernel = try ConstantQKernel(geometry: geometry, octave: geometry.octaves - 1)
        let length = try golden.integer("transformLength"), span = try golden.integer("span"), center = try golden.integer("center")
        let atomLengths = try golden.real("atomLengths").map { Int($0) }
        #expect(kernel.rowCount == geometry.binsPerOctave && kernel.transformLength == length)
        #expect(kernel.span == span && kernel.center == center && kernel.columnCount == reference.bins)
        #expect(kernel.atomLengths == atomLengths)

        // Compressed sparse rows: offsets that only grow, columns that only grow within a row.
        #expect(kernel.rowStarts.count == kernel.rowCount + 1 && kernel.rowStarts.first == 0 && kernel.rowStarts.last == kernel.nonZeroCount)
        #expect(kernel.columns.count == kernel.nonZeroCount && kernel.real.count == kernel.nonZeroCount && kernel.imaginary.count == kernel.nonZeroCount)
        var worstEntry = 0.0, leastKept = 1.0, mostDropped = 0.0
        for row in 0 ..< kernel.rowCount {
            let range = kernel.rowStarts[row] ..< kernel.rowStarts[row + 1]
            let columns = Array(kernel.columns[range])
            #expect(!columns.isEmpty && columns == columns.sorted() && Set(columns).count == columns.count, "row \(row)")
            let peak = reference.peak(row)
            var keptEnergy = 0.0, keptMagnitude = 0.0, smallestKept = Double.infinity
            for index in range {
                let column = kernel.columns[index]
                let error = hypot(Double(kernel.real[index]) - reference.real[row * reference.bins + column],
                                  Double(kernel.imaginary[index]) - reference.imaginary[row * reference.bins + column])
                worstEntry = max(worstEntry, error / peak)
                keptEnergy += reference.magnitude(row, column) * reference.magnitude(row, column)
                keptMagnitude += reference.magnitude(row, column)
                smallestKept = min(smallestKept, reference.magnitude(row, column))
            }
            // What was dropped is smaller than everything that was kept, and is less than
            // `sparsity` of the row's summed magnitude.
            var summed = 0.0, largestDropped = 0.0
            for bin in 0 ..< reference.bins {
                summed += reference.magnitude(row, bin)
                if !columns.contains(bin) { largestDropped = max(largestDropped, reference.magnitude(row, bin)) }
            }
            #expect(largestDropped <= smallestKept * (1 + 1e-9), "row \(row): the entries are dropped from the smallest up")
            mostDropped = max(mostDropped, 1 - keptMagnitude / summed)
            // The energy kept, counted on the reference: of the whole row, both halves of the spectrum.
            let share = keptEnergy / reference.energy[row]
            leastKept = min(leastKept, share)
            expectClose(kernel.keptEnergy[row], share, .absolute(1e-9), "row \(row): the share the kernel states is the share it keeps")
        }
        #expect(worstEntry <= 1e-6, "\(name): an entry is off by \(worstEntry) of the largest of its row")
        #expect(leastKept >= 0.999, "\(name): a row keeps \(leastKept) of its energy; 99.9 % is the least (§7.5 row 13)")
        #expect(mostDropped < 0.01 && mostDropped > 0.001, "\(name): \(mostDropped) of a row's magnitude is dropped, below the sparsity of 0.01 and not nothing")
        #expect(kernel.nonZeroCount < kernel.rowCount * reference.bins / 8, "\(name): \(kernel.nonZeroCount) entries of \(kernel.rowCount * reference.bins)")
        #expect(kernel.columnRange.lowerBound == kernel.columns.min() && kernel.columnRange.upperBound == kernel.columns.max())
    }

    @Test(arguments: cases)
    func withoutSparsityTheKernelIsTheDenseKernelOverTheBandItReads(name: String) throws {
        let golden = try GoldenFile(named: "constant_q", in: .module).require("kernel-\(name)")
        let geometry = try geometry(of: golden), reference = try dense(golden)
        let kernel = try ConstantQKernel(geometry: geometry, octave: geometry.octaves - 1, sparsity: 0)
        // With a gamma of 0 the kernel of the highest octave is that of every octave, and
        // reads what the decimators keep clean: the lower 80 % of the band. With a gamma
        // above 0 the highest octave has a kernel of its own and reads the whole band.
        let readable = geometry.gamma == 0 ? Int(0.8 * Double(kernel.transformLength / 2)) + 1 : reference.bins
        #expect(kernel.nonZeroCount == kernel.rowCount * readable && kernel.columnRange == 0 ... readable - 1)
        let (real, imaginary) = kernel.dense()
        #expect(real.count == kernel.rowCount * reference.bins && imaginary.count == real.count)
        for row in 0 ..< kernel.rowCount {
            let peak = reference.peak(row)
            var worst = 0.0, beyond = 0.0
            for bin in 0 ..< reference.bins {
                let index = row * reference.bins + bin
                if bin < readable {
                    worst = max(worst, hypot(Double(real[index]) - reference.real[index], Double(imaginary[index]) - reference.imaginary[index]) / peak)
                } else {
                    #expect(real[index] == 0 && imaginary[index] == 0)
                    beyond += reference.magnitude(row, bin) * reference.magnitude(row, bin)
                }
            }
            #expect(worst <= 1e-6, "row \(row): off by \(worst) of its largest entry")
            #expect(beyond <= 1e-6 * reference.energy[row] && kernel.keptEnergy[row] >= 0.999_99, "row \(row): what lies above the band is next to nothing")
        }
    }

    @Test func aKernelIsTheTransformOfItsAtoms() throws {
        // A kernel small enough to transform by the definition, with atoms of even and of odd
        // length, under a window vDSP generates and under windows the package computes.
        let geometry = try ConstantQGeometry(minimumFrequency: 500, octaves: 1, binsPerOctave: 5, tuning: 0.3, filterScale: 1.4, sampleRate: 8_000)
        let windows: [(Window, (Double) -> Double)] = [
            (.hann, hannShape), (.hamming, { 0.54 - 0.46 * cos(2 * .pi * $0) }),
            (.blackmanHarris, { 0.35875 - 0.48829 * cos(2 * .pi * $0) + 0.14128 * cos(4 * .pi * $0) - 0.01168 * cos(6 * .pi * $0) }),
            (.custom { 1 - abs(2 * $0 - 1) }, { 1 - abs(2 * $0 - 1) }),
        ]
        for (window, shape) in windows {
            let kernel = try ConstantQKernel(geometry: geometry, octave: 0, window: window, sparsity: 0)
            #expect(kernel.atomLengths == geometry.atomLengths && kernel.span == geometry.atomLength(ofBin: 0) && kernel.center == kernel.span / 2)
            #expect(kernel.atomLengths.contains { $0 % 2 == 0 } && kernel.atomLengths.contains { $0 % 2 == 1 }, "\(kernel.atomLengths)")
            let length = kernel.transformLength, bins = kernel.columnCount
            #expect(length == DSP.nextFastLength(kernel.span) && bins == length / 2 + 1 && kernel.nonZeroCount == 5 * bins)
            let (real, imaginary) = kernel.dense()
            for row in 0 ..< 5 {
                let atom = referenceAtom(length: kernel.atomLengths[row], cyclesPerSample: geometry.frequency(ofBin: row) / 8_000, window: shape)
                var worst = 0.0, peak = 0.0
                for bin in 0 ..< bins {
                    // conj(Σ a[i] e^(−j2πbi/N)) / N with the atom centred on sample `center`.
                    var sumReal = 0.0, sumImaginary = 0.0
                    for index in 0 ..< atom.real.count {
                        let position = kernel.center + atom.first + index
                        let angle = -2 * Double.pi * Double((bin * position) % length) / Double(length)
                        sumReal += atom.real[index] * cos(angle) - atom.imaginary[index] * sin(angle)
                        sumImaginary += atom.real[index] * sin(angle) + atom.imaginary[index] * cos(angle)
                    }
                    let expectedReal = sumReal / Double(length), expectedImaginary = -sumImaginary / Double(length)
                    peak = max(peak, hypot(expectedReal, expectedImaginary))
                    worst = max(worst, hypot(Double(real[row * bins + bin]) - expectedReal, Double(imaginary[row * bins + bin]) - expectedImaginary))
                }
                #expect(worst <= 1e-6 * peak, "\(window), row \(row): off by \(worst / peak) of the largest entry")
                // Scaled by 2 / Σw: the transform of the atom is 2 at the bin's own frequency,
                // which lies between two bins of the frame's transform.
                #expect(peak <= 2 / Double(length) * (1 + 1e-9) && peak >= 0.6 * 2 / Double(length), "\(window), row \(row): \(peak * Double(length))")
            }
        }
    }

    // MARK: The energy criterion (§7.5 row 13)

    @Test func aRowKeepsItsEnergyWhateverTheSparsityAsksFor() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 22_050)
        var counts: [Int] = []
        for sparsity in [0, 0.001, 0.01, 0.05, 0.3, 0.6, 0.9, 0.999] {
            let kernel = try ConstantQKernel(geometry: geometry, octave: 6, sparsity: sparsity)
            #expect(kernel.keptEnergy.allSatisfy { $0 >= ConstantQKernel.keptEnergyFloor && $0 <= 1 }, "sparsity \(sparsity): a row keeps \(kernel.keptEnergy.min() ?? 0)")
            counts.append(kernel.nonZeroCount)
        }
        #expect(counts == counts.sorted(by: >) && counts[0] > 20 * counts[2], "the more may be dropped, the fewer entries stay: \(counts)")
        // From the point where the energy decides, a larger sparsity drops nothing more.
        #expect(counts[5] == counts[4] && counts[7] == counts[4], "\(counts)")
        #expect(counts[4] >= 36 * 5, "five entries a row hold 99.9 % of a Hann atom: \(counts[4]) in 36 rows")
        #expect(ConstantQKernel.keptEnergyFloor == 0.999)

        // The figures of `constant-q-kernel.md`, printed (register audit, WP-905c).
        for rate in [22_050.0, 44_100, 48_000] {
            let defaults = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: rate)
            let kernel = try ConstantQKernel(geometry: defaults, octave: 6, sparsity: 0.01)
            let schedule = try ConstantQSchedule(geometry: defaults, hop: 512, filterLength: HalfBand.taps().count)
            print("measured WP-518: the defaults at \(rate) Hz, sparsity 0.01: the longest atom \(kernel.span), a transform of \(kernel.transformLength), \(kernel.nonZeroCount) entries of \(kernel.rowCount * kernel.columnCount), \(Double(kernel.nonZeroCount) / Double(kernel.rowCount)) a row; the least share of its energy a row keeps \(kernel.keptEnergy.min() ?? 0); latency \(schedule.latency) samples, the lowest atom \(defaults.atomLength(ofBin: 0)); zeros ahead of the decimators \(schedule.primes), lags \(schedule.delays)")
        }
        let at48 = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        for sparsity in [0, 0.001, 0.01, 0.05, 0.3, 0.9, 0.999] {
            let kernel = try ConstantQKernel(geometry: at48, octave: 6, sparsity: sparsity)
            print("measured WP-518: the defaults at 48 kHz, sparsity \(sparsity): \(kernel.nonZeroCount) entries, the least share of its energy a row keeps \(kernel.keptEnergy.min() ?? 0)")
        }
    }

    /// Hazard 2 of the product (register audit, WP-905c): the columns of a kernel are bins of the
    /// transform it was made for. The node refuses a kernel for another length before a product
    /// is made of it: one for twice the length would read bins the spectrum does not have.
    @Test func aKernelForAnotherTransformLengthIsRefusedBeforeAProductIsMadeOfIt() throws {
        let strategy = MultirateSparseKernelStrategy()
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 5, binsPerOctave: 12, sampleRate: 48_000)
        let schedule = try strategy.schedule(of: geometry, hop: 256)
        let length = try strategy.transformLength(holding: schedule.spans.max() ?? 1)
        let taps = try HalfBand.taps().map { Float($0) }
        func refusal(kernelLength: Int) -> String? {
            errorMessage {
                _ = try ConstantQNode(
                    geometry: geometry, schedule: schedule,
                    kernels: try strategy.kernels(of: geometry, window: .hann, sparsity: 0.01, transformLength: kernelLength),
                    taps: taps, plan: strategy.backend.makePlan(length: length), mixer: ChannelMixer(channel: nil, channelCount: 1, maximumFrames: 512))
            }
        }
        #expect(refusal(kernelLength: length) == nil, "the kernel made for the transform")
        let refused = try #require(refusal(kernelLength: 2 * length), "a kernel for \(2 * length) points on a transform of \(length)")
        #expect(refused.contains("for a transform of \(2 * length) points does not fit") && refused.contains("a transform of \(length)"), "\(refused)")
    }

    @Test func aRowThatCannotKeepItsEnergyIsRefusedAndTheErrorSaysWhy() throws {
        func refusal(_ geometry: ConstantQGeometry, octave: Int, window: Window = .hann) -> String? {
            errorMessage { _ = try ConstantQKernel(geometry: geometry, octave: octave, window: window) }
        }
        // One bin per octave: an atom of one period cannot be told from its mirror image.
        let coarse = try ConstantQGeometry(minimumFrequency: 100, octaves: 3, binsPerOctave: 1, sampleRate: 8_000)
        let few = try #require(refusal(coarse, octave: 2))
        #expect(few.contains("binsPerOctave") && few.contains("bin 2, at 400.0 Hz") && few.contains("periods") && few.contains("mirror image"), "\(few)")
        // The same bins with atoms six times as long are fine.
        #expect(refusal(try ConstantQGeometry(minimumFrequency: 100, octaves: 3, binsPerOctave: 1, filterScale: 6, sampleRate: 8_000), octave: 2) == nil)

        // The highest bin at 0.77 of the Nyquist frequency: its transform does not fit below
        // 0.8 of it, where the decimators stop keeping the band clean.
        let high = try ConstantQGeometry(minimumFrequency: 4_900, octaves: 2, binsPerOctave: 12, sampleRate: 48_000)
        let clean = try #require(refusal(high, octave: 1))
        #expect(clean.contains("octaves") && clean.contains("0.8 of the Nyquist frequency") && clean.contains("19200.0 Hz") && clean.contains("half-band decimators"), "\(clean)")
        // A semitone lower, the highest bin is clear of it.
        #expect(refusal(try ConstantQGeometry(minimumFrequency: 4_440, octaves: 2, binsPerOctave: 12, sampleRate: 48_000), octave: 1) == nil)
        // One octave has no decimator: the same bins are read up to the Nyquist frequency.
        #expect(refusal(try ConstantQGeometry(minimumFrequency: 9_800, octaves: 1, binsPerOctave: 12, sampleRate: 48_000), octave: 0) == nil)
        // … until the transform of an atom reaches across it.
        let top = try ConstantQGeometry(minimumFrequency: 12_300, octaves: 1, binsPerOctave: 12, sampleRate: 48_000)
        let folded = try #require(refusal(top, octave: 0))
        #expect(folded.contains("too close to the Nyquist frequency, 24000.0 Hz") && !folded.contains("decimators"), "\(folded)")
    }

    // MARK: Octaves, values, arguments

    @Test func withoutGammaEveryOctaveSharesOneKernel() throws {
        let constant = try ConstantQGeometry(minimumFrequency: 110, octaves: 4, binsPerOctave: 12, sampleRate: 22_050)
        let top = try ConstantQKernel(geometry: constant, octave: 3)
        for octave in 0 ..< 3 { #expect(try ConstantQKernel(geometry: constant, octave: octave) == top, "octave \(octave)") }
        let lowest = try ConstantQKernel(geometry: constant, octave: 0)
        #expect(top.hashValue == lowest.hashValue)

        let variable = try ConstantQGeometry(minimumFrequency: 110, octaves: 4, binsPerOctave: 12, gamma: 4, sampleRate: 22_050)
        let kernels = try (0 ..< 4).map { try ConstantQKernel(geometry: variable, octave: $0) }
        #expect(Set(kernels).count == 4, "with gamma every octave has a kernel of its own")
        #expect(kernels.map { $0.span } == kernels.map { $0.span }.sorted() && kernels[0].span < kernels[3].span, "\(kernels.map { $0.span })")
        #expect(kernels.allSatisfy { $0.transformLength == kernels[3].transformLength }, "all for one transform length, that of the highest octave")
        #expect(kernels[3] != top && kernels[3].atomLengths != top.atomLengths)
    }

    @Test func aKernelAppliedToTheSpectrumOfAToneReadsItsAmplitude() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 1_000, octaves: 1, binsPerOctave: 12, sampleRate: 16_000)
        let kernel = try ConstantQKernel(geometry: geometry, octave: 0)
        for bin in 0 ..< 12 {
            // A frame of `span` samples of a cosine at the bin's centre, zero-padded, transformed.
            let frequency = geometry.frequency(ofBin: bin)
            var frame = [Double](repeating: 0, count: kernel.transformLength)
            for index in 0 ..< kernel.span { frame[index] = 0.25 * cos(2 * .pi * frequency * Double(index - kernel.center) / 16_000 + 1) }
            let spectrum = try DSP.realDFT(frame)
            let result = kernel.applied(toReal: spectrum.real.map { Float($0) }, imaginary: spectrum.imaginary.map { Float($0) })
            let read = magnitudes(result.real, result.imaginary)
            expectClose(read[bin], 0.25, .decibels(0.05), "bin \(bin)")
            #expect(indexOfMaximum(read) == bin)
            // The phase is that of the tone at the sample the atoms are centred on.
            expectClose(atan2(Double(result.imaginary[bin]), Double(result.real[bin])), 1, .absolute(0.01), "bin \(bin)")
        }
        // Bins a spectrum does not have count as zero.
        let short = kernel.applied(toReal: [1, 1], imaginary: [0, 0])
        #expect(short.real.count == 12 && short.real.allSatisfy { $0 == 0 })
    }

    @Test func argumentsOutOfRangeAreRefused() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: 220, octaves: 3, binsPerOctave: 12, sampleRate: 16_000)
        func refusal(octave: Int = 2, window: Window = .hann, sparsity: Double = 0.01, length: Int? = nil) -> String? {
            errorMessage { _ = try ConstantQKernel(geometry: geometry, octave: octave, window: window, sparsity: sparsity, transformLength: length) }
        }
        #expect(refusal() == nil && refusal(length: 4_096) == nil)
        #expect(refusal(octave: 3)?.contains("octave 3 is not one of the 3 octaves") == true && refusal(octave: -1) != nil)
        #expect(refusal(sparsity: 1)?.contains("sparsity") == true && refusal(sparsity: -0.1) != nil && refusal(sparsity: .nan) != nil && refusal(sparsity: 0.999) == nil)
        #expect(refusal(length: 500)?.contains("not a transform length") == true, "a length the transform does not take")
        #expect(refusal(length: 256)?.contains("does not hold the longest atom") == true, "a length shorter than the atoms")
        #expect(refusal(window: .hann.half)?.contains("first half") == true)
        #expect(refusal(window: .custom { $0 < 0.5 ? 1 : -1 })?.contains("no gain to normalise") == true, "a window without a sum")
        #expect(refusal(window: .custom { _ in 0 }) != nil && refusal(window: .custom { $0 > 0.9 ? .infinity : 1 }) != nil, "WIN-3")
        // An atom of two million samples of its own rate is more than a kernel is built for.
        let long = try ConstantQGeometry(minimumFrequency: 0.4, octaves: 1, binsPerOctave: 12, sampleRate: 48_000)
        #expect(errorMessage { _ = try ConstantQKernel(geometry: long, octave: 0) }?.contains("above the 1048576 a kernel is built for") == true)
        // A rectangular window falls off too slowly for atoms of seventeen periods: half a
        // per cent of such an atom's energy lies at negative frequencies.
        #expect(refusal(window: .rectangular)?.contains("mirror image") == true)
    }

    // MARK: The product (WP-520)

    /// A spectrum of seeded noise: what no signal would give, in every bin.
    private func noiseSpectrum(_ bins: Int, seed: UInt64) -> (real: [Float], imaginary: [Float]) {
        (TestSignal.whiteNoise(count: bins, seed: seed), TestSignal.whiteNoise(count: bins, seed: seed &+ 1_000))
    }

    private func sparse(_ product: SparseKernelProduct, _ spectrum: (real: [Float], imaginary: [Float])) -> (real: [Float], imaginary: [Float]) {
        var real = [Float](repeating: -7, count: product.rowCount), imaginary = real
        spectrum.real.withUnsafeBufferPointer { xr in
            spectrum.imaginary.withUnsafeBufferPointer { xi in
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        product.apply(real: xr.baseAddress!, imaginary: xi.baseAddress!, intoReal: re.baseAddress!, imaginary: im.baseAddress!)
                    }
                }
            }
        }
        return (real, imaginary)
    }

    /// The same product with the kernel as a dense matrix: four matrix products of vDSP.
    private func dense(_ kernel: ConstantQKernel, _ spectrum: (real: [Float], imaginary: [Float])) -> (real: [Float], imaginary: [Float]) {
        let matrix = kernel.dense()
        let rows = vDSP_Length(kernel.rowCount), columns = vDSP_Length(kernel.columnCount)
        var a = [Float](repeating: 0, count: kernel.rowCount), b = a, c = a, d = a
        vDSP_mmul(matrix.real, 1, spectrum.real, 1, &a, 1, rows, 1, columns)
        vDSP_mmul(matrix.imaginary, 1, spectrum.imaginary, 1, &b, 1, rows, 1, columns)
        vDSP_mmul(matrix.real, 1, spectrum.imaginary, 1, &c, 1, rows, 1, columns)
        vDSP_mmul(matrix.imaginary, 1, spectrum.real, 1, &d, 1, rows, 1, columns)
        // re = Kr·Xr − Ki·Xi; im = Kr·Xi + Ki·Xr.
        return (zip(a, b).map { $0 - $1 }, zip(c, d).map { $0 + $1 })
    }

    @Test(arguments: [0, 0.01, 0.3])
    func theSparseProductIsTheDenseProduct(sparsity: Double) throws {
        for (rate, bins) in [(22_050.0, 36), (48_000.0, 36), (16_000.0, 12)] {
            let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(36), octaves: 5, binsPerOctave: bins, sampleRate: rate)
            let kernel = try ConstantQKernel(geometry: geometry, octave: 4, sparsity: sparsity)
            let product = try SparseKernelProduct(kernel)
            #expect(product.rowCount == kernel.rowCount && product.columnCount == kernel.columnCount)
            for seed in [1 as UInt64, 2, 3] {
                let spectrum = noiseSpectrum(kernel.columnCount, seed: seed)
                let fast = sparse(product, spectrum), full = dense(kernel, spectrum), exact = kernel.applied(toReal: spectrum.real, imaginary: spectrum.imaginary)
                let peak = magnitudes(exact.real, exact.imaginary).max() ?? 0
                var againstDense = 0.0, againstDouble = 0.0
                for row in 0 ..< kernel.rowCount {
                    againstDense = max(againstDense, hypot(Double(fast.real[row] - full.real[row]), Double(fast.imaginary[row] - full.imaginary[row])))
                    againstDouble = max(againstDouble, hypot(Double(fast.real[row] - exact.real[row]), Double(fast.imaginary[row] - exact.imaginary[row])))
                }
                #expect(peak > 0 && againstDense <= 1e-5 * peak, "\(rate) Hz, \(bins) bins, sparsity \(sparsity): \(againstDense / peak) from the dense product")
                #expect(againstDouble <= 1e-5 * peak, "\(rate) Hz, \(bins) bins, sparsity \(sparsity): \(againstDouble / peak) from the product in double precision")
            }
        }
    }

    @Test func theProductRunsWithoutAllocating() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        let kernel = try ConstantQKernel(geometry: geometry, octave: 6)
        let product = try SparseKernelProduct(kernel)
        let spectrumReal = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: kernel.columnCount, seed: 5))
        let spectrumImaginary = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: kernel.columnCount, seed: 6))
        let real = try AlignedBuffer<Float>(count: kernel.rowCount), imaginary = try AlignedBuffer<Float>(count: kernel.rowCount)
        product.apply(real: spectrumReal.baseAddress, imaginary: spectrumImaginary.baseAddress, intoReal: real.baseAddress, imaginary: imaginary.baseAddress)
        let first = real.array
        expectNoAllocations {
            var pass = 0
            while pass < 1_000 {
                product.apply(real: spectrumReal.baseAddress, imaginary: spectrumImaginary.baseAddress, intoReal: real.baseAddress, imaginary: imaginary.baseAddress)
                pass += 1
            }
        }
        #expect(real.array == first && first.contains { $0 != 0 }, "the product keeps no state")
    }

    /// The benchmark of WP-520 (PERF-1): the sparse product against the same kernel as a
    /// dense matrix. It is recorded; no timing is held against anything here.
    @Test func theProductIsTimedAgainstTheDenseProduct() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        let kernel = try ConstantQKernel(geometry: geometry, octave: 6)
        let product = try SparseKernelProduct(kernel)
        let spectrumReal = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: kernel.columnCount, seed: 5))
        let spectrumImaginary = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: kernel.columnCount, seed: 6))
        let real = try AlignedBuffer<Float>(count: kernel.rowCount), imaginary = try AlignedBuffer<Float>(count: kernel.rowCount)
        let matrix = kernel.dense()
        let matrixReal = try AlignedBuffer<Float>(copying: matrix.real), matrixImaginary = try AlignedBuffer<Float>(copying: matrix.imaginary)
        let rows = vDSP_Length(kernel.rowCount), columns = vDSP_Length(kernel.columnCount)
        let partA = try AlignedBuffer<Float>(count: kernel.rowCount), partB = try AlignedBuffer<Float>(count: kernel.rowCount)

        let sparse = Benchmark.measure("constant-Q kernel × spectrum: sparse, 36 rows of 1 280 points", samples: 11, iterations: 200) {
            product.apply(real: spectrumReal.baseAddress, imaginary: spectrumImaginary.baseAddress, intoReal: real.baseAddress, imaginary: imaginary.baseAddress)
        }
        let checksum = real.array
        let dense = Benchmark.measure("constant-Q kernel × spectrum: dense, 36 rows of 1 280 points", samples: 11, iterations: 200) {
            vDSP_mmul(matrixReal.baseAddress, 1, spectrumReal.baseAddress, 1, partA.baseAddress, 1, rows, 1, columns)
            vDSP_mmul(matrixImaginary.baseAddress, 1, spectrumImaginary.baseAddress, 1, partB.baseAddress, 1, rows, 1, columns)
            vDSP_vsub(partB.baseAddress, 1, partA.baseAddress, 1, real.baseAddress, 1, rows)
            vDSP_mmul(matrixReal.baseAddress, 1, spectrumImaginary.baseAddress, 1, partA.baseAddress, 1, rows, 1, columns)
            vDSP_mmul(matrixImaginary.baseAddress, 1, spectrumReal.baseAddress, 1, partB.baseAddress, 1, rows, 1, columns)
            vDSP_vadd(partA.baseAddress, 1, partB.baseAddress, 1, imaginary.baseAddress, 1, rows)
        }
        expectClose(real.array, checksum, .relativeToMaximum(1e-5), "the two products that were timed are the same product")
        #expect(sparse.minimum > 0 && dense.minimum > 0 && sparse.samples == 11 && dense.iterations == 200)
        #expect(kernel.transformLength == 1_280 && kernel.nonZeroCount < 36 * 16, "\(kernel.nonZeroCount) entries")
        Benchmark.record([sparse, dense])
    }
}
