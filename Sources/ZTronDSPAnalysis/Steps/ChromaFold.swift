import Foundation
import ZTronDSPCore

/// How the twelve values of a chroma frame are scaled (§6.8). A strategy (§5.3): pass `.none`,
/// `.l1`, `.l2` or `.max`, or a conformer of your own.
///
/// Conformers are immutable values, usable on any thread. `norm(of:)` is called on the
/// analysis thread, once per frame: it must not allocate, lock or log (RT-2).
public protocol ChromaNormalization: Hashable, Sendable {
    /// What the twelve pitch-class values of one frame are divided by. The values are not
    /// negative. A frame whose norm lies below the floor of the step is twelve zeros.
    func norm(of chroma: UnsafeBufferPointer<Float>) -> Float
}

/// No normalisation: the sums of the magnitudes as they are.
public struct UnscaledChromaNormalization: ChromaNormalization {
    public init() {}

    @inlinable
    public func norm(of chroma: UnsafeBufferPointer<Float>) -> Float { 1 }
}

/// The values divided by their sum: a frame adds up to 1.
public struct L1ChromaNormalization: ChromaNormalization {
    public init() {}

    @inlinable
    public func norm(of chroma: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        var index = 0
        while index < chroma.count {
            sum += abs(chroma[index])
            index &+= 1
        }
        return sum
    }
}

/// The values divided by their Euclidean length: the squares of a frame add up to 1.
public struct L2ChromaNormalization: ChromaNormalization {
    public init() {}

    @inlinable
    public func norm(of chroma: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        var index = 0
        while index < chroma.count {
            sum += chroma[index] * chroma[index]
            index &+= 1
        }
        return sum.squareRoot()
    }
}

/// The values divided by the largest of them: the strongest pitch class of a frame reads 1.
public struct MaximumChromaNormalization: ChromaNormalization {
    public init() {}

    @inlinable
    public func norm(of chroma: UnsafeBufferPointer<Float>) -> Float {
        var largest: Float = 0
        var index = 0
        while index < chroma.count {
            if abs(chroma[index]) > largest { largest = abs(chroma[index]) }
            index &+= 1
        }
        return largest
    }
}

extension ChromaNormalization where Self == UnscaledChromaNormalization {
    /// No normalisation.
    public static var none: UnscaledChromaNormalization { UnscaledChromaNormalization() }
}

extension ChromaNormalization where Self == L1ChromaNormalization {
    /// A frame adds up to 1.
    public static var l1: L1ChromaNormalization { L1ChromaNormalization() }
}

extension ChromaNormalization where Self == L2ChromaNormalization {
    /// The squares of a frame add up to 1.
    public static var l2: L2ChromaNormalization { L2ChromaNormalization() }
}

extension ChromaNormalization where Self == MaximumChromaNormalization {
    /// The strongest pitch class of a frame reads 1: the default.
    public static var max: MaximumChromaNormalization { MaximumChromaNormalization() }
}

/// Chroma from a constant-Q spectrum (§6.8): the magnitudes of the bins folded onto the twelve
/// pitch classes, C first.
///
/// ```swift
/// ConstantQ(); Magnitude()
/// ChromaFold(normalization: .max)
/// Emit(to: chromagram)
/// ```
///
/// - With `B` bins per octave, bin `k` belongs to the pitch class `round(12 · k / B)` semitones
///   above that of bin 0, modulo 12: a class collects the `B / 12` bins nearest to its
///   semitone in every octave. The class of bin 0 is that of the semitone nearest to it, so a
///   transform that starts on a C starts on class 0 and one that starts on an A on class 9.
///   Tuning belongs to the transform: it has already moved the bins.
/// - The magnitudes of a class are summed. A sum below `threshold` is discarded, as 0. The
///   twelve values are then divided by their norm under `normalization`.
/// - A frame whose norm lies below `floor` is twelve zeros: silence is no pitch class, and
///   nothing is divided by next to nothing (NUM-1).
/// - It follows the magnitudes of a constant-Q spectrum, from `ConstantQ` and `Magnitude` or
///   from `ConstantQScale`: the bins of an STFT are not spaced by semitones (O-7). When the
///   pipeline is attached, bins per octave that are no multiple of 12 are refused.
///
/// Downstream the axis is the twelve pitch classes. There is no way back from here (§6.13).
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on
/// any thread.
public struct ChromaFold: PipelineStage {
    public typealias Input = Spectrum<ConstantQFrequency, MagnitudeValues>
    public typealias Output = Chroma

    let normalizationBox: AnyStrategy
    /// The least sum of magnitudes a pitch class keeps; a smaller one is discarded.
    public let threshold: Double
    /// The least norm a frame is divided by; below it the frame is twelve zeros.
    public let floor: Double
    public let activation: StageActivation

    public init(
        normalization: some ChromaNormalization = .max, threshold: Double = 0, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) {
        normalizationBox = AnyStrategy(normalization)
        self.threshold = threshold
        self.floor = floor
        activation = isActive.stageActivation
    }

    /// The normalisation the step was declared with.
    public var normalization: any ChromaNormalization {
        normalizationBox.value(as: (any ChromaNormalization).self) ?? MaximumChromaNormalization()
    }

    struct Key: Hashable, Sendable {
        let classes: [Int32]
        let threshold: Float
        let floor: Float
        let normalization: AnyStrategy
    }

    /// The pitch class of each bin of a constant-Q axis, C as 0.
    static func pitchClasses(minimumFrequency: Double, binsPerOctave: Int, binCount: Int) -> [Int32] {
        // The semitone nearest to bin 0, as a MIDI note: note 60 is a C, and so is every multiple of 12.
        let note = Int((69 + 12 * log2(minimumFrequency / 440)).rounded())
        let first = ((note % 12) + 12) % 12
        return (0 ..< binCount).map { bin in
            Int32((first + Int((12 * Double(bin) / Double(binsPerOctave)).rounded())) % 12)
        }
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard case .constantQ(let minimum, let binsPerOctave, let bins)? = context.environment.frequencyAxis, bins >= 1, minimum > 0, minimum.isFinite else {
            throw DSPError.unsupportedConfiguration(
                reason: "ChromaFold needs the bins of a constant-Q spectrum: there is no constant-Q axis at this position", stage: context.path)
        }
        guard binsPerOctave >= 12, binsPerOctave % 12 == 0 else {
            let above = (binsPerOctave / 12 + 1) * 12, below = binsPerOctave / 12 * 12
            let nearest = below >= 12 ? "the nearest are \(below) and \(above)" : "the nearest is 12"
            throw context.invalid(
                "binsPerOctave", "\(binsPerOctave) bins per octave do not fold onto twelve pitch classes: chroma need a multiple of 12, so that every semitone has as many bins; \(nearest)")
        }
        guard threshold >= 0, threshold.isFinite else { throw context.invalid("threshold", "the threshold is a sum of magnitudes of 0 or more, not \(threshold)") }
        guard floor >= 0, floor.isFinite else { throw context.invalid("floor", "the floor is a norm of 0 or more, not \(floor)") }
        let classes = ChromaFold.pitchClasses(minimumFrequency: minimum, binsPerOctave: binsPerOctave, binCount: bins)
        let threshold = Float(threshold), floor = Float(floor)
        let normalization = normalization
        context.emit(.analysis(AnalysisStep(
            name: "ChromaFold", key: Key(classes: classes, threshold: threshold, floor: floor, normalization: normalizationBox),
            output: .real(count: 12), scope: .axis(.pitchClasses)
        ) { () throws(DSPError) -> any AnalysisNode in
            try ChromaFoldNode(classes: classes, threshold: threshold, floor: floor, normalization: normalization)
        }))
    }
}

extension Pipeline where Output == Spectrum<ConstantQFrequency, MagnitudeValues> {
    /// The constant-Q magnitudes folded onto the twelve pitch classes: see ``ChromaFold``.
    public func chromaFold(
        normalization: some ChromaNormalization = .max, threshold: Double = 0, floor: Double = 1e-10, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Chroma> {
        appending(ChromaFold(normalization: normalization, threshold: threshold, floor: floor, isActive: isActive))
    }
}
