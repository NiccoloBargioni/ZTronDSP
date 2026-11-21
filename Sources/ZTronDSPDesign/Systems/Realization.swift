import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

// How a designed system becomes what a plan runs (§6.3.9): the cascade with its gain spread
// over the sections, the precision chosen by measurement, the taps in single precision.

extension SecondOrderSections {
    /// The cascade with its gain spread over the sections: the same system, section by
    /// section the same zeros and poles, scaled so that the response from the input of the
    /// cascade to the output of every section but the last peaks at 1. The last section
    /// carries what is left, so the whole response is unchanged.
    ///
    /// The pairing puts the whole gain into the first section, as the reference does. For a
    /// low cutoff at a high rate that gain is tiny (5·10⁻³¹ for a 10 Hz low-pass of order 8 at
    /// 192 kHz), and the first section then works some twenty decades below the signal, where
    /// the kernels clear its memory at the end of every block (RT-6). Spread, every section
    /// works at the level of the signal. This is the form the filter stages run and the form
    /// the numerical figures of an analysis are measured on.
    ///
    /// The peaks are taken on a grid of 257 frequencies from 0 Hz to the Nyquist frequency,
    /// to which the angle of every pole and of every zero is added, so that a resonance
    /// between two grid points is not missed. A cascade of fewer than two sections, an
    /// analog one, and one whose response is zero or not finite are returned as they are.
    /// Usable on any thread; allocates.
    public func spreadingGain() -> SecondOrderSections {
        guard domain == .digital, sections.count > 1 else { return self }
        var grid = (0 ... 256).map { Double.pi * Double($0) / 256 }
        for section in sections {
            let roots = section.roots()
            for root in roots.zeros + roots.poles where root.imaginary != 0 && root.magnitude > 0 {
                grid.append(abs(root.phase))
            }
        }
        var running = [Double](repeating: 1, count: grid.count)
        var scales: [Double] = []
        var previous = 1.0
        for section in sections.dropLast() {
            var peak = 0.0
            for (index, frequency) in grid.enumerated() {
                let delay = Complex(magnitude: 1, phase: -frequency)
                let numerator = (section.b2 * delay + section.b1) * delay + section.b0
                let denominator = (section.a2 * delay + section.a1) * delay + 1
                running[index] *= (numerator / denominator).magnitude
                if running[index].isFinite { peak = max(peak, running[index]) } else { peak = .infinity }
            }
            guard peak.isFinite, peak > 0 else { return self }
            let cumulative = 1 / peak
            scales.append(cumulative / previous)
            previous = cumulative
        }
        scales.append(1 / previous)
        guard scales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return self }
        let scaled = zip(sections, scales).map { section, scale in
            Section(b0: section.b0 * scale, b1: section.b1 * scale, b2: section.b2 * scale, a1: section.a1, a2: section.a2)
        }
        return SecondOrderSections(sections: scaled, domain: .digital)
    }

    /// How far the cascade in single precision is from the same cascade in double precision
    /// (§6.3.8, REAL-3): measured, not estimated. The realised cascade (``spreadingGain()``)
    /// is run through the single-precision kernel (`vDSP_biquad`) and through the
    /// double-precision one, on an impulse and on seeded noise of 4 096 samples each, in
    /// blocks of 512; the result is the larger of the two deviations, in decibels relative to
    /// the peak of the double-precision output, and never below −160 dB. It is `.infinity`
    /// when an output is not a finite number: a cascade whose gain exceeds what single
    /// precision carries.
    ///
    /// Creates two kernels and runs them: control or background context.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for an analog cascade or one that is not
    ///   stable; `DSPError.resourceAllocationFailed` when a kernel cannot be created.
    public func singleVersusDoubleDeviation() throws(DSPError) -> Double {
        try singleVersusDoubleDeviation(accelerated: true, channelCount: 1, blockFrames: 512)
    }

    /// The precision the cascade should run in (REAL-3): `.double` when
    /// ``singleVersusDoubleDeviation()`` exceeds −100 dB, `.single` otherwise. Control or
    /// background context. It allocates: it creates two kernels and runs them.
    public func recommendedPrecision() throws(DSPError) -> BiquadPrecision {
        try recommendedPrecision(accelerated: true, channelCount: 1, blockFrames: 512)
    }

    /// ``singleVersusDoubleDeviation()`` for the place a stage stands at (REAL-3): the same
    /// measurement, with the single-precision kernel a plan creates there and in blocks of
    /// the size it runs there. The stock filter stages make it with exactly these three
    /// figures when the environment asks for `.automatic`, so a filter written outside the
    /// package that passes them picks the precision its stock twin picks (EXT-1).
    ///
    /// Creates two kernels and runs them: control or background context, which is where a stage's
    /// `lower(_:)` runs. It allocates.
    ///
    /// - Parameters:
    ///   - accelerated: whether a plan runs a single-precision cascade on Accelerate at that
    ///     place. In `lower(_:)`:
    ///     `context.implementation(for: .biquadKernel, size: context.maximumBlockFrames) == .accelerate`.
    ///     Otherwise the single path is the C loop, which rounds differently.
    ///   - channelCount: channels of the signal there, `context.channelCount`. From three
    ///     channels up an accelerated cascade runs on one setup for all channels
    ///     (`vDSP_biquadm`), another routine than the one for one or two.
    ///   - blockFrames: frames per block there, `context.maximumBlockFrames`; taken as
    ///     1 … 4 096.
    /// - Throws: as ``singleVersusDoubleDeviation()``.
    public func singleVersusDoubleDeviation(accelerated: Bool, channelCount: Int, blockFrames: Int) throws(DSPError) -> Double {
        guard domain == .digital else {
            throw .unsupportedConfiguration(reason: "only a digital cascade runs: an analog one has no single-precision realisation to measure")
        }
        guard stabilityMargin > 0 else {
            throw .unsupportedConfiguration(reason: "the cascade is not stable (largest pole radius \(1 - stabilityMargin)): it is never run, so there is nothing to measure")
        }
        let realised = spreadingGain().biquadSections
        guard !realised.isEmpty else { return DSP.decibelFloor }
        return try PrecisionMeasurement.deviation(of: realised, accelerated: accelerated, channelCount: channelCount, blockFrames: blockFrames)
    }

    /// The precision the cascade should run in at the place a stage stands at (REAL-3):
    /// `.double` when ``singleVersusDoubleDeviation(accelerated:channelCount:blockFrames:)``
    /// exceeds −100 dB, `.single` otherwise. What a stock filter stage picks there for
    /// `.automatic`. Control or background context; allocates (it makes the measurement).
    public func recommendedPrecision(accelerated: Bool, channelCount: Int, blockFrames: Int) throws(DSPError) -> BiquadPrecision {
        PrecisionMeasurement.precision(
            for: try singleVersusDoubleDeviation(accelerated: accelerated, channelCount: channelCount, blockFrames: blockFrames))
    }

    /// The sections as the kernels take them.
    var biquadSections: [BiquadSection] {
        sections.map { BiquadSection(b0: $0.b0, b1: $0.b1, b2: $0.b2, a1: $0.a1, a2: $0.a2) }
    }
}

/// The measurement behind `BiquadPrecision.automatic` (REAL-3, WP-433).
enum PrecisionMeasurement {
    /// Samples of each of the two test signals.
    static let sampleCount = 4_096
    /// The deviation above which the double-precision kernel is chosen, in decibels.
    static let threshold = -100.0
    /// The seed of the noise: the measurement is the same on every run.
    static let noiseSeed: UInt64 = 0x5EED_0433

    static func precision(for deviation: Double) -> BiquadPrecision {
        deviation > threshold ? .double : .single
    }

    /// The two test signals: an impulse, and uniform noise in −1 … 1 from a SplitMix64
    /// generator with a fixed seed.
    static func signals() -> [[Float]] {
        var impulse = [Float](repeating: 0, count: sampleCount)
        impulse[0] = 1
        var state = noiseSeed
        var noise = [Float](repeating: 0, count: sampleCount)
        for index in 0 ..< sampleCount {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            noise[index] = Float(2 * (Double(z >> 11) * 0x1.0p-53) - 1)
        }
        return [impulse, noise]
    }

    /// Runs `sections` through the single-precision kernel a plan would create at this
    /// position and through the double-precision kernel, and returns the larger deviation
    /// over the two test signals in decibels relative to the peak of the double-precision
    /// output, clamped at −160 dB. An output that is not a finite number, in either
    /// precision, is an infinite deviation: a coefficient or a sample then exceeds what single
    /// precision carries, and the comparison of two such outputs says nothing.
    ///
    /// - Parameters:
    ///   - accelerated: the single path is `vDSP_biquad` (or `vDSP_biquadm` from three
    ///     channels up, as the plan chooses); otherwise the C loop.
    ///   - channelCount: channels of the signal at the stage's position.
    ///   - blockFrames: frames per block there; clamped to 1 … 4 096.
    static func deviation(of sections: [BiquadSection], accelerated: Bool, channelCount: Int, blockFrames: Int) throws(DSPError) -> Double {
        let coefficients = sections.flatMap(\.coefficients)
        guard !sections.isEmpty, coefficients.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "sections", reason: "a cascade to measure has at least one section and finite coefficients")
        }
        let count = UInt32(sections.count)
        // The kernel the plan creates: one setup for all channels from three channels up.
        let multichannel = accelerated && channelCount > 2
        let channels = multichannel ? channelCount : 1
        var single = multichannel
            ? ztd_biquadm_create(UInt32(channels), count, coefficients)
            : ztd_biquad_create(1, count, coefficients, accelerated ? ZTD_IMPLEMENTATION_ACCELERATE : ZTD_IMPLEMENTATION_NATIVE)
        var double = ztd_biquad_double_create(1, count, coefficients)
        defer {
            ztd_kernel_destroy(&single)
            ztd_kernel_destroy(&double)
        }
        guard !ztd_kernel_is_null(&single), !ztd_kernel_is_null(&double) else {
            throw .resourceAllocationFailed(what: "the kernels of the precision measurement")
        }
        let block = min(max(blockFrames, 1), sampleCount)
        let input = try AudioBuffer(channelCount: channels, capacity: block)
        let singleOutput = try AudioBuffer(channelCount: channels, capacity: block)
        let doubleOutput = try AudioBuffer(channelCount: 1, capacity: block)

        var worst = 0.0
        var isFinite = true
        for signal in signals() {
            single.reset?(single.state)
            double.reset?(double.state)
            var peak = 0.0
            var difference = 0.0
            var position = 0
            while position < sampleCount {
                let frames = min(block, sampleCount - position)
                for channel in 0 ..< channels {
                    let target = input.channel(channel)
                    for index in 0 ..< frames { target[index] = signal[position + index] }
                }
                let source = input.block(frameCount: frames)
                _ = single.process?(single.state, source.constantChannelTable, singleOutput.block(frameCount: frames).channelTable, UInt32(channels), UInt32(frames))
                _ = double.process?(double.state, source.constantChannelTable, doubleOutput.block(frameCount: frames).channelTable, 1, UInt32(frames))
                let fast = singleOutput.channel(0), exact = doubleOutput.channel(0)
                for index in 0 ..< frames {
                    // `max` passes a NaN by: what is not finite is counted, not compared.
                    if !(fast[index].isFinite && exact[index].isFinite) { isFinite = false }
                    peak = max(peak, Double(abs(exact[index])))
                    difference = max(difference, Double(abs(fast[index] - exact[index])))
                }
                position += frames
            }
            if peak > 0 { worst = max(worst, difference / peak) }
        }
        guard isFinite else { return .infinity }
        return DSP.decibels(fromAmplitude: worst)
    }
}

/// How a filter stage lowers itself (REAL-1 … REAL-5).
enum FilterLowering {
    /// Emits a digital cascade: stable (REAL-2), its gain spread over the sections (RT-6), in
    /// the precision the environment asks for or, for `.automatic`, the one the measurement
    /// chooses here, on the control context (REAL-3). A cascade without sections emits
    /// nothing.
    static func emit(_ sections: SecondOrderSections, into context: inout LoweringContext) throws(DSPError) {
        guard !sections.sections.isEmpty else { return }
        let margin = sections.stabilityMargin
        guard margin > 0 else {
            throw DSPError.unstableDesign(maxPoleRadius: 1 - margin)
        }
        let realised = sections.spreadingGain().biquadSections
        guard realised.allSatisfy({ $0.coefficients.allSatisfy(\.isFinite) }) else {
            throw context.invalid("sections", "a coefficient of the cascade is not a finite number")
        }
        let precision: BiquadPrecision
        switch context.environment.biquadPrecision {
        case .single: precision = .single
        case .double: precision = .double
        case .automatic:
            let frames = context.maximumBlockFrames
            let accelerated = context.implementation(for: .biquadKernel, size: frames) == .accelerate
            precision = PrecisionMeasurement.precision(
                for: try PrecisionMeasurement.deviation(of: realised, accelerated: accelerated, channelCount: context.channelCount, blockFrames: frames))
        }
        if precision == .single {
            guard realised.allSatisfy({ $0.coefficients.allSatisfy { Float($0).isFinite } }) else {
                throw context.invalid("sections", "a coefficient of the cascade exceeds single precision; run it in double precision: .environment(\\.biquadPrecision, .double), or leave the choice to .automatic")
            }
        }
        context.emit(.biquad(sections: realised, precision: precision))
    }

    /// Emits an FIR filter: its taps in single precision, with the latency of a linear-phase
    /// filter (REAL-5). The plan runs it directly or as a partitioned convolution, by its
    /// length (REAL-4).
    static func emit(taps: [Double], into context: inout LoweringContext) throws(DSPError) {
        let single = taps.map { Float($0) }
        guard !single.isEmpty, single.allSatisfy(\.isFinite) else {
            throw context.invalid("taps", "an FIR filter has at least one tap, and every tap is a finite number in single precision")
        }
        context.emit(.fir(taps: single, latency: FIRMath.latency(of: taps)))
    }
}
