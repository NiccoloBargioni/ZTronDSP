import ZTronDSPCore

/// The width of an equaliser band (§6.3.5), measured between the two frequencies at which
/// the gain is half the band's gain in decibels.
///
/// An immutable value, usable on any thread.
public enum Bandwidth: Hashable, Sendable {
    /// A width in hertz. Met exactly on the digital frequency axis: the design pre-warps it.
    case hertz(Double)
    /// A width in octaves around the centre `f₀`, converted to
    /// `f₀·(2^(b/2) − 2^(−b/2))` hertz and then met exactly.
    case octaves(Double)
    /// The quality factor of the Audio EQ Cookbook: `α = sin ω₀ / 2Q`. The width in hertz
    /// follows from it and narrows towards the Nyquist frequency.
    case q(Double)
}

/// The steepness of a shelving filter (§6.3.5), in either of the Audio EQ Cookbook's forms.
///
/// An immutable value, usable on any thread.
public enum ShelfSlope: Hashable, Sendable {
    /// The Cookbook's shelf slope `S`. At 1 the shelf is as steep as it can be while the
    /// gain stays monotonic; smaller values are gentler.
    case slope(Double)
    /// The quality factor `Q`. `1/√2` is the same shelf as a slope of 1.
    case q(Double)
}
