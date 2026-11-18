// The order rules of the spectral front-end, as far as they accept (§5.8): every step of the
// analysis target where it belongs, in the builder and in the fluent spelling, with its
// measuring spelling, its recipes and its switch.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules below do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

@MainActor func accepted(flag: Bool, level: Binding<Float>, pitch: Binding<ScalarFrame>, centroid: Binding<Float>, vector: Binding<[Float]>,
                         shown: Binding<Bool>, heat: HeatmapFeed, mel: HeatmapFeed, cepstra: HeatmapFeed, wave: WaveformFeed) {
    // O-3, O-4, O-5: complex → power → mel → decibels, each where the one before leaves it.
    let melSpectrum: Pipeline<Samples, Spectrum<MelFrequency, DecibelValues>> = Pipeline {
        STFT(frame: 2_048, hop: 512, window: .kaiser(beta: 8.6), paddedTo: 4_096, normalization: .power, alignment: .centered, channels: .mixdown)
        Power()
        MelScale(bands: flag ? 64 : 40, range: .hertz(50 ... 8_000), formula: .htk, normalization: .none)
        Decibels(reference: 1, floor: -100)
        Emit(to: mel)
    }
    // O-3, O-4 on a linear axis, and back from decibels to either kind of value.
    let magnitudes: Pipeline<Samples, Spectrum<LinearFrequency, MagnitudeValues>> = Pipeline {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        Decibels()
        InverseDecibels(.magnitude)
    }
    let powers: Pipeline<Samples, Spectrum<LinearFrequency, PowerValues>> = Pipeline {
        STFT(frame: 1_024, hop: 256)
        Power(isActive: shown)
        Decibels(isActive: true)
        InverseDecibels(.power, reference: 2)
    }
    // O-6: the complex linear-frequency spectrum back to samples, and sequence stages on them.
    let analysis = STFT(frame: 1_024, hop: 256, window: .hamming)
    let roundTrip: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        analysis
        analysis.inverse
        Halve()
    }
    // O-8, OUT-1: the centroid after magnitudes or powers on a linear axis, in both spellings.
    let track: Pipeline<Samples, Scalar> = Pipeline {
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        SpectralCentroid(to: centroid)                    // measures; the spectrum passes on
        SpectralCentroid(range: .hertz(100 ... 8_000))    // transforms; a scalar track follows
        Halve()                                           // a sequence stage on a scalar track (O-1)
        Emit(to: level)
    }
    // O-10: cepstra, lifters, pitch; the complex cepstrum and its way back.
    let cepstrum: Pipeline<Samples, Samples> = Pipeline {
        Level(.rms, to: level)                            // measures; the samples pass on
        Tap {
            STFT(frame: 2_048, hop: 512)
            Cepstrum(.real)
            Lifter(.highTime(0.001))
            Emit(to: cepstra)
            CepstralPitch(range: .hertz(60 ... 400), to: pitch)
            CepstralPitch()
            Emit(to: pitch)
        }
        Tap(isActive: shown) {
            STFT(frame: 1_024, hop: 256)
            Cepstrum(.complex)
            Lifter(.lowTime(0.002))
            InverseCepstrum()
            InverseSTFT()
            Halve()
        }
        Tap { Level(.peak, window: 0.02, hop: 0.01); Emit(to: level) }
        Tap { Waveform(resolution: 0.005); Emit(to: wave) }
    }
    // O-10: coefficients after a mel spectrum in decibels, and back to one.
    let coefficients: Pipeline<Samples, Spectrum<MelFrequency, DecibelValues>> = Pipeline {
        STFT(frame: 2_048, hop: 512)
        Power()
        MelScale(bands: 40)
        Decibels()
        CepstralCoefficients(count: 13)
        Emit(to: vector)
        InverseCepstralCoefficients(bands: 40)
    }
    // The recipes take samples and return them, so they stand among sequence stages (§5.2).
    let recipes: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        Spectrogram(frame: 2_048, hop: 512, window: .hann, to: heat)
        MelSpectrogram(frame: 2_048, hop: 512, bands: 128, to: mel, isActive: shown)
        MFCC(count: 13, melBands: 40, to: vector)
        if flag { Spectrogram(to: heat, isActive: false) }
        Halve()
    }
    // The fluent spelling gives the same descriptions (API-1); a branch that begins with a
    // step of a family is written this way (ORD-3).
    let fluent = Pipeline()
        .level(.rms, to: level)
        .stft(frame: 1_024, hop: 256)
        .tap { $0.magnitude().spectralCentroid(to: centroid).melScale(bands: 40).decibels().cepstralCoefficients(count: 13).emit(to: vector) }
        .tap { $0.power().decibels().inverseDecibels(.power).spectralCentroid().emit(to: level) }
        .tap { $0.cepstrum(.complex).lifter(.sinusoidal(22)).cepstralPitch(to: pitch).inverseCepstrum().inverseSTFT().waveform().emit(to: wave) }
        .inverseSTFT()
        .spectrogram(to: heat)
        .melSpectrogram(to: mel)
        .mfcc(to: vector)
    _ = (melSpectrum, magnitudes, powers, roundTrip, track, cepstrum, coefficients, recipes, fluent)
}

// A strategy written outside the package is passed the same way as a stock one (§5.3).
struct ErbFormula: MelFormula {
    func mel(fromHertz hertz: Double) -> Double { hertz / 100 }
    func hertz(fromMel mel: Double) -> Double { mel * 100 }
}

struct FlatNormalization: MelNormalization {
    func gain(lowerEdge: Double, center: Double, upperEdge: Double) -> Double { 0.5 }
}

func analyses(samples: [Float]) async throws {
    let window = Window.custom { t in exp(-18 * (t - 0.5) * (t - 0.5)) }
    let report = try await window.analysis(frame: 2_048, hop: 512)
    let followed = try await window.analysis(frame: 2_048, hop: 512, tail: { t in exp(-18 * (t - 0.5) * (t - 0.5)) })
    let inversion = try await STFT(frame: 2_048, hop: 512, window: .hann).inversionReport(for: samples, sampleRate: 48_000)
    let decibels = try await Decibels().inversionReport(for: samples, after: Pipeline { STFT(frame: 1_024, hop: 256); Power() })
    let scripts = [try await report.matlabScript(), try await inversion.matlabScript(), try await HeatmapFeed().snapshot().matlabScript(),
                   try await ScalarTrack([], rate: 100).matlabScript()]
    let custom = Pipeline { STFT(frame: 1_024, hop: 256, backend: .vDSP); Power(); MelScale(bands: 20, formula: ErbFormula(), normalization: FlatNormalization()) }
    let bank = try MelFilterBank(bands: 40, binCount: 513, nyquist: 24_000)
    let spectrum = try DSP.realDFT([Double](repeating: 0, count: 64))
    _ = (followed.tailLimit, inversion.isExactlyInvertible, decibels.predictedError, scripts, custom, bank.centers, spectrum.real)
}
