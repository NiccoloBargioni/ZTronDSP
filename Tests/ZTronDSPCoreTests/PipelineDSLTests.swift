import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("Pipeline DSL (WP-301…304, WP-325, WP-326, WP-329)")
struct PipelineDSLTests {
    // MARK: Descriptions

    @Test func aDescriptionIsHashableAndCarriesItsRule() {
        let gain = StageDescription(TestGain(0.5), rule: .sequence)
        #expect(gain == StageDescription(TestGain(0.5), rule: .sequence))
        #expect(gain != StageDescription(TestGain(0.6), rule: .sequence))
        #expect(gain != StageDescription(TestFIR([0.5]), rule: .sequence), "another stage type, whatever its fields")
        #expect(gain.name == "TestGain" && gain.kind == .stage && gain.activation == .active)
        #expect(gain.stage(as: TestGain.self)?.factor == 0.5 && gain.stage(as: TestFIR.self) == nil)
        #expect(Set([gain, gain, StageDescription(TestGain(0.6), rule: .sequence)]).count == 2)
        #expect(gain.nestedStages.isEmpty)
        let sendable: any Sendable = gain
        #expect(sendable is StageDescription)
    }

    /// Each rule maps tags as §5.2 states.
    @Test func rulesMapTagsAsTheDomainTableStates() {
        let complex = DomainTag.spectrum(axis: .linear, values: .complex)
        #expect(DomainRule.sequence(.samples) == .samples && DomainRule.sequence(.novelty) == .novelty && DomainRule.sequence(.scalar) == .scalar)
        #expect(DomainRule.sequence(complex) == nil && DomainRule.sequence(.chroma) == nil, "O-1")
        #expect(DomainRule.fixed(.samples, complex)(.samples) == complex)
        #expect(DomainRule.fixed(.samples, complex)(complex) == nil && DomainRule.fixed(.samples, complex)(.novelty) == nil, "O-15")
        #expect(DomainRule.any(.chroma) == .chroma && DomainRule.any(complex) == complex)
        #expect(TestMagnitude.rule(complex) == .spectrum(axis: .linear, values: .magnitude))
        #expect(TestMagnitude.rule(.spectrum(axis: .mel, values: .complex)) == .spectrum(axis: .mel, values: .magnitude), "the axis is kept")
        #expect(TestMagnitude.rule(.spectrum(axis: .linear, values: .power)) == nil && TestMagnitude.rule(.samples) == nil, "O-3")
        let scalarSink = DomainRule.keeping("scalars") { $0.isScalarValued }
        #expect(scalarSink(.scalar) == .scalar && scalarSink(complex) == nil, "O-11")
        #expect(DomainRule.sequence == DomainRule.sequence && DomainRule.sequence != DomainRule.any)
        #expect(DomainRule.fixed(.samples, .chroma) != DomainRule.fixed(.samples, .lags))
        #expect(DomainRule("mine") { $0 } == DomainRule("mine") { _ in nil }, "a rule is identified by its name")
    }

    // MARK: Two spellings, one description (API-1)

    @Test func builderAndFluentSpellingsAreEqual() {
        let stream = CollectingSink<Spectrum<LinearFrequency, MagnitudeValues>>()
        for extra in [false, true] {
            let built = Pipeline {
                TestGain(0.5)
                TestFIR([0.25, 0.5, 0.25])
                if extra { TestGain(2) }
                Tap {
                    TestFramer(frame: 64, hop: 16)
                    TestMagnitude()
                    Emit(to: stream)
                }
            }
            var fluent = Pipeline().testGain(0.5).testFIR([0.25, 0.5, 0.25])
            if extra { fluent = fluent.testGain(2) }
            fluent = fluent.tap { $0.testFramer(frame: 64, hop: 16).testMagnitude().emit(to: stream) }
            #expect(built == fluent, "extra stage present: \(extra)")
            #expect(built.hashValue == fluent.hashValue)
            #expect(built.stages.count == (extra ? 4 : 3), "an absent optional stage leaves no trace")
        }
    }

    @Test func aPipelineIsAValueOfDescriptions() {
        let pipeline = Pipeline { TestGain(0.5); TestGain(2) }
        #expect(pipeline == pipeline)
        #expect(pipeline != Pipeline { TestGain(0.5); TestGain(3) })
        #expect(pipeline != Pipeline { TestGain(2); TestGain(0.5) }, "order is part of the description")
        #expect(pipeline.stages.map(\.name) == ["TestGain", "TestGain"])
        #expect(Pipeline().stages.isEmpty)
        #expect(pipeline.inputTag == .samples && pipeline.outputTag == .samples)
        let spectral = Pipeline { TestFramer(frame: 32, hop: 8) }
        #expect(spectral.outputTag == .spectrum(axis: .linear, values: .complex))
        #expect(Pipeline<Samples, Samples>(unchecked: pipeline.stages) == pipeline)
    }

    @Test func nestedPipelinesAndChainsAreSpliced() {
        let inner = Pipeline { TestGain(0.5); TestGain(0.25) }
        let chain = SequenceChain(stages: inner.stages)
        let nested = Pipeline {
            inner
            TestGain(2)
        }
        #expect(nested == Pipeline { TestGain(0.5); TestGain(0.25); TestGain(2) }, "nesting leaves no trace")
        #expect(Pipeline().appending(chain).appending(TestGain(2)) == nested)
        #expect(Pipeline { chain; TestGain(2) } == nested)
    }

    // MARK: Control flow (API-2, ORD-3)

    @Test func controlFlowBuildsTheExpectedDescriptions() {
        func build(_ deEss: Bool, _ mode: Int, _ repeats: Int) -> Pipeline<Samples, Samples> {
            Pipeline {
                TestGain(0.5)
                if deEss { TestFIR([1, -1]) }
                if mode == 0 { TestGain(0.1) } else { TestGain(0.2) }
                switch mode {
                case 1: TestBiquad(count: 1)
                case 2: TestBiquad(count: 2)
                default: TestBiquad(count: 3)
                }
                for index in 0 ..< repeats { TestGain(Float(index + 1)) }
                if #available(iOS 17.0, *) { TestGain(9) } else { TestGain(8) }
                if #available(iOS 99.0, *) { TestGain(99) }
            }
        }
        #expect(build(false, 0, 0).stages.map(\.name) == ["TestGain", "TestGain", "TestBiquad", "TestGain"])
        #expect(build(true, 0, 0).stages.count == 5)
        #expect(build(false, 0, 3).stages.count == 7)
        #expect(build(false, 0, 0).stages[1].stage(as: TestGain.self)?.factor == 0.1)
        #expect(build(false, 2, 0).stages[1].stage(as: TestGain.self)?.factor == 0.2)
        #expect(build(false, 1, 0).stages[2].stage(as: TestBiquad.self)?.count == 1)
        #expect(build(false, 2, 0).stages[2].stage(as: TestBiquad.self)?.count == 2)
        #expect(build(false, 7, 0).stages[2].stage(as: TestBiquad.self)?.count == 3)
        #expect(build(false, 0, 2).stages[3 ... 4].map { $0.stage(as: TestGain.self)!.factor } == [1, 2])
        #expect(build(false, 0, 0).stages.last?.stage(as: TestGain.self)?.factor == 9)
    }

    @Test func domainKeepingStagesMayBeOptionalOrRepeated() {
        // O-13: a tap keeps the domain, so it may sit in `if` and `for`.
        func build(_ taps: Int, _ extra: Bool) -> Pipeline<Samples, Spectrum<LinearFrequency, ComplexValues>> {
            Pipeline {
                TestGain(0.5)
                for hop in 0 ..< taps {
                    Tap { TestFramer(frame: 64, hop: 16 + hop) }
                }
                if extra {
                    Tap { TestFramer(frame: 32, hop: 8) }
                }
                TestFramer(frame: 128, hop: 32)
            }
        }
        #expect(build(0, false).stages.map(\.name) == ["TestGain", "TestFramer"])
        #expect(build(2, true).stages.map(\.name) == ["TestGain", "Tap", "Tap", "Tap", "TestFramer"])
    }

    // MARK: Structure

    @Test func aTapHoldsItsBranchAndKeepsTheMainLine() {
        let pipeline = Pipeline {
            TestGain(0.5)
            Tap {
                TestFramer(frame: 64, hop: 16)
                TestMagnitude()
            }
            TestGain(2)
        }
        #expect(pipeline.outputTag == .samples, "the main line stays in the time domain")
        let tap = pipeline.stages[1]
        #expect(tap.kind == .tap && tap.name == "Tap" && tap.nestedStages.map(\.name) == ["TestFramer", "TestMagnitude"])
        // Nested branches.
        let nested = Pipeline {
            Tap {
                TestFramer(frame: 64, hop: 16)
                TestMagnitude()
                Tap { TestMean() }
            }
        }
        #expect(nested.stages[0].nestedStages[2].nestedStages.map(\.name) == ["TestMean"])
        // A branch of sequence stages only taps samples.
        #expect(Pipeline { Tap { TestGain(0.5) } }.stages[0].nestedStages.count == 1)
    }

    @Test func aGroupHasTheTypeOfItsContent() {
        let sequence = Pipeline {
            Group { TestGain(0.5); TestGain(0.25) }
            TestGain(2)
        }
        #expect(sequence.stages.map(\.kind) == [.group, .stage])
        #expect(sequence.stages[0].nestedStages.count == 2)
        let typed = Pipeline {
            Group { TestFramer(frame: 64, hop: 16); TestMagnitude() }
            TestMean()
        }
        #expect(typed.outputTag == .scalar, "the group moved the chain to magnitudes, as its content does")
        #expect(Group { TestGain(1) } == Group { TestGain(1) } && Group { TestGain(1) } != Group { TestGain(2) })
        #expect(Group(isActive: false) { TestGain(1) } != Group { TestGain(1) })
    }

    @Test func environmentOverridesAreScopedAndReturnNewValues() {
        let base = Pipeline { TestGain(0.5) }
        let forced = base.environment(\.implementation, .native)
        #expect(base.stages.count == 1 && base.stages[0].kind == .stage, "the original is unchanged (IMM-5)")
        #expect(forced.stages.count == 1 && forced.stages[0].kind == .group)
        #expect(forced == base.environment(\.implementation, .native))
        #expect(forced != base.environment(\.implementation, .accelerate) && forced != base)
        let twice = forced.environment(\.resultRate, 60)
        #expect(twice.stages.count == 1 && twice.stages[0].nestedStages.count == 1, "a second override joins the scope instead of nesting")
        #expect(twice.environment(\.implementation, .native) == base.environment(\.resultRate, 60).environment(\.implementation, .native))
        // This file imports SwiftUI, which has a Group and an .environment of its own: qualify.
        let group = ZTronDSPCore.Group { TestGain(1) }.environment(\.biquadPrecision, .double)
        #expect(group != ZTronDSPCore.Group { TestGain(1) })
        #expect(group == ZTronDSPCore.Group { TestGain(1) }.environment(\.biquadPrecision, .single).environment(\.biquadPrecision, .double))
    }

    @Test func readersCompareByWhatTheyProduce() {
        let first = Pipeline { EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.nyquistFrequency * 0.5)) } }
        let second = Pipeline { EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.nyquistFrequency / 2)) } }
        #expect(first == first, "a pipeline equals its copy")
        #expect(first == second, "two readers that produce equal stages are equal (API-1)")
        #expect(first.hashValue == second.hashValue)
        #expect(first != Pipeline { EnvironmentReader { env in TestLowPass(cutoff: .hertz(env.nyquistFrequency * 0.8)) } })
        #expect(first.stages[0].kind == .environmentReader && first.stages[0].nestedStages.isEmpty)
        // A reader has the type of its content.
        let typed = Pipeline { EnvironmentReader { _ in TestFramer(frame: 64, hop: 16) }; TestMagnitude() }
        #expect(typed.outputTag == .spectrum(axis: .linear, values: .magnitude))
    }

    // MARK: Activation (ACT-1, ACT-2, ACT-12)

    @Test func constantActivationsCompareByValueAndBoundOnesAreAllEqual() {
        let a = StateBox(true).binding, b = StateBox(false).binding
        #expect(TestGain(0.5) == TestGain(0.5, isActive: true) && TestGain(0.5) == TestGain(0.5, isActive: .active))
        #expect(TestGain(0.5).stageDescriptions == TestGain(0.5, isActive: true).stageDescriptions, "the default, true and .active give equal descriptions")
        #expect(TestGain(0.5, isActive: false) == TestGain(0.5, isActive: .bypassed))
        #expect(TestGain(0.5, isActive: false) != TestGain(0.5))
        #expect(TestGain(0.5, isActive: a).stageDescriptions != TestGain(0.5).stageDescriptions, "a binding differs from every constant")
        #expect(TestGain(0.5, isActive: a).stageDescriptions != TestGain(0.5, isActive: false).stageDescriptions)
        #expect(TestGain(0.5, isActive: a).stageDescriptions == TestGain(0.5, isActive: b).stageDescriptions, "two bindings give equal descriptions")
        #expect(Pipeline { TestGain(0.5, isActive: a) } == Pipeline { TestGain(0.5, isActive: b) })

        #expect(true.stageActivation == .active && false.stageActivation == .constant(false))
        #expect(Activation.active.stageActivation == .active && Activation.bypassed.stageActivation == .constant(false))
        #expect(Activation.active.isActive && !Activation.bypassed.isActive && Activation.active != Activation.bypassed)
        #expect(a.stageActivation.isBound && !StageActivation.active.isBound)
        #expect(a.stageActivation.constantValue == nil && StageActivation.constant(false).constantValue == false)
        #expect(a.stageActivation == b.stageActivation)
    }

    @Test @MainActor func aBoundSwitchReadsItsBindingOnTheMainActor() {
        let state = StateBox(true)
        guard case .bound(let bound) = state.binding.stageActivation else { Issue.record("not bound"); return }
        #expect(bound.read())
        state.value = false
        #expect(!bound.read(), "the binding is read each time, never cached")
    }

    @Test func anyStageGetsItsSwitchFromTheModifier() {
        let binding = StateBox(true).binding
        let framer = TestFramer(frame: 64, hop: 16)
        #expect(framer.active(true).stageDescriptions == framer.stageDescriptions, "an active switch leaves no trace")
        #expect(framer.active(false).stageDescriptions[0].activation == .constant(false))
        #expect(framer.active(binding).stageDescriptions[0].activation.isBound)
        #expect(framer.active(binding).stageDescriptions[0].name == "TestFramer")
        #expect(TestFIR([1]).active(.bypassed).stageDescriptions[0].activation == .constant(false))
        #expect(type(of: TestFIR([1]).active(false)).stageName == "TestFIR" && type(of: framer.active(false)).stageName == "TestFramer")
        // The switched stage still composes where the bare one does.
        let pipeline = Pipeline { framer.active(binding); TestMagnitude() }
        #expect(pipeline.outputTag == .spectrum(axis: .linear, values: .magnitude))
        #expect(Pipeline { TestGain(1).active(binding) }.stages[0].activation.isBound)
        // A switch around something that is already switched becomes a group: both switches stay.
        let twice = TestGain(1, isActive: binding).active(binding).stageDescriptions
        #expect(twice.count == 1 && twice[0].kind == .group && twice[0].nestedStages[0].activation.isBound)
        #expect(framer.active(false).parameters.isEmpty && TestGain(2).active(false).parameters == [2])
        #expect(TestGain(2).active(false).replacingParameters([3][...]).base.factor == 3)
    }

    @Test func structureTakesASwitchToo() {
        let binding = StateBox(true).binding
        let stream = CollectingSink<Samples>()
        let pipeline = Pipeline {
            Tap(isActive: binding) { TestFramer(frame: 64, hop: 16) }
            Group(isActive: false) { TestGain(0.5) }
            Emit(to: stream, isActive: binding)
        }
        #expect(pipeline.stages.map(\.activation.isBound) == [true, false, true])
        #expect(pipeline.stages[1].activation == .constant(false))
        #expect(pipeline.stages[2].kind == .emit)
        #expect(Pipeline().tap(isActive: binding) { $0.testFramer(frame: 64, hop: 16) }.stages[0].activation.isBound)
        #expect(Pipeline().emit(to: stream, isActive: false).stages[0].activation == .constant(false))
    }

    // MARK: Sinks (O-11)

    @Test func sinksCompareByIdentityAndBindingsByKind() {
        let a = CollectingSink<Samples>(), b = CollectingSink<Samples>()
        #expect(Pipeline().emit(to: a) == Pipeline().emit(to: a))
        #expect(Pipeline().emit(to: a) != Pipeline().emit(to: b), "another sink is another pipeline")
        let bx = StateBox(Float(0)).binding, by = StateBox(Float(0)).binding
        let bf = StateBox(ScalarFrame.none).binding, bv = StateBox([Float]()).binding
        let scalar = Pipeline { TestFramer(frame: 64, hop: 16); TestMagnitude(); TestMean() }
        #expect(scalar.emit(to: bx) == scalar.emit(to: by), "a binding has no identity (OUT-4)")
        #expect(scalar.emit(to: bx) != scalar.emit(to: bf), "a value and a frame are different deliveries")
        #expect(bx.boundResult.kind == .value && bf.boundResult.kind == .frame && bv.boundResult.kind == .vector)
        let magnitudes = Pipeline { TestFramer(frame: 64, hop: 16); TestMagnitude() }
        #expect(magnitudes.emit(to: bv).stages.last?.kind == .emit)
        // The builder spelling of the same three sinks.
        let built = Pipeline {
            TestFramer(frame: 64, hop: 16)
            TestMagnitude()
            Emit(to: bv)
            TestMean()
            Emit(to: bx)
            Emit(to: bf)
        }
        #expect(built.stages.map(\.kind) == [.stage, .stage, .emit, .stage, .emit, .emit])
        #expect(built == magnitudes.emit(to: bv).appending(TestMean()).emit(to: by).emit(to: bf))
    }

    @Test func aSinkMayOpenABlock() {
        let samples = CollectingSink<Samples>()
        let pipeline = Pipeline {
            Tap { Emit(to: samples) }
            TestGain(0.5)
            Tap { TestGain(2); Emit(to: samples) }
        }
        #expect(pipeline.stages.map(\.kind) == [.tap, .stage, .tap])
        #expect(pipeline.stages[2].nestedStages.map(\.kind) == [.stage, .emit])
    }

    // MARK: Parameters (WP-305)

    @Test func parametersRoundTripAndLeaveStructureOut() {
        let pipeline = Pipeline {
            TestGain(0.5)
            TestLowPass(cutoff: .hertz(1_000))
            TestBiquad(count: 4)                    // structure only: no parameters
            Tap { TestGain(2); TestFramer(frame: 64, hop: 16) }
            Group { TestLowPass(cutoff: .midiNote(69)) }      // one line, in a file that imports SwiftUI
        }
        let vector = pipeline.parameters
        #expect(vector.values == [0.5, log2(1_000.0), 2, 69.0 / 12])
        #expect(pipeline.replacingParameters(vector) == pipeline, "the round trip is the identity")
        let moved = pipeline.replacingParameters(ParameterVector([0.25, log2(2_000.0), 3, 6]))
        #expect(moved.stages[0].stage(as: TestGain.self)?.factor == 0.25)
        expectClose(moved.stages[1].stage(as: TestLowPass.self)!.cutoff.value, 2_000, .relative(1e-12))
        #expect(moved.stages[3].nestedStages[0].stage(as: TestGain.self)?.factor == 3)
        #expect(moved.stages[4].nestedStages[0].stage(as: TestLowPass.self)?.cutoff == Frequency.midiNote(72))
        #expect(moved.stages[2] == pipeline.stages[2], "orders and sizes are structure")
        #expect(moved.parameters.values[0] == 0.25)
        #expect(pipeline.replacingParameters(ParameterVector([1, 2])) == pipeline, "a vector of another length belongs to another topology")
        #expect(Pipeline { EnvironmentReader { _ in TestGain(0.5) } }.parameters.isEmpty, "a reader's stages exist only per environment")
    }
}
