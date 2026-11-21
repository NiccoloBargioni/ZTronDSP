import Accelerate
import Foundation

/// The unit of a gain, a ripple or an attenuation: a linear amplitude factor or a number of
/// decibels (§6.1). Amplitude decibels are 20·log₁₀; conversions to decibels clamp at a floor
/// instead of returning −∞.
///
/// An immutable value, usable on any thread. It does not allocate; only ``description``
/// allocates, for the string it returns.
public struct Amplification: Hashable, Sendable, CustomStringConvertible {
    @usableFromInline
    enum Unit: Hashable, Sendable {
        case linear
        case decibels
    }

    @usableFromInline let unit: Unit
    /// The number as it was stated.
    public let value: Double

    @usableFromInline
    init(unit: Unit, value: Double) {
        self.unit = unit
        self.value = value
    }

    /// An amplitude factor: 1 leaves a signal unchanged, 0.5 halves it, a negative factor
    /// also inverts it.
    public static func linear(_ factor: Double) -> Amplification { Amplification(unit: .linear, value: factor) }

    /// Amplitude decibels: 0 dB leaves a signal unchanged, −6.02 dB halves it.
    public static func decibels(_ value: Double) -> Amplification { Amplification(unit: .decibels, value: value) }

    /// No change.
    public static let unity = Amplification.linear(1)

    /// The amplitude factor.
    public var linear: Double {
        switch unit {
        case .linear: value
        case .decibels: DSP.amplitude(fromDecibels: value)
        }
    }

    /// Amplitude decibels, clamped at the default floor of −160 dB.
    public var decibels: Double { decibels(floor: DSP.decibelFloor) }

    /// Amplitude decibels, clamped at `floor`.
    public func decibels(floor: Double) -> Double {
        switch unit {
        case .linear: DSP.decibels(fromAmplitude: value, floor: floor)
        case .decibels: max(value, floor)
        }
    }

    /// The factor applied to a power: the square of the amplitude factor.
    public var powerRatio: Double {
        let factor = linear
        return factor * factor
    }

    /// True when the amplification leaves a signal exactly unchanged.
    public var isUnity: Bool { linear == 1 }

    /// The value a parameter vector carries for this amplification: decibels (ANI-2).
    public var animatableValue: Double { decibels }

    /// The amplification in the same unit whose ``animatableValue`` is `animatableValue`.
    /// Passing this amplification's own value returns it unchanged, bit for bit.
    public func replacing(animatableValue: Double) -> Amplification {
        guard animatableValue != self.animatableValue else { return self }
        switch unit {
        case .linear:
            let magnitude = DSP.amplitude(fromDecibels: animatableValue)
            return .linear(value < 0 ? -magnitude : magnitude)
        case .decibels:
            return .decibels(animatableValue)
        }
    }

    /// The amount as it was stated: `×0.5` or `-6.0 dB`.
    public var description: String {
        switch unit {
        case .linear: "×\(value)"
        case .decibels: "\(value) dB"
        }
    }
}

extension DSP {
    /// The floor of every conversion to decibels unless another is given: −160 dB. A constant, read
    /// on any thread; it does not allocate.
    public static let decibelFloor: Double = -160

    // MARK: Scalars

    /// `20·log₁₀(|amplitude| / reference)`, clamped at `floor`. Zero, and a reference that is not
    /// positive, give the floor; no NaN and no infinity is returned (NUM-1). Usable on any thread,
    /// the analysis thread included; it does not allocate.
    public static func decibels(fromAmplitude amplitude: Double, reference: Double = 1, floor: Double = decibelFloor) -> Double {
        let magnitude = abs(amplitude)
        guard reference > 0, magnitude > 0, magnitude.isFinite else { return magnitude == .infinity && reference > 0 ? .greatestFiniteMagnitude : floor }
        return max(20 * log10(magnitude / reference), floor)
    }

    /// `10·log₁₀(power / reference)`, clamped at `floor`. Zero, a negative power, and a reference
    /// that is not positive, give the floor. Usable on any thread, the analysis thread included; it
    /// does not allocate.
    public static func decibels(fromPower power: Double, reference: Double = 1, floor: Double = decibelFloor) -> Double {
        guard reference > 0, power > 0, power.isFinite else { return power == .infinity && reference > 0 ? .greatestFiniteMagnitude : floor }
        return max(10 * log10(power / reference), floor)
    }

    /// `reference · 10^(decibels / 20)`. Usable on any thread, the analysis thread included; it
    /// does not allocate.
    public static func amplitude(fromDecibels decibels: Double, reference: Double = 1) -> Double {
        reference * pow(10, decibels / 20)
    }

    /// `reference · 10^(decibels / 10)`. Usable on any thread, the analysis thread included; it
    /// does not allocate.
    public static func power(fromDecibels decibels: Double, reference: Double = 1) -> Double {
        reference * pow(10, decibels / 10)
    }

    // MARK: Vectors

    /// Amplitudes to decibels, in place or into another buffer (`vDSP_vdbcon`). Magnitudes are
    /// taken first and clamped at the floor, so zeros, negative values and NaN all come out as
    /// the floor. Allocation-free; callable on the analysis thread.
    public static func decibels(
        fromAmplitude amplitude: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int,
        reference: Float = 1, floor: Float = Float(decibelFloor)
    ) {
        guard count > 0 else { return }
        let length = vDSP_Length(count)
        vDSP_vabs(amplitude, 1, result, 1, length)
        convertClamped(result, length, reference: reference, floor: floor, divisor: 20, flag: 1)
    }

    /// Powers to decibels, in place or into another buffer (`vDSP_vdbcon`). Zeros, negative
    /// values and NaN come out as the floor. Allocation-free; callable on the analysis thread.
    public static func decibels(
        fromPower power: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int,
        reference: Float = 1, floor: Float = Float(decibelFloor)
    ) {
        guard count > 0 else { return }
        let length = vDSP_Length(count)
        if power != UnsafePointer(result) { result.update(from: power, count: count) }
        convertClamped(result, length, reference: reference, floor: floor, divisor: 10, flag: 0)
    }

    private static func convertClamped(
        _ values: UnsafeMutablePointer<Float>, _ length: vDSP_Length, reference: Float, floor: Float, divisor: Float, flag: UInt32
    ) {
        guard reference > 0 else {
            var fill = floor
            vDSP_vfill(&fill, values, 1, length)
            return
        }
        // Clamp in the linear domain first, so the logarithm never sees zero. `vDSP_vthres`
        // is the one vDSP threshold that compares (it writes 0 for a NaN, where `vDSP_vclip`,
        // `vDSP_vthr` and `vDSP_vmax` pass a NaN through), so it goes first.
        var low = reference * powf(10, floor / divisor)
        if low < .leastNormalMagnitude { low = .leastNormalMagnitude }
        var high = Float.greatestFiniteMagnitude
        vDSP_vthres(values, 1, &low, values, 1, length)
        vDSP_vclip(values, 1, &low, &high, values, 1, length)
        var zeroReference = reference
        vDSP_vdbcon(values, 1, &zeroReference, values, 1, length, flag)
        var lowest = floor
        var highest = Float.greatestFiniteMagnitude
        vDSP_vclip(values, 1, &lowest, &highest, values, 1, length)
    }

    /// Decibels to amplitudes: `reference · 10^(dB / 20)`. Allocation-free. Usable on any thread,
    /// the analysis thread included.
    public static func amplitude(
        fromDecibels decibels: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int, reference: Float = 1
    ) {
        exponentiate(decibels, result, count, divisor: 20, reference: reference)
    }

    /// Decibels to powers: `reference · 10^(dB / 10)`. Allocation-free. Usable on any thread, the
    /// analysis thread included.
    public static func power(
        fromDecibels decibels: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int, reference: Float = 1
    ) {
        exponentiate(decibels, result, count, divisor: 10, reference: reference)
    }

    private static func exponentiate(
        _ decibels: UnsafePointer<Float>, _ result: UnsafeMutablePointer<Float>, _ count: Int, divisor: Float, reference: Float
    ) {
        guard count > 0 else { return }
        let length = vDSP_Length(count)
        // 10^(x / d) = e^(x · ln 10 / d): vForce has the natural exponential.
        var scale = Float(M_LN10) / divisor
        vDSP_vsmul(decibels, 1, &scale, result, 1, length)
        var size = Int32(count)
        vvexpf(result, result, &size)
        if reference != 1 {
            var factor = reference
            vDSP_vsmul(result, 1, &factor, result, 1, length)
        }
    }

    /// Amplitudes to decibels, as a new array. Usable on any thread; allocates the array it
    /// returns.
    public static func decibels(fromAmplitude amplitude: [Float], reference: Float = 1, floor: Float = Float(decibelFloor)) -> [Float] {
        var result = [Float](repeating: 0, count: amplitude.count)
        amplitude.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let into = target.baseAddress else { return }
                decibels(fromAmplitude: from, into: into, count: source.count, reference: reference, floor: floor)
            }
        }
        return result
    }

    /// Powers to decibels, as a new array. Usable on any thread; allocates the array it returns.
    public static func decibels(fromPower power: [Float], reference: Float = 1, floor: Float = Float(decibelFloor)) -> [Float] {
        var result = [Float](repeating: 0, count: power.count)
        power.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let into = target.baseAddress else { return }
                decibels(fromPower: from, into: into, count: source.count, reference: reference, floor: floor)
            }
        }
        return result
    }

    /// Decibels to amplitudes, as a new array. Usable on any thread; allocates the array it
    /// returns.
    public static func amplitude(fromDecibels decibels: [Float], reference: Float = 1) -> [Float] {
        var result = [Float](repeating: 0, count: decibels.count)
        decibels.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let into = target.baseAddress else { return }
                amplitude(fromDecibels: from, into: into, count: source.count, reference: reference)
            }
        }
        return result
    }

    /// Decibels to powers, as a new array. Usable on any thread; allocates the array it returns.
    public static func power(fromDecibels decibels: [Float], reference: Float = 1) -> [Float] {
        var result = [Float](repeating: 0, count: decibels.count)
        decibels.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let into = target.baseAddress else { return }
                power(fromDecibels: from, into: into, count: source.count, reference: reference)
            }
        }
        return result
    }
}
