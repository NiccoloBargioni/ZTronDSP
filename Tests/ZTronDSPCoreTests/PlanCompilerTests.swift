import Foundation
import Testing
import ZTronDSPTesting
@testable import ZTronDSPCore

/// The plan compiler's first passes, seen through the intermediate representation: resolve,
/// validate, lower (WP-306a…c) and fuse (WP-307…310, WP-330a).
@Suite("Plan compiler")
struct PlanCompilerTests {
    private let compiler = PlanCompiler(crossovers: .shipped)
    private let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 512)

    private func lower<O>(_ pipeline: Pipeline<Samples, O>, in environment: DSPEnvironment? = nil) throws -> LoweredPipeline {
        try compiler.lower(pipeline.stages, environment: environment ?? self.environment, blockSize: 512)
    }

    private func kernels(_ steps: [IRStep]) -> [IRKernel] {
        steps.compactMap { if case .kernel(let kernel) = $0 { kernel } else { nil } }
    }

    private func branches(_ steps: [IRStep]) -> [IRBranch] {
        steps.compactMap { if case .branch(let branch) = $0 { branch } else { nil } }
    }

    private func kinds(_ steps: [IRStep]) -> [String] {
        steps.map {
            switch $0 {
            case .kernel(let kernel):
                switch kernel.spec {
                case .gain: "gain"
                case .gainCascade(let factors, _): "gains×\(factors.count)"
                case .biquad(let sections, _): "biquad×\(sections.count)"
                case .fir(let taps, _): "fir×\(taps.count)"
                case .subsample: "subsample"
                default: "kernel"
                }
            case .node(let node): "node:\(node.step.name)"
            case .emission: "emit"
            case .branch(let branch): branch.isShared ? "shared" : "branch"
            case .region: "region"
            case .gate: "gate"
            }
        }
    }

    // MARK: Resolve (WP-306a)

    @Test func readersAreExpandedAgainstThePositionalEnvironment() throws {
        let pipeline = Pipeline {
            EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.nyquistFrequency * 0.5)) }
            TestSubsample(by: 2)
            EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.nyquistFrequency * 0.5)) }
        }
        let lowered = try lower(pipeline)
        #expect(lowered.resolved.map(\.name) == ["TestLowPass", "TestSubsample", "TestLowPass"], "the readers are gone")
        #expect(lowered.resolved[0].stage(as: TestLowPass.self)?.cutoff == .hertz(12_000))
        #expect(lowered.resolved[2].stage(as: TestLowPass.self)?.cutoff == .hertz(6_000), "the second reader sees half the rate (ENV-1)")
        // Two readers that produce equal stages resolve to equal descriptions.
        let other = Pipeline {
            EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.sampleRate / 4)) }
            TestSubsample(by: 2)
            TestLowPass(cutoff: .hertz(6_000))
        }
        #expect(try lower(other).resolved == lowered.resolved)
        #expect(try lower(pipeline, in: DSPEnvironment(sampleRate: 44_100)).resolved != lowered.resolved)
    }

    @Test func stagePathsAreRecorded() throws {
        let pipeline = Pipeline {
            TestGain(0.5)
            Tap {
                TestFramer(frame: 64, hop: 16)
                TestMagnitude()
            }
            Group { TestBiquad(); TestFIR([0.5, 0.5], isActive: StateBox(true).binding) }
        }
        let lowered = try lower(pipeline)
        let branch = try #require(branches(lowered.steps).first)
        guard case .node(let framer) = branch.steps[0], case .node(let magnitude) = branch.steps[1] else {
            Issue.record("unexpected branch \(kinds(branch.steps))"); return
        }
        #expect(framer.path.description == "Tap[1] › TestFramer[0]")
        #expect(magnitude.path.description == "Tap[1] › TestMagnitude[1]")
        let all = kernels(lowered.steps)
        #expect(all.map(\.path.description) == ["TestGain[0]", "Group[2] › TestBiquad[0]", "Group[2] › TestFIR[1]"])
    }

    @Test func thePositionIsThreadedThroughTheStages() throws {
        let stream = CollectingSink<Scalar>()
        let lowered = try lower(Pipeline {
            TestFIR([0.25, 0.5, 0.25])              // latency 1 frame
            TestSubsample(by: 4)
            TestFramer(frame: 64, hop: 16)
            TestMagnitude()
            TestMean()
            TestGain(2)                             // a sequence stage on a scalar track
            Emit(to: stream)
        })
        #expect(kinds(lowered.steps) == ["fir×3", "subsample", "node:TestFramer", "node:TestMagnitude", "node:TestMean", "gain", "emit"])
        let all = kernels(lowered.steps)
        #expect(all[0].position.environment.sampleRate == 48_000 && all[0].position.maximumFrames == 512)
        #expect(all[1].position.environment.latency == 1.0 / 48_000, "the FIR's latency is accounted for downstream (REAL-5)")
        guard case .node(let framer) = lowered.steps[2], case .node(let mean) = lowered.steps[4] else { Issue.record("no nodes"); return }
        #expect(framer.position.environment.sampleRate == 12_000 && framer.position.maximumFrames == 129)
        #expect(framer.position.domain == .samples && framer.outputDomain == .spectrum(axis: .linear, values: .complex))
        #expect(mean.position.environment.frameSize == 64 && mean.position.environment.featureRate == 750)
        #expect(mean.outputDomain == .scalar)
        // Downstream of the scalar step: a new sampled sequence at the feature rate, no spectral scope.
        let gain = all[2]
        #expect(gain.position.domain == .scalar && gain.position.environment.sampleRate == 750)
        #expect(gain.position.environment.frameSize == nil && gain.position.maximumFrames == 1 && gain.position.kernelChannels == 1)
        #expect(lowered.output.domain == .scalar && lowered.output.environment.sampleRate == 750)
        #expect(lowered.sourceEnvironment == environment)
    }

    @Test func scopedOverridesReachOnlyTheirScope() throws {
        struct Probe: SequenceStage {
            let id: Int
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                // Encode what the stage saw into a gain the test can read back.
                context.emit(.gain(factor: context.environment.implementation == .native ? 100 + Float(id) : Float(id), ramp: 0))
            }
        }
        let lowered = try lower(Pipeline {
            Probe(id: 2)
            TestBiquad()
            ZTronDSPCore.Group { Probe(id: 3) }.environment(\.implementation, .native)
            TestBiquad()
            Probe(id: 4)
        })
        let factors = kernels(lowered.steps).compactMap { kernel -> Float? in
            if case .gain(let factor, _) = kernel.spec { factor } else { nil }
        }
        #expect(factors == [2, 103, 4], "only the stage inside the scope saw the override (ENV-3)")
        let whole = try lower(Pipeline { Probe(id: 2) }.environment(\.implementation, .native))
        #expect(kernels(whole.steps).first?.spec == .gain(factor: 102, ramp: 0))
        #expect(whole.output.environment.implementation == .automatic, "the override ends with its scope")
    }

    // MARK: Validate (WP-306b)

    /// Tier 2: the order rules on the erased description, each failure naming its stage.
    @Test func anInvalidOrderIsRejectedWithTheStagesPath() throws {
        // A forged description: a sequence stage after a framer. The types would not allow it.
        let forged = Pipeline<Samples, Samples>(unchecked: [
            StageDescription(TestFramer(frame: 64, hop: 16), rule: .fixed(.samples, .spectrum(axis: .linear, values: .complex))),
            StageDescription(TestGain(0.5), rule: .sequence),
        ])
        #expect(throws: DSPError.invalidStageOrder(stage: StagePath().appending("TestGain", index: 1), found: .spectrum(axis: .linear, values: .complex))) {
            try lower(forged)
        }
        // A branch that starts in the wrong domain (O-15).
        let branch = Pipeline<Samples, Samples>(unchecked: [
            StageDescription(TestFramer(frame: 64, hop: 16), rule: .fixed(.samples, .spectrum(axis: .linear, values: .complex))),
        ] + Pipeline { Tap { TestFramer(frame: 32, hop: 8) } }.stages)
        do {
            _ = try lower(branch)
            Issue.record("an invalid branch was accepted")
        } catch let error as DSPError {
            #expect(error.stage?.description == "Tap[1] › TestFramer[0]")
            guard case .invalidStageOrder(_, let found) = error else { Issue.record("unexpected \(error)"); return }
            #expect(found == .spectrum(axis: .linear, values: .complex))
        }
        // A sink that cannot hold the domain (O-11).
        let sink = Pipeline<Samples, Samples>(unchecked: Pipeline().emit(to: CollectingSink<Samples>()).stages.map { $0 })
        #expect(throws: Never.self) { try lower(sink) }
        let wrongSink = Pipeline<Samples, Samples>(unchecked: [
            StageDescription(TestFramer(frame: 64, hop: 16), rule: .fixed(.samples, .spectrum(axis: .linear, values: .complex))),
        ] + sink.stages)
        #expect(throws: DSPError.self) { try lower(wrongSink) }
    }

    /// O-16: a frequency lies below the Nyquist frequency at its position.
    @Test func aFrequencyIsCheckedAgainstTheNyquistFrequencyAtItsPosition() throws {
        #expect(throws: Never.self) { try lower(Pipeline { TestLowPass(cutoff: .hertz(10_000)) }) }
        do {
            _ = try lower(Pipeline { TestSubsample(by: 4); TestLowPass(cutoff: .hertz(10_000)) })
            Issue.record("a cutoff above the local Nyquist frequency was accepted")
        } catch let error as DSPError {
            guard case .invalidParameter(let stage, let parameter, let reason) = error else { Issue.record("unexpected \(error)"); return }
            #expect(stage.description == "TestLowPass[1]" && parameter == "cutoff")
            #expect(reason.contains("6000.0"), "the reason names the Nyquist frequency at that position: \(reason)")
        }
        // The same cutoff upstream of the decimator is fine.
        #expect(throws: Never.self) { try lower(Pipeline { TestLowPass(cutoff: .hertz(10_000)); TestSubsample(by: 4) }) }
    }

    @Test func errorsThrownByAStageAreAttributedToIt() throws {
        struct Unstable: SequenceStage {
            func lower(_ context: inout LoweringContext) throws(DSPError) { throw .unstableDesign(maxPoleRadius: 1.02) }
        }
        struct BadFrequency: SequenceStage {
            func lower(_ context: inout LoweringContext) throws(DSPError) { _ = try Frequency.hertz(-1).hertz(sampleRate: 48_000) }
        }
        let path = StagePath().appending("Group", index: 1).appending("Unstable", index: 0)
        #expect(throws: DSPError.unstableDesign(maxPoleRadius: 1.02, stage: path)) {
            try lower(Pipeline { TestGain(1); Group { Unstable() } })
        }
        do {
            _ = try lower(Pipeline { BadFrequency() })
            Issue.record("accepted")
        } catch let error as DSPError {
            #expect(error.stage?.description == "BadFrequency[0]", "a unit's own error gains the stage's path")
        }
        #expect(throws: DSPError.self) { try lower(Pipeline { TestGain(.nan) }) }
        #expect(throws: DSPError.self) { try lower(Pipeline { TestFramer(frame: 8, hop: 9) }) }
    }

    @Test func aKernelOnASignalThatIsNotASequenceIsRefused() throws {
        struct Confused: PipelineStage {
            typealias Input = Spectrum<LinearFrequency, ComplexValues>
            typealias Output = Spectrum<LinearFrequency, ComplexValues>
            func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 2, ramp: 0)) }
        }
        do {
            _ = try lower(Pipeline { TestFramer(frame: 64, hop: 16); Confused() })
            Issue.record("accepted")
        } catch let error as DSPError {
            guard case .unsupportedConfiguration(let reason, let stage) = error else { Issue.record("unexpected \(error)"); return }
            #expect(stage?.description == "Confused[1]" && reason.contains("sampled sequence"))
        }
    }

    @Test func structuralStagesDoNotLowerThemselves() {
        let position = IRPosition(domain: .samples, environment: environment, maximumFrames: 512,
                                  format: .samples(channelCount: 1, maximumFrames: 512))
        var context = LoweringContext(position: position, path: StagePath().appending("Tap", index: 0), crossovers: .shipped)
        #expect(throws: DSPError.self) { try Tap { TestFramer(frame: 64, hop: 16) }.lower(&context) }
        #expect(throws: DSPError.self) { try ZTronDSPCore.Group { TestGain(1) }.lower(&context) }
        #expect(throws: DSPError.self) { try EnvironmentReader { _ in TestGain(1) }.lower(&context) }
        #expect(throws: DSPError.self) { try Pipeline { TestGain(1) }.lower(&context) }
        #expect(throws: DSPError.self) { try SequenceChain().lower(&context) }
        #expect(throws: DSPError.self) { try Emit(to: CollectingSink<Samples>()).lower(&context) }
        #expect(context.specs.isEmpty)
        #expect(context.domain == DomainTag.samples && context.channelCount == 1 && context.maximumBlockFrames == 512)
        #expect(context.implementation(for: .gainKernel, size: 512) == .accelerate && context.implementation(for: .gainKernel, size: 64) == .native)
    }

    // MARK: Fusion (WP-307, WP-308, WP-309)

    @Test func adjacentGainsFuseAndIdentitiesAreRemoved() throws {
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            TestGain(1)                 // unity: removed (F4)
            TestGain(2)
            TestGain(0.25)
            TestBiquad(count: 0)        // an empty cascade: removed (F4)
            TestGain(4)
        })
        #expect(kinds(lowered.steps) == ["gains×4"])
        #expect(kernels(lowered.steps)[0].spec == .gainCascade(factors: [0.5, 2, 0.25, 4], ramp: 0.010), "applied in sequence, not multiplied (CR-006)")
        #expect(try lower(Pipeline { TestGain(1) }).steps.isEmpty, "a pipeline of identities compiles to nothing")
        #expect(kinds(try lower(Pipeline { TestGain(3) }).steps) == ["gain"], "a single gain stays a gain")
        #expect(KernelSpec.fir(taps: [1], latency: 0).isIdentity && !KernelSpec.fir(taps: [1], latency: 2).isIdentity)
        #expect(KernelSpec.gainCascade(factors: [1, 1], ramp: 0).isIdentity && KernelSpec.channelGains(factors: [1, 1], ramp: 0).isIdentity)
        #expect(!KernelSpec.subsample(factor: 1, phase: 0).isIdentity)
    }

    @Test func adjacentCascadesOfOnePrecisionBecomeOne() throws {
        let lowered = try lower(Pipeline { TestBiquad(count: 4); TestBiquad(count: 4) })
        #expect(kinds(lowered.steps) == ["biquad×8"], "two 4-section stages are one setup with all sections (F2)")
        let mixed = try lower(Pipeline { TestBiquad(count: 2, precision: .single); TestBiquad(count: 2, precision: .double); TestBiquad(count: 1, precision: .double) })
        #expect(kinds(mixed.steps) == ["biquad×2", "biquad×3"], "cascades of different precision stay apart")
        let automatic = try lower(Pipeline { TestBiquad(count: 2, precision: .automatic) })
        #expect(kernels(automatic.steps)[0].spec == .biquad(sections: [BiquadSection](repeating: TestBiquad().section, count: 2), precision: .single))
    }

    @Test func adjacentShortFIRFiltersAreConvolvedUnderTheLengthBound() throws {
        let lowered = try lower(Pipeline { TestFIR([1, 2, 3]); TestFIR([0.5, -0.5]) })
        #expect(kinds(lowered.steps) == ["fir×4"])
        #expect(kernels(lowered.steps)[0].spec == .fir(taps: [0.5, 0.5, 0.5, -1.5], latency: 1), "the taps are convolved and the latencies add (F3)")
        // Combined length at the direct / partitioned crossover: not fused.
        let long = [Float](repeating: 0.01, count: 200)
        #expect(kinds(try lower(Pipeline { TestFIR(long); TestFIR([Float](repeating: 0.1, count: 57)) }).steps) == ["fir×200", "fir×57"])
        #expect(kinds(try lower(Pipeline { TestFIR(long); TestFIR([Float](repeating: 0.1, count: 56)) }).steps) == ["fir×255"])
        #expect(PlanCompiler.convolve([1, 1], [1, -1]) == [1, 0, -1])
    }

    @Test func fusionDoesNotCrossATapASinkOrADifferentKindOfKernel() throws {
        let stream = CollectingSink<Samples>()
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            Tap { TestFramer(frame: 64, hop: 16) }
            TestGain(2)
            Emit(to: stream)
            TestGain(3)
            TestBiquad()
            TestGain(4)
        })
        #expect(kinds(lowered.steps) == ["gain", "branch", "gain", "emit", "gain", "biquad×1", "gain"])
    }

    // MARK: Activation in the compiler (WP-330a)

    @Test func aBypassedConstantLeavesNoKernel() throws {
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            TestBiquad(count: 4, isActive: false)
            TestGain(2)
            Group(isActive: .bypassed) { TestFIR([1, 2]); TestGain(7) }
        })
        #expect(kinds(lowered.steps) == ["gains×2"], "the bypassed stages are gone and their neighbours fused across the gap (ACT-4)")
        #expect(lowered.switches.isEmpty)
        #expect(lowered.resolved.count == 4, "the description still holds them: a constant flip is a topology change (ACT-12)")
    }

    @Test func aBypassedConstantThatChangesTheDomainRemovesTheRestOfItsBranch() throws {
        let a = CollectingSink<Samples>(), b = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            Tap {
                Emit(to: a)
                TestFramer(frame: 64, hop: 16, isActive: false)       // changes the domain: the rest of the tap is suspended
                TestMagnitude()
                Emit(to: b)
            }
            TestGain(2)
        })
        #expect(kinds(lowered.steps) == ["gain", "branch", "gain"], "the main line is untouched")
        #expect(kinds(branches(lowered.steps)[0].steps) == ["emit"], "what came before the stage stays, what follows is removed (ACT-3, ACT-4)")
        // On the main line: everything after the stage.
        let main = try lower(Pipeline { TestGain(0.5); TestSubsample(by: 2, isActive: false); TestGain(3); TestBiquad() })
        #expect(kinds(main.steps) == ["gain"])
        // The rest is still validated: an invalid stage behind a bypassed one is still an error.
        #expect(throws: DSPError.self) { try lower(Pipeline { TestSubsample(by: 2, isActive: false); TestGain(.nan) }) }
    }

    @Test func aBoundStageIsNotFusedWithItsNeighbours() throws {
        let presence = StateBox(true).binding
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            TestGain(2, isActive: presence)
            TestGain(4)
            TestBiquad(count: 2)
            TestBiquad(count: 2, isActive: presence)
            TestBiquad(count: 2)
        })
        #expect(kinds(lowered.steps) == ["gain", "gain", "gain", "biquad×2", "biquad×2", "biquad×2"], "a bound activation is a fusion barrier (ACT-6)")
        let all = kernels(lowered.steps)
        #expect(all.map { $0.activation?.ordinal } == [nil, 0, nil, nil, 1, nil], "each bound stage is its own switch, even on one binding")
        #expect(lowered.switches.count == 2)
        // Even a unity gain keeps its kernel when it is bound: it must be switchable.
        #expect(kinds(try lower(Pipeline { TestGain(1, isActive: presence) }).steps) == ["gain"])
    }

    @Test func theContentOfASwitchedGroupFusesInside() throws {
        let presence = StateBox(true).binding
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            Group(isActive: presence) { TestBiquad(count: 2); TestBiquad(count: 3) }
            TestGain(2)
        })
        #expect(kinds(lowered.steps) == ["gain", "biquad×5", "gain"], "one fused cascade under one switch (ACT-6)")
        #expect(kernels(lowered.steps)[1].activation == IRSwitch(ordinal: 0))
        // A group that does not fuse to one kernel is a region under one switch.
        let region = try lower(Pipeline { Group(isActive: presence) { TestBiquad(); TestFIR([0.5, 0.5]) } })
        #expect(kinds(region.steps) == ["region"])
        guard case .region(let inner) = region.steps[0] else { return }
        #expect(kinds(inner.steps) == ["biquad×1", "fir×2"] && inner.activation.ordinal == 0 && inner.position.domain == .samples)
    }

    @Test func aBoundStageThatChangesTheDomainOrTheRateIsAGate() throws {
        let on = StateBox(true).binding
        let stream = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>()
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            Tap(isActive: on) {
                TestFramer(frame: 64, hop: 16, isActive: on)
                Emit(to: stream, isActive: on)
            }
            TestSubsample(by: 2, isActive: on)
            TestGain(2)
        })
        #expect(kinds(lowered.steps) == ["gain", "branch", "gate", "subsample", "gain"])
        let branch = branches(lowered.steps)[0]
        #expect(kinds(branch.steps) == ["gate", "node:TestFramer", "emit"])
        #expect(lowered.switches.count == 4)
        // Ordinals are assigned in the order the stages close: the framer, the sink, then the tap, then the main line.
        guard case .gate(let framerSwitch, let origin) = branch.steps[0], case .emission(let sink) = branch.steps[2],
              case .gate(let rateSwitch, _) = lowered.steps[2] else { Issue.record("unexpected shape"); return }
        #expect(framerSwitch.ordinal == 0 && sink.activation?.ordinal == 1 && branch.activation?.ordinal == 2 && rateSwitch.ordinal == 3)
        #expect(origin.path.description == "Tap[1] › TestFramer[0]")
    }

    @Test func boundResultsAreCollectedInOrder() throws {
        let value = StateBox(Float(0)).binding, frame = StateBox(ScalarFrame.none).binding
        let lowered = try lower(Pipeline {
            TestFramer(frame: 64, hop: 16)
            TestMagnitude()
            TestMean()
            Emit(to: value)
            Emit(to: frame, isActive: false)        // removed: it contributes no slot
            Emit(to: frame)
        })
        #expect(lowered.results.map(\.kind) == [.value, .frame])
        let ordinals = lowered.steps.compactMap { step -> Int? in if case .emission(let sink) = step { sink.resultOrdinal } else { nil } }
        #expect(ordinals == [0, 1])
    }

    // MARK: Shared work (WP-310, at the level of the plan's shape)

    @Test func equalLeadingStepsOfSiblingBranchesAreComputedOnce() throws {
        let a = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>(), b = CollectingSink<Scalar>()
        let c = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>(), d = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>()
        let showMel = StateBox(true).binding
        let lowered = try lower(Pipeline {
            TestGain(0.5)
            Tap { TestFramer(frame: 64, hop: 16); TestMagnitude(); Emit(to: a) }
            Tap(isActive: showMel) { TestFramer(frame: 64, hop: 16); TestMagnitude(); TestMean(); Emit(to: b) }
            Tap { TestFramer(frame: 64, hop: 16); Emit(to: c) }
            Tap { TestFramer(frame: 32, hop: 8); Emit(to: d) }          // another framing: not shared
        })
        #expect(kinds(lowered.steps) == ["gain", "shared", "branch"])
        let shared = branches(lowered.steps)[0]
        #expect(shared.isShared && shared.activation == nil)
        #expect(kinds(shared.steps) == ["node:TestFramer", "shared", "branch"], "one framer for three taps (F5)")
        let magnitudes = branches(shared.steps)[0]
        #expect(kinds(magnitudes.steps) == ["node:TestMagnitude", "branch", "branch"], "and the equal run that follows is shared too")
        let leaves = branches(magnitudes.steps)
        #expect(kinds(leaves[0].steps) == ["emit"] && leaves[0].activation == nil)
        #expect(kinds(leaves[1].steps) == ["node:TestMean", "emit"] && leaves[1].activation == IRSwitch(ordinal: 0), "each tap keeps its own switch")
        #expect(kinds(branches(shared.steps)[1].steps) == ["emit"])
        #expect(kinds(branches(lowered.steps)[1].steps) == ["node:TestFramer", "emit"])
    }

    @Test func branchesAtDifferentPositionsShareNothing() throws {
        let a = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>(), b = CollectingSink<Spectrum<LinearFrequency, ComplexValues>>()
        let lowered = try lower(Pipeline {
            Tap { TestFramer(frame: 64, hop: 16); Emit(to: a) }
            TestGain(0.5)                                               // the signal changes between the two taps
            Tap { TestFramer(frame: 64, hop: 16); Emit(to: b) }
        })
        #expect(kinds(lowered.steps) == ["branch", "gain", "branch"])
    }

    @Test func aBranchWithNothingInItIsDropped() throws {
        let lowered = try lower(Pipeline { TestGain(0.5); Tap { TestGain(1) }; TestGain(2) })
        #expect(kinds(lowered.steps) == ["gains×2"], "a tap that compiles to nothing is no tap point")
    }

    // MARK: Structure for the plan difference (WP-312)

    @Test func stepsOfOneStructureDifferOnlyInValues() throws {
        let base = try lower(Pipeline { TestGain(0.5); TestBiquad(count: 2); TestFIR([1, 2, 3]) })
        let values = try lower(Pipeline { TestGain(0.7); TestBiquad(BiquadSection(b0: 1, b1: 0, b2: 0, a1: 0.5, a2: 0), count: 2); TestFIR([3, 2, 1]) })
        #expect(base.steps != values.steps)
        #expect(IRStep.sameStructure(base.steps, values.steps), "a cutoff or a gain changed: same topology")
        let order = try lower(Pipeline { TestGain(0.5); TestBiquad(count: 3); TestFIR([1, 2, 3]) })
        #expect(!IRStep.sameStructure(base.steps, order.steps), "another section count is another topology")
        let length = try lower(Pipeline { TestGain(0.5); TestBiquad(count: 2); TestFIR([1, 2, 3, 4]) })
        #expect(!IRStep.sameStructure(base.steps, length.steps), "another tap count is another topology")
        let bound = try lower(Pipeline { TestGain(0.5, isActive: StateBox(true).binding); TestBiquad(count: 2); TestFIR([1, 2, 3]) })
        #expect(!IRStep.sameStructure(base.steps, bound.steps), "a bound activation is structure")
        #expect(IRStep.sameStructure(base.steps, base.steps))
    }
}
