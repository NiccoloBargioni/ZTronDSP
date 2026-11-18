import Foundation
import ZTronDSPCore

/// What the package finds out about a window by examining it numerically (WIN-4, §7.2 row 21).
///
/// ```swift
/// let report = try await Window.kaiser(beta: 8.6).analysis(frame: 2_048, hop: 512)
/// report.equivalentNoiseBandwidth          // in bins
/// report.peakSideLobe                      // in decibels below the main lobe
/// report.isConstantOverlapAdd              // for the hop given
/// ```
///
/// Nothing in a report is an error: a window that is not smooth, not normalised or not
/// overlap-add complete is reported as such and may still be used. (A window with a sample
/// that is not finite, and one that is zero everywhere, are errors, raised when the window is
/// sampled: WIN-3.)
///
/// The answers are numerical (WIN-6): a verdict holds at the grids named with it. The window
/// is evaluated in double precision; grids are never finer than 2⁻¹² of the frame, and
/// smoothness is reported up to the fourth derivative, because finite differences amplify
/// round-off beyond that.
///
/// An immutable value, usable on any thread. It is produced in the background (BG-1).
public struct WindowAnalysis: Hashable, Sendable {
    /// What the window's function does far outside the frame (a window itself is zero there,
    /// whatever its function returns: WIN-2).
    public enum TailLimit: Hashable, Sendable {
        /// It tends to 0: the function is a window in its own right.
        case zero
        /// It tends to another value: the function is truncated by the frame.
        case value(Double)
        /// It grows without bound.
        case unbounded
        /// It has no limit, or it stops returning numbers.
        case undefined
    }

    /// A jump of the window between two neighbouring samples that does not shrink as the grid
    /// is refined.
    public struct Discontinuity: Hashable, Sendable {
        /// Where, as a fraction of the frame: 0 is its start, 1 its end.
        public let position: Double
        /// The size of the jump.
        public let size: Double
    }

    // MARK: What was analysed

    /// The window, as it describes itself.
    public let window: String
    /// Samples analysed: the frame, or its first half for a half window.
    public let frame: Int
    /// The hop the overlap-add questions were asked for, when one was given.
    public let hop: Int?
    /// The window as sampled, in double precision.
    public let samples: [Double]

    // MARK: Shape

    /// True when the window is its own mirror image about the middle of the frame.
    public let isSymmetric: Bool
    /// True when no sample is negative.
    public let isNonNegative: Bool
    /// True when every sample is finite: always, for a window that could be sampled (WIN-3).
    public let isFinite: Bool

    // MARK: Normalisation

    /// The largest magnitude of a sample.
    public let peak: Double
    /// The mean of the samples: what a sine at a bin centre is scaled by.
    public let coherentGain: Double
    /// The mean of the squared samples: what the power of noise is scaled by.
    public let noiseGain: Double
    /// `noiseGain / coherentGain²`, in bins: the width of the rectangle that passes as much
    /// noise as the window does. `nil` for a window whose samples sum to zero.
    public let equivalentNoiseBandwidth: Double?
    /// The factor `WindowNormalization.amplitude` applies: `2 / Σw`. `nil` for a window whose
    /// samples sum to zero.
    public let amplitudeNormalization: Double?
    /// The factor `WindowNormalization.power` applies for a transform of the frame's length:
    /// `√(2 / (N·Σw²))`.
    public let powerNormalization: Double

    // MARK: Outside the frame

    /// The limit of the window's function far outside the frame, examined at `2ᵏ` frame
    /// lengths on either side, `k = 0 … 20`. `.zero` for a stock window, which is defined on
    /// the frame only. `nil` for a custom window analysed without its function: see
    /// `Window.analysis(frame:hop:tail:)`.
    public let tailLimit: TailLimit?

    // MARK: Continuity and smoothness

    /// The jumps of the window, the frame's edges included, where the outside is 0. Examined
    /// on three grids, each twice as fine as the one before.
    public let discontinuities: [Discontinuity]
    /// The window at the start of the frame.
    public let leadingEdgeValue: Double
    /// The window at the end of the frame: what it tends to there, not its last sample.
    public let trailingEdgeValue: Double
    /// The order of the lowest derivative that jumps, `0 … 4`: 0 means the window itself
    /// jumps; 4 stands for the fourth derivative or any beyond it.
    public let smoothness: Int

    // MARK: Integrability

    /// Whether `∫|w|` over the frame exists: its Riemann sums on the three grids are finite
    /// and converge.
    public let isAbsolutelyIntegrableOnFrame: Bool
    /// Whether `∫w²` over the frame exists.
    public let isSquareIntegrableOnFrame: Bool
    /// Whether `∫|w|` exists over the whole line: over the frame, and the function decays
    /// faster than `1 / |t|` outside it. `nil` when the function is not known there.
    public let isAbsolutelyIntegrableOnLine: Bool?
    /// Whether `∫w²` exists over the whole line. `nil` when the function is not known there.
    public let isSquareIntegrableOnLine: Bool?

    // MARK: Spectrum

    /// The spectrum of the window zero-padded sixteen times, in decibels relative to its value
    /// at 0 Hz, from bin 0 to the Nyquist bin of the frame.
    public let spectrum: [Double]
    /// Bins of the frame's own transform per point of `spectrum`.
    public let spectrumBinStep: Double
    /// The width of the main lobe at −3 dB, in bins.
    public let mainLobeWidthAtHalfPower: Double
    /// The width of the main lobe between its first nulls, in bins. `nil` when the spectrum
    /// has no minimum.
    public let mainLobeWidthNullToNull: Double?
    /// The highest side lobe, in decibels relative to the main lobe: a negative number. `nil`
    /// when the spectrum has no side lobe.
    public let peakSideLobe: Double?
    /// How fast the side lobes fall, measured on their peaks between `N / 32` (and never
    /// below 8) and `N / 4` bins: decibels per octave, a negative number. `nil` when fewer
    /// than three lobes lie there.
    public let sideLobeFallOff: Double?
    /// What a sine half a bin off a bin centre loses against one at the centre, in decibels.
    public let scallopingLoss: Double

    // MARK: Overlap-add

    /// Whether `Σₖ w²(n − k·hop) > 0` for every `n`: the condition under which an
    /// `InverseSTFT` recovers every sample. `nil` without a hop.
    public let isNonZeroOverlapAdd: Bool?
    /// Whether `Σₖ w(n − k·hop)` is the same for every `n`: frames that overlap add up to a
    /// flat response. `nil` without a hop.
    public let isConstantOverlapAdd: Bool?
    /// How far `Σₖ w(n − k·hop)` is from constant: its range over its largest magnitude.
    /// `nil` without a hop.
    public let overlapRipple: Double?
    /// The greatest value of `Σₖ w²(n − k·hop)` over the least: the ratio of the frame bounds,
    /// by which an `InverseSTFT` amplifies an error. 1 for a constant sum; `nil` without a hop
    /// and when the least value is not above zero.
    public let frameBoundRatio: Double?

    /// The side-lobe fall-off the smoothness predicts: `6·(smoothness + 1)` dB per octave.
    public var predictedSideLobeFallOff: Double { -6 * Double(smoothness + 1) }
}

extension Window {
    /// Examines the window on a frame of `frame` samples (WIN-4): its gains, its edges, its
    /// continuity and smoothness, whether it can be integrated, what its spectrum looks like,
    /// and, for a `hop`, whether frames that overlap add up.
    ///
    /// The work runs on the background executor (BG-1): the call may be made from any context,
    /// the main actor included, and can be cancelled (BG-3).
    ///
    /// - Parameter tail: the function behind a custom window, to be followed outside the
    ///   frame. A `Window` does not hand its closure back, so the questions about the whole
    ///   line (`tailLimit`, integrability on the line) are answered for a custom window only
    ///   when the closure is given here as well; without it they are `nil`.
    /// - Throws: `DSPError.invalidParameter` for a frame or hop that holds nothing and for a
    ///   window that cannot be sampled (WIN-3); `DSPError.cancelled`.
    public func analysis(frame: Int, hop: Int? = nil, tail: (@Sendable (Double) -> Double)? = nil) async throws(DSPError) -> WindowAnalysis {
        let window = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            try WindowAnalysis(window, frame: frame, hop: hop, tail: tail, checkpoint: checkpoint)
        }
    }
}

// MARK: - The analysis

extension WindowAnalysis {
    /// Tolerances of the analysis, in one place.
    enum Limit {
        /// The finest grid: the step is never below 2⁻¹² of the frame (WIN-6).
        static let finestGrid = 4_096
        /// A jump counts when it keeps at least this share of its size as the grid is halved;
        /// a continuous function keeps half.
        static let persistence = 0.75
        /// Two values are the same value within this, relative to the larger.
        static let sameValue = 1e-9
        /// Sums over shifts are constant within this, relative to their size.
        static let constantSum = 1e-10
        /// Riemann sums agree within this, relative to their size.
        static let riemann = 1e-6
        static let highestDerivative = 4
        static let tailProbes = 21
    }

    /// Runs the analysis where it is called. `checkpoint` is asked between the steps.
    init(_ window: Window, frame: Int, hop: Int?, tail: (@Sendable (Double) -> Double)?, checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) {
        guard frame >= 1, frame <= 1 << 22 else {
            throw .invalidParameter(stage: .none, parameter: "frame", reason: "a window is analysed on a frame of 1 to 2²² samples, not \(frame)")
        }
        if let hop {
            guard hop >= 1 else { throw .invalidParameter(stage: .none, parameter: "hop", reason: "a hop is at least one sample, not \(hop)") }
        }
        let samples = try window.doubleSamples(count: frame)
        let count = samples.count
        self.window = window.description
        self.frame = count
        self.hop = hop
        self.samples = samples

        // Shape and gains.
        let sum = samples.reduce(0, +), energy = samples.reduce(0) { $0 + $1 * $1 }
        let peak = samples.reduce(0) { max($0, abs($1)) }
        self.peak = peak
        isFinite = samples.allSatisfy { $0.isFinite }
        isNonNegative = samples.allSatisfy { $0 >= 0 }
        coherentGain = sum / Double(count)
        noiseGain = energy / Double(count)
        let hasSum = abs(sum) > Limit.sameValue * Double(count) * peak
        equivalentNoiseBandwidth = hasSum ? Double(count) * energy / (sum * sum) : nil
        amplitudeNormalization = hasSum ? 2 / abs(sum) : nil
        powerNormalization = (2 / (Double(count) * energy)).squareRoot()
        isSymmetric = WindowAnalysis.isMirrorImage(samples, isClosed: window.isSymmetric || window.isHalf, tolerance: Limit.sameValue * peak)
        try checkpoint?.check()

        // The edges: the symmetric form on three points is the window at t = 0, ½ and 1.
        if window.isHalf {
            (leadingEdgeValue, trailingEdgeValue) = (samples[0], samples[count - 1])
        } else {
            let ends = (try? window.symmetric.doubleSamples(count: 3)) ?? [samples[0], samples[count - 1]]
            (leadingEdgeValue, trailingEdgeValue) = (ends[0], ends[ends.count - 1])
        }

        // Outside the frame.
        let isCustom = window.description.hasPrefix("custom")
        let outside = tail.map { WindowAnalysis.tail(of: $0, peak: peak) }
        if let outside {
            tailLimit = outside.limit
        } else {
            tailLimit = isCustom ? nil : .zero
        }
        try checkpoint?.check()

        // Continuity, smoothness, integrability: three grids, each twice as fine.
        let grids = try WindowAnalysis.grids(of: window, frame: frame)
        try checkpoint?.check()
        var lowest = Limit.highestDerivative
        var jumps: [Discontinuity] = []
        for order in 0 ... Limit.highestDerivative {
            let found = WindowAnalysis.jumps(ofDerivative: order, on: grids, peak: peak)
            if order == 0 { jumps = found }
            if !found.isEmpty {
                lowest = order
                break
            }
            try checkpoint?.check()
        }
        discontinuities = jumps
        smoothness = lowest
        let absolute = WindowAnalysis.converges(grids.map { $0.riemann(power: 1) }, variation: grids.map { $0.variation }, coarsest: grids[0].values.count)
        let square = WindowAnalysis.converges(grids.map { $0.riemann(power: 2) }, variation: grids.map { 2 * peak * $0.variation }, coarsest: grids[0].values.count)
        isAbsolutelyIntegrableOnFrame = absolute
        isSquareIntegrableOnFrame = square
        if let outside {
            isAbsolutelyIntegrableOnLine = absolute && outside.decaysFasterThanReciprocal
            isSquareIntegrableOnLine = square && outside.squareDecaysFasterThanReciprocal
        } else if isCustom {
            isAbsolutelyIntegrableOnLine = nil
            isSquareIntegrableOnLine = nil
        } else {
            isAbsolutelyIntegrableOnLine = absolute
            isSquareIntegrableOnLine = square
        }
        try checkpoint?.check()

        // The spectrum.
        let figures = try WindowAnalysis.spectrum(of: samples, checkpoint: checkpoint)
        spectrum = figures.decibels
        spectrumBinStep = figures.binStep
        mainLobeWidthAtHalfPower = figures.halfPowerWidth
        mainLobeWidthNullToNull = figures.nullToNullWidth
        peakSideLobe = figures.peakSideLobe
        sideLobeFallOff = figures.fallOff
        scallopingLoss = figures.scallopingLoss
        try checkpoint?.check()

        // Overlap-add.
        if let hop {
            let plain = OverlapAdd.sums(samples, hop: Swift.min(hop, count), power: 1)
            let bounds = OverlapAdd.frameBounds(samples, hop: hop)
            let least = hop > count ? Swift.min(plain.min() ?? 0, 0) : (plain.min() ?? 0)
            let greatest = hop > count ? Swift.max(plain.max() ?? 0, 0) : (plain.max() ?? 0)
            let size = Swift.max(abs(least), abs(greatest))
            let ripple = size > 0 ? (greatest - least) / size : 0
            isNonZeroOverlapAdd = OverlapAdd.isNonZero(bounds)
            overlapRipple = ripple
            isConstantOverlapAdd = size > 0 && ripple <= Limit.constantSum
            frameBoundRatio = OverlapAdd.isNonZero(bounds) ? bounds.greatest / bounds.least : nil
        } else {
            isNonZeroOverlapAdd = nil
            isConstantOverlapAdd = nil
            overlapRipple = nil
            frameBoundRatio = nil
        }
    }

    // MARK: Shape

    /// Whether the samples are their own mirror image. A periodic window is one period of a
    /// function: its mirror image pairs sample `n` with sample `N − n`; a symmetric one pairs
    /// `n` with `N − 1 − n`.
    static func isMirrorImage(_ samples: [Double], isClosed: Bool, tolerance: Double) -> Bool {
        let count = samples.count
        var index = isClosed ? 0 : 1
        while index < count {
            let mirror = isClosed ? count - 1 - index : count - index
            if abs(samples[index] - samples[mirror]) > tolerance { return false }
            index += 1
        }
        return true
    }

    // MARK: Outside the frame (WP-501d)

    struct Tail {
        let limit: TailLimit
        let decaysFasterThanReciprocal: Bool
        let squareDecaysFasterThanReciprocal: Bool
    }

    /// Follows `function` to `2ᵏ` frame lengths on either side of the frame, `k = 0 … 20`.
    static func tail(of function: @Sendable (Double) -> Double, peak: Double) -> Tail {
        let distances = (0 ..< Limit.tailProbes).map { pow(2, Double($0)) }
        let before = distances.map { function(-$0) }, after = distances.map { function(1 + $0) }
        let scale = Swift.max(peak, 1e-300)

        func limit(_ values: [Double]) -> TailLimit {
            if values.contains(where: { $0.isNaN }) { return .undefined }
            if values.contains(where: { $0.isInfinite }) { return .unbounded }
            // The far end of the probes: 2¹⁴ frame lengths out and beyond.
            let far = Array(values.suffix(7))
            let sizes = far.map { abs($0) }
            let last = far[far.count - 1]
            if sizes.allSatisfy({ $0 <= 1e-12 * scale }) { return .zero }
            let ratios = zip(sizes, sizes.dropFirst()).map { $0 > 0 ? $1 / $0 : .infinity }
            if ratios.allSatisfy({ $0 > 1.01 }) { return .unbounded }                     // still growing
            // It has a limit when it has stopped moving, or when its steps keep shrinking.
            let steps = zip(far, far.dropFirst()).map { abs($1 - $0) }
            let hasSettled = (steps.max() ?? 0) <= Limit.sameValue * Swift.max(abs(last), scale)
            let isClosingIn = zip(steps, steps.dropFirst()).allSatisfy { $1 <= 0.9 * $0 || $1 <= 1e-300 }
            guard hasSettled || isClosingIn else { return .undefined }
            if ratios.allSatisfy({ $0 < 0.99 }) || abs(last) <= 1e-12 * scale { return .zero }  // still falling: towards 0
            return .value(last)
        }

        let left = limit(before), right = limit(after)
        let combined: TailLimit
        switch (left, right) {
        case (.undefined, _), (_, .undefined): combined = .undefined
        case (.unbounded, _), (_, .unbounded): combined = .unbounded
        case (.zero, .zero): combined = .zero
        case (.value(let a), .value(let b)): combined = abs(a - b) <= Limit.sameValue * Swift.max(abs(a), abs(b), scale) ? .value(a) : .undefined
        default: combined = .undefined                                                   // 0 on one side, another value on the other
        }

        // ∫|f| exists out there when |f|·|t| keeps falling; ∫f² when f²·|t| does.
        func falls(_ values: [Double], power: Double) -> Bool {
            guard values.allSatisfy({ $0.isFinite }) else { return false }
            let weighted = zip(values, distances).map { pow(abs($0), power) * $1 }.suffix(10)
            return zip(weighted, weighted.dropFirst()).allSatisfy { $1 <= 0.9 * $0 || $1 <= 1e-300 }
        }
        return Tail(limit: combined, decaysFasterThanReciprocal: falls(before, power: 1) && falls(after, power: 1),
                    squareDecaysFasterThanReciprocal: falls(before, power: 2) && falls(after, power: 2))
    }

    // MARK: Grids (WP-501e)

    /// The window on one grid, with zeros where the outside is.
    struct Grid {
        /// The samples on the grid.
        let values: [Double]
        /// The distance between two grid points, as a fraction of the frame.
        let step: Double
        /// True when the last grid point is the end of the frame itself; otherwise the end of
        /// the frame is one step after the last point.
        let isClosed: Bool

        /// `Σ|v|^power` times the step: a Riemann sum over the frame.
        func riemann(power: Int) -> Double {
            values.reduce(0) { $0 + (power == 2 ? $1 * $1 : abs($1)) } * step
        }

        /// The total variation of the samples, the outside included.
        var variation: Double {
            var total = abs(values[0]) + abs(values[values.count - 1])
            for index in 1 ..< values.count { total += abs(values[index] - values[index - 1]) }
            return total
        }
    }

    /// Three grids over the frame, each twice as fine as the one before: 2¹⁰, 2¹¹ and 2¹²
    /// points, the finest the method allows (WIN-6). The verdicts are about the window's
    /// function, so they are read on the same grids whatever the frame: a short frame would
    /// give grids too coarse to tell a jump from a steep slope.
    static func grids(of window: Window, frame: Int) throws(DSPError) -> [Grid] {
        let coarsest = Limit.finestGrid / 4
        var result: [Grid] = []
        for factor in [1, 2, 4] {
            // A symmetric window has its last sample on the end of the frame: its grids share
            // their end points. A periodic one has it one step before.
            let intervals = window.isSymmetric ? (coarsest - 1) * factor : coarsest * factor
            let count: Int
            if window.isHalf {
                count = 2 * (window.isSymmetric ? intervals + 1 : intervals) - 1
            } else {
                count = window.isSymmetric ? intervals + 1 : intervals
            }
            let values = try window.doubleSamples(count: count)
            let closed = window.isSymmetric || window.isHalf
            result.append(Grid(values: values, step: 1 / Double(closed ? Swift.max(values.count - 1, 1) : values.count), isClosed: closed))
        }
        return result
    }

    /// The jumps of the `order`-th derivative: places where its change across a few grid
    /// steps does not shrink as the grid is refined. A continuous derivative changes by an
    /// amount proportional to the step; across a jump it changes by the jump.
    static func jumps(ofDerivative order: Int, on grids: [Grid], peak: Double) -> [Discontinuity] {
        // The change of the derivative of order `order` across `2·order + 3` steps, centred
        // on each grid point, on each grid.
        let changes = grids.map { change(ofDerivative: order, on: $0) }
        let fine = changes[2], middle = changes[1], coarse = changes[0]
        let finest = grids[2]
        // Round-off of a difference of order `order + 1` at the finest step.
        let noise = 64 * Double.ulpOfOne * pow(2, Double(order + 1)) * Swift.max(peak, 1e-300) * pow(1 / finest.step, Double(order))
        let reach = 2 * order + 3

        var found: [Discontinuity] = []
        var index = 0
        while index < fine.values.count {
            let size = abs(fine.values[index])
            guard size > noise else { index += 1; continue }
            // The largest change in its neighbourhood.
            let low = Swift.max(index - reach, 0), high = Swift.min(index + reach, fine.values.count - 1)
            guard (low ... high).allSatisfy({ abs(fine.values[$0]) <= size }) else { index += 1; continue }
            // The same place on the coarser grids.
            let position = fine.position(index)
            let onMiddle = middle.nearest(to: position), onCoarse = coarse.nearest(to: position)
            if size >= Limit.persistence * onMiddle, onMiddle >= Limit.persistence * onCoarse {
                // A jump of the window itself is placed between the two samples it separates.
                let place = order == 0 ? WindowAnalysis.steepestStep(of: finest, around: position, reach: reach) : position
                found.append(Discontinuity(position: Swift.min(Swift.max(place, 0), 1), size: size))
                index = high + 1
            } else {
                index += 1
            }
        }
        return found
    }

    /// The middle of the largest step between two neighbouring samples of `grid` within
    /// `reach` steps of `position`, the outside counting as 0. Of two steps of one size, the
    /// one nearer to `position`: jumps a few samples apart are each reported where they are.
    static func steepestStep(of grid: Grid, around position: Double, reach: Int) -> Double {
        let count = grid.values.count
        func value(_ index: Int) -> Double { index >= 0 && index < count ? grid.values[index] : 0 }
        let centre = Int((position / grid.step).rounded())
        var best = position, largest = -1.0, nearest = Double.infinity
        for index in (centre - reach - 1) ... (centre + reach) {
            let step = abs(value(index + 1) - value(index))
            // Between the outside and the first or last sample, the jump is the frame's edge.
            let place = index < 0 ? 0 : (index + 1 >= count ? 1 : (Double(index) + 0.5) * grid.step)
            let distance = abs(place - position)
            if step > largest || (step == largest && distance < nearest) {
                (largest, nearest, best) = (step, distance, place)
            }
        }
        return best
    }

    /// The change of a derivative across a window of grid steps, per grid point.
    struct Changes {
        let values: [Double]
        /// The position of the centre of the first window, and the step between two.
        let origin: Double
        let step: Double

        func position(_ index: Int) -> Double { origin + Double(index) * step }

        /// The largest change among the windows nearest to `position`.
        func nearest(to position: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let index = Int(((position - origin) / step).rounded())
            var largest = 0.0
            for candidate in (index - 1) ... (index + 1) where candidate >= 0 && candidate < values.count {
                largest = Swift.max(largest, abs(values[candidate]))
            }
            return largest
        }
    }

    static func change(ofDerivative order: Int, on grid: Grid) -> Changes {
        // Zeros where the outside is. A closed grid ends on the frame's end; an open one stops
        // one step before it, and the end of the frame is where the outside begins.
        let padding = 2 * order + 4
        var extended = [Double](repeating: 0, count: padding) + grid.values + [Double](repeating: 0, count: padding)
        // The derivative of order `order`, as differences divided by the step.
        var derivative = extended
        for _ in 0 ..< order {
            for index in 0 ..< derivative.count - 1 { derivative[index] = (derivative[index + 1] - derivative[index]) / grid.step }
            derivative.removeLast()
        }
        extended = derivative
        // Its change across 2·order + 3 steps: wide enough to hold a jump wherever it falls
        // between the grid points.
        let width = 2 * order + 3
        var values: [Double] = []
        values.reserveCapacity(Swift.max(extended.count - width, 0))
        var index = 0
        while index + width < extended.count {
            values.append(extended[index + width] - extended[index])
            index += 1
        }
        // Sample `j` of the extended sequence sits at (j − padding)·step; a difference of order
        // `order` at `j` is centred `order / 2` steps later, and a window of `width` steps that
        // starts there is centred `width / 2` steps later still.
        let origin = (Double(order) / 2 + Double(width) / 2 - Double(padding)) * grid.step
        return Changes(values: values, origin: origin, step: grid.step)
    }

    /// Whether Riemann sums on three grids converge: they are finite, and they agree, or they
    /// close in on one another, or the function is of bounded variation, in which case the
    /// sums differ by no more than its variation times the step.
    static func converges(_ sums: [Double], variation: [Double], coarsest: Int) -> Bool {
        guard sums.count == 3, variation.count == 3, sums.allSatisfy({ $0.isFinite }), variation.allSatisfy({ $0.isFinite }) else { return false }
        let first = abs(sums[1] - sums[0]), second = abs(sums[2] - sums[1])
        if second <= Limit.riemann * Swift.max(abs(sums[2]), 1e-300) { return true }
        if second <= 0.9 * first { return true }
        return variation[2] <= 1.5 * variation[0] && second <= variation[2] / Double(Swift.max(coarsest, 1))
    }

    // MARK: Spectrum (WP-501f)

    struct SpectralFigures {
        let decibels: [Double]
        let binStep: Double
        let halfPowerWidth: Double
        let nullToNullWidth: Double?
        let peakSideLobe: Double?
        let fallOff: Double?
        let scallopingLoss: Double
    }

    /// The least power kept apart from zero, relative to the power at 0 Hz: −400 dB.
    static let powerFloor = 1e-40

    static func spectrum(of samples: [Double], checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) -> SpectralFigures {
        let count = samples.count
        // Zero-padded sixteen times, or to the next transform length above that.
        let length = DSP.nextFastLength(16 * count)
        let transform = try DoubleDFT(length: length)
        var padded = [Double](repeating: 0, count: length)
        padded.replaceSubrange(0 ..< count, with: samples)
        var real = [Double](repeating: 0, count: length / 2 + 1), imaginary = real
        padded.withUnsafeBufferPointer { source in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    guard let from = source.baseAddress, let toReal = re.baseAddress, let toImaginary = im.baseAddress else { return }
                    transform.forward(from, real: toReal, imaginary: toImaginary)
                }
            }
        }
        try checkpoint?.check()

        // Powers relative to the one at 0 Hz, the top of the main lobe; for a window without a
        // sum, relative to the largest.
        var power = [Double](repeating: 0, count: real.count)
        for index in power.indices { power[index] = real[index] * real[index] + imaginary[index] * imaginary[index] }
        let reference = power[0] > 0 ? power[0] : Swift.max(power.max() ?? 0, 1e-300)
        for index in power.indices { power[index] = Swift.max(power[index] / reference, powerFloor) }
        let binStep = Double(count) / Double(length)             // bins of the frame's transform per point
        let decibels = power.map { 10 * log10($0) }
        let last = power.count - 1

        // The main lobe at half power: the first point at or below it, interpolated.
        var halfPowerWidth = 2 * Double(last) * binStep
        if let below = power.firstIndex(where: { $0 <= 0.5 }), below > 0 {
            let above = decibels[below - 1], under = decibels[below], target = 10 * log10(0.5)
            let fraction = above > under ? (above - target) / (above - under) : 0
            halfPowerWidth = 2 * (Double(below - 1) + fraction) * binStep
        }

        // The first null: the first local minimum. Through a null the transform itself passes
        // through zero in a straight line, so the null is where the line between two of its
        // points comes nearest to zero.
        var null: Int?
        var index = 1
        while index < last {
            if power[index] < power[index - 1], power[index] <= power[index + 1] {
                null = index
                break
            }
            index += 1
        }
        var nullToNullWidth: Double?
        if let null {
            var best = (position: Double(null), residual: Double.infinity)
            for start in [null - 1, null] {
                let dr = real[start + 1] - real[start], di = imaginary[start + 1] - imaginary[start]
                let length = dr * dr + di * di
                let fraction = length > 0 ? Swift.min(Swift.max(-(real[start] * dr + imaginary[start] * di) / length, 0), 1) : 0
                let re = real[start] + fraction * dr, im = imaginary[start] + fraction * di
                if re * re + im * im < best.residual { best = (Double(start) + fraction, re * re + im * im) }
            }
            nullToNullWidth = 2 * best.position * binStep
        }

        // The side lobes: the local maxima beyond the first null, each refined by a parabola
        // through its powers. (Through decibels a parabola fails beside a null, where the
        // level has no bottom.)
        var lobes: [(frequency: Double, level: Double)] = []
        if let null {
            index = null + 1
            while index < last {
                if power[index] >= power[index - 1], power[index] > power[index + 1] {
                    let curvature = power[index - 1] - 2 * power[index] + power[index + 1]
                    var shift = 0.0, top = power[index]
                    if curvature < 0 {
                        shift = Swift.min(Swift.max(0.5 * (power[index - 1] - power[index + 1]) / curvature, -0.5), 0.5)
                        top -= 0.25 * (power[index - 1] - power[index + 1]) * shift
                    }
                    lobes.append(((Double(index) + shift) * binStep, 10 * log10(Swift.max(top, powerFloor))))
                }
                index += 1
            }
        }
        let peakSideLobe = lobes.map { $0.level }.max()

        // The fall-off: a line through the lobe peaks between N / 32 (and never below 8) and
        // N / 4 bins, against the octave. Nearer the main lobe the lobes are not yet regular;
        // nearer the Nyquist bin those of a sampled window stop falling.
        var fallOff: Double?
        let fitted = lobes.filter {
            $0.frequency >= Swift.max(Double(count) / 32, 8) && $0.frequency <= Double(count) / 4 && $0.level > 10 * log10(powerFloor) + 20
        }
        if fitted.count >= 3 {
            let octaves = fitted.map { log2($0.frequency) }, levels = fitted.map { $0.level }
            let meanOctave = octaves.reduce(0, +) / Double(fitted.count), meanLevel = levels.reduce(0, +) / Double(fitted.count)
            let spread = octaves.reduce(0) { $0 + ($1 - meanOctave) * ($1 - meanOctave) }
            if spread > 0 {
                fallOff = zip(octaves, levels).reduce(0) { $0 + ($1.0 - meanOctave) * ($1.1 - meanLevel) } / spread
            }
        }

        // Half a bin off centre.
        let half = 0.5 / binStep
        let lower = Swift.min(Int(half.rounded(.down)), last), upper = Swift.min(lower + 1, last)
        let fraction = half - Double(lower)
        let scallopingLoss = 0 - (decibels[lower] * (1 - fraction) + decibels[upper] * fraction)

        // What is kept for a plot: up to the Nyquist bin of the frame.
        return SpectralFigures(decibels: decibels, binStep: binStep, halfPowerWidth: halfPowerWidth, nullToNullWidth: nullToNullWidth,
                               peakSideLobe: peakSideLobe, fallOff: fallOff, scallopingLoss: scallopingLoss)
    }
}
