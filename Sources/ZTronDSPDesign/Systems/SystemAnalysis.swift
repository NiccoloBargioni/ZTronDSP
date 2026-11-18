import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// Whether the impulse response of a system ends (§6.3.8).
public enum SystemKind: Hashable, Sendable {
    /// A digital system whose poles all lie at the origin: its impulse response ends.
    case finiteImpulseResponse
    /// Every other system, every analog one among them.
    case infiniteImpulseResponse
}

/// What is known about the accuracy of the roots of an analysed system (§6.3.8): for every
/// zero and every pole that was *found* from coefficients, its condition number with respect
/// to them, `κ(r) = Σ|aₖ|·|r|ᵏ / (|r|·|p′(r)|)`. Such a root is wrong by about `κ·ε`.
///
/// A root that was placed, designed, or read from a second-order section in closed form has
/// no entry: it is known to rounding. An immutable value, usable on any thread.
public struct RootConditions: Hashable, Sendable {
    /// For each zero of the analysis, in its order: the condition number, or `nil` for a zero
    /// that was not found from coefficients. Usable on any thread.
    public let zeros: [Double?]
    /// For each pole of the analysis, in its order: the condition number, or `nil` for a pole
    /// that was not found from coefficients. Usable on any thread.
    public let poles: [Double?]

    /// The largest condition number among the roots that have one; `nil` when no root was
    /// found from coefficients. A multiple root has the condition `.infinity`. Usable on any
    /// thread.
    public var largest: Double? {
        (zeros + poles).compactMap { $0 }.max()
    }
}

/// The analysis of a linear time-invariant system (§6.3.8): what `analysis(sampleRate:)`
/// returns for any `LTISystem`, the two system builders among them.
///
/// ```swift
/// let report = try await hum.analysis(sampleRate: 48_000)     // runs in the background (BG-1)
/// report.poles; report.zeros; report.gain
/// report.isStable; report.stabilityMargin; report.isMinimumPhase
/// report.recommendedPrecision
/// let level = try report.magnitudeResponse(at: [.hertz(50)], in: .decibels)
/// let script = try await report.matlabScript()
/// ```
///
/// A report carries what was found: the roots, the verdicts, the cascade or the taps the
/// system runs as, and the numerical figures, all computed when the analysis ran. The
/// responses are functions of a frequency and are evaluated from that data when they are
/// asked for; the impulse and step responses run the realised kernels where they are called.
///
/// The report is itself an `LTISystem`: the system at the sample rate it was analysed at.
/// Its members that take angular frequencies are those of the protocol (radians per sample
/// for a digital system, radians per second for an analog one); the ones that take
/// `Frequency` values resolve them against the report's sample rate.
///
/// An immutable value, usable on any thread (BG-2).
public struct SystemAnalysis: LTISystem, Hashable, Sendable {
    /// The plane the system is described in. Usable on any thread.
    public let domain: SystemDomain
    /// The sample rate the system was analysed at, in hertz. For an analog system it is only
    /// what a `Frequency` in cycles per sample is resolved against. Usable on any thread.
    public let sampleRate: Double
    /// The zeros, with their multiplicity. Read from the zero-pole-gain form, or in closed
    /// form from each section; found from coefficients only for what was given as
    /// coefficients (see ``rootConditions``). Usable on any thread.
    public let zeros: [Complex]
    /// The poles, with their multiplicity. Usable on any thread.
    public let poles: [Complex]
    /// The gain `k` of `H = k·Π(x − zᵢ) / Π(x − pᵢ)`. Usable on any thread.
    public let gain: Double
    /// Digital: every pole lies strictly inside the unit circle. Analog: every pole lies
    /// strictly in the left half plane. Usable on any thread.
    public let isStable: Bool
    /// Digital: `1 − max|p|`. Analog: `−max Re p`. Positive exactly when the system is
    /// stable. Usable on any thread.
    public let stabilityMargin: Double
    /// Digital: every zero lies inside or on the unit circle. Analog: every zero lies in the
    /// closed left half plane. Usable on any thread.
    public let isMinimumPhase: Bool
    /// True for a digital system of finite impulse response whose taps are symmetric or
    /// antisymmetric about their middle: its group delay is the same at every frequency.
    /// Usable on any thread.
    public let isLinearPhase: Bool
    /// The order: the larger of the number of poles and the number of zeros. Usable on any
    /// thread.
    public let order: Int
    /// Whether the impulse response ends. Usable on any thread.
    public let kind: SystemKind
    /// The cascade a digital system runs as (REAL-1): all its zeros and poles paired by the
    /// nearest rule, the gain spread over the sections. `nil` for a system that runs as taps,
    /// for an analog system, and for one whose roots are not closed under conjugation.
    /// Usable on any thread.
    public let sections: SecondOrderSections?
    /// The taps a system given as taps runs as, lowest delay first; `nil` for any other.
    /// Usable on any thread.
    public let taps: [Double]?
    /// The condition of the roots that were found from coefficients. Usable on any thread.
    public let rootConditions: RootConditions
    /// How far the realised cascade in single precision is from the same cascade in double
    /// precision: measured, not estimated. The cascade is run in both precisions on an
    /// impulse and on seeded noise, 4 096 samples each; this is the larger deviation in
    /// decibels relative to the peak of the output, never below −160 dB, and `.infinity` when
    /// an output is not a finite number (a cascade whose gain exceeds what single precision
    /// carries). `nil` for a system that does not run as a stable cascade. Usable on any
    /// thread.
    public let singleVersusDoubleDeviation: Double?
    /// The precision the system should run in (REAL-3): `.double` when
    /// ``singleVersusDoubleDeviation`` exceeds −100 dB, `.single` otherwise, and for a system
    /// that does not run as a cascade, whose kernels are single precision throughout. It is
    /// what `BiquadPrecision.automatic` chooses for the same cascade on `vDSP_biquad`. Usable
    /// on any thread.
    public let recommendedPrecision: BiquadPrecision

    /// `Σₖ ‖(1/Aₖ)·Π_{j>k} Hⱼ‖₂²`, or `nil` where there is no stable cascade.
    let roundOffPowerGain: Double?
    /// What runs when the impulse or the step response is asked for: the stage a pipeline
    /// would hold.
    let realization: Filter?

    // MARK: Responses

    private func angular(_ frequencies: [Frequency]) throws(DSPError) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(frequencies.count)
        for frequency in frequencies {
            let hertz = try frequency.hertz(sampleRate: sampleRate)
            result.append(domain == .digital ? 2 * Double.pi * hertz / sampleRate : 2 * Double.pi * hertz)
        }
        return result
    }

    /// The complex response at each angular frequency: the product of the section responses
    /// for a cascade, the transform of the taps for a system given as taps, the product over
    /// the zeros and poles otherwise. Control or background context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        if let taps { return frequencies.map { FIRMath.response(of: taps, at: $0) } }
        if let sections { return try sections.frequencyResponse(at: frequencies) }
        return LTIAnalysis.response(zeros: zeros, poles: poles, gain: gain, domain: domain, at: frequencies)
    }

    /// The group delay at each angular frequency, in samples for a digital system and in
    /// seconds for an analog one: closed form per section, `Re{DFT(n·h) / DFT(h)}` for taps.
    /// `nil` where the delay is undefined: where `|H|` is below 10⁻¹² of its largest value
    /// among `frequencies`. Control or background context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        try LTIAnalysis.validate(frequencies)
        if let taps { return FIRMath.groupDelay(of: taps, at: frequencies) }
        if let sections { return try sections.groupDelay(at: frequencies) }
        let response = LTIAnalysis.response(zeros: zeros, poles: poles, gain: gain, domain: domain, at: frequencies)
        return LTIAnalysis.masked(LTIAnalysis.groupDelay(zeros: zeros, poles: poles, domain: domain, at: frequencies), by: response)
    }

    /// The complex response at each frequency, resolved against the report's sample rate.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a frequency that is negative or not finite.
    public func frequencyResponse(at frequencies: [Frequency]) throws(DSPError) -> [Complex] {
        try frequencyResponse(at: try angular(frequencies))
    }

    /// `|H|` at each frequency, in `scale` (linear unless stated). Control or background
    /// context; allocates.
    public func magnitudeResponse(at frequencies: [Frequency], in scale: MagnitudeScale = .linear) throws(DSPError) -> [Double] {
        try magnitudeResponse(at: try angular(frequencies), in: scale)
    }

    /// `arg H` at each frequency, in radians; unwrapped along the order of `frequencies` when
    /// asked. Control or background context; allocates.
    public func phaseResponse(at frequencies: [Frequency], unwrapped: Bool = false) throws(DSPError) -> [Double] {
        try phaseResponse(at: try angular(frequencies), unwrapped: unwrapped)
    }

    /// The group delay at each frequency, in samples for a digital system and in seconds for
    /// an analog one; `nil` where it is undefined. Control or background context; allocates.
    public func groupDelay(at frequencies: [Frequency]) throws(DSPError) -> [Double?] {
        try groupDelay(at: try angular(frequencies))
    }

    // MARK: Time responses, by the realised kernels

    /// The first `count` samples of the response to a unit impulse, by running the realised
    /// kernels offline: the plan a pipeline with `Filter(system)` compiles, on an impulse, so
    /// that analysis and execution cannot disagree. Runs where it is called and allocates:
    /// control or background context.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for an analog system, which no kernel
    ///   runs; `DSPError.unstableDesign` for a system that is not stable (REAL-2);
    ///   `DSPError.invalidParameter` for a negative count.
    public func impulseResponse(count: Int) throws(DSPError) -> [Float] {
        var impulse = [Float](repeating: 0, count: max(count, 0))
        if count > 0 { impulse[0] = 1 }
        return try run(impulse, count: count)
    }

    /// The first `count` samples of the response to a unit step, by running the realised
    /// kernels offline. Runs where it is called and allocates: control or background context.
    ///
    /// - Throws: as ``impulseResponse(count:)``.
    public func stepResponse(count: Int) throws(DSPError) -> [Float] {
        try run([Float](repeating: 1, count: max(count, 0)), count: count)
    }

    private func run(_ input: [Float], count: Int) throws(DSPError) -> [Float] {
        guard count >= 0 else {
            throw .invalidParameter(stage: .none, parameter: "count", reason: "a response has a number of samples that is not negative, not \(count)")
        }
        guard let realization else {
            throw .unsupportedConfiguration(reason: domain == .analog
                ? "an analog system is not run by any kernel: it has no sampled impulse or step response"
                : "this system cannot be realised as second-order sections with real coefficients: its roots are not closed under conjugation")
        }
        guard count > 0 else { return [] }
        return try Pipeline().appending(realization).process(input, format: SignalFormat(sampleRate: sampleRate))
    }

    // MARK: Round-off

    /// The level of the round-off noise at the output of the realised cascade, estimated, in
    /// decibels relative to a full-scale signal: the power gain from a round-off injected at
    /// the summing node of each section to the output, `‖(1/Aₖ)·Π_{j>k} Hⱼ‖₂²`, summed over
    /// the sections, with a round-off of one rounding unit of `precision` (2⁻²⁴ for
    /// `.single`, 2⁻⁵³ for `.double`). `.automatic` stands for ``recommendedPrecision``.
    ///
    /// The gain grows without bound as poles approach the unit circle: low cutoffs, high
    /// orders. It is the figure that says how much of the precision a filter spends; the
    /// measured counterpart for single precision is ``singleVersusDoubleDeviation``. A system
    /// that runs as taps has no recursion, so its gain is 1. The responses are summed as the
    /// kernels produce them, in single-precision samples, for at most 2²² samples per
    /// section: a response that has not died away by then is cut there, and one that leaves
    /// the range of a single-precision sample makes the figure `.infinity`. Usable on any
    /// thread.
    ///
    /// - Returns: `nil` for a system that does not run: an analog one, one that is not
    ///   stable, one that has no real sections.
    public func roundOffNoiseGain(precision: BiquadPrecision = .automatic) -> Double? {
        guard let roundOffPowerGain else { return nil }
        guard roundOffPowerGain.isFinite else { return .infinity }
        let unit: Double
        switch precision == .automatic ? recommendedPrecision : precision {
        case .double: unit = 0x1.0p-53
        case .single, .automatic: unit = 0x1.0p-24
        }
        return DSP.decibels(fromPower: roundOffPowerGain * unit * unit, floor: -400)
    }
}

// MARK: What is analysed

/// A system as an analysis takes it in: resolved against the sample rate, with what is known
/// about how its roots were obtained and with what a pipeline would run.
struct AnalysisSubject {
    let domain: SystemDomain
    let zeros: [Complex]
    let poles: [Complex]
    let gain: Double
    var zeroConditions: [Double?]?
    var poleConditions: [Double?]?
    /// The cascade as the pairing gives it, for a digital system that runs as sections.
    var cascade: SecondOrderSections?
    /// The taps, for a system that was given as taps.
    var taps: [Double]?
    /// The stage a pipeline would hold.
    var realization: Filter?
}

/// A system that knows how to present itself to an analysis. Every `LTISystem` can be
/// analysed; the representations of this target say more about themselves than the protocol
/// asks for.
protocol AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject
}

extension IIRSystem: AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject {
        let resolved = try resolved(sampleRate: sampleRate)
        let system = resolved.system
        var subject = AnalysisSubject(domain: .digital, zeros: system.zeros, poles: system.poles, gain: system.gain,
                                      zeroConditions: resolved.zeroConditions, poleConditions: resolved.poleConditions)
        // A system whose roots are not closed under conjugation has no real sections: it can
        // be described, and nothing runs it.
        subject.cascade = try? secondOrderSections(sampleRate: sampleRate)
        subject.realization = subject.cascade == nil ? nil : Filter(self)
        return subject
    }
}

extension FIRSystem: AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject {
        let taps = try taps(sampleRate: sampleRate)
        let roots = try FIRRoots(taps: taps)
        var subject = AnalysisSubject(domain: .digital, zeros: roots.zeros, poles: roots.poles, gain: taps.first { $0 != 0 } ?? 0,
                                      zeroConditions: roots.zeroConditions.map { Optional($0) })
        subject.taps = taps
        subject.realization = Filter(self)
        return subject
    }
}

extension ZeroPoleGain: AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject {
        guard isFinite else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the gain and every root of a system must be finite")
        }
        guard domain == .digital else {
            return AnalysisSubject(domain: domain, zeros: zeros, poles: poles, gain: gain)
        }
        // A digital system is analysed as it runs: as the system of one element.
        let system = self
        var subject = try IIRSystem { system }.analysisSubject(sampleRate: sampleRate)
        if subject.cascade == nil { subject.realization = nil }
        return subject
    }
}

extension SecondOrderSections: AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject {
        let system = zeroPoleGain()
        guard system.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "sections", reason: "every coefficient of a cascade must be finite")
        }
        guard domain == .digital else {
            return AnalysisSubject(domain: domain, zeros: system.zeros, poles: system.poles, gain: system.gain)
        }
        let cascade = self
        return try IIRSystem { cascade }.analysisSubject(sampleRate: sampleRate)
    }
}

extension TransferFunction: AnalysisSubjectProviding {
    func analysisSubject(sampleRate: Double) throws(DSPError) -> AnalysisSubject {
        let system = try zeroPoleGain()
        var subject = AnalysisSubject(domain: domain, zeros: system.zeros, poles: system.poles, gain: system.gain,
                                      zeroConditions: try zeroConditions.map { Optional($0) }, poleConditions: try poleConditions.map { Optional($0) })
        guard domain == .digital else { return subject }
        if system.poles.allSatisfy({ $0 == .zero }) {
            // A denominator that is a power of z alone: the numerator's coefficients are taps,
            // delayed by the excess of the denominator's degree.
            let delay = max(denominator.degree - numerator.degree, 0)
            let taps = [Double](repeating: 0, count: delay) + numerator.coefficients.map { $0 / denominator.leadingCoefficient }
            subject.taps = taps
            subject.realization = Filter(FIRSystem { Taps(taps) })
        } else {
            let realised = IIRSystem { system }
            if let cascade = try? realised.secondOrderSections(sampleRate: sampleRate) {
                subject.cascade = cascade
                subject.realization = Filter(realised)
            }
        }
        return subject
    }
}

// MARK: The analysis

extension SystemAnalysis {
    /// Analyses a system at a sample rate, step by step, asking between the steps whether to
    /// go on. This is the work behind `analysis(sampleRate:)`: it runs on the background
    /// executor, and tests of the figures call it directly.
    static func analyse(
        _ system: some LTISystem, sampleRate: Double, checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> SystemAnalysis {
        try IIRDesign.validate(sampleRate: sampleRate)

        // Step 1: the roots.
        let subject: AnalysisSubject
        if let provider = system as? any AnalysisSubjectProviding {
            subject = try provider.analysisSubject(sampleRate: sampleRate)
        } else {
            // A conformer from outside the package: what the protocol gives.
            let general = ZeroPoleGain(zeros: try system.zeros, poles: try system.poles, gain: try system.gain, domain: system.domain)
            subject = try general.analysisSubject(sampleRate: sampleRate)
        }
        try checkpoint?.check()

        // Step 2: stability and phase.
        let margin = subject.cascade?.stabilityMargin ?? LTIAnalysis.stabilityMargin(of: subject.poles, domain: subject.domain)
        let isStable = margin > 0
        let isFinite = subject.domain == .digital && subject.poles.allSatisfy { $0 == .zero }
        var isLinearPhase = false
        if let taps = subject.taps {
            isLinearPhase = FIRMath.isLinearPhase(FIRMath.trimmed(taps).taps)
        } else if isFinite, let cascade = subject.cascade {
            // Zeros alone: the numerators of the sections multiply to the taps.
            var product = [1.0]
            for section in cascade.sections { product = FIRMath.convolve(product, [section.b0, section.b1, section.b2]) }
            let trimmed = FIRMath.trimmed(product).taps
            isLinearPhase = !trimmed.isEmpty && FIRMath.isLinearPhase(trimmed)
        }
        try checkpoint?.check()

        // Step 3: the cascade as it runs, and the figures measured on it.
        let realised = subject.taps == nil ? subject.cascade?.spreadingGain() : nil
        var deviation: Double?
        var recommended = BiquadPrecision.single
        var powerGain: Double?
        if let taps = subject.taps {
            // No recursion: a round-off at the output reaches the output once.
            powerGain = taps.isEmpty ? nil : 1
        } else if let realised, isStable, !realised.sections.isEmpty {
            let sections = realised.biquadSections
            let measured = try PrecisionMeasurement.deviation(of: sections, accelerated: true, channelCount: 1, blockFrames: 512)
            deviation = measured
            recommended = PrecisionMeasurement.precision(for: measured)
            try checkpoint?.check()
            powerGain = try RoundOffNoise.powerGain(of: sections, checkpoint: checkpoint)
        }
        try checkpoint?.check()

        return SystemAnalysis(
            domain: subject.domain, sampleRate: sampleRate, zeros: subject.zeros, poles: subject.poles, gain: subject.gain,
            isStable: isStable, stabilityMargin: margin,
            isMinimumPhase: LTIAnalysis.isMinimumPhase(zeros: subject.zeros, domain: subject.domain),
            isLinearPhase: isLinearPhase, order: max(subject.zeros.count, subject.poles.count),
            kind: isFinite ? .finiteImpulseResponse : .infiniteImpulseResponse,
            sections: realised, taps: subject.taps,
            rootConditions: RootConditions(
                zeros: subject.zeroConditions ?? [Double?](repeating: nil, count: subject.zeros.count),
                poles: subject.poleConditions ?? [Double?](repeating: nil, count: subject.poles.count)),
            singleVersusDoubleDeviation: deviation, recommendedPrecision: recommended,
            roundOffPowerGain: powerGain, realization: subject.realization)
    }
}

extension LTISystem {
    /// The analysis of the system at a sample rate (§6.3.8): its zeros, poles and gain, its
    /// stability and phase verdicts, the cascade or the taps it runs as, and the numerical
    /// figures of its realisation.
    ///
    /// The work runs on `BackgroundWork`, never on the main thread and never on an audio
    /// thread (BG-1); the caller suspends. It checks between its steps whether the calling
    /// task was cancelled and then throws `DSPError.cancelled` (BG-3). What comes back is an
    /// immutable value (BG-2).
    ///
    /// - Parameter sampleRate: The rate the frequencies of the system are resolved against,
    ///   in hertz. A representation that holds no frequency (`ZeroPoleGain`, sections,
    ///   coefficients) is the same system at any rate; the rate is then what the report's
    ///   `Frequency` arguments are resolved against.
    /// - Throws: `DSPError.invalidParameter` for a sample rate that is not positive and
    ///   finite and for a system whose values make no system at this rate; what a root
    ///   finder throws for a system given as coefficients (`unsupportedConfiguration` above
    ///   degree 512, an FIR system of more than 513 taps among them); `DSPError.cancelled`.
    public func analysis(sampleRate: Double) async throws(DSPError) -> SystemAnalysis {
        try await BackgroundWork.run { (checkpoint: BackgroundWork.Checkpoint) throws(DSPError) -> SystemAnalysis in
            try SystemAnalysis.analyse(self, sampleRate: sampleRate, checkpoint: checkpoint)
        }
    }
}

/// The round-off figure of a cascade (§6.3.8).
enum RoundOffNoise {
    /// The longest impulse response that is summed: 2²² samples.
    static let maximumFrames = 1 << 22
    private static let block = 4_096

    /// `Σₖ ‖(1/Aₖ)·Π_{j>k} Hⱼ‖₂²`: for every section, the energy of the impulse response from
    /// its summing node to the output of the cascade, by running that part of the cascade in
    /// the double-precision kernel until the response has died away (three blocks in a row
    /// that add less than 10⁻¹³ of the energy so far), or for 2²² samples at most.
    /// `.infinity` when a response leaves the range of a single-precision sample.
    static func powerGain(of sections: [BiquadSection], checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) -> Double {
        var total = 0.0
        let input = try AudioBuffer(channelCount: 1, capacity: block)
        let output = try AudioBuffer(channelCount: 1, capacity: block)
        for index in sections.indices {
            // From the summing node of section `index`: its own poles, then what follows.
            var coefficients = [1, 0, 0, sections[index].a1, sections[index].a2]
            for section in sections[(index + 1)...] { coefficients += section.coefficients }
            var kernel = ztd_biquad_double_create(1, UInt32(sections.count - index), coefficients)
            defer { ztd_kernel_destroy(&kernel) }
            guard !ztd_kernel_is_null(&kernel) else {
                throw .resourceAllocationFailed(what: "the kernel of the round-off measurement")
            }
            var energy = 0.0
            var quiet = 0
            var frames = 0
            input.clear()
            input.channel(0)[0] = 1
            while frames < maximumFrames, quiet < 3 {
                _ = kernel.process?(kernel.state, input.block().constantChannelTable, output.block().channelTable, 1, UInt32(block))
                if frames == 0 { input.channel(0)[0] = 0 }
                var sum = 0.0
                let samples = output.channel(0)
                for sample in 0 ..< block { sum += Double(samples[sample]) * Double(samples[sample]) }
                energy += sum
                // A response beyond the range of a sample: the gain is beyond measure.
                guard energy.isFinite else { return .infinity }
                quiet = sum <= 1e-13 * energy ? quiet + 1 : 0
                frames += block
                if frames % (16 * block) == 0 { try checkpoint?.check() }
            }
            total += energy
            try checkpoint?.check()
        }
        return total
    }
}
