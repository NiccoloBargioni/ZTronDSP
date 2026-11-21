import Foundation

/// Where a plan's main-line output goes, and where the output of a plan that is being
/// pre-rolled beside it goes (SWAP-2).
protocol PlanOutput: AnyObject {
    func take(_ frame: FrameView)
    func takeShadow(_ frame: FrameView)
}

/// How a new plan relates to the one it replaces (§5.5.4, SWAP-1…3).
struct PlanTransition {
    /// The first step of the old plan's main line that the new plan does not share: where the
    /// old plan lets the new one hear the signal while it is pre-rolled.
    let oldStep: Int
    /// The step of the new plan's main line that takes that signal.
    let newStep: Int
    /// Inside those steps, when both are kernel runs: the first kernel of the old run that the
    /// new run does not share …
    let kernel: Int
    /// … and the kernel of the new run that takes its place. The two differ when kernels
    /// arrived in the new run before that point: they are identities until their values reach
    /// them, and the old run has none for them.
    let newKernel: Int
    /// How long the new part of the main line runs beside the old one before it is used, in
    /// frames of the source: its settling time, at most one second (SWAP-2).
    let prerollFrames: Int
    /// True when old and new output can be cross-faded: same rate, same latency, block for block.
    let crossfades: Bool
    /// True when the main line is the same in both plans: only branches changed.
    let mainLineUnchanged: Bool
}

/// A compiled plan (§5.5.2): the tree of segments the analysis thread walks once per block,
/// with every kernel, node, buffer and setup it needs already allocated (RT-3).
///
/// Built and released on the control context; run on the analysis thread. A plan is immutable
/// in shape: a structural change is a new plan (IMM-4).
final class ExecutionPlan {
    /// Where a value command for one kernel goes: the run that holds it, its entry in the
    /// run's C plan, and, for a kernel inside a switched group, its place in the group.
    typealias KernelTarget = (run: KernelRun, entry: UInt32, inner: UInt32)

    /// A kernel this plan made for a stage that was an identity in the plan before, and the
    /// step that says what the stage is now: its values are sent to the kernel by command
    /// once the plan is published (§5.5.4).
    struct Arrival {
        /// The kernel's place among `kernelTargets`.
        let target: Int
        let box: KernelBox
        let kernel: IRKernel
    }

    /// What the plan was compiled from. A change of values replaces it, also while the plan
    /// is on its way in. It is the control context's alone: the thread that runs the plan
    /// reads nothing of it, and what that thread needs of it is a constant of the plan
    /// (`fadeLength`, `transition`), fixed when the plan is compiled (RT-4).
    private(set) var lowered: LoweredPipeline
    let generation: UInt32
    /// The position of each bound switch when the plan was compiled, by ordinal (BIND-4).
    let switchValues: [Bool]
    // The shape of the plan: constants from the moment it is compiled. The thread that runs
    // the plan reads these, and nothing of the plan that the control context changes after it
    // has handed the plan over (RT-4).
    let root: PlanSegment
    let switchTargets: [SwitchTarget]
    /// What a value command addresses, in the order kernels appear in the skeleton of the
    /// lowered pipeline; `nil` for a stage that was an identity when the plan was compiled,
    /// for which no kernel runs (F4).
    let kernelTargets: [KernelTarget?]
    let resultSlots: [ResultSlot]
    let sinkSlots: [SinkSlot]
    /// Every sink with the steps that describe it, for claims.
    let sinks: [(sink: any PlanSink, description: IRSink)]
    /// For each sink, the switches that must all be on for it to receive frames (ACT-11).
    let sinkGates: [[Int]]
    let transition: PlanTransition?

    // What a later plan may take over, by the key of its place in the signal. Keys leave out
    // the values a kernel takes by command, so a change of values moves nothing.
    private let kernelBoxes: [Int: KernelBox]
    /// The stages that were identities when the plan was compiled, by the same keys: no
    /// kernel runs for them, and a later plan that finds one of them changed makes its kernel
    /// as the identity it was.
    private let identities: [Int: IRKernel]
    private let nodeBoxes: [Int: NodeBox]
    private let sinkKeys: Set<Int>
    /// The kernel objects in the order they appear in the skeleton: kernels, and switched
    /// groups of them; `nil` for an identity without a kernel.
    private let kernelOrder: [KernelBox?]
    /// Control context: taken once, after the plan is published.
    private var arrivals: [Arrival]
    /// Where old and new output meet while this plan is faded in (SWAP-2).
    let fade: AudioBuffer?
    /// The frames over which this plan is faded in when it replaces another: 10 ms at the
    /// rate of the source, and never shorter than one block (ACT-7).
    let fadeLength: Int

    /// Where the output goes: set by the control context before it hands the plan over.
    weak var output: (any PlanOutput)?

    // Run-time state, touched by the analysis thread only.
    /// True while this plan is pre-rolled beside the running one: its branches and sinks are idle.
    var isShadow = false
    /// The plan that is being pre-rolled beside this one, and where it starts to differ.
    var shadow: ExecutionPlan?
    /// The step of this plan's main line at which the shadow hears the signal.
    var shadowStep = 0
    /// The step of the shadow's main line that takes it.
    var shadowStart = 0
    /// Inside those two steps, when both are kernel runs: the kernels of this plan's run that
    /// come before the point, and the kernel of the shadow's run that follows it.
    var shadowKernel = 0
    var shadowStartKernel = 0

    /// The most samples (frames times channels) one buffer of a plan holds: a gigabyte of
    /// Float32, which is what a feed's history may come to as well. A plan that needs more
    /// is one no machine is asked to hold (§9.3).
    static let maximumSamples = 1 << 28

    /// Compiles the plan.
    ///
    /// - Parameters:
    ///   - switchValues: the position of each bound switch, by ordinal, as read on the main actor (BIND-4).
    ///   - previous: the plan this one replaces. Kernels and nodes whose own description and
    ///     whole upstream path are equal in both are taken over with their state (SWAP-1).
    init(lowered: LoweredPipeline, switchValues: [Bool], crossovers: CrossoverTable, generation: UInt32, previous: ExecutionPlan?) throws(DSPError) {
        self.lowered = lowered
        self.generation = generation
        self.switchValues = switchValues
        var builder = Builder(crossovers: crossovers, switchValues: switchValues, previous: previous,
                              followed: previous.map { ExecutionPlan.mainLineObjects(of: $0.root) } ?? [],
                              switchTargets: [SwitchTarget](repeating: .none, count: lowered.switches.count))
        for result in lowered.results { builder.resultSlots.append(try ResultSlot(kind: result.kind)) }
        let segment = try builder.segment(lowered.skeleton, key: 0, cell: nil, isShared: false, gates: [])
        // A main line that is suspended for good ends at a gate nothing opens: what stands
        // before it runs, and nothing leaves the plan.
        if lowered.isSuspended { segment.steps.append(.gate(SwitchCell(isOn: false), key: Builder.closedGateKey)) }
        segment.steps.append(.output)
        root = segment
        switchTargets = builder.switchTargets
        kernelTargets = builder.kernelTargets
        resultSlots = builder.resultSlots
        sinkSlots = builder.sinkSlots
        sinks = builder.sinks
        sinkGates = builder.sinkGates
        kernelBoxes = builder.kernelBoxes
        identities = builder.identities
        nodeBoxes = builder.nodeBoxes
        sinkKeys = builder.sinkKeys
        kernelOrder = builder.kernelOrder
        arrivals = builder.arrivals
        let arriving = Set(builder.arrivals.map { ObjectIdentifier($0.box) })
        let change = previous.map { ExecutionPlan.transition(from: $0, to: lowered, root: segment, arriving: arriving) }
        transition = change
        let source = lowered.sourceEnvironment
        fadeLength = max(FrameCount.capped(0.010, at: source.sampleRate, rounding: .toNearestOrAwayFromZero), source.blockSize, 1)
        if change?.crossfades == true {
            fade = try AudioBuffer(channelCount: max(lowered.output.environment.channelCount, 1), capacity: max(lowered.output.maximumFrames, 1))
        } else {
            fade = nil
        }
        connect(root)
        root.refreshLiveness()
    }

    /// Tells every node slot where its frames continue.
    private func connect(_ segment: PlanSegment) {
        for (index, step) in segment.steps.enumerated() {
            switch step {
            case .node(let slot):
                slot.plan = self
                slot.segment = segment
                slot.next = index + 1
            case .branch(let child):
                connect(child)
            default:
                break
            }
        }
    }

    // MARK: Building

    private struct Builder {
        let crossovers: CrossoverTable
        let switchValues: [Bool]
        let previous: ExecutionPlan?
        /// The kernels and nodes of the previous plan's main line, in the order the signal
        /// passes them: what this plan's main line is held against while it is built.
        let followed: [ObjectIdentifier]
        var switchTargets: [SwitchTarget]
        var kernelTargets: [KernelTarget?] = []
        var resultSlots: [ResultSlot] = []
        var sinkSlots: [SinkSlot] = []
        var sinks: [(sink: any PlanSink, description: IRSink)] = []
        var sinkGates: [[Int]] = []
        var kernelBoxes: [Int: KernelBox] = [:]
        var identities: [Int: IRKernel] = [:]
        var nodeBoxes: [Int: NodeBox] = [:]
        var sinkKeys: Set<Int> = []
        var kernelOrder: [KernelBox?] = []
        var arrivals: [Arrival] = []
        /// The kernels made as the identities their stages were, each with what its stage is now.
        var arriving: [ObjectIdentifier: IRKernel] = [:]
        /// Objects of the previous plan already taken by this one: an object moves once.
        var taken: Set<ObjectIdentifier> = []
        /// How deep in branches the steps being built are: 0 on the main line.
        var depth = 0
        /// How many objects of `followed` this plan's main line has taken, in order.
        var cursor = 0
        /// True once this plan's main line is no longer the previous plan's, object for object.
        var hasDiverged = false

        /// The key of the gate that ends a main line suspended for good.
        static let closedGateKey = Builder.key(0, "closed for good")

        static func key(_ parent: Int, _ value: some Hashable) -> Int {
            var hasher = Hasher()
            hasher.combine(parent)
            hasher.combine(value)
            return hasher.finalize()
        }

        /// The key of a step's place by its structure: the values a kernel takes by command
        /// are left out, so a change of values moves nothing (§5.5.4).
        static func key(_ parent: Int, structureOf step: IRStep) -> Int {
            var hasher = Hasher()
            hasher.combine(parent)
            step.hashStructure(into: &hasher)
            return hasher.finalize()
        }

        func value(of activation: IRSwitch) -> Bool {
            activation.ordinal < switchValues.count ? switchValues[activation.ordinal] : true
        }

        /// A step that runs in a C plan: a kernel, or a switched group that runs as one.
        enum Unit {
            case kernel(IRKernel)
            case group(IRRegion)

            init?(_ step: IRStep) {
                switch step {
                case .kernel(let kernel): self = .kernel(kernel)
                case .region(let region) where step.isKernelRegion: self = .group(region)
                default: return nil
                }
            }

            var step: IRStep {
                switch self {
                case .kernel(let kernel): .kernel(kernel)
                case .group(let region): .region(region)
                }
            }

            var position: IRPosition {
                switch self {
                case .kernel(let kernel): kernel.position
                case .group(let region): region.position
                }
            }

            var activation: IRSwitch? {
                switch self {
                case .kernel(let kernel): kernel.activation
                case .group(let region): region.activation
                }
            }

            var path: StagePath {
                switch self {
                case .kernel(let kernel): kernel.path
                case .group(let region): region.path
                }
            }
        }

        /// The most frames a kernel reads or writes in one call.
        static func frames(of kernel: IRKernel) -> Int {
            max(kernel.position.maximumFrames, LoweringContext.maximumFrames(after: kernel.spec, from: kernel.position.maximumFrames), 1)
        }

        /// The most frames a switched group that runs as one kernel reads or writes in one
        /// call, which is the most any kernel inside it does. The plan inside the group and
        /// the plan around it are both made for this figure, so the group is never handed a
        /// buffer shorter than what it may write.
        static func frames(of region: IRRegion) -> Int {
            var frames = max(region.position.maximumFrames, region.outputMaximumFrames, 1)
            for case .kernel(let kernel) in region.steps { frames = max(frames, Builder.frames(of: kernel)) }
            return frames
        }

        static func frames(of unit: Unit) -> Int {
            switch unit {
            case .kernel(let kernel): frames(of: kernel)
            case .group(let region): frames(of: region)
            }
        }

        /// The sizes of a C plan as it takes them, or `nil` for a plan no machine is asked to
        /// hold: a count that does not fit the plan's counters, or buffers of more samples
        /// than `maximumSamples`. Decided by arithmetic, before anything is allocated (§9.3).
        static func planSizes(kernels: Int, channels: Int, frames: Int) -> (kernels: UInt32, channels: UInt32, frames: UInt32)? {
            guard let kernels = UInt32(exactly: kernels), let channels = UInt32(exactly: channels), let frames = UInt32(exactly: frames),
                  channels >= 1, Int(frames) <= ExecutionPlan.maximumSamples / Int(channels) else { return nil }
            return (kernels, channels, frames)
        }

        mutating func segment(
            _ steps: [IRStep], key parentKey: Int, cell: SwitchCell?, isShared: Bool, gates: [Int]
        ) throws(DSPError) -> PlanSegment {
            let segment = PlanSegment(cell: cell, isShared: isShared)
            var key = parentKey
            var gates = gates
            try append(steps, to: segment, key: &key, gates: &gates)
            return segment
        }

        mutating func append(
            _ steps: [IRStep], to segment: PlanSegment, key: inout Int, gates: inout [Int]
        ) throws(DSPError) {
            var index = 0
            var seenBranches: [Int: Int] = [:]
            while index < steps.count {
                let step = steps[index]
                switch step {
                case .kernel,
                     .region where step.isKernelRegion:
                    // A maximal run of kernels on one kind of sequence becomes one C plan.
                    var units: [Unit] = []
                    var isScalar = false
                    while index < steps.count, let unit = Unit(steps[index]) {
                        let scalar = unit.position.domain != .samples
                        if !units.isEmpty, scalar != isScalar { break }
                        isScalar = scalar
                        units.append(unit)
                        index += 1
                    }
                    if let run = try kernelRun(units, key: &key, isScalar: isScalar) { segment.steps.append(.kernels(run)) }
                    continue
                case .node(let node):
                    key = Builder.key(key, node)
                    let box = try nodeBox(node, key: key)
                    segment.steps.append(.node(NodeSlot(box: box)))
                case .emission(let description):
                    let sinkKey = Builder.key(key, description)
                    let cell = description.activation.map { SwitchCell(isOn: value(of: $0)) }
                    let target: any PlanSink
                    if case .object(let sink, _) = description.sink.target {
                        target = sink
                    } else {
                        // A bound result: the compiler numbers them as it meets them, and the
                        // plan has made a slot for each.
                        target = resultSlots[description.resultOrdinal ?? 0]
                    }
                    let slot = SinkSlot(sink: target, cell: cell)
                    slot.isNewBranch = !(previous?.sinkKeys.contains(sinkKey) ?? false)
                    sinkKeys.insert(sinkKey)
                    sinkSlots.append(slot)
                    sinks.append((target, description))
                    sinkGates.append(gates + (description.activation.map { [$0.ordinal] } ?? []))
                    if let activation = description.activation, let cell { switchTargets[activation.ordinal] = .emission(cell) }
                    segment.steps.append(.emission(slot))
                case .branch(let branch):
                    // Branches are keyed by what they hold, so a tap keeps its state when other
                    // taps come and go; equal siblings are told apart by their order.
                    let content = Builder.key(key, structureOf: step)
                    let ordinal = seenBranches[content, default: 0]
                    seenBranches[content] = ordinal + 1
                    let cell = branch.activation.map { SwitchCell(isOn: value(of: $0)) }
                    depth += 1
                    let child = try self.segment(
                        branch.steps, key: Builder.key(content, ordinal), cell: cell, isShared: branch.isShared,
                        gates: gates + (branch.activation.map { [$0.ordinal] } ?? []))
                    depth -= 1
                    segment.children.append(child)
                    if let activation = branch.activation { switchTargets[activation.ordinal] = .branch(child) }
                    segment.steps.append(.branch(child))
                case .gate(let activation, _):
                    key = Builder.key(key, "gate")
                    let cell = SwitchCell(isOn: value(of: activation))
                    switchTargets[activation.ordinal] = .gate(cell, segment: segment, index: segment.steps.count)
                    gates.append(activation.ordinal)
                    segment.steps.append(.gate(cell, key: key))
                case .region(let region):
                    // A switched group that does not run as one kernel: it holds a node, changes
                    // the rate inside, or has a stage with a switch of its own. Its steps run in
                    // line, between a marker and the index the marker skips to when the group
                    // is off.
                    key = Builder.key(key, "region")
                    let cell = SwitchCell(isOn: value(of: region.activation))
                    let slot: RegionSlot
                    if region.position.domain == .samples {
                        // On samples the switch is faded and keeps the latency (ACT-7, ACT-8).
                        // The group may hand on more frames in one block than it was given, when
                        // it changes the rate inside: its buffers are made for both sides.
                        let rate = region.position.environment.sampleRate
                        let channels = region.position.kernelChannels
                        let frames = max(region.position.maximumFrames, region.outputMaximumFrames, 1)
                        // The unprocessed path is a delay line of the group's latency, and the
                        // switch a fade of 10 ms: both are counted in frames here, and a count
                        // the group's buffers do not hold is refused before one is made (§9.3).
                        guard Builder.planSizes(kernels: 0, channels: channels, frames: frames) != nil,
                              let latency = FrameCount.exact(region.latency, at: rate, atMost: ExecutionPlan.maximumSamples / channels),
                              let fade = FrameCount.exact(0.010, at: rate, atMost: ExecutionPlan.maximumSamples) else {
                            throw .resourceAllocationFailed(what: "the buffers of a group", stage: region.path)
                        }
                        slot = try RegionSlot(
                            cell: cell, key: key, channels: channels, sampleRate: rate, latency: latency, fadeLength: max(fade, frames),
                            maximumFrames: frames)
                    } else {
                        slot = RegionSlot(cell: cell, key: key)
                    }
                    let at = segment.steps.count
                    segment.steps.append(.region(slot))
                    var inner = gates + [region.activation.ordinal]
                    try append(region.steps, to: segment, key: &key, gates: &inner)
                    if slot.fades {
                        // Switched on, the group runs unheard for its latency, which is the
                        // length of its delay line, and for its settling time (ACT-7).
                        slot.prerollLength = slot.latency + Builder.settling(of: segment, from: at + 1, rate: slot.sampleRate)
                        segment.steps.append(.regionEnd(slot))
                    }
                    slot.end = segment.steps.count
                    switchTargets[region.activation.ordinal] = .region(slot, segment: segment, index: at)
                }
                index += 1
            }
        }

        /// The settling time of the steps of `segment` from `start` on, in frames at `rate`:
        /// what their kernels and nodes say they need, beyond their latency, before their
        /// output is what it would have been had they always run. It is the figure SWAP-2
        /// defines, "declared by each stage, capped at one second", and a switch runs a stage
        /// for its latency plus this (ACT-7): the same rule as for the switch of a kernel,
        /// where `kernelRun` states it to the C plan.
        static func settling(of segment: PlanSegment, from start: Int, rate: Double) -> Int {
            // Added in frames at `rate`: a figure stated at that rate stays the whole number it is.
            var frames = 0.0
            for index in start ..< segment.steps.count {
                switch segment.steps[index] {
                case .kernels(let run):
                    for box in run.boxes {
                        frames += Double(box.kernel.settling_frames) * (rate / max(box.position.environment.sampleRate, 1))
                    }
                case .node(let slot):
                    let environment = slot.box.source.position.environment
                    let own = slot.box.source.position.domain == .samples ? environment.sampleRate : (environment.featureRate ?? environment.sampleRate)
                    frames += Double(slot.box.node.settlingFrames) * (rate / max(own, 1))
                default:
                    break
                }
            }
            return min(FrameCount.capped(frames, at: 1), Builder.oneSecond(at: rate))
        }

        /// One second in frames at `rate`: the most a stage is given to settle (SWAP-2).
        static func oneSecond(at rate: Double) -> Int {
            FrameCount.capped(1, at: rate)
        }

        /// Whether `candidate`, an object the previous plan holds at this place in the signal,
        /// is taken over (SWAP-1: "a kernel or node whose own description and whole upstream
        /// path are equal in both plans is moved").
        ///
        /// In a branch its place is all that counts: a branch runs in one plan at a time. On
        /// the main line the previous plan goes on running beside this one, from the first
        /// object in which the two differ, while this one is pre-rolled and faded in (SWAP-2).
        /// An object both held behind that point would be run by both for every block, and
        /// its state would be neither's. So the main line takes over what the previous plan
        /// runs, object for object and in order, up to the first that differs; what stands
        /// behind a stage that changed is made anew.
        private mutating func takes(_ candidate: AnyObject) -> Bool {
            let identity = ObjectIdentifier(candidate)
            guard !taken.contains(identity) else { return false }
            if depth == 0 {
                guard !hasDiverged, cursor < followed.count, followed[cursor] == identity else {
                    hasDiverged = true
                    return false
                }
                cursor += 1
            }
            taken.insert(identity)
            return true
        }

        /// The node for a step: the previous plan's, when its place in the signal is the same.
        private mutating func nodeBox(_ node: IRNode, key: Int) throws(DSPError) -> NodeBox {
            if let existing = previous?.nodeBoxes[key], existing.source == node, takes(existing) {
                nodeBoxes[key] = existing
                return existing
            }
            if depth == 0 { hasDiverged = true }
            let made: any AnalysisNode
            do throws(DSPError) { made = try node.step.make() } catch { throw error.inStage(node.path) }
            let box = try NodeBox(node: made, source: node)
            nodeBoxes[key] = box
            return box
        }

        /// The kernel for a unit at the place `key`, or `nil` for an identity, which runs no
        /// kernel (F4).
        private mutating func kernelBox(for unit: Unit, key: Int) throws(DSPError) -> KernelBox? {
            // The previous plan's, when its place in the signal and what it holds are the same (SWAP-1).
            if let existing = previous?.kernelBoxes[key], existing.source == unit.step, takes(existing) {
                kernelBoxes[key] = existing
                return existing
            }
            let made: KernelBox
            switch unit {
            case .group(let region):
                if depth == 0 { hasDiverged = true }
                made = KernelBox(kernel: try nestedKernel(region), source: unit.step, position: region.position)
            case .kernel(let kernel):
                if kernel.activation == nil, kernel.spec.isIdentity {
                    // No kernel runs for an identity. Its place is kept: values that make it
                    // something else are a change of values, not another stage (§5.5.4).
                    identities[key] = kernel
                    return nil
                }
                if kernel.activation == nil, !(depth == 0 && hasDiverged), let identity = previous?.identities[key],
                   identity.hasSameStructure(as: kernel) {
                    // The plan before ran no kernel here, because the stage was an identity. Its
                    // kernel is made as that identity, so this plan does at the exchange what
                    // the running one does, and the stage's values are then sent to it like any
                    // change of values: a gain ramps away from 0 dB instead of stepping. (Behind
                    // a stage that changed, the two plans are cross-faded anyway: the kernel is
                    // made with its values.)
                    made = KernelBox(kernel: try KernelFactory.make(identity, crossovers: crossovers), source: .kernel(identity), position: kernel.position)
                    arriving[ObjectIdentifier(made)] = kernel
                } else {
                    if depth == 0 { hasDiverged = true }
                    made = KernelBox(kernel: try KernelFactory.make(kernel, crossovers: crossovers), source: unit.step, position: kernel.position)
                }
            }
            kernelBoxes[key] = made
            return made
        }

        /// A run of kernels as one C plan, or `nil` when every kernel of the run is an
        /// identity, so that none runs.
        private mutating func kernelRun(_ units: [Unit], key: inout Int, isScalar: Bool) throws(DSPError) -> KernelRun? {
            let first = units[0].position
            let channels = first.kernelChannels
            var maximumFrames = 1
            for unit in units { maximumFrames = max(maximumFrames, Builder.frames(of: unit)) }
            // A size the plan cannot count, or that no machine holds, is an allocation that
            // failed, and it fails here, before anything is made for the run (§9.3).
            guard let sizes = Builder.planSizes(kernels: units.count, channels: channels, frames: maximumFrames) else {
                throw .resourceAllocationFailed(what: "a plan of \(units.count) kernels")
            }

            var boxes: [KernelBox?] = []
            var outputRate = first.environment.sampleRate
            for unit in units {
                key = Builder.key(key, structureOf: unit.step)
                boxes.append(try kernelBox(for: unit, key: key))
                outputRate = unit.position.environment.sampleRate
                if case .kernel(let kernel) = unit {
                    let rate = kernel.spec.rate
                    outputRate = outputRate * Double(rate.interpolation) / Double(rate.decimation)
                }
            }
            let kept = boxes.compactMap { $0 }
            guard !kept.isEmpty else {
                // Identities all: an identity is a kernel, never a group.
                for _ in units {
                    kernelOrder.append(nil)
                    kernelTargets.append(nil)
                }
                return nil
            }
            guard let plan = ztd_plan_create(UInt32(kept.count), sizes.channels, sizes.frames) else {
                throw .resourceAllocationFailed(what: "a plan of \(units.count) kernels")
            }
            do throws(DSPError) {
                var entries: [UInt32?] = []
                var latency = 0.0
                for (unit, box) in zip(units, boxes) {
                    guard let box else {
                        entries.append(nil)
                        continue
                    }
                    // The plan was made for exactly these kernels, and none of them is null.
                    let entry = ztd_plan_append(plan, box.kernel, false)
                    entries.append(entry)
                    let position = unit.position
                    latency += position.environment.sampleRate > 0 ? Double(box.kernel.latency_frames) / position.environment.sampleRate : 0
                    if let activation = unit.activation {
                        // 10 ms, and never shorter than one block (ACT-7). A rate at which that
                        // is more frames than a switch counts is refused, not cut (§9.3).
                        let rate = position.environment.sampleRate
                        guard let fade = FrameCount.exact(0.010, at: rate, atMost: Int(UInt32.max)) else {
                            throw DSPError.invalidParameter(
                                stage: unit.path, parameter: "sampleRate", reason: "the 10 ms of a switch at \(rate) Hz are not a number of frames it can count")
                        }
                        // The block is one the plan was sized for, far below 2³².
                        guard ztd_plan_make_switchable(plan, entry, UInt32(max(fade, position.maximumFrames, 1)), value(of: activation)) else {
                            throw DSPError.resourceAllocationFailed(what: "a switch")
                        }
                        // Switched on, the kernel runs unheard for its latency and for its settling
                        // time, the latter at most one second: the rule of a group that runs in
                        // line (ACT-7, SWAP-2). The plan does not know the rate, so it is told.
                        let preroll = Int(box.kernel.latency_frames) + min(Int(box.kernel.settling_frames), Builder.oneSecond(at: rate))
                        _ = ztd_plan_set_switch_preroll(plan, entry, UInt32(clamping: preroll))
                    }
                }
                let run = try KernelRun(plan: plan, boxes: kept, isScalar: isScalar, channels: channels, maximumFrames: maximumFrames,
                                        latency: latency, outputRate: outputRate)
                for (index, unit) in units.enumerated() {
                    let box = boxes[index], entry = entries[index]
                    kernelOrder.append(box)
                    if let activation = unit.activation, let entry { switchTargets[activation.ordinal] = .kernel(run, entry: entry) }
                    switch unit {
                    case .kernel:
                        kernelTargets.append(entry.map { (run, $0, 0) })
                        if let box, let kernel = arriving[ObjectIdentifier(box)] {
                            arrivals.append(Arrival(target: kernelTargets.count - 1, box: box, kernel: kernel))
                        }
                    case .group(let region):
                        for inner in region.steps.indices { kernelTargets.append(entry.map { (run, $0, UInt32(inner)) }) }
                    }
                }
                return run
            } catch {
                ztd_plan_destroy(plan)
                throw error
            }
        }

        /// A switched group of kernels as one kernel: a plan of its own behind the kernel ABI.
        /// Every stage of the group gets its kernel, an identity too: a group is made whole.
        private func nestedKernel(_ region: IRRegion) throws(DSPError) -> ztd_kernel_t {
            let position = region.position
            guard let sizes = Builder.planSizes(kernels: region.steps.count, channels: position.kernelChannels, frames: Builder.frames(of: region)),
                  let plan = ztd_plan_create(sizes.kernels, sizes.channels, sizes.frames) else {
                throw .resourceAllocationFailed(what: "the plan of a group", stage: region.path)
            }
            do throws(DSPError) {
                // The group delays the signal by the latencies of all its kernels, and its one
                // kernel states that sum in 32 bits. It is added here, in a type that holds it:
                // the group is switched as one, its unprocessed path is a delay line of that
                // many frames (ACT-8), and a sum the buffers of a plan do not hold is refused
                // before the kernel could state another figure in its place (REAL-5, §9.3).
                let limit = ExecutionPlan.maximumSamples / position.kernelChannels
                var latency = 0
                for case .kernel(let kernel) in region.steps {
                    let made = try KernelFactory.make(kernel, crossovers: crossovers)
                    // The plan was made for exactly these kernels, and the factory makes none that is null.
                    _ = ztd_plan_append(plan, made, true)
                    latency += Int(made.latency_frames)
                    guard latency <= limit else {
                        throw DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: region.path)
                    }
                }
            } catch {
                ztd_plan_destroy(plan)
                throw error
            }
            return ztd_plan_as_kernel(plan)
        }
    }

    // MARK: Bindings (BIND-6)

    /// Replaces the bindings the plan's description carries with those of an equal pipeline:
    /// the ones captured before are let go. Control context.
    func adoptBindings(resolved: [StageDescription], switches: [BoundSwitch], results: [BoundResult]) {
        lowered = LoweredPipeline(
            resolved: resolved, steps: lowered.steps, skeleton: lowered.skeleton, switches: switches, results: results,
            switchSites: lowered.switchSites, resultSites: lowered.resultSites, readerEnvironments: lowered.readerEnvironments,
            sourceEnvironment: lowered.sourceEnvironment, resultRate: lowered.resultRate, output: lowered.output,
            isSuspended: lowered.isSuspended)
    }

    // MARK: Values (§5.5.4)

    /// True when the plan can take the values of `lowered`, a pipeline of the same structure,
    /// by command: every kernel whose values differ from the ones the plan runs exists. A
    /// stage that was an identity when the plan was compiled has no kernel to send them to
    /// (F4): for that one a plan is compiled. Control context.
    func canTakeValues(of lowered: LoweredPipeline) -> Bool {
        let before = IRStep.kernels(of: self.lowered.skeleton), after = IRStep.kernels(of: lowered.skeleton)
        guard before.count == after.count, after.count == kernelTargets.count else { return false }
        for (index, kernel) in after.enumerated() where kernel.spec != before[index].spec && kernelTargets[index] == nil { return false }
        return true
    }

    /// Records that the plan now runs the values of `lowered`, a pipeline of the same
    /// structure whose changed values have been sent to the kernels by command: a later plan
    /// compares against what the kernels hold now. Control context.
    func adoptValues(of lowered: LoweredPipeline) {
        let objects = IRStep.kernelObjects(of: lowered.skeleton)
        guard objects.count == kernelOrder.count else { return }
        for (box, step) in zip(kernelOrder, objects) { box?.source = step }
        self.lowered = lowered
    }

    /// The values that are on their way to kernels this plan made as identities, to be sent
    /// once: the list is empty afterwards. Control context.
    func takeArrivals() -> [Arrival] {
        defer { arrivals = [] }
        return arrivals
    }

    // MARK: Transition (SWAP-1…3)

    /// What transforms or gates the signal of the main line, step by step. Taps and sinks
    /// only listen, so they are not part of it.
    private enum SignalItem: Equatable {
        case kernels([ObjectIdentifier])
        case node(ObjectIdentifier)
        case gate(Int)
        case region(Int)
        case output
    }

    /// The main line of a plan, step by step. Kernels named in `arriving` are left out.
    private static func signalPath(of root: PlanSegment, without arriving: Set<ObjectIdentifier> = []) -> [(step: Int, item: SignalItem)] {
        var path: [(step: Int, item: SignalItem)] = []
        for (index, step) in root.steps.enumerated() {
            switch step {
            case .kernels(let run):
                let boxes = run.boxes.map { ObjectIdentifier($0) }.filter { !arriving.contains($0) }
                if !boxes.isEmpty { path.append((index, .kernels(boxes))) }
            case .node(let slot): path.append((index, .node(ObjectIdentifier(slot.box))))
            case .gate(_, let key): path.append((index, .gate(key)))
            case .region(let slot): path.append((index, .region(slot.key)))
            case .output: path.append((index, .output))
            case .branch, .emission, .regionEnd: break
            }
        }
        return path
    }

    /// The kernels and nodes of a plan's main line, in the order the signal passes them.
    private static func mainLineObjects(of root: PlanSegment) -> [ObjectIdentifier] {
        var objects: [ObjectIdentifier] = []
        for step in root.steps {
            switch step {
            case .kernels(let run): objects += run.boxes.map { ObjectIdentifier($0) }
            case .node(let slot): objects.append(ObjectIdentifier(slot.box))
            default: break
            }
        }
        return objects
    }

    private static func transition(from old: ExecutionPlan, to lowered: LoweredPipeline, root: PlanSegment, arriving: Set<ObjectIdentifier>) -> PlanTransition {
        // A kernel that arrives was made as the identity its stage was in the plan before: at
        // the exchange the signal passes it as it passed no kernel. The main lines are
        // compared without such kernels.
        let oldPath = signalPath(of: old.root), newPath = signalPath(of: root, without: arriving)
        if newPath.map(\.item) == oldPath.map(\.item) {
            // Only taps and sinks changed, or kernels arrived whose values are still to come:
            // there is nothing to settle and nothing to fade.
            return PlanTransition(oldStep: old.root.steps.count, newStep: root.steps.count, kernel: 0, newKernel: 0, prerollFrames: 0,
                                  crossfades: false, mainLineUnchanged: true)
        }
        // Both paths end in `.output` and nowhere else, so two that differ differ before either ends.
        var position = 0
        while oldPath[position].item == newPath[position].item { position += 1 }
        let oldStep = oldPath[position].step, newStep = newPath[position].step
        // Inside two runs of kernels: the kernels they share come first in both; the kernels
        // that arrive in the new run among them are stepped over.
        var kernel = 0, newKernel = 0
        if case .kernels(let a) = old.root.steps[oldStep], case .kernels(let b) = root.steps[newStep] {
            while true {
                while newKernel < b.boxes.count, arriving.contains(ObjectIdentifier(b.boxes[newKernel])) { newKernel += 1 }
                guard kernel < a.boxes.count, newKernel < b.boxes.count, a.boxes[kernel] === b.boxes[newKernel] else { break }
                kernel += 1
                newKernel += 1
            }
        }

        // What is new on the main line settles before it is used, for at most one second.
        var preroll = 0.0
        var newLatency = 0.0, oldLatency = 0.0
        var synchronous = true
        func examine(_ segment: PlanSegment, from: Int, skip: Int, latency: inout Double, settle: inout Double) {
            for index in from ..< segment.steps.count {
                switch segment.steps[index] {
                case .kernels(let run):
                    let first = index == from ? skip : 0
                    for box in run.boxes.dropFirst(first) {
                        let rate = box.position.environment.sampleRate
                        let spec: KernelSpec? = if case .kernel(let kernel) = box.source { kernel.spec } else { nil }
                        if let spec, !spec.keepsRate { synchronous = false }
                        if run.isScalar { synchronous = false }
                        latency += Double(box.kernel.latency_frames) / max(rate, 1)
                        settle += (Double(box.kernel.latency_frames) + Double(box.kernel.settling_frames)) / max(rate, 1)
                    }
                case .node(let slot):
                    synchronous = false
                    let environment = slot.box.source.position.environment
                    let rate = slot.box.source.position.domain == .samples ? environment.sampleRate : (environment.featureRate ?? environment.sampleRate)
                    settle += (Double(slot.box.node.latencyFrames) + Double(slot.box.node.settlingFrames)) / max(rate, 1)
                case .gate, .region:
                    synchronous = false
                case .branch, .emission, .output, .regionEnd:
                    break
                }
            }
        }
        var ignored = 0.0
        examine(root, from: newStep, skip: newKernel, latency: &newLatency, settle: &preroll)
        examine(old.root, from: oldStep, skip: kernel, latency: &oldLatency, settle: &ignored)
        // Old and new output can be cross-faded when they are the same kind of signal at the
        // same rate with the same delay, and both come out block for block (SWAP-2).
        let sameOutput = old.lowered.output.domain == .samples && lowered.output.domain == .samples
            && old.lowered.output.environment.sampleRate == lowered.output.environment.sampleRate
            && old.lowered.output.environment.channelCount == lowered.output.environment.channelCount
        let crossfades = synchronous && sameOutput && abs(newLatency - oldLatency) < 1e-9
        // The thread that carries the exchange out counts the pre-roll in frames of the source:
        // the count is made here, so that thread converts nothing (RT-4).
        return PlanTransition(oldStep: oldStep, newStep: newStep, kernel: kernel, newKernel: newKernel,
                              prerollFrames: FrameCount.capped(min(preroll, 1), at: lowered.sourceEnvironment.sampleRate),
                              crossfades: crossfades, mainLineUnchanged: false)
    }
}
