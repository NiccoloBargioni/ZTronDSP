/// A value that moves to its target over a fixed number of frames (§5.11.4): what keeps a
/// changed gain from producing a step (§6.2).
///
/// The ramp is linear and reaches its target exactly: the last step lands on the target
/// itself, not on an accumulated sum. A value type whose state is state by nature (IMM-3):
/// it lives inside a kernel or a node and is advanced by one thread. Allocation-free.
public struct Ramp: Sendable {
    @usableFromInline var current: Float
    @usableFromInline var goal: Float
    @usableFromInline var increment: Float
    @usableFromInline var remaining: Int
    /// The number of frames a move takes.
    public let duration: Int

    /// - Parameters:
    ///   - value: where the ramp starts, at rest.
    ///   - duration: frames a move takes; below 1 the ramp jumps.
    @inlinable
    public init(value: Float, duration: Int) {
        self.current = value
        self.goal = value
        self.increment = 0
        self.remaining = 0
        self.duration = max(duration, 0)
    }

    /// The value now.
    @inlinable public var value: Float { current }
    /// The value the ramp is moving to.
    @inlinable public var target: Float { goal }
    /// True while the value has not reached its target.
    @inlinable public var isMoving: Bool { remaining > 0 }
    /// Frames left until the target is reached.
    @inlinable public var remainingFrames: Int { remaining }

    /// Starts a move from the current value to `target`, over `duration` frames.
    @inlinable
    public mutating func setTarget(_ target: Float) {
        goal = target
        if duration < 1 || target == current {
            current = target
            increment = 0
            remaining = 0
        } else {
            increment = (target - current) / Float(duration)
            remaining = duration
        }
    }

    /// Sets the value and the target at once, with no ramp.
    @inlinable
    public mutating func jump(to value: Float) {
        current = value
        goal = value
        increment = 0
        remaining = 0
    }

    /// Advances one frame and returns the new value.
    ///
    /// The value is computed from the target, `target − increment · remaining`, not by adding
    /// the increment to a running value: round-off does not accumulate, and stepping by
    /// frames or by blocks gives the same values.
    @inlinable
    public mutating func next() -> Float {
        if remaining > 0 {
            remaining &-= 1
            current = remaining == 0 ? goal : goal - increment * Float(remaining)
        }
        return current
    }

    /// The moving part of the next `count` frames: the value at the first of them, the
    /// increment per frame, and how many of them move. The frames after those hold the
    /// target. Advances the ramp by `count` frames.
    ///
    /// Frame `k` of the move holds `start + k · increment`, which is what `vDSP_vrampmul`
    /// computes.
    @inlinable
    public mutating func advance(by count: Int) -> (start: Float, increment: Float, movingFrames: Int) {
        guard remaining > 0, count > 0 else { return (current, 0, 0) }
        let moving = min(count, remaining)
        let start = goal - increment * Float(remaining &- 1)
        remaining &-= moving
        current = remaining == 0 ? goal : goal - increment * Float(remaining)
        return (start, increment, moving)
    }

    /// Writes the next `count` values and advances by as many frames.
    @inlinable
    public mutating func render(into values: UnsafeMutablePointer<Float>, count: Int) {
        var index = 0
        while index < count {
            values[index] = next()
            index &+= 1
        }
    }
}

/// State hygiene (RT-6): sets to zero every value whose magnitude is below `threshold`, so no
/// kernel or node leaves denormal state behind. Call it at the end of a block. The
/// floating-point environment is not touched. Allocation-free.
@inlinable
public func flushSmallState(_ state: UnsafeMutablePointer<Float>, count: Int, threshold: Float = 1e-20) {
    var index = 0
    while index < count {
        let value = state[index]
        if value < threshold && value > -threshold { state[index] = 0 }
        index &+= 1
    }
}

/// State hygiene (RT-6) for double-precision state.
@inlinable
public func flushSmallState(_ state: UnsafeMutablePointer<Double>, count: Int, threshold: Double = 1e-20) {
    var index = 0
    while index < count {
        let value = state[index]
        if value < threshold && value > -threshold { state[index] = 0 }
        index &+= 1
    }
}
