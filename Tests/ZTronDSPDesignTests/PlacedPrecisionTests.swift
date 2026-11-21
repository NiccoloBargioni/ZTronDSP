import Foundation
import Testing
@testable import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// REAL-3, EXT-1 (CR-025 item 6): for `.automatic` a stock filter stage measures the deviation
/// of single from double precision with the kernel a plan creates at its place: accelerated or
/// not, one setup for all channels from three channels up, in blocks of the size it runs
/// there. The public measurement fixed all three (accelerated, one channel, 512 frames), so a
/// filter written outside the package could pick another precision than its twin near the
/// threshold. `recommendedPrecision(accelerated:channelCount:blockFrames:)` is the measurement
/// with the three figures a stage reads off its lowering context.
@Suite("The precision a filter picks at its place (REAL-3, EXT-1)")
struct PlacedPrecisionTests {
    private struct Place: Sendable, CustomStringConvertible {
        let implementation: Implementation
        let channels: Int
        let block: Int

        var description: String { "\(implementation), \(channels) channel(s), blocks of \(block)" }

        /// What a stage's `lower(_:)` reads: `context.implementation(for: .biquadKernel, size: context.maximumBlockFrames)`.
        var accelerated: Bool {
            CrossoverTable.shipped.implementation(for: .biquadKernel, size: block, requested: implementation) == .accelerate
        }
    }

    private let places = [
        Place(implementation: .accelerate, channels: 1, block: 512), Place(implementation: .native, channels: 1, block: 512),
        Place(implementation: .accelerate, channels: 3, block: 512), Place(implementation: .native, channels: 2, block: 1),
        Place(implementation: .accelerate, channels: 2, block: 37), Place(implementation: .automatic, channels: 4, block: 64),
    ]

    private func sections(_ cutoff: Double) throws -> SecondOrderSections {
        try IIRDesign(.butterworth, .lowPass(cutoff: cutoff), order: 2, domain: .digital(sampleRate: 48_000)).secondOrderSections
    }

    /// The precision the stock low-pass picks at `place`.
    private func stock(_ cutoff: Double, at place: Place) throws -> BiquadPrecision? {
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: place.channels, blockSize: place.block)
        let pipeline = Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 2) }.environment(\.implementation, place.implementation)
        let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: place.block)
        for step in lowered.steps {
            if case .kernel(let kernel) = step, case .biquad(_, let precision) = kernel.spec { return precision }
        }
        return nil
    }

    @Test func theMeasurementAtTheStandardPlaceIsTheOneWithoutArguments() throws {
        for cutoff in [200.0, 1_000, 5_000, 21_600] {
            let cascade = try sections(cutoff)
            #expect(try cascade.singleVersusDoubleDeviation(accelerated: true, channelCount: 1, blockFrames: 512) == cascade.singleVersusDoubleDeviation())
            #expect(try cascade.recommendedPrecision(accelerated: true, channelCount: 1, blockFrames: 512) == cascade.recommendedPrecision())
        }
        // What cannot be measured cannot be measured at any place.
        let analog = SecondOrderSections(sections: [.identity], domain: .analog)
        #expect(throws: DSPError.self) { _ = try analog.recommendedPrecision(accelerated: false, channelCount: 2, blockFrames: 64) }
        #expect(try SecondOrderSections(sections: []).singleVersusDoubleDeviation(accelerated: false, channelCount: 3, blockFrames: 7) == DSP.decibelFloor)
    }

    @Test func aFilterThatPassesItsPlacePicksWhatTheStockStagePicksThere() throws {
        // Cutoffs from where single precision is far too coarse to where it is plenty, in steps of half a percent.
        var cutoffs: [Double] = []
        var cutoff = 150.0
        while cutoff < 21_600 {
            cutoffs.append(cutoff)
            cutoff *= 1.005
        }
        var dependsOnThePlace = 0, differsFromTheStandardPlace = 0
        for cutoff in cutoffs {
            let cascade = try sections(cutoff)
            let standard = try cascade.recommendedPrecision()
            var picked: Set<BiquadPrecision> = []
            for place in places {
                let placed = try cascade.recommendedPrecision(accelerated: place.accelerated, channelCount: place.channels, blockFrames: place.block)
                let twin = try stock(cutoff, at: place)
                #expect(twin == placed, "\(cutoff) Hz, \(place): the stage picks \(String(describing: twin)), the measurement at its place says \(placed)")
                picked.insert(placed)
                if placed != standard { differsFromTheStandardPlace += 1 }
            }
            if picked.count > 1 { dependsOnThePlace += 1 }
        }
        // The place matters: near the threshold the choice is not the same everywhere, and not
        // always the one the measurement without arguments names.
        #expect(dependsOnThePlace > 0 && differsFromTheStandardPlace > 0,
                "\(dependsOnThePlace) of \(cutoffs.count) cutoffs pick by the place; \(differsFromTheStandardPlace) choices differ from the standard place's")
    }
}
