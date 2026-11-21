import Foundation

// The intermediate representation the plan compiler works on between a description and a
// plan (§5.5.3): a tree of steps, each with everything needed to create its run-time object.
// It is what fusion rewrites and what two plans are compared by (§5.5.4).

/// A stage's path as a step carries it: there for error messages, and left out of every
/// comparison. Two steps that do the same work are the same step wherever their stages were
/// written, which is what lets equal branches be shared (F5) and an unchanged stage keep its
/// state when a stage elsewhere in the pipeline comes or goes (SWAP-1).
struct StepOrigin: Hashable, Sendable {
    let path: StagePath

    init(_ path: StagePath) {
        self.path = path
    }

    static func == (lhs: StepOrigin, rhs: StepOrigin) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// A bound activation, by its position among the bound switches of the pipeline.
struct IRSwitch: Hashable, Sendable {
    let ordinal: Int
}

/// Where a step sits in the signal: what the plan needs to size and bind it.
struct IRPosition: Hashable, Sendable {
    /// The domain of the frames the step receives.
    let domain: DomainTag
    /// The environment at the step's input.
    let environment: DSPEnvironment
    /// The most frames a block of samples holds here; 1 on a feature-rate sequence.
    let maximumFrames: Int
    /// The shape of the frames that arrive here: what a sink sizes its storage for.
    let format: FrameFormat

    /// Channels of the sequence a kernel runs on: the signal's channels on samples, one on a
    /// feature-rate sequence.
    var kernelChannels: Int { domain == .samples ? max(environment.channelCount, 1) : 1 }
}

/// A kernel of a sample or feature-rate sequence: everything that runs in a C plan.
struct IRKernel: Hashable, Sendable {
    var spec: KernelSpec
    let origin: StepOrigin
    var path: StagePath { origin.path }
    let position: IRPosition
    /// A bound switch on a kernel that keeps the domain and the rate: a faded bypass.
    var activation: IRSwitch?

    /// True when a kernel of `other`'s spec could take this spec's values without being
    /// re-created: the two differ at most in what a command can carry (§5.5.4).
    func hasSameStructure(as other: IRKernel) -> Bool {
        guard position.domain == other.position.domain, position.kernelChannels == other.position.kernelChannels,
              position.maximumFrames == other.position.maximumFrames,
              position.environment.sampleRate == other.position.environment.sampleRate, activation == other.activation
        else { return false }
        switch (spec, other.spec) {
        case (.gain(_, let a), .gain(_, let b)): return a == b
        case (.gainCascade(let a, let rampA), .gainCascade(let b, let rampB)): return a.count == b.count && rampA == rampB
        case (.channelGains(let a, let rampA), .channelGains(let b, let rampB)): return a.count == b.count && rampA == rampB
        case (.biquad(let a, let precisionA), .biquad(let b, let precisionB)): return a.count == b.count && precisionA == precisionB
        case (.fir(let a, let latencyA), .fir(let b, let latencyB)): return a.count == b.count && latencyA == latencyB
        case (.custom(let a), .custom(let b)): return a.hasSameStructure(as: b)
        case (.processor(let a), .processor(let b)): return a.hasSameStructure(as: b)
        default: return spec == other.spec
        }
    }
}

/// An analysis node.
struct IRNode: Hashable, Sendable {
    let step: AnalysisStep
    let origin: StepOrigin
    var path: StagePath { origin.path }
    let position: IRPosition
    /// The domain of the frames the node writes.
    let outputDomain: DomainTag
}

/// A sink.
struct IRSink: Hashable, Sendable {
    let sink: SinkDescription
    let origin: StepOrigin
    let position: IRPosition
    var activation: IRSwitch?
    /// For a bound result: its position among the bound results of the pipeline.
    let resultOrdinal: Int?
}

/// A side branch.
struct IRBranch: Hashable, Sendable {
    var steps: [IRStep]
    let origin: StepOrigin
    var activation: IRSwitch?
    /// True for the common prefix of several branches, computed once for all of them (F5). It
    /// runs while at least one of the branches it serves is active (ACT-9).
    var isShared = false
}

/// Stages under one bound switch that keep the domain and the rate: bypassed as one unit.
struct IRRegion: Hashable, Sendable {
    var steps: [IRStep]
    let origin: StepOrigin
    var path: StagePath { origin.path }
    let position: IRPosition
    let activation: IRSwitch
    /// The delay the stages inside add, in seconds: what the unprocessed path is delayed by
    /// while they are switched off (ACT-8).
    let latency: TimeInterval
    /// The most frames a block of samples holds after the region.
    let outputMaximumFrames: Int
}

indirect enum IRStep: Hashable, Sendable {
    case kernel(IRKernel)
    case node(IRNode)
    case emission(IRSink)
    case branch(IRBranch)
    case region(IRRegion)
    /// The bound switch of a stage that changes the domain or the rate: switched off, the rest
    /// of the branch is suspended (ACT-3).
    case gate(IRSwitch, origin: StepOrigin)

    /// True when the two steps differ at most in values a running plan can take by command.
    func hasSameStructure(as other: IRStep) -> Bool {
        switch (self, other) {
        case (.kernel(let a), .kernel(let b)): return a.hasSameStructure(as: b)
        case (.node(let a), .node(let b)): return a == b
        case (.emission(let a), .emission(let b)): return a == b
        case (.branch(let a), .branch(let b)): return a.activation == b.activation && IRStep.sameStructure(a.steps, b.steps)
        case (.region(let a), .region(let b)):
            return a.activation == b.activation && a.position == b.position && IRStep.sameStructure(a.steps, b.steps)
        case (.gate(let a, _), .gate(let b, _)): return a == b
        default: return false
        }
    }

    static func sameStructure(_ lhs: [IRStep], _ rhs: [IRStep]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.hasSameStructure(as: $1) }
    }
}

/// A pipeline lowered for one environment: the plan compiler's result before allocation.
struct LoweredPipeline: Sendable {
    /// The description with every `EnvironmentReader` replaced by what it produced: what two
    /// pipelines are compared by once they are attached (API-1).
    let resolved: [StageDescription]
    /// The steps after fusion (F1 … F5): what a plan compiled from nothing runs.
    var steps: [IRStep]
    /// The same steps with every identity that depends on its values kept in its place (a
    /// gain of 0 dB, a single unit tap), and fused without regard to them. Its shape does not
    /// move when a value does, so it is what plans are built from, keyed by and compared by:
    /// a gain that reaches or leaves 0 dB is a change of values, not another topology
    /// (§5.5.4). A plan makes no kernel for an identity it is compiled with (F4).
    var skeleton: [IRStep]
    /// The bound switches, in the order of their ordinals.
    let switches: [BoundSwitch]
    /// The bound results, in the order of their ordinals.
    let results: [BoundResult]
    /// Where each bound switch and each bound result sits in `resolved`, in pre-order.
    let switchSites: [Int]
    let resultSites: [Int]
    /// The environment each `EnvironmentReader` was expanded in, in the order of the walk.
    let readerEnvironments: [DSPEnvironment]
    /// The environment at the source.
    let sourceEnvironment: DSPEnvironment
    /// How often the bindings of this pipeline receive results, per second (OUT-2): the
    /// highest `resultRate` among the environments its bound results stand in, which is what a
    /// pipeline or a group sets with `.environment(\.resultRate, …)` around them (ENV-3). One
    /// heartbeat serves every bound result of a session. The rate at the source where no
    /// result is bound: there is no heartbeat then.
    let resultRate: Double
    /// Domain, environment and block size at the end of the main line.
    let output: IRPosition
    /// True when the main line ends behind a stage that is switched off for good and changes
    /// the domain or the rate: nothing leaves it, as when a bound switch there is off (ACT-3).
    let isSuspended: Bool
}

// MARK: Structure without values

extension IRKernel {
    /// Hashes what `hasSameStructure(as:)` compares: everything but the values a running
    /// kernel can take by command.
    func hashStructure(into hasher: inout Hasher) {
        hasher.combine(position.domain)
        hasher.combine(position.kernelChannels)
        hasher.combine(position.maximumFrames)
        hasher.combine(position.environment.sampleRate)
        hasher.combine(activation)
        switch spec {
        case .gain(_, let ramp):
            hasher.combine(0)
            hasher.combine(ramp)
        case .gainCascade(let factors, let ramp):
            hasher.combine(1)
            hasher.combine(factors.count)
            hasher.combine(ramp)
        case .channelGains(let factors, let ramp):
            hasher.combine(2)
            hasher.combine(factors.count)
            hasher.combine(ramp)
        case .biquad(let sections, let precision):
            hasher.combine(3)
            hasher.combine(sections.count)
            hasher.combine(precision)
        case .fir(let taps, let latency):
            hasher.combine(4)
            hasher.combine(taps.count)
            hasher.combine(latency)
        case .custom(let custom):
            // Name and key, as the description hashes itself: its values are left out.
            hasher.combine(6)
            hasher.combine(custom)
            hasher.combine(custom.values.count)
        case .processor(let processor):
            hasher.combine(7)
            hasher.combine(processor)
            hasher.combine(processor.values.count)
        default:
            hasher.combine(5)
            hasher.combine(spec)
        }
    }
}

extension IRStep {
    /// Hashes what `hasSameStructure(as:)` compares: the step without the values a running
    /// kernel can take by command. It is what the place of a step in a plan is keyed by, so
    /// that a change of values moves nothing (§5.5.4).
    func hashStructure(into hasher: inout Hasher) {
        switch self {
        case .kernel(let kernel):
            hasher.combine(0)
            kernel.hashStructure(into: &hasher)
        case .node(let node):
            hasher.combine(1)
            hasher.combine(node)
        case .emission(let sink):
            hasher.combine(2)
            hasher.combine(sink)
        case .branch(let branch):
            hasher.combine(3)
            hasher.combine(branch.activation)
            hasher.combine(branch.steps.count)
            for step in branch.steps { step.hashStructure(into: &hasher) }
        case .region(let region):
            hasher.combine(4)
            hasher.combine(region.activation)
            hasher.combine(region.position)
            hasher.combine(region.steps.count)
            for step in region.steps { step.hashStructure(into: &hasher) }
        case .gate(let activation, _):
            hasher.combine(5)
            hasher.combine(activation)
        }
    }

    /// The kernels of `steps` in the order a plan creates them, a switched group of kernels
    /// counting as its kernels: the order value commands address them in.
    static func kernels(of steps: [IRStep]) -> [IRKernel] {
        var result: [IRKernel] = []
        func collect(_ steps: [IRStep]) {
            for step in steps {
                switch step {
                case .kernel(let kernel): result.append(kernel)
                case .branch(let branch): collect(branch.steps)
                case .region(let region): collect(region.steps)
                case .node, .emission, .gate: break
                }
            }
        }
        collect(steps)
        return result
    }

    /// True for a switched group that runs as one kernel (ACT-6): it holds kernels only, each
    /// keeps the rate, and none has a switch of its own. A plan behind the kernel ABI counts
    /// its latency in frames of one rate and writes as many frames as it reads, and it can
    /// switch nothing inside itself; a group that changes the rate inside, or that holds a
    /// stage with a bound switch, runs its steps one by one between the group's markers
    /// instead, as a group with a node does (ACT-1, ACT-5, ACT-8).
    var isKernelRegion: Bool {
        guard case .region(let region) = self else { return false }
        return !region.steps.isEmpty && region.steps.allSatisfy { step in
            if case .kernel(let kernel) = step { kernel.activation == nil && kernel.spec.keepsRate } else { false }
        }
    }

    /// The steps of `steps` that a plan holds as one kernel object each, in the order it
    /// creates them: kernels, and switched groups of kernels.
    static func kernelObjects(of steps: [IRStep]) -> [IRStep] {
        var result: [IRStep] = []
        func collect(_ steps: [IRStep]) {
            for step in steps {
                switch step {
                case .kernel: result.append(step)
                case .branch(let branch): collect(branch.steps)
                case .region(let region):
                    if step.isKernelRegion { result.append(step) } else { collect(region.steps) }
                case .node, .emission, .gate: break
                }
            }
        }
        collect(steps)
        return result
    }
}
