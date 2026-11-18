import Foundation
import Testing
@testable import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPTesting

/// The transform backend (WP-502): the unscaled one-sided DFT and its exact inverse, on the
/// lengths the rule admits and on no other.
@Suite("FFT backend")
struct TransformTests {
    private func transform(_ signal: [Float], backend: some FFTBackend = .vDSP) throws -> (real: [Float], imaginary: [Float]) {
        let plan = try backend.makePlan(length: signal.count)
        var real = [Float](repeating: -1, count: plan.binCount), imaginary = real
        signal.withUnsafeBufferPointer { source in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in plan.forward(source.baseAddress!, real: re.baseAddress!, imaginary: im.baseAddress!) }
            }
        }
        return (real, imaginary)
    }

    private func inverse(real: [Float], imaginary: [Float], length: Int) throws -> [Float] {
        let plan = try VDSPFFTBackend().makePlan(length: length)
        var signal = [Float](repeating: -1, count: length)
        real.withUnsafeBufferPointer { re in
            imaginary.withUnsafeBufferPointer { im in
                signal.withUnsafeMutableBufferPointer { plan.inverse(real: re.baseAddress!, imaginary: im.baseAddress!, into: $0.baseAddress!) }
            }
        }
        return signal
    }

    // MARK: Parity with the definition (§6.1)

    @Test(arguments: [16, 32, 48, 64])
    func theForwardTransformIsTheUnscaledDFT(length: Int) throws {
        let signal = TestSignal.whiteNoise(count: length, seed: UInt64(length), amplitude: 0.8)
        let expected = naiveDFT(signal.map(Double.init))
        let spectrum = try transform(signal)
        #expect(spectrum.real.count == length / 2 + 1, "a spectrum is one-sided: N / 2 + 1 bins")
        let deviation = complexDeviation(spectrum.real, spectrum.imaginary, expected.real, expected.imaginary)
        #expect(deviation < 1e-6, "no library factor survives: X[k] = Σ x[n]·e^(−j2πkn/N); deviation \(deviation) of the frame maximum")
        #expect(spectrum.imaginary[0] == 0 && spectrum.imaginary[length / 2] == 0, "the first and the last bin of a real signal are real")
    }

    @Test func aConstantAndTheNyquistSignalLandInTheirBins() throws {
        let constant = try transform(TestSignal.constant(0.5, count: 48))
        #expect(constant.real[0] == 24, "Σ x[n], unscaled")
        #expect(constant.real.dropFirst().allSatisfy { abs($0) < 1e-5 })
        let fastest = try transform(TestSignal.nyquist(count: 80, amplitude: 0.25))
        #expect(fastest.real[40] == 20, "the Nyquist bin holds Σ x[n]·(−1)ⁿ")
        #expect(fastest.real.dropLast().allSatisfy { abs($0) < 1e-5 })
    }

    @Test(arguments: [16, 48, 80, 240, 1_024, 4_096])
    func theTransformEqualsTheGoldenVectors(length: Int) throws {
        let golden = try GoldenFile(named: "fft", in: .module).require("rfft-\(length)")
        let signal = try golden.floats("signal")
        let expected = try golden.complex("spectrum")
        let spectrum = try transform(signal)
        let deviation = complexDeviation(spectrum.real, spectrum.imaginary, expected.real, expected.imaginary)
        #expect(deviation < 1e-5, "numpy.fft.rfft, length \(length): \(deviation) of the frame maximum")

        // The inverse of the oracle's spectrum is the oracle's inverse, and the signal.
        let back = try inverse(real: expected.real.map { Float($0) }, imaginary: expected.imaginary.map { Float($0) }, length: length)
        expectClose(back, try golden.real("inverse"), .relativeToMaximum(1e-5))
        expectClose(back, signal, .relativeToMaximum(1e-5))
    }

    @Test(arguments: [16, 240, 4_096])
    func theInverseUndoesTheForwardTransform(length: Int) throws {
        let signal = TestSignal.gaussianNoise(count: length, seed: 9, standardDeviation: 0.3)
        let spectrum = try transform(signal)
        let back = try inverse(real: spectrum.real, imaginary: spectrum.imaginary, length: length)
        expectClose(back, signal, .deviationBelow(decibels: -120))
    }

    @Test func theInverseReadsNoImaginaryPartOfTheEndBins() throws {
        var spectrum = try transform(TestSignal.whiteNoise(count: 32, seed: 3))
        let clean = try inverse(real: spectrum.real, imaginary: spectrum.imaginary, length: 32)
        spectrum.imaginary[0] = 7
        spectrum.imaginary[16] = -3
        #expect(try inverse(real: spectrum.real, imaginary: spectrum.imaginary, length: 32) == clean)
    }

    // MARK: Lengths (O-17, E-09)

    @Test func lengthsAreAdmittedByArithmeticOnly() {
        let backend = VDSPFFTBackend()
        #expect([16, 32, 48, 80, 96, 240, 1_024, 3_072, 3_840, 65_536].allSatisfy { backend.supports(length: $0) })
        #expect([0, 1, 8, 12, 18, 24, 26, 30, 40, 100, 1_000, 2_047, 4_097].allSatisfy { !backend.supports(length: $0) })
        #expect(VDSPFFTBackend() == .vDSP && AnyStrategy(VDSPFFTBackend()) == AnyStrategy(VDSPFFTBackend.vDSP))
    }

    @Test(arguments: [-4, 0, 1, 8, 18, 26, 30, 40, 1_000, 2_047])
    func anIllegalLengthIsATypedErrorAndNoSetupIsCreatedForIt(length: Int) {
        let observed = Observed()
        TransformSetup.$observer.withValue({ _, length in observed.note(length) }) {
            #expect(throws: DSPError.self) { _ = try VDSPFFTBackend().makePlan(length: length) }
            #expect(throws: DSPError.self) { _ = try DSP.realDFT([Double](repeating: 0, count: max(length, 0))) }
        }
        #expect(observed.lengths.isEmpty, "the rule is applied by arithmetic: no setup call is made for \(length)")
    }

    @Test func theErrorOfAnIllegalLengthNamesTheNearestLegalOnes() {
        let message = errorMessage { _ = try VDSPFFTBackend().makePlan(length: 1_000) }
        #expect(message?.contains("960") == true && message?.contains("1024") == true, "\(message ?? "no error")")
    }

    @Test func aLegalLengthCreatesItsSetups() throws {
        let observed = Observed()
        try TransformSetup.$observer.withValue({ _, length in observed.note(length) }) {
            _ = try VDSPFFTBackend().makePlan(length: 48)
        }
        #expect(observed.lengths == [48], "the control case of the observer")
    }

    // MARK: The one-shot functions

    @Test func theOneShotTransformsAreDoublePrecision() throws {
        let signal = (0 ..< 240).map { sin(Double($0) * 0.31) + 0.25 * cos(Double($0) * 1.7) - 0.1 }
        let spectrum = try DSP.realDFT(signal)
        let expected = naiveDFT(signal)
        expectClose(spectrum.real, expected.real, .relativeToMaximum(1e-13))
        expectClose(spectrum.imaginary, expected.imaginary, .relativeToMaximum(1e-13))
        expectClose(try DSP.inverseRealDFT(real: spectrum.real, imaginary: spectrum.imaginary), signal, .relativeToMaximum(1e-14))
        #expect(throws: DSPError.self) { _ = try DSP.inverseRealDFT(real: [1, 2, 3], imaginary: [0, 0]) }
        #expect(throws: DSPError.self) { _ = try DSP.inverseRealDFT(real: [1, 2, 3], imaginary: [0, 0, 0]) }
    }

    // MARK: The real-time audit (RT-7)

    @Test func aPlanTransformsWithoutAllocating() throws {
        let plan = try VDSPFFTBackend().makePlan(length: 4_096)
        let signal = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 4_096, seed: 1))
        let real = try AlignedBuffer<Float>(count: 2_049), imaginary = try AlignedBuffer<Float>(count: 2_049)
        let back = try AlignedBuffer<Float>(count: 4_096)
        plan.forward(signal.baseAddress, real: real.baseAddress, imaginary: imaginary.baseAddress)
        _ = expectNoAllocations {
            var pass = 0
            while pass < 1_000 {
                plan.forward(signal.baseAddress, real: real.baseAddress, imaginary: imaginary.baseAddress)
                plan.inverse(real: real.baseAddress, imaginary: imaginary.baseAddress, into: back.baseAddress)
                pass += 1
            }
        }
        expectClose(back.array, signal.array, .deviationBelow(decibels: -120))
    }

    @Test func buffersNeedNotBeAligned() throws {
        // The transform works on the plan's own aligned buffers, whatever it is handed.
        let plan = try VDSPFFTBackend().makePlan(length: 64)
        let storage = try AlignedBuffer<Float>(count: 64 + 1 + 2 * 34)
        let signal = TestSignal.whiteNoise(count: 64, seed: 4)
        for (index, value) in signal.enumerated() { (storage.baseAddress + 1)[index] = value }
        let real = storage.baseAddress + 66, imaginary = storage.baseAddress + 100
        plan.forward(storage.baseAddress + 1, real: real, imaginary: imaginary)
        let expected = try transform(signal)
        #expect(Array(UnsafeBufferPointer(start: real, count: 33)) == expected.real)
        #expect(Array(UnsafeBufferPointer(start: imaginary, count: 33)) == expected.imaginary)
    }
}

/// What a test hears of the setups created on its task.
final class Observed: @unchecked Sendable {
    // Threading: written and read by the test's own task.
    private(set) var lengths: [Int] = []
    func note(_ length: Int) { lengths.append(length) }
}
