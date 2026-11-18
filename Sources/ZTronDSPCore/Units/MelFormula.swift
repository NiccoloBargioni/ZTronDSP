import Foundation

/// A mapping between hertz and the mel scale (§6.11). The two functions are exact inverses of
/// each other.
///
/// A strategy (§5.3): pass `.slaney` or `.htk`, or a conformer of your own, wherever a formula
/// is asked for. Conformers are immutable values, usable on any thread.
public protocol MelFormula: Hashable, Sendable {
    func mel(fromHertz hertz: Double) -> Double
    func hertz(fromMel mel: Double) -> Double
}

/// Slaney's formula (Auditory Toolbox, 1998): linear below 1 000 Hz, logarithmic above.
/// 1 000 Hz is 15 mel.
public struct SlaneyMelFormula: MelFormula {
    public init() {}

    @usableFromInline static let breakHertz = 1_000.0
    @usableFromInline static let breakMel = 15.0
    @usableFromInline static let hertzPerMel = 200.0 / 3.0
    @usableFromInline static let logStep = Foundation.log(6.4) / 27.0

    @inlinable
    public func mel(fromHertz hertz: Double) -> Double {
        hertz < Self.breakHertz
            ? hertz / Self.hertzPerMel
            : Self.breakMel + Foundation.log(hertz / Self.breakHertz) / Self.logStep
    }

    @inlinable
    public func hertz(fromMel mel: Double) -> Double {
        mel < Self.breakMel
            ? mel * Self.hertzPerMel
            : Self.breakHertz * Foundation.exp(Self.logStep * (mel - Self.breakMel))
    }
}

/// The HTK formula: `m = 2 595 · log₁₀(1 + f / 700)`.
public struct HTKMelFormula: MelFormula {
    public init() {}

    @inlinable
    public func mel(fromHertz hertz: Double) -> Double {
        2_595 * Foundation.log10(1 + hertz / 700)
    }

    @inlinable
    public func hertz(fromMel mel: Double) -> Double {
        700 * (Foundation.pow(10, mel / 2_595) - 1)
    }
}

extension MelFormula where Self == SlaneyMelFormula {
    /// Slaney's formula, the default.
    public static var slaney: SlaneyMelFormula { SlaneyMelFormula() }
}

extension MelFormula where Self == HTKMelFormula {
    /// The HTK formula.
    public static var htk: HTKMelFormula { HTKMelFormula() }
}

extension DSP {
    /// Hertz to mel.
    @inlinable
    public static func mel(fromHertz hertz: Double, formula: some MelFormula = .slaney) -> Double {
        formula.mel(fromHertz: hertz)
    }

    /// Mel to hertz.
    @inlinable
    public static func hertz(fromMel mel: Double, formula: some MelFormula = .slaney) -> Double {
        formula.hertz(fromMel: mel)
    }

    /// Hertz to mel, element by element.
    public static func mel(fromHertz hertz: [Double], formula: some MelFormula = .slaney) -> [Double] {
        hertz.map { formula.mel(fromHertz: $0) }
    }

    /// Mel to hertz, element by element.
    public static func hertz(fromMel mel: [Double], formula: some MelFormula = .slaney) -> [Double] {
        mel.map { formula.hertz(fromMel: $0) }
    }
}
