import Testing
import ZTronDSP

// This file imports the facade and nothing else of the package (§4.2, WP-901a): what it reaches,
// a client that writes `import ZTronDSP` reaches. That it does not reach the views or the test
// product is held by the must-not-compile fixtures `Tests/CompileFixtures/invalid/Facade*.swift`.

/// The facade re-exports `ZTronDSPCore`, `ZTronDSPDesign`, `ZTronDSPAnalysis`, `ZTronDSPIO` and
/// `ZTronDSPMetal` (§4.2): one representative symbol of each is reachable through one import, and
/// its full name says which module declares it.
@Suite("Facade")
struct FacadeTests {
    /// The module part of a type's full name, `ZTronDSPCore` for `ZTronDSPCore.Frequency`.
    static func module<T>(of type: T.Type) -> String {
        String(String(reflecting: type).prefix { $0 != "." })
    }

    @Test func oneImportReachesTheCore() {
        let pipeline = Pipeline<Samples, Samples>()
        #expect(Self.module(of: Pipeline<Samples, Samples>.self) == "ZTronDSPCore")
        #expect(Self.module(of: Frequency.self) == "ZTronDSPCore")
        #expect(pipeline.stages.isEmpty)
    }

    @Test func oneImportReachesTheDesignTarget() {
        let pipeline: Pipeline<Samples, Samples> = Pipeline { Gain(.decibels(-3)) }
        #expect(Self.module(of: Gain.self) == "ZTronDSPDesign")
        #expect(pipeline.stages.count == 1)
    }

    @Test func oneImportReachesTheAnalysisTarget() {
        let pipeline: Pipeline<Samples, Spectrum<LinearFrequency, ComplexValues>> = Pipeline { STFT(frame: 1_024, hop: 256) }
        #expect(Self.module(of: STFT.self) == "ZTronDSPAnalysis")
        #expect(pipeline.stages.count == 1)
    }

    @Test func oneImportReachesTheInputTarget() {
        let policy = AudioSessionPolicy.playAndRecord.mixingWithOthers()
        #expect(Self.module(of: AudioSessionPolicy.self) == "ZTronDSPIO")
        #expect(Self.module(of: HardwareInputSource.self) == "ZTronDSPIO")
        #expect(Self.module(of: type(of: policy)) == "ZTronDSPIO")
    }

    @Test func oneImportReachesTheMetalTarget() {
        let entry = CrossoverEntry.gainKernel
        #expect(Self.module(of: CrossoverEntry.self) == "ZTronDSPMetal")
        #expect(Self.module(of: MetalContext.self) == "ZTronDSPMetal")
        #expect(entry.rawValue.isEmpty == false)
    }
}
