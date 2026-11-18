import Testing
import ZTronDSP
@testable import ZTronDSPCore

/// The two tiers of the order rules agree (ORD-2, WP-328): what the compiler accepts, recorded
/// in `OrderMatrix.compiled` by `Scripts/order-matrix.sh`, is what the `DomainRule` of each
/// stage accepts when a pipeline is validated.
@Suite("Order matrix")
struct OrderMatrixTests {
    /// Tier 2 as the package runs it: the stage's descriptions validated from `tag` on.
    static func rulesAccept(_ descriptions: [StageDescription], after tag: DomainTag) -> Bool {
        var current = tag
        do throws(DSPError) {
            try DynamicPipeline.check(descriptions, from: &current, prefix: StagePath())
            return true
        } catch {
            return false
        }
    }

    /// Every cell on which the compiler and the rules differ, in words.
    static func disagreements(
        stages: [(name: String, descriptions: [StageDescription])], domains: [(name: String, tag: DomainTag)], compiled: [String]
    ) -> [String] {
        var found: [String] = []
        for (stage, row) in zip(stages, compiled) {
            for (domain, cell) in zip(domains, row) {
                let compiles = cell == "1"
                let ruled = rulesAccept(stage.descriptions, after: domain.tag)
                if compiles != ruled {
                    found.append("\(stage.name) after \(domain.name): the compiler \(compiles ? "accepts" : "refuses"), the rules \(ruled ? "accept" : "refuse")")
                }
            }
        }
        return found
    }

    @Test func theMatrixHasACellForEveryStageOnEveryDomain() {
        #expect(OrderMatrix.compiled.count == OrderMatrix.stages.count && !OrderMatrix.stages.isEmpty)
        #expect(OrderMatrix.compiled.allSatisfy { $0.count == OrderMatrix.domains.count })
        #expect(Set(OrderMatrix.domains.map(\.tag)).count == OrderMatrix.domains.count, "no domain is listed twice")
        // A stage that stands nowhere is a line of the list that is wrong, not a stage.
        for (stage, row) in zip(OrderMatrix.stages, OrderMatrix.compiled) {
            #expect(row.contains("1"), "\(stage.name) compiles after no domain at all")
        }
    }

    @Test func theCompilerAndTheRulesAgreeOnEveryCell() {
        let found = Self.disagreements(stages: OrderMatrix.stages, domains: OrderMatrix.domains, compiled: OrderMatrix.compiled)
        #expect(found.isEmpty, "\(found.count) cells differ:\n\(found.joined(separator: "\n"))")
    }

    @Test func aSeededDisagreementIsReported() throws {
        // The first cell the compiler accepts, flipped: the comparison names it.
        var tampered = OrderMatrix.compiled
        let row = try #require(tampered.firstIndex { $0.contains("1") })
        let column = try #require(Array(tampered[row]).firstIndex(of: "1"))
        var cells = Array(tampered[row])
        cells[column] = "0"
        tampered[row] = String(cells)
        let found = Self.disagreements(stages: OrderMatrix.stages, domains: OrderMatrix.domains, compiled: tampered)
        #expect(found == ["\(OrderMatrix.stages[row].name) after \(OrderMatrix.domains[column].name): the compiler refuses, the rules accept"])

        // And the other way: a cell the compiler refuses, recorded as accepted.
        var loose = OrderMatrix.compiled
        let refusedRow = try #require(loose.firstIndex { $0.contains("0") })
        let refusedColumn = try #require(Array(loose[refusedRow]).firstIndex(of: "0"))
        var looseCells = Array(loose[refusedRow])
        looseCells[refusedColumn] = "1"
        loose[refusedRow] = String(looseCells)
        #expect(Self.disagreements(stages: OrderMatrix.stages, domains: OrderMatrix.domains, compiled: loose).count == 1)
    }

    @Test func theRulesOfAStageWithStructureAreFollowedIntoIt() {
        // A branch is validated from the point it taps, and leaves the main line where it was.
        let inner = Gain(.decibels(-6)).stageDescriptions
        let tap = [StageDescription(name: "Tap", rule: .any, activation: .active, content: .tap(inner))]
        #expect(Self.rulesAccept(tap, after: .samples))
        #expect(!Self.rulesAccept(tap, after: .chroma), "a gain inside a tap of chroma is refused, as it is on the main line")
    }
}
