import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Tier 2 of the order rules for the constant-Q transform and chroma, as a matrix (ORD-2,
/// ORD-6): every public stage of WP-517 … WP-524 on every domain, walked the way a pipeline
/// is checked when it is attached, against what the types of tier 1 accept.
///
/// The expectations are the typing of §5.2 written out by hand, not read back from the rules
/// under test. The compiler's side of the same cells is `Tests/CompileFixtures` and the
/// generated matrix of `ZTronDSPTests`.
@Suite("Order matrix of the constant-Q steps")
struct ConstantQOrderTests {
    private struct Row {
        let name: String
        let stages: [StageDescription]
        /// The domain after the stage, or `nil` where the stage may not stand.
        let typing: (DomainTag) -> DomainTag?
    }

    @MainActor private static func rows() -> [Row] {
        let heat = HeatmapFeed(history: 8), values = StateBox([Float]())
        return [
            // Framing: samples to the complex constant-Q spectrum.
            Row(name: "ConstantQ", stages: ConstantQ().stageDescriptions) { $0 == .samples ? .spectrum(axis: .constantQ, values: .complex) : nil },
            // The axis conversion: energies on a linear-frequency axis, to the same on a constant-Q axis.
            Row(name: "ConstantQScale", stages: [ConstantQScale().stageDescription]) { tag in
                if case .spectrum(.linear, let values) = tag, values == .magnitude || values == .power { return .spectrum(axis: .constantQ, values: values) }
                return nil
            },
            // O-7: chroma from the magnitudes of a constant-Q spectrum, and from nothing else.
            Row(name: "ChromaFold", stages: ChromaFold().stageDescriptions) { $0 == .spectrum(axis: .constantQ, values: .magnitude) ? .chroma : nil },
            // The recipe: a tap on samples; the samples pass.
            Row(name: "ChromaCQT(to: feed)", stages: ChromaCQT(to: heat).stageDescriptions) { $0 == .samples ? .samples : nil },
            Row(name: "ChromaCQT(to: binding)", stages: ChromaCQT(to: values.binding).stageDescriptions) { $0 == .samples ? .samples : nil },
        ]
    }

    @Test @MainActor func tierTwoAcceptsExactlyWhatTheTypesAccept() {
        let rows = ConstantQOrderTests.rows()
        var accepted = 0, refused = 0
        for row in rows {
            #expect(!row.stages.isEmpty, "\(row.name) describes itself")
            for domain in OrderMatrixTests.domains {
                var tag = domain
                var result: DomainTag?
                do {
                    try DynamicPipeline.check(row.stages, from: &tag, prefix: StagePath())
                    result = tag
                } catch {
                    // A refusal names the stage and the domain it found (ORD-6).
                    guard case DSPError.invalidStageOrder(_, let found) = error else {
                        Issue.record("\(row.name) after \(domain): refused with \(error), not with an order error")
                        continue
                    }
                    #expect(found == domain, "\(row.name) after \(domain): the error names \(found)")
                }
                let expected = row.typing(domain)
                #expect(result == expected, "\(row.name) after \(domain): tier 2 gives \(String(describing: result)), the types give \(String(describing: expected))")
                if expected == nil { refused += 1 } else { accepted += 1 }
            }
        }
        // Five spellings on 22 domains: one cell each, and two for the axis conversion.
        #expect(rows.count == 5 && OrderMatrixTests.domains.count == 22)
        #expect(accepted == 6 && accepted + refused == 5 * 22, "\(accepted) cells accepted, \(refused) refused")
    }

    @Test func aDisagreementBetweenTheTiersIsSeen() throws {
        // A ChromaFold whose rule forgot the axis would fold the bins of an STFT, which no type lets it.
        let forgetful = DomainRule("ChromaFold without its axis") { tag in
            if case .spectrum(_, .magnitude) = tag { return .chroma }
            return nil
        }
        var tag = DomainTag.spectrum(axis: .linear, values: .magnitude)
        try DynamicPipeline.check([StageDescription(ChromaFold(), rule: forgetful)], from: &tag, prefix: StagePath())
        #expect(tag == .chroma, "tier 2 with the seeded rule accepts the cell")
        var real = DomainTag.spectrum(axis: .linear, values: .magnitude)
        #expect(throws: DSPError.self, "the rule the step ships with refuses it, as the types do (O-7)") {
            try DynamicPipeline.check(ChromaFold().stageDescriptions, from: &real, prefix: StagePath())
        }
    }

    @Test func theOrdersOfSectionSixEightAreAcceptedFromSamples() throws {
        // What §5.2 and §6.8 write down, end to end, on the descriptions.
        let feed = HeatmapFeed()
        #expect(try DynamicPipeline(Pipeline { ConstantQ(); Magnitude(); ChromaFold(); Emit(to: feed) }).outputTag == .chroma)
        #expect(try DynamicPipeline(Pipeline { ConstantQ(); Power(); Decibels(); Emit(to: feed) }).outputTag == .spectrum(axis: .constantQ, values: .decibel))
        #expect(try DynamicPipeline(Pipeline { STFT(frame: 8_192, hop: 512); Magnitude(); ConstantQScale(); ChromaFold() }).outputTag == .chroma)
        #expect(try DynamicPipeline(Pipeline { ChromaCQT(to: feed); TestGain(1) }).outputTag == .samples)
        // A pipeline forged past the types is still refused when it is checked (ORD-6).
        let forged = Pipeline<Samples, Chroma>(unchecked: STFT(frame: 1_024, hop: 256).stageDescriptions + [Magnitude().stageDescription] + ChromaFold().stageDescriptions)
        #expect(throws: DSPError.self) { _ = try DynamicPipeline(forged) }
        let refusal = errorMessage { let _: [[Float]] = try forged.process(TestSignal.silence(count: 2_048), format: mono48) }
        #expect(refusal?.contains("ChromaFold cannot follow a signal of the domain linear-frequency magnitude spectrum") == true, "\(refusal ?? "attached")")
    }
}
