import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Tier 2 of the order rules for the spectral front-end, as a matrix (ORD-2, ORD-6): every
/// public stage of the target on every domain, walked the way a pipeline is checked when it
/// is attached, against what the types of tier 1 accept.
///
/// The expectations are the typing of §5.8 and the order rules of §5.8.3 written out by hand,
/// not read back from the rules under test. The compiler's side of the same cells is what
/// `Tests/CompileFixtures` holds: one must-compile and one must-not-compile fixture per order
/// rule that names a stage of this target (STG-1).
@Suite("Order matrix")
struct OrderMatrixTests {
    static let axes: [DomainTag.Axis] = [.linear, .mel, .constantQ]
    static let values: [DomainTag.Values] = [.complex, .magnitude, .power, .decibel]

    /// Every domain a stage can be asked to follow.
    static let domains: [DomainTag] = [.samples] + axes.flatMap { axis in values.map { DomainTag.spectrum(axis: axis, values: $0) } }
        + [.quefrency, .melCepstrum, .chroma, .lags, .tempoSpectrum, .envelope, .novelty, .scalar, .custom("a domain of the app's own")]

    private struct Row {
        let name: String
        let stages: [StageDescription]
        /// The domain after the stage, or `nil` where the stage may not stand.
        let typing: (DomainTag) -> DomainTag?
    }

    private static func linear(_ values: DomainTag.Values) -> DomainTag { .spectrum(axis: .linear, values: values) }

    /// A stage with one input domain.
    private static func from(_ input: DomainTag, to output: DomainTag) -> (DomainTag) -> DomainTag? {
        { $0 == input ? output : nil }
    }

    /// A step that follows a spectrum, typed by its axis and its values.
    private static func spectral(_ typing: @escaping (DomainTag.Axis, DomainTag.Values) -> DomainTag?) -> (DomainTag) -> DomainTag? {
        { tag in
            if case .spectrum(let axis, let values) = tag { return typing(axis, values) }
            return nil
        }
    }

    @MainActor private static func rows() -> [Row] {
        let heat = HeatmapFeed(history: 8), level = StateBox(Float(0)), centroid = StateBox(ScalarFrame.none), pitch = StateBox(Float(0))
        let coefficients = StateBox([Float]())
        let energies: (DomainTag.Values) -> Bool = { $0 == .magnitude || $0 == .power }
        return [
            // Framing (O-1, O-6): samples to the complex linear spectrum, and back.
            Row(name: "STFT", stages: STFT(frame: 1_024, hop: 256).stageDescriptions, typing: from(.samples, to: linear(.complex))),
            Row(name: "InverseSTFT", stages: InverseSTFT().stageDescriptions, typing: from(linear(.complex), to: .samples)),
            // Value steps (O-3, O-4): any axis; the values decide.
            Row(name: "Magnitude", stages: [Magnitude().stageDescription], typing: spectral { $1 == .complex ? .spectrum(axis: $0, values: .magnitude) : nil }),
            Row(name: "Power", stages: [Power().stageDescription], typing: spectral { $1 == .complex ? .spectrum(axis: $0, values: .power) : nil }),
            Row(name: "Decibels", stages: [Decibels().stageDescription], typing: spectral { energies($1) ? .spectrum(axis: $0, values: .decibel) : nil }),
            Row(name: "InverseDecibels(.magnitude)", stages: [InverseDecibels(.magnitude).stageDescription],
                typing: spectral { $1 == .decibel ? .spectrum(axis: $0, values: .magnitude) : nil }),
            Row(name: "InverseDecibels(.power)", stages: [InverseDecibels(.power).stageDescription],
                typing: spectral { $1 == .decibel ? .spectrum(axis: $0, values: .power) : nil }),
            // Mel conversion (O-5) and the centroid (O-8): energies on a linear-frequency axis.
            Row(name: "MelScale", stages: [MelScale(bands: 40).stageDescription],
                typing: spectral { $0 == .linear && energies($1) ? .spectrum(axis: .mel, values: $1) : nil }),
            Row(name: "SpectralCentroid", stages: [SpectralCentroid().stageDescription], typing: spectral { $0 == .linear && energies($1) ? .scalar : nil }),
            Row(name: "SpectralCentroid(to:)", stages: [SpectralCentroid(to: centroid.binding).stageDescription],
                typing: spectral { $0 == .linear && energies($1) ? .spectrum(axis: $0, values: $1) : nil }),
            // Steps on samples (O-1).
            Row(name: "Level", stages: Level(.rms).stageDescriptions, typing: from(.samples, to: .scalar)),
            Row(name: "Level(to:)", stages: Level(.peak, to: level.binding).stageDescriptions, typing: from(.samples, to: .samples)),
            Row(name: "Waveform", stages: Waveform().stageDescriptions, typing: from(.samples, to: .envelope)),
            // Cepstral steps (O-9).
            Row(name: "Cepstrum", stages: Cepstrum().stageDescriptions, typing: from(linear(.complex), to: .quefrency)),
            Row(name: "InverseCepstrum", stages: InverseCepstrum().stageDescriptions, typing: from(.quefrency, to: linear(.complex))),
            Row(name: "Lifter", stages: Lifter(.lowTime(0.002)).stageDescriptions, typing: from(.quefrency, to: .quefrency)),
            Row(name: "CepstralPitch", stages: CepstralPitch().stageDescriptions, typing: from(.quefrency, to: .scalar)),
            Row(name: "CepstralPitch(to:)", stages: CepstralPitch(to: pitch.binding).stageDescriptions, typing: from(.quefrency, to: .quefrency)),
            // Cepstral coefficients (O-10): a mel spectrum in decibels, and back.
            Row(name: "CepstralCoefficients", stages: CepstralCoefficients().stageDescriptions,
                typing: from(.spectrum(axis: .mel, values: .decibel), to: .melCepstrum)),
            Row(name: "InverseCepstralCoefficients", stages: InverseCepstralCoefficients(bands: 40).stageDescriptions,
                typing: from(.melCepstrum, to: .spectrum(axis: .mel, values: .decibel))),
            // Recipes: taps on samples; the samples pass.
            Row(name: "Spectrogram", stages: Spectrogram(to: heat).stageDescriptions, typing: from(.samples, to: .samples)),
            Row(name: "MelSpectrogram", stages: MelSpectrogram(to: heat).stageDescriptions, typing: from(.samples, to: .samples)),
            Row(name: "MFCC(to: feed)", stages: MFCC(to: heat).stageDescriptions, typing: from(.samples, to: .samples)),
            Row(name: "MFCC(to: binding)", stages: MFCC(to: coefficients.binding).stageDescriptions, typing: from(.samples, to: .samples)),
        ]
    }

    @Test @MainActor func tierTwoAcceptsExactlyWhatTheTypesAccept() {
        let rows = OrderMatrixTests.rows()
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
        // 24 stages on 22 domains. Accepted: one cell for each of the sixteen stages with one
        // input domain; three each for Magnitude and Power (one per axis); six for Decibels;
        // three each for the two InverseDecibels; two each for MelScale and the two centroids.
        #expect(rows.count == 24 && OrderMatrixTests.domains.count == 22)
        #expect(accepted == 16 + 3 + 3 + 6 + 3 + 3 + 2 + 2 + 2 && accepted + refused == 24 * 22, "\(accepted) cells accepted, \(refused) refused")
    }

    @Test func aDisagreementBetweenTheTiersIsSeen() throws {
        // The matrix is only worth something if a wrong rule fails it: a MelScale whose rule
        // forgot the axis would be accepted after a constant-Q spectrum by tier 2, and by no type.
        let forgetful = DomainRule.spectral("MelScale without its axis") { _, values in
            values == .magnitude || values == .power ? .spectrum(axis: .mel, values: values) : nil
        }
        let seeded = StageDescription(MelScale(bands: 40), rule: forgetful)
        var tag = DomainTag.spectrum(axis: .constantQ, values: .power)
        try DynamicPipeline.check([seeded], from: &tag, prefix: StagePath())
        #expect(tag == .spectrum(axis: .mel, values: .power), "tier 2 with the seeded rule accepts the cell")
        var real = DomainTag.spectrum(axis: .constantQ, values: .power)
        #expect(throws: DSPError.self, "the rule the step ships with refuses it, as the types do") {
            try DynamicPipeline.check([MelScale(bands: 40).stageDescription], from: &real, prefix: StagePath())
        }
    }
}
