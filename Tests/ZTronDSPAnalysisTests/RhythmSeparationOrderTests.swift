import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// Tier 2 of the order rules for convolution, autocorrelation, the onset strength, the
/// tempograms and the harmonic–percussive separation, as a matrix (ORD-2, ORD-6): every public
/// stage of WP-515, WP-516, WP-525 … WP-527, WP-531a and WP-532 on every domain, walked the
/// way a pipeline is checked when it is attached, against what the types of tier 1 accept.
///
/// The expectations are the typing of §5.2 and the rules O-1, O-2, O-9 and O-12 of §5.8
/// written out by hand, not read back from the rules under test. The compiler's side of the
/// same cells is `Tests/CompileFixtures` and the generated matrix of `ZTronDSPTests`.
@Suite("Order matrix of the convolution, rhythm and separation steps")
struct RhythmSeparationOrderTests {
    private struct Row {
        let name: String
        let stages: [StageDescription]
        /// The domain after the stage, or `nil` where the stage may not stand.
        let typing: (DomainTag) -> DomainTag?
    }

    private static let sequences: [DomainTag] = [.samples, .novelty, .scalar]

    @MainActor private static func rows() -> [Row] {
        let shown = StateBox(true)
        return [
            // O-1: a convolution is a sequence stage; any sampled sequence, kept.
            Row(name: "Convolve", stages: Convolve(kernel: [0.5, 0.5]).stageDescriptions) { sequences.contains($0) ? $0 : nil },
            Row(name: "Convolve(strategy: .partitioned)", stages: Convolve(kernel: [0.5, 0.5], strategy: .partitioned).stageDescriptions) {
                sequences.contains($0) ? $0 : nil
            },
            // O-1: an autocorrelation frames any sampled sequence; lags follow.
            Row(name: "Autocorrelation", stages: [Autocorrelation().stageDescription]) { sequences.contains($0) ? .lags : nil },
            // O-9: a spectrum in decibels, on any axis, to a novelty curve; a novelty curve to a tempogram.
            Row(name: "OnsetStrength", stages: [OnsetStrength().stageDescription]) { tag in
                if case .spectrum(_, .decibel) = tag { return .novelty }
                return nil
            },
            Row(name: "Tempogram(.autocorrelation)", stages: Tempogram().stageDescriptions) { $0 == .novelty ? .tempoSpectrum : nil },
            Row(name: "Tempogram(.fourier)", stages: Tempogram(.fourier, alignment: .centered).stageDescriptions) { $0 == .novelty ? .tempoSpectrum : nil },
            // O-2: the complex spectrum of an STFT, or magnitudes on any axis; the domain is kept.
            Row(name: "HarmonicPercussive", stages: [HarmonicPercussive(select: .harmonic).stageDescription]) { tag in
                switch tag {
                case .spectrum(.linear, .complex), .spectrum(_, .magnitude): return tag
                default: return nil
                }
            },
            // O-12: the recipe takes samples and returns them, switched or not.
            Row(name: "HPSS", stages: HPSS(select: .percussive).stageDescriptions) { $0 == .samples ? .samples : nil },
            Row(name: "HPSS(isActive: binding)", stages: HPSS(select: .harmonic, isActive: shown.binding).stageDescriptions) { $0 == .samples ? .samples : nil },
        ]
    }

    @Test @MainActor func tierTwoAcceptsExactlyWhatTheTypesAccept() {
        let rows = RhythmSeparationOrderTests.rows()
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
        // Nine spellings on 22 domains. Accepted: three sequences each for the two convolutions
        // and the autocorrelation; the three spectra in decibels for the onset strength; the
        // novelty curve for each tempogram; the complex linear spectrum and the three spectra
        // of magnitudes for the separation; samples for each recipe.
        #expect(rows.count == 9 && OrderMatrixTests.domains.count == 22)
        #expect(accepted == 3 + 3 + 3 + 3 + 1 + 1 + 4 + 1 + 1 && accepted + refused == 9 * 22, "\(accepted) cells accepted, \(refused) refused")
    }

    @Test func aDisagreementBetweenTheTiersIsSeen() throws {
        // A separation whose rule forgot the values would mask powers, which no type lets it;
        // an onset strength whose rule forgot them would difference magnitudes.
        let forgetful = DomainRule.spectral("HarmonicPercussive without its values") { axis, values in .spectrum(axis: axis, values: values) }
        var tag = DomainTag.spectrum(axis: .linear, values: .power)
        try DynamicPipeline.check([StageDescription(HarmonicPercussive(select: .harmonic), rule: forgetful)], from: &tag, prefix: StagePath())
        #expect(tag == .spectrum(axis: .linear, values: .power), "tier 2 with the seeded rule accepts the cell")
        var real = DomainTag.spectrum(axis: .linear, values: .power)
        #expect(throws: DSPError.self, "the rule the step ships with refuses it, as the types do (O-2)") {
            try DynamicPipeline.check([HarmonicPercussive(select: .harmonic).stageDescription], from: &real, prefix: StagePath())
        }
        var magnitudes = DomainTag.spectrum(axis: .mel, values: .magnitude)
        #expect(throws: DSPError.self, "O-9: magnitudes are not levels") {
            try DynamicPipeline.check([OnsetStrength().stageDescription], from: &magnitudes, prefix: StagePath())
        }
    }

    @Test func theOrdersOfTheSpecificationAreAcceptedFromSamples() throws {
        // What §5.2, §6.7, §6.9 and §6.10 write down, end to end, on the descriptions.
        let feed = HeatmapFeed()
        let decibels = Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 128); Decibels() }
        #expect(try DynamicPipeline(decibels.onsetStrength().tempogram(.autocorrelation).emit(to: feed)).outputTag == .tempoSpectrum)
        #expect(try DynamicPipeline(decibels.onsetStrength().convolve(kernel: [0.5, 0.5]).tempogram(.fourier)).outputTag == .tempoSpectrum,
                "sequence stages may stand between the curve and its tempogram (O-1)")
        #expect(try DynamicPipeline(decibels.onsetStrength().autocorrelation(window: 128, hop: 1)).outputTag == .lags)
        #expect(try DynamicPipeline(Pipeline { TestGain(1); Convolve(kernel: [1, -1]); Autocorrelation(); Emit(to: feed) }).outputTag == .lags)
        #expect(try DynamicPipeline(Pipeline { STFT(frame: 2_048, hop: 512); HarmonicPercussive(select: .harmonic); InverseSTFT() }).outputTag == .samples)
        #expect(try DynamicPipeline(Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); HarmonicPercussive(select: .percussive); MelScale(bands: 40) }).outputTag
                == .spectrum(axis: .mel, values: .magnitude))
        #expect(try DynamicPipeline(Pipeline { HPSS(select: .harmonic); Convolve(kernel: [0.5, 0.5]) }).outputTag == .samples)

        // Pipelines forged past the types are still refused when they are checked (ORD-6), and
        // the refusal names the stage and what it found.
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 9, amplitude: 0.5)
        let afterSamples = Pipeline<Samples, TempoSpectrum>(unchecked: TestGain(1).stageDescriptions + Tempogram().stageDescriptions)
        #expect(throws: DSPError.self, "O-9: `Gain → Tempogram`") { _ = try DynamicPipeline(afterSamples) }
        let gainThenTempogram = errorMessage { let _: [[Float]] = try afterSamples.process(noise, format: mono48) }
        #expect(gainThenTempogram?.contains("Tempogram cannot follow a signal of the domain samples") == true, "\(gainThenTempogram ?? "attached")")

        let ofPowers = Pipeline<Samples, Novelty>(unchecked: STFT(frame: 1_024, hop: 256).stageDescriptions + [Power().stageDescription, OnsetStrength().stageDescription])
        let onsetOfPowers = errorMessage { try ofPowers.run(on: noise, format: mono48) }
        #expect(onsetOfPowers?.contains("OnsetStrength cannot follow a signal of the domain linear-frequency power spectrum") == true, "\(onsetOfPowers ?? "attached")")

        let lagsOfBins = Pipeline<Samples, Lags>(unchecked: STFT(frame: 1_024, hop: 256).stageDescriptions + [Autocorrelation().stageDescription])
        let autocorrelationOfBins = errorMessage { let _: [[Float]] = try lagsOfBins.process(noise, format: mono48) }
        #expect(autocorrelationOfBins?.contains("Autocorrelation cannot follow a signal of the domain") == true, "\(autocorrelationOfBins ?? "attached")")

        let recipeOfBins = Pipeline<Samples, Samples>(unchecked: STFT(frame: 1_024, hop: 256).stageDescriptions + HPSS(select: .harmonic).stageDescriptions)
        #expect(throws: DSPError.self, "O-12: the recipe starts from samples") { _ = try DynamicPipeline(recipeOfBins) }
        let filterOfBins = Pipeline<Samples, Samples>(unchecked: STFT(frame: 1_024, hop: 256).stageDescriptions + Convolve(kernel: [0.5, 0.5]).stageDescriptions)
        #expect(throws: DSPError.self, "O-1: a convolution is a sequence stage") { _ = try DynamicPipeline(filterOfBins) }
    }
}
