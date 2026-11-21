import Foundation
import ZTronDSPCore

/// Mel-frequency cepstral coefficients (§6.6): the orthonormal DCT-II of a mel spectrum in
/// decibels, of which the first `count` values are kept.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 40); Decibels()
/// CepstralCoefficients(count: 13)
/// ```
///
/// It follows a mel spectrum in decibels: the coefficients are defined on log energies
/// (O-10). The vDSP DCT is used when the band count is a length it documents (64, 80 and 128
/// are; 26 and 40 are not), a pre-computed basis otherwise; the decision is arithmetic, and
/// no setup is created to find out (E-09). Downstream the rows are plain positions.
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on
/// any thread; `lower(_:)` runs on the control context and may allocate.
public struct CepstralCoefficients: PipelineStage {
    /// A mel spectrum in decibels (O-10).
    public typealias Input = Spectrum<MelFrequency, DecibelValues>
    /// The coefficients, one per row.
    public typealias Output = MelCepstrum

    /// Coefficients kept, from the first on.
    public let count: Int
    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// Keeps the first `count` coefficients: between 1 and the band count, which `lower(_:)`
    /// checks when the plan is compiled.
    public init(count: Int = 13, isActive: some ActivationSource = .active) {
        self.count = count
        self.activation = isActive.stageActivation
    }

    struct Key: Hashable, Sendable {
        let bands: Int
        let count: Int
    }

    /// Checks the count against the bands at the step's position and emits the transform: the
    /// vDSP DCT at a band count it documents, the basis otherwise. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bands = context.environment.frequencyAxis?.rowCount, bands >= 1 else {
            throw DSPError.unsupportedConfiguration(
                reason: "CepstralCoefficients needs the bands of a mel spectrum: there is no axis at this position", stage: context.path)
        }
        guard count >= 1, count <= bands else {
            throw context.invalid("count", "\(count) coefficients cannot be kept of the \(bands) a spectrum of \(bands) bands has: the count lies between 1 and the band count")
        }
        let count = count
        context.emit(.analysis(AnalysisStep(
            name: "CepstralCoefficients", key: Key(bands: bands, count: count), output: .real(count: count), scope: .axis(.indices(count: count))
        ) { () throws(DSPError) -> any AnalysisNode in
            // The length rule decides, by arithmetic (E-09).
            if DSP.isFastLength(bands) { return try CosineTransformNode(bands: bands, count: count) }
            return try CosineBasisNode(bands: bands, count: count, isInverse: false)
        }))
    }
}

/// From mel-frequency cepstral coefficients back to a mel spectrum in decibels of `bands`
/// bands (§6.6, §6.13): the transposed DCT basis.
///
/// It is exact when the coefficients are as many as the bands. With fewer, what the dropped
/// coefficients carried is gone, and the result is the smooth part of the spectrum; the
/// inversion report says how much that is. The centres of the bands are not known here, so
/// downstream the rows are plain positions.
///
/// Switched off, it suspends the rest of its branch (ACT-3). An immutable value, usable on
/// any thread; `lower(_:)` runs on the control context and may allocate.
public struct InverseCepstralCoefficients: PipelineStage {
    /// Mel-frequency cepstral coefficients.
    public typealias Input = MelCepstrum
    /// A mel spectrum in decibels.
    public typealias Output = Spectrum<MelFrequency, DecibelValues>

    /// Bands of the spectrum produced.
    public let bands: Int
    /// The step's switch: off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    /// A spectrum of `bands` bands: at least as many as the coefficients and at most 65 536, which
    /// `lower(_:)` checks when the plan is compiled.
    public init(bands: Int, isActive: some ActivationSource = .active) {
        self.bands = bands
        self.activation = isActive.stageActivation
    }

    /// Checks the band count against the coefficients at the step's position and emits the
    /// transposed basis. Control context; may allocate.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let count = context.environment.frequencyAxis?.rowCount, count >= 1 else {
            throw DSPError.unsupportedConfiguration(
                reason: "InverseCepstralCoefficients needs cepstral coefficients: there is no axis at this position", stage: context.path)
        }
        guard bands >= count, bands <= 1 << 16 else {
            throw context.invalid("bands", "\(count) coefficients cannot come from a spectrum of \(bands) bands: the band count lies between the coefficient count and 65 536")
        }
        let bands = bands
        context.emit(.analysis(AnalysisStep(
            name: "InverseCepstralCoefficients", key: CepstralCoefficients.Key(bands: bands, count: count), output: .real(count: bands),
            scope: .axis(.indices(count: bands))
        ) { () throws(DSPError) -> any AnalysisNode in
            try CosineBasisNode(bands: bands, count: count, isInverse: true)
        }))
    }
}

extension CepstralCoefficients {
    /// The step that undoes this one where it can be undone: with as many bands as coefficients
    /// (INV-1). Usable on any thread; it does not allocate.
    public var inverse: InverseCepstralCoefficients { InverseCepstralCoefficients(bands: count) }
}

extension Pipeline where Output == Spectrum<MelFrequency, DecibelValues> {
    /// The mel-frequency cepstral coefficients of each frame: see ``CepstralCoefficients``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func cepstralCoefficients(count: Int = 13, isActive: some ActivationSource = .active) -> Pipeline<Input, MelCepstrum> {
        appending(CepstralCoefficients(count: count, isActive: isActive))
    }
}

extension Pipeline where Output == MelCepstrum {
    /// The coefficients back to a mel spectrum in decibels: see ``InverseCepstralCoefficients``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func inverseCepstralCoefficients(bands: Int, isActive: some ActivationSource = .active) -> Pipeline<Input, Spectrum<MelFrequency, DecibelValues>> {
        appending(InverseCepstralCoefficients(bands: bands, isActive: isActive))
    }
}

/// The orthonormal DCT-II as a table (§6.6): row `k` is `cₖ·cos(π·k·(j + ½) / bands)` over the
/// bands `j`, with `c₀ = √(1 / bands)` and `cₖ = √(2 / bands)` otherwise.
enum CosineBasis {
    /// The first `count` rows, row after row: `count · bands` values, from double precision.
    static func orthonormal(bands: Int, count: Int) -> [Float] {
        var table = [Float](repeating: 0, count: count * bands)
        let scale = (2 / Double(bands)).squareRoot()
        for row in 0 ..< count {
            let factor = row == 0 ? scale * 0.5.squareRoot() : scale
            for column in 0 ..< bands {
                table[row * bands + column] = Float(factor * cos(.pi * Double(row) * (Double(column) + 0.5) / Double(bands)))
            }
        }
        return table
    }
}
