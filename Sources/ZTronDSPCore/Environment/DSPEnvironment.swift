import Foundation

/// A key of the pipeline environment (§5.4): a type that names a value and gives its default.
public protocol DSPEnvironmentKey {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// A key the app may set, with `.environment(_:_:)` on a pipeline or a `Group`, or with
/// ``DSPEnvironment/setting(_:to:)``. Three built-in keys are settable; every other built-in
/// key is derived from the source and the stages and has no setter (ENV-3). Keys an app
/// defines are settable by adopting this protocol. The value is `Hashable` because an override
/// is part of a pipeline's description and descriptions compare (API-1).
public protocol SettableDSPEnvironmentKey: DSPEnvironmentKey where Value: Hashable {}

protocol BuiltInDSPEnvironmentKey: DSPEnvironmentKey {
    static func read(_ environment: DSPEnvironment) -> Value
}

/// The environment of a pipeline: typed, keyed values that the framework fills in and that
/// stages read, as `EnvironmentValues` is to a SwiftUI view tree (§5.4).
///
/// The environment is **positional** (ENV-1): a stage that changes the rate or the domain
/// rewrites it for everything downstream, so the value a stage reads is the value at its own
/// position. It is a value (IMM-5): every change returns a new environment.
///
/// Usable on any thread.
public struct DSPEnvironment: Hashable, Sendable {
    var storedSampleRate: Double
    var storedChannelCount: Int
    var storedBlockSize: Int
    var storedFrameSize: Int?
    var storedHopSize: Int?
    var storedAxis: FeedAxis?
    var storedLatency: TimeInterval
    var storedIsRealTime: Bool
    var storedSourceKind: SourceKind
    var overrides: [ObjectIdentifier: AnyStrategy]

    /// An environment at the start of a signal: no spectral scope, no latency.
    ///
    /// The engine resolves the environment of an attachment from its source (ATT-3). Create
    /// one yourself to design or test away from a source.
    public init(sampleRate: Double = 48_000, channelCount: Int = 1, blockSize: Int = 512, isRealTime: Bool = false) {
        storedSampleRate = sampleRate
        storedChannelCount = channelCount
        storedBlockSize = blockSize
        storedFrameSize = nil
        storedHopSize = nil
        storedAxis = nil
        storedLatency = 0
        storedIsRealTime = isRealTime
        storedSourceKind = .offline
        overrides = [:]
    }

    /// The environment an unresolved description is compared in: 48 kHz, mono, 512 frames.
    public static let reference = DSPEnvironment()

    // MARK: Reading

    /// The value of a key at this position: a built-in key's current value, an override, or
    /// the key's default.
    public subscript<K: DSPEnvironmentKey>(key: K.Type) -> K.Value {
        if let builtIn = key as? any BuiltInDSPEnvironmentKey.Type, let value = Self.read(builtIn, self) as? K.Value {
            return value
        }
        if let value = overrides[ObjectIdentifier(key)]?.value(as: K.Value.self) {
            return value
        }
        return key.defaultValue
    }

    private static func read<B: BuiltInDSPEnvironmentKey>(_ key: B.Type, _ environment: DSPEnvironment) -> B.Value {
        key.read(environment)
    }

    /// Samples per second of the sequence at this point. Downstream of a step that produces a
    /// novelty curve or a scalar it is the feature rate.
    public var sampleRate: Double { storedSampleRate }
    /// `sampleRate / 2`.
    public var nyquistFrequency: Double { storedSampleRate / 2 }
    /// Channels in the signal.
    public var channelCount: Int { storedChannelCount }
    /// Frames per processing block, as the engine was created with.
    public var blockSize: Int { storedBlockSize }
    /// The frame size of the framing step, inside a spectral scope.
    public var frameSize: Int? { storedFrameSize }
    /// The hop of the framing step, inside a spectral scope.
    public var hopSize: Int? { storedHopSize }
    /// `sampleRate / frameSize`, inside a spectral scope.
    public var frequencyResolution: Double? { storedFrameSize.map { storedSampleRate / Double($0) } }
    /// `sampleRate / hopSize`, inside a spectral scope.
    public var featureRate: Double? { storedHopSize.map { storedSampleRate / Double($0) } }
    /// What the bins are, inside a spectral scope.
    public var frequencyAxis: FeedAxis? { storedAxis }
    /// The delay accumulated by all stages upstream of this point, in seconds (REAL-5).
    public var latency: TimeInterval { storedLatency }
    /// False for offline processing and for sources that run as fast as possible.
    public var isRealTime: Bool { storedIsRealTime }
    /// The kind of source. Informational only: a stage MUST NOT change behaviour on it.
    public var sourceKind: SourceKind { storedSourceKind }
    /// Which implementation primitives are bound to. Settable; default `.automatic`.
    public var implementation: Implementation { self[ImplementationKey.self] }
    /// The precision IIR cascades run in. Settable; default `.automatic`.
    public var biquadPrecision: BiquadPrecision { self[BiquadPrecisionKey.self] }
    /// How often bindings receive results, per second. Settable; default 30 (OUT-2).
    public var resultRate: Double { self[ResultRateKey.self] }

    /// True inside a spectral scope: between a framing step and the end of its branch.
    public var isInSpectralScope: Bool { storedFrameSize != nil }

    /// The signal format at this point.
    public var format: SignalFormat { SignalFormat(sampleRate: storedSampleRate, channelCount: storedChannelCount) }

    // MARK: Setting

    /// The environment with a settable key overridden. Derived keys are not settable: passing
    /// one does not compile.
    public func setting<K: SettableDSPEnvironmentKey>(_ key: K.Type, to value: K.Value) -> DSPEnvironment {
        var copy = self
        copy.overrides[ObjectIdentifier(key)] = AnyStrategy(value)
        return copy
    }

    /// The catalogue of settable keys, for the key-path spelling `.environment(\.implementation, .native)`.
    /// An app adds its own keys with an extension: `var gateThreshold: GateThresholdKey.Type { GateThresholdKey.self }`.
    public struct SettableKeys: Sendable {
        @usableFromInline init() {}
        public var implementation: ImplementationKey.Type { ImplementationKey.self }
        public var biquadPrecision: BiquadPrecisionKey.Type { BiquadPrecisionKey.self }
        public var resultRate: ResultRateKey.Type { ResultRateKey.self }
    }

    /// The environment with a settable key overridden, by key path.
    public func setting<K: SettableDSPEnvironmentKey>(_ keyPath: KeyPath<SettableKeys, K.Type>, to value: K.Value) -> DSPEnvironment {
        setting(SettableKeys()[keyPath: keyPath], to: value)
    }

    // MARK: Positional changes (ENV-1). Stages reach these through `LoweringContext`.

    /// The environment at the start of a signal of another format.
    package func withFormat(_ format: SignalFormat) -> DSPEnvironment {
        var copy = self
        copy.storedSampleRate = format.sampleRate
        copy.storedChannelCount = format.channelCount
        return copy
    }

    package func withChannelCount(_ count: Int) -> DSPEnvironment {
        var copy = self
        copy.storedChannelCount = count
        return copy
    }

    package func withBlockSize(_ size: Int) -> DSPEnvironment {
        var copy = self
        copy.storedBlockSize = size
        return copy
    }

    package func withSource(kind: SourceKind, isRealTime: Bool) -> DSPEnvironment {
        var copy = self
        copy.storedSourceKind = kind
        copy.storedIsRealTime = isRealTime
        return copy
    }

    /// Downstream of a stage that multiplies the rate by `interpolation / decimation`.
    package func changingRate(interpolation: Int, decimation: Int) -> DSPEnvironment {
        var copy = self
        copy.storedSampleRate = storedSampleRate * Double(interpolation) / Double(decimation)
        return copy
    }

    /// Downstream of a framing step.
    package func enteringSpectralScope(frameSize: Int, hopSize: Int, axis: FeedAxis) -> DSPEnvironment {
        var copy = self
        copy.storedFrameSize = frameSize
        copy.storedHopSize = hopSize
        copy.storedAxis = axis
        copy.storedChannelCount = 1
        return copy
    }

    /// Downstream of a step that changes what the bins are.
    package func replacingAxis(_ axis: FeedAxis) -> DSPEnvironment {
        var copy = self
        copy.storedAxis = axis
        return copy
    }

    /// Downstream of a step that returns to samples: the spectral keys are `nil` again.
    package func leavingSpectralScope(channelCount: Int = 1) -> DSPEnvironment {
        var copy = self
        copy.storedFrameSize = nil
        copy.storedHopSize = nil
        copy.storedAxis = nil
        copy.storedChannelCount = channelCount
        return copy
    }

    /// Downstream of a step that produces a novelty curve or a scalar: a new sampled sequence
    /// whose rate is the feature rate, outside any spectral scope (§5.2).
    package func beginningFeatureSequence(rate: Double) -> DSPEnvironment {
        var copy = self
        copy.storedSampleRate = rate
        copy.storedFrameSize = nil
        copy.storedHopSize = nil
        copy.storedAxis = nil
        copy.storedChannelCount = 1
        return copy
    }

    package func addingLatency(_ seconds: TimeInterval) -> DSPEnvironment {
        var copy = self
        copy.storedLatency = storedLatency + seconds
        return copy
    }

    /// The environment with the overrides of `outer`: what remains of a scope's overrides
    /// once the scope ends.
    package func restoringOverrides(of outer: DSPEnvironment) -> DSPEnvironment {
        var copy = self
        copy.overrides = outer.overrides
        return copy
    }

    /// The overrides of this environment laid over `base`: what a scope's `.environment`
    /// modifiers contribute to the environment that reaches it.
    package func applyingOverrides(of scope: [ObjectIdentifier: AnyStrategy]) -> DSPEnvironment {
        guard !scope.isEmpty else { return self }
        var copy = self
        for (key, value) in scope { copy.overrides[key] = value }
        return copy
    }
}

// MARK: Built-in keys

/// Samples per second of the sequence at this point. Derived.
public enum SampleRateKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Double { 48_000 }
    static func read(_ environment: DSPEnvironment) -> Double { environment.sampleRate }
}

/// Half the sample rate. Derived.
public enum NyquistFrequencyKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Double { 24_000 }
    static func read(_ environment: DSPEnvironment) -> Double { environment.nyquistFrequency }
}

/// Channels in the signal. Derived.
public enum ChannelCountKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Int { 1 }
    static func read(_ environment: DSPEnvironment) -> Int { environment.channelCount }
}

/// Frames per processing block. Derived.
public enum BlockSizeKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Int { 512 }
    static func read(_ environment: DSPEnvironment) -> Int { environment.blockSize }
}

/// The frame size inside a spectral scope. Derived.
public enum FrameSizeKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Int? { nil }
    static func read(_ environment: DSPEnvironment) -> Int? { environment.frameSize }
}

/// The hop inside a spectral scope. Derived.
public enum HopSizeKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Int? { nil }
    static func read(_ environment: DSPEnvironment) -> Int? { environment.hopSize }
}

/// `sampleRate / frameSize` inside a spectral scope. Derived.
public enum FrequencyResolutionKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Double? { nil }
    static func read(_ environment: DSPEnvironment) -> Double? { environment.frequencyResolution }
}

/// `sampleRate / hopSize` inside a spectral scope. Derived.
public enum FeatureRateKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Double? { nil }
    static func read(_ environment: DSPEnvironment) -> Double? { environment.featureRate }
}

/// What the bins are inside a spectral scope. Derived.
public enum FrequencyAxisKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: FeedAxis? { nil }
    static func read(_ environment: DSPEnvironment) -> FeedAxis? { environment.frequencyAxis }
}

/// The delay accumulated upstream, in seconds. Derived.
public enum LatencyKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: TimeInterval { 0 }
    static func read(_ environment: DSPEnvironment) -> TimeInterval { environment.latency }
}

/// Whether the signal arrives in real time. Derived.
public enum IsRealTimeKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: Bool { false }
    static func read(_ environment: DSPEnvironment) -> Bool { environment.isRealTime }
}

/// The kind of source. Derived; informational only.
public enum SourceKindKey: BuiltInDSPEnvironmentKey {
    public static var defaultValue: SourceKind { .offline }
    static func read(_ environment: DSPEnvironment) -> SourceKind { environment.sourceKind }
}

/// Which implementation primitives are bound to (§7.4). Settable.
public enum ImplementationKey: SettableDSPEnvironmentKey {
    public static var defaultValue: Implementation { .automatic }
}

/// The precision IIR cascades run in (REAL-3). Settable.
public enum BiquadPrecisionKey: SettableDSPEnvironmentKey {
    public static var defaultValue: BiquadPrecision { .automatic }
}

/// How often bindings receive results, per second (OUT-2). Settable.
public enum ResultRateKey: SettableDSPEnvironmentKey {
    public static var defaultValue: Double { 30 }
}
