import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("DSPError (WP-106)")
struct DSPErrorTests {
    private let path = StagePath().appending("Tap", index: 3).appending("MelScale", index: 2)

    private var everyCase: [DSPError] {
        [
            .invalidParameter(stage: path, parameter: "bands", reason: "128 bands on a 256-point frame"),
            .invalidStageOrder(stage: path, found: .spectrum(axis: .linear, values: .decibel)),
            .unsupportedConfiguration(reason: "degree 600"),
            .unstableDesign(maxPoleRadius: 1.02),
            .numericalFailure(routine: "dhseqr", info: 3),
            .permissionDenied,
            .sessionConfigurationFailed(reason: "category playback"),
            .sourceUnavailable(reason: "no input"),
            .backendUnavailable(reason: "no Metal device"),
            .resourceAllocationFailed(what: "a DFT setup"),
            .sinkInUse(sink: "HeatmapFeed"),
            .sessionDetached,
            .exportTooLarge(elements: 5_000_000, limit: 4_000_000),
            .cancelled,
        ]
    }

    @Test func everyCaseIsConstructedAndDescribed() {
        let descriptions = everyCase.map(\.description)
        #expect(descriptions.count == 14)
        #expect(Set(descriptions).count == 14, "each case reads differently")
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(descriptions[0] == "Invalid parameter bands: 128 bands on a 256-point frame (at Tap[3] › MelScale[2])")
        #expect(descriptions[1] == "MelScale cannot follow a signal of the domain linear-frequency spectrum in decibels (at Tap[3] › MelScale[2])")
        #expect(descriptions[3].contains("1.02"))
        #expect(descriptions[4].contains("dhseqr") && descriptions[4].contains("3"))
        #expect(descriptions[12].contains("5000000") && descriptions[12].contains("4000000"))
    }

    @Test func errorsRaisedByAStageCarryItsPath() {
        #expect(DSPError.invalidParameter(stage: path, parameter: "p", reason: "r").stage == path)
        #expect(DSPError.invalidParameter(stage: .none, parameter: "p", reason: "r").stage == nil)
        for error in [DSPError.unsupportedConfiguration(reason: "x"), .unstableDesign(maxPoleRadius: 1), .numericalFailure(routine: "r", info: 1),
                      .backendUnavailable(reason: "x"), .resourceAllocationFailed(what: "x"),
                      .invalidParameter(stage: .none, parameter: "p", reason: "r"), .invalidStageOrder(stage: .none, found: .samples)] {
            #expect(error.stage == nil)
            let placed = error.inStage(path)
            #expect(placed.stage == path, "\(error)")
            #expect(placed.description.hasSuffix("(at Tap[3] › MelScale[2])"), "\(placed)")
            #expect(placed.inStage(StagePath().appending("Other", index: 0)) == placed, "the first attribution stands")
            #expect(error.inStage(.none) == error)
        }
        for error in [DSPError.permissionDenied, .sessionConfigurationFailed(reason: "x"), .sourceUnavailable(reason: "x"),
                      .sinkInUse(sink: "x"), .sessionDetached, .exportTooLarge(elements: 1, limit: 0), .cancelled] {
            #expect(error.inStage(path) == error, "\(error) is not raised by a stage")
            #expect(error.stage == nil)
        }
        #expect(DSPError.unstableDesign(maxPoleRadius: 1.5, stage: path).stage == path)
    }

    @Test func errorsAreValues() {
        #expect(DSPError.cancelled == .cancelled)
        #expect(DSPError.unstableDesign(maxPoleRadius: 1) != .unstableDesign(maxPoleRadius: 2))
        #expect(Set(everyCase).count == 14)
        let thrown: any Error = DSPError.sessionDetached
        #expect(thrown as? DSPError == .sessionDetached)
    }

    @Test func pathsDescribeWhereAStageSits() {
        #expect(StagePath.none.isEmpty)
        #expect(StagePath.none.description == "(no stage)")
        #expect(StagePath.none.stageName == nil)
        #expect(path.description == "Tap[3] › MelScale[2]")
        #expect(path.stageName == "MelScale")
        #expect(path.components.count == 2)
        #expect(path.components[0] == StagePath.Component(name: "Tap", index: 3))
        #expect(path == StagePath(components: [.init(name: "Tap", index: 3), .init(name: "MelScale", index: 2)]))
        #expect(path != path.appending("Decibels", index: 3))
    }
}

@Suite("Complex (WP-107)")
struct ComplexTests {
    private func samples() -> [Complex] {
        var generator = SeededGenerator(seed: 107)
        return (0 ..< 200).map { _ in Complex(generator.nextGaussian() * 3, generator.nextGaussian() * 3) }
    }

    private func expectEqual(_ a: Complex, _ b: Complex, _ tolerance: Double, _ message: String = "") {
        let scale = max(1, a.magnitude, b.magnitude)
        #expect((a - b).magnitude <= tolerance * scale, "\(message): \(a) against \(b)")
    }

    @Test func fieldIdentities() {
        let values = samples()
        for index in 0 ..< values.count - 2 {
            let a = values[index], b = values[index + 1], c = values[index + 2]
            #expect(a + b == b + a)
            #expect(a * b == b * a)
            expectEqual((a + b) + c, a + (b + c), 1e-15, "addition associates")
            expectEqual((a * b) * c, a * (b * c), 4e-15, "multiplication associates")
            expectEqual(a * (b + c), a * b + a * c, 4e-15, "multiplication distributes")
            #expect(a + .zero == a)
            #expect(a * .one == a)
            #expect(a - a == .zero)
            expectEqual(a * a.reciprocal, .one, 4e-16, "the reciprocal inverts")
            expectEqual((a * b) / b, a, 4e-15, "division undoes multiplication")
            #expect(-(-a) == a)
            #expect(a.conjugate.conjugate == a)
            expectEqual(a * a.conjugate, Complex(a.squaredMagnitude), 1e-15, "z · z̄ = |z|²")
        }
        #expect(Complex.i * Complex.i == Complex(-1, 0))
    }

    @Test func polarRoundTripIsWithinTenToTheMinusFifteen() {
        for value in samples() {
            let back = Complex(magnitude: value.magnitude, phase: value.phase)
            #expect((back - value).magnitude <= 1e-15 * max(1, value.magnitude), "\(value)")
        }
        var generator = SeededGenerator(seed: 1_070)
        for _ in 0 ..< 200 {
            let magnitude = generator.nextUnit() * 10 + 0.01
            let phase = (generator.nextUnit() * 2 - 1) * .pi * 0.999
            let value = Complex(magnitude: magnitude, phase: phase)
            #expect(abs(value.magnitude - magnitude) <= 1e-15 * magnitude)
            #expect(abs(value.phase - phase) <= 1e-15)
        }
    }

    @Test func mixedRealArithmetic() {
        let z = Complex(3, -4)
        #expect(z + 1 == Complex(4, -4))
        #expect(1 + z == Complex(4, -4))
        #expect(z - 1 == Complex(2, -4))
        #expect(1 - z == Complex(-2, 4))
        #expect(z * 2 == Complex(6, -8))
        #expect(2 * z == Complex(6, -8))
        #expect(z / 2 == Complex(1.5, -2))
        #expect(25 / z == Complex(3, 4))
        #expect(z.magnitude == 5)
        #expect(z.squaredMagnitude == 25)
        #expect(z.conjugate == Complex(3, 4))
        #expect(z.isFinite && !z.isReal)
        #expect(Complex(2).isReal && Complex(2).imaginary == 0)
        #expect(!Complex(.nan, 0).isFinite && !Complex(0, .infinity).isFinite)
    }

    @Test func divisionDoesNotOverflowWhereThePlainFormulaWould() {
        let large = Complex(1e300, 1e300)
        let quotient = large / large
        #expect(abs(quotient.real - 1) < 1e-15 && abs(quotient.imaginary) < 1e-15)
        let mixed = Complex(1e-300, 1e300) / Complex(1e300, 1e-300)
        #expect(mixed.isFinite)
        #expect(!(Complex.one / .zero).isFinite, "division by zero is not finite, and does not trap")
    }

    @Test func elementaryFunctions() {
        expectEqual(Complex.exp(Complex(0, .pi)), Complex(-1, 0), 2e-16, "Euler")
        expectEqual(Complex.exp(.zero), .one, 0)
        for value in samples() {
            expectEqual(Complex.exp(Complex.log(value)), value, 4e-15, "exp undoes log")
            let root = Complex.sqrt(value)
            expectEqual(root * root, value, 4e-15, "the square root squares back")
            #expect(root.real >= 0, "the principal root")
            expectEqual(Complex.pow(value, 3), value * value * value, 1e-14, "a whole power")
            expectEqual(Complex.pow(value, -2), (value * value).reciprocal, 1e-14, "a negative power")
        }
        #expect(Complex.pow(Complex(2, 1), 0) == .one)
        #expect(Complex.sqrt(.zero) == .zero)
        #expect(Complex.sqrt(Complex(-4, 0)) == Complex(0, 2))
        #expect(Complex.sqrt(Complex(-4, -0.0)).imaginary == -2, "the branch cut follows the sign of zero")
        #expect(Complex.sqrt(Complex(4, 0)) == Complex(2, 0))
    }

    @Test func descriptionShowsBothParts() {
        #expect(Complex(1, 2).description == "1.0 + 2.0j")
        #expect(Complex(1, -2).description == "1.0 - 2.0j")
        #expect(Set([Complex(1, 2), Complex(1, 2), Complex(2, 1)]).count == 2)
    }
}
