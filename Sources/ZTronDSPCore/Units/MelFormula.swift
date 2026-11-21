import Foundation

/// A mapping between hertz and the mel scale (§6.11). The two functions are exact inverses of
/// each other.
///
/// A strategy (§5.3): pass `.slaney` or `.htk`, or a conformer of your own, wherever a formula
/// is asked for. Conformers are immutable values, usable on any thread; the stock ones do not
/// allocate.
public protocol MelFormula: Hashable, Sendable {
    /// The mel value of a frequency in hertz.
    func mel(fromHertz hertz: Double) -> Double
    /// The frequency in hertz of a mel value: the inverse of `mel(fromHertz:)`.
    func hertz(fromMel mel: Double) -> Double
}

/// Slaney's formula (Auditory Toolbox, 1998): linear below 1 000 Hz, logarithmic above.
/// 1 000 Hz is 15 mel.
///
/// An immutable value, usable on any thread; it does not allocate.
public struct SlaneyMelFormula: MelFormula {
    /// The formula; it has no parameters.
    public init() {}

    @usableFromInline static let breakHertz = 1_000.0
    @usableFromInline static let breakMel = 15.0
    @usableFromInline static let hertzPerMel = 200.0 / 3.0
    @usableFromInline static let logStep = Foundation.log(6.4) / 27.0

    /// `hertz / (200 / 3)` below 1 000 Hz; above, 15 plus 27 mel per factor of 6.4.
    @inlinable
    public func mel(fromHertz hertz: Double) -> Double {
        hertz < Self.breakHertz
            ? hertz / Self.hertzPerMel
            : Self.breakMel + Foundation.log(hertz / Self.breakHertz) / Self.logStep
    }

    /// The inverse: linear below 15 mel, exponential above.
    @inlinable
    public func hertz(fromMel mel: Double) -> Double {
        mel < Self.breakMel
            ? mel * Self.hertzPerMel
            : Self.breakHertz * Foundation.exp(Self.logStep * (mel - Self.breakMel))
    }
}

/// The HTK formula: `m = 2 595 · log₁₀(1 + f / 700)`.
///
/// An immutable value, usable on any thread; it does not allocate.
public struct HTKMelFormula: MelFormula {
    /// The formula; it has no parameters.
    public init() {}

    /// `2 595 · log₁₀(1 + hertz / 700)`.
    @inlinable
    public func mel(fromHertz hertz: Double) -> Double {
        2_595 * Foundation.log10(1 + hertz / 700)
    }

    /// The inverse: `700 · (10^(mel / 2 595) − 1)`.
    @inlinable
    public func hertz(fromMel mel: Double) -> Double {
        700 * (Foundation.pow(10, mel / 2_595) - 1)
    }
}

extension MelFormula where Self == SlaneyMelFormula {
    /// Slaney's formula, the default. Usable on any thread; it does not allocate.
    public static var slaney: SlaneyMelFormula { SlaneyMelFormula() }
}

extension MelFormula where Self == HTKMelFormula {
    /// The HTK formula. Usable on any thread; it does not allocate.
    public static var htk: HTKMelFormula { HTKMelFormula() }
}

extension DSP {
    /// Hertz to mel. Usable on any thread; it does not allocate with the stock formulas.
    @inlinable
    public static func mel(fromHertz hertz: Double, formula: some MelFormula = .slaney) -> Double {
        formula.mel(fromHertz: hertz)
    }

    /// Mel to hertz. Usable on any thread; it does not allocate with the stock formulas.
    @inlinable
    public static func hertz(fromMel mel: Double, formula: some MelFormula = .slaney) -> Double {
        formula.hertz(fromMel: mel)
    }

    /// Hertz to mel, element by element. Usable on any thread; allocates the array it returns.
    public static func mel(fromHertz hertz: [Double], formula: some MelFormula = .slaney) -> [Double] {
        hertz.map { formula.mel(fromHertz: $0) }
    }

    /// Mel to hertz, element by element. Usable on any thread; allocates the array it returns.
    public static func hertz(fromMel mel: [Double], formula: some MelFormula = .slaney) -> [Double] {
        mel.map { formula.hertz(fromMel: $0) }
    }
}
