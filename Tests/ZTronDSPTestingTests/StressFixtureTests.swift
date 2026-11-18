import Foundation
import Testing
import ZTronDSPTesting

@Suite("Stress fixtures")
struct StressFixtureTests {
    /// Horner evaluation in double precision, real coefficients at a complex point.
    private func evaluate(_ coefficients: [Double], re: Double, im: Double) -> (Double, Double) {
        var accRe = 0.0, accIm = 0.0
        for coefficient in coefficients {
            let nextRe = accRe * re - accIm * im + coefficient
            let nextIm = accRe * im + accIm * re
            accRe = nextRe
            accIm = nextIm
        }
        return (accRe, accIm)
    }

    @Test func everyFixtureDocumentsItsHazard() {
        let polynomials = StressFixture.illConditionedPolynomials + StressFixture.wellConditionedPolynomials
        #expect(polynomials.count == 8)
        for fixture in polynomials {
            #expect(!fixture.name.isEmpty)
            #expect(fixture.hazard.count > 20, "\(fixture.name) states its hazard")
            #expect(fixture.rootsReal.count == fixture.degree)
            #expect(fixture.rootsImaginary.count == fixture.degree)
            #expect(fixture.coefficients.first == 1, "\(fixture.name) is monic")
            #expect(fixture.achievableAccuracy > 0)
        }
        for fixture in StressFixture.filtersNearZero + StressFixture.filtersNearNyquist {
            #expect(fixture.hazard.count > 20, "\(fixture.name) states its hazard")
            #expect(fixture.cutoff > 0 && fixture.cutoff < fixture.sampleRate / 2)
            #expect(fixture.order >= 1)
        }
        for fixture in StressFixture.signals(count: 512) {
            #expect(fixture.hazard.count > 20, "\(fixture.name) states its hazard")
            #expect(fixture.samples.count == 512)
            #expect(fixture.samples.allSatisfy { $0.isFinite })
        }
    }

    @Test func wellConditionedPolynomialsVanishAtTheirRoots() {
        for fixture in StressFixture.wellConditionedPolynomials {
            #expect(fixture.largestConditionNumber <= 1e4, "\(fixture.name)")
            #expect(fixture.multiplicity == 1)
            let scale = fixture.coefficients.map(abs).reduce(0, +)
            for (re, im) in zip(fixture.rootsReal, fixture.rootsImaginary) {
                let value = evaluate(fixture.coefficients, re: re, im: im)
                #expect(hypot(value.0, value.1) <= 1e-12 * scale * max(1, pow(hypot(re, im), Double(fixture.degree))), "\(fixture.name) at \(re) + \(im)i")
            }
        }
    }

    @Test func illConditionedPolynomialsCarryTheirDocumentedConditionNumbers() {
        let wilkinson = StressFixture.wilkinson20
        #expect(wilkinson.degree == 20)
        #expect(wilkinson.rootsReal == (1 ... 20).map(Double.init))
        #expect(wilkinson.largestConditionNumber > 1e13)
        #expect(wilkinson.coefficients[1] == -210, "minus the sum of the roots")
        // 20! is not representable: the stored constant term is the rounded value.
        #expect(wilkinson.coefficients[20] == 2_432_902_008_176_640_000)

        let butterworth = StressFixture.butterworth16Expanded
        #expect(butterworth.degree == 16)
        #expect(butterworth.largestConditionNumber > 1e15)
        for (re, im) in zip(butterworth.rootsReal, butterworth.rootsImaginary) {
            #expect(hypot(re, im) < 1, "a stable filter")
            #expect(hypot(re - 1, im) < 0.2, "poles clustered near z = 1")
        }

        let triple = StressFixture.tripleRoot
        #expect(triple.multiplicity == 3)
        #expect(triple.coefficients == [1, -1.25, 0.375, 0.0625, -0.03125])
    }

    @Test func filterFixturesSitAtTheEdgesOfTheBand() {
        for fixture in StressFixture.filtersNearZero {
            #expect(fixture.normalizedAngle < 0.02, "\(fixture.name)")
        }
        for fixture in StressFixture.filtersNearNyquist {
            #expect(fixture.cutoff / fixture.sampleRate >= 0.45, "\(fixture.name)")
        }
    }

    @Test func signalFixturesAreWhatTheySay() {
        let fixtures = Dictionary(uniqueKeysWithValues: StressFixture.signals(count: 1_024).map { ($0.name, $0.samples) })
        #expect(fixtures["silence"]?.allSatisfy { $0 == 0 } == true)
        #expect(fixtures["full-scale-sine"]?.map(abs).max() ?? 0 > 0.999)
        #expect(fixtures["full-scale-square"]?.allSatisfy { abs($0) == 1 } == true)
        #expect(fixtures["dc"]?.allSatisfy { $0 == 1 } == true)
        #expect(fixtures["nyquist"]?[0] == 1 && fixtures["nyquist"]?[1] == -1)
        #expect(fixtures["decaying-tail"]?.last == 0)
        #expect(fixtures["denormal"]?.allSatisfy { $0.isSubnormal } == true)
        #expect(fixtures["impulse"]?.reduce(0, +) == 1)
        #expect(fixtures["white-noise"] == StressFixture.signals(count: 1_024).last?.samples, "seeded")
        #expect(fixtures.count == 9)
    }

    @Test func nonFiniteSignalCountsWhatItInjects() {
        let fixture = StressFixture.nonFiniteSignal(count: 4_096)
        #expect(fixture.nonFiniteCount == 3)
        #expect(fixture.samples.filter { !$0.isFinite }.count == 3)
        #expect(fixture.samples.contains { $0.isNaN })
        let tiny = StressFixture.nonFiniteSignal(count: 1)
        #expect(tiny.samples.count == 1)
        #expect(tiny.nonFiniteCount == tiny.samples.filter { !$0.isFinite }.count)
    }
}
