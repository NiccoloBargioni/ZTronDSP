// The run-time half of a plan: what the analysis thread does with it, once per block (§5.5.2).
// Nothing here allocates, locks or logs (RT-2); loops are `while` loops (CR-002).

extension ExecutionPlan {
    /// Runs one block of samples through the plan. Analysis thread.
    @inline(__always)
    func process(_ frame: FrameView) {
        run(root, from: 0, frame)
    }

    /// Runs the steps of `segment` from `start` on `frame`. A node hands each frame it emits
    /// back here, at the step after it, so one input may run the rest of the segment no times,
    /// once, or several times.
    func run(_ segment: PlanSegment, from start: Int, _ frame: FrameView) {
        var current = frame
        var index = start
        let count = segment.steps.count
        while index < count {
            // While a new plan is pre-rolled beside this one, it hears the main line at the
            // point where the two start to differ (SWAP-2).
            if let shadow, segment === root, index == shadowStep {
                if shadowKernel > 0, case .kernels(let run) = segment.steps[index] {
                    guard let middle = run.process(current, first: 0, last: UInt32(shadowKernel), into: run.middle) else { return }
                    shadow.runShadow(from: shadowStart, kernel: shadowStartKernel, middle)
                    guard let next = run.process(middle, first: UInt32(shadowKernel), last: .max, into: run.output) else { return }
                    run.advance(next)
                    current = next
                    index &+= 1
                    continue
                }
                shadow.runShadow(from: shadowStart, kernel: shadowStartKernel, current)
            }

            switch segment.steps[index] {
            case .kernels(let run):
                guard let next = run.process(current, first: 0, last: .max, into: run.output) else { return }
                run.advance(next)
                current = next
            case .node(let slot):
                slot.process(current)
                return
            case .branch(let child):
                if !isShadow, child.isLive { self.run(child, from: 0, current) }
            case .emission(let slot):
                if !isShadow, !slot.isRetired, slot.cell?.isOn ?? true { slot.sink.write(current) }
            case .gate(let cell, _):
                if !cell.isOn { return }
            case .region(let slot):
                if !slot.fades {
                    if !slot.cell.isOn {
                        index = slot.end
                        continue
                    }
                } else if let block = current.samples {
                    slot.capture(block, time: current.time)
                    switch slot.state {
                    case .active, .fadingOut, .fadingIn:
                        break
                    case .bypassed:
                        current = slot.dry(from: slot.emittedIndex, count: block.frameCount)
                        slot.emittedIndex &+= block.frameCount
                        index = slot.end
                        continue
                    case .prerolling:
                        // The delayed input goes on while the stages inside settle.
                        let dry = slot.dry(from: slot.emittedIndex, count: block.frameCount)
                        slot.emittedIndex &+= block.frameCount
                        self.run(segment, from: slot.end, dry)
                        slot.prerollLeft &-= block.frameCount
                        if slot.prerollLeft <= 0 {
                            slot.state = .fadingIn
                            slot.fadePosition = 0
                        }
                    }
                }
            case .regionEnd(let slot):
                guard let block = current.samples else { break }
                let first = slot.processedIndex
                slot.processedIndex &+= block.frameCount
                switch slot.state {
                case .active:
                    slot.emittedIndex = slot.processedIndex
                case .bypassed, .prerolling:
                    return
                case .fadingOut, .fadingIn:
                    // Only what the unprocessed path has not handed on already.
                    let skip = max(slot.emittedIndex &- first, 0)
                    if skip >= block.frameCount { return }
                    let mixed = slot.mix(block, skipping: skip, at: first &+ skip)
                    slot.emittedIndex = first &+ block.frameCount
                    if slot.fadePosition < slot.fadeLength {
                        current = mixed
                    } else if slot.state == .fadingIn {
                        slot.state = .active
                        current = mixed
                    } else {
                        slot.state = .bypassed
                        self.run(segment, from: index &+ 1, mixed)
                        // What the input is ahead of the processed signal comes out at once.
                        while slot.emittedIndex < slot.inputCount {
                            let count = min(slot.inputCount &- slot.emittedIndex, slot.chunk)
                            let dry = slot.dry(from: slot.emittedIndex, count: count)
                            slot.emittedIndex &+= count
                            self.run(segment, from: index &+ 1, dry)
                        }
                        return
                    }
                }
            case .output:
                if isShadow { output?.takeShadow(current) } else { output?.take(current) }
            }
            index &+= 1
        }
    }

    /// Runs the part of the main line this plan does not share with the running one, with its
    /// branches and sinks idle (SWAP-2, SWAP-3).
    func runShadow(from step: Int, kernel: Int, _ frame: FrameView) {
        if kernel > 0, step < root.steps.count, case .kernels(let run) = root.steps[step] {
            guard let next = run.process(frame, first: UInt32(kernel), last: .max, into: run.output) else { return }
            run.advance(next)
            self.run(root, from: step &+ 1, next)
        } else {
            self.run(root, from: step, frame)
        }
    }

    // MARK: Commands, applied at a block boundary

    /// Moves the bound switch with the given ordinal (ACT-5).
    func setSwitch(_ ordinal: Int, _ isOn: Bool) {
        guard ordinal >= 0, ordinal < switchTargets.count else { return }
        switch switchTargets[ordinal] {
        case .kernel(let run, let entry):
            var command = ztd_command_t()
            command.target = entry
            command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
            command.scalar.0 = isOn ? 1 : 0
            ztd_plan_command(run.plan, &command)
        case .branch(let segment):
            guard let cell = segment.cell else { return }
            // A branch that resumes starts as it does at session start (ACT-10).
            if isOn, !cell.isOn { reset(segment, from: 0, to: segment.steps.count) }
            cell.isOn = isOn
            refreshLiveness(of: root)
        case .emission(let cell):
            cell.isOn = isOn
        case .gate(let cell, let segment, let index):
            if isOn, !cell.isOn { reset(segment, from: index &+ 1, to: segment.steps.count) }
            cell.isOn = isOn
        case .region(let slot, let segment, let index):
            guard slot.fades else {
                if isOn, !slot.cell.isOn { reset(segment, from: index &+ 1, to: slot.end) }
                slot.cell.isOn = isOn
                return
            }
            slot.cell.isOn = isOn
            switch (isOn, slot.state) {
            case (false, .active):
                slot.state = .fadingOut
                slot.fadePosition = 0
            case (false, .fadingIn):
                // The fade turns round where it stands.
                slot.state = .fadingOut
                slot.fadePosition = max(slot.fadeLength &- slot.fadePosition, 0)
            case (false, .prerolling):
                slot.state = .bypassed
            case (true, .bypassed):
                // Restoring takes effect after the pre-roll; before it, nothing changes (ACT-7).
                reset(segment, from: index &+ 1, to: slot.end)
                slot.processedIndex = slot.inputCount
                if slot.prerollLength > 0 {
                    slot.state = .prerolling
                    slot.prerollLeft = slot.prerollLength
                } else {
                    slot.state = .fadingIn
                    slot.fadePosition = 0
                }
            case (true, .fadingOut):
                slot.state = .fadingIn
                slot.fadePosition = max(slot.fadeLength &- slot.fadePosition, 0)
            default:
                break
            }
        case .none:
            break
        }
    }

    /// Hands a value command to the kernel it is for (§5.5.4). `target` counts the kernels of
    /// the lowered pipeline in order.
    func applyValues(_ command: inout ztd_command_t) {
        let target = Int(command.target)
        // A stage that was an identity when the plan was compiled has no kernel to take values.
        guard target < kernelTargets.count, let address = kernelTargets[target] else { return }
        command.target = address.entry
        command.flags = address.inner
        ztd_plan_command(address.run.plan, &command)
    }

    /// Recomputes which segments run, from the leaves up, after a switch has moved. A shared
    /// prefix that comes back because one of its branches did starts cold too: what it kept
    /// from before the suspension would reach that branch as a stale frame (ACT-9, ACT-10).
    @discardableResult
    func refreshLiveness(of segment: PlanSegment) -> Bool {
        var anyChild = false
        var index = 0
        while index < segment.children.count {
            if refreshLiveness(of: segment.children[index]) { anyChild = true }
            index &+= 1
        }
        let own = segment.cell?.isOn ?? true
        let live = own && (!segment.isShared || anyChild)
        if live, !segment.isLive, segment.isShared { reset(segment, from: 0, to: segment.steps.count) }
        segment.isLive = live
        return live
    }

    /// A cold start of the steps `from ..< to` of a segment, and of everything below them.
    func reset(_ segment: PlanSegment, from: Int, to: Int) {
        var index = from
        while index < to, index < segment.steps.count {
            switch segment.steps[index] {
            case .kernels(let run): run.reset()
            case .node(let slot): slot.box.reset()
            case .branch(let child): reset(child, from: 0, to: child.steps.count)
            case .region(let slot): slot.restart()
            case .emission, .gate, .regionEnd, .output: break
            }
            index &+= 1
        }
    }

    /// A cold start of the whole plan: after an interruption, a format change, a restart.
    func resetAll() {
        reset(root, from: 0, to: root.steps.count)
    }
}
