import ZTronDSPCore

/// The elements an `FIRSystem { }` block gathered, in order. What the builder passes around;
/// an app never names it. An immutable value, usable on any thread; the builder allocates it
/// as it gathers.
public struct FIRSystemContent: Hashable, Sendable {
    let elements: [AnyStrategy]
}

/// The result builder behind `FIRSystem { … }`: one element per line (§6.3.7), with `if`,
/// `if … else`, `switch`, `for … in` and `if #available` around them.
///
/// Its functions run where the system is described, on any thread, and may allocate the
/// content they return.
@resultBuilder
public enum FIRSystemBuilder {
    /// An element. Usable on any thread.
    public static func buildExpression(_ element: some FIRSystemElement) -> FIRSystemContent {
        FIRSystemContent(elements: [AnyStrategy(element)])
    }

    /// Unavailable: it exists for its diagnostic, which names the elements an `FIRSystem` holds and
    /// where the value belongs instead. Never called, being unavailable: no context runs it, and it
    /// allocates nothing.
    @available(*, unavailable, message: "An FIRSystem holds FIR elements: Taps, LeastSquares, Zero and the FIR forms of the response stages, such as LowPass(.windowedSinc(), cutoff:length:). This value is none of them: an equaliser (BandBoost, LowShelf, HighShelf) always has poles and belongs in an IIRSystem; a smoother, a gain or a rate changer belongs in the pipeline, beside Filter(system).")
    public static func buildExpression<Value>(_ value: Value) -> FIRSystemContent {
        FIRSystemContent(elements: [])
    }

    /// The lines of a block, in order. Usable on any thread.
    public static func buildBlock(_ parts: FIRSystemContent...) -> FIRSystemContent {
        FIRSystemContent(elements: parts.flatMap(\.elements))
    }

    /// `if` without `else`. Usable on any thread.
    public static func buildOptional(_ part: FIRSystemContent?) -> FIRSystemContent {
        part ?? FIRSystemContent(elements: [])
    }

    /// `if … else` and `switch`. Usable on any thread.
    public static func buildEither(first part: FIRSystemContent) -> FIRSystemContent { part }
    /// `if … else` and `switch`. Usable on any thread.
    public static func buildEither(second part: FIRSystemContent) -> FIRSystemContent { part }

    /// `for … in`. Usable on any thread.
    public static func buildArray(_ parts: [FIRSystemContent]) -> FIRSystemContent {
        FIRSystemContent(elements: parts.flatMap(\.elements))
    }

    /// `if #available`. Usable on any thread.
    public static func buildLimitedAvailability(_ part: FIRSystemContent) -> FIRSystemContent { part }
}

/// An FIR system designed declaratively (§6.3.7): the cascade of the elements of its block.
///
/// ```swift
/// let antiAlias = FIRSystem {
///     LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
///     Taps([0.25, 0.5, 0.25])
/// }
/// let report = try await antiAlias.analysis(sampleRate: 48_000)
/// Pipeline { Filter(antiAlias) }
/// ```
///
/// **What the system is.** The convolution of the taps of its elements. Anything that would
/// place a pole away from the origin is rejected when the system is resolved: a ``Pole``
/// that is not at the origin, a ``Section`` or a ``DifferenceEquation`` with a recurrence on
/// its output, an IIR form of a response stage.
///
/// **How it runs.** Directly up to the crossover length of the engine's table, as a
/// partitioned convolution above it (REAL-4). Its latency is `(K − 1) / 2` samples when its
/// taps are symmetric or antisymmetric, the delay of a linear-phase filter (REAL-5).
///
/// **Sample rate, switching.** As for ``IIRSystem``: resolved against a rate when it is
/// analysed or compiled, an `LTISystem` on its own only when no element depends on a rate,
/// and switched whole, through `Filter(_:isActive:)` (ACT-1).
///
/// An immutable value, usable on any thread. Resolving it is design maths: it allocates and
/// belongs on a control or background context.
public struct FIRSystem: LTISystem, FIRSystemElement {
    let elements: [AnyStrategy]

    /// A system from a block of elements. Runs the block where it is called, on any thread, and
    /// allocates the elements.
    public init(@FIRSystemBuilder _ content: () -> FIRSystemContent) {
        elements = content().elements
    }

    init(elements: [AnyStrategy]) {
        self.elements = elements
    }

    /// The number of elements in the block. Usable on any thread.
    public var elementCount: Int { elements.count }

    /// The longest filter a system resolves to. Usable on any thread.
    public static let maximumLength = WindowedSincMethod.maximumLength

    // MARK: Resolution

    /// The taps of the system at `sampleRate`, lowest delay first: the convolution of the taps
    /// of its elements. A system without elements passes its input unchanged: `[1]`. Control
    /// or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a sample rate that is not positive and
    ///   finite, an element whose values make no FIR filter at this rate (one that would
    ///   place a pole away from the origin among them), and an element with an `isActive`
    ///   other than the default (ACT-1); `DSPError.unsupportedConfiguration` when the system
    ///   would have more than ``maximumLength`` taps.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try IIRDesign.validate(sampleRate: sampleRate)
        var result = [1.0]
        for (index, boxed) in elements.enumerated() {
            guard let element = boxed.value(as: (any FIRSystemElement).self) else {
                throw .invalidParameter(stage: .none, parameter: "element \(index)", reason: "this value is not an element of an FIR system")
            }
            try SystemResolution.requireDefaultActivation(of: element, index: index)
            let part: [Double]
            do throws(DSPError) {
                part = try element.taps(sampleRate: sampleRate)
            } catch {
                throw SystemResolution.attributed(error, to: element, index: index)
            }
            guard !part.isEmpty, part.allSatisfy(\.isFinite) else {
                throw .invalidParameter(stage: .none, parameter: "element \(index)", reason: "\(type(of: element)) has no finite taps at \(sampleRate) Hz")
            }
            guard result.count + part.count - 1 <= Self.maximumLength else {
                throw .unsupportedConfiguration(reason: "the elements of this FIR system convolve to more than \(Self.maximumLength) taps")
            }
            result = result.count == 1 && result[0] == 1 ? part : FIRMath.convolve(result, part)
        }
        guard result.allSatisfy(\.isFinite) else {
            throw .invalidParameter(stage: .none, parameter: "taps", reason: "the taps of the elements convolve to a number that is not finite")
        }
        return result
    }

    // MARK: Element of a system, and animation

    /// True when an element depends on the sample rate. Usable on any thread.
    public var dependsOnSampleRate: Bool {
        elements.contains { ($0.value(as: (any FIRSystemElement).self))?.dependsOnSampleRate ?? true }
    }

    /// The continuous values of the elements, in order (ANI-2). Usable on any thread; it may
    /// allocate.
    public var parameters: [Double] {
        elements.flatMap { ($0.value(as: (any FIRSystemElement).self))?.parameters ?? [] }
    }

    /// The system with the continuous values of its elements replaced. Usable on any thread; it may
    /// allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> FIRSystem {
        guard values.count == parameters.count else { return self }
        var remaining = values
        var replaced: [AnyStrategy] = []
        for boxed in elements {
            guard let element = boxed.value(as: (any FIRSystemElement).self) else {
                replaced.append(boxed)
                continue
            }
            func open<Element: FIRSystemElement>(_ element: Element) -> AnyStrategy {
                let count = element.parameters.count
                let own = remaining.prefix(count)
                remaining = remaining.dropFirst(count)
                return count == 0 ? boxed : AnyStrategy(element.replacingParameters(own))
            }
            replaced.append(open(element))
        }
        return FIRSystem(elements: replaced)
    }

    // MARK: LTISystem, for a system that needs no sample rate

    /// A system of this kind is digital. Usable on any thread.
    public var domain: SystemDomain { .digital }

    private func fixed() throws(DSPError) -> [Double] {
        try SystemResolution.requireFixed(dependsOnSampleRate)
        return try taps(sampleRate: SystemResolution.referenceRate)
    }

    /// The zeros: the roots of the polynomial of the taps, found by the companion-matrix root
    /// finder and therefore known only to their condition (§6.3.8). For a system that does not
    /// depend on the sample rate. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for more than 513 taps: the root finder
    ///   stops at degree 512.
    public var zeros: [Complex] {
        get throws(DSPError) { try FIRRoots(taps: try fixed()).zeros }
    }

    /// The poles: as many at the origin as the filter has delays that no zero at the origin
    /// cancels. For a system that does not depend on the sample rate. Control or background
    /// context; allocates.
    public var poles: [Complex] {
        get throws(DSPError) { try FIRRoots(taps: try fixed()).poles }
    }

    /// The first tap that is not zero. For a system that does not depend on the sample rate.
    /// Control or background context; allocates.
    public var gain: Double {
        get throws(DSPError) { try fixed().first { $0 != 0 } ?? 0 }
    }

    /// True when the taps are symmetric or antisymmetric about their middle (§6.3.8). For a
    /// system that does not depend on the sample rate. Control or background context;
    /// allocates.
    public var isLinearPhase: Bool {
        get throws(DSPError) { FIRMath.isLinearPhase(FIRMath.trimmed(try fixed()).taps) }
    }

    /// The transform of the taps at each frequency: no root is found. Control or background
    /// context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        let taps = try fixed()
        return frequencies.map { FIRMath.response(of: taps, at: $0) }
    }

    /// `Re{DFT(n·h) / DFT(h)}` at each frequency; `nil` where the response is zero. Control or
    /// background context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        try LTIAnalysis.validate(frequencies)
        return FIRMath.groupDelay(of: try fixed(), at: frequencies)
    }
}

/// The zeros and poles of an FIR filter, from its taps.
struct FIRRoots {
    let zeros: [Complex]
    let poles: [Complex]
    /// The condition number of each zero with respect to the taps.
    let zeroConditions: [Double]

    /// `H(z) = Σ h[k]·z⁻ᵏ = N(z) / z^{K−1}`: the zeros are the roots of the polynomial whose
    /// coefficients are the taps, highest power first, and there are `K − 1` poles at the
    /// origin. A zero and a pole at the origin cancel: the taps that are zero at the end of
    /// the list add nothing but such a pair.
    init(taps: [Double], rootFinder: some PolynomialRootFinder = .companionQR) throws(DSPError) {
        guard taps.contains(where: { $0 != 0 }) else {
            zeros = []
            poles = []
            zeroConditions = []
            return
        }
        let polynomial = Polynomial(taps)
        var found = try rootFinder.roots(of: polynomial)
        var conditions = found.map { polynomial.rootCondition(at: $0) }
        var poleCount = taps.count - 1
        while poleCount > 0, let index = found.firstIndex(of: .zero) {
            found.remove(at: index)
            conditions.remove(at: index)
            poleCount -= 1
        }
        zeros = found
        zeroConditions = conditions
        poles = [Complex](repeating: .zero, count: poleCount)
    }
}

extension FIRMath {
    /// The group delay of an FIR filter in samples, `Re{DFT(n·h) / DFT(h)}`, with the points
    /// where the response is below 10⁻¹² of its largest value among `frequencies` reported as
    /// undefined (§6.3.8).
    static func groupDelay(of taps: [Double], at frequencies: [Double]) -> [Double?] {
        let responses = frequencies.map { LTIAnalysis.reported(response(of: taps, at: $0)) }
        let delays = zip(frequencies, responses).map { frequency, value -> Double in
            (rampedResponse(of: taps, at: frequency) / value).real
        }
        return LTIAnalysis.masked(delays, by: responses)
    }

    /// The delay a filter reports as its latency, in whole samples (REAL-5): the zeros in
    /// front of its first tap, plus `(K − 1) / 2` for what follows when that is symmetric or
    /// antisymmetric, rounded down for an even `K`. A filter that is not linear-phase has no
    /// one delay and reports the zeros in front alone.
    static func latency(of taps: [Double]) -> Int {
        let core = trimmed(taps)
        guard !core.taps.isEmpty else { return 0 }
        return core.leading + (isLinearPhase(core.taps) ? (core.taps.count - 1) / 2 : 0)
    }
}
