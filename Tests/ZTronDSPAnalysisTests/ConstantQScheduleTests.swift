import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The half-band decimator and the octave schedule (WP-519), and the time alignment of the
/// octaves with its latency (WP-522b).
@Suite("Constant-Q octave schedule")
struct ConstantQScheduleTests {
    typealias ConstantQSpectrum = Spectrum<ConstantQFrequency, ComplexValues>

    /// `|H(e^(jπf))|` of real taps, `f` in units of the Nyquist frequency.
    private func gain(_ taps: [Double], at frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, tap) in taps.enumerated() {
            real += tap * cos(.pi * frequency * Double(index))
            imaginary -= tap * sin(.pi * frequency * Double(index))
        }
        return hypot(real, imaginary)
    }

    // MARK: The half-band filter (WP-519)

    @Test func theHalfBandFilterPassesTheLowerBandAndRejectsWhatWouldFoldOntoItByEightyDecibels() throws {
        let taps = try HalfBand.taps()
        #expect(taps.count % 2 == 1 && taps.count >= 31 && taps.count <= 71, "\(taps.count) taps")
        #expect(taps == Array(taps.reversed()), "linear phase: the delay is a whole number of samples")
        expectClose(taps.reduce(0, +), 1, .absolute(1e-12), "unity gain at 0 Hz")
        // A half-band filter: one half at a quarter of the sample rate, and every second tap
        // off the centre is zero.
        let centre = (taps.count - 1) / 2
        expectClose(gain(taps, at: 0.5), 0.5, .absolute(1e-3))
        for offset in stride(from: 2, through: centre, by: 2) {
            #expect(abs(taps[centre + offset]) <= 1e-12 * taps[centre], "tap \(offset) off the centre: \(taps[centre + offset])")
        }
        expectClose(taps[centre], 0.5, .absolute(1e-3))

        var ripple = 0.0, leak = 0.0
        for step in 0 ... 4_000 {
            let frequency = Double(step) / 4_000
            let level = gain(taps, at: frequency)
            if frequency <= HalfBand.passbandEdge { ripple = max(ripple, abs(20 * log10(level))) }
            if frequency >= HalfBand.stopbandEdge { leak = max(leak, level) }
            // The response mirrors itself about a quarter of the sample rate.
            #expect(abs(level + gain(taps, at: 1 - frequency) - 1) <= 2e-3 || frequency > 0.5, "at \(frequency)")
        }
        #expect(ripple <= 0.01, "the pass band, 0 … 0.4 of the Nyquist frequency, is flat within \(ripple) dB")
        #expect(20 * log10(leak) <= -80, "the stop band, from 0.6 of the Nyquist frequency up, is \(-20 * log10(leak)) dB down; 80 dB is asked for (§6.8)")
        #expect(HalfBand.passbandEdge + HalfBand.stopbandEdge == 1 && HalfBand.cleanShare == 0.8 && HalfBand.rejection == 80)
    }

    @Test func aToneThatWouldAliasLeavesTheDecimatorEightyDecibelsDown() throws {
        let taps = try HalfBand.taps().map { Float($0) }
        let settled = taps.count
        // In units of the Nyquist frequency of the input: the stop band is 0.6 … 1.
        for frequency in [0.6, 0.61, 0.7, 0.8, 0.9, 0.97, 1.0] {
            let decimator = try HalfBandDecimator(taps: taps)
            let tone = TestSignal.sine(frequency: frequency / 2, sampleRate: 1, count: 6_000, phase: 0.4)
            let output = halved(tone, by: decimator)
            #expect(output.count == 3_000)
            let peak = output[settled...].reduce(0) { max($0, abs($1)) }
            #expect(20 * log10(Double(peak)) <= -80, "a full-scale tone at \(frequency) of the Nyquist frequency leaves at \(20 * log10(Double(peak))) dB")
        }
        // In the pass band a tone comes out as itself, at twice the normalised frequency,
        // delayed by the filter.
        let delay = (taps.count - 1) / 2
        for frequency in [0.01, 0.1, 0.25, 0.39] {
            let decimator = try HalfBandDecimator(taps: taps)
            let tone = TestSignal.sine(frequency: frequency / 2, sampleRate: 1, count: 6_000, phase: 0.4)
            let output = halved(tone, by: decimator)
            var worst = 0.0
            for index in settled ..< 3_000 {
                let expected = sin(2 * Double.pi * frequency / 2 * Double(2 * index - delay) + 0.4)
                worst = max(worst, abs(Double(output[index]) - expected))
            }
            #expect(worst <= 1.5e-3, "a tone at \(frequency) of the Nyquist frequency is off by \(worst)")
        }
    }

    @Test func aDecimatorDoesNotDependOnHowItsInputIsCutAndStartsAgainAfterAReset() throws {
        let taps = try HalfBand.taps().map { Float($0) }
        let noise = TestSignal.whiteNoise(count: 5_001, seed: 519)
        let decimator = try HalfBandDecimator(taps: taps)
        let first = halved(noise, by: decimator)
        #expect(first.count == 2_501, "every other sample, the first included")
        // Sample by sample, on a second decimator.
        let other = try HalfBandDecimator(taps: taps)
        var single: [Float] = []
        var slot: [Float] = [0, 0]
        for sample in noise {
            var value = sample
            let written = slot.withUnsafeMutableBufferPointer { target in other.process(&value, count: 1, into: target.baseAddress!) }
            single += slot[..<written]
        }
        #expect(single == first, "bit for bit, whatever the blocks")
        decimator.reset()
        #expect(halved(noise, by: decimator) == first, "after a reset, the stream of a fresh decimator (ACT-10)")
        #expect(throws: DSPError.self) { _ = try HalfBandDecimator(taps: []) }
    }

    // MARK: The hops (O-17)

    @Test func theHopHalvesFromOctaveToOctaveAndAHopThatCannotIsRefusedWithTheNearestThatCan() throws {
        let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), sampleRate: 48_000)
        let schedule = try ConstantQSchedule(geometry: geometry, hop: 512, filterLength: 53)
        #expect(schedule.hops == [512, 256, 128, 64, 32, 16, 8] && schedule.octaves == 7 && schedule.hop == 512 && schedule.filterLength == 53)
        #expect(try ConstantQSchedule(geometry: geometry, hop: 64, filterLength: 53).hops == [64, 32, 16, 8, 4, 2, 1])

        func refusal(_ hop: Int, octaves: Int = 7) -> String? {
            errorMessage {
                let geometry = try ConstantQGeometry(minimumFrequency: noteFrequency(24), octaves: octaves, sampleRate: 48_000)
                _ = try ConstantQSchedule(geometry: geometry, hop: hop, filterLength: 53)
            }
        }
        let odd = try #require(refusal(500))
        #expect(odd.contains("hop") && odd.contains("a multiple of 64 (2^6)") && odd.contains("the nearest are 448 and 512"), "\(odd)")
        #expect(refusal(100)?.contains("the nearest are 64 and 128") == true && refusal(1_000)?.contains("the nearest are 960 and 1024") == true)
        #expect(refusal(63)?.contains("the nearest is 64") == true && refusal(1)?.contains("the nearest is 64") == true)
        #expect(refusal(0)?.contains("the nearest is 64") == true && refusal(-128) != nil)
        for hop in [64, 128, 448, 512, 4_096] { #expect(refusal(hop) == nil, "\(hop)") }
        // Fewer octaves, more hops; one octave takes any.
        #expect(refusal(500, octaves: 3) == nil && refusal(502, octaves: 3)?.contains("the nearest are 500 and 504") == true)
        #expect(refusal(1, octaves: 1) == nil && refusal(333, octaves: 1) == nil && refusal(0, octaves: 1)?.contains("at least one sample") == true)
        #expect(refusal(1 << 25, octaves: 1)?.contains("longest supported") == true)
    }

    @Test func theStepRefusesAnIllegalHopWhenThePipelineIsAttachedAndNamesTheStage() throws {
        func failure(_ step: ConstantQ) -> DSPError? {
            do {
                try Pipeline { TestGain(1); Tap { step } }.run(on: TestSignal.silence(count: 100), format: mono48)
                return nil
            } catch {
                return error
            }
        }
        let refused = try #require(failure(ConstantQ(hop: 500)))
        guard case .invalidParameter(let stage, let parameter, let reason) = refused else {
            Issue.record("not an invalid parameter: \(refused)")
            return
        }
        #expect(parameter == "hop" && stage.description == "Tap[1] › ConstantQ[0]" && reason.contains("the nearest are 448 and 512"), "\(refused)")
        #expect(failure(ConstantQ(hop: 448)) == nil && failure(ConstantQ(hop: 512)) == nil)
        #expect(failure(ConstantQ(octaves: 8, hop: 448)) != nil && failure(ConstantQ(octaves: 6, hop: 96)) == nil)
        #expect(failure(ConstantQ(hop: 0)) != nil && failure(ConstantQ(hop: -512)) != nil)
    }

    // MARK: Alignment (WP-522b)

    @Test(arguments: [3, 15, 51, 53, 55, 57, 101])
    func everyOctaveLagsTheInputByAWholeNumberOfItsOwnSamples(filterLength: Int) throws {
        let delay = (filterLength - 1) / 2
        for octaves in 1 ... 9 {
            let geometry = try ConstantQGeometry(minimumFrequency: 27.5, octaves: octaves, binsPerOctave: 12, sampleRate: 48_000)
            let schedule = try ConstantQSchedule(geometry: geometry, hop: 1 << (octaves - 1), filterLength: filterLength)
            #expect(schedule.delays.count == octaves && schedule.primes.count == octaves - 1 && schedule.delays[0] == 0)
            #expect(schedule.primes.allSatisfy { $0 == 0 || $0 == 1 })
            // In input samples the lag of depth d is the sum of what each decimator above it
            // adds: its filter's delay and its priming zero, in samples of its own input.
            var lag = 0
            for depth in 0 ..< octaves {
                #expect(lag % (1 << depth) == 0 && schedule.delays[depth] == lag >> depth, "\(octaves) octaves, depth \(depth): a lag of \(lag) input samples")
                if depth < octaves - 1 { lag += (delay + schedule.primes[depth]) << depth }
            }
            // A frame of every depth is complete half its longest atom after its centre.
            for depth in 0 ..< octaves {
                let span = geometry.span(atDepth: depth)
                #expect(schedule.spans[depth] == span && schedule.firstEnds[depth] == schedule.delays[depth] + (span + 1) / 2)
            }
            #expect(schedule.latency == schedule.latencies.max() && schedule.latencies == schedule.latencies.sorted(), "the lowest octave is the last to be complete")
            #expect(schedule.latencies[0] == (schedule.spans[0] + 1) / 2, "the highest octave waits for half its longest atom and nothing else")
        }
    }

    @Test(arguments: [(1, 1), (2, 2), (4, 8), (6, 32)])
    func everyOctaveOfAFrameIsCentredOnTheSameSample(octaves: Int, hop: Int) throws {
        // An impulse on a frame centre. Every atom is symmetric about its centre, so if every
        // octave has a sample exactly there, the magnitudes of a bin over the frames mirror
        // themselves about that frame. A lag of one sample of an octave's own rate breaks it.
        let rate = 16_000.0
        let step = ConstantQ(fmin: .hertz(2_000 / pow(2, Double(octaves - 1))), octaves: octaves, binsPerOctave: 12, hop: hop, sparsity: 0)
        let geometry = try step.geometry(in: try lowering(sampleRate: rate))
        // Frames enough before the impulse and after it for the longest atom to pass over it.
        let reach = geometry.atomLength(ofBin: 0) / 2 / hop
        let centre = (reach + 20) * hop
        let signal = TestSignal.impulse(count: centre + (reach + 120) * hop, at: centre)
        let sink = try complexFrames(of: Pipeline { step }, on: signal, format: SignalFormat(sampleRate: rate), blockSize: 333)
        let frame = centre / hop
        #expect(sink.frameCount > frame + reach + 4, "\(sink.frameCount) frames, the impulse in frame \(frame)")
        var worst = 0.0, sharpest = 0.0
        for bin in 0 ..< geometry.binCount {
            let half = geometry.atomLength(ofBin: bin) / 2 / hop
            let peak = hypot(Double(sink.reals[frame][bin]), Double(sink.imaginaries[frame][bin]))
            #expect(peak > 0)
            for offset in 1 ... max(half, 1) + 2 where frame + offset < sink.frameCount {
                let after = hypot(Double(sink.reals[frame + offset][bin]), Double(sink.imaginaries[frame + offset][bin]))
                let before = hypot(Double(sink.reals[frame - offset][bin]), Double(sink.imaginaries[frame - offset][bin]))
                worst = max(worst, abs(after - before) / peak)
                #expect(after <= peak * (1 + 1e-4) && before <= peak * (1 + 1e-4), "bin \(bin): the frame on the impulse is the largest")
            }
            // What a lag of one sample of the octave's rate would do to the first pair: the
            // slope of a Hann window there, 2π · hop / N of the peak for each side.
            if half >= 2 { sharpest = max(sharpest, 2 * Double.pi * Double(hop) / Double(geometry.atomLength(ofBin: bin))) }
        }
        #expect(worst <= 2e-4, "\(octaves) octaves: the magnitudes before and after the impulse differ by \(worst) of the peak")
        #expect(octaves == 1 || sharpest >= 0.01, "a misplaced octave would show: \(sharpest)")
    }

    // MARK: Latency (WP-522b)

    @Test(arguments: [(7, 36, 512, 0.0), (5, 12, 64, 0.0), (1, 24, 100, 0.0), (6, 24, 96, 5.0)])
    func aFrameLeavesWhenTheLastSampleOfItsLowestOctaveHasArrivedAndNotBefore(octaves: Int, bins: Int, hop: Int, gamma: Double) throws {
        let rate = 22_050.0
        // The highest octave is C7 … C8 whatever their number: 7 octaves start on C1, the default.
        let step = ConstantQ(fmin: .midiNote(108 - 12 * Double(octaves)), octaves: octaves, binsPerOctave: bins, gamma: gamma, hop: hop)
        let geometry = try step.geometry(in: try lowering(sampleRate: rate))
        let latency = try step.strategy.latency(of: geometry, hop: hop, window: .hann, sparsity: 0.01)
        let taps = octaves > 1 ? try HalfBand.taps().count : 1
        let schedule = try ConstantQSchedule(geometry: geometry, hop: hop, filterLength: taps)
        #expect(latency == schedule.latency)

        // Half the longest atom, plus what the decimators above the lowest octave delay it by.
        let scale = 1 << (octaves - 1)
        let half = ((geometry.span(atDepth: octaves - 1) + 1) / 2) * scale
        let filters = ((taps - 1) / 2) * (scale - 1)
        #expect(latency >= half && latency <= half + filters + scale, "\(latency) samples: half the longest atom is \(half), the filters add \(filters)")
        // … and that half atom is the one of the definition, to a sample of the octave's rate.
        #expect(abs(half - (geometry.atomLength(ofBin: 0) + 1) / 2) <= scale)

        // The node says the same, and so does the environment downstream (REAL-5).
        let node = try step.strategy.makeNode(of: geometry, hop: hop, window: .hann, sparsity: 0.01, channel: nil, channelCount: 1, maximumBlockFrames: 512)
        #expect(node.latencyFrames == latency && node.settlingFrames == schedule.settling)
        #expect(schedule.settling >= half - scale && schedule.settling <= half + 2 * filters + 2 * scale, "a frame reaches \(schedule.settling) samples back")
        let format = SignalFormat(sampleRate: rate)
        let noise = TestSignal.whiteNoise(count: latency + 3 * hop + 5, seed: 522)
        // With n samples in, the frames out are those centred on k · hop with k · hop + latency ≤ n.
        for (count, frames) in [(latency - 1, 0), (latency, 1), (latency + hop - 1, 1), (latency + hop, 2), (latency + 3 * hop + 5, 4)] {
            let sink = try complexFrames(of: Pipeline { step }, on: Array(noise[..<count]), format: format, blockSize: 77)
            #expect(sink.frameCount == frames, "\(count) samples in, latency \(latency): \(sink.frameCount) frames out, not \(frames)")
            expectClose(sink.times, (0 ..< sink.frameCount).map { Double($0 * hop) / rate }, .absolute(1e-9), "a frame is stamped with the time of its centre")
            #expect(sink.indices == Array(0 ..< sink.frameCount))
            #expect(sink.environment?.latency == Double(latency) / rate, "the latency is declared: \(String(describing: sink.environment?.latency))")
        }
    }

    @Test func gammaIsTheLeverOnLatency() throws {
        func latency(_ gamma: Double) throws -> Double {
            let sink = try complexFrames(of: Pipeline { ConstantQ(gamma: gamma) }, on: TestSignal.silence(count: 64), format: mono48)
            return try #require(sink.environment?.latency)
        }
        let constant = try latency(0), narrow = try latency(4.45), wide = try latency(8)
        #expect(constant > 0.8 && constant < 0.86, "C1 at constant Q: \(constant) s")
        #expect(narrow < constant / 4 && wide < narrow && wide > 0.03, "with a gamma of 4.45 Hz and of 8 Hz: \(narrow) s, \(wide) s")
    }
}
