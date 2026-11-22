Currency check (§7.3): 2026-11-15. Registered source confirmed from the specification's register (§7.2 row 12: LAPACK; Aurentz, Mach, Vandebril & Watkins 2015). No literature search possible offline.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 12. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Polynomial roots (WP-402, register row 12)

`PolynomialRootFinder.companionQR`: `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift`, LAPACK in `LinearAlgebra/LAPACK.swift`.

## Hazard

1. **Conditioning.** A simple root moves by about κ(r)·ε when the coefficients are rounded, κ(r) = Σ|aₖ||r|ᵏ / (|r||p′(r)|). A root of multiplicity m is only determined to ε^(1/m).
2. **Scaling.** The companion matrix of a polynomial whose roots are all small (or all large) has entries of very different sizes; the QR iteration then converges to eigenvalues that are wrong in the first digit.
3. **Evaluation beside a root.** A Newton step needs p(r), which cancels almost every digit a double holds exactly where it is needed.

## Measured behaviour

Fixtures of WP-016 (`StressFixture`), relative error of the worst root under the best assignment of computed to expected roots, on the iOS 27.0 simulator and on the host (identical):

| Fixture | κ | Error reached | Fixture's `achievableAccuracy` |
|---|---|---|---|
| five well-conditioned polynomials | ≤ 15 | 0 (bit-exact) | 1e-10 |
| `wilkinson20` | 5.4e13 | 7.2e-5 | 1e-3 |
| `tripleRoot` | ∞ (m = 3) | 3.8e-6 | 1e-4 |
| `butterworth16Expanded` | 3.8e20 | 0.106 | 0.1 |

The last row does not meet the fixture's figure and cannot. The stored coefficients are the exact expansion rounded to doubles; their exact roots, computed in 120-digit arithmetic, already lie 0.152 from the sixteen poles under the best assignment (two of them outside the unit circle). The test holds the finder to 0.25 and records why. For Wilkinson the same computation gives 4.8e-5: the finder is at the limit of the stored coefficients.

Without the mitigations: roots of size 1e-4 with neither balance nor polish are off by 1.65 (relative); Wilkinson without polish by 9.9e-3.

## Mitigation

- Designs never come here: they stay in zero-pole-gain form (REAL-1). Only a system *given* as coefficients is root-found.
- Roots at the origin are read from the trailing zero coefficients, exactly. Degree ≤ 2 is closed form, with the discriminant formed by fused multiply-adds (Kahan) and the real roots taken in the order that does not cancel.
- The companion matrix is balanced by scaling only (`dgebal`, `JOB = 'S'`): a diagonal similarity, which keeps it Hessenberg for `dhseqr`.
- At most two Newton steps on the original polynomial, with p and p′ evaluated in double-double arithmetic (`ExtendedHorner`); a step is kept only when it lowers the residual. A multiple root that rounding has split into a cluster is where Newton's method is erratic: a step from inside the cluster can throw a root out of it, and such a step raises the residual and is refused.
- `rootConditions` reports κ(r) for every root (it saturates near 1/ε, where a double-precision p′ has no correct digit; that already means "no digit of the root is known").
- Degree cap 512 (`DSPError.unsupportedConfiguration`); a non-zero LAPACK `info` is `DSPError.numericalFailure`.

## Stress tests (`PolynomialRootFinderTests`)

- `stressBalancingRescuesABadlyScaledPolynomial` fails when the balance is removed.
- `stressThePolishBringsWilkinsonWithinItsAccuracy` and `wilkinsonReachesItsDocumentedAccuracy` fail when the polish is removed (9.9e-3 against 1e-3).
- `theExpandedButterworthDenominatorIsDocumentedAtItsLimit` and `theTripleRootReachesItsDocumentedAccuracy` pin the two fixtures no mitigation can rescue.
- `stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic` fails when the test of the residual is removed (added by the register audit, 2026-11-21; the stored `tripleRoot` is exact in binary, so Newton's method converges on it, linearly, and the test is never needed there). The triple root rescaled by 0.1, 0.2, …, 4.0 has rounded coefficients and is a cluster of three: steps kept whatever they do raise the residual of three roots at each of four scales (2.3, 2.7, 3.3, 3.7) and leave the one rescaled by 3.3 off by 6.4e-4 against the fixture's 1e-4. With the test the worst is 6.2e-6.

Register audit, 2026-11-21 (WP-905b): balance, polish and the test of the residual as above. Five more mitigations, one at a time:

- Roots at the origin left to the eigenvalue solver fail `rootsAtTheOriginAreReadFromTheTrailingZerosExactly`.
- The real roots of a quadratic taken by the textbook formula fail `degreeTwoUsesTheClosedFormWithoutCancellation` (the stiff quadratic is off by 0.25).
- The discriminant formed without the errors of its two products passed every test, because the nearly double root of that test has exact products. Kahan's example (94 906 265.625x² − 189 812 534x + 94 906 268.375) was added. Without the errors it is a double root, 1.4e-8 from both roots.
- A degree cap of 1 024 fails `theDegreeCapIsATypedError`.
