// The order rules of convolution and autocorrelation, of the onset strength and the
// tempograms, and of the harmonic–percussive separation, as far as they accept (§5.8, §6.7,
// §6.9, §6.10): every stage where it belongs, in the builder and in the fluent spelling, with
// its recipe, its switch and strategies written outside the package.
import SwiftUI
import ZTronDSP
import ZTronDSPTesting

// A sequence stage of the fixture's own: the rules below do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

@MainActor func accepted(flag: Bool, shown: Binding<Bool>, level: Binding<Float>, onset: Binding<ScalarFrame>, vector: Binding<[Float]>,
                         lagFeed: HeatmapFeed, tempoFeed: HeatmapFeed, heat: HeatmapFeed, chromagram: HeatmapFeed, impulseResponse: [Float]) {
    // O-1: a convolution is a sequence stage. It keeps the domain, so it may be absent (O-13).
    let convolved: Pipeline<Samples, Samples> = Pipeline {
        Convolve(kernel: impulseResponse)
        Convolve(kernel: [0.25, 0.5, 0.25], strategy: .direct, isActive: shown)
        if flag { Convolve(kernel: impulseResponse, strategy: .partitioned) }
        for _ in 0 ..< 2 { Convolve(kernel: [0.5, 0.5], strategy: .fft, isActive: false) }
        Halve()
    }
    // O-1: an autocorrelation frames a sampled sequence. A block may begin with it, or with
    // sequence stages and then it: the block is then taken to start from samples.
    let lags: Pipeline<Samples, Lags> = Pipeline {
        Autocorrelation(window: 2_048, hop: 512, maxLag: 1_024, normalization: .coefficient, floor: 1e-12, channels: .mixdown, backend: .vDSP)
        Emit(to: lagFeed)                                    // O-11: lags are real vectors
    }
    let filteredLags: Pipeline<Samples, Lags> = Pipeline {
        Halve()
        Convolve(kernel: [1, -1])
        Autocorrelation(isActive: shown)
        Emit(to: vector)
    }
    // … and after a scalar track, whose values it frames as it frames samples.
    let trackLags: Pipeline<Samples, Lags> = Pipeline {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        SpectralCentroid()
        Convolve(kernel: [0.5, 0.5])                         // O-1: a sequence stage on a scalar track
        Autocorrelation(window: 64, hop: 8, normalization: .unbiased)
    }
    // O-9: the onset strength follows a spectrum in decibels, by custom a mel spectrum; the
    // tempogram follows the novelty curve, and sequence stages may stand between the two.
    let tempo: Pipeline<Samples, TempoSpectrum> = Pipeline {
        STFT(frame: 2_048, hop: 512)
        Power()
        MelScale(bands: 128)
        Decibels()
        OnsetStrength(lag: 1, maxSize: 3, floor: -80)
        Emit(to: level)                                      // O-11: a novelty value fits a binding of one
        Emit(to: onset)
        Halve()                                              // O-1: sequence stages on a novelty curve
        Convolve(kernel: [0.25, 0.5, 0.25])
        Tap(isActive: shown) {                               // O-15: the branch starts from the novelty curve
            Tempogram(.fourier(resolution: 8), window: 256, taper: .hamming, range: 60 ... 240, alignment: .centered)
            Emit(to: vector)
        }
        Tempogram(.autocorrelation, window: 384, taper: .hann, range: 30 ... 300, alignment: .causal)
        Emit(to: tempoFeed)                                  // O-11: a tempogram column is a real vector
    }
    // O-9 on the other axes; the lags of a novelty curve; a tempogram that is switched.
    let linear: Pipeline<Samples, Lags> = Pipeline {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        Decibels()
        OnsetStrength(isActive: shown)
        Autocorrelation(window: 128, hop: 1, normalization: .coefficient)
    }
    let constantQ: Pipeline<Samples, TempoSpectrum> = Pipeline {
        ConstantQ()
        Power()
        Decibels()
        OnsetStrength(lag: 2)
        Tempogram(flag ? .fourier : .fourier(resolution: 2), isActive: shown)
    }
    // O-2: the separation follows the complex spectrum of an STFT, whose phase it keeps, or
    // magnitudes on any axis; either way the domain stays what it was.
    let analysis = STFT(frame: 2_048, hop: 512)
    let harmonic: Pipeline<Samples, Samples> = Pipeline {
        analysis
        HarmonicPercussive(select: .harmonic, timeKernel: 17, frequencyKernel: 17, mask: .soft(power: 1), harmonicMargin: 2, percussiveMargin: 2,
                           alignment: .centered, median: .selectionNetwork, floor: 1e-10)
        HarmonicPercussive(select: flag ? .residual : .percussive, mask: .hard, isActive: shown)
        analysis.inverse                                     // O-6: the spectrum is still complex
    }
    let percussive: Pipeline<Samples, Spectrum<MelFrequency, DecibelValues>> = Pipeline {
        STFT(frame: 2_048, hop: 512)
        Magnitude()
        HarmonicPercussive(select: .percussive)
        MelScale(bands: 64)
        HarmonicPercussive(select: .percussive, median: .automatic, isActive: false)
        Decibels()
        Emit(to: heat)
    }
    let sustained: Pipeline<Samples, Chroma> = Pipeline {
        ConstantQ()
        Magnitude()
        HarmonicPercussive(select: .harmonic, timeKernel: 9, frequencyKernel: 9)
        ChromaFold()
    }
    // The recipe takes samples and returns them, so it stands among sequence stages (§5.2,
    // O-12) and may be absent (O-13).
    let drums: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        HPSS(select: .percussive)
        HPSS(select: .harmonic, frame: 1_024, hop: 256, window: .hann, timeKernel: 17, frequencyKernel: 17, mask: .hard, harmonicMargin: 2,
             percussiveMargin: 2, alignment: .centered, median: .selectionNetwork, channels: .mixdown, isActive: shown)
        if flag { HPSS(select: .residual, isActive: false) }
        Level(.peak, to: level)
    }
    // The stock full analysis of §10.4, as an app declares it.
    let full: Pipeline<Samples, Samples> = Pipeline {
        Spectrogram(frame: 2_048, hop: 512, to: heat)
        Tap { STFT(frame: 2_048, hop: 512); Magnitude(); SpectralCentroid(to: level) }
        ChromaCQT(octaves: 6, to: chromagram)
        HPSS(select: .harmonic, timeKernel: 17, frequencyKernel: 17)
        Tap {
            STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels()
            OnsetStrength()
            Tempogram(.autocorrelation)
            Emit(to: tempoFeed)
        }
    }
    // The fluent spelling gives the same descriptions (API-1); a branch that begins with a
    // step of a family is written this way (ORD-3), on whichever sequence it taps.
    let fluent = Pipeline()
        .convolve(kernel: impulseResponse)
        .convolve(kernel: [1, -1], strategy: .fft, isActive: shown)
        .hpss(select: .percussive, timeKernel: 17, frequencyKernel: 17)
        .tap { $0.autocorrelation(window: 1_024, hop: 256, maxLag: 512, normalization: .biased).emit(to: lagFeed) }
        .stft(frame: 2_048, hop: 512)
        .tap {
            $0.magnitude().harmonicPercussive(select: .harmonic).melScale(bands: 40).harmonicPercussive(select: .harmonic, mask: .hard)
                .decibels().onsetStrength(lag: 2, maxSize: 3)
                .tap { $0.autocorrelation(window: 128, hop: 1).emit(to: lagFeed) }
                .convolve(kernel: [0.5, 0.5])
                .tempogram(.fourier(resolution: 8), window: 256, range: 60 ... 240).emit(to: tempoFeed)
        }
        .harmonicPercussive(select: .percussive, alignment: .centered)
        .inverseSTFT()
    _ = (convolved, lags, filteredLags, trackLags, tempo, linear, constantQ, harmonic, percussive, sustained, drums, full, fluent)
}

// An attached pipeline starts from samples (O-12): each of these does.
func attached(engine: DSPEngine, source: any SampleSource, tempoFeed: HeatmapFeed) async throws {
    _ = try await engine.attach(Pipeline { Autocorrelation(); Emit(to: tempoFeed) }, to: source)
    _ = try await engine.attach(Pipeline { HPSS(select: .harmonic); Convolve(kernel: [1]) }, to: source)
    _ = try await engine.attach(
        Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels(); OnsetStrength(); Tempogram(); Emit(to: tempoFeed) },
        to: source)
}

// Strategies written outside the package are passed the same way as the stock ones (§5.3).
final class FlatRows: TempogramTransform {
    let beatsPerMinute: [Double] = [60, 120, 240]
    func transform(_ segment: UnsafePointer<Float>, into column: UnsafeMutablePointer<Float>) {
        var row = 0
        while row < 3 {
            column[row] = abs(segment[row])
            row += 1
        }
    }
}

struct ThreeRows: TempogramMethod {
    func makeTransform(window: Int, featureRate: Double, range: ClosedRange<Double>) throws(DSPError) -> any TempogramTransform { FlatRows() }
}

struct EqualShares: MaskStrategy {
    func mask(_ component: UnsafePointer<Float>, against competitor: UnsafePointer<Float>, floor: Float, into mask: UnsafeMutablePointer<Float>, count: Int) {
        var index = 0
        while index < count {
            mask[index] = component[index] >= floor ? 0.5 : 0
            index += 1
        }
    }
}

final class Passing: MedianFilter {
    let count: Int
    init(count: Int) { self.count = count }
    func process(_ frame: UnsafePointer<Float>, into medians: UnsafeMutablePointer<Float>) { medians.update(from: frame, count: count) }
    func reset() {}
}

struct NoMedian: MedianStrategy {
    func makeFilter(kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable) throws(DSPError) -> any MedianFilter {
        Passing(count: binCount)
    }
}

func custom() {
    let rhythm = Pipeline { STFT(frame: 2_048, hop: 512); Power(); Decibels(); OnsetStrength(); Tempogram(ThreeRows(), window: 16) }
    let separation = Pipeline { STFT(frame: 2_048, hop: 512); HarmonicPercussive(select: .harmonic, mask: EqualShares(), median: NoMedian()) }
    let recipe = Pipeline { HPSS(select: .percussive, mask: EqualShares(), median: NoMedian()) }
    _ = (rhythm, separation, recipe, Tempogram().method, HarmonicPercussive(select: .harmonic).mask, HarmonicPercussive(select: .harmonic).median,
         AutocorrelationTempogram(floor: 1e-8).floor, FourierTempogram(resolution: 2).resolution, SoftMask(power: 3).power, HardMask(),
         HPSS(select: .harmonic).expansion, Autocorrelation().backend)
}

// The one-shot functions and the analyses of the slice.
func oneShots(x: [Float], h: [Float], spectrogram: [Float]) async throws {
    let full = try DSP.convolve(x, h)
    let same = try DSP.convolve(x, h, mode: .same, strategy: .fft, crossovers: .shipped)
    let partitioned = try DSP.convolve(x, h, mode: .valid, strategy: .partitioned)
    let correlation = try DSP.correlate(x, h, mode: .full, normalization: .coefficient, strategy: .direct, floor: DSP.correlationFloor)
    let lags = try DSP.autocorrelate(x, maxLag: 2_048, normalization: .unbiased, strategy: .automatic)
    let masks = try await DSP.harmonicPercussiveMasks(of: spectrogram, binCount: 1_025)
    let harmonic = try await DSP.harmonicPercussive(
        spectrogram, binCount: 1_025, select: .harmonic, timeKernel: 17, frequencyKernel: 17, mask: .hard, harmonicMargin: 2, percussiveMargin: 2,
        floor: 1e-10, median: .metal, crossovers: .shipped)
    let medians = try SelectionNetworkMedian().filter(spectrogram, rowCount: 1_025, kernel: 17, along: .time)
    let table = try await Calibration.measureAnalysis(startingFrom: .shipped)
    let report = try await Calibration.analysisReport()
    let decimation = try await Decimate(by: 2).inversionReport(for: x, sampleRate: 48_000)
    _ = (full, same, partitioned, correlation, lags, masks.harmonic, masks.percussive, harmonic, medians, table, report.convolution.factor,
         report.measurements, ConvolutionCrossover.modelSize(signalLength: 4_096, kernelLength: 64), decimation.isExactlyInvertible,
         Decimate(by: 2).inverse, MedianOracle.median([3, 1, 2]), ConvolutionMode.allCases, CorrelationNormalization.allCases,
         ConvolutionStrategy.allCases, HarmonicPercussiveComponent.allCases, DSPEngine(crossovers: table))
}
