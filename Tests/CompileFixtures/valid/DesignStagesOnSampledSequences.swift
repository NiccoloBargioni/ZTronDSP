// The stock stages of ZTronDSPDesign where the order rules accept them (§5.8, O-1): filters,
// equalisers, gains, smoothers and rate changers on samples and on a scalar track, in the
// builder and in the fluent spelling, each with its switch (ACT-1); and the two system
// builders with control flow inside (§6.3.7).
import SwiftUI
import ZTronDSP

// What a fixture brings along: a stage into a spectrum and a stage into a scalar track.
struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

struct Loudness: PipelineStage {
    typealias Input = Samples
    typealias Output = Scalar
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

@MainActor func accepted(flag: Bool, shown: Binding<Bool>, level: Binding<Float>, stream: FeatureStream<Samples>) {
    // The response stages: IIR by order, by roll-off and by tolerance scheme; FIR by length,
    // by roll-off and by tolerance scheme.
    let responses: Pipeline<Samples, Samples> = Pipeline {
        LowPass(.butterworth, cutoff: .hertz(4_000), order: 4)
        HighPass(.chebyshev1(ripple: .decibels(1)), cutoff: .hertz(80), rollOff: .decibelsPerOctave(24))
        BandPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), passband: (from: .hertz(300), to: .hertz(3_400)),
                 stopband: (from: .hertz(150), to: .hertz(6_000)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(60))
        BandStop(.bessel(), from: .hertz(45), to: .hertz(55), order: 2, isActive: shown)
        LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 63)
        HighPass(.windowedSinc(window: .hann), cutoff: .hertz(200), transition: .hertz(100), length: 255, isActive: false)
        BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerOctave(96), stopband: .decibels(40))
        BandStop(.windowedSinc(), passband: (from: .hertz(500), to: .hertz(4_000)), stopband: (from: .hertz(1_000), to: .hertz(2_000)),
                 maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), isActive: .bypassed)
        Emit(to: stream)
    }
    // Equalisers, a gain, smoothers and rate changers, with control flow around them (ORD-3).
    let shaping: Pipeline<Samples, Samples> = Pipeline {
        Gain(.decibels(-6))
        Gain(channels: [.decibels(0), .decibels(-3)], ramp: 0.02, isActive: shown)
        BandBoost(center: .hertz(1_000), gain: .decibels(6), bandwidth: .octaves(1))
        if flag { BandBoost(center: .hertz(250), gain: .decibels(-9), bandwidth: .hertz(100), order: 4) }
        for octave in 0 ..< 3 { MatchedPeak(center: .hertz(2_000 * pow(2, Double(octave))), gain: .decibels(2), bandwidth: .q(2)) }
        if flag { LowShelf(midpoint: .hertz(120), gain: .decibels(3)) } else { HighShelf(midpoint: .hertz(8_000), gain: .decibels(-3), slope: .q(0.7)) }
        if #available(iOS 16, *) { SavitzkyGolay(window: 11, polynomialOrder: 3) }
        Decimate(by: 2)
        Interpolate(by: 2, rejection: .decibels(90))
        Subsample(by: 3, phase: 1)
        Upsample(by: 3, isActive: shown)
    }
    // The same stages follow a scalar track: a track is a sampled sequence (O-1).
    let track: Pipeline<Samples, Samples> = Pipeline {
        Tap(isActive: shown) {
            Loudness()
            LowPass(.butterworth, cutoff: .hertz(5), order: 2)
            SavitzkyGolay(window: 5, polynomialOrder: 2, derivative: 1, edge: .mirror)
            AlphaBeta(alpha: 0.85, beta: 0.005, output: .velocity)
            Gain(.linear(2))
            Emit(to: level)
        }
    }
    // The fluent spelling gives the same descriptions (API-1), and the environment reaches a stage.
    let fluent = Pipeline()
        .highPass(.butterworth, cutoff: .hertz(30), order: 2)
        .bandBoost(center: .midiNote(69), gain: .decibels(3), bandwidth: .octaves(0.5), rollOff: .decibelsPerOctave(24))
        .lowPass(.leastSquares(stopbandWeight: 10), cutoff: .fractionOfNyquist(0.5), length: 101, isActive: shown)
        .gain(.decibels(-3))
        .decimate(by: 2)
        .tap { $0.appending(Loudness()).alphaBeta(alpha: 0.5, beta: 0.1).savitzkyGolay(window: 7, polynomialOrder: 2).emit(to: level) }
        .environment(\.biquadPrecision, .double)
    // A tap into a spectrum leaves the main line a sampled sequence.
    let tapped: Pipeline<Samples, Samples> = Pipeline {
        Tap { Frames() }
        LowShelf(midpoint: .hertz(200), gain: .decibels(2), slope: .slope(0.8))
    }
    _ = (responses, shaping, track, fluent, tapped)
}

@MainActor func systems(flag: Bool, shown: Binding<Bool>) async throws {
    // An IIR system: roots, sections, difference equations and the IIR forms of the stages,
    // with `if`, `if … else`, `for` and `if #available` (§6.3.7).
    let hum = IIRSystem {
        Zero(onUnitCircleAt: .hertz(50))
        Pole(radius: 0.98, frequency: .hertz(50))
        if flag { HighPass(.butterworth, cutoff: .hertz(30), order: 2) }
        for harmonic in 2 ... 4 {
            Zero(onUnitCircleAt: .hertz(50 * Double(harmonic)))
            Pole(radius: 0.98, frequency: .hertz(50 * Double(harmonic)))
        }
        if flag { Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87]) } else { DifferenceEquation(b: [1, 0.5], a: [1, -0.25]) }
        if #available(iOS 16, *) { BandBoost(center: .hertz(1_000), gain: .decibels(3), bandwidth: .octaves(1)) }
        LowShelf(midpoint: .hertz(100), gain: .decibels(-2))
        MatchedPeak(center: .hertz(12_000), gain: .decibels(2), bandwidth: .q(2))
    }
    // An FIR system: taps, a least-squares design, zeros and the FIR forms of the response stages.
    let comb = FIRSystem {
        Taps([0.25, 0.5, 0.25])
        LowPass(.windowedSinc(), cutoff: .hertz(8_000), length: 31)
        if flag { Zero(onUnitCircleAt: .hertz(12_000)) }
        for _ in 0 ..< 2 { Taps([1, -1]) }
        LeastSquares(length: 33, bands: [.hertz(0), .hertz(3_000), .hertz(5_000), .hertz(24_000)], desired: [1, 1, 0, 0])
    }
    // A system is a value: an element of another system, and what a `Filter` stage runs.
    let both = IIRSystem { hum; Pole(radius: 0.5, frequency: .hertz(0)) }
    let pipeline: Pipeline<Samples, Samples> = Pipeline {
        Filter(hum)
        Filter(comb, isActive: shown)
        if flag { Filter(both) }
    }
    let fluent = Pipeline().filter(hum).filter(comb, isActive: false)
    // The analysis and its export are asynchronous, and their results are values (BG-1, BG-2).
    let report: SystemAnalysis = try await hum.analysis(sampleRate: 48_000)
    let script: String = try await report.matlabScript()
    let exportable: any MATLABExportable = report
    let precision: BiquadPrecision = report.recommendedPrecision
    _ = (pipeline, fluent, script, exportable, precision, try comb.taps(sampleRate: 48_000))
}
