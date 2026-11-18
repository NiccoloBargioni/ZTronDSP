import Foundation

/// A frequency, in whichever unit it was stated (§6.1). A stage keeps the unit and resolves
/// it against the environment's sample rate when the plan is compiled (ENV-2), so
/// `.fractionOfNyquist(0.5)` means a different number of hertz at 44.1 kHz and at 48 kHz.
///
/// Construction never fails; a value that makes no sense (negative, not finite) is reported
/// as a typed error when the frequency is resolved. An immutable value, usable on any thread.
public struct Frequency: Hashable, Sendable, CustomStringConvertible {
    @usableFromInline
    enum Unit: Hashable, Sendable {
        case hertz
        case normalized
        case fractionOfNyquist
        case radiansPerSample
        case midiNote
        case mel(AnyStrategy)
    }

    @usableFromInline let unit: Unit
    /// The number as it was stated, in the unit it was stated in.
    public let value: Double

    @usableFromInline
    init(unit: Unit, value: Double) {
        self.unit = unit
        self.value = value
    }

    /// Cycles per second.
    public static func hertz(_ value: Double) -> Frequency { Frequency(unit: .hertz, value: value) }

    /// Cycles per sample: `0 … 0.5`, where `0.5` is the Nyquist frequency.
    public static func normalized(_ cyclesPerSample: Double) -> Frequency {
        Frequency(unit: .normalized, value: cyclesPerSample)
    }

    /// A fraction of the Nyquist frequency: `0 … 1`.
    public static func fractionOfNyquist(_ fraction: Double) -> Frequency {
        Frequency(unit: .fractionOfNyquist, value: fraction)
    }

    /// Radians per sample: `0 … π`.
    public static func radiansPerSample(_ value: Double) -> Frequency {
        Frequency(unit: .radiansPerSample, value: value)
    }

    /// A MIDI note number, fractional notes included: 69 is 440 Hz, 12 notes to the octave.
    public static func midiNote(_ note: Double) -> Frequency { Frequency(unit: .midiNote, value: note) }

    /// A frequency on the mel scale (§6.11).
    public static func mel(_ value: Double, formula: some MelFormula = .slaney) -> Frequency {
        Frequency(unit: .mel(AnyStrategy(formula)), value: value)
    }

    /// True when the frequency in hertz depends on the sample rate it is resolved against.
    public var dependsOnSampleRate: Bool {
        switch unit {
        case .normalized, .fractionOfNyquist, .radiansPerSample: true
        case .hertz, .midiNote, .mel: false
        }
    }

    // MARK: Resolution

    /// The frequency in hertz at `sampleRate`.
    ///
    /// - Throws: `DSPError.invalidParameter` when the frequency or the sample rate is
    ///   negative or not finite.
    public func hertz(sampleRate: Double) throws(DSPError) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        guard value.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "frequency", reason: "\(self) is not finite")
        }
        let hertz: Double
        switch unit {
        case .hertz: hertz = value
        case .normalized: hertz = value * sampleRate
        case .fractionOfNyquist: hertz = value * (sampleRate / 2)
        case .radiansPerSample: hertz = value / (2 * .pi) * sampleRate
        case .midiNote: hertz = 440 * pow(2, (value - 69) / 12)
        case .mel(let formula):
            guard let formula = formula.value(as: (any MelFormula).self) else {
                throw .invalidParameter(stage: .none, parameter: "frequency", reason: "\(self) has no mel formula")
            }
            hertz = formula.hertz(fromMel: value)
        }
        guard hertz.isFinite, hertz >= 0 else {
            throw .invalidParameter(stage: .none, parameter: "frequency", reason: "\(self) is negative or not finite")
        }
        return hertz
    }

    /// The frequency in cycles per sample at `sampleRate`: 0.5 is the Nyquist frequency.
    public func normalized(sampleRate: Double) throws(DSPError) -> Double {
        if case .normalized = unit { return try validated(value, sampleRate: sampleRate) }
        if case .fractionOfNyquist = unit { return try validated(value, sampleRate: sampleRate) / 2 }
        return try hertz(sampleRate: sampleRate) / sampleRate
    }

    /// The frequency as a fraction of the Nyquist frequency at `sampleRate`.
    public func fractionOfNyquist(sampleRate: Double) throws(DSPError) -> Double {
        if case .fractionOfNyquist = unit { return try validated(value, sampleRate: sampleRate) }
        if case .normalized = unit { return try validated(value, sampleRate: sampleRate) * 2 }
        return try hertz(sampleRate: sampleRate) / (sampleRate / 2)
    }

    /// The frequency in radians per sample at `sampleRate`.
    public func radiansPerSample(sampleRate: Double) throws(DSPError) -> Double {
        if case .radiansPerSample = unit { return try validated(value, sampleRate: sampleRate) }
        return try normalized(sampleRate: sampleRate) * 2 * .pi
    }

    /// The frequency as a MIDI note number at `sampleRate`. 0 Hz has no note and is an error.
    public func midiNote(sampleRate: Double) throws(DSPError) -> Double {
        if case .midiNote = unit, value.isFinite { return value }
        let hertz = try hertz(sampleRate: sampleRate)
        guard hertz > 0 else {
            throw .invalidParameter(stage: .none, parameter: "frequency", reason: "0 Hz has no MIDI note")
        }
        return 69 + 12 * log2(hertz / 440)
    }

    /// The frequency on the mel scale at `sampleRate`.
    public func mel(sampleRate: Double, formula: some MelFormula = .slaney) throws(DSPError) -> Double {
        if case .mel(let own) = unit, own == AnyStrategy(formula), value.isFinite, value >= 0 { return value }
        return formula.mel(fromHertz: try hertz(sampleRate: sampleRate))
    }

    private func validated(_ value: Double, sampleRate: Double) throws(DSPError) -> Double {
        _ = try hertz(sampleRate: sampleRate)
        return value
    }

    // MARK: Animation (ANI-2)

    /// The value a parameter vector carries for this frequency: log₂ of the stated number for
    /// the linear units, so an animated frequency glides evenly in pitch; the note number
    /// over twelve for a MIDI note; the stated number for a mel value.
    public var animatableValue: Double {
        switch unit {
        case .hertz, .normalized, .fractionOfNyquist, .radiansPerSample:
            return log2(max(value, Self.smallestAnimatableValue))
        case .midiNote:
            return value / 12
        case .mel:
            return value
        }
    }

    /// The frequency in the same unit whose ``animatableValue`` is `animatableValue`. Passing
    /// this frequency's own value returns it unchanged, bit for bit.
    public func replacing(animatableValue: Double) -> Frequency {
        guard animatableValue != self.animatableValue else { return self }
        switch unit {
        case .hertz, .normalized, .fractionOfNyquist, .radiansPerSample:
            return Frequency(unit: unit, value: pow(2, animatableValue))
        case .midiNote:
            return Frequency(unit: unit, value: animatableValue * 12)
        case .mel:
            return Frequency(unit: unit, value: animatableValue)
        }
    }

    @usableFromInline static let smallestAnimatableValue = 1e-9

    public var description: String {
        switch unit {
        case .hertz: "\(value) Hz"
        case .normalized: "\(value) cycles per sample"
        case .fractionOfNyquist: "\(value) of Nyquist"
        case .radiansPerSample: "\(value) rad per sample"
        case .midiNote: "MIDI note \(value)"
        case .mel: "\(value) mel"
        }
    }
}
