import Foundation

/// The stress-fixture library behind the numerical-stability tests (NUMS-2, WP-016). Every
/// fixture states the hazard it carries, and where one exists the condition number, so a
/// stability note can cite it and a stress test can fail when a mitigation is removed.
///
/// Constants and plain functions, usable on any thread: a constant is built on its first read,
/// which allocates, and each function allocates the samples it returns.
public enum StressFixture {
    // MARK: Polynomials

    /// A polynomial with known roots, given by the coefficients a root finder would receive.
    ///
    /// An immutable value, usable on any thread; it does not allocate.
    public struct PolynomialCase: Sendable {
        /// The case's name, as a test reports it.
        public let name: String
        /// Coefficients, highest power first, rounded to double precision from the exact
        /// expansion of the roots. The rounding is part of the hazard.
        public let coefficients: [Double]
        /// The real parts of the roots, each root as often as its multiplicity.
        public let rootsReal: [Double]
        /// The imaginary parts, root for root with `rootsReal`.
        public let rootsImaginary: [Double]
        /// The largest finite condition number of a root with respect to the coefficients,
        /// κ(r) = Σ |aₖ|·|r|ᵏ / (|r|·|p′(r)|) (specification §6.3.8). Multiple roots have an
        /// infinite condition number and are left out of the maximum.
        public let largestConditionNumber: Double
        /// The highest multiplicity among the roots.
        public let multiplicity: Int
        /// The accuracy a root finder working from these coefficients can be held to.
        public let achievableAccuracy: Double
        /// What makes the case hard, in words a stability note can cite.
        public let hazard: String

        /// The degree: one less than the number of coefficients.
        public var degree: Int { coefficients.count - 1 }
    }

    /// Wilkinson's polynomial of degree 20.
    public static let wilkinson20 = StressFixtureData.wilkinson20
    /// The expanded denominator of an order-16 Butterworth low-pass at 1 kHz / 48 kHz.
    public static let butterworth16Expanded = StressFixtureData.butterworth16Expanded
    /// (x − ½)³·(x + ¼).
    public static let tripleRoot = StressFixtureData.tripleRoot
    /// Polynomials whose roots all have a condition number at or below 10⁴.
    public static let wellConditionedPolynomials: [PolynomialCase] = [
        StressFixtureData.wellQuadratic, StressFixtureData.wellCubic, StressFixtureData.wellQuintic,
        StressFixtureData.wellOctic, StressFixtureData.wellSpread,
    ]
    /// The three ill-conditioned polynomials, in the order above.
    public static let illConditionedPolynomials: [PolynomialCase] = [wilkinson20, butterworth16Expanded, tripleRoot]

    // MARK: Filters at the edges of the band

    /// A filter whose poles crowd z = 1 (cutoff near 0 Hz) or whose edge sits just below Nyquist.
    ///
    /// An immutable value, usable on any thread; it does not allocate.
    public struct FilterCase: Sendable {
        /// Which side of the cutoff passes: a value, usable on any thread; it does not allocate.
        public enum Response: Sendable {
            /// The band below the cutoff passes.
            case lowPass
            /// The band above the cutoff passes.
            case highPass
        }
        /// The case's name: response, cutoff, sample rate and order.
        public let name: String
        /// Low-pass or high-pass.
        public let response: Response
        /// The sample rate, in hertz.
        public let sampleRate: Double
        /// The cutoff, in hertz.
        public let cutoff: Double
        /// The order of the filter.
        public let order: Int
        /// What makes the case hard, in words a stability note can cite.
        public let hazard: String

        /// The distance of a Butterworth pole pair from z = 1 at this cutoff, about
        /// 2π·cutoff / sampleRate: what single precision has to resolve.
        public var normalizedAngle: Double { 2 * .pi * cutoff / sampleRate }
    }

    /// Cutoffs close to 0 Hz, where single-precision cascades lose accuracy (§7.5, row 3).
    public static let filtersNearZero: [FilterCase] = [
        FilterCase(name: "hp-90Hz-48k-order8", response: .highPass, sampleRate: 48_000, cutoff: 90, order: 8,
                   hazard: "E-30: about 4e-5 against a double-precision reference in Float32."),
        FilterCase(name: "hp-20Hz-96k-order8", response: .highPass, sampleRate: 96_000, cutoff: 20, order: 8,
                   hazard: "Poles within 1.3e-3 of z = 1: the acceptance fixture of the double-precision kernel (WP-211)."),
        FilterCase(name: "lp-10Hz-192k-order8", response: .lowPass, sampleRate: 192_000, cutoff: 10, order: 8,
                   hazard: "Poles within 3.3e-4 of z = 1: the lowest corner of the precision grid (WP-433)."),
        FilterCase(name: "hp-10Hz-44k1-order2", response: .highPass, sampleRate: 44_100, cutoff: 10, order: 2,
                   hazard: "A DC blocker: one pole pair within 1.4e-3 of z = 1."),
    ]

    /// Cutoffs close to Nyquist, where the bilinear transform's warping is strongest.
    public static let filtersNearNyquist: [FilterCase] = [
        FilterCase(name: "lp-0.45fs-48k-order8", response: .lowPass, sampleRate: 48_000, cutoff: 21_600, order: 8,
                   hazard: "Pre-warped edge at tan(0.45π) ≈ 6.3: the upper corner of the precision grid."),
        FilterCase(name: "hp-0.45fs-44k1-order4", response: .highPass, sampleRate: 44_100, cutoff: 19_845, order: 4,
                   hazard: "A pass band of one twentieth of the spectrum."),
        FilterCase(name: "lp-0.49fs-48k-order2", response: .lowPass, sampleRate: 48_000, cutoff: 23_520, order: 2,
                   hazard: "The edge of what a filter stage accepts (ENV-2 rejects 0.5·fs and above)."),
    ]

    // MARK: Signals

    /// A signal that probes one numerical or real-time hazard.
    ///
    /// An immutable value, usable on any thread; it does not allocate: it keeps the samples it is
    /// given.
    public struct SignalCase: Sendable {
        /// The fixture's name, as a test reports it.
        public let name: String
        /// The signal.
        public let samples: [Float]
        /// What the signal probes, in words a stability note can cite.
        public let hazard: String
    }

    /// The signal fixtures at a given length. Deterministic.
    public static func signals(count: Int, sampleRate: Double = 48_000) -> [SignalCase] {
        [
            SignalCase(name: "silence", samples: TestSignal.silence(count: count),
                       hazard: "0/0 in every normalised quantity; logarithms of zero (NUM-1)."),
            SignalCase(name: "full-scale-sine", samples: TestSignal.sine(frequency: 997, sampleRate: sampleRate, count: count),
                       hazard: "Peak at exactly ±1: headroom and clipping paths."),
            SignalCase(name: "full-scale-square", samples: (0 ..< count).map { ($0 / 24) % 2 == 0 ? 1 : -1 },
                       hazard: "The largest step a signal can take, at every edge."),
            SignalCase(name: "dc", samples: TestSignal.constant(1, count: count),
                       hazard: "All energy in bin 0; high-pass filters must settle to exactly zero."),
            SignalCase(name: "nyquist", samples: TestSignal.nyquist(count: count),
                       hazard: "All energy in the last bin; low-pass filters and decimators."),
            SignalCase(name: "decaying-tail", samples: TestSignal.decayingTail(count: count, ratio: 0.5),
                       hazard: "Reaches the denormal range after about 126 samples and zero after 150: state hygiene (RT-6)."),
            SignalCase(name: "denormal", samples: TestSignal.constant(.leastNonzeroMagnitude * 64, count: count),
                       hazard: "Subnormal input from the first sample."),
            SignalCase(name: "impulse", samples: TestSignal.impulse(count: count),
                       hazard: "A flat spectrum; a filter's whole response in one pass."),
            SignalCase(name: "white-noise", samples: TestSignal.whiteNoise(count: count, seed: 0x5EED),
                       hazard: "Broadband, seeded: the reference input for single-versus-double deviation."),
        ]
    }

    /// Samples carrying NaN and both infinities at known positions, for the guard at the source
    /// adapter (NUM-1). Returns the samples and the number of non-finite values in them.
    public static func nonFiniteSignal(count: Int) -> (samples: [Float], nonFiniteCount: Int) {
        var samples = TestSignal.whiteNoise(count: count, seed: 0xBAD, amplitude: 0.5)
        var injected = 0
        for (position, value) in [(count / 7, Float.nan), (count / 3, Float.infinity), (count / 2, -Float.infinity)]
        where position < count {
            if samples[position].isFinite { injected += 1 }
            samples[position] = value
        }
        return (samples, injected)
    }
}
