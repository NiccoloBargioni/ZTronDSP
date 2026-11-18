/// A signal domain: what one frame of the signal is at some point of a pipeline (§5.2).
///
/// A domain is a type with no values. It exists so that the compiler can check the order of
/// stages: a stage names the domain it consumes and the one it produces, and a composition
/// compiles only when they agree (§5.8, tier 1). `tag` is the same information at run time,
/// for the checks made when a pipeline is attached (tier 2).
public protocol SignalDomain: Sendable {
    static var tag: DomainTag { get }
}

/// A domain that is a sequence in time at a rate: audio samples at the sample rate, or
/// feature values at the feature rate. Sequence stages (gains, filters, rate changers) run on
/// any sampled sequence and keep its domain.
public protocol SampledSequence: SignalDomain {}

/// A domain whose frame is a vector of real numbers. Such a domain can be written to a
/// `HeatmapFeed` and to a `Binding<[Float]>` (O-11).
public protocol RealVectorDomain: SignalDomain {}

/// A domain whose frame is one value with a confidence. Such a domain can be written to a
/// `Binding<Float>` and to a `Binding<ScalarFrame>` (O-11).
public protocol ScalarValuedDomain: SignalDomain {}

// MARK: Spectra

/// What the bins of a spectrum are spaced by.
public protocol SpectralAxis: Sendable {
    static var axisTag: DomainTag.Axis { get }
}

/// What a bin of a spectrum holds.
public protocol SpectralValues: Sendable {
    static var valuesTag: DomainTag.Values { get }
}

/// Real values: magnitudes, powers or decibels.
public protocol RealValued: SpectralValues {}

/// Values on a linear scale that add like energies: magnitudes or powers. Band projections
/// (mel, constant-Q) and the spectral centroid need them (O-5, O-8).
public protocol LinearValued: RealValued {}

/// Bins evenly spaced in hertz, from 0 Hz to the Nyquist frequency.
public enum LinearFrequency: SpectralAxis { public static var axisTag: DomainTag.Axis { .linear } }
/// Bands evenly spaced on the mel scale.
public enum MelFrequency: SpectralAxis { public static var axisTag: DomainTag.Axis { .mel } }
/// Bins spaced by a constant ratio: a fixed number per octave.
public enum ConstantQFrequency: SpectralAxis { public static var axisTag: DomainTag.Axis { .constantQ } }

/// Complex bins: magnitude and phase.
public enum ComplexValues: SpectralValues { public static var valuesTag: DomainTag.Values { .complex } }
/// Magnitudes, `|X|`.
public enum MagnitudeValues: LinearValued { public static var valuesTag: DomainTag.Values { .magnitude } }
/// Powers, `|X|²`.
public enum PowerValues: LinearValued { public static var valuesTag: DomainTag.Values { .power } }
/// Levels in decibels.
public enum DecibelValues: RealValued { public static var valuesTag: DomainTag.Values { .decibel } }

// MARK: The domains

/// A block of audio samples per channel, at the sample rate.
public enum Samples: SampledSequence { public static var tag: DomainTag { .samples } }

/// One value per frequency bin, once per hop.
public enum Spectrum<Axis: SpectralAxis, Values: SpectralValues>: SignalDomain {
    public static var tag: DomainTag { .spectrum(axis: Axis.axisTag, values: Values.valuesTag) }
}

extension Spectrum: RealVectorDomain where Values: RealValued {}

/// A cepstrum: one value per quefrency.
public enum Quefrency: RealVectorDomain { public static var tag: DomainTag { .quefrency } }
/// Mel-frequency cepstral coefficients.
public enum MelCepstrum: RealVectorDomain { public static var tag: DomainTag { .melCepstrum } }
/// Twelve pitch-class energies.
public enum Chroma: RealVectorDomain { public static var tag: DomainTag { .chroma } }
/// An autocorrelation over lag.
public enum Lags: RealVectorDomain { public static var tag: DomainTag { .lags } }
/// One column of a tempogram.
public enum TempoSpectrum: RealVectorDomain { public static var tag: DomainTag { .tempoSpectrum } }
/// (min, max) pairs of a waveform.
public enum Envelope: SignalDomain { public static var tag: DomainTag { .envelope } }
/// One onset-strength value, once per hop: a sampled sequence at the feature rate.
public enum Novelty: SampledSequence, ScalarValuedDomain { public static var tag: DomainTag { .novelty } }
/// One value with a confidence, once per hop: a sampled sequence at the feature rate.
public enum Scalar: SampledSequence, ScalarValuedDomain { public static var tag: DomainTag { .scalar } }

// MARK: Run-time tags

/// A signal domain as a run-time value: what the type-erased description of a pipeline is
/// checked against when it is attached (§5.8, tier 2).
public enum DomainTag: Hashable, Sendable, CustomStringConvertible {
    case samples
    case spectrum(axis: Axis, values: Values)
    case quefrency
    case melCepstrum
    case chroma
    case lags
    case tempoSpectrum
    case envelope
    case novelty
    case scalar
    /// A domain defined outside the package, by name.
    case custom(String)

    public enum Axis: Hashable, Sendable { case linear, mel, constantQ }
    public enum Values: Hashable, Sendable { case complex, magnitude, power, decibel }

    /// How a frame of the domain is delivered.
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
