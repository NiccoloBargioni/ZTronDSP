import Accelerate
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

/// Lengths around every boundary the implementations have: empty, one, the 8-lane block, the
/// crossovers.
private let lengths = [0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 511, 512, 513, 1_025]

private func withBuffers<T>(_ a: [Float], _ b: [Float], _ body: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> T) -> (T, [Float]) {
    var out = [Float](repeating: -777, count: max(a.count, 1))
    let result = a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            out.withUnsafeMutableBufferPointer { po in
                // An empty array may have no base address: lend a valid one, it is never read.
                body(pa.baseAddress ?? UnsafePointer(po.baseAddress!), pb.baseAddress ?? UnsafePointer(po.baseAddress!), po.baseAddress!)
            }
        }
    }
    return (result, Array(out.prefix(a.count)))
}

@Suite("Vector, element-wise (WP-113)")
struct VectorElementwiseTests {
    private func signals(_ count: Int) -> ([Float], [Float]) {
        (TestSignal.whiteNoise(count: count, seed: 113, amplitude: 4), TestSignal.whiteNoise(count: count, seed: 1_130, amplitude: 4))
    }

    @Test(arguments: lengths)
    func implementationsAgreeBitForBit(count: Int) {
        let (a, b) = signals(count)
        let scalar: [(String, [Float])] = [
            ("scale", a.map { $0 * 0.37 }),
            ("add", zip(a, b).map { $0 + $1 }),
            ("subtract", zip(a, b).map { $0 - $1 }),
            ("multiply", zip(a, b).map { $0 * $1 }),
            ("clip", a.map { min(max($0, -1.5), 2.25) }),
        ]
        typealias Operation = (UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Void
        let native: [Operation] = [
            { Vector.Native.scale($0, by: 0.37, into: $2, count: count) },
            { Vector.Native.add($0, $1, into: $2, count: count) },
            { Vector.Native.subtract($0, $1, into: $2, count: count) },
            { Vector.Native.multiply($0, $1, into: $2, count: count) },
            { Vector.Native.clip($0, low: -1.5, high: 2.25, into: $2, count: count) },
        ]
        let accelerated: [Operation] = [
            { Vector.Accelerated.scale($0, by: 0.37, into: $2, count: count) },
            { Vector.Accelerated.add($0, $1, into: $2, count: count) },
            { Vector.Accelerated.subtract($0, $1, into: $2, count: count) },
            { Vector.Accelerated.multiply($0, $1, into: $2, count: count) },
            { Vector.Accelerated.clip($0, low: -1.5, high: 2.25, into: $2, count: count) },
        ]
        let automatic: [Operation] = [
            { Vector.scale($0, by: 0.37, into: $2, count: count) },
            { Vector.add($0, $1, into: $2, count: count) },
            { Vector.subtract($0, $1, into: $2, count: count) },
            { Vector.multiply($0, $1, into: $2, count: count) },
            { Vector.clip($0, low: -1.5, high: 2.25, into: $2, count: count) },
        ]
        for (index, (name, expected)) in scalar.enumerated() {
            #expect(withBuffers(a, b, native[index]).1 == expected, "native \(name), \(count)")
            #expect(withBuffers(a, b, accelerated[index]).1 == expected, "accelerate \(name), \(count)")
            #expect(withBuffers(a, b, automatic[index]).1 == expected, "automatic \(name), \(count)")
        }
    }

    @Test func aNaNStaysANaNInEveryImplementationOfClip() {
        let source: [Float] = [.nan, 5, -5, 0.5] + [Float](repeating: 1, count: 600)
        let native = withBuffers(source, source) { a, _, out in Vector.Native.clip(a, low: 0, high: 1, into: out, count: source.count) }.1
        let accelerated = withBuffers(source, source) { a, _, out in Vector.Accelerated.clip(a, low: 0, high: 1, into: out, count: source.count) }.1
        #expect(native[0].isNaN && accelerated[0].isNaN)
        #expect(Array(native[1...]) == Array(accelerated[1...]))
        #expect(Array(native[1 ... 3]) == [1, 0, 0.5])
    }

    @Test func operationsWorkInPlace() {
        let (a, b) = signals(700)
        for count in [40, 700] {
            var inPlace = Array(a.prefix(count))
            inPlace.withUnsafeMutableBufferPointer { buffer in
                Vector.scale(UnsafePointer(buffer.baseAddress!), by: 2, into: buffer.baseAddress!, count: count)
            }
            #expect(inPlace == a.prefix(count).map { $0 * 2 })
            var sum = Array(a.prefix(count))
            sum.withUnsafeMutableBufferPointer { buffer in
                b.withUnsafeBufferPointer { other in
                    Vector.add(UnsafePointer(buffer.baseAddress!), other.baseAddress!, into: buffer.baseAddress!, count: count)
                }
            }
            #expect(sum == zip(a.prefix(count), b.prefix(count)).map { $0 + $1 })
        }
    }

    @Test func aCountOfZeroOrLessDoesNothing() {
        var out: [Float] = [9, 9]
        let source: [Float] = [1, 2]
        out.withUnsafeMutableBufferPointer { buffer in
            source.withUnsafeBufferPointer { input in
                for count in [0, -4] {
                    Vector.Native.scale(input.baseAddress!, by: 3, into: buffer.baseAddress!, count: count)
                    Vector.Accelerated.scale(input.baseAddress!, by: 3, into: buffer.baseAddress!, count: count)
                    Vector.Accelerated.add(input.baseAddress!, input.baseAddress!, into: buffer.baseAddress!, count: count)
                    Vector.Accelerated.subtract(input.baseAddress!, input.baseAddress!, into: buffer.baseAddress!, count: count)
                    Vector.Accelerated.multiply(input.baseAddress!, input.baseAddress!, into: buffer.baseAddress!, count: count)
                    Vector.Accelerated.clip(input.baseAddress!, low: 0, high: 1, into: buffer.baseAddress!, count: count)
                }
            }
        }
        #expect(out == [9, 9])
    }

    @Test func everyImplementationIsAllocationFree() throws {
        let a = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 2_048, seed: 1))
        let b = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 2_048, seed: 2))
        let out = try AlignedBuffer<Float>(count: 2_048)
        let pa = UnsafePointer(a.baseAddress), pb = UnsafePointer(b.baseAddress), po = out.baseAddress
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                let count = round % 2 == 0 ? 64 : 2_048
                Vector.scale(pa, by: 0.5, into: po, count: count)
                Vector.add(pa, pb, into: po, count: count)
                Vector.subtract(pa, pb, into: po, count: count)
                Vector.multiply(pa, pb, into: po, count: count)
                Vector.clip(pa, low: -0.5, high: 0.5, into: po, count: count)
                Vector.Native.scale(pa, by: 0.5, into: po, count: count)
                Vector.Accelerated.scale(pa, by: 0.5, into: po, count: count)
                round += 1
            }
        }
    }
}

@Suite("Vector, reductions (WP-114)")
struct VectorReductionTests {
    @Test(arguments: lengths)
    func implementationsAgreeWithinTenToTheMinusSix(count: Int) {
        let a = TestSignal.whiteNoise(count: count, seed: 114, amplitude: 2).map { $0 + 0.75 }
        let b = TestSignal.whiteNoise(count: count, seed: 1_140, amplitude: 2).map { $0 + 0.5 }
        // References in double precision.
        let sum = a.reduce(0.0) { $0 + Double($1) }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let meanSquare = count == 0 ? 0 : a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(count)
        let minimum = Double(a.min() ?? 0), maximum = Double(a.max() ?? 0)
        let magnitude = a.reduce(0.0) { $0 + abs(Double($1)) } + 1e-30
        let dotMagnitude = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) * Double($1.1)) } + 1e-30

        func check(_ name: String, _ value: Float, _ reference: Double, scale: Double) {
            #expect(abs(Double(value) - reference) <= 1e-6 * scale, "\(name) of \(count): \(value) against \(reference)")
        }
        _ = withBuffers(a, b) { pa, pb, _ in
            check("native sum", Vector.Native.sum(pa, count: count), sum, scale: magnitude)
            check("SIMD sum", Vector.Native.sumSIMD(pa, count: count), sum, scale: magnitude)
            check("vDSP sum", Vector.Accelerated.sum(pa, count: count), sum, scale: magnitude)
            check("automatic sum", Vector.sum(pa, count: count), sum, scale: magnitude)

            check("native dot", Vector.Native.dot(pa, pb, count: count), dot, scale: dotMagnitude)
            check("SIMD dot", Vector.Native.dotSIMD(pa, pb, count: count), dot, scale: dotMagnitude)
            check("vDSP dot", Vector.Accelerated.dot(pa, pb, count: count), dot, scale: dotMagnitude)
            check("automatic dot", Vector.dot(pa, pb, count: count), dot, scale: dotMagnitude)

            check("native mean square", Vector.Native.meanSquare(pa, count: count), meanSquare, scale: max(meanSquare, 1e-30))
            check("SIMD mean square", Vector.Native.meanSquareSIMD(pa, count: count), meanSquare, scale: max(meanSquare, 1e-30))
            check("vDSP mean square", Vector.Accelerated.meanSquare(pa, count: count), meanSquare, scale: max(meanSquare, 1e-30))
            check("automatic mean square", Vector.meanSquare(pa, count: count), meanSquare, scale: max(meanSquare, 1e-30))

            // Extremes are selections, not sums: they are exact.
            for (name, value) in [("native", Vector.Native.minimum(pa, count: count)), ("SIMD", Vector.Native.minimumSIMD(pa, count: count)),
                                  ("vDSP", Vector.Accelerated.minimum(pa, count: count)), ("automatic", Vector.minimum(pa, count: count))] {
                #expect(Double(value) == minimum, "\(name) minimum of \(count)")
            }
            for (name, value) in [("native", Vector.Native.maximum(pa, count: count)), ("SIMD", Vector.Native.maximumSIMD(pa, count: count)),
                                  ("vDSP", Vector.Accelerated.maximum(pa, count: count)), ("automatic", Vector.maximum(pa, count: count))] {
                #expect(Double(value) == maximum, "\(name) maximum of \(count)")
            }
        }
    }

    @Test func emptyVectorsReduceToZeroNotNaN() {
        let value: [Float] = [3]
        value.withUnsafeBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            for count in [0, -1] {
                #expect(Vector.sum(pointer, count: count) == 0 && Vector.dot(pointer, pointer, count: count) == 0)
                #expect(Vector.meanSquare(pointer, count: count) == 0)
                #expect(Vector.minimum(pointer, count: count) == 0 && Vector.maximum(pointer, count: count) == 0)
                #expect(Vector.Accelerated.meanSquare(pointer, count: count) == 0 && Vector.Native.meanSquareSIMD(pointer, count: count) == 0)
                #expect(Vector.Accelerated.minimum(pointer, count: count) == 0 && Vector.Accelerated.maximum(pointer, count: count) == 0)
                #expect(Vector.Accelerated.sum(pointer, count: count) == 0 && Vector.Accelerated.dot(pointer, pointer, count: count) == 0)
                #expect(Vector.Native.minimumSIMD(pointer, count: count) == 0 && Vector.Native.maximumSIMD(pointer, count: count) == 0)
            }
            #expect(Vector.sum(pointer, count: 1) == 3 && Vector.meanSquare(pointer, count: 1) == 9)
        }
    }

    @Test func everyReductionIsAllocationFree() throws {
        let a = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 2_048, seed: 3))
        let pa = UnsafePointer(a.baseAddress)
        expectNoAllocations {
            var round = 0
            var total: Float = 0
            while round < 1_000 {
                // No array literal here: it would allocate, and the audit covers this loop too.
                let count = round % 3 == 0 ? 9 : (round % 3 == 1 ? 40 : 2_048)
                total += Vector.sum(pa, count: count) + Vector.dot(pa, pa, count: count) + Vector.meanSquare(pa, count: count)
                total += Vector.minimum(pa, count: count) + Vector.maximum(pa, count: count)
                round += 1
            }
            Benchmark.blackHole(total)
        }
    }
}

@Suite("Implementation and CrossoverTable (WP-115)")
struct CrossoverTableTests {
    @Test func theShippedTableHoldsTheInitialValuesOfTheSpecification() {
        let table = CrossoverTable.shipped
        #expect(table.elementwise == 512 && table.reductionSIMD == 16 && table.reductionAccelerate == 64)
        #expect(table.laneExchange == 1_024 && table.gainKernel == 512 && table.biquadKernel == 4 && table.firPartitioned == 256)
        #expect(table.polynomialClosedForm == 2)
        #expect(table.elementwise == Vector.Crossover.elementwise && table.reductionSIMD == Vector.Crossover.reductionSIMD)
        #expect(table.reductionAccelerate == Vector.Crossover.reductionAccelerate, "one source for the inlined constants and the table")
    }

    @Test func automaticFollowsTheTable() {
        let table = CrossoverTable.shipped
        #expect(table.implementation(for: .elementwise, size: 511) == .native)
        #expect(table.implementation(for: .elementwise, size: 512) == .accelerate)
        #expect(table.implementation(for: .reduction, size: 63) == .native)
        #expect(table.implementation(for: .reduction, size: 64) == .accelerate)
        #expect(!table.reductionUsesSIMD(count: 15) && table.reductionUsesSIMD(count: 16))
        #expect(table.implementation(for: .laneExchange, size: 1_023) == .native && table.implementation(for: .laneExchange, size: 1_024) == .accelerate)
        #expect(table.implementation(for: .gainKernel, size: 256) == .native && table.implementation(for: .gainKernel, size: 512) == .accelerate)
        #expect(table.implementation(for: .biquadKernel, size: 3) == .native && table.implementation(for: .biquadKernel, size: 4) == .accelerate)
        #expect(table.implementation(for: .fir, size: 255) == .native && table.implementation(for: .fir, size: 256) == .accelerate)
        #expect(table.implementation(for: .polynomialRoots, size: 2) == .native && table.implementation(for: .polynomialRoots, size: 3) == .accelerate)
        #expect(table.implementation(for: .melProjection, size: 128 * 1_025) == .native)
        #expect(table.implementation(for: .median, size: 31 * 1_025 * 100) == .native)

        let measured = CrossoverTable(elementwise: 100, reductionSIMD: 4, reductionAccelerate: 20, melDense: 1_000, medianGPU: 5_000)
        #expect(measured.implementation(for: .elementwise, size: 100) == .accelerate, "a measured table is followed")
        #expect(measured.implementation(for: .reduction, size: 19) == .native && measured.reductionUsesSIMD(count: 4))
        #expect(measured.implementation(for: .melProjection, size: 1_000) == .accelerate)
        #expect(measured.implementation(for: .median, size: 5_000) == .metal)
        #expect(measured.gainKernel == 512, "values that were not passed keep their shipped figures")
    }

    @Test func aForcedChoiceIsHonouredWhereThePrimitiveHasIt() {
        let table = CrossoverTable.shipped
        for primitive in Primitive.allCases {
            #expect(table.implementation(for: primitive, size: 1 << 30, requested: .native) == .native, "\(primitive)")
            #expect(table.implementation(for: primitive, size: 1, requested: .automatic) != .automatic, "the answer is never .automatic")
        }
        #expect(table.implementation(for: .elementwise, size: 4, requested: .accelerate) == .accelerate)
        #expect(table.implementation(for: .gainKernel, size: 4, requested: .accelerate) == .accelerate)
        // Only the median has a GPU implementation: elsewhere a forced .metal stays automatic (SEL-2).
        #expect(table.implementation(for: .elementwise, size: 4, requested: .metal) == .native)
        #expect(table.implementation(for: .elementwise, size: 4_096, requested: .metal) == .accelerate)
        #expect(table.implementation(for: .median, size: 4, requested: .metal) == .metal)
        // The median has no Accelerate implementation: a forced .accelerate keeps it on the CPU.
        #expect(table.implementation(for: .median, size: 1 << 30, requested: .accelerate) == .native)
        #expect(table.implementation(for: .median, size: 4, requested: .accelerate) == .native)
    }

    @Test func theConvolutionCostModelPrefersTheFFTForLongInputs() {
        let table = CrossoverTable.shipped
        #expect(!table.convolutionUsesFFT(16, 5))
        #expect(!table.convolutionUsesFFT(48_000, 3), "a short kernel is cheaper directly, whatever the signal")
        #expect(table.convolutionUsesFFT(1_024, 255))
        #expect(table.convolutionUsesFFT(48_000, 4_096))
        #expect(!table.convolutionUsesFFT(0, 10) && !table.convolutionUsesFFT(10, 0))
    }

    @Test func aTableIsCodableAndEquatable() throws {
        let table = CrossoverTable(elementwise: 300, convolutionFFTFactor: 2.5)
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(CrossoverTable.self, from: data)
        #expect(decoded == table)
        #expect(decoded != .shipped)
        #expect(CrossoverTable() == .shipped)
        #expect(Set([table, decoded, .shipped]).count == 2)
        #expect(try JSONDecoder().decode(Implementation.self, from: Data("\"accelerate\"".utf8)) == .accelerate)
        #expect(Implementation.allCases.count == 4 && BiquadPrecision.allCases.count == 3 && Primitive.allCases.count == 9)
    }

    @Test func boundPrimitivesFollowTheChoiceMadeForTheirLength() throws {
        let small = Vector.Bound(count: 32)
        #expect(small.elementwise == .native && small.reduction == .native && small.reductionUsesSIMD && small.count == 32)
        let tiny = Vector.Bound(count: 8)
        #expect(!tiny.reductionUsesSIMD)
        let large = Vector.Bound(count: 4_096)
        #expect(large.elementwise == .accelerate && large.reduction == .accelerate)
        #expect(Vector.Bound(count: 4_096, implementation: .native).elementwise == .native)
        #expect(Vector.Bound(count: 8, implementation: .accelerate).reduction == .accelerate)
        #expect(Vector.Bound(count: 8, implementation: .metal).elementwise == .native, "no GPU implementation: automatic")
        #expect(Vector.Bound(count: 100, crossovers: CrossoverTable(elementwise: 50)).elementwise == .accelerate)

        // Whatever they are bound to, they compute the same thing.
        let a = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 4_096, seed: 5).map { $0 + 1.5 })
        let b = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 4_096, seed: 6))
        let out = try AlignedBuffer<Float>(count: 4_096)
        let reference = try AlignedBuffer<Float>(count: 4_096)
        let pa = UnsafePointer(a.baseAddress), pb = UnsafePointer(b.baseAddress)
        for bound in [tiny, small, large, Vector.Bound(count: 4_096, implementation: .native), Vector.Bound(count: 8, implementation: .accelerate)] {
            let n = bound.count
            bound.scale(pa, 0.25, out.baseAddress, n); Vector.Native.scale(pa, by: 0.25, into: reference.baseAddress, count: n)
            #expect(Array(out.buffer.prefix(n)) == Array(reference.buffer.prefix(n)))
            bound.add(pa, pb, out.baseAddress, n); Vector.Native.add(pa, pb, into: reference.baseAddress, count: n)
            #expect(Array(out.buffer.prefix(n)) == Array(reference.buffer.prefix(n)))
            bound.subtract(pa, pb, out.baseAddress, n); Vector.Native.subtract(pa, pb, into: reference.baseAddress, count: n)
            #expect(Array(out.buffer.prefix(n)) == Array(reference.buffer.prefix(n)))
            bound.multiply(pa, pb, out.baseAddress, n); Vector.Native.multiply(pa, pb, into: reference.baseAddress, count: n)
            #expect(Array(out.buffer.prefix(n)) == Array(reference.buffer.prefix(n)))
            bound.clip(pa, 1, 2, out.baseAddress, n); Vector.Native.clip(pa, low: 1, high: 2, into: reference.baseAddress, count: n)
            #expect(Array(out.buffer.prefix(n)) == Array(reference.buffer.prefix(n)))
            expectClose(bound.sum(pa, n), Vector.Native.sum(pa, count: n), .relative(1e-5))
            expectClose(bound.dot(pa, pb, n), Vector.Native.dot(pa, pb, count: n), .absolute(1e-3))
            expectClose(bound.meanSquare(pa, n), Vector.Native.meanSquare(pa, count: n), .relative(1e-5))
            #expect(bound.minimum(pa, n) == Vector.Native.minimum(pa, count: n))
            #expect(bound.maximum(pa, n) == Vector.Native.maximum(pa, count: n))
        }
    }

    @Test func boundPrimitivesAreAllocationFreeOnTheHotPath() throws {
        let a = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 512, seed: 5))
        let out = try AlignedBuffer<Float>(count: 512)
        let pa = UnsafePointer(a.baseAddress), po = out.baseAddress
        let bounds = [Vector.Bound(count: 8), Vector.Bound(count: 32), Vector.Bound(count: 512)]
        // The first call of each function value may instantiate metadata: warm up, then audit the steady state.
        for bound in bounds { bound.scale(pa, 0.5, po, bound.count); _ = bound.sum(pa, bound.count) }
        expectNoAllocations {
            var round = 0
            var total: Float = 0
            while round < 1_000 {
                let bound = bounds[round % 3]
                bound.scale(pa, 0.5, po, bound.count)
                bound.add(pa, pa, po, bound.count)
                bound.clip(pa, -0.1, 0.1, po, bound.count)
                total += bound.sum(pa, bound.count) + bound.dot(pa, pa, bound.count) + bound.maximum(pa, bound.count)
                round += 1
            }
            Benchmark.blackHole(total)
        }
    }
}

@Suite("Padding and transform lengths (WP-116)")
struct PaddingTests {
    /// The documented lengths, written out independently of the rule under test (E-09).
    private var documented: Set<Int> {
        var result = Set<Int>()
        for factor in [1, 3, 5, 15] {
            var power = 16
            while factor * power <= 4_096 {
                result.insert(factor * power)
                power *= 2
            }
        }
        return result
    }

    @Test func theRuleMatchesTheDocumentedLengthsUpTo4096() {
        let expected = documented
        for length in -4 ... 4_096 {
            #expect(DSP.isFastLength(length) == expected.contains(length), "\(length)")
        }
        #expect(expected.count == 27, "9 powers of two, 7 of 3·2ⁿ, 6 of 5·2ⁿ, 5 of 15·2ⁿ")
        for length in [16, 48, 80, 240, 1_024, 4_096, 64, 128] { #expect(DSP.isFastLength(length)) }
        for length in [0, 1, 2, 8, 12, 18, 20, 24, 26, 30, 40, 1_000, 3_072 + 1] { #expect(!DSP.isFastLength(length), "\(length)") }
        #expect(DSP.isFastLength(3_072), "complex 3 072 of E-07 is 3 · 2¹⁰")
        #expect(DSP.isFastLength(65_536) && DSP.isFastLength(15 << 20) && !DSP.isFastLength(7 << 10))
    }

    @Test func theRuleIsArithmeticAndCreatesNothing() {
        // A transform setup allocates; the rule must not (E-09: a setup is never created to find out).
        expectNoAllocations {
            var length = 1
            var admitted = 0
            while length <= 4_096 {
                if DSP.isFastLength(length) { admitted += 1 }
                length += 1
            }
            Benchmark.blackHole(admitted)
        }
    }

    /// The other direction: every length the rule admits is one vDSP really accepts. Setups are
    /// created for admitted lengths only, which is what the rule exists to guarantee.
    @Test func everyAdmittedLengthHasATransformSetup() {
        for length in documented.sorted() {
            let real = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(length), .FORWARD)
            #expect(real != nil, "real DFT of \(length)")
            if let real { vDSP_DFT_DestroySetup(real) }
            let cosine = vDSP_DCT_CreateSetup(nil, vDSP_Length(length), .II)
            #expect(cosine != nil, "DCT-II of \(length)")
            if let cosine { vDSP_DFT_DestroySetup(cosine) }
        }
    }

    @Test func nextAndPreviousFastLengths() {
        #expect(DSP.nextFastLength(-5) == 16 && DSP.nextFastLength(0) == 16 && DSP.nextFastLength(16) == 16)
        #expect(DSP.nextFastLength(17) == 32 && DSP.nextFastLength(33) == 48 && DSP.nextFastLength(49) == 64)
        #expect(DSP.nextFastLength(1_000) == 1_024 && DSP.nextFastLength(1_025) == 1_280 && DSP.nextFastLength(2_047) == 2_048)
        #expect(DSP.nextFastLength(4_097) == 5_120)
        #expect(DSP.previousFastLength(15) == nil && DSP.previousFastLength(16) == 16 && DSP.previousFastLength(1_000) == 960)
        #expect(DSP.previousFastLength(4_095) == 3_840 && DSP.previousFastLength(47) == 32)
        let expected = documented.sorted()
        for length in 1 ... 4_096 {
            let next = DSP.nextFastLength(length)
            #expect(next == expected.first { $0 >= length }, "next of \(length)")
            #expect(DSP.isFastLength(next))
            #expect(DSP.previousFastLength(length) == expected.last { $0 <= length }, "previous of \(length)")
        }
    }

    @Test func paddingMatchesItsDefinitionForBothPlacements() {
        let samples: [Float] = [1, 2, 3, 4, 5]
        #expect(zeroPadded(samples, to: 8) == [1, 2, 3, 4, 5, 0, 0, 0])
        #expect(zeroPadded(samples, to: 8, placement: .centered) == [0, 1, 2, 3, 4, 5, 0, 0], "⌊3 / 2⌋ zeros before, the rest after")
        #expect(zeroPadded(samples, to: 9, placement: .centered) == [0, 0, 1, 2, 3, 4, 5, 0, 0])
        #expect(zeroPadded(samples, to: 5) == samples && zeroPadded(samples, to: 3) == samples && zeroPadded(samples, to: -1) == samples)
        #expect(zeroPadded([Float](), to: 3) == [0, 0, 0])
        #expect(zeroPadded([1.5, 2.5], to: 4) == [1.5, 2.5, 0, 0], "generic over the element")
        #expect(zeroPadded([Complex(1, 2)].map(\.real), to: 2) == [1, 0])

        // The pointer form against the array form, over a grid.
        var generator = SeededGenerator(seed: 116)
        for _ in 0 ..< 100 {
            let count = Int(generator.next() % 40)
            let padded = count + Int(generator.next() % 40)
            let source = TestSignal.whiteNoise(count: count, seed: generator.next())
            for placement in [ZeroPadding.trailing, .centered] {
                var destination = [Float](repeating: .nan, count: max(padded, 1))
                source.withUnsafeBufferPointer { input in
                    destination.withUnsafeMutableBufferPointer { output in
                        zeroPad(input.baseAddress ?? UnsafePointer(output.baseAddress!), count: count, into: output.baseAddress!, paddedCount: padded, placement: placement)
                    }
                }
                #expect(Array(destination.prefix(padded)) == zeroPadded(source, to: padded, placement: placement), "\(count) → \(padded), \(placement)")
            }
        }
    }

    @Test func thePointerFormNeverWritesPastItsDestination() {
        let source: [Float] = [1, 2, 3, 4]
        var destination: [Float] = [9, 9, 9]
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { output in
                zeroPad(input.baseAddress!, count: 4, into: output.baseAddress!, paddedCount: 2)
                zeroPad(input.baseAddress!, count: 4, into: output.baseAddress!, paddedCount: 0)
                zeroPad(input.baseAddress!, count: -2, into: output.baseAddress! + 2, paddedCount: 1)
            }
        }
        #expect(destination == [1, 2, 0])
    }
}

@Suite("Rate hooks (WP-117)")
struct RateChangeTests {
    @Test func subsamplingKeepsEveryMthSample() {
        let samples = (0 ..< 10).map(Float.init)
        #expect(subsampled(samples, by: 3) == [0, 3, 6, 9])
        #expect(subsampled(samples, by: 3, phase: 1) == [1, 4, 7])
        #expect(subsampled(samples, by: 3, phase: 2) == [2, 5, 8])
        #expect(subsampled(samples, by: 3, phase: 4) == [1, 4, 7], "a phase is wrapped into 0 ..< factor")
        #expect(subsampled(samples, by: 3, phase: -1) == [2, 5, 8])
        #expect(subsampled(samples, by: 1) == samples && subsampled(samples, by: 0) == samples && subsampled(samples, by: -2) == samples)
        #expect(subsampled(samples, by: 100) == [0] && subsampled(samples, by: 100, phase: 50).isEmpty)
        #expect(subsampled([Float](), by: 2).isEmpty)
        #expect(subsampled(["a", "b", "c"], by: 2) == ["a", "c"], "any element")
    }

    @Test func upsamplingInsertsZeros() {
        #expect(upsampled([1, 2, 3] as [Float], by: 3) == [1, 0, 0, 2, 0, 0, 3, 0, 0])
        #expect(upsampled([1, 2] as [Float], by: 1) == [1, 2] && upsampled([1, 2] as [Float], by: 0) == [1, 2])
        #expect(upsampled([Float](), by: 4).isEmpty)
        #expect(upsampled([1.5, 2.5], by: 2) == [1.5, 0, 2.5, 0])
    }

    @Test func upThenDownByOneFactorIsTheIdentityBitForBit() {
        let samples = TestSignal.whiteNoise(count: 1_000, seed: 117)
        for factor in 1 ... 9 {
            #expect(subsampled(upsampled(samples, by: factor), by: factor) == samples, "factor \(factor)")
        }
    }

    @Test func thePointerFormsMatchTheArrayFormsAcrossIrregularBlocks() {
        let samples = TestSignal.whiteNoise(count: 1_000, seed: 1_170)
        var generator = SeededGenerator(seed: 1_171)
        for factor in [1, 2, 3, 5, 8] {
            var phase = 0
            var kept: [Float] = []
            var position = 0
            var destination = [Float](repeating: 0, count: 64)
            while position < samples.count {
                let block = min(Int(generator.next() % 37), samples.count - position)   // blocks of 0 … 36 samples
                samples.withUnsafeBufferPointer { input in
                    destination.withUnsafeMutableBufferPointer { output in
                        let result = subsample(input.baseAddress! + position, count: block, by: factor, phase: phase, into: output.baseAddress!)
                        kept.append(contentsOf: output.prefix(result.written))
                        phase = result.nextPhase
                    }
                }
                position += block
            }
            #expect(kept == subsampled(samples, by: factor), "factor \(factor): the phase is carried across blocks")

            var stuffed = [Float](repeating: .nan, count: samples.count * factor)
            samples.withUnsafeBufferPointer { input in
                stuffed.withUnsafeMutableBufferPointer { output in
                    upsample(input.baseAddress!, count: samples.count, by: factor, into: output.baseAddress!)
                }
            }
            #expect(stuffed == upsampled(samples, by: factor))
        }
    }

    @Test func thePointerFormsAreAllocationFree() throws {
        let source = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 512, seed: 9))
        let destination = try AlignedBuffer<Float>(count: 2_048)
        expectNoAllocations {
            var round = 0
            var phase = 0
            while round < 1_000 {
                let result = subsample(UnsafePointer(source.baseAddress), count: 509, by: 3, phase: phase, into: destination.baseAddress)
                phase = result.nextPhase
                upsample(UnsafePointer(source.baseAddress), count: 512, by: 4, into: destination.baseAddress)
                round += 1
            }
        }
    }
}
