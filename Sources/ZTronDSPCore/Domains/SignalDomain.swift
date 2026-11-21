/// A signal domain: what one frame of the signal is at some point of a pipeline (§5.2).
///
/// A domain is a type with no values. It exists so that the compiler can check the order of
/// stages: a stage names the domain it consumes and the one it produces, and a composition
/// compiles only when they agree (§5.8, tier 1). `tag` is the same information at run time,
/// for the checks made when a pipeline is attached (tier 2). It may be read on any thread and
/// does not allocate, in every domain of the package.
public protocol SignalDomain: Sendable {
    /// The domain as a run-time value.
    static var tag: DomainTag { get }
}

/// A domain that is a sequence in time at a rate: audio samples at the sample rate, or
/// feature values at the feature rate. Sequence stages (gains, filters, rate changers) run on
/// any sampled sequence and keep its domain.
///
/// A type with no values, like every domain; its tag may be read on any thread and does not
/// allocate.
public protocol SampledSequence: SignalDomain {}

/// A domain whose frame is a vector of real numbers. Such a domain can be written to a
/// `HeatmapFeed` and to a `Binding<[Float]>` (O-11).
///
/// A type with no values, like every domain; its tag may be read on any thread and does not
/// allocate.
public protocol RealVectorDomain: SignalDomain {}

/// A domain whose frame is one value with a confidence. Such a domain can be written to a
/// `Binding<Float>` and to a `Binding<ScalarFrame>` (O-11).
///
/// A type with no values, like every domain; its tag may be read on any thread and does not
/// allocate.
public protocol ScalarValuedDomain: SignalDomain {}

// MARK: Spectra

/// What the bins of a spectrum are spaced by.
///
/// A type with no values; its tag may be read on any thread and does not allocate.
public protocol SpectralAxis: Sendable {
    /// The axis as a run-time value.
    static var axisTag: DomainTag.Axis { get }
}

/// What a bin of a spectrum holds.
///
/// A type with no values; its tag may be read on any thread and does not allocate.
public protocol SpectralValues: Sendable {
    /// The values as a run-time value.
    static var valuesTag: DomainTag.Values { get }
}

/// Real values: magnitudes, powers or decibels.
///
/// A type with no values; its tag may be read on any thread and does not allocate.
public protocol RealValued: SpectralValues {}

/// Values on a linear scale that add like energies: magnitudes or powers. Band projections
/// (mel, constant-Q) and the spectral centroid need them (O-5, O-8).
///
/// A type with no values; its tag may be read on any thread and does not allocate.
public protocol LinearValued: RealValued {}

/// Bins evenly spaced in hertz, from 0 Hz to the Nyquist frequency.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum LinearFrequency: SpectralAxis {
    /// `.linear`.
    public static var axisTag: DomainTag.Axis { .linear }
}

/// Bands evenly spaced on the mel scale.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum MelFrequency: SpectralAxis {
    /// `.mel`.
    public static var axisTag: DomainTag.Axis { .mel }
}

/// Bins spaced by a constant ratio: a fixed number per octave.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum ConstantQFrequency: SpectralAxis {
    /// `.constantQ`.
    public static var axisTag: DomainTag.Axis { .constantQ }
}

/// Complex bins: magnitude and phase.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum ComplexValues: SpectralValues {
    /// `.complex`.
    public static var valuesTag: DomainTag.Values { .complex }
}

/// Magnitudes, `|X|`.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum MagnitudeValues: LinearValued {
    /// `.magnitude`.
    public static var valuesTag: DomainTag.Values { .magnitude }
}

/// Powers, `|X|²`.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum PowerValues: LinearValued {
    /// `.power`.
    public static var valuesTag: DomainTag.Values { .power }
}

/// Levels in decibels.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum DecibelValues: RealValued {
    /// `.decibel`.
    public static var valuesTag: DomainTag.Values { .decibel }
}

// MARK: The domains

/// A block of audio samples per channel, at the sample rate.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Samples: SampledSequence {
    /// `.samples`.
    public static var tag: DomainTag { .samples }
}

/// One value per frequency bin, once per hop.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Spectrum<Axis: SpectralAxis, Values: SpectralValues>: SignalDomain {
    /// `.spectrum` with the axis and the values of the type's parameters.
    public static var tag: DomainTag { .spectrum(axis: Axis.axisTag, values: Values.valuesTag) }
}

extension Spectrum: RealVectorDomain where Values: RealValued {}

/// A cepstrum: one value per quefrency.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Quefrency: RealVectorDomain {
    /// `.quefrency`.
    public static var tag: DomainTag { .quefrency }
}

/// Mel-frequency cepstral coefficients.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum MelCepstrum: RealVectorDomain {
    /// `.melCepstrum`.
    public static var tag: DomainTag { .melCepstrum }
}

/// Twelve pitch-class energies.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Chroma: RealVectorDomain {
    /// `.chroma`.
    public static var tag: DomainTag { .chroma }
}

/// An autocorrelation over lag.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Lags: RealVectorDomain {
    /// `.lags`.
    public static var tag: DomainTag { .lags }
}

/// One column of a tempogram.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum TempoSpectrum: RealVectorDomain {
    /// `.tempoSpectrum`.
    public static var tag: DomainTag { .tempoSpectrum }
}

/// (min, max) pairs of a waveform.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Envelope: SignalDomain {
    /// `.envelope`.
    public static var tag: DomainTag { .envelope }
}

/// One onset-strength value, once per hop: a sampled sequence at the feature rate.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Novelty: SampledSequence, ScalarValuedDomain {
    /// `.novelty`.
    public static var tag: DomainTag { .novelty }
}

/// One value with a confidence, once per hop: a sampled sequence at the feature rate.
///
/// No values; its tag may be read on any thread and does not allocate.
public enum Scalar: SampledSequence, ScalarValuedDomain {
    /// `.scalar`.
    public static var tag: DomainTag { .scalar }
}

// MARK: Run-time tags

/// A signal domain as a run-time value: what the type-erased description of a pipeline is
/// checked against when it is attached (§5.8, tier 2).
///
/// A value, usable on any thread. It does not allocate, except the name of a custom domain
/// and ``description``.
public enum DomainTag: Hashable, Sendable, CustomStringConvertible {
    /// Audio samples (`Samples`).
    case samples
    /// A spectrum, by its axis and what its bins hold (`Spectrum`).
    case spectrum(axis: Axis, values: Values)
    /// A cepstrum (`Quefrency`).
    case quefrency
    /// Mel-frequency cepstral coefficients (`MelCepstrum`).
    case melCepstrum
    /// Pitch-class energies (`Chroma`).
    case chroma
    /// An autocorrelation over lag (`Lags`).
    case lags
    /// A column of a tempogram (`TempoSpectrum`).
    case tempoSpectrum
    /// (min, max) pairs of a waveform (`Envelope`).
    case envelope
    /// An onset-strength curve (`Novelty`).
    case novelty
    /// One value with a confidence (`Scalar`).
    case scalar
    /// A domain defined outside the package, by name.
    case custom(String)

    /// What the bins of a spectrum are spaced by, as a run-time value.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum Axis: Hashable, Sendable {
        /// Evenly spaced in hertz (`LinearFrequency`).
        case linear
        /// Evenly spaced on the mel scale (`MelFrequency`).
        case mel
        /// A constant ratio apart (`ConstantQFrequency`).
        case constantQ
    }

    /// What a bin of a spectrum holds, as a run-time value.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum Values: Hashable, Sendable {
        /// Complex bins (`ComplexValues`).
        case complex
        /// Magnitudes (`MagnitudeValues`).
        case magnitude
        /// Powers (`PowerValues`).
        case power
        /// Levels in decibels (`DecibelValues`).
        case decibel
    }

    /// How a frame of the domain is delivered.
    ///
    /// A value, usable on any thread; it does not allocate.
    public enum FrameKind: Hashable, Sendable {
        /// An `AudioBlock`.
        case samples
        /// A `RealFrame`.
        case real
        /// A `ComplexFrame`.
        case complex
        /// A `ScalarFrame`.
        case scalar
        /// An `EnvelopeFrame`.
        case envelope
    }

    /// True for samples, novelty curves and scalars: sequence stages run on these.
    public var isSampledSequence: Bool {
        switch self {
        case .samples, .novelty, .scalar: true
        default: false
        }
    }

    /// True when a frame is a vector of real numbers.
    public var isRealVector: Bool {
        switch self {
        case .spectrum(_, let values): values != .complex
        case .quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum: true
        case .samples, .envelope, .novelty, .scalar, .custom: false
        }
    }

    /// True when a frame is one value with a confidence.
    public var isScalarValued: Bool {
        self == .novelty || self == .scalar
    }

    /// True for a spectrum, whatever its axis and values.
    public var isSpectrum: Bool {
        if case .spectrum = self { return true }
        return false
    }

    /// How a frame of the domain is delivered. A custom domain delivers real frames.
    public var frameKind: FrameKind {
        switch self {
        case .samples: .samples
        case .spectrum(_, let values): values == .complex ? .complex : .real
        case .quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum, .custom: .real
        case .envelope: .envelope
        case .novelty, .scalar: .scalar
        }
    }

    /// The domain in words, as errors name it: `linear-frequency power spectrum`, `chroma`;
    /// for a custom domain, its name.
    public var description: String {
        switch self {
        case .samples:
            return "samples"
        case .spectrum(let axis, let values):
            let axisName: String
            switch axis {
            case .linear: axisName = "linear-frequency"
            case .mel: axisName = "mel"
            case .constantQ: axisName = "constant-Q"
            }
            let valueName: String
            switch values {
            case .complex: valueName = "complex spectrum"
            case .magnitude: valueName = "magnitude spectrum"
            case .power: valueName = "power spectrum"
            case .decibel: valueName = "spectrum in decibels"
            }
            return "\(axisName) \(valueName)"
        case .quefrency: return "cepstrum"
        case .melCepstrum: return "mel cepstrum"
        case .chroma: return "chroma"
        case .lags: return "autocorrelation lags"
        case .tempoSpectrum: return "tempo spectrum"
        case .envelope: return "waveform envelope"
        case .novelty: return "novelty curve"
        case .scalar: return "scalar"
        case .custom(let name): return name
        }
    }
}
