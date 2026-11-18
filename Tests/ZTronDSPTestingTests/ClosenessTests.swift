import Testing
import ZTronDSPTesting

@Suite("expectClose")
struct ClosenessTests {
    @Test func absoluteToleranceIsElementwise() {
        #expect(Closeness.compare([1.0, 2.0], [1.0005, 2.0], .absolute(1e-3)) == nil)
        let failure = Closeness.compare([1.0, 2.0, 3.0], [1.0, 2.5, 3.2], .absolute(1e-3))
        #expect(failure?.reason == .outOfTolerance)
        #expect(failure?.index == 1)
        #expect(failure?.failingCount == 2)
        #expect(failure?.count == 3)
    }

    @Test func relativeToleranceScalesWithTheValues() {
        #expect(Closeness.compare(1_000_000.0, 1_000_001.0, .relative(1e-5)) == nil)
        #expect(Closeness.compare(1e-9, 2e-9, .relative(1e-5)) != nil)
        #expect(Closeness.compare(0.0, 0.0, .relative(1e-12)) == nil)
    }

    @Test func levelToleranceIsInDecibels() {
        // A factor of 1.0116 is 0.1 dB.
        #expect(Closeness.compare(1.011, 1.0, .decibels(0.1)) == nil)
        #expect(Closeness.compare(1.02, 1.0, .decibels(0.1)) != nil)
        #expect(Closeness.compare(0.0, 0.0, .decibels(0.1)) == nil)
        #expect(Closeness.compare(0.0, 1e-30, .decibels(0.1)) != nil)
        #expect(Closeness.compare(-2.0, 2.0, .decibels(0.1)) == nil, "a level has no sign")
    }

    @Test func spectralToleranceIsRelativeToTheLargestExpectedValue() {
        // 1e-3 against a peak of 100 allows 0.1 on every element, the small ones included.
        #expect(Closeness.compare([100.0, 0.05], [100.0, 0.0], .relativeToMaximum(1e-3)) == nil)
        #expect(Closeness.compare([100.0, 0.2], [100.0, 0.0], .relativeToMaximum(1e-3)) != nil)
    }

    @Test func deviationBoundReadsAsDecibelsBelowThePeak() {
        let expected: [Float] = [0, 0.5, -1, 0.25]
        var actual = expected
        actual[3] += 5e-6  // −106 dB re the peak of 1
        #expect(Closeness.compare(actual, expected, .deviationBelow(decibels: -100)) == nil)
        actual[3] += 5e-5  // −85 dB
        #expect(Closeness.compare(actual, expected, .deviationBelow(decibels: -100)) != nil)
    }

    @Test func countMismatchAndNonFiniteValuesNeverPass() {
        #expect(Closeness.compare([1.0], [1.0, 2.0], .absolute(1))?.reason == .countMismatch(actual: 1, expected: 2))
        #expect(Closeness.compare([Double.nan], [Double.nan], .absolute(1))?.reason == .nonFinite)
        #expect(Closeness.compare([Double.infinity], [1.0], .absolute(.infinity))?.reason == .nonFinite)
        #expect(Closeness.compare([Double.infinity], [Double.infinity], .absolute(0)) == nil)
        #expect(Closeness.compare([Double](), [Double](), .absolute(0)) == nil, "two empty sequences agree")
    }

    @Test func failureMessagesNameTheWorstElement() throws {
        let failure = try #require(Closeness.compare([1.0, 2.0, 3.0], [1.0, 2.5, 3.2], .absolute(1e-3)))
        let text = failure.description
        #expect(text.contains("element 1"))
        #expect(text.contains("2.0"))
        #expect(text.contains("2.5"))
        #expect(text.contains("absolute tolerance 0.001"))
        #expect(text.contains("2 of 3 elements"))

        let scalar = try #require(Closeness.compare(1.0, 2.0, .relative(0.1)))
        #expect(scalar.description.hasPrefix("value is 1.0 where 2.0 was expected"))

        let mismatch = try #require(Closeness.compare([1.0], [Double](), .absolute(1)))
        #expect(mismatch.description == "count mismatch: 1 values, 0 expected")
    }

    @Test func mixedPrecisionsCompare() {
        let singles: [Float] = [0.1, 0.2]
        let doubles: [Double] = [0.1, 0.2]
        #expect(Closeness.compare(singles, doubles, .absolute(1e-7)) == nil)
    }

    @Test func expectCloseRecordsAnIssueOnFailureOnly() {
        #expect(expectClose(1.0, 1.0, .absolute(0)))
        #expect(expectClose([1.0, 2.0], [1.0, 2.0], .relative(0)))
        withKnownIssue {
            expectClose(1.0, 2.0, .absolute(0.5), "seeded failure")
        } matching: { issue in
            issue.description.contains("seeded failure") && issue.description.contains("value is 1.0 where 2.0 was expected")
        }
    }
}
