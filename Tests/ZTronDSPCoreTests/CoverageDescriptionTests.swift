import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// What a pipeline is made of, where the suites of M3 left lines unrun (COV-3): the activation
// wrappers, descriptions and their parameters, the dynamic pipeline, two builder overloads,
// bound results, and the keys the plan compiler compares steps by.

/// A self-typed stage with one continuous value: a gain on samples, with its factor as the
/// parameter an animation interpolates.
private struct CoverageLevel: PipelineStage {
    typealias Input = Samples
    typealias Output = Samples
    let factor: Double

    var parameters: [Double] { [factor] }
    func replacingParameters(_ values: ArraySlice<Double>) -> CoverageLevel {
        guard let value = values.first, value != factor else { return self }
        return CoverageLevel(factor: value)
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.gain(factor: Float(factor), ramp: 0))
    }
}

/// A stage on the caller's own C kernel that cannot make one: `make` returns the kernel that is
/// none.
private struct CoverageNoKernel: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "CoverageNoKernel", key: self) { _, _, _ in ztd_kernel_t() }))
    }
}

/// Where a `FrameWriter` under test sends its frames: it keeps a copy of each.
private final class CoverageFrameLog: FrameDelivery {
    private(set) var frames: [FeatureFrame] = []

    override func deliver(_ frame: FrameView) {
        frames.append(FeatureFrame(frame))
    }
}

@Suite("Descriptions, builder and compiler values (COV-3)")
struct CoverageDescriptionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)

    private func position(_ domain: DomainTag = .samples) -> IRPosition {
        IRPosition(domain: domain, environment: environment, maximumFrames: 64, format: .samples(channelCount: 1, maximumFrames: 64))
    }

    // MARK: `.active(_:)` (ACT-1)

    /// ACT-1: a custom stage gets its switch from `.active(_:)`. ANI-2: the wrapper has the
    /// continuous values of the stage it wraps, and replacing them replaces the stage's and
    /// keeps the switch; the stage's own values give the wrapper back unchanged.
    @Test func anActivatedStageHasTheValuesOfItsStageAndKeepsItsSwitch() {
        let wrapped = CoverageLevel(factor: 2).active(false)
        #expect(ActivatedStage<CoverageLevel>.stageName == "CoverageLevel" && wrapped.parameters == [2])
        let replaced = wrapped.replacingParameters([3][...])
        #expect(replaced.base == CoverageLevel(factor: 3) && replaced.activation == .constant(false))
        #expect(wrapped.replacingParameters([2][...]) == wrapped, "its own values: the same value")

        let sequence = TestGain(0.5).active(true)
        #expect(ActivatedSequenceStage<TestGain>.stageName == "TestGain" && sequence.parameters == [0.5])
        let moved = sequence.replacingParameters([0.25][...])
        #expect(moved.base.factor == 0.25 && moved.activation == .constant(true))
        #expect(sequence.replacingParameters([0.5][...]) == sequence)
    }

    /// ACT-1, §5.11.1: the wrapper is the stage with a switch and nothing else. Lowered, it
    /// emits exactly what the stage emits; the compiler applies the switch, the stage does not.
    @Test func anActivatedStageLowersToWhatItsStageLowersTo() throws {
        let path = StagePath().appending("CoverageLevel", index: 0)
        var plain = LoweringContext(position: position(), path: path, crossovers: .shipped)
        try CoverageLevel(factor: 2).lower(&plain)
        var wrapped = LoweringContext(position: position(), path: path, crossovers: .shipped)
        try CoverageLevel(factor: 2).active(false).lower(&wrapped)
        #expect(wrapped.specs == plain.specs && wrapped.specs == [.gain(factor: 2, ramp: 0)])

        var sequence = LoweringContext(position: position(), path: path, crossovers: .shipped)
        try TestGain(0.5).active(StateBox(true).binding).lower(&sequence)
        #expect(sequence.specs == [.gain(factor: 0.5, ramp: 0.010)])
        // An error of the stage is the wrapper's error.
        var failing = LoweringContext(position: position(), path: path, crossovers: .shipped)
        #expect(throws: DSPError.self) { try TestGain(.nan).active(true).lower(&failing) }
        #expect(failing.specs.isEmpty)

        // In a pipeline the switch does what ACT-3 and ACT-4 say: off for good, the stage leaves no trace.
        let noise = TestSignal.whiteNoise(count: 128, seed: 301)
        #expect(try Pipeline { CoverageLevel(factor: 2).active(false) }.process(noise, format: format, blockSize: 64) == noise)
        #expect(Pipeline { CoverageLevel(factor: 2).active(true) } == Pipeline { CoverageLevel(factor: 2) }, "`.active(true)` is the default (ACT-12)")
    }

    /// ANI-2: "Passing the stage's own values returns the stage unchanged". A stage without
    /// continuous values has nothing to replace, whatever it is handed.
    @Test func aStageWithoutContinuousValuesIsItsOwnReplacement() {
        let taps = TestFIR([1, 2, 3])
        #expect(taps.parameters.isEmpty)
        #expect(taps.replacingParameters([][...]) == taps && taps.replacingParameters([7, 8][...]) == taps)
        #expect(TestBarrier().replacingParameters([1][...]) == TestBarrier())
    }

    // MARK: Descriptions (API-1, ANI-2)

    /// API-1: a description gives back the stage it was made from, to whoever names its type,
    /// and nothing for another type or for structure, which is no stage.
    @Test func aDescriptionGivesBackItsStageAndStructureGivesNone() {
        let gain = TestGain(2).stageDescriptions[0]
        #expect(gain.stage(as: TestGain.self)?.factor == 2)
        #expect(gain.stage(as: TestFIR.self) == nil, "another type")
        let sink = CollectingSink<Samples>()
        let structure: [StageDescription] = [
            Emit(to: sink).stageDescription,
            Tap { TestGain(2) }.stageDescriptions[0],
            ZTronDSPCore.Group { TestGain(2) }.stageDescriptions[0],
            EnvironmentReader { _ in TestGain(2) }.stageDescriptions[0],
        ]
        for description in structure {
            #expect(description.stage(as: TestGain.self) == nil, "\(description.kind) holds no stage of its own")
        }
        let kinds = structure.map { $0.kind }
        #expect(kinds == [.emit, .tap, .group, .environmentReader])
    }

    /// ANI-2: an `EnvironmentReader` and a sink contribute no continuous value, so a vector
    /// replaces the values of the stages around them and leaves them as they are.
    @Test func replacingParametersLeavesSinksAndReadersAsTheyAre() {
        let sink = CollectingSink<Samples>()
        let pipeline = Pipeline {
            TestGain(2)
            EnvironmentReader { environment in TestGain(Float(environment.blockSize)) }
            Emit(to: sink)
            Tap { TestGain(4); Emit(to: CollectingSink<Samples>()) }
        }
        #expect(pipeline.parameters == ParameterVector([2, 4]), "the reader's stages exist only per environment")
        let replaced = pipeline.replacingParameters(ParameterVector([3, 5]))
        #expect(replaced.parameters == ParameterVector([3, 5]))
        #expect(replaced.stages[1] == pipeline.stages[1] && replaced.stages[2] == pipeline.stages[2], "the reader and the sink are the ones given")
        #expect(replaced.stages[0].stage(as: TestGain.self)?.factor == 3)
        #expect(replaced.stages[3].nestedStages[0].stage(as: TestGain.self)?.factor == 5 && replaced.stages[3].nestedStages[1] == pipeline.stages[3].nestedStages[1])
        #expect(pipeline.replacingParameters(pipeline.parameters) == pipeline, "its own vector: an equal pipeline")
    }

    /// ORD-5, §5.8.2: an `EnvironmentReader` is checked as what it produces in the reference
    /// environment, whose domains are those of every environment. Its content exists only once
    /// it is resolved: the description holds no nested stages.
    @Test func aReaderIsExpandedInTheReferenceEnvironmentForTheOrderCheck() throws {
        let seen = Locked<[Double]>([])
        let reader = EnvironmentReader { environment in
            let _ = seen.withLock { $0.append(environment.sampleRate) }
            TestGain(Float(environment.sampleRate))
            TestGain(2)
        }.stageDescriptions[0]
        #expect(reader.nestedStages.isEmpty, "its content exists only once it is resolved")
        let checked = try DynamicPipeline().appending(reader)
        #expect(checked.stages.count == 1 && checked.outputTag == .samples)
        let rates = seen.get(), reference = DSPEnvironment.reference.sampleRate
        #expect(!rates.isEmpty && rates.allSatisfy { $0 == reference }, "asked for what it produces in the reference environment: \(rates)")
    }

    // MARK: DynamicPipeline (ORD-5)

    /// ORD-5: a reader in a pipeline assembled from data moves the domain as its content does,
    /// and a reader whose content cannot follow what stands before it is refused, with the
    /// path of the stage inside it.
    @Test func aDynamicPipelineChecksAReaderByItsContent() throws {
        typealias Bins = Spectrum<LinearFrequency, ComplexValues>
        let framing = EnvironmentReader { _ in TestFramer(frame: 64, hop: 16) }
        let pipeline = try DynamicPipeline().appending(TestGain(2)).appending(framing)
        #expect(pipeline.outputTag == Bins.tag && pipeline.stages.count == 2)

        // Spectra cannot be framed again: the reader's own stage is the one that is named.
        let expected = DSPError.invalidStageOrder(
            stage: StagePath().appending("EnvironmentReader", index: 2).appending("TestFramer", index: 0), found: Bins.tag)
        #expect(throws: expected) { _ = try pipeline.appending(framing) }
        // A reader of sequence stages keeps the domain, and cannot stand on a spectrum either.
        let gains = EnvironmentReader { _ in TestGain(3) }
        #expect(try DynamicPipeline().appending(gains).outputTag == .samples)
        #expect(throws: DSPError.self) { _ = try pipeline.appending(gains) }
    }

    /// ORD-5: "Either all are appended or none is", in the mutating spelling too (CR-015, item 10).
    @Test func appendingSeveralStepsInPlaceAppendsAllOrNone() throws {
        var pipeline = DynamicPipeline()
        try pipeline.append(TestGain(2))
        let magnitudes = TestFramer(frame: 64, hop: 16).stageDescriptions + [TestMagnitude().stageDescription]
        try pipeline.append(contentsOf: magnitudes)
        #expect(pipeline.stages.count == 3 && pipeline.outputTag == Spectrum<LinearFrequency, MagnitudeValues>.tag)

        // The second of these cannot follow the first: neither is appended.
        let before = pipeline
        let impossible = [TestScaleBins(2).stageDescriptions[0], TestGain(2).stageDescriptions[0]]
        let expected = DSPError.invalidStageOrder(stage: StagePath().appending("TestGain", index: 4), found: pipeline.outputTag)
        #expect(throws: expected) { try pipeline.append(contentsOf: impossible) }
        #expect(pipeline == before, "the pipeline is as it was")
        try pipeline.append(contentsOf: [])
        #expect(pipeline == before)
    }

    // MARK: Pipeline and its builder (API-1, API-2)

    /// O-11, §5.1: in a block, a `WaveformFeed` follows an envelope, and the block equals the
    /// fluent spelling. The feed then holds one (minimum, maximum) pair per bucket.
    @Test func aWaveformFeedFollowsAnEnvelopeInABlock() throws {
        let feed = WaveformFeed(history: 64)
        let block = Pipeline { TestEnvelope(bucket: 16); Emit(to: feed) }
        let fluent = Pipeline().appending(TestEnvelope(bucket: 16)).emit(to: feed)
        let kinds = block.stages.map { $0.kind }
        #expect(block == fluent && block.outputTag == .envelope && kinds == [.stage, .emit])

        let samples = TestSignal.whiteNoise(count: 64 * 5, seed: 302)
        try block.run(on: samples, format: format, blockSize: 64)
        let snapshot = feed.snapshot()
        var expected: [Float] = []
        for bucket in 0 ..< 20 {
            let slice = samples[(bucket * 16) ..< ((bucket + 1) * 16)]
            expected += [slice.min()!, slice.max()!]
        }
        #expect(snapshot.rowCount == 2 && snapshot.values == expected, "twenty buckets of sixteen frames, minimum then maximum")
    }

    /// API-2, O-13: a stage inside `if #available` keeps the domain, and the block is the
    /// pipeline with the stage in it: the condition leaves no trace in the description.
    @Test func aStageInsideAnAvailabilityCheckIsPartOfThePipeline() throws {
        let guarded = Pipeline {
            TestGain(2)
            if #available(iOS 16, *) {
                TestLate(latency: 0, chunk: 64)
                TestGain(3)
            }
        }
        let plain = Pipeline { TestGain(2); TestLate(latency: 0, chunk: 64); TestGain(3) }
        #expect(guarded == plain)
        let noise = TestSignal.whiteNoise(count: 128, seed: 303)
        let expected = noise.map { (sample: Float) -> Float in -(sample * 2) * 3 }
        #expect(try guarded.process(noise, format: format, blockSize: 64) == expected, "the test node inverts")
    }

    // MARK: Bound results (OUT-4)

    /// OUT-4: a binding has no identity, so all bound results of one kind are one value: equal,
    /// and with one hash. The three kinds differ.
    @Test func boundResultsOfOneKindAreOneValue() throws {
        let first = StateBox<Float>(0), second = StateBox<Float>(1)
        let frame = StateBox(ScalarFrame.none), vector = StateBox<[Float]>([])
        let a = first.binding.boundResult, b = second.binding.boundResult
        #expect(a == b && a.hashValue == b.hashValue)
        let all: Set<BoundResult> = [a, b, frame.binding.boundResult, vector.binding.boundResult]
        let kinds = Set(all.map { $0.kind }), names = Set(all.map { $0.name })
        #expect(all.count == 3 && kinds == [.value, .frame, .vector])
        #expect(names == ["Binding<Float>", "Binding<ScalarFrame>", "Binding<[Float]>"])
        // So two pipelines that differ in which binding they hold are one description (ACT-12).
        let one = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestMean()).emit(to: first.binding)
        let other = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().appending(TestMean()).emit(to: second.binding)
        #expect(one == other && one.hashValue == other.hashValue)

        // What an error calls such a sink is the type of its binding (ATT-5 names sinks in its
        // errors): as the description holds it, and as the plan does, which keeps a slot of the
        // binding's kind and not the binding (BIND-6).
        let described = Emit(to: first.binding).sink.name, vectors = Emit(to: vector.binding).sink.name
        #expect(described == "Binding<Float>" && vectors == "Binding<[Float]>")
        let lowered = try PlanCompiler(crossovers: .shipped).lower(one.stages, environment: environment, blockSize: 64)
        guard case .emission(let emission)? = lowered.steps.last else {
            Issue.record("the pipeline ends in its sink")
            return
        }
        #expect(emission.sink.name == "Binding<Float>" && emission.sink.identity == nil && emission.resultOrdinal == 0 && lowered.results.count == 1)
    }

    // MARK: Steps (§5.5.3, §5.5.4, §9.3)

    /// §9.3: an error raised for a stage carries the stage's path, so every step the compiler
    /// makes knows where its stage stood: a sink, a branch and a switched group as much as a
    /// kernel. The path is left out of every comparison (SWAP-1, F5).
    @Test func everyStepKnowsThePathOfItsStage() throws {
        let sink = CollectingSink<Samples>()
        let pipeline = Pipeline {
            TestGain(2)
            Tap { TestGain(3); Emit(to: sink) }
            ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestGain(4); TestDelay(2) }
        }
        let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: 64)
        guard lowered.steps.count == 3, case .kernel(let gain) = lowered.steps[0], case .branch(let branch) = lowered.steps[1],
              case .region(let region) = lowered.steps[2], branch.steps.count == 2, case .emission(let emission) = branch.steps[1] else {
            Issue.record("a kernel, a branch that ends in a sink, and a switched group were expected: \(lowered.steps.count) steps")
            return
        }
        #expect(gain.path.description == "TestGain[0]")
        #expect(branch.origin.path.description == "Tap[1]")
        #expect(emission.origin.path.description == "Tap[1] › Emit[1]")
        #expect(region.path.description == "Group[2]" && region.steps.count == 2)

        // The same branch written at another place is the same step.
        let moved = Pipeline { TestGain(2); TestBarrier(); TestBarrier(); Tap { TestGain(3); Emit(to: sink) } }
        let again = try PlanCompiler(crossovers: .shipped).lower(moved.stages, environment: environment, blockSize: 64)
        guard case .branch(let other)? = again.steps.last else {
            Issue.record("the pipeline ends in a branch")
            return
        }
        #expect(other.origin.path.description == "Tap[3]" && IRStep.branch(other) == IRStep.branch(branch) && other.hashValue == branch.hashValue)
    }

    /// §5.5.4, "Topology": two steps that differ at most in what a kernel takes by command (a
    /// gain's factor, a cascade's coefficients at unchanged length) have one structure, and the
    /// place of a step in a plan is keyed by its structure, so a change of values moves nothing
    /// (SWAP-1). Another kind of kernel, another count, a switch, are another structure.
    @Test func theStructureOfAStepLeavesOutTheValuesAKernelTakesByCommand() throws {
        let compiler = PlanCompiler(crossovers: .shipped)
        func first(_ pipeline: Pipeline<Samples, Samples>) throws -> IRStep {
            try #require(try compiler.lower(pipeline.stages, environment: environment, blockSize: 64).steps.first)
        }
        func structure(_ step: IRStep) -> Int {
            var hasher = Hasher()
            step.hashStructure(into: &hasher)
            return hasher.finalize()
        }
        let two = try first(Pipeline { TestGain(2) }), three = try first(Pipeline { TestGain(3) })
        #expect(two != three, "the steps differ")
        #expect(two.hasSameStructure(as: three) && structure(two) == structure(three), "their structure does not")

        let cascade = try first(Pipeline { TestGain(2); TestGain(3) })
        let filter = try first(Pipeline { TestBiquad() }), longer = try first(Pipeline { TestBiquad(count: 2) })
        let bound = try first(Pipeline { TestGain(2, isActive: StateBox(true).binding) })
        #expect(!two.hasSameStructure(as: cascade) && structure(two) != structure(cascade), "one gain and two fused gains")
        #expect(!two.hasSameStructure(as: filter) && !filter.hasSameStructure(as: longer) && structure(filter) != structure(longer), "another kernel, another number of sections")
        #expect(!two.hasSameStructure(as: bound) && structure(two) != structure(bound), "a bound switch is structure")

        // A switched group is compared by its switch, its place and the structure of its steps.
        func group(_ factor: Float, delay: Int) throws -> IRStep {
            try first(Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestGain(factor); TestDelay(delay) } })
        }
        let a = try group(2, delay: 3), b = try group(5, delay: 3), c = try group(2, delay: 4)
        #expect(a != b && a.hasSameStructure(as: b) && structure(a) == structure(b))
        #expect(!a.hasSameStructure(as: c) && structure(a) != structure(c), "another processor inside is another group")
        #expect(!a.hasSameStructure(as: two) && structure(a) != structure(two), "a group is not a kernel")
        #expect(a.isKernelRegion && !two.isKernelRegion, "a group of kernels runs as one kernel (ACT-6)")
        // A group that changes the rate inside, or holds a stage with a switch of its own, runs its steps one by one.
        let changing = try first(Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestSubsample(by: 2); TestZeroStuff(factor: 2) } })
        let switched = try first(Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestGain(2, isActive: StateBox(true).binding); TestDelay(1) } })
        #expect(!changing.isKernelRegion && !switched.isKernelRegion)

        // A tap is compared by its switch and by the structure of what it holds; the bound
        // switch of a stage that changes the rate is a step of its own there, and structure.
        let heard = CollectingSink<Samples>()
        func tap(_ factor: Float, isSwitched: Bool) throws -> IRStep {
            let subsample = isSwitched ? TestSubsample(by: 2, isActive: StateBox(true).binding) : TestSubsample(by: 2)
            return try first(Pipeline().tap { $0.testGain(factor).appending(subsample).emit(to: heard) })
        }
        let quiet = try tap(2, isSwitched: true), loud = try tap(3, isSwitched: true), open = try tap(2, isSwitched: false)
        #expect(quiet != loud && quiet.hasSameStructure(as: loud) && structure(quiet) == structure(loud), "a value inside a tap is not its structure")
        #expect(!quiet.hasSameStructure(as: open) && structure(quiet) != structure(open), "the switch of a stage that changes the rate is")
    }

    /// §5.5.4: a kernel takes by command what its documentation says it takes: the factors of
    /// gains, the taps of an FIR, the coefficients of a cascade, in the order the kernel reads
    /// them. A spec whose values are its structure (a factor of decimation, a tracker's
    /// constants, a kernel of the caller's own) carries nothing: a change there is another
    /// topology, and a plan is compiled for it.
    @Test func aSpecCarriesByCommandWhatItsKernelTakesAndNothingElse() throws {
        func floats(_ spec: KernelSpec) -> [Float]? {
            guard let payload = spec.commandPayload() else { return nil }
            defer { payload.pointer.deallocate() }
            return Array(UnsafeBufferPointer(start: payload.pointer.assumingMemoryBound(to: Float.self), count: payload.count))
        }
        func doubles(_ spec: KernelSpec) -> [Double]? {
            guard let payload = spec.commandPayload() else { return nil }
            defer { payload.pointer.deallocate() }
            return Array(UnsafeBufferPointer(start: payload.pointer.assumingMemoryBound(to: Double.self), count: payload.count))
        }
        #expect(floats(.gain(factor: 2, ramp: 0.01)) == [2])
        #expect(floats(.gainCascade(factors: [2, 1, 3], ramp: 0.01)) == [2, 1, 3] && floats(.channelGains(factors: [0.5, 4], ramp: 0)) == [0.5, 4])
        #expect(floats(.fir(taps: [0.25, 0.5, 0.25], latency: 1)) == [0.25, 0.5, 0.25])
        let section = BiquadSection(b0: 0.2, b1: 0.4, b2: 0.2, a1: -0.3, a2: 0.1)
        #expect(doubles(.biquad(sections: [section, .identity], precision: .double)) == [0.2, 0.4, 0.2, -0.3, 0.1, 1, 0, 0, 0, 0])
        #expect(floats(.gainCascade(factors: [], ramp: 0)) == [], "nothing to say is still a payload: the kernel is told its (empty) list")

        let custom = CustomKernel(name: "K", key: 1) { _, _, _ in ztd_kernel_identity() }
        let structural: [KernelSpec] = [
            .decimator(factor: 2, taps: [0.5, 0.5], latency: 0), .interpolator(factor: 2, taps: [0.5, 0.5], latency: 0),
            .subsample(factor: 2, phase: 0), .zeroStuff(factor: 2),
            .alphaBeta(alpha: 0.5, beta: 0.1, initialPosition: 0, initialVelocity: 0, outputVelocity: false), .custom(custom),
        ]
        for spec in structural { #expect(spec.commandPayload() == nil, "\(spec) takes nothing by command") }
    }

    /// §5.11.1, SWAP-1: "two descriptions with equal names and keys are the same stage". What
    /// a custom kernel is made by is not compared; its name, its key, its rate and its latency are.
    @Test func customKernelsAreComparedByNameKeyRateAndLatency() {
        func kernel(_ name: String = "K", key: Int = 1, interpolation: Int = 1, decimation: Int = 1, latency: Int = 0) -> CustomKernel {
            CustomKernel(name: name, key: key, interpolation: interpolation, decimation: decimation, latencyFrames: latency) { _, _, _ in
                ztd_kernel_identity()
            }
        }
        let reference = kernel()
        #expect(reference == kernel() && reference.hashValue == kernel().hashValue, "made by another closure: the same stage")
        #expect(reference != kernel("L") && reference != kernel(key: 2))
        #expect(reference != kernel(interpolation: 2) && reference != kernel(decimation: 2) && reference != kernel(latency: 3))
        #expect(KernelSpec.custom(reference) == .custom(kernel()) && KernelSpec.custom(reference) != .custom(kernel(latency: 3)))
        // Values below what a kernel can have are brought to it: a rate of at least 1:1, no negative delay.
        let clamped = kernel(interpolation: 0, decimation: -4, latency: -1)
        #expect(clamped.interpolation == 1 && clamped.decimation == 1 && clamped.latencyFrames == 0 && clamped == reference)
    }

    // MARK: Plan emission (WP-311a)

    /// §5.11.1: "A kernel whose `process` is null is taken as a failed allocation". The error
    /// names the stage (§9.3), and the pipeline does not run.
    @Test func aCustomKernelThatCannotBeMadeIsAnAllocationThatFailed() {
        let expected = DSPError.resourceAllocationFailed(
            what: "the kernel of CoverageNoKernel", stage: StagePath().appending("CoverageNoKernel", index: 1))
        #expect(throws: expected) {
            _ = try Pipeline { TestGain(2); CoverageNoKernel() }.process([0, 1, 2], format: format, blockSize: 64)
        }
    }

    /// §5.5.3, pass 6: an analysis step becomes a node, never a kernel of a C plan. Handed to
    /// the kernel factory all the same, it is refused with the stage's path, not run.
    @Test func anAnalysisStepIsNotAKernel() {
        let path = StagePath().appending("TestMean", index: 3)
        let step = AnalysisStep(name: "TestMean", key: 0, output: .scalar) { () throws(DSPError) -> any AnalysisNode in TestMeanNode() }
        let kernel = IRKernel(spec: .analysis(step), origin: StepOrigin(path), position: position(), activation: nil)
        #expect(throws: DSPError.unsupportedConfiguration(reason: "an analysis step is a node, not a kernel", stage: path)) {
            _ = try KernelFactory.make(kernel, crossovers: .shipped)
        }
    }

    /// REAL-5, §5.11.1: a stage on the caller's own kernel states its latency twice, in its
    /// description and in the kernel it makes: "It must equal the `latency_frames` of the kernel
    /// `make` returns". A kernel that runs with another delay than it was described with is
    /// refused, the error names the stage and both figures, and the kernel is destroyed, once.
    @Test func aKernelThatRunsWithAnotherLatencyThanItWasDescribedWithIsRefused() throws {
        let path = StagePath().appending("CoverageLate", index: 2)
        func step(described: Int, actual: UInt32, destroyed: UnsafeMutablePointer<Int32>) -> IRKernel {
            let counter = UInt(bitPattern: destroyed)
            let custom = CustomKernel(name: "CoverageLate", key: described, latencyFrames: described) { _, _, _ in
                var kernel = ztd_kernel_identity()
                kernel.latency_frames = actual
                kernel.state = UnsafeMutableRawPointer(bitPattern: counter)
                kernel.destroy = { state in state?.assumingMemoryBound(to: Int32.self).pointee += 1 }
                return kernel
            }
            return IRKernel(spec: .custom(custom), origin: StepOrigin(path), position: position(), activation: nil)
        }
        let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        destroyed.initialize(to: 0)
        defer { destroyed.deallocate() }

        for described in 1 ... 40 {
            let expected = DSPError.unsupportedConfiguration(
                reason: "CoverageLate is described with a latency of \(described) frames and runs with one of 0: the two must be equal", stage: path)
            #expect(throws: expected) { _ = try KernelFactory.make(step(described: described, actual: 0, destroyed: destroyed), crossovers: .shipped) }
        }
        #expect(destroyed.pointee == 40, "each refused kernel was destroyed, once: \(destroyed.pointee)")

        // Described as it runs, the kernel is the caller's to keep.
        var kept = try KernelFactory.make(step(described: 7, actual: 7, destroyed: destroyed), crossovers: .shipped)
        #expect(kept.latency_frames == 7 && !ztd_kernel_is_null(&kept) && destroyed.pointee == 40)
        ztd_kernel_destroy(&kept)
        #expect(destroyed.pointee == 41)
    }

    // MARK: FrameWriter (§5.11.1)

    /// §5.11.1: a node writes its output through a `FrameWriter`. `emit` sends what the node
    /// declares valid, clamped to the storage it was lent, stamped with the input's time unless
    /// the node says otherwise, and numbered from 0; a block of samples is numbered by its
    /// first sample.
    @Test func aFrameWriterDeliversWhatTheNodeDeclares() {
        let log = CoverageFrameLog()
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        storage.initialize(repeating: 0, count: 4)
        defer {
            counter.deallocate()
            storage.deallocate()
        }

        var real = FrameWriter(format: .real(count: 4), delivery: log, first: UnsafeMutableRawPointer(storage), second: nil, capacity: 4,
                               channelCount: 1, counter: counter, inputTime: 0.5)
        #expect(real.real.count == 4 && real.imaginary.count == 0 && real.minima.count == 0 && real.samples == nil)
        let bins = real.real
        for index in 0 ..< 4 { bins[index] = Float(index + 1) }
        real.emit(count: 3)
        real.emit()
        real.emit(count: 99, time: 2)
        real.emit(count: -1)
        let written = log.frames.map { $0.values }, indices = log.frames.map { $0.index }, times = log.frames.map { $0.time }
        #expect(written == [[1, 2, 3], [1, 2, 3, 4], [1, 2, 3, 4], []], "what is valid, never more than the storage holds")
        #expect(indices == [0, 1, 2, 3] && times == [0.5, 0.5, 2, 0.5])
        #expect(log.frames.allSatisfy { $0.kind == .real })

        // A node that declared one value per frame and emits without one delivers "no value":
        // 0 with confidence 0 (§5.2), numbered like any other frame.
        counter.pointee = 0
        var scalar = FrameWriter(format: .scalar, delivery: log, first: nil, second: nil, capacity: 1, channelCount: 1, counter: counter, inputTime: 1)
        #expect(scalar.real.count == 0 && scalar.samples == nil)
        scalar.emit()
        scalar.emit(scalar: ScalarFrame(value: 7, confidence: 0.5), time: 3)
        let scalars = Array(log.frames.suffix(2))
        let values = scalars.map { $0.scalar }, numbers = scalars.map { $0.index }, stamps = scalars.map { $0.time }
        #expect(scalars.allSatisfy { $0.kind == .scalar } && values == [.none, ScalarFrame(value: 7, confidence: 0.5)])
        #expect(numbers == [0, 1] && stamps == [1, 3] && counter.pointee == 2)
    }

    /// §5.11.1: where a writer's frames go is its delivery's business. The plain delivery takes
    /// a frame and hands it to nobody; the writer still counts it.
    @Test func aWriterWithoutAConsumerCountsItsFramesAndDeliversNone() {
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        let nowhere = FrameDelivery()
        var writer = FrameWriter(format: .scalar, delivery: nowhere, first: nil, second: nil, capacity: 1, channelCount: 1, counter: counter, inputTime: 0)
        writer.emit(scalar: ScalarFrame(value: 1))
        writer.emit(scalar: ScalarFrame(value: 2))
        #expect(counter.pointee == 2, "two frames were emitted")
    }

    // MARK: The engine's own values (§4.5)

    /// §4.5: an engine processes blocks of the size it was made with and chooses
    /// implementations by the table it was given; both can be read back.
    @Test func anEngineSaysWhatItWasMadeWith() {
        let standard = DSPEngine()
        #expect(standard.blockSize == 512 && standard.crossovers == .shipped, "the defaults")
        let table = CrossoverTable(gainKernel: 7, firPartitioned: 99)
        let engine = DSPEngine(blockSize: 128, crossovers: table)
        #expect(engine.blockSize == 128 && engine.crossovers == table && engine.crossovers != .shipped)
        #expect(engine.analysisScheduling == .notStarted, "no session has run: there is no thread yet")
    }

    /// §4.5: a session is `Identifiable`. Its id tells it from every other attachment, of the
    /// same pipeline to the same source included, and stays what it is through start, stop and
    /// detach.
    @Test func everyAttachmentHasAnIdentityOfItsOwn() async throws {
        let rig = Rig()
        let pipeline = Pipeline { TestGain(2) }
        let first = try await rig.engine.attach(pipeline, to: rig.source)
        let second = try await rig.engine.attach(pipeline, to: rig.source)
        let id = first.id
        #expect(first.id != second.id)
        try first.start()
        first.stop()
        first.detach()
        #expect(first.id == id && first.state == .detached)
        second.detach()
    }
}
