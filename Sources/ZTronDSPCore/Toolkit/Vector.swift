import Accelerate

/// Element-wise operations and reductions on `Float` vectors, each in more than one
/// implementation with one contract (§5.11.4, §7.4, SEL-1).
///
/// Three ways to call a primitive:
///
/// - `Vector.scale(…)`: **automatic**. One integer comparison of the length with the shipped
///   crossover picks the implementation (SEL-4).
/// - `Vector.Native.scale(…)`, `Vector.Accelerated.scale(…)`: one implementation, by name.
/// - `Vector.Bound`: the primitives bound once for a fixed length, as a plan binds them when
///   it is compiled, so the hot path has no size test (SEL-3).
///
/// The element-wise implementations agree bit for bit; the reductions agree within 10⁻⁶
/// relative, because they sum in a different order (SEL-6).
///
/// Every function here is allocation-free and lock-free and may be called on the analysis
/// thread. The native loops are `while` loops on purpose: a `for … in` loop allocates per
/// iteration in an unoptimised build (CR-002). Source and result may be the same buffer;
/// partial overlap is not supported. A count of zero or less does nothing.
public enum Vector {
    /// The shipped crossovers, as constants an inlined caller folds (§7.4). `CrossoverTable.shipped`
    /// is built from the same numbers.
    /// Usable on any thread; reading them does not allocate.
    public enum Crossover {
        /// The length from which the element-wise primitives use vDSP.
        @inlinable public static var elementwise: Int { 512 }
        /// The length from which the native reductions use the 8-lane loop.
        @inlinable public static var reductionSIMD: Int { 16 }
        /// The length from which the reductions use vDSP.
        @inlinable public static var reductionAccelerate: Int { 64 }
    }

    // MARK: Automatic

    /// `result[i] = source[i] · factor`.
    @inlinable
    public static func scale(_ source: UnsafePointer<Float>, by factor: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
        if count >= Crossover.elementwise { Accelerated.scale(source, by: factor, into: result, count: count) }
        else { Native.scale(source, by: factor, into: result, count: count) }
    }

    /// `result[i] = a[i] + b[i]`.
    @inlinable
    public static func add(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
        if count >= Crossover.elementwise { Accelerated.add(a, b, into: result, count: count) }
        else { Native.add(a, b, into: result, count: count) }
    }

    /// `result[i] = a[i] − b[i]`.
    @inlinable
    public static func subtract(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
        if count >= Crossover.elementwise { Accelerated.subtract(a, b, into: result, count: count) }
        else { Native.subtract(a, b, into: result, count: count) }
    }

    /// `result[i] = a[i] · b[i]`.
    @inlinable
    public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
        if count >= Crossover.elementwise { Accelerated.multiply(a, b, into: result, count: count) }
        else { Native.multiply(a, b, into: result, count: count) }
    }

    /// `result[i] = min(max(source[i], low), high)`. A NaN stays a NaN in every implementation.
    @inlinable
    public static func clip(_ source: UnsafePointer<Float>, low: Float, high: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
        if count >= Crossover.elementwise { Accelerated.clip(source, low: low, high: high, into: result, count: count) }
        else { Native.clip(source, low: low, high: high, into: result, count: count) }
    }

    /// `Σ source[i]`. Zero for an empty vector.
    @inlinable
    public static func sum(_ source: UnsafePointer<Float>, count: Int) -> Float {
        if count >= Crossover.reductionAccelerate { return Accelerated.sum(source, count: count) }
        if count >= Crossover.reductionSIMD { return Native.sumSIMD(source, count: count) }
        return Native.sum(source, count: count)
    }

    /// `Σ a[i] · b[i]`. Zero for empty vectors.
    @inlinable
    public static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
        if count >= Crossover.reductionAccelerate { return Accelerated.dot(a, b, count: count) }
        if count >= Crossover.reductionSIMD { return Native.dotSIMD(a, b, count: count) }
        return Native.dot(a, b, count: count)
    }

    /// `(Σ source[i]²) / count`. Zero for an empty vector.
    @inlinable
    public static func meanSquare(_ source: UnsafePointer<Float>, count: Int) -> Float {
        if count >= Crossover.reductionAccelerate { return Accelerated.meanSquare(source, count: count) }
        if count >= Crossover.reductionSIMD { return Native.meanSquareSIMD(source, count: count) }
        return Native.meanSquare(source, count: count)
    }

    /// The smallest element. Zero for an empty vector. The input must hold no NaN (NUM-1).
    @inlinable
    public static func minimum(_ source: UnsafePointer<Float>, count: Int) -> Float {
        if count >= Crossover.reductionAccelerate { return Accelerated.minimum(source, count: count) }
        if count >= Crossover.reductionSIMD { return Native.minimumSIMD(source, count: count) }
        return Native.minimum(source, count: count)
    }

    /// The largest element. Zero for an empty vector. The input must hold no NaN (NUM-1).
    @inlinable
    public static func maximum(_ source: UnsafePointer<Float>, count: Int) -> Float {
        if count >= Crossover.reductionAccelerate { return Accelerated.maximum(source, count: count) }
        if count >= Crossover.reductionSIMD { return Native.maximumSIMD(source, count: count) }
        return Native.maximum(source, count: count)
    }

    // MARK: Native

    /// Plain Swift loops: the fastest way to do a small thing (E-26).
    /// Like every primitive here, each function may be called on any thread, the analysis thread
    /// included, and does not allocate or lock.
    public enum Native {
        /// `result[i] = source[i] · factor`, in a plain loop.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func scale(_ source: UnsafePointer<Float>, by factor: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
            var index = 0
            while index < count {
                result[index] = source[index] * factor
                index &+= 1
            }
        }

        /// `result[i] = a[i] + b[i]`, in a plain loop.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func add(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            var index = 0
            while index < count {
                result[index] = a[index] + b[index]
                index &+= 1
            }
        }

        /// `result[i] = a[i] − b[i]`, in a plain loop.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func subtract(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            var index = 0
            while index < count {
                result[index] = a[index] - b[index]
                index &+= 1
            }
        }

        /// `result[i] = a[i] · b[i]`, in a plain loop.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            var index = 0
            while index < count {
                result[index] = a[index] * b[index]
                index &+= 1
            }
        }

        /// `result[i] = min(max(source[i], low), high)`, in a plain loop. A NaN stays a NaN.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func clip(_ source: UnsafePointer<Float>, low: Float, high: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
            var index = 0
            while index < count {
                // Written so that a NaN stays a NaN, as it does in vDSP_vclip.
                let value = source[index]
                result[index] = value > high ? high : (value < low ? low : value)
                index &+= 1
            }
        }

        /// `Σ source[i]`, added in index order. Zero for an empty vector.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func sum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            var total: Float = 0
            var index = 0
            while index < count {
                total += source[index]
                index &+= 1
            }
            return total
        }

        /// `Σ a[i] · b[i]`, added in index order. Zero for empty vectors.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
            var total: Float = 0
            var index = 0
            while index < count {
                total += a[index] * b[index]
                index &+= 1
            }
            return total
        }

        /// `(Σ source[i]²) / count`, by the plain dot product. Zero for an empty vector.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func meanSquare(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            return dot(source, source, count: count) / Float(count)
        }

        /// The smallest element, in a plain loop. Zero for an empty vector. The input must hold no
        /// NaN (NUM-1).
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func minimum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var best = source[0]
            var index = 1
            while index < count {
                if source[index] < best { best = source[index] }
                index &+= 1
            }
            return best
        }

        /// The largest element, in a plain loop. Zero for an empty vector. The input must hold no
        /// NaN (NUM-1).
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func maximum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var best = source[0]
            var index = 1
            while index < count {
                if source[index] > best { best = source[index] }
                index &+= 1
            }
            return best
        }

        // The 8-lane forms: eight independent accumulators, then the tail in scalar. Eight
        // lanes break the dependency chain of a single running sum, and the optimiser turns
        // them into vector registers. They are written as eight scalars, not as `SIMD8<Float>`:
        // in an unoptimised build the generic SIMD operations box their operands on the heap,
        // and the hot path must stay allocation-free in Debug as well (CR-002).

        /// `Σ source[i]` in eight running sums, added pairwise at the end, then the tail. Zero
        /// for an
        /// empty vector.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func sumSIMD(_ source: UnsafePointer<Float>, count: Int) -> Float {
            var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
            var s4: Float = 0, s5: Float = 0, s6: Float = 0, s7: Float = 0
            var index = 0
            while index &+ 8 <= count {
                s0 += source[index]
                s1 += source[index &+ 1]
                s2 += source[index &+ 2]
                s3 += source[index &+ 3]
                s4 += source[index &+ 4]
                s5 += source[index &+ 5]
                s6 += source[index &+ 6]
                s7 += source[index &+ 7]
                index &+= 8
            }
            var total = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7))
            while index < count {
                total += source[index]
                index &+= 1
            }
            return total
        }

        /// `Σ a[i] · b[i]` in eight running sums, added pairwise at the end, then the tail. Zero
        /// for
        /// empty vectors.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func dotSIMD(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
            var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
            var s4: Float = 0, s5: Float = 0, s6: Float = 0, s7: Float = 0
            var index = 0
            while index &+ 8 <= count {
                s0 += a[index] * b[index]
                s1 += a[index &+ 1] * b[index &+ 1]
                s2 += a[index &+ 2] * b[index &+ 2]
                s3 += a[index &+ 3] * b[index &+ 3]
                s4 += a[index &+ 4] * b[index &+ 4]
                s5 += a[index &+ 5] * b[index &+ 5]
                s6 += a[index &+ 6] * b[index &+ 6]
                s7 += a[index &+ 7] * b[index &+ 7]
                index &+= 8
            }
            var total = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7))
            while index < count {
                total += a[index] * b[index]
                index &+= 1
            }
            return total
        }

        /// `(Σ source[i]²) / count`, by the 8-lane dot product. Zero for an empty vector.
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func meanSquareSIMD(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            return dotSIMD(source, source, count: count) / Float(count)
        }

        /// The smallest element, in eight running minima; below eight elements, the plain loop.
        /// Zero
        /// for an empty vector. The input must hold no NaN (NUM-1).
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func minimumSIMD(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count >= 8 else { return minimum(source, count: count) }
            var m0 = source[0], m1 = source[1], m2 = source[2], m3 = source[3]
            var m4 = source[4], m5 = source[5], m6 = source[6], m7 = source[7]
            var index = 8
            while index &+ 8 <= count {
                if source[index] < m0 { m0 = source[index] }
                if source[index &+ 1] < m1 { m1 = source[index &+ 1] }
                if source[index &+ 2] < m2 { m2 = source[index &+ 2] }
                if source[index &+ 3] < m3 { m3 = source[index &+ 3] }
                if source[index &+ 4] < m4 { m4 = source[index &+ 4] }
                if source[index &+ 5] < m5 { m5 = source[index &+ 5] }
                if source[index &+ 6] < m6 { m6 = source[index &+ 6] }
                if source[index &+ 7] < m7 { m7 = source[index &+ 7] }
                index &+= 8
            }
            if m1 < m0 { m0 = m1 }
            if m3 < m2 { m2 = m3 }
            if m5 < m4 { m4 = m5 }
            if m7 < m6 { m6 = m7 }
            if m2 < m0 { m0 = m2 }
            if m6 < m4 { m4 = m6 }
            var result = m4 < m0 ? m4 : m0
            while index < count {
                if source[index] < result { result = source[index] }
                index &+= 1
            }
            return result
        }

        /// The largest element, in eight running maxima; below eight elements, the plain loop. Zero
        /// for an empty vector. The input must hold no NaN (NUM-1).
        #if ZTRONDSP_PERF_ANNOTATIONS
        @_noAllocation @_noLocks
        #endif
        @inlinable
        public static func maximumSIMD(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count >= 8 else { return maximum(source, count: count) }
            var m0 = source[0], m1 = source[1], m2 = source[2], m3 = source[3]
            var m4 = source[4], m5 = source[5], m6 = source[6], m7 = source[7]
            var index = 8
            while index &+ 8 <= count {
                if source[index] > m0 { m0 = source[index] }
                if source[index &+ 1] > m1 { m1 = source[index &+ 1] }
                if source[index &+ 2] > m2 { m2 = source[index &+ 2] }
                if source[index &+ 3] > m3 { m3 = source[index &+ 3] }
                if source[index &+ 4] > m4 { m4 = source[index &+ 4] }
                if source[index &+ 5] > m5 { m5 = source[index &+ 5] }
                if source[index &+ 6] > m6 { m6 = source[index &+ 6] }
                if source[index &+ 7] > m7 { m7 = source[index &+ 7] }
                index &+= 8
            }
            if m1 > m0 { m0 = m1 }
            if m3 > m2 { m2 = m3 }
            if m5 > m4 { m4 = m5 }
            if m7 > m6 { m6 = m7 }
            if m2 > m0 { m0 = m2 }
            if m6 > m4 { m4 = m6 }
            var result = m4 > m0 ? m4 : m0
            while index < count {
                if source[index] > result { result = source[index] }
                index &+= 1
            }
            return result
        }
    }

    // MARK: Accelerate

    /// vDSP: the fastest way to do a large thing.
    ///
    /// Each function may be called on any thread, the analysis thread included, and does not
    /// allocate; a count of zero or less returns before vDSP is called.
    public enum Accelerated {
        /// `result[i] = source[i] · factor`, by `vDSP_vsmul`.
        @inlinable
        public static func scale(_ source: UnsafePointer<Float>, by factor: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
            guard count > 0 else { return }
            var factor = factor
            vDSP_vsmul(source, 1, &factor, result, 1, vDSP_Length(count))
        }

        /// `result[i] = a[i] + b[i]`, by `vDSP_vadd`.
        @inlinable
        public static func add(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            guard count > 0 else { return }
            vDSP_vadd(a, 1, b, 1, result, 1, vDSP_Length(count))
        }

        /// `result[i] = a[i] − b[i]`, by `vDSP_vsub`.
        @inlinable
        public static func subtract(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            guard count > 0 else { return }
            // vDSP_vsub computes its second operand minus its first.
            vDSP_vsub(b, 1, a, 1, result, 1, vDSP_Length(count))
        }

        /// `result[i] = a[i] · b[i]`, by `vDSP_vmul`.
        @inlinable
        public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
            guard count > 0 else { return }
            vDSP_vmul(a, 1, b, 1, result, 1, vDSP_Length(count))
        }

        /// `result[i] = min(max(source[i], low), high)`, by `vDSP_vclip`. A NaN stays a NaN.
        @inlinable
        public static func clip(_ source: UnsafePointer<Float>, low: Float, high: Float, into result: UnsafeMutablePointer<Float>, count: Int) {
            guard count > 0 else { return }
            var low = low, high = high
            vDSP_vclip(source, 1, &low, &high, result, 1, vDSP_Length(count))
        }

        /// `Σ source[i]`, by `vDSP_sve`. Zero for an empty vector.
        @inlinable
        public static func sum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var result: Float = 0
            vDSP_sve(source, 1, &result, vDSP_Length(count))
            return result
        }

        /// `Σ a[i] · b[i]`, by `vDSP_dotpr`. Zero for empty vectors.
        @inlinable
        public static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var result: Float = 0
            vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
            return result
        }

        /// `(Σ source[i]²) / count`, by `vDSP_measqv`. Zero for an empty vector.
        @inlinable
        public static func meanSquare(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var result: Float = 0
            vDSP_measqv(source, 1, &result, vDSP_Length(count))
            return result
        }

        /// The smallest element, by `vDSP_minv`. Zero for an empty vector. The input must hold no
        /// NaN (NUM-1).
        @inlinable
        public static func minimum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var result: Float = 0
            vDSP_minv(source, 1, &result, vDSP_Length(count))
            return result
        }

        /// The largest element, by `vDSP_maxv`. Zero for an empty vector. The input must hold no
        /// NaN (NUM-1).
        @inlinable
        public static func maximum(_ source: UnsafePointer<Float>, count: Int) -> Float {
            guard count > 0 else { return 0 }
            var result: Float = 0
            vDSP_maxv(source, 1, &result, vDSP_Length(count))
            return result
        }
    }

    // MARK: Bound

    /// The primitives bound to one implementation each for a fixed length: what a node keeps
    /// when its plan is compiled, so that its hot path holds the chosen functions and makes
    /// no size test (SEL-3). Create it on the control context; call its members on the
    /// analysis thread. An immutable value.
    /// Neither creating one nor calling its members allocates: the bound closures capture nothing.
    public struct Bound: Sendable {
        /// The shape of ``scale``: source, factor, result, count.
        public typealias Scale = @Sendable (_ source: UnsafePointer<Float>, _ factor: Float, _ result: UnsafeMutablePointer<Float>, _ count: Int) -> Void
        /// The shape of the element-wise operations on two vectors: `a`, `b`, result, count.
        public typealias Binary = @Sendable (_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ result: UnsafeMutablePointer<Float>, _ count: Int) -> Void
        /// The shape of ``clip``: source, low, high, result, count.
        public typealias Clip = @Sendable (_ source: UnsafePointer<Float>, _ low: Float, _ high: Float, _ result: UnsafeMutablePointer<Float>, _ count: Int) -> Void
        /// The shape of a reduction of one vector: source, count.
        public typealias Reduction = @Sendable (_ source: UnsafePointer<Float>, _ count: Int) -> Float
        /// The shape of ``dot``: `a`, `b`, count.
        public typealias BinaryReduction = @Sendable (_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ count: Int) -> Float

        /// The length the binding was made for.
        public let count: Int
        /// The implementation the element-wise primitives are bound to.
        public let elementwise: Implementation
        /// The implementation the reductions are bound to.
        public let reduction: Implementation
        /// Whether the native reductions use the 8-lane loop.
        public let reductionUsesSIMD: Bool

        /// `result[i] = source[i] · factor`, in the bound implementation.
        public let scale: Scale
        /// `result[i] = a[i] + b[i]`, in the bound implementation.
        public let add: Binary
        /// `result[i] = a[i] − b[i]`, in the bound implementation.
        public let subtract: Binary
        /// `result[i] = a[i] · b[i]`, in the bound implementation.
        public let multiply: Binary
        /// `result[i] = min(max(source[i], low), high)`, in the bound implementation.
        public let clip: Clip
        /// `Σ source[i]`, in the bound implementation.
        public let sum: Reduction
        /// `Σ a[i] · b[i]`, in the bound implementation.
        public let dot: BinaryReduction
        /// `(Σ source[i]²) / count`, in the bound implementation.
        public let meanSquare: Reduction
        /// The smallest element, in the bound implementation. The input must hold no NaN (NUM-1).
        public let minimum: Reduction
        /// The largest element, in the bound implementation. The input must hold no NaN (NUM-1).
        public let maximum: Reduction

        /// Binds the primitives for vectors of `count` elements.
        ///
        /// - Parameters:
        ///   - count: the length the primitives are bound for.
        ///   - implementation: `.automatic` follows `crossovers`; `.native` and `.accelerate`
        ///     are honoured; `.metal` has no implementation here and is treated as automatic.
        ///   - crossovers: the table to follow; the engine passes its own.
        public init(count: Int, implementation: Implementation = .automatic, crossovers: CrossoverTable = .shipped) {
            self.count = count
            elementwise = crossovers.implementation(for: .elementwise, size: count, requested: implementation)
            reduction = crossovers.implementation(for: .reduction, size: count, requested: implementation)
            reductionUsesSIMD = crossovers.reductionUsesSIMD(count: count)

            if elementwise == .accelerate {
                scale = { Accelerated.scale($0, by: $1, into: $2, count: $3) }
                add = { Accelerated.add($0, $1, into: $2, count: $3) }
                subtract = { Accelerated.subtract($0, $1, into: $2, count: $3) }
                multiply = { Accelerated.multiply($0, $1, into: $2, count: $3) }
                clip = { Accelerated.clip($0, low: $1, high: $2, into: $3, count: $4) }
            } else {
                scale = { Native.scale($0, by: $1, into: $2, count: $3) }
                add = { Native.add($0, $1, into: $2, count: $3) }
                subtract = { Native.subtract($0, $1, into: $2, count: $3) }
                multiply = { Native.multiply($0, $1, into: $2, count: $3) }
                clip = { Native.clip($0, low: $1, high: $2, into: $3, count: $4) }
            }

            if reduction == .accelerate {
                sum = { Accelerated.sum($0, count: $1) }
                dot = { Accelerated.dot($0, $1, count: $2) }
                meanSquare = { Accelerated.meanSquare($0, count: $1) }
                minimum = { Accelerated.minimum($0, count: $1) }
                maximum = { Accelerated.maximum($0, count: $1) }
            } else if reductionUsesSIMD {
                sum = { Native.sumSIMD($0, count: $1) }
                dot = { Native.dotSIMD($0, $1, count: $2) }
                meanSquare = { Native.meanSquareSIMD($0, count: $1) }
                minimum = { Native.minimumSIMD($0, count: $1) }
                maximum = { Native.maximumSIMD($0, count: $1) }
            } else {
                sum = { Native.sum($0, count: $1) }
                dot = { Native.dot($0, $1, count: $2) }
                meanSquare = { Native.meanSquare($0, count: $1) }
                minimum = { Native.minimum($0, count: $1) }
                maximum = { Native.maximum($0, count: $1) }
            }
        }
    }
}
