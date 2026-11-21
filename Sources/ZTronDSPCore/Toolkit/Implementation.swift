import Foundation

/// Which implementation of a primitive to use (§7.4, SEL-2). A settable environment key.
///
/// `.automatic` follows the crossover table. A forced choice applies to the primitives that
/// have that implementation; the rest stay automatic.
///
/// A value, usable on any thread; it does not allocate.
public enum Implementation: String, Hashable, Sendable, Codable, CaseIterable {
    /// Decide by size, from the measured crossovers. The default.
    case automatic
    /// Plain Swift or C loops.
    case native
    /// Accelerate: vDSP, vForce, BLAS, LAPACK.
    case accelerate
    /// Metal, where a GPU implementation exists.
    case metal
}

/// The precision an IIR cascade runs in (REAL-3). A settable environment key.
/// A value, usable on any thread; it does not allocate.
public enum BiquadPrecision: String, Hashable, Sendable, Codable, CaseIterable {
    /// Float32 state and coefficients, on `vDSP_biquad`.
    case single
    /// Double-precision state and coefficients, on the package's own kernel.
    case double
    /// Decide by measurement when the plan is compiled. The default.
    case automatic
}

/// The primitives that exist in more than one implementation (§7.4).
/// A value, usable on any thread; it does not allocate.
public enum Primitive: String, Hashable, Sendable, Codable, CaseIterable {
    /// Scale, add, subtract, multiply, clip. Decided by the vector's length.
    case elementwise
    /// Sum, dot product, mean square, minimum, maximum. Decided by the vector's length.
    case reduction
    /// Minimum and maximum of two lanes, element by element. Decided by the lane's length.
    case laneExchange
    /// The gain kernel. Decided by the block size.
    case gainKernel
    /// A single-precision biquad cascade. Decided by the block size.
    case biquadKernel
    /// An FIR: direct below the crossover, partitioned at and above it. Decided by the taps.
    case fir
    /// A mel projection: banded dot products, or a dense product. Decided by bands × bins.
    case melProjection
    /// A median over whole spectrograms: CPU lanes, or the GPU. Decided by the work's size.
    case median
    /// Polynomial roots: closed form, or the companion matrix. Decided by the degree.
    case polynomialRoots
}

/// The measured crossovers between implementations (SEL-5): for each primitive, the size at
/// which the heavier implementation starts to pay. A table is data: an immutable value, and
/// `Codable`, so an app can keep one measured on its own device and pass it to the engine.
///
/// A wrong crossover costs speed, never correctness (SEL-6).
///
/// Usable on any thread; creating or reading a table does not allocate.
public struct CrossoverTable: Hashable, Sendable, Codable {
    /// Vector length from which element-wise operations use vDSP.
    public let elementwise: Int
    /// Vector length from which reductions use the 8-lane SIMD loop.
    public let reductionSIMD: Int
    /// Vector length from which reductions use vDSP.
    public let reductionAccelerate: Int
    /// Lane length from which the minimum / maximum exchange uses vDSP.
    public let laneExchange: Int
    /// Block size from which the gain kernel uses vDSP.
    public let gainKernel: Int
    /// Block size from which a single-precision biquad cascade uses `vDSP_biquad`.
    public let biquadKernel: Int
    /// Tap count from which an FIR runs as a partitioned convolution (REAL-4).
    public let firPartitioned: Int
    /// The cost model of one-shot convolution: the FFT method is used when
    /// `N·K > convolutionFFTFactor · (N + K)·log₂(N + K)`.
    public let convolutionFFTFactor: Double
    /// Bands × bins from which a mel projection uses a dense product.
    public let melDense: Int
    /// Kernel × bins × frames from which an offline median uses the GPU.
    public let medianGPU: Int
    /// The highest degree whose roots are found in closed form.
    public let polynomialClosedForm: Int

    /// A table with the given crossovers; each one left out has the figure the package ships
    /// (``shipped``).
    public init(
        elementwise: Int = Vector.Crossover.elementwise, reductionSIMD: Int = Vector.Crossover.reductionSIMD,
        reductionAccelerate: Int = Vector.Crossover.reductionAccelerate, laneExchange: Int = 1_024,
        gainKernel: Int = 512, biquadKernel: Int = 4, firPartitioned: Int = 256, convolutionFFTFactor: Double = 4,
        melDense: Int = 1 << 20, medianGPU: Int = 1 << 24, polynomialClosedForm: Int = 2
    ) {
        self.elementwise = elementwise
        self.reductionSIMD = reductionSIMD
        self.reductionAccelerate = reductionAccelerate
        self.laneExchange = laneExchange
        self.gainKernel = gainKernel
        self.biquadKernel = biquadKernel
        self.firPartitioned = firPartitioned
        self.convolutionFFTFactor = convolutionFFTFactor
        self.melDense = melDense
        self.medianGPU = medianGPU
        self.polynomialClosedForm = polynomialClosedForm
    }

    /// The table that ships with the package. Its figures are the initial values of §7.4,
    /// measured on one host (E-26); the calibration packages replace them (WP-611b…d).
    public static let shipped = CrossoverTable()

    /// The implementation a primitive is bound to at a size.
    ///
    /// - Parameters:
    ///   - primitive: which primitive.
    ///   - size: the size that decides for it (see ``Primitive``).
    ///   - requested: `.automatic` follows the table; a forced choice is honoured when the
    ///     primitive has that implementation and ignored otherwise.
    /// - Returns: `.native`, `.accelerate` or `.metal`; never `.automatic`.
    public func implementation(for primitive: Primitive, size: Int, requested: Implementation = .automatic) -> Implementation {
        let automatic: Implementation
        let hasMetal: Bool
        switch primitive {
        case .elementwise:
            automatic = size >= elementwise ? .accelerate : .native; hasMetal = false
        case .reduction:
            automatic = size >= reductionAccelerate ? .accelerate : .native; hasMetal = false
        case .laneExchange:
            automatic = size >= laneExchange ? .accelerate : .native; hasMetal = false
        case .gainKernel:
            automatic = size >= gainKernel ? .accelerate : .native; hasMetal = false
        case .biquadKernel:
            automatic = size >= biquadKernel ? .accelerate : .native; hasMetal = false
        case .fir:
            automatic = size >= firPartitioned ? .accelerate : .native; hasMetal = false
        case .melProjection:
            automatic = size >= melDense ? .accelerate : .native; hasMetal = false
        case .median:
            automatic = size >= medianGPU ? .metal : .native; hasMetal = true
        case .polynomialRoots:
            automatic = size > polynomialClosedForm ? .accelerate : .native; hasMetal = false
        }
        switch requested {
        case .automatic: return automatic
        case .native: return .native
        case .accelerate: return primitive == .median ? automatic == .metal ? .native : automatic : .accelerate
        case .metal: return hasMetal ? .metal : automatic
        }
    }

    /// Whether a reduction of `count` elements uses the 8-lane SIMD loop when it runs natively.
    @inlinable
    public func reductionUsesSIMD(count: Int) -> Bool {
        count >= reductionSIMD
    }

    /// Whether a one-shot convolution of lengths `n` and `k` uses the FFT method.
    public func convolutionUsesFFT(_ n: Int, _ k: Int) -> Bool {
        guard n > 0, k > 0 else { return false }
        let total = Double(n + k)
        return Double(n) * Double(k) > convolutionFFTFactor * total * Foundation.log2(total)
    }
}

