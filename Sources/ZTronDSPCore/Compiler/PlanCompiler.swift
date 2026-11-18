import Foundation

/// The plan compiler (§5.5.3): from a description to a lowered pipeline, on the control
/// context. Resolve, validate and lower are one walk, because the environment a stage reads
/// is the one the stages before it left (ENV-1); fusion is a second pass over the result.
struct PlanCompiler: Sendable {
    let crossovers: CrossoverTable

    /// Where the walk stands in the signal.
    private struct Cursor {
        var domain: DomainTag
        var environment: DSPEnvironment
        var maximumFrames: Int
        /// The format of the last analysis step, while the signal is frames of bins.
        var frames: FrameFormat?

        /// The shape of the frames here: blocks of samples, single values, or what the last
        /// analysis step declared.
        var format: FrameFormat {
            switch domain {
            case .samples: .samples(channelCount: max(environment.channelCount, 1), maximumFrames: maximumFrames)
            case .novelty, .scalar: .scalar
            default: frames ?? .real(count: environment.frequencyAxis?.rowCount ?? 0)
            }
        }

        var position: IRPosition {
            IRPosition(domain: domain, environment: environment, maximumFrames: maximumFrames, format: format)
        }

        /// True when `other` is the same point of the same kind of signal: a stage between the
        /// two keeps the domain and the rate, and so can be bypassed (ACT-3).
        func isSameSignal(as other: Cursor) -> Bool {
            domain == other.domain && environment.sampleRate == other.environment.sampleRate
                && environment.frameSize == other.environment.frameSize && environment.hopSize == other.environment.hopSize
                && environment.channelCount == other.environment.channelCount
        }
    }

    private struct Collected {
        var switches: [BoundSwitch] = []
        var results: [BoundResult] = []
        /// Where each bound switch and each bound result sits in the resolved description,
        /// counted in pre-order: what lets an equal pipeline's bindings be captured again
        /// without compiling it (§5.5.4).
        var switchSites: [Int] = []
        var resultSites: [Int] = []
        var nextSite = 0
        /// The environment each `EnvironmentReader` was expanded in, in the order of the walk.
        var readerEnvironments: [DSPEnvironment] = []
    }

    /// Resolves, validates and lowers `stages` for a signal that starts as samples in
    /// `environment`, then fuses the result.
    func lower(_ stages: [StageDescription], environment: DSPEnvironment, blockSize: Int) throws(DSPError) -> LoweredPipeline {
        var cursor = Cursor(domain: .samples, environment: environment, maximumFrames: max(blockSize, 1))
        var collected = Collected()
        let (resolved, steps, suspended) = try walk(stages, &cursor, StagePath(), &collected)
        return LoweredPipeline(
            resolved: resolved, steps: fuse(steps), skeleton: fuse(steps, keepingIdentitiesByValue: true),
            switches: collected.switches, results: collected.results,
            switchSites: collected.switchSites, resultSites: collected.resultSites,
            readerEnvironments: collected.readerEnvironments, sourceEnvironment: environment, output: cursor.position,
            isSuspended: suspended)
    }

    // MARK: Resolve, validate, lower

    /// - Returns: the resolved stages, their steps, and whether the walk ended behind a stage
    ///   that is switched off for good and changes the domain or the rate. That suspends the
    ///   rest of the branch the stages are part of (ACT-3, ACT-4): a `Group` and an
    ///   `EnvironmentReader` are part of the branch around them, so they pass it on; a `Tap`
    ///   is a branch of its own, so it ends there.
    private func walk(
        _ stages: [StageDescription], _ cursor: inout Cursor, _ prefix: StagePath, _ collected: inout Collected
    ) throws(DSPError) -> (resolved: [StageDescription], steps: [IRStep], suspended: Bool) {
        var resolved: [StageDescription] = []
        var steps: [IRStep] = []
        // The rest of a suspended branch is removed. It is still walked, so it is validated.
        var suspended = false

        for (index, stage) in stages.enumerated() {
            let path = prefix.appending(stage.name, index: index)
            let before = cursor
            let marks = (collected.switches.count, collected.results.count)
            // A reader leaves no stage of its own in the resolved description: what it
            // produces takes its place.
            let site = collected.nextSite
            if case .reader = stage.content {} else { collected.nextSite += 1 }
            let lowered = try lowerOne(stage, &cursor, path, site, &collected)
            var stageSteps = lowered.steps
            resolved += lowered.resolved

            let drop = { (collected: inout Collected) in
                collected.switches.removeSubrange(marks.0...)
                collected.switchSites.removeSubrange(marks.0...)
                collected.results.removeSubrange(marks.1...)
                collected.resultSites.removeSubrange(marks.1...)
            }
            if suspended {
                drop(&collected)
                continue
            }

            switch stage.activation {
            case .constant(true):
                steps += stageSteps
                if lowered.suspended { suspended = true }
            case .constant(false):
                drop(&collected)
                if before.isSameSignal(as: cursor) {
                    // Bypassed for good, it leaves no trace: not its kernels, and not its
                    // latency in the environment of what follows (ACT-4, REAL-5).
                    cursor = before
                } else {
                    suspended = true
                }
            case .bound(let bound):
                let own = IRSwitch(ordinal: collected.switches.count)
                collected.switches.append(bound)
                collected.switchSites.append(site)
                if case .tap = stage.content, stageSteps.count == 1, case .branch(var branch) = stageSteps[0] {
                    branch.activation = own
                    steps.append(.branch(branch))
                } else if case .emit = stage.content, stageSteps.count == 1, case .emission(var sink) = stageSteps[0] {
                    sink.activation = own
                    steps.append(.emission(sink))
                } else if before.isSameSignal(as: cursor) {
                    // Keeps the domain and the rate: a faded bypass (ACT-3).
                    if stageSteps.count == 1, case .kernel(var kernel) = stageSteps[0], kernel.activation == nil {
                        kernel.activation = own
                        steps.append(.kernel(kernel))
                    } else if !stageSteps.isEmpty {
                        stageSteps = [.region(IRRegion(
                            steps: stageSteps, origin: StepOrigin(path), position: before.position, activation: own,
                            latency: cursor.environment.latency - before.environment.latency, outputMaximumFrames: cursor.maximumFrames))]
                        steps += stageSteps
                    }
                } else {
                    // Changes the domain or the rate: off, the rest of the branch is suspended.
                    steps.append(.gate(own, origin: StepOrigin(path)))
                    steps += stageSteps
                }
                // What is off for good inside a switched group stays off whatever the switch says.
                if lowered.suspended { suspended = true }
            }
        }
        return (resolved, steps, suspended)
    }

    /// Lowers one stage as if it were active, and moves the cursor past it.
    private func lowerOne(
        _ stage: StageDescription, _ cursor: inout Cursor, _ path: StagePath, _ site: Int, _ collected: inout Collected
    ) throws(DSPError) -> (resolved: [StageDescription], steps: [IRStep], suspended: Bool) {
        switch stage.content {
        case .reader(let box):
            // An EnvironmentReader is replaced by what it produces here (resolve).
            collected.readerEnvironments.append(cursor.environment)
            return try walk(box.make(cursor.environment), &cursor, path, &collected)

        case .tap(let inner):
            var branch = cursor
            let (resolved, steps, _) = try walk(inner, &branch, path, &collected)
            let description = StageDescription(name: stage.name, rule: stage.rule, activation: stage.activation, content: .tap(resolved))
            return ([description], [.branch(IRBranch(steps: steps, origin: StepOrigin(path), activation: nil))], false)

        case .group(let inner, let overrides):
            let outer = cursor.environment
            var scope: [ObjectIdentifier: AnyStrategy] = [:]
            for override in overrides { scope[override.key] = override.value }
            cursor.environment = outer.applyingOverrides(of: scope)
            let (resolved, steps, suspended) = try walk(inner, &cursor, path, &collected)
            cursor.environment = cursor.environment.restoringOverrides(of: outer)
            let description = StageDescription(name: stage.name, rule: stage.rule, activation: stage.activation,
                                               content: .group(resolved, overrides: overrides))
            return ([description], steps, suspended)

        case .emit(let sink):
            guard stage.rule(cursor.domain) != nil else { throw DSPError.invalidStageOrder(stage: path, found: cursor.domain) }
            var ordinal: Int?
            var written = sink
            if case .result(let result) = sink.target {
                ordinal = collected.results.count
                collected.results.append(result)
                collected.resultSites.append(site)
                // The plan writes a slot of the binding's kind; the binding stays with the
                // description and with the pump that captured it (BIND-6).
                written = SinkDescription(target: .slot(result.kind), accepts: sink.accepts)
            }
            return ([stage], [.emission(IRSink(sink: written, origin: StepOrigin(path), position: cursor.position, activation: nil, resultOrdinal: ordinal))], false)

        case .stage(let erased):
            // Tier 2 of the order rules, for every pipeline, typed or not (ORD-6).
            guard let output = stage.rule(cursor.domain) else { throw DSPError.invalidStageOrder(stage: path, found: cursor.domain) }
            var context = LoweringContext(position: cursor.position, path: path, crossovers: crossovers)
            do throws(DSPError) {
                try erased.base.lower(&context)
            } catch {
                throw error.inStage(path)
            }
            var steps: [IRStep] = []
            let specs = context.specs
            for (index, spec) in specs.enumerated() {
                let isLast = index == specs.count - 1
                if case .analysis(let step) = spec {
                    let produced: DomainTag
                    switch step.scope {
                    case _ where isLast: produced = output
                    case .samples: produced = .samples
                    case .featureSequence: produced = .scalar
                    default: produced = .custom("\(stage.name) intermediate")
                    }
                    steps.append(.node(IRNode(step: step, origin: StepOrigin(path), position: cursor.position, outputDomain: produced)))
                    cursor.domain = produced
                    cursor.frames = step.output
                } else {
                    guard cursor.domain.isSampledSequence else {
                        throw DSPError.unsupportedConfiguration(
                            reason: "\(stage.name) emitted a sequence kernel where the signal is a \(cursor.domain), not a sampled sequence", stage: path)
                    }
                    var resolved = spec
                    // `.automatic` is not a precision a kernel can run in; a stage that leaves it
                    // unresolved gets single precision.
                    if case .biquad(let sections, .automatic) = spec { resolved = .biquad(sections: sections, precision: .single) }
                    steps.append(.kernel(IRKernel(spec: resolved, origin: StepOrigin(path), position: cursor.position, activation: nil)))
                }
                cursor.environment = LoweringContext.environment(after: spec, from: cursor.environment)
                cursor.maximumFrames = LoweringContext.maximumFrames(after: spec, from: cursor.maximumFrames)
                try PlanCompiler.checkCountable(cursor.environment, behind: path)
            }
            cursor.domain = output
            if !output.isSampledSequence || output != .samples { cursor.maximumFrames = output == .samples ? cursor.maximumFrames : max(cursor.maximumFrames, 1) }
            if output.isScalarValued { cursor.maximumFrames = 1 }
            return ([stage], steps, false)
        }
    }

    /// What every count of frames behind a stage is made from (§9.3): the rate there is a
    /// positive, finite number, and the delay so far a finite time. A stage written outside
    /// the package states both freely (a feature sequence at any rate, a node with any
    /// latency); one that leaves anything else has stated a value no plan can count in, and
    /// is refused here, by name, before a plan is made from it.
    private static func checkCountable(_ environment: DSPEnvironment, behind path: StagePath) throws(DSPError) {
        guard environment.sampleRate.isFinite, environment.sampleRate > 0 else {
            throw .invalidParameter(
                stage: path, parameter: "sampleRate",
                reason: "the stage leaves a rate of \(environment.sampleRate) per second, which is not a positive, finite number")
        }
        guard environment.latency.isFinite else {
            throw .invalidParameter(
                stage: path, parameter: "latency", reason: "the stage leaves a delay of \(environment.latency) s, which is not a finite time")
        }
    }

    // MARK: Fuse (§5.5.3, pass 4)

    /// Fuses adjacent kernels (F1–F3), removes identities (F4) and shares equal leading steps
    /// of sibling branches (F5). Fusion never reorders stages and never crosses a tap point,
    /// a sink, a node, or a stage with a bound activation (ACT-6).
    ///
    /// - Parameter keepingIdentitiesByValue: true for the skeleton of the pipeline: an
    ///   identity that is one by its values stays where it is and fuses like any kernel of
    ///   its kind, so the result has one shape whatever the values are (§5.5.4).
    func fuse(_ steps: [IRStep], keepingIdentitiesByValue: Bool = false) -> [IRStep] {
        var result: [IRStep] = []
        for step in steps {
            switch step {
            case .branch(var branch):
                branch.steps = fuse(branch.steps, keepingIdentitiesByValue: keepingIdentitiesByValue)
                if !branch.steps.isEmpty { result.append(.branch(branch)) }
            case .region(var region):
                // Inside a switched group the stages fuse with one another (ACT-6).
                region.steps = fuse(region.steps, keepingIdentitiesByValue: keepingIdentitiesByValue)
                if region.steps.count == 1, case .kernel(var kernel) = region.steps[0], kernel.activation == nil {
                    kernel.activation = region.activation
                    result.append(.kernel(kernel))
                } else if !region.steps.isEmpty {
                    result.append(.region(region))
                }
            case .kernel(let kernel):
                if kernel.activation == nil, kernel.spec.isIdentity,
                   !(keepingIdentitiesByValue && kernel.spec.isIdentityByValue) { continue }                 // F4
                if kernel.activation == nil, case .kernel(let previous)? = result.last, previous.activation == nil,
                   previous.position.domain == kernel.position.domain,
                   let merged = merge(previous, kernel) {
                    result[result.count - 1] = .kernel(merged)
                    continue
                }
                result.append(step)
            case .node, .emission, .gate:
                result.append(step)
            }
        }
        return shareBranchPrefixes(result)
    }

    /// The kernel two adjacent kernels fuse into, or `nil` when they do not fuse.
    ///
    /// A figure that cannot be counted stays with the stage that stated it, so that the stage
    /// is refused by its own name when its kernel is made, and two stages that can each be
    /// counted are never refused for a figure that neither of them stated (§9.3). So a gain
    /// whose ramp is no count of frames at this rate does not fuse: the longer of two ramps
    /// would hide a ramp that is no number, and put one that is too long under the name of
    /// the other stage. And two filters fuse only when their latencies, each as its own
    /// kernel would state it, add up to a figure one kernel can count.
    private func merge(_ first: IRKernel, _ second: IRKernel) -> IRKernel? {
        var fused = first
        // The rate at which the one kernel of both would be made: a gain keeps the rate.
        let rate = first.position.environment.sampleRate
        func uncountable(_ rampA: TimeInterval, _ rampB: TimeInterval) -> Bool {
            FrameCount.ramp(rampA, at: rate) == nil || FrameCount.ramp(rampB, at: rate) == nil
        }
        switch (first.spec, second.spec) {
        case (.gain(_, let rampA), .gain(_, let rampB)) where uncountable(rampA, rampB),
             (.gainCascade(_, let rampA), .gain(_, let rampB)) where uncountable(rampA, rampB),
             (.gain(_, let rampA), .gainCascade(_, let rampB)) where uncountable(rampA, rampB),
             (.gainCascade(_, let rampA), .gainCascade(_, let rampB)) where uncountable(rampA, rampB):
            return nil
        case (.gain(let a, let rampA), .gain(let b, let rampB)):                                              // F1
            fused.spec = .gainCascade(factors: [a, b], ramp: max(rampA, rampB))
        case (.gainCascade(let factors, let rampA), .gain(let b, let rampB)):
            fused.spec = .gainCascade(factors: factors + [b], ramp: max(rampA, rampB))
        case (.gain(let a, let rampA), .gainCascade(let factors, let rampB)):
            fused.spec = .gainCascade(factors: [a] + factors, ramp: max(rampA, rampB))
        case (.gainCascade(let a, let rampA), .gainCascade(let b, let rampB)):
            fused.spec = .gainCascade(factors: a + b, ramp: max(rampA, rampB))
        case (.biquad(let a, let precisionA), .biquad(let b, let precisionB)) where precisionA == precisionB:  // F2
            fused.spec = .biquad(sections: a + b, precision: precisionA)
        case (.fir(let a, let latencyA), .fir(let b, let latencyB))                                           // F3
            where a.count < crossovers.firPartitioned && b.count < crossovers.firPartitioned
                && a.count + b.count - 1 < crossovers.firPartitioned && !a.isEmpty && !b.isEmpty:
            guard let latency = PlanCompiler.latencyInSeries(latencyA, latencyB) else { return nil }
            fused.spec = .fir(taps: PlanCompiler.convolve(a, b), latency: latency)
        default:
            return nil
        }
        return fused
    }

    /// The latency of two filters in a row as the one filter of both states it, or `nil` when
    /// one kernel cannot count it. Each latency counts for what the filter's own kernel would
    /// state, and for what the environment behind the filter was computed from
    /// (`KernelSpec.latencyFrames`): a negative one is none, so that the delay of the fused
    /// filter is the delay of the two (REAL-5).
    static func latencyInSeries(_ first: Int, _ second: Int) -> Int? {
        guard let first = UInt32(exactly: max(first, 0)), let second = UInt32(exactly: max(second, 0)) else { return nil }
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? nil : Int(sum)
    }

    /// The taps of two FIR filters in series: their convolution, accumulated in double precision.
    static func convolve(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Double](repeating: 0, count: a.count + b.count - 1)
        for (i, x) in a.enumerated() {
            for (j, y) in b.enumerated() { result[i + j] += Double(x) * Double(y) }
        }
        return result.map { Float($0) }
    }

    /// F5: sibling branches at one position that begin with equal steps compute those steps
    /// once. The shared prefix becomes a branch of its own, and what is left of each sibling
    /// hangs off it with its own switch.
    private func shareBranchPrefixes(_ steps: [IRStep]) -> [IRStep] {
        var result: [IRStep] = []
        var run: [IRBranch] = []
        func flush() {
            guard !run.isEmpty else { return }
            result += share(run).map { IRStep.branch($0) }
            run.removeAll()
        }
        for step in steps {
            if case .branch(let branch) = step {
                run.append(branch)
            } else {
                flush()
                result.append(step)
            }
        }
        flush()
        return result
    }

    private func share(_ branches: [IRBranch]) -> [IRBranch] {
        guard branches.count > 1 else { return branches }
        var groups: [(first: IRStep, members: [IRBranch])] = []
        var order: [Int] = []      // index into `groups`, or -1 for a branch that shares nothing
        var loners: [IRBranch] = []
        for branch in branches {
            guard let first = branch.steps.first, PlanCompiler.isShareable(first) else {
                order.append(-1 - loners.count)
                loners.append(branch)
                continue
            }
            if let index = groups.firstIndex(where: { $0.first == first }) {
                groups[index].members.append(branch)
            } else {
                order.append(groups.count)
                groups.append((first, [branch]))
            }
        }
        var result: [IRBranch] = []
        for entry in order {
            if entry < 0 {
                result.append(loners[-1 - entry])
                continue
            }
            let group = groups[entry]
            guard group.members.count > 1 else {
                result.append(group.members[0])
                continue
            }
            // What is left of each member after the shared step, each under its own switch.
            let tails = group.members.compactMap { member -> IRBranch? in
                let rest = Array(member.steps.dropFirst())
                guard !rest.isEmpty else { return nil }
                return IRBranch(steps: rest, origin: member.origin, activation: member.activation, isShared: member.isShared)
            }
            let shared = IRBranch(steps: [group.first] + share(tails).map { IRStep.branch($0) }, origin: group.members[0].origin,
                                  activation: nil, isShared: true)
            result.append(shared)
        }
        return result
    }

    /// Only pure computation is shared: a node, or a kernel without a switch of its own.
    private static func isShareable(_ step: IRStep) -> Bool {
        switch step {
        case .node: true
        case .kernel(let kernel): kernel.activation == nil
        case .emission, .branch, .region, .gate: false
        }
    }
}

// MARK: Comparing and re-capturing without compiling (§5.5.4)

extension PlanCompiler {
    /// `stages` with every `EnvironmentReader` replaced by what it produces in the environment
    /// a previous compilation recorded for it, or `nil` when the stages hold another number of
    /// readers than that compilation saw.
    ///
    /// This is how an update is compared with what is running without being compiled: the
    /// recorded environments are the right ones exactly when everything before each reader is
    /// equal, and when the result equals the resolved description of the running plan, it is.
    static func resolve(_ stages: [StageDescription], readerEnvironments: [DSPEnvironment]) -> [StageDescription]? {
        var remaining = readerEnvironments[...]
        guard let resolved = resolve(stages, &remaining), remaining.isEmpty else { return nil }
        return resolved
    }

    private static func resolve(_ stages: [StageDescription], _ environments: inout ArraySlice<DSPEnvironment>) -> [StageDescription]? {
        var result: [StageDescription] = []
        result.reserveCapacity(stages.count)
        for stage in stages {
            switch stage.content {
            case .reader(let box):
                guard let environment = environments.popFirst(), let inner = resolve(box.make(environment), &environments) else { return nil }
                result += inner
            case .tap(let inner):
                guard let resolved = resolve(inner, &environments) else { return nil }
                result.append(StageDescription(name: stage.name, rule: stage.rule, activation: stage.activation, content: .tap(resolved)))
            case .group(let inner, let overrides):
                guard let resolved = resolve(inner, &environments) else { return nil }
                result.append(StageDescription(name: stage.name, rule: stage.rule, activation: stage.activation,
                                               content: .group(resolved, overrides: overrides)))
            case .stage, .emit:
                result.append(stage)
            }
        }
        return result
    }

    /// The bindings of a resolved description at the places a compilation recorded: the bound
    /// switches and the bound results, in the order of their ordinals. `nil` when a place does
    /// not hold what was recorded there, which an equal description cannot do.
    static func bindings(
        of resolved: [StageDescription], switchSites: [Int], resultSites: [Int]
    ) -> (switches: [BoundSwitch], results: [BoundResult])? {
        var flat: [StageDescription] = []
        func flatten(_ stages: [StageDescription]) {
            for stage in stages {
                flat.append(stage)
                flatten(stage.nestedStages)
            }
        }
        flatten(resolved)
        var switches: [BoundSwitch] = []
        for site in switchSites {
            guard site < flat.count, case .bound(let bound) = flat[site].activation else { return nil }
            switches.append(bound)
        }
        var results: [BoundResult] = []
        for site in resultSites {
            guard site < flat.count, case .emit(let sink) = flat[site].content, case .result(let result) = sink.target else { return nil }
            results.append(result)
        }
        return (switches, results)
    }
}
