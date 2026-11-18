/// Keeps every `factor`-th sample, starting at `phase`. No filter: what aliases, aliases
/// (§6.12). A factor below 1 is taken as 1; a phase outside `0 ..< factor` is wrapped into it.
/// Allocates a new array; not for the analysis thread.
public func subsampled<Element>(_ samples: [Element], by factor: Int, phase: Int = 0) -> [Element] {
    let factor = max(factor, 1)
    let phase = ((phase % factor) + factor) % factor
    guard factor > 1 || phase > 0 else { return samples }
    var result: [Element] = []
    result.reserveCapacity(samples.count / factor + 1)
    var index = phase
    while index < samples.count {
        result.append(samples[index])
        index += factor
    }
    return result
}

/// Inserts `factor − 1` zeros after each sample. No filter: the images remain (§6.12). A
/// factor below 1 is taken as 1. `subsampled(upsampled(x, by: L), by: L)` is `x`, bit for bit.
/// Allocates a new array; not for the analysis thread.
public func upsampled<Element: AdditiveArithmetic>(_ samples: [Element], by factor: Int) -> [Element] {
    let factor = max(factor, 1)
    guard factor > 1 else { return samples }
    var result = [Element](repeating: .zero, count: samples.count * factor)
    var index = 0
    while index < samples.count {
        result[index * factor] = samples[index]
        index += 1
    }
    return result
}

/// The pointer form of ``subsampled(_:by:phase:)`` for a stage that carries its phase across
/// blocks. Reads `count` samples, keeps those at positions `phase`, `phase + factor`, …, and
/// returns how many it wrote and the phase to pass for the next block.
///
/// `destination` needs room for `(count + factor − 1) / factor` samples. Allocation-free;
/// callable on the analysis thread.
@inlinable
public func subsample(
    _ source: UnsafePointer<Float>, count: Int, by factor: Int, phase: Int, into destination: UnsafeMutablePointer<Float>
) -> (written: Int, nextPhase: Int) {
    let factor = max(factor, 1)
    var index = min(max(phase, 0), factor - 1)
    var written = 0
    while index < count {
        destination[written] = source[index]
        written &+= 1
        index &+= factor
    }
    return (written, index - max(count, 0))
}

/// The pointer form of ``upsampled(_:by:)``: writes `count · factor` samples. Source and
/// destination must not overlap. Allocation-free; callable on the analysis thread.
@inlinable
public func upsample(_ source: UnsafePointer<Float>, count: Int, by factor: Int, into destination: UnsafeMutablePointer<Float>) {
    let factor = max(factor, 1)
    var index = 0
    while index < count {
        let base = index &* factor
        destination[base] = source[index]
        var offset = 1
        while offset < factor {
            destination[base &+ offset] = 0
            offset &+= 1
        }
        index &+= 1
    }
}
