import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

@Suite("PolynomialRootFinder.companionQR (WP-402)")
struct PolynomialRootFinderTests {
    private let finder = CompanionQRRootFinder()

    private func expected(_ fixture: StressFixture.PolynomialCase) -> [Complex] {
        zip(fixture.rootsReal, fixture.rootsImaginary).map { Complex($0, $1) }
    }

    // MARK: Acceptance: well-conditioned fixtures to 1e-10

    @Test func wellConditionedFixturesAreFoundToTenToTheMinusTen() throws {
        for fixture in StressFixture.wellConditionedPolynomials {
            #expect(fixture.largestConditionNumber <= 1e4)
            let roots = try finder.roots(of: Polynomial(fixture.coefficients))
            expectRootsClose(roots, expected(fixture), relative: fixture.achievableAccuracy, fixture.name,
                             measure: "WP-402 well-conditioned fixtures, relative root error")
            #expect(fixture.achievableAccuracy == 1e-10)
        }
    }

    // MARK: Acceptance: degree 0–2 in closed form

    @Test func degreeZeroHasNoRoots() throws {
        #expect(try finder.roots(of: Polynomial([3.5])).isEmpty)
        #expect(try finder.rootConditions(of: Polynomial([3.5])).isEmpty)
    }

    @Test func degreeOneIsExact() throws {
        #expect(try finder.roots(of: Polynomial([2, -3])) == [Complex(1.5)])
        #expect(try finder.roots(of: Polynomial([-4, 1])) == [Complex(0.25)])
        #expect(try finder.roots(of: Polynomial([7, 0])) == [Complex(0)])
    }

    @Test func degreeTwoUsesTheClosedFormWithoutCancellation() throws {
        // Real and distinct, real and equal, complex.
        expectRootsClose(try finder.roots(of: Polynomial([1, -3, 2])), [Complex(1), Complex(2)], relative: 1e-15, "x² − 3x + 2")
        #expect(try finder.roots(of: Polynomial([1, -2, 1])) == [Complex(1), Complex(1)])
        #expect(try finder.roots(of: Polynomial([4, 0, 1])) == [Complex(0, 0.5), Complex(0, -0.5)])
        let quadratic = try finder.roots(of: Polynomial(StressFixture.wellConditionedPolynomials[0].coefficients))
        expectRootsClose(quadratic, [Complex(0.3, 0.4), Complex(0.3, -0.4)], relative: 2e-16, "wellQuadratic")
        #expect(quadratic[0].imaginary > 0 && quadratic[1] == quadratic[0].conjugate, "a pair, positive imaginary part first")

        // x² − 10⁸x + 1: the textbook formula loses the small root entirely; the closed form
        // here takes it from the product of the roots.
        let stiff = try finder.roots(of: Polynomial([1, -1e8, 1]))
        expectRootsClose(stiff, [Complex(1e8), Complex(1e-8)], relative: 1e-15, "stiff quadratic")

        // Nearly equal roots: b² and 4ac agree to 14 digits. The discriminant is formed with
        // fused multiply-adds, so the roots are those of the stored coefficients, 1 ± √(1 − c),
        // where 1 − c is exact.
        let constant = 1 - 1e-14
        let split = (1 - constant).squareRoot()
        let near = try finder.roots(of: Polynomial([1, -2, constant]))
        expectRootsClose(near, [Complex(1 + split), Complex(1 - split)], relative: 1e-15, "nearly double root")
        // Both products are exact there. Kahan's example is where the fused multiply-adds are
        // needed (register audit, WP-905b): b² and 4ac are rounded, and what is left of their
        // difference is all rounding error. The roots are 1 and c/a; the discriminant formed
        // without the two errors is 0, a double root, 1.4e-8 from either.
        let kahan = try finder.roots(of: Polynomial([94_906_265.625, -189_812_534, 94_906_268.375]))
        expectRootsClose(kahan, [Complex(1), Complex(94_906_268.375 / 94_906_265.625)], relative: 1e-15, "Kahan's quadratic")

        // Coefficients whose squares would overflow.
        let huge = try finder.roots(of: Polynomial([1e200, -3e200, 2e200]))
        expectRootsClose(huge, [Complex(1), Complex(2)], relative: 1e-15, "huge coefficients")
        let tiny = try finder.roots(of: Polynomial([1e-200, -3e-200, 2e-200]))
        expectRootsClose(tiny, [Complex(1), Complex(2)], relative: 1e-15, "tiny coefficients")
    }

    @Test func rootsAtTheOriginAreReadFromTheTrailingZerosExactly() throws {
        // x³·(x² − 3x + 2)
        let roots = try finder.roots(of: Polynomial([1, -3, 2, 0, 0, 0]))
        #expect(roots.count == 5)
        #expect(roots.filter { $0 == .zero }.count == 3)
        expectRootsClose(roots.filter { $0 != .zero }, [Complex(1), Complex(2)], relative: 1e-15, "the roots that are left")
        #expect(try finder.roots(of: Polynomial([5, 0, 0])) == [.zero, .zero])
        // Above degree 2 as well: x²·(the cubic fixture).
        let cubic = StressFixture.wellConditionedPolynomials[1]
        let padded = try finder.roots(of: Polynomial(cubic.coefficients + [0, 0]))
        #expect(padded.suffix(2) == [.zero, .zero])
        expectRootsClose(Array(padded.prefix(3)), expected(cubic), relative: 1e-10, "cubic times x²")
    }

    // MARK: Acceptance: the three ill-conditioned fixtures, documented at their limit

    @Test func wilkinsonReachesItsDocumentedAccuracy() throws {
        let fixture = StressFixture.wilkinson20
        let roots = try finder.roots(of: Polynomial(fixture.coefficients))
        let error = try #require(expectRootsClose(roots, expected(fixture), relative: fixture.achievableAccuracy, fixture.name,
                                                  measure: "WP-402 Wilkinson degree 20, relative root error"))
        // The limit is real: the stored coefficients are rounded, and their exact roots (found
        // in 120-digit arithmetic) already sit 4.8e-5 from the integers.
        #expect(error > 1e-6, "the fixture is ill-conditioned: an error of \(error) would mean it is not being exercised")
        #expect(roots.allSatisfy { $0.isFinite })
    }

    @Test func theTripleRootReachesItsDocumentedAccuracy() throws {
        let fixture = StressFixture.tripleRoot
        #expect(fixture.multiplicity == 3)
        let roots = try finder.roots(of: Polynomial(fixture.coefficients))
        let error = try #require(expectRootsClose(roots, expected(fixture), relative: fixture.achievableAccuracy, fixture.name,
                                                  measure: "WP-402 triple root, relative root error"))
        // ε^(1/3) ≈ 6e-6: a multiple root cannot be recovered to working precision.
        #expect(error > 1e-9 && error < 1e-4)
        // The simple root of the same polynomial is not affected by its neighbour's multiplicity.
        let simple = try #require(roots.min { ($0 - Complex(-0.25)).magnitude < ($1 - Complex(-0.25)).magnitude })
        #expect((simple - Complex(-0.25)).magnitude <= 1e-14)
    }

    /// The expanded order-16 Butterworth denominator. The fixture documents an achievable
    /// accuracy of 0.1; the test holds the finder to 0.25 instead, and says why.
    ///
    /// The stored coefficients are the exact expansion *rounded to doubles*. Their exact
    /// roots, computed in 120-digit arithmetic, are not the sixteen poles any more: under the
    /// best possible assignment the worst of them lies 0.152 from its pole, and two of them
    /// lie outside the unit circle. No root finder that is given these coefficients can do
    /// better than that, so 0.1 cannot be met; what can be asked is that the answer stays in
    /// the neighbourhood the rounding allows. This is the fixture that shows why a design is
    /// never expanded (REAL-1).
    @Test func theExpandedButterworthDenominatorIsDocumentedAtItsLimit() throws {
        let fixture = StressFixture.butterworth16Expanded
        #expect(fixture.largestConditionNumber > 1e20)
        let roots = try finder.roots(of: Polynomial(fixture.coefficients))
        let error = try #require(expectRootsClose(roots, expected(fixture), relative: 0.25, fixture.name,
                                                  measure: "WP-402 expanded Butterworth 16, relative root error (fixture documents 0.1)"))
        #expect(error > 1e-3, "sixteen clustered poles cannot be recovered from rounded coefficients: \(error)")
        #expect(roots.count == 16 && roots.allSatisfy { $0.isFinite })
        // Conjugate symmetry survives, and the cluster is located: every root lies within
        // 0.25 of the cluster's centre.
        let centre = Complex(0.93, 0)
        #expect(roots.allSatisfy { ($0 - centre).magnitude < 0.25 })
        for root in roots where root.imaginary != 0 {
            #expect(roots.contains(root.conjugate))
        }
    }

    // MARK: Mitigations (NUMS-2): each of these fails when its mitigation is removed

    /// Balancing by scaling only. A polynomial whose roots are small has a companion matrix
    /// with entries of very different sizes; the QR iteration then converges to eigenvalues
    /// that are wrong in the first digit, and no polish can repair that.
    @Test func stressBalancingRescuesABadlyScaledPolynomial() throws {
        for scale in [1e-4, 1e5] {
            let expectedRoots = (1 ... 6).map { Complex(Double($0) * scale) }
            let polynomial = Polynomial(realRoots: expectedRoots.map(\.real))
            let balanced = try finder.roots(of: polynomial)
            expectRootsClose(balanced, expectedRoots, relative: 1e-10, "balanced, roots of size \(scale)",
                             measure: "WP-402 badly scaled roots with balancing, relative root error")

            // The hazard, shown: the same finder without the balance and without the polish.
            let raw = try CompanionQRRootFinder(balancing: false, polishSteps: 0).roots(of: polynomial)
            var free = raw
            var worst = 0.0
            for root in expectedRoots {
                let nearest = try #require(free.indices.min { (free[$0] - root).magnitude < (free[$1] - root).magnitude })
                worst = max(worst, (free[nearest] - root).magnitude / root.magnitude)
                free.remove(at: nearest)
            }
            Measurements.shared.record("WP-402 badly scaled roots WITHOUT balancing or polish, relative root error (hazard)", worst, bound: 1e-10)
            #expect(worst > 1e-6, "without balancing the roots of size \(scale) are off by \(worst)")
        }
    }

    /// The Newton polish, evaluated in double-double arithmetic. Without it the QR
    /// eigenvalues of the Wilkinson companion matrix are an order of magnitude outside the
    /// fixture's accuracy.
    @Test func stressThePolishBringsWilkinsonWithinItsAccuracy() throws {
        let fixture = StressFixture.wilkinson20
        let polynomial = Polynomial(fixture.coefficients)
        let unpolished = try CompanionQRRootFinder(balancing: true, polishSteps: 0).roots(of: polynomial)
        var free = unpolished
        var worst = 0.0
        for root in expected(fixture) {
            let nearest = try #require(free.indices.min { (free[$0] - root).magnitude < (free[$1] - root).magnitude })
            worst = max(worst, (free[nearest] - root).magnitude / root.magnitude)
            free.remove(at: nearest)
        }
        Measurements.shared.record("WP-402 Wilkinson WITHOUT polish, relative root error (hazard)", worst, bound: fixture.achievableAccuracy)
        #expect(worst > fixture.achievableAccuracy, "the unpolished eigenvalues are off by \(worst)")
        expectRootsClose(try finder.roots(of: polynomial), expected(fixture), relative: fixture.achievableAccuracy, "polished")
    }

    /// The test of the residual in the polish (register audit, WP-905b). The triple root of
    /// WP-016 rescaled by 0.1, 0.2, …, 4.0: off the binary grid the coefficients are rounded,
    /// the triple root becomes a cluster of three simple ones, and a Newton step from an
    /// eigenvalue inside the cluster can land anywhere. A step is kept only when it lowers the
    /// residual, so no polished root is a worse root of the polynomial than the eigenvalue it
    /// came from, and every rescaled polynomial is found to the fixture's accuracy.
    @Test func stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic() throws {
        let fixture = StressFixture.tripleRoot
        let unpolishedFinder = CompanionQRRootFinder(balancing: true, polishSteps: 0)
        var worst = 0.0
        var plainWorst = 0.0
        for step in 1 ... 40 {
            let scale = 0.1 * Double(step)
            var power = 1.0
            let coefficients = fixture.coefficients.map { coefficient -> Double in
                defer { power *= scale }
                return coefficient * power
            }
            let polynomial = Polynomial(coefficients)
            let exact = expected(fixture).map { $0 * scale }
            let eigenvalues = try unpolishedFinder.roots(of: polynomial)
            let polished = try finder.roots(of: polynomial)
            let extended = coefficients.map { DoubleDouble($0) }
            let residual = { (root: Complex) in ExtendedHorner.evaluate(extended, at: root).value.magnitude }
            #expect(polished.count == eigenvalues.count)
            for (root, eigenvalue) in zip(polished, eigenvalues) {
                #expect(residual(root) <= residual(eigenvalue), "rescaled by \(scale): a polished root is a worse root than its eigenvalue")
            }
            worst = max(worst, try #require(expectRootsClose(polished, exact, relative: fixture.achievableAccuracy, "rescaled by \(scale)")))

            // The hazard, shown: the same two Newton steps from the same eigenvalues, each kept
            // whatever it does to the residual.
            var plain: [Complex] = []
            var index = 0
            while index < eigenvalues.count {
                var root = eigenvalues[index]
                for _ in 0 ..< 2 {
                    let current = ExtendedHorner.evaluate(extended, at: root)
                    guard current.value.magnitude > 0, current.derivative.magnitude > 0 else { break }
                    let candidate = root - current.value / current.derivative
                    guard candidate.isFinite else { break }
                    root = candidate
                }
                plain.append(root)
                if eigenvalues[index].imaginary != 0, index + 1 < eigenvalues.count {
                    plain.append(root.conjugate)
                    index += 2
                } else {
                    index += 1
                }
            }
            plainWorst = max(plainWorst, RootMatching.bottleneck(plain, exact))
        }
        Measurements.shared.record("WP-402 triple root rescaled by 0.1 to 4.0, relative root error", worst, bound: fixture.achievableAccuracy)
        Measurements.shared.record("WP-402 rescaled triple root, Newton steps kept WITHOUT the residual test, relative root error (hazard)", plainWorst, bound: fixture.achievableAccuracy)
        #expect(plainWorst > fixture.achievableAccuracy, "without the test of the residual a cluster is thrown off by \(plainWorst)")
    }

    // MARK: rootConditions

    @Test func rootConditionsFollowTheDefinition() throws {
        // p = (x − 1)(x − 2) = x² − 3x + 2: κ(1) = (1 + 3 + 2)/(1·1) = 6, κ(2) = (4 + 6 + 2)/(2·1) = 6.
        let polynomial = Polynomial([1, -3, 2])
        #expect(polynomial.rootCondition(at: Complex(1)) == 6)
        #expect(polynomial.rootCondition(at: Complex(2)) == 6)
        let conditions = try finder.rootConditions(of: polynomial)
        #expect(conditions == [6, 6])
        // A complex root: p = x² + 1, κ(j) = (1 + 1)/(1·2) = 1.
        #expect(Polynomial([1, 0, 1]).rootCondition(at: .i) == 1)
    }

    @Test func rootConditionsOfTheFixturesEqualTheirRecordedValues() throws {
        // At the exact roots the largest condition number is the one recorded with the fixture.
        for fixture in StressFixture.wellConditionedPolynomials {
            let polynomial = Polynomial(fixture.coefficients)
            let largest = try #require(expected(fixture).map { polynomial.rootCondition(at: $0) }.max())
            expectClose(largest, fixture.largestConditionNumber, .relative(1e-10), fixture.name)
        }
        // Wilkinson: the recorded figure is that of the exact coefficients; the stored ones
        // are rounded, and p′ at a root is itself only known to κ·ε. The two agree to 1 %.
        let wilkinson = Polynomial(StressFixture.wilkinson20.coefficients)
        let wilkinsonWorst = try #require(expected(StressFixture.wilkinson20).map { wilkinson.rootCondition(at: $0) }.max())
        expectClose(wilkinsonWorst, StressFixture.wilkinson20.largestConditionNumber, .relative(1e-2))
        // The expanded Butterworth denominator: beyond 1/ε a double-precision evaluation of p′
        // has no correct digit, and the figure saturates there. It still says what matters.
        let butterworth = Polynomial(StressFixture.butterworth16Expanded.coefficients)
        let butterworthWorst = try #require(expected(StressFixture.butterworth16Expanded).map { butterworth.rootCondition(at: $0) }.max())
        #expect(butterworthWorst > 1e15, "reported as \(butterworthWorst)")

        // Through the finder the order is that of `roots(of:)`.
        let quintic = StressFixture.wellConditionedPolynomials[2]
        let polynomial = Polynomial(quintic.coefficients)
        let roots = try finder.roots(of: polynomial)
        let conditions = try finder.rootConditions(of: polynomial)
        #expect(conditions.count == roots.count)
        for (root, condition) in zip(roots, conditions) {
            #expect(condition == polynomial.rootCondition(at: root))
            #expect(condition > 0 && condition <= 1e4)
        }
    }

    @Test func aMultipleRootHasAnInfiniteConditionAndARootAtTheOriginNone() throws {
        let triple = Polynomial(StressFixture.tripleRoot.coefficients)
        #expect(triple.rootCondition(at: Complex(0.5)) == .infinity)
        expectClose(triple.rootCondition(at: Complex(-0.25)), StressFixture.tripleRoot.largestConditionNumber, .relative(1e-12))
        #expect(Polynomial([1, -2, 1]).rootCondition(at: Complex(1)) == .infinity)
        // Roots read from trailing zeros are exact.
        #expect(Polynomial([1, -3, 2, 0]).rootCondition(at: .zero) == 0)
        let conditions = try finder.rootConditions(of: Polynomial([1, -3, 2, 0]))
        #expect(conditions.count == 3 && conditions[2] == 0)
        // Coefficients that overflow the sum are reported as infinitely ill-conditioned, not NaN.
        #expect(Polynomial([1e300, 1e300, 1e300]).rootCondition(at: Complex(1e10)) == .infinity)
    }

    // MARK: Limits and failures

    @Test func theDegreeCapIsATypedError() throws {
        #expect(CompanionQRRootFinder.maximumDegree == 512)
        var coefficients = [Double](repeating: 0, count: 514)
        coefficients[0] = 1
        coefficients[513] = -1                      // x⁵¹³ − 1
        let error = thrownError { _ = try finder.roots(of: Polynomial(coefficients)) }
        #expect(error?.isUnsupportedConfiguration == true)
        #expect(error?.description.contains("513") == true)

        // The cap itself is accepted: x⁵¹² − 1 has its roots on the unit circle.
        coefficients = [Double](repeating: 0, count: 513)
        coefficients[0] = 1
        coefficients[512] = -1
        let roots = try finder.roots(of: Polynomial(coefficients))
        #expect(roots.count == 512)
        #expect(roots.allSatisfy { abs($0.magnitude - 1) < 1e-12 })
        #expect(roots.allSatisfy { (Complex.pow($0, 512) - Complex.one).magnitude < 1e-9 })
    }

    @Test func invalidPolynomialsAreTypedErrors() {
        #expect(thrownError { _ = try finder.roots(of: .zero) }?.invalidParameterName == "polynomial")
        #expect(thrownError { _ = try finder.roots(of: Polynomial([1, .nan, 2, 3])) }?.invalidParameterName == "polynomial")
        #expect(thrownError { _ = try finder.roots(of: Polynomial([1, .infinity])) }?.invalidParameterName == "polynomial")
        #expect(thrownError { _ = try finder.rootConditions(of: .zero) }?.invalidParameterName == "polynomial")
        // A leading coefficient so small that the monic form overflows.
        #expect(thrownError { _ = try finder.roots(of: Polynomial([1e-300, 1e300, 1, 1])) }?.invalidParameterName == "polynomial")
    }

    @Test func aLAPACKFailureIsATypedError() throws {
        // The mapping of `info`.
        #expect(throws: Never.self) { try LAPACK.check(0, routine: "dhseqr") }
        #expect(thrownError { try LAPACK.check(3, routine: "dhseqr") } == .numericalFailure(routine: "dhseqr", info: 3))
        #expect(thrownError { try LAPACK.check(-7, routine: "dgebal") } == .numericalFailure(routine: "dgebal", info: -7))

        // A real failure of the routine: the QR iteration cannot converge on a matrix that
        // holds a NaN, and dhseqr says so through `info`.
        var companion = [Double](repeating: 0, count: 16)
        companion[0] = .nan
        companion[4] = 2
        companion[8] = 3
        companion[12] = 4
        companion[1] = 1
        companion[6] = 1
        companion[11] = 1
        let failure = try #require(thrownError { _ = try LAPACK.hessenbergEigenvalues(of: companion, order: 4) }?.numericalFailure)
        #expect(failure.routine == "dhseqr")
        #expect(failure.info > 0)

        // Storage that is not a square matrix never reaches LAPACK.
        #expect(thrownError { _ = try LAPACK.hessenbergEigenvalues(of: [1, 2, 3], order: 2) }?.invalidParameterName == "matrix")
        #expect(thrownError { _ = try LAPACK.hessenbergEigenvalues(of: [], order: 0) }?.invalidParameterName == "matrix")
    }

    @Test func theEigenvalueRoutineAgreesWithAKnownMatrix() throws {
        // The companion matrix of (x − 1)(x − 2)(x − 3) = x³ − 6x² + 11x − 6, column by column.
        let companion: [Double] = [6, 1, 0, -11, 0, 1, 6, 0, 0]
        let eigenvalues = try LAPACK.hessenbergEigenvalues(of: companion, order: 3)
        expectClose(eigenvalues.real.sorted(), [1, 2, 3], .relative(1e-13))
        #expect(eigenvalues.imaginary == [0, 0, 0])
        // A 1 × 1 matrix.
        #expect(try LAPACK.hessenbergEigenvalues(of: [4.5], order: 1).real == [4.5])
        // Without balancing the answer is the same for a well-scaled matrix.
        let plain = try LAPACK.hessenbergEigenvalues(of: companion, order: 3, balancing: false)
        expectClose(plain.real.sorted(), [1, 2, 3], .relative(1e-13))
    }

    // MARK: Structure

    @Test func complexRootsComeInExactConjugatePairs() throws {
        for fixture in StressFixture.wellConditionedPolynomials + StressFixture.illConditionedPolynomials {
            let roots = try finder.roots(of: Polynomial(fixture.coefficients))
            #expect(roots.count == fixture.degree, "\(fixture.name)")
            for root in roots where root.imaginary != 0 {
                #expect(roots.contains(root.conjugate), "\(fixture.name): \(root) has no exact conjugate")
            }
        }
    }

    @Test func theStrategyIsAValue() {
        let stock: some PolynomialRootFinder = .companionQR
        #expect(AnyStrategy(stock) == AnyStrategy(CompanionQRRootFinder()))
        #expect(AnyStrategy(stock) != AnyStrategy(CompanionQRRootFinder(balancing: false, polishSteps: 2)))
        #expect(CompanionQRRootFinder(balancing: true, polishSteps: -3) == CompanionQRRootFinder(balancing: true, polishSteps: 0))
    }
}
