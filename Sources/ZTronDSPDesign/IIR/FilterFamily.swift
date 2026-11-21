import ZTronDSPCore

/// A family of IIR filters: what decides the shape of the response once the edges and the
/// order are fixed (§5.3, §6.3.2). A strategy: pass `.butterworth`, `.chebyshev1(ripple:)`,
/// `.chebyshev2(stopband:)`, `.elliptic(ripple:stopband:)` or `.bessel(normalization:)`, or a
/// conformer of your own, wherever a family is asked for:
///
/// ```swift
/// try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate:
/// 48_000))
/// ```
///
/// A family supplies one thing: its analog low-pass prototype. The frequency transformation,
/// the bilinear transform and the section pairing are the same for every family, so a
/// family written outside the package gets them unchanged.
///
/// Conformers are immutable values, usable on any thread. Designing allocates: control or
/// background context.
public protocol FilterFamily: Hashable, Sendable {
    /// The analog low-pass prototype of the given order: a system in the `s` plane, with at
    /// least as many poles as zeros, whose edge sits at 1 rad/s.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an order or a parameter the family cannot
    ///   design for; `DSPError.unsupportedConfiguration` beyond what it implements.
    func prototype(order: Int) throws(DSPError) -> ZeroPoleGain

    /// The strategy that turns a tolerance scheme into an order and a natural frequency, or
    /// `nil` for a family that has none (Bessel, as in etk4j).
    /// Usable on any thread.
    var orderStrategy: (any FilterOrderStrategy)? { get }

    /// The member of the family that a tolerance scheme selects: its pass-band ripple is the
    /// scheme's maximum loss and its stop-band attenuation the scheme's minimum attenuation,
    /// as in etk4j and SciPy. A family without those parameters returns itself.
    /// Usable on any thread.
    func fitted(maximumLoss: Amplification, minimumAttenuation: Amplification) -> Self
}

extension FilterFamily {
    /// The family's order estimate; `nil` when it has none. Usable on any thread.
    public var orderStrategy: (any FilterOrderStrategy)? { nil }

    /// The member of the family that a tolerance scheme selects. Usable on any thread. It does not
    /// allocate.
    public func fitted(maximumLoss: Amplification, minimumAttenuation: Amplification) -> Self { self }
}

/// Butterworth: maximally flat magnitude, monotonic in both bands, no parameter but the
/// order. An all-pole family: a roll-off is the exact asymptotic slope of its skirt
/// (§6.3.4). An immutable value, usable on any thread; creating one does not allocate, and
/// designing with it allocates.
public struct ButterworthFamily: FilterFamily {
    /// Usable on any thread.
    public init() {}

    /// The family's analog low-pass prototype, with its edge at 1 rad/s. Control or background
    /// context; allocates.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        try AnalogPrototype.butterworth(order: order)
    }

    /// The family's order estimate; `nil` when it has none. Usable on any thread.
    public var orderStrategy: (any FilterOrderStrategy)? { ButterworthOrderStrategy() }
}

/// Chebyshev type I: an equiripple pass band, a monotonic stop band. An all-pole family: a
/// roll-off is the exact asymptotic slope of its skirt (§6.3.4). An immutable value, usable
/// on any thread; creating one does not allocate, and designing with it allocates.
public struct Chebyshev1Family: FilterFamily {
    /// The peak-to-peak ripple of the pass band, as a number of decibels. Usable on any
    /// thread.
    public let ripple: Amplification

    /// Usable on any thread.
    public init(ripple: Amplification) {
        self.ripple = ripple
    }

    /// The family's analog low-pass prototype, with its edge at 1 rad/s. Control or background
    /// context; allocates.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        try AnalogPrototype.chebyshev1(order: order, ripple: ripple)
    }

    /// The family's order estimate; `nil` when it has none. Usable on any thread.
    public var orderStrategy: (any FilterOrderStrategy)? { Chebyshev1OrderStrategy() }

    /// The member of the family that a tolerance scheme selects. Usable on any thread.
    public func fitted(maximumLoss: Amplification, minimumAttenuation: Amplification) -> Chebyshev1Family {
        Chebyshev1Family(ripple: maximumLoss)
    }
}

/// Chebyshev type II (inverse Chebyshev): a monotonic pass band, an equiripple stop band
/// with finite zeros.
///
/// **A roll-off is nominal for this family** (§6.3.4): it selects the order whose all-pole
/// counterpart has that slope. The real transition is steeper, and the stop band is bounded
/// by `stopband`, not by a slope: it does not keep falling. An immutable value, usable on
/// any thread; creating one does not allocate, and designing with it allocates.
public struct Chebyshev2Family: FilterFamily {
    /// The least attenuation of the stop band, as a number of decibels. Usable on any
    /// thread.
    public let stopband: Amplification

    /// Usable on any thread.
    public init(stopband: Amplification) {
        self.stopband = stopband
    }

    /// The family's analog low-pass prototype, with its edge at 1 rad/s. Control or background
    /// context; allocates.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        try AnalogPrototype.chebyshev2(order: order, stopband: stopband)
    }

    /// The family's order estimate; `nil` when it has none. Usable on any thread.
    public var orderStrategy: (any FilterOrderStrategy)? { Chebyshev2OrderStrategy() }

    /// The member of the family that a tolerance scheme selects. Usable on any thread.
    public func fitted(maximumLoss: Amplification, minimumAttenuation: Amplification) -> Chebyshev2Family {
        Chebyshev2Family(stopband: minimumAttenuation)
    }
}

/// Elliptic (Cauer): equiripple in both bands; the narrowest transition for a given order.
///
/// **A roll-off is nominal for this family** (§6.3.4): it selects the order whose all-pole
/// counterpart has that slope. The real transition is steeper, and the stop band is bounded
/// by `stopband`, not by a slope: it does not keep falling. An immutable value, usable on
/// any thread; creating one does not allocate, and designing with it allocates.
public struct EllipticFamily: FilterFamily {
    /// The peak-to-peak ripple of the pass band, as a number of decibels. Usable on any
    /// thread.
    public let ripple: Amplification
    /// The least attenuation of the stop band, as a number of decibels. Usable on any
    /// thread.
    public let stopband: Amplification

    /// Usable on any thread.
    public init(ripple: Amplification, stopband: Amplification) {
        self.ripple = ripple
        self.stopband = stopband
    }

    /// The family's analog low-pass prototype, with its edge at 1 rad/s. Control or background
    /// context; allocates.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        try AnalogPrototype.elliptic(order: order, ripple: ripple, stopband: stopband)
    }

    /// The family's order estimate; `nil` when it has none. Usable on any thread.
    public var orderStrategy: (any FilterOrderStrategy)? { EllipticOrderStrategy() }

    /// The member of the family that a tolerance scheme selects. Usable on any thread.
    public func fitted(maximumLoss: Amplification, minimumAttenuation: Amplification) -> EllipticFamily {
        EllipticFamily(ripple: maximumLoss, stopband: minimumAttenuation)
    }
}

/// Bessel (Thomson): maximally flat group delay. An all-pole family: a roll-off is the exact
/// asymptotic slope of its skirt (§6.3.4). It has no order estimation, as in etk4j: a
/// tolerance scheme is rejected. An immutable value, usable on any thread; creating one does
/// not allocate, and designing with it allocates.
public struct BesselFamily: FilterFamily {
    /// How the prototype is scaled in frequency. Usable on any thread.
    public let normalization: BesselNormalization

    /// Usable on any thread.
    public init(normalization: BesselNormalization = .phase) {
        self.normalization = normalization
    }

    /// The family's analog low-pass prototype, with its edge at 1 rad/s. Control or background
    /// context; allocates.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        try AnalogPrototype.bessel(order: order, normalization: normalization)
    }
}

extension FilterFamily where Self == ButterworthFamily {
    /// Maximally flat magnitude. Usable on any thread.
    public static var butterworth: ButterworthFamily { ButterworthFamily() }
}

extension FilterFamily where Self == Chebyshev1Family {
    /// An equiripple pass band of `ripple` decibels. Usable on any thread. It does not allocate.
    public static func chebyshev1(ripple: Amplification) -> Chebyshev1Family { Chebyshev1Family(ripple: ripple) }
}

extension FilterFamily where Self == Chebyshev2Family {
    /// An equiripple stop band at least `stopband` decibels down. Usable on any thread. It does not
    /// allocate.
    public static func chebyshev2(stopband: Amplification) -> Chebyshev2Family { Chebyshev2Family(stopband: stopband) }
}

extension FilterFamily where Self == EllipticFamily {
    /// Equiripple in both bands: `ripple` decibels in the pass band, at least `stopband` decibels
    /// down in the stop band. Usable on any thread. It does not allocate.
    public static func elliptic(ripple: Amplification, stopband: Amplification) -> EllipticFamily {
        EllipticFamily(ripple: ripple, stopband: stopband)
    }
}

extension FilterFamily where Self == BesselFamily {
    /// Maximally flat group delay, in the given normalisation. Usable on any thread. It does not
    /// allocate.
    public static func bessel(normalization: BesselNormalization = .phase) -> BesselFamily {
        BesselFamily(normalization: normalization)
    }
}
