import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `CepstralCoefficients`, `InverseCepstralCoefficients` and the `MFCC` recipe (WP-512).
@Suite("Cepstral coefficients")
struct CepstralCoefficientTests {
    typealias MelDecibels = Spectrum<MelFrequency, DecibelValues>
    private let noise = TestSignal.gaussianNoise(count: 16_384, seed: 512, standardDeviation: 0.2)

    private func melDecibels(bands: Int) -> Pipeline<Samples, MelDecibels> {
        Pipeline { STFT(frame: 2_048, hop: 512, alignment: .centered); Power(); MelScale(bands: bands); Decibels() }
    }

    // MARK: Golden (STG-2)

    @Test(arguments: ["speech-40-13", "speech-64-20", "speech-128-128", "speech-26-26", "music-40-13", "music-64-20", "music-128-128", "music-26-26"])
    func theCoefficientsEqualTheGoldenVectors(name: String) throws {
        let fixtureName = String(name.prefix { $0 != "-" })
        let fixture = try GoldenFile(named: "fixtures", in: .module).require(fixtureName)
        let golden = try GoldenFile(named: "cepstrum", in: .module).require("mfcc-\(name)")
        let samples = try fixture.floats("samples"), format = SignalFormat(sampleRate: try fixture.number("sampleRate"))
        let bands = try golden.integer("bands"), count = try golden.integer("count"), frames = try golden.integer("frames")
        let reference = try golden.real("coefficients")
        let coefficients: [[Float]] = try melDecibels(bands: bands).appending(CepstralCoefficients(count: count)).process(samples, format: format, blockSize: 400)
        #expect(coefficients.count == frames && coefficients.allSatisfy { $0.count == count })
        for (index, values) in coefficients.enumerated() {
            expectClose(values, Array(reference[index * count ..< (index + 1) * count]), .absolute(1e-3), "\(name), frame \(index)")
        }
    }

    // MARK: The two implementations of the DCT (§6.6, E-09)

    @Test(arguments: [16, 18, 20, 24, 26, 30, 40, 48, 64, 80])
    func theTransformIsTheOrthonormalDCTWhateverTheBandCount(bands: Int) throws {
        let observed = Observed()
        let decibels: [[Float]] = try melDecibels(bands: bands).process(noise, format: mono48)
        let coefficients: [[Float]] = try TransformSetup.$observer.withValue({ kind, length in if kind == "DCT" { observed.note(length) } }) {
            try melDecibels(bands: bands).appending(CepstralCoefficients(count: bands)).process(noise, format: mono48)
        }
        // The vDSP DCT where the length is one it documents, a basis otherwise; creating a setup
        // for 18, 26 or 30 points crashes, so that this test finishes is part of what it shows.
        #expect(observed.lengths == (DSP.isFastLength(bands) ? [bands] : []), "\(bands) bands: DCT setups for \(observed.lengths)")
        let basis = CosineBasis.orthonormal(bands: bands, count: bands)
        for (index, values) in coefficients.enumerated() {
            let expected = (0 ..< bands).map { row in (0 ..< bands).reduce(0.0) { $0 + Double(basis[row * bands + $1]) * Double(decibels[index][$1]) } }
            expectClose(values, expected, .absolute(2e-4), "\(bands) bands, frame \(index)")
        }
        // Orthonormal: the energy of the coefficients is the energy of the bands.
        let energy = coefficients[3].reduce(0) { $0 + Double($1) * Double($1) }, expected = decibels[3].reduce(0) { $0 + Double($1) * Double($1) }
        expectClose(energy, expected, .relative(1e-5))
    }

    @Test func theBasisIsOrthonormal() {
        for bands in [5, 26, 40] {
            let basis = CosineBasis.orthonormal(bands: bands, count: bands)
            for row in 0 ..< bands {
                for other in row ..< bands {
                    let product = (0 ..< bands).reduce(0.0) { $0 + Double(basis[row * bands + $1]) * Double(basis[other * bands + $1]) }
                    expectClose(product, row == other ? 1 : 0, .absolute(1e-6))
                }
            }
        }
    }

    // MARK: The inverse (§6.13)

    @Test(arguments: [26, 40, 64, 128])
    func theInverseIsExactWhenTheCountEqualsTheBandCount(bands: Int) throws {
        let decibels: [[Float]] = try melDecibels(bands: bands).process(noise, format: mono48)
        let coefficients = CepstralCoefficients(count: bands)
        let restored: [[Float]] = try melDecibels(bands: bands).appending(coefficients).appending(coefficients.inverse).process(noise, format: mono48)
        #expect(coefficients.inverse == InverseCepstralCoefficients(bands: bands) && restored.count == decibels.count)
        for index in decibels.indices { expectClose(restored[index], decibels[index], .relativeToMaximum(2e-6), "\(bands) bands, frame \(index)") }
    }

    @Test func withFewerCoefficientsTheInverseIsTheSmoothPart() throws {
        let decibels: [[Float]] = try melDecibels(bands: 40).process(noise, format: mono48)
        let smooth: [[Float]] = try melDecibels(bands: 40).appending(CepstralCoefficients(count: 8)).appending(InverseCepstralCoefficients(bands: 40))
            .process(noise, format: mono48)
        let basis = CosineBasis.orthonormal(bands: 40, count: 8)
        for index in [0, 5, decibels.count - 1] {
            // The projection of the bands on the first eight rows of the basis.
            let kept = (0 ..< 8).map { row in (0 ..< 40).reduce(0.0) { $0 + Double(basis[row * 40 + $1]) * Double(decibels[index][$1]) } }
            let expected = (0 ..< 40).map { column in (0 ..< 8).reduce(0.0) { $0 + kept[$1] * Double(basis[$1 * 40 + column]) } }
            expectClose(smooth[index], expected, .relativeToMaximum(1e-5))
        }
    }

    @Test func downstreamTheRowsArePlainPositions() throws {
        let coefficients = CollectingSink<MelCepstrum>(), back = CollectingSink<MelDecibels>()
        try melDecibels(bands: 40).appending(CepstralCoefficients(count: 13)).emit(to: coefficients).appending(InverseCepstralCoefficients(bands: 40)).emit(to: back)
            .run(on: noise, format: mono48)
        #expect(coefficients.axis == .indices(count: 13) && coefficients.reals.allSatisfy { $0.count == 13 })
        #expect(back.axis == .indices(count: 40) && back.reals.allSatisfy { $0.count == 40 }, "the centres of the bands are not known to the inverse")
        #expect(coefficients.environment?.frameSize == 2_048 && coefficients.environment?.hopSize == 512 && coefficients.times == back.times)
    }

    @Test func countsThatDoNotFitAreRefusedAtAttachTime() {
        func refused(_ pipeline: Pipeline<Samples, some SignalDomain>) -> String? { errorMessage { try pipeline.run(on: noise, format: mono48) } }
        #expect(refused(melDecibels(bands: 40).appending(CepstralCoefficients(count: 41)))?.contains("between 1 and the band count") == true)
        #expect(refused(melDecibels(bands: 40).appending(CepstralCoefficients(count: 0))) != nil)
        #expect(refused(melDecibels(bands: 40).appending(CepstralCoefficients(count: 13)).appending(InverseCepstralCoefficients(bands: 12))) != nil)
        #expect(refused(melDecibels(bands: 40).appending(CepstralCoefficients(count: 13)).appending(InverseCepstralCoefficients(bands: 1 << 20))) != nil)
        #expect(refused(melDecibels(bands: 40).appending(CepstralCoefficients(count: 40))) == nil)
    }

    // MARK: Order (O-10), descriptions, the recipe

    @Test func theRulesOfTheDescriptions() throws {
        let forward = try #require(CepstralCoefficients().stageDescriptions.first), inverse = try #require(InverseCepstralCoefficients(bands: 40).stageDescriptions.first)
        let melDecibel = DomainTag.spectrum(axis: .mel, values: .decibel)
        #expect(forward.rule(melDecibel) == .melCepstrum && inverse.rule(.melCepstrum) == melDecibel)
        for tag in [DomainTag.samples, .quefrency, .spectrum(axis: .mel, values: .power), .spectrum(axis: .linear, values: .decibel), .spectrum(axis: .mel, values: .magnitude)] {
            #expect(forward.rule(tag) == nil && inverse.rule(tag) == nil, "\(tag) (O-10)")
        }
        let mel = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 512)).appending(Power().stageDescription).appending(MelScale(bands: 40).stageDescription)
        #expect(throws: DSPError.self) { _ = try mel.appending(CepstralCoefficients()) }
        #expect(try mel.appending(Decibels().stageDescription).appending(CepstralCoefficients()).outputTag == .melCepstrum)
    }

    @Test func descriptionsAndTheRecipe() throws {
        #expect(melDecibels(bands: 40).appending(CepstralCoefficients(count: 13)) == melDecibels(bands: 40).cepstralCoefficients(count: 13))
        #expect(melDecibels(bands: 40).cepstralCoefficients() == melDecibels(bands: 40).appending(CepstralCoefficients()), "13 by default")
        #expect(melDecibels(bands: 40).cepstralCoefficients(count: 13).inverseCepstralCoefficients(bands: 40)
            == melDecibels(bands: 40).appending(CepstralCoefficients(count: 13)).appending(InverseCepstralCoefficients(bands: 40)))
        #expect(CepstralCoefficients.stageName == "CepstralCoefficients" && CepstralCoefficients(isActive: false).activation == .constant(false))

        let feed = HeatmapFeed(history: 64), box = StateBox([Float]())
        #expect(Pipeline { MFCC(frame: 1_024, hop: 256, count: 20, melBands: 64, window: .hamming, to: feed) }
            == Pipeline { Tap { STFT(frame: 1_024, hop: 256, window: .hamming); Power(); MelScale(bands: 64); Decibels(); CepstralCoefficients(count: 20); Emit(to: feed) } })
        #expect(Pipeline { MFCC(to: feed) } == Pipeline { Tap { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 40); Decibels(); CepstralCoefficients(count: 13); Emit(to: feed) } })
        #expect(Pipeline { MFCC(count: 5, melBands: 20, to: box.binding, isActive: false) }
            == Pipeline { Tap(isActive: false) { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 20); Decibels(); CepstralCoefficients(count: 5); Emit(to: box.binding) } })
        #expect(Pipeline().mfcc(count: 20, melBands: 64, to: feed) == Pipeline { MFCC(count: 20, melBands: 64, to: feed) })
        #expect(Pipeline().mfcc(to: box.binding) == Pipeline { MFCC(to: box.binding) } && MFCC(to: feed, isActive: false).activation == .constant(false))
    }

    @Test @MainActor func theRecipeFillsAFeedOrABinding() throws {
        let feed = HeatmapFeed(history: 64), box = StateBox([Float]())
        let output = try Pipeline { MFCC(to: feed); MFCC(count: 5, melBands: 20, to: box.binding); TestGain(0.5) }.process(noise, format: mono48)
        #expect(output == noise.map { $0 * 0.5 }, "the samples pass on")
        let direct: [[Float]] = try Pipeline { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 40); Decibels(); CepstralCoefficients(count: 13) }.process(noise, format: mono48)
        #expect(feed.snapshot().values == direct.flatMap { $0 } && feed.axis == .indices(count: 13) && feed.rowCount == 13)
        #expect(box.value.count == 5 && box.writes == 1)
    }

    // MARK: The real-time audit (RT-7)

    @Test func theNodesRunWithoutAllocating() throws {
        let transform = CountingSink<MelCepstrum>(), basis = CountingSink<MelCepstrum>(), back = CountingSink<MelDecibels>()
        let feed = HeatmapFeed(history: 64)
        try expectNoAllocationsRunning(Pipeline {
            Tap { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 64); Decibels(); CepstralCoefficients(count: 20); Emit(to: transform) }
            Tap { STFT(frame: 2_048, hop: 512); Power(); MelScale(bands: 40); Decibels(); CepstralCoefficients(count: 13); Emit(to: basis)
                  InverseCepstralCoefficients(bands: 40); Emit(to: back) }
            MFCC(frame: 1_024, hop: 512, count: 13, melBands: 26, to: feed)
        })
        #expect(transform.frames > 990 && basis.frames == transform.frames && back.frames == basis.frames && feed.columnCount == 64)
    }
}
