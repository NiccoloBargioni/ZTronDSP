import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `DynamicPipeline` (WP-327a, WP-327b) and `StageValidation` (WP-342).
@Suite("Pipelines assembled from data")
struct DynamicPipelineTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 2_048, seed: 51)

    @Test func appendingAppliesTheOrderRules() throws {
        var pipeline = DynamicPipeline()
        #expect(pipeline.outputTag == .samples && pipeline.stages.isEmpty)
        try pipeline.append(TestGain(0.5))
        try pipeline.append(TestFramer(frame: 64, hop: 32))
        #expect(pipeline.outputTag == .spectrum(axis: .linear, values: .complex))
        // O-1: a sequence stage cannot follow a spectrum.
        #expect(throws: DSPError.invalidStageOrder(stage: StagePath().appending("TestGain", index: 2), found: .spectrum(axis: .linear, values: .complex))) {
            _ = try pipeline.appending(TestGain(2))
        }
        #expect(pipeline.stages.count == 2, "a refused append leaves the pipeline as it was")
        try pipeline.append(TestMagnitude().stageDescription)
        #expect(pipeline.outputTag == .spectrum(axis: .linear, values: .magnitude))
        #expect(throws: DSPError.self) { _ = try pipeline.appending(TestMagnitude().stageDescription) }
        try pipeline.append(TestMean())
        #expect(pipeline.outputTag == .scalar)
        try pipeline.append(TestGain(2))
        #expect(pipeline.stages.count == 5, "a sequence stage runs on a scalar track")
        let immutable = pipeline
        let longer = try immutable.appending(TestGain(3))
        #expect(immutable.stages.count == 5 && longer.stages.count == 6, "appending returns a new value")
    }

    @Test func aForgedDescriptionAndAnInvalidBranchAreRejectedWithTheirPath() throws {
        // A pipeline whose types lie: built unchecked, it claims samples all the way.
        let forged = Pipeline<Samples, Samples>(unchecked: [
            TestGain(1).stageDescriptions[0], TestFramer(frame: 64, hop: 32).stageDescriptions[0], TestGain(2).stageDescriptions[0],
        ])
        #expect(throws: DSPError.invalidStageOrder(stage: StagePath().appending("TestGain", index: 2), found: .spectrum(axis: .linear, values: .complex))) {
            _ = try DynamicPipeline(forged)
        }
        #expect(throws: DSPError.self) { try forged.process(noise, format: format) }
        // A branch that starts with a step its tap point cannot feed (O-15).
        let branch = Tap<Samples, Samples>(branch: [TestMagnitude().stageDescription], activation: .active).stageDescriptions[0]
        do {
            _ = try DynamicPipeline().appending(TestGain(1)).appending(branch)
            Issue.record("the branch was accepted")
        } catch {
            guard case .invalidStageOrder(let stage, let found) = error else { Issue.record("\(error)"); return }
            #expect(found == .samples && stage.description.contains("Tap") && stage.description.contains("TestMagnitude"), "the path leads into the branch: \(stage)")
        }
        // A sink after a domain it cannot hold (O-11), inside a group.
        let group = Group { TestGain(1) }.stageDescriptions[0]
        #expect(throws: Never.self) { _ = try DynamicPipeline().appending(group) }
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(Emit<HeatmapFeed>(to: HeatmapFeed()).stageDescription) }
        // A valid branch leaves the main line where it was.
        let valid = Tap<Samples, Samples>(branch: TestFramer(frame: 64, hop: 32).stageDescriptions, activation: .active).stageDescriptions[0]
        #expect(try DynamicPipeline().appending(valid).outputTag == .samples)
    }

    @Test func equalStagesGiveEqualPlansTypedOrDynamic() async throws {
        let sink = CollectingSink<Samples>()
        let typed = Pipeline { TestGain(0.5); TestBiquad(count: 2); TestDelay(3) }.emit(to: sink)
        var dynamic = DynamicPipeline()
        try dynamic.append(TestGain(0.5))
        try dynamic.append(TestBiquad(count: 2))
        try dynamic.append(TestDelay(3))
        try dynamic.append(Emit<CollectingSink<Samples>>(to: sink).stageDescription)
        let rebuilt = try DynamicPipeline(typed)
        #expect(dynamic.stages == typed.stages && dynamic == rebuilt)
        let compiler = PlanCompiler(crossovers: .shipped)
        #expect(try compiler.lower(dynamic.stages, environment: DSPEnvironment(), blockSize: 64).steps
            == compiler.lower(typed.stages, environment: DSPEnvironment(), blockSize: 64).steps, "the same stages give the same plan (ORD-5)")

        let engine = DSPEngine(blockSize: 64)
        let session = try await engine.attach(dynamic, to: BufferSource(noise, sampleRate: 48_000))
        try session.start()
        #expect(await session.reaches(.finished))
        let offline = try Pipeline { TestGain(0.5); TestBiquad(count: 2); TestDelay(3) }.process(noise, format: format, blockSize: 64)
        #expect(sink.samples == offline)
        session.detach()
    }

    @Test func aDynamicPipelineUpdatesLikeATypedOne() async throws {
        let rig = Rig()
        var first = DynamicPipeline()
        try first.append(TestGain(0.5))
        let session = try await rig.engine.attach(first, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        rig.feed([Float](repeating: 1, count: 64))
        let plan = session.core.plan
        try await session.update(first)
        #expect(session.core.plan === plan, "an equal pipeline costs a comparison")
        try await session.update(try DynamicPipeline().appending(TestGain(0.25)))
        #expect(session.core.plan === plan && session.core.generation == 1, "other values travel to the kernel")
        try await session.update(try DynamicPipeline().appending(TestGain(0.25)).appending(TestDelay(2)))
        #expect(session.core.generation == 2, "another topology is another plan")
        rig.feed([Float](repeating: 1, count: 64 * 12))
        #expect(probe.samples.last == -0.25)
        // What a typed update gives, a dynamic one gives.
        try await session.update(Pipeline { TestGain(0.25); TestDelay(2) })
        #expect(session.core.generation == 2)
    }

    // MARK: StageValidation (WP-342)

    private struct Checked: SequenceStage {
        let check: @Sendable (LoweringContext) throws(DSPError) -> Void
        static func == (lhs: Checked, rhs: Checked) -> Bool { true }
        func hash(into hasher: inout Hasher) {}
        func lower(_ context: inout LoweringContext) throws(DSPError) {
            try check(context)
            context.emit(.gain(factor: 2, ramp: 0))
        }
    }

    /// Runs `check` inside a stage at 48 kHz, after a decimation by 4 when asked, and returns
    /// what it returned, or the error it raised as the pipeline reports it.
    private func checked<T: Sendable>(
        decimated: Bool = false, _ check: @escaping @Sendable (LoweringContext) throws(DSPError) -> T
    ) -> Result<T, DSPError> {
        let value = Locked<T?>(nil)
        let stage = Checked { context throws(DSPError) in value.set(try check(context)) }
        do {
            _ = try (decimated ? Pipeline { TestSubsample(by: 4); stage } : Pipeline { stage }).process(noise, format: format)
        } catch {
            return .failure(error)
        }
        return value.get().map { .success($0) } ?? .failure(.cancelled)
    }

    private func refused(_ result: Result<some Sendable, DSPError>) -> (stage: String?, parameter: String, reason: String)? {
        guard case .failure(.invalidParameter(let stage, let parameter, let reason)) = result else { return nil }
        return (stage.stageName, parameter, reason)
    }

    @Test func aFrequencyIsHeldAgainstNyquistAtItsPosition() throws {
        let accepted = checked { context throws(DSPError) in
            [try StageValidation.frequency(.hertz(10_000), named: "cutoff", in: context),
             try StageValidation.frequency(.fractionOfNyquist(0.5), named: "cutoff", in: context),
             try StageValidation.frequency(.hertz(0), named: "low", in: context, allowingZero: true),
             try StageValidation.frequency(.hertz(24_000), named: "high", in: context, allowingNyquist: true)]
        }
        #expect(try accepted.get() == [10_000, 12_000, 0, 24_000])
        let band = checked { context throws(DSPError) in try StageValidation.band(from: .hertz(100), to: .hertz(200), named: "band", in: context) }
        #expect(try band.get() == 100 ... 200)

        // O-16: the same cutoff is legal at 48 kHz and not after a decimation by 4.
        let late = refused(checked(decimated: true) { context throws(DSPError) in try StageValidation.frequency(.hertz(10_000), named: "cutoff", in: context) })
        #expect(late?.stage == "Checked" && late?.parameter == "cutoff" && late?.reason.contains("6000") == true,
                "the error names the stage and the Nyquist frequency there: \(late?.reason ?? "")")
        let failures = [
            refused(checked { context throws(DSPError) in try StageValidation.frequency(.hertz(24_000), named: "f", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.frequency(.hertz(0), named: "f", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.frequency(.hertz(-5), named: "f", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.frequency(.hertz(.nan), named: "f", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.band(from: .hertz(300), to: .hertz(200), named: "f", in: context).lowerBound }),
        ]
        #expect(failures.allSatisfy { $0?.stage == "Checked" && $0?.parameter == "f" }, "every refusal carries the stage's path")
    }

    @Test func lengthsAndValuesAreHeldAgainstTheirRules() throws {
        let accepted = checked { context throws(DSPError) in
            [try StageValidation.transformLength(1_024, named: "frame", in: context),
             try StageValidation.transformLength(960, named: "frame", in: context),
             try StageValidation.hop(256, frame: 1_024, named: "hop", in: context),
             try StageValidation.value(3, named: "order", in: 1 ... 8, context: context),
             try StageValidation.value(7, named: "count", atLeast: 1, context: context)]
        }
        #expect(try accepted.get() == [1_024, 960, 256, 3, 7])
        #expect(try checked { context throws(DSPError) in try StageValidation.finite(Float(1.5), named: "gain", in: context) }.get() == 1.5)

        let odd = refused(checked { context throws(DSPError) in try StageValidation.transformLength(1_000, named: "frame", in: context) })
        #expect(odd?.stage == "Checked" && odd?.parameter == "frame" && odd?.reason.contains("960") == true && odd?.reason.contains("1024") == true,
                "the error names the nearest lengths: \(odd?.reason ?? "")")
        let failures = [
            refused(checked { context throws(DSPError) in try StageValidation.transformLength(0, named: "n", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.hop(0, frame: 64, named: "n", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.hop(65, frame: 64, named: "n", in: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.value(9, named: "n", in: 1 ... 8, context: context) }),
            refused(checked { context throws(DSPError) in try StageValidation.value(0, named: "n", atLeast: 1, context: context) }),
            refused(checked { context throws(DSPError) in Int(try StageValidation.finite(Double.infinity, named: "n", in: context)) }),
        ]
        #expect(failures.allSatisfy { $0?.stage == "Checked" && $0?.parameter == "n" })
    }
}
