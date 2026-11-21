import Foundation
import ZTronDSPCore

/// Which cepstrum `Cepstrum` computes (§6.6).
///
/// A value, usable on any thread; it does not allocate.
public enum CepstrumKind: Hashable, Sendable {
    /// `IDFT(ln |X|)`: the real cepstrum.
    case real
    /// `|IDFT(ln |X|²)|²`: the power cepstrum.
    case power
    /// `IDFT(ln |X| + j·unwrap(∠X))` with the linear-phase term removed: the complex cepstrum,
    /// the one `InverseCepstrum` undoes.
    case complex
}

/// How the values of a cepstrum frame are laid out, read from the number of rows of its
/// axis. The cepstrum steps agree on it, so a `Lifter` or a `CepstralPitch` works on any of
/// the three cepstra.
enum CepstrumLayout: Hashable, Sendable {
    /// A real or power cepstrum of a transform of `length` points: it is even, so its frame is
    /// the quefrencies `0 … length / 2`.
    case oneSided(length: Int)
    /// A complex cepstrum of a transform of `length` points: `length` values, the second half
    /// being the negative quefrencies, then the two values that are not quefrencies.
    case complex(length: Int)
    /// A cepstrum from a step outside the package: every value is a quefrency, in order.
    case plain(count: Int)

    /// Values that follow the complex cepstrum: the delay removed, as a fraction of the
    /// transform length, and the sign of bin 0.
    static let trailer = 2

    init(rowCount: Int) {
        if DSP.isFastLength(rowCount - CepstrumLayout.trailer) {
            self = .complex(length: rowCount - CepstrumLayout.trailer)
        } else if rowCount >= 2, DSP.isFastLength(2 * (rowCount - 1)) {
            self = .oneSided(length: 2 * (rowCount - 1))
        } else {
            self = .plain(count: rowCount)
        }
    }

    /// Values in a frame.
    var frameCount: Int {
        switch self {
        case .oneSided(let length): length / 2 + 1
        case .complex(let length): length + CepstrumLayout.trailer
        case .plain(let count): count
        }
    }

    /// The quefrencies `0 ..< positiveCount` are the first values of a frame.
    var positiveCount: Int {
        switch self {
        case .oneSided(let length), .complex(let length): length / 2 + 1
        case .plain(let count): count
        }
    }

    /// The quefrency of value `index`, in samples and without its sign; `nil` for a value that
    /// is not a quefrency.
    func quefrency(at index: Int) -> Int? {
        switch self {
        case .oneSided, .plain: index
        case .complex(let length): index < length ? min(index, length - index) : nil
        }
    }
}

/// The cepstrum of each spectrum of an `STFT` (§6.6): the inverse transform of its logarithm,
/// one value per quefrency.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Cepstrum(.real); CepstralPitch(range: .hertz(60 ... 400))
/// ```
///
/// - `.real` and `.power` are even in quefrency, so a frame is the quefrencies `0 … N / 2` of
///   a transform of `N` points: `N / 2 + 1` values.
/// - `.complex` keeps the phase: `N` values, the second half being the negative quefrencies.
///   The phase is unwrapped along the bins, and its linear term, an integer delay, is taken
///   out so that the cepstrum decays; the delay and the sign of bin 0 travel with the frame
///   as two more values, which `Lifter` leaves alone and `InverseCepstrum` puts back. A frame
///   therefore has `N + 2` values, the last two not being quefrencies.
/// - The argument of every logarithm is raised to `floor` first, so a bin without energy is a
///   number (NUM-1). The arithmetic is double precision.
///
/// It follows the complex linear-frequency spectrum of an `STFT`. Downstream the axis is
/// quefrency. Switched off, it suspends the rest of its branch (ACT-3). An immutable value,
/// usable on any thread; `lower(_:)` runs on the control context and may allocate.
public struct Cepstrum: PipelineStage {
    /// The complex linear-frequency spectrum of an `STFT`.
    public typealias Input = Spectrum<LinearFrequency, ComplexValues>
    /// One value per quefrency, and two more after a complex cepstrum.
    public typealias Output = Quefrency

    /// Which cepstrum: the real, the power or the complex one.
    public let kind: CepstrumKind
    /// What the argument of a logarithm is raised to: `|X|` for `.real` and `.complex`,
    /// `|X|²` for `.power`.
    public let floor: Double
    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// The cepstrum of `kind`, with the argument of every logarithm raised to `floor` first.
    /// Nothing is checked here: `lower(_:)` requires a positive, finite floor when the plan is
    /// compiled.
    public init(_ kind: CepstrumKind = .real, floor: Double = 1e-10, isActive: some ActivationSource = .active) {
        self.kind = kind
        self.floor = floor
        self.activation = isActive.stageActivation
    }

    struct Key: Hashable, Sendable {
        let kind: CepstrumKind
        let floor: Double
        let length: Int
    }

    /// The transform length behind the spectra at this position, checked.
    static func transformLength(in context: LoweringContext, stage: String) throws(DSPError) -> Int {
        guard case .linearFrequency(let bins, _)? = context.environment.frequencyAxis, bins >= 2 else {
            throw DSPError.unsupportedConfiguration(
                reason: "\(stage) needs the spectra of an STFT: there is no linear-frequency axis at this position", stage: context.path)
        }
        return try StageValidation.transformLength(2 * (bins - 1), named: "transform length", in: context)
    }

    /// Checks the transform length of the spectra at the step's position and the floor, and
    /// emits the node. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let length = try Cepstrum.transformLength(in: context, stage: "Cepstrum")
        guard floor > 0, floor.isFinite else { throw context.invalid("floor", "the floor of a logarithm is positive and finite, not \(floor)") }
        let layout: CepstrumLayout = kind == .complex ? .complex(length: length) : .oneSided(length: length)
        let kind = kind, floor = floor
        context.emit(.analysis(AnalysisStep(
            name: "Cepstrum", key: Key(kind: kind, floor: floor, length: length), output: .real(count: layout.frameCount),
            scope: .axis(.quefrency(count: layout.frameCount, sampleRate: context.environment.sampleRate))
        ) { () throws(DSPError) -> any AnalysisNode in
            try CepstrumNode(kind: kind, floor: floor, length: length)
        }))
    }
}

/// From a complex cepstrum back to the spectrum it came from (§6.6, §6.13): the transform,
/// the exponential, and the linear-phase term put back.
///
/// It undoes `Cepstrum(.complex)`, with any `Lifter` in between. A real or a power cepstrum
/// has no phase to return: after one, attaching fails. Bins whose magnitude lay below the
/// floor of the cepstrum come back at the floor; the inversion report counts them.
///
/// Downstream the axis is linear frequency again, so an `InverseSTFT` can follow. Switched
/// off, it suspends the rest of its branch (ACT-3). An immutable value, usable on any thread;
/// `lower(_:)` runs on the control context and may allocate.
public struct InverseCepstrum: PipelineStage {
    /// A complex cepstrum, with the two values that follow it.
    public typealias Input = Quefrency
    /// The complex linear-frequency spectrum the cepstrum came from.
    public typealias Output = Spectrum<LinearFrequency, ComplexValues>

    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// The inverse of `Cepstrum(.complex)`; there is nothing to set but the switch.
    public init(isActive: some ActivationSource = .active) {
        self.activation = isActive.stageActivation
    }

    /// Checks that the frames at the step's position hold a complex cepstrum, and throws after
    /// a real or a power one, then emits the node. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard case .quefrency(let count, let rate)? = context.environment.frequencyAxis, rate > 0 else {
            throw DSPError.unsupportedConfiguration(reason: "InverseCepstrum needs a cepstrum: there is no quefrency axis at this position", stage: context.path)
        }
        guard case .complex(let length) = CepstrumLayout(rowCount: count) else {
            throw context.invalid(
                "position", "InverseCepstrum undoes Cepstrum(.complex), whose frames hold a transform length and two more values; the frames here hold \(count). A real or a power cepstrum has no phase to return")
        }
        let bins = length / 2 + 1
        context.emit(.analysis(AnalysisStep(
            name: "InverseCepstrum", key: length, output: .complex(count: bins), scope: .axis(.linearFrequency(binCount: bins, nyquist: rate / 2))
        ) { () throws(DSPError) -> any AnalysisNode in
            try InverseCepstrumNode(length: length)
        }))
    }
}

/// A window over quefrency (§6.6): what separates the spectral envelope, at low quefrencies,
/// from the excitation, at high ones.
///
/// ```swift
/// Cepstrum(.real); Lifter(.lowTime(0.002))            // keeps quefrencies below 2 ms
/// ```
///
/// A quefrency is taken without its sign, so the negative quefrencies of a complex cepstrum
/// are treated as the positive ones. `.lowTime` and `.highTime` with one cutoff split a
/// cepstrum in two parts that add up to it. Switched off, the cepstrum passes unchanged
/// (ACT-3). An immutable value, usable on any thread; `lower(_:)` runs on the control context and
/// may allocate.
public struct Lifter: PipelineStage {
    /// A cepstrum, of any of the three kinds.
    public typealias Input = Quefrency
    /// The same cepstrum, weighted.
    public typealias Output = Quefrency

    /// The shape of the window over quefrency.
    /// A value, usable on any thread; it does not allocate.
    public enum Shape: Hashable, Sendable {
        /// Keeps the quefrencies below the cutoff, in seconds: the spectral envelope.
        case lowTime(TimeInterval)
        /// Keeps the quefrencies at and above the cutoff, in seconds: the excitation.
        case highTime(TimeInterval)
        /// `1 + (length / 2)·sin(π·n / length)` at quefrency `n`, in samples: the lifter that
        /// evens out the size of cepstral coefficients.
        case sinusoidal(Int)
    }

    /// The window over quefrency.
    public let shape: Shape
    /// The stage's switch: off, the cepstrum passes unchanged (ACT-3).
    public let activation: StageActivation

    /// A lifter of `shape`. Nothing is checked here: `lower(_:)` requires a finite cutoff that is
    /// not negative, or a sinusoidal length of at least 1, when the plan is compiled.
    public init(_ shape: Shape, isActive: some ActivationSource = .active) {
        self.shape = shape
        self.activation = isActive.stageActivation
    }

    /// Checks the shape, weighs every value of the frames at the step's position (a value that is
    /// not a quefrency keeps a weight of 1) and emits the node. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard case .quefrency(let count, let rate)? = context.environment.frequencyAxis, count >= 1, rate > 0 else {
            throw DSPError.unsupportedConfiguration(reason: "Lifter needs a cepstrum: there is no quefrency axis at this position", stage: context.path)
        }
        let layout = CepstrumLayout(rowCount: count)
        var weights = [Float](repeating: 1, count: count)
        switch shape {
        case .lowTime(let cutoff), .highTime(let cutoff):
            guard cutoff >= 0, cutoff.isFinite else { throw context.invalid("cutoff", "a quefrency is a time that is finite and not negative, not \(cutoff) s") }
            let keepsLow: Bool = if case .lowTime = shape { true } else { false }
            for index in 0 ..< count {
                guard let quefrency = layout.quefrency(at: index) else { continue }
                let isLow = Double(quefrency) / rate < cutoff
                weights[index] = isLow == keepsLow ? 1 : 0
            }
        case .sinusoidal(let length):
            guard length >= 1 else { throw context.invalid("length", "the length of a sinusoidal lifter is at least 1, not \(length)") }
            for index in 0 ..< count {
                guard let quefrency = layout.quefrency(at: index) else { continue }
                weights[index] = Float(1 + Double(length) / 2 * sin(.pi * Double(quefrency) / Double(length)))
            }
        }
        let table = weights
        let bound = Vector.Bound(count: count, implementation: context.environment.implementation, crossovers: context.crossovers)
        context.emit(.analysis(AnalysisStep(name: "Lifter", key: table, output: .real(count: count)) { () throws(DSPError) -> any AnalysisNode in
            try LifterNode(weights: table, bound: bound)
        }))
    }
}

/// The pitch read from a cepstrum (§6.6): the quefrency of the largest value inside
/// `1 / f_max … 1 / f_min`, refined by a parabola through it and its neighbours, as a
/// frequency in hertz.
///
/// ```swift
/// CepstralPitch(range: .hertz(60 ... 400))                 // transforming: the chain goes on with f₀
/// CepstralPitch(range: .hertz(60 ... 400), to: $pitch)     // measuring: the cepstrum passes on (OUT-1)
/// ```
///
/// The confidence is `1 − μ / p` clamped to `0 … 1`, with `p` the peak and `μ` the mean
/// magnitude of the cepstrum inside the range: near 1 for a voiced frame, low for noise. A
/// frame with no positive peak has no pitch: it repeats the last value, or 0 before the
/// first, with confidence 0 (NUM-1).
///
/// The frame must reach the longest period asked for; when it does not, attaching fails and
/// the error names the transform length that would. The transforming spelling starts a scalar
/// track at the feature rate; the measuring one equals `Tap { CepstralPitch(…); Emit(to:) }`.
/// Switched off, the transforming spelling suspends the rest of its branch; the measuring one
/// stops measuring (ACT-3). An immutable value, usable on any thread; `lower(_:)` runs on the
/// control context and may allocate.
public struct CepstralPitch<Output: SignalDomain>: PipelineStage {
    /// A cepstrum, of any of the three kinds.
    public typealias Input = Quefrency

    /// The pitches looked for.
    public let range: FrequencyRange
    /// The step's switch: off, the transforming spelling suspends the rest of its branch and the
    /// measuring one stops measuring (ACT-3).
    public let activation: StageActivation
    let measuring: StageDescription?

    /// The step itself, from quefrency to a scalar track; for the measuring spelling, the tap that
    /// measures (OUT-1).
    public var stageDescriptions: [StageDescription] {
        [measuring ?? StageDescription(self, rule: .fixed(.quefrency, .scalar))]
    }

    /// Checks the range against the cepstrum at the step's position (above 0 Hz, at most the
    /// Nyquist frequency, a longest period the frame reaches) and emits the node. The measuring
    /// spelling is lowered as its tap: called on it, this throws. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard measuring == nil else { throw context.structuralStage() }
        let environment = context.environment
        guard case .quefrency(let count, let rate)? = environment.frequencyAxis, rate > 0, let featureRate = environment.featureRate else {
            throw DSPError.unsupportedConfiguration(reason: "CepstralPitch needs a cepstrum: there is no quefrency axis at this position", stage: context.path)
        }
        let hertz = try range.hertz(sampleRate: rate)
        guard hertz.lowerBound > 0 else { throw context.invalid("range", "a pitch of 0 Hz has no period: the range must begin above 0 Hz") }
        guard hertz.upperBound <= rate / 2 else {
            throw context.invalid("range", "\(range) ends at \(hertz.upperBound) Hz, above the Nyquist frequency of \(rate / 2) Hz")
        }
        // The peak needs a neighbour on either side for the parabola.
        let positive = CepstrumLayout(rowCount: count).positiveCount
        let first = max(Int((rate / hertz.upperBound).rounded(.up)), 1)
        let last = Int((rate / hertz.lowerBound).rounded(.down))
        guard last <= positive - 2 else {
            let needed = DSP.nextFastLength(2 * (last + 2))
            throw context.invalid(
                "range", "a pitch of \(hertz.lowerBound) Hz has a period of \(last) samples, and the cepstrum here holds quefrencies up to \(positive - 1): a transform of \(needed) points reaches it")
        }
        guard last >= first else {
            throw context.invalid("range", "no quefrency lies between 1 / \(hertz.upperBound) Hz and 1 / \(hertz.lowerBound) Hz at a sample rate of \(rate) Hz")
        }
        let key = CepstralPitchKey(first: first, count: last - first + 1, sampleRate: rate)
        context.emit(.analysis(AnalysisStep(
            name: "CepstralPitch", key: key, output: .scalar, scope: .featureSequence(rate: featureRate)
        ) { () throws(DSPError) -> any AnalysisNode in
            CepstralPitchNode(first: key.first, count: key.count, sampleRate: rate)
        }))
    }
}

struct CepstralPitchKey: Hashable, Sendable {
    let first: Int
    let count: Int
    let sampleRate: Double
}

extension CepstralPitch where Output == Scalar {
    /// The transforming spelling: the chain goes on with the pitch in hertz, one value per frame.
    /// Usable on any thread; it does not allocate.
    public init(range: FrequencyRange = .hertz(50 ... 500), isActive: some ActivationSource = .active) {
        self.range = range
        self.activation = isActive.stageActivation
        self.measuring = nil
    }
}

extension CepstralPitch where Output == Quefrency {
    /// The measuring spelling (OUT-1): the pitch goes to `binding`, a `Binding<Float>` or a
    /// `Binding<ScalarFrame>`, on the main thread and at the result rate; the cepstrum passes on
    /// unchanged. Usable on any thread; it allocates the description of its measuring branch.
    public init(range: FrequencyRange = .hertz(50 ... 500), to binding: some ScalarResultTarget, isActive: some ActivationSource = .active) {
        self.range = range
        self.activation = isActive.stageActivation
        self.measuring = .measuring(CepstralPitch<Scalar>(range: range).stageDescriptions, to: binding, isActive: isActive)
    }
}

extension Pipeline where Output == Spectrum<LinearFrequency, ComplexValues> {
    /// The cepstrum of each spectrum: see ``Cepstrum``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func cepstrum(_ kind: CepstrumKind = .real, floor: Double = 1e-10, isActive: some ActivationSource = .active) -> Pipeline<Input, Quefrency> {
        appending(Cepstrum(kind, floor: floor, isActive: isActive))
    }
}

extension Pipeline where Output == Quefrency {
    /// The complex cepstrum back to its spectrum: see ``InverseCepstrum``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func inverseCepstrum(isActive: some ActivationSource = .active) -> Pipeline<Input, Spectrum<LinearFrequency, ComplexValues>> {
        appending(InverseCepstrum(isActive: isActive))
    }

    /// A window over quefrency: see ``Lifter``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func lifter(_ shape: Lifter.Shape, isActive: some ActivationSource = .active) -> Pipeline<Input, Quefrency> {
        appending(Lifter(shape, isActive: isActive))
    }

    /// The pitch read from the cepstrum, as a scalar track: see ``CepstralPitch``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func cepstralPitch(range: FrequencyRange = .hertz(50 ... 500), isActive: some ActivationSource = .active) -> Pipeline<Input, Scalar> {
        appending(CepstralPitch<Scalar>(range: range, isActive: isActive))
    }

    /// The pitch read from the cepstrum, delivered to a binding; the cepstrum passes on: see
    /// ``CepstralPitch``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func cepstralPitch(
        range: FrequencyRange = .hertz(50 ... 500), to binding: some ScalarResultTarget, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Quefrency> {
        appending(CepstralPitch<Quefrency>(range: range, to: binding, isActive: isActive))
    }
}
