import Foundation
import ZTronDSPCore

/// One condition under which an inverse recovers what its stage was given (INV-2): the
/// theorem behind it, whether it holds, and by how much.
///
/// An immutable value, usable on any thread.
public struct InversionCondition: Hashable, Sendable {
    /// What the condition is called: "non-zero overlap-add", "sampling theorem".
    public let name: String
    /// The statement that has to hold, with its source.
    public let theorem: String
    /// What was measured to decide: "the least value of Σ w² over its greatest".
    public let quantity: String
    /// The measured value of `quantity`.
    public let observed: Double
    /// Whether the condition holds.
    public let holds: Bool
    /// How far the measured value lies on the safe side of what the condition asks for: not
    /// negative when it holds, negative when it does not. Its unit is that of `quantity`,
    /// unless `quantity` says otherwise.
    public let margin: Double
    /// False for a condition that makes the inverse better conditioned or its answer more
    /// meaningful, but that exactness does not depend on.
    public let isNecessary: Bool
    /// The relative error this condition accounts for as it stands: 0 for one that holds and
    /// costs nothing, a bound for one that amplifies round-off, the share that is lost for one
    /// that fails.
    public let predictedError: Double

    public init(
        name: String, theorem: String, quantity: String, observed: Double, holds: Bool, margin: Double, isNecessary: Bool = true,
        predictedError: Double = 0
    ) {
        self.name = name
        self.theorem = theorem
        self.quantity = quantity
        self.observed = observed
        self.holds = holds
        self.margin = margin
        self.isNecessary = isNecessary
        self.predictedError = predictedError
    }
}

/// What entered a stage and what came back from its inverse, value for value: the raw
/// material of a measured error (INV-2).
///
/// An immutable value, usable on any thread.
public struct InversionRoundTrip: Hashable, Sendable {
    public let original: [Float]
    public let reconstruction: [Float]
    /// Values per frame, when the stage works on frames: an error is then held against the
    /// largest value of its own frame (§6.1). 1 for samples.
    public let frameLength: Int

    /// A round trip over the values both arrays hold: the longer one is cut to the shorter.
    public init(original: [Float], reconstruction: [Float], frameLength: Int = 1) {
        let count = Swift.min(original.count, reconstruction.count)
        self.original = Array(original.prefix(count))
        self.reconstruction = Array(reconstruction.prefix(count))
        self.frameLength = Swift.max(frameLength, 1)
    }
}

/// The error of a round trip, measured (INV-2).
///
/// An immutable value, usable on any thread.
public struct InversionMeasurement: Hashable, Sendable {
    /// `10·log₁₀(Σ original² / Σ error²)`, in decibels. Infinite for a round trip that is exact
    /// bit for bit; 0 when there was nothing to compare.
    public let signalToNoiseRatio: Double
    /// The largest magnitude of `original − reconstruction`.
    public let largestError: Double
    /// The largest error relative to the largest value it is held against: the peak of the
    /// signal for samples, the maximum of its own frame for frames (§6.1). 0 when the original
    /// is zero everywhere and so is the error.
    public let relativeError: Double
    /// Values compared.
    public let count: Int

    public init(signalToNoiseRatio: Double, largestError: Double, relativeError: Double, count: Int) {
        self.signalToNoiseRatio = signalToNoiseRatio
        self.largestError = largestError
        self.relativeError = relativeError
        self.count = count
    }

    /// Measures a round trip.
    public init(_ roundTrip: InversionRoundTrip) {
        let count = roundTrip.original.count
        var power = 0.0, noise = 0.0, largest = 0.0, peak = 0.0, relative = 0.0
        let frame = roundTrip.frameLength
        var start = 0
        // Frame by frame; samples are one frame.
        let span = frame > 1 ? frame : Swift.max(count, 1)
        while start < count {
            let end = Swift.min(start + span, count)
            var frameError = 0.0, framePeak = 0.0
            for index in start ..< end {
                let value = Double(roundTrip.original[index]), error = value - Double(roundTrip.reconstruction[index])
                power += value * value
                noise += error * error
                frameError = Swift.max(frameError, abs(error))
                framePeak = Swift.max(framePeak, abs(value))
            }
            largest = Swift.max(largest, frameError)
            peak = Swift.max(peak, framePeak)
            if framePeak > 0 { relative = Swift.max(relative, frameError / framePeak) }
            start = end
        }
        // An error where the original holds nothing is held against the whole signal's peak.
        if relative == 0, largest > 0 { relative = peak > 0 ? largest / peak : .infinity }
        self.init(signalToNoiseRatio: count == 0 ? 0 : (noise > 0 ? 10 * log10(Swift.max(power, 1e-300) / noise) : .infinity),
                  largestError: largest, relativeError: relative, count: count)
    }
}

/// How well an operation inverts (§6.13, IN-21): the conditions, each with its theorem, its
/// verdict and its margin; the error the conditions predict; and, when a signal was supplied,
/// the error measured by performing the round trip on it (INV-2).
///
/// ```swift
/// let report = try await STFT(frame: 2_048, hop: 512, window: .hann)
///     .inversionReport(for: samples, sampleRate: 48_000)
/// report.isExactlyInvertible       // every necessary condition holds
/// report.predictedError            // a bound on the relative error
/// report.measuredError             // SNR and largest error of a real round trip
/// ```
///
/// A failed condition is reported, not thrown (INV-3). A report is an immutable value,
/// computed in the background, and exports as a MATLAB script (INV-4).
public struct InversionReport: Hashable, Sendable {
    /// The operation.
    public let stage: String
    /// The operation that undoes it.
    public let inverse: String
    public let conditions: [InversionCondition]
    /// The relative error the conditions predict: the sum of what each accounts for. It can
    /// exceed 1: an inverse that returns a floor where the signal lay below it, or the image
    /// of what aliased, is further from the signal than silence is.
    public let predictedError: Double
    /// The error of the round trip on the signal supplied; `nil` without one.
    public let measuredError: InversionMeasurement?
    /// What the round trip was measured on, for the export; `nil` without a signal.
    public let roundTrip: InversionRoundTrip?
    /// Values per second of the signal the round trip is given in.
    public let sampleRate: Double

    /// A report from the conditions of an operation and a round trip already performed: what
    /// an operation outside the package builds its report with.
    public init(stage: String, inverse: String, conditions: [InversionCondition], roundTrip: InversionRoundTrip? = nil, sampleRate: Double = 48_000) {
        self.stage = stage
        self.inverse = inverse
        self.conditions = conditions
        self.predictedError = conditions.reduce(0) { $0 + Swift.max($1.predictedError, 0) }
        self.roundTrip = roundTrip
        self.measuredError = roundTrip.map { InversionMeasurement($0) }
        self.sampleRate = sampleRate
    }

    /// True when every condition exactness depends on holds: the inverse then returns the
    /// input but for round-off.
    public var isExactlyInvertible: Bool {
        conditions.allSatisfy { $0.holds || !$0.isNecessary }
    }
}

/// The signal an inversion report is asked for, and the means to send it through stages
/// (INV-2): what `InvertibleStage` implementations are handed.
///
/// Everything here allocates and compiles plans: it belongs to background work.
public struct InversionContext: Sendable {
    /// The samples the report is asked for; `nil` when only the conditions are wanted.
    public let samples: [Float]?
    public let sampleRate: Double
    /// The stages between the samples and the stage under report.
    public let upstream: [StageDescription]
    let checkpoint: BackgroundWork.Checkpoint?

    public init(samples: [Float]?, sampleRate: Double, upstream: [StageDescription] = []) {
        self.init(samples: samples, sampleRate: sampleRate, upstream: upstream, checkpoint: nil)
    }

    init(samples: [Float]?, sampleRate: Double, upstream: [StageDescription], checkpoint: BackgroundWork.Checkpoint?) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.upstream = upstream
        self.checkpoint = checkpoint
    }

    /// Throws `DSPError.cancelled` when the report was cancelled. Call it between steps.
    public func check() throws(DSPError) {
        try checkpoint?.check()
    }

    private var format: SignalFormat { SignalFormat(sampleRate: sampleRate) }

    /// The samples after `upstream` and then `stages`; empty without a signal. The stages must
    /// end in samples: their order is checked as it is for any pipeline (ORD-6).
    public func samples(after stages: [StageDescription] = []) throws(DSPError) -> [Float] {
        guard let samples else { return [] }
        try check()
        return try Pipeline<Samples, Samples>(unchecked: upstream + stages).process(samples, format: format)
    }

    /// The real frames after `upstream` and then `stages`, one array per frame; empty without
    /// a signal. The stages must end in frames of real values.
    public func frames(after stages: [StageDescription] = []) throws(DSPError) -> [[Float]] {
        guard let samples else { return [] }
        try check()
        return try Pipeline<Samples, Quefrency>(unchecked: upstream + stages).process(samples, format: format)
    }

    /// The complex frames after `upstream` and then `stages`, each as its real parts followed
    /// by its imaginary parts; empty without a signal. The stages must end in a complex
    /// spectrum.
    public func complexFrames(after stages: [StageDescription] = []) throws(DSPError) -> [[Float]] {
        try frames(after: stages + [ComplexPacking().stageDescription])
    }

    /// The frames `upstream` produces for a short stretch of silence, when no signal was
    /// supplied: enough to learn their shape.
    func probeFrames(after stages: [StageDescription] = []) throws(DSPError) -> [[Float]] {
        let silence = [Float](repeating: 0, count: 1 << 15)
        return try InversionContext(samples: silence, sampleRate: sampleRate, upstream: upstream, checkpoint: checkpoint).frames(after: stages)
    }
}

/// A stage that has an inverse (INV-1): it names the inverse and states the conditions under
/// which the inverse recovers its input. Adopt it for a stage of your own and it gets the
/// same report the stock stages get.
///
/// ```swift
/// extension MyTransform: InvertibleStage {
///     var inverse: MyInverseTransform { MyInverseTransform(size: size) }
///     func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] { … }
///     func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? { … }
/// }
/// let report = try await MyTransform(size: 64).inversionReport(for: samples, sampleRate: 48_000)
/// ```
///
/// Both requirements run in background work (BG-1): they may allocate and compile plans, and
/// should call `context.check()` between their steps.
public protocol InvertibleStage: StageValue {
    /// The stage that undoes this one.
    associatedtype Inverse: StageValue

    /// The stage that undoes this one, with the values it needs to match it.
    var inverse: Inverse { get }

    /// The conditions, each with its theorem, its verdict and its margin. A condition about
    /// the signal is evaluated on the signal of `context` and left out when there is none.
    func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition]

    /// The stage and then its inverse on the signal of `context`: what entered the stage and
    /// what came back, aligned. `nil` without a signal.
    func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip?
}

extension InvertibleStage {
    /// The inversion report of the stage on `samples` (§6.13).
    ///
    /// The work runs on the background executor (BG-1): the call may be made from any context,
    /// the main actor included, and can be cancelled (BG-3). A condition that fails is part of
    /// the report, not an error (INV-3).
    ///
    /// - Parameter samples: the signal a condition about the signal is evaluated on, and the
    ///   round trip measured on. Without one the report holds the conditions that do not
    ///   depend on a signal and no measured error.
    public func inversionReport(for samples: [Float]? = nil, sampleRate: Double = 48_000) async throws(DSPError) -> InversionReport {
        try await report(samples: samples, sampleRate: sampleRate, upstream: [])
    }

    /// The inversion report of the stage where it follows `upstream`: the samples are sent
    /// through `upstream` first, and the stage is examined on what arrives.
    public func inversionReport<Domain>(
        for samples: [Float]? = nil, sampleRate: Double = 48_000, after upstream: Pipeline<Samples, Domain>
    ) async throws(DSPError) -> InversionReport {
        try await report(samples: samples, sampleRate: sampleRate, upstream: upstream.stages)
    }

    func report(samples: [Float]?, sampleRate: Double, upstream: [StageDescription]) async throws(DSPError) -> InversionReport {
        let stage = self
        guard sampleRate > 0, sampleRate.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate is positive and finite, not \(sampleRate)")
        }
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            let context = InversionContext(samples: samples, sampleRate: sampleRate, upstream: upstream, checkpoint: checkpoint)
            let conditions = try stage.inversionConditions(in: context)
            try checkpoint.check()
            let roundTrip = try stage.inversionRoundTrip(in: context)
            let values = roundTrip.map { $0.frameLength > 1 ? 1.0 : sampleRate } ?? sampleRate
            return InversionReport(stage: Self.stageName, inverse: Inverse.stageName, conditions: conditions, roundTrip: roundTrip, sampleRate: values)
        }
    }
}

// MARK: Complex frames as real ones

/// A complex spectrum as one real frame, the real parts and then the imaginary parts: how the
/// reports read complex frames back from a pipeline.
struct ComplexPacking: StageValue {
    static let rule = DomainRule.spectral("ComplexPacking: a complex spectrum as one real frame") { _, values in
        values == .complex ? .custom("packed complex spectrum") : nil
    }

    var stageDescription: StageDescription { StageDescription(self, rule: ComplexPacking.rule) }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(reason: "there is no spectrum to read at this position", stage: context.path)
        }
        context.emit(.analysis(AnalysisStep(name: "ComplexPacking", key: bins, output: .real(count: 2 * bins)) { () throws(DSPError) -> any AnalysisNode in
            ComplexPackingNode(bins: bins)
        }))
    }
}
