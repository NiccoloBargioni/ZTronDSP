import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A median strategy written outside the package's stock set: it wraps the CPU lanes and
/// counts what it is asked for, and where. It is passed the same way as a stock one (§5.3).
struct CountingMedian: MedianStrategy {
    let log: MedianLog

    func makeFilter(kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable) throws(DSPError) -> any MedianFilter {
        log.record(axis, onBackground: BackgroundWork.isCurrent)
        return try SelectionNetworkMedian().makeFilter(kernel: kernel, binCount: binCount, along: axis, implementation: implementation, crossovers: crossovers)
    }

    static func == (lhs: CountingMedian, rhs: CountingMedian) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class MedianLog: @unchecked Sendable {
    // Threading: written where a filter is made, read by the test afterwards; behind a lock.
    private let entries = Locked<[(axis: MedianAxis, onBackground: Bool)]>([])
    func record(_ axis: MedianAxis, onBackground: Bool) { entries.withLock { $0.append((axis, onBackground)) } }
    var axes: [MedianAxis] { entries.get().map { $0.axis } }
    var allOnBackground: Bool { entries.get().allSatisfy { $0.onBackground } }
}

/// The streaming `HarmonicPercussive(select:)` step (WP-531a, WP-531b), and what every step
/// owes (STG-1).
@Suite("Harmonic–percussive step")
struct HarmonicPercussiveTests {
    typealias Magnitudes = Spectrum<LinearFrequency, MagnitudeValues>
    typealias Complex = Spectrum<LinearFrequency, ComplexValues>
    private let noise = TestSignal.whiteNoise(count: 12_000, seed: 531, amplitude: 0.5)

    /// A signal with something of each kind: a chord, clicks and noise.
    private var mixture: [Float] {
        TestSignal.sum(TestSignal.harmonic(fundamental: 330, amplitudes: [0.3, 0.2, 0.1, 0.05], sampleRate: 48_000, count: 24_000),
                       TestSignal.clickTrack(beatsPerMinute: 480, sampleRate: 48_000, count: 24_000, amplitude: 0.5),
                       TestSignal.whiteNoise(count: 24_000, seed: 5, amplitude: 0.01))
    }

    /// The offline separation of frames: the medians of the whole spectrogram, centred, with
    /// both edges reflected, on CPU lanes.
    private func offline(_ frames: [[Float]], timeKernel: Int, frequencyKernel: Int, mask: any MaskStrategy = SoftMask(), harmonicMargin: Double = 1,
                         percussiveMargin: Double = 1) throws -> OfflineSeparation {
        try OfflineSeparation(
            frames.flatMap { $0 }, binCount: frames[0].count, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask,
            harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: 1e-10, median: SelectionNetworkMedian(), crossovers: .shipped, checkpoint: nil)
    }

    // MARK: Centred: ≡ offline; latency equals the look-ahead (WP-531b)

    @Test(arguments: [0, 1, 2])
    func theCentredStepEqualsTheOfflineSeparation(caseIndex: Int) throws {
        let (fixture, hop, timeKernel, frequencyKernel) = [("music", 512, 31, 31), ("speech", 256, 17, 31), ("music", 512, 5, 3)][caseIndex]
        let (spectrogram, format) = try separationSpectrogram(of: fixture, hop: hop)
        let samples = try GoldenFile(named: "fixtures", in: .module).require(fixture).floats("samples")
        let bins = spectrogram[0].count, ahead = (timeKernel - 1) / 2
        let reference = try offline(spectrogram, timeKernel: timeKernel, frequencyKernel: frequencyKernel)
        for component in HarmonicPercussiveComponent.allCases {
            let expected = try reference.masked(component, applied: true, checkpoint: nil)
            let sink = CollectingSink<Magnitudes>()
            try Pipeline {
                STFT(frame: 1_024, hop: hop, alignment: .centered); Magnitude()
                HarmonicPercussive(select: component, timeKernel: timeKernel, frequencyKernel: frequencyKernel, alignment: .centered)
                Emit(to: sink)
            }.run(on: samples, format: format, blockSize: 441)
            // A stream is still waiting for the look-ahead of its last frames.
            #expect(sink.frameCount == spectrogram.count - ahead, "\(fixture), \(component): \(sink.frameCount) frames")
            for (index, frame) in sink.reals.enumerated() {
                #expect(frame == Array(expected[index * bins ..< (index + 1) * bins]), "\(fixture), \(component), frame \(index): the offline result, bit for bit, the left edge included")
            }
        }
        print("measured WP-531b: \(fixture), kernels \(timeKernel) and \(frequencyKernel): \(spectrogram.count - ahead) frames of \(bins) bins equal the offline separation exactly, for each component")
    }

    @Test func theLookAheadIsLatencyAndFramesKeepTheirTimes() throws {
        let plain = CollectingSink<Magnitudes>(), centred = CollectingSink<Magnitudes>(), causal = CollectingSink<Magnitudes>()
        let framing = Pipeline { STFT(frame: 1_024, hop: 256); Magnitude() }
        try framing.emit(to: plain).run(on: noise, format: mono48, blockSize: 441)
        try framing.harmonicPercussive(select: .harmonic, timeKernel: 17, alignment: .centered).emit(to: centred).run(on: noise, format: mono48, blockSize: 441)
        try framing.harmonicPercussive(select: .harmonic, timeKernel: 17).emit(to: causal).run(on: noise, format: mono48, blockSize: 441)
        // Centred: eight frames of look-ahead, declared as latency (REAL-5); a frame is stamped
        // with the time of the spectrum it describes.
        #expect(centred.environment?.latency == 8 * 256 / 48_000.0 && plain.environment?.latency == 0)
        #expect(centred.frameCount == plain.frameCount - 8 && centred.times == Array(plain.times.dropLast(8)), "content times, to the bit")
        #expect(centred.indices == Array(0 ..< centred.frameCount))
        // Causal: a frame for every frame, at its time, and no latency.
        #expect(causal.environment?.latency == 0 && causal.frameCount == plain.frameCount && causal.times == plain.times)
        // The scope and the axis are kept.
        #expect(centred.axis == plain.axis && centred.environment?.frameSize == 1_024 && centred.environment?.hopSize == 256 && centred.environment?.featureRate == 187.5)
        #expect(HarmonicPercussive.lookAhead(timeKernel: 31, alignment: .centered) == 15 && HarmonicPercussive.lookAhead(timeKernel: 31, alignment: .causal) == 0)
        let node = try HarmonicPercussiveNode(
            component: .harmonic, binCount: 33, isComplex: false, lookAhead: 8, settling: 8, timeMedian: try TimeLaneMedian(kernel: 17, binCount: 33),
            frequencyMedian: try FrequencyLaneMedian(kernel: 17, binCount: 33), mask: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10,
            featureRate: 187.5)
        #expect(node.latencyFrames == 8 && node.settlingFrames == 8, "the latency is the look-ahead; settled once the time kernel holds only new frames")
    }

    // MARK: Causal: ≡ offline on interior frames (WP-531a)

    /// What the causal step gives for every frame: the running median along time as the oracle
    /// defines it, the median along frequency of the frame itself, the masks, the frame under them.
    private func causalReference(
        _ spectrogram: [[Float]], _ component: HarmonicPercussiveComponent, timeKernel: Int, frequencyKernel: Int, timeMedians: [[Float]]? = nil
    ) throws -> [[Float]] {
        let bins = spectrogram[0].count
        let along = timeMedians ?? MedianOracle.running(spectrogram, kernel: timeKernel)
        let masks = try SeparationMasks(binCount: bins, strategy: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10)
        return spectrogram.indices.map { frame in
            let across = MedianOracle.filter(spectrogram[frame], rowCount: bins, kernel: frequencyKernel, along: .frequency)
            var mask = [Float](repeating: 0, count: bins)
            along[frame].withUnsafeBufferPointer { h in across.withUnsafeBufferPointer { p in
                mask.withUnsafeMutableBufferPointer { masks.mask(component, timeMedian: h.baseAddress!, frequencyMedian: p.baseAddress!, into: $0.baseAddress!) }
            } }
            return zip(spectrogram[frame], mask).map { $0 * $1 }
        }
    }

    @Test(arguments: [0, 1])
    func theCausalStepEqualsTheOfflineMediansOnInteriorFrames(caseIndex: Int) throws {
        let (fixture, hop, timeKernel, frequencyKernel) = [("music", 512, 31, 31), ("speech", 256, 17, 17)][caseIndex]
        let (spectrogram, format) = try separationSpectrogram(of: fixture, hop: hop)
        let samples = try GoldenFile(named: "fixtures", in: .module).require(fixture).floats("samples")
        let bins = spectrogram[0].count, reach = (timeKernel - 1) / 2
        // Causal, the time median of frame t is taken over t − kernel + 1 … t: the centred
        // median of frame t − reach, as the offline separation computes it. The frequency
        // median and the mask are those of frame t.
        let offlineMedians = try offline(spectrogram, timeKernel: timeKernel, frequencyKernel: frequencyKernel).timeMedian
        let shifted = spectrogram.indices.map { frame -> [Float] in
            let source = max(frame - reach, 0)
            return Array(offlineMedians[source * bins ..< (source + 1) * bins])
        }
        var interior = 0
        for component in HarmonicPercussiveComponent.allCases {
            let frames: [[Float]] = try Pipeline {
                STFT(frame: 1_024, hop: hop, alignment: .centered); Magnitude()
                HarmonicPercussive(select: component, timeKernel: timeKernel, frequencyKernel: frequencyKernel)
            }.process(samples, format: format, blockSize: 441)
            #expect(frames.count == spectrogram.count, "\(component): a frame for every frame, from the first")
            let fromOffline = try causalReference(spectrogram, component, timeKernel: timeKernel, frequencyKernel: frequencyKernel, timeMedians: shifted)
            // The oracle's running median says what the first frames are, too: the frames there are, reflected.
            let fromOracle = try causalReference(spectrogram, component, timeKernel: timeKernel, frequencyKernel: frequencyKernel)
            for frame in frames.indices {
                if frame >= 2 * reach {
                    #expect(frames[frame] == fromOffline[frame], "\(fixture), \(component), frame \(frame): the offline medians")
                    interior += 1
                }
                #expect(frames[frame] == fromOracle[frame], "\(fixture), \(component), frame \(frame): the running median")
            }
        }
        print("measured WP-531a: \(fixture), kernels \(timeKernel) and \(frequencyKernel): \(interior / 3) interior frames of \(bins) bins equal the offline medians exactly, for each component")
    }

    // MARK: On a complex spectrum the phase is kept

    @Test func onAComplexSpectrumTheMaskIsAppliedAndThePhaseKept() throws {
        let signal = mixture
        let stft = STFT(frame: 1_024, hop: 256)
        for (component, alignment) in [(HarmonicPercussiveComponent.harmonic, FrameAlignment.causal), (.percussive, .centered), (.residual, .causal)] {
            let step = HarmonicPercussive(select: component, timeKernel: 17, frequencyKernel: 17, harmonicMargin: 2, percussiveMargin: 2, alignment: alignment)
            let complex = try complexFrames(of: Pipeline { stft; step }, on: signal)
            let magnitudes: [[Float]] = try Pipeline { stft; Magnitude(); step }.process(signal, format: mono48)
            let spectra = try complexFrames(of: Pipeline { stft }, on: signal)
            let ahead = alignment == .centered ? 8 : 0
            // On a complex spectrum a centred step is a delay line: a frame out for every frame
            // in, the first of them the silence it begins with.
            #expect(complex.frameCount == spectra.frameCount && magnitudes.count == spectra.frameCount - ahead)
            #expect(complex.reals[..<ahead].allSatisfy { $0.allSatisfy { $0 == 0 } } && complex.imaginaries[..<ahead].allSatisfy { $0.allSatisfy { $0 == 0 } })
            var worst = 0.0, turned = 0.0
            for frame in magnitudes.indices {
                let real = complex.reals[frame + ahead], imaginary = complex.imaginaries[frame + ahead]
                let peak = Double(magnitudes[frame].max() ?? 0) + 1e-12
                for bin in real.indices {
                    // Its magnitude is the component's magnitude …
                    worst = max(worst, abs(Double(hypot(real[bin], imaginary[bin])) - Double(magnitudes[frame][bin])) / peak)
                    // … and its phase is that of the bin it came from: the cross product with it is zero.
                    let re = Double(spectra.reals[frame][bin]), im = Double(spectra.imaginaries[frame][bin])
                    turned = max(turned, abs(Double(real[bin]) * im - Double(imaginary[bin]) * re) / (peak * (hypot(re, im) + 1e-12)))
                    #expect(Double(real[bin]) * re + Double(imaginary[bin]) * im >= 0, "never turned by half a turn")
                }
            }
            #expect(worst <= 1e-6 && turned <= 1e-6, "\(component), \(alignment): magnitudes off by \(worst) of the frame maximum, phases by \(turned)")
            // A frame keeps the time of the spectrum it describes; the silence before the first
            // takes the times the stream would have had before it began, one hop apart.
            #expect(Array(complex.times.dropFirst(ahead)) == Array(spectra.times.dropLast(ahead)))
            for frame in 0 ..< ahead {
                expectClose(complex.times[frame], spectra.times[0] - Double(ahead - frame) * 256 / 48_000, .absolute(1e-9), "lead-in frame \(frame)")
            }
        }
    }

    @Test func theThreeComponentsAddUpToTheSpectrum() throws {
        let stft = STFT(frame: 1_024, hop: 256)
        let spectrum: [[Float]] = try Pipeline { stft; Magnitude() }.process(mixture, format: mono48)
        for (mask, margins) in [(SoftMask(power: 2) as any MaskStrategy, (1.0, 1.0)), (SoftMask(power: 1), (2.0, 3.0)), (HardMask(), (1.0, 1.0)), (HardMask(), (2.0, 2.0))] {
            func component(_ component: HarmonicPercussiveComponent) throws -> [[Float]] {
                func step<M: MaskStrategy>(_ mask: M) -> HarmonicPercussive {
                    HarmonicPercussive(select: component, timeKernel: 17, frequencyKernel: 17, mask: mask, harmonicMargin: margins.0, percussiveMargin: margins.1)
                }
                return try Pipeline { stft; Magnitude(); step(mask) }.process(mixture, format: mono48)
            }
            let harmonic = try component(.harmonic), percussive = try component(.percussive), residual = try component(.residual)
            var worst = 0.0
            for frame in spectrum.indices {
                let peak = Double(spectrum[frame].max() ?? 0) + 1e-12
                for bin in spectrum[frame].indices {
                    worst = max(worst, abs(Double(harmonic[frame][bin]) + Double(percussive[frame][bin]) + Double(residual[frame][bin]) - Double(spectrum[frame][bin])) / peak)
                    #expect(harmonic[frame][bin] >= 0 && percussive[frame][bin] >= 0 && residual[frame][bin] >= 0)
                }
            }
            #expect(worst <= 1e-6, "\(mask), margins \(margins): off by \(worst) of the frame maximum")
        }
        // A chord is harmonic and a click is percussive: each lands where it belongs.
        let harmonic: [[Float]] = try Pipeline { stft; Magnitude(); HarmonicPercussive(select: .harmonic, alignment: .centered) }
            .process(TestSignal.harmonic(fundamental: 330, amplitudes: [0.5], sampleRate: 48_000, count: 24_000), format: mono48)
        let tone: [[Float]] = try Pipeline { stft; Magnitude() }.process(TestSignal.harmonic(fundamental: 330, amplitudes: [0.5], sampleRate: 48_000, count: 24_000), format: mono48)
        let kept = harmonic[20].reduce(0) { $0 + Double($1) * Double($1) } / tone[20].reduce(0) { $0 + Double($1) * Double($1) }
        #expect(kept > 0.99, "\(kept) of the energy of a steady tone is harmonic")
    }

    @Test func itFollowsMagnitudesOnAnyAxis() throws {
        let sink = CollectingSink<Spectrum<MelFrequency, MagnitudeValues>>()
        try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 40); HarmonicPercussive(select: .percussive, timeKernel: 9, frequencyKernel: 5); Emit(to: sink) }
            .run(on: noise, format: mono48)
        let mel: [[Float]] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); MelScale(bands: 40) }.process(noise, format: mono48)
        guard case .mel(let centers)? = sink.axis else { Issue.record("the axis is \(String(describing: sink.axis))"); return }
        #expect(centers.count == 40 && sink.frameCount == mel.count && sink.reals.allSatisfy { $0.count == 40 })
        let expected = try causalReference(mel, .percussive, timeKernel: 9, frequencyKernel: 5)
        #expect(sink.reals == expected, "the same medians and masks, whatever the rows are")
    }

    // MARK: Order (O-2), both tiers

    @Test func theRuleOfTheDescriptionIsTheRuleOfTheTypes() throws {
        for axis in [DomainTag.Axis.linear, .mel, .constantQ] {
            for values in [DomainTag.Values.complex, .magnitude, .power, .decibel] {
                let accepted = values == .magnitude || (values == .complex && axis == .linear)
                #expect(HarmonicPercussive.rule(.spectrum(axis: axis, values: values)) == (accepted ? .spectrum(axis: axis, values: values) : nil), "\(axis), \(values)")
            }
        }
        for tag in [DomainTag.samples, .novelty, .scalar, .quefrency, .lags, .chroma] { #expect(HarmonicPercussive.rule(tag) == nil, "\(tag)") }
        let step = HarmonicPercussive(select: .harmonic).stageDescription
        let spectrum = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256))
        #expect(try spectrum.appending(step).outputTag == .spectrum(axis: .linear, values: .complex))
        #expect(try spectrum.appending(Magnitude().stageDescription).appending(step).appending(step).outputTag == .spectrum(axis: .linear, values: .magnitude), "it keeps the domain")
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Power().stageDescription).appending(step) }
        #expect(throws: DSPError.self) { _ = try spectrum.appending(Magnitude().stageDescription).appending(Decibels().stageDescription).appending(step) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(step) }
    }

    @Test func descriptionsSpellingsAndActivation() throws {
        let stft = STFT(frame: 1_024, hop: 256)
        #expect(Pipeline { stft; HarmonicPercussive(select: .harmonic) } == Pipeline().appending(stft).harmonicPercussive(select: .harmonic))
        #expect(Pipeline { stft; Magnitude(); HarmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 9, mask: .hard, harmonicMargin: 2, percussiveMargin: 3,
                                                                  alignment: .centered, median: .automatic, floor: 1e-6, isActive: false) }
            == Pipeline().appending(stft).magnitude().harmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 9, mask: .hard, harmonicMargin: 2,
                                                                         percussiveMargin: 3, alignment: .centered, median: .automatic, floor: 1e-6, isActive: false))
        let base = Pipeline().appending(stft)
        let plain = base.harmonicPercussive(select: .harmonic)
        #expect(plain == base.harmonicPercussive(select: .harmonic, timeKernel: 31, frequencyKernel: 31, mask: .soft(power: 2), harmonicMargin: 1, percussiveMargin: 1,
                                                 alignment: .causal, median: .selectionNetwork, floor: 1e-10, isActive: true))
        #expect(plain != base.harmonicPercussive(select: .percussive) && plain != base.harmonicPercussive(select: .harmonic, timeKernel: 17))
        #expect(plain != base.harmonicPercussive(select: .harmonic, frequencyKernel: 17) && plain != base.harmonicPercussive(select: .harmonic, mask: .hard))
        #expect(plain != base.harmonicPercussive(select: .harmonic, mask: .soft(power: 1)) && plain != base.harmonicPercussive(select: .harmonic, harmonicMargin: 2))
        #expect(plain != base.harmonicPercussive(select: .harmonic, percussiveMargin: 2) && plain != base.harmonicPercussive(select: .harmonic, alignment: .centered))
        #expect(plain != base.harmonicPercussive(select: .harmonic, median: .automatic) && plain != base.harmonicPercussive(select: .harmonic, floor: 0))
        let step = HarmonicPercussive(select: .residual, mask: .hard, median: .automatic)
        #expect(step.mask is HardMask && step.median is AutomaticMedian && step.component == .residual && HarmonicPercussive.stageName == "HarmonicPercussive")
        #expect(HarmonicPercussive(select: .harmonic).mask is SoftMask && HarmonicPercussive(select: .harmonic).median is SelectionNetworkMedian)

        // It keeps the domain: switched off for good it is bypassed, and leaves no trace (ACT-3, ACT-4).
        let dark = CollectingSink<Magnitudes>(), plainMagnitudes = CollectingSink<Magnitudes>()
        let off = Pipeline { stft; Magnitude(); HarmonicPercussive(select: .harmonic, timeKernel: 17, alignment: .centered, isActive: false); Emit(to: dark) }
        try off.run(on: noise, format: mono48)
        try Pipeline { stft; Magnitude(); Emit(to: plainMagnitudes) }.run(on: noise, format: mono48)
        #expect(dark.frameCount == plainMagnitudes.frameCount && dark.reals == plainMagnitudes.reals && dark.times == plainMagnitudes.times, "the magnitudes pass, unmasked")
        let names = nodeNames(try lowered(off).steps)
        #expect(dark.environment?.latency == 0 && names == ["STFT", "Magnitude"], "no node, and no latency")
        // Two components in two taps: the framing before them is computed once (F5).
        let a = CollectingSink<Magnitudes>(), b = CollectingSink<Magnitudes>()
        let shared = Pipeline {
            Tap { stft; Magnitude(); HarmonicPercussive(select: .harmonic, timeKernel: 5, frequencyKernel: 5); Emit(to: a) }
            Tap { stft; Magnitude(); HarmonicPercussive(select: .percussive, timeKernel: 5, frequencyKernel: 5); Emit(to: b) }
        }
        #expect(nodeNames(try lowered(shared).steps) == ["STFT", "Magnitude", "HarmonicPercussive", "HarmonicPercussive"])
        try shared.run(on: noise, format: mono48)
        #expect(a.frameCount == b.frameCount && a.frameCount == 43 && a.reals != b.reals)
    }

    // MARK: The median strategy of a live step (GPU-1)

    @Test func aLiveFrameIsFilteredOnCPULanesWhateverTheStrategy() throws {
        let framing = Pipeline { STFT(frame: 512, hop: 128); Magnitude() }
        let lanes: [[Float]] = try framing.harmonicPercussive(select: .harmonic, timeKernel: 9, frequencyKernel: 9).process(noise, format: mono48)
        let automatic: [[Float]] = try framing.harmonicPercussive(select: .harmonic, timeKernel: 9, frequencyKernel: 9, median: .automatic).process(noise, format: mono48)
        #expect(automatic == lanes, ".automatic is the CPU for a live frame")
        // Either lane exchange gives the same medians (SEL-6): the environment may force one.
        for implementation in [Implementation.native, .accelerate, .metal] {
            let forced: [[Float]] = try framing.harmonicPercussive(select: .harmonic, timeKernel: 9, frequencyKernel: 9).environment(\.implementation, implementation)
                .process(noise, format: mono48)
            #expect(forced == lanes, "\(implementation)")
        }
        // The GPU median filters whole spectrograms: a live step declared with it is refused when it is attached.
        let refusal = errorMessage { let _: [[Float]] = try framing.harmonicPercussive(select: .harmonic, median: .metal).process(noise, format: mono48) }
        #expect(refusal?.contains("the GPU median filters whole spectrograms offline") == true && refusal?.contains("HarmonicPercussive") == true, "\(refusal ?? "no error")")
        // A strategy written outside makes the filters of the step: one along time, one along frequency.
        let log = MedianLog()
        let own: [[Float]] = try framing.harmonicPercussive(select: .harmonic, timeKernel: 9, frequencyKernel: 9, median: CountingMedian(log: log)).process(noise, format: mono48)
        #expect(own == lanes && log.axes.filter { $0 == .time }.count >= 1 && log.axes.filter { $0 == .frequency }.count >= 1)
    }

    // MARK: Attach-time checks

    @Test func nonsenseIsRefusedWhenThePipelineIsAttached() {
        func refusal(_ step: HarmonicPercussive) -> String? {
            errorMessage { let _: [[Float]] = try Pipeline { STFT(frame: 512, hop: 128); Magnitude(); step }.process(noise, format: mono48) }
        }
        for kernel in [0, 2, 30, 257, -3] {
            #expect(refusal(HarmonicPercussive(select: .harmonic, timeKernel: kernel))?.contains("Invalid parameter timeKernel") == true, "\(kernel)")
            #expect(refusal(HarmonicPercussive(select: .harmonic, frequencyKernel: kernel))?.contains("Invalid parameter frequencyKernel") == true, "\(kernel)")
        }
        #expect(refusal(HarmonicPercussive(select: .harmonic, harmonicMargin: 0.5))?.contains("Invalid parameter harmonicMargin") == true)
        #expect(refusal(HarmonicPercussive(select: .harmonic, percussiveMargin: .infinity))?.contains("Invalid parameter percussiveMargin") == true)
        #expect(refusal(HarmonicPercussive(select: .harmonic, floor: -1))?.contains("Invalid parameter floor") == true)
        #expect(refusal(HarmonicPercussive(select: .harmonic, mask: .soft(power: 0)))?.contains("Invalid parameter mask") == true)
        #expect(refusal(HarmonicPercussive(select: .harmonic, timeKernel: 1, frequencyKernel: 255)) == nil, "a kernel wider than the frame reflects more than once")
        // Frames of the right domain from a stage that opens no scope: no axis, no feature rate.
        #expect(errorMessage { let _: [[Float]] = try Pipeline { FixedFrames<Magnitudes>([Float](repeating: 1, count: 33)); HarmonicPercussive(select: .harmonic) }
            .process(noise, format: mono48) }?.contains("HarmonicPercussive needs the frames of a spectral scope") == true)
    }

    // MARK: Cold start (ACT-10)

    @Test func aColdStartRefillsTheHistoryOfTheMedian() throws {
        let short = Array(noise[..<6_000])
        let framing = Pipeline { STFT(frame: 256, hop: 64); Magnitude() }
        for alignment in [FrameAlignment.causal, .centered] {
            try expectAFreshStreamAfterAColdStart(of: framing.harmonicPercussive(select: .harmonic, timeKernel: 17, frequencyKernel: 5, alignment: alignment), on: short,
                                                  "HarmonicPercussive on magnitudes, \(alignment)")
            try expectAFreshStreamAfterAColdStart(
                of: Pipeline { STFT(frame: 256, hop: 64); HarmonicPercussive(select: .percussive, timeKernel: 9, frequencyKernel: 9, alignment: alignment) }, on: short,
                "HarmonicPercussive on a complex spectrum, \(alignment)")
        }
        // No stale frame: centred, the second pass waits for its look-ahead again.
        let cold = try twoPasses(of: framing.harmonicPercussive(select: .harmonic, timeKernel: 17, alignment: .centered), on: short, coldStart: true)
        let frames = (6_000 - 256) / 64 + 1
        #expect(cold.frameCount == 2 * (frames - 8))
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodeRunsWithoutAllocating() throws {
        let harmonic = CountingSink<Complex>(), percussive = CountingSink<Magnitudes>(), residual = CountingSink<Magnitudes>(), hard = CountingSink<Complex>()
        try expectNoAllocationsRunning(
            Pipeline().stft(frame: 2_048, hop: 512)
                .tap { $0.harmonicPercussive(select: .harmonic).emit(to: harmonic) }
                .tap { $0.magnitude().harmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 17, alignment: .centered).emit(to: percussive) }
                .tap { $0.magnitude().harmonicPercussive(select: .residual, mask: .soft(power: 1.5), harmonicMargin: 2, percussiveMargin: 2).emit(to: residual) }
                .tap { $0.harmonicPercussive(select: .percussive, timeKernel: 5, frequencyKernel: 5, mask: .hard, alignment: .centered).emit(to: hard) })
        #expect(harmonic.frames > 990 && percussive.frames > 990 && residual.frames > 990 && hard.frames > 990)
        // The other lane exchange.
        let forced = CountingSink<Magnitudes>()
        try expectNoAllocationsRunning(
            Pipeline().stft(frame: 1_024, hop: 256).magnitude().harmonicPercussive(select: .harmonic, timeKernel: 17, frequencyKernel: 17).emit(to: forced)
                .environment(\.implementation, .accelerate), blocks: 500)
        #expect(forced.frames > 990)
    }
}
