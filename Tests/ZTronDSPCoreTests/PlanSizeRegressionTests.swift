import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Plans of a size no machine holds, or no plan can count (§9.3): "No `fatalError` or
/// `precondition` is reachable from public API through invalid input", and a size the machine
/// cannot hold "is an allocation that failed, not a trap". The size of a plan is decided by
/// arithmetic, before anything is allocated for it.
@Suite("Plans no machine can hold are typed errors (§9.3)")
struct PlanSizeRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)

    /// A block of 2²⁰ frames is one the engine accepts, and a factor of 4 096 one a rate changer
    /// accepts. Together they need buffers of 2³² frames, which must be refused with
    /// `resourceAllocationFailed`.
    ///
    /// The defect: the plan converted the frame count to the 32 bits a C plan counts in before
    /// any size was checked, and the conversion trapped.
    @Test func aRateChangerThatNeedsMoreFramesThanAPlanCanCountIsATypedError() throws {
        #expect(throws: DSPError.self) {
            _ = try Pipeline { TestZeroStuff(factor: 4_096) }.process([0, 1, 2, 3], format: format, blockSize: 1 << 20)
        }
    }

    /// The error says what could not be had, and it is the same error for a count that fits 32
    /// bits and no machine: 2²⁹ frames of scratch, twice, and twice again for the run's own
    /// buffers. Blocks of any size are refused the same way, up to the largest an `Int` holds,
    /// where the frames a rate changer needs are no number at all.
    @Test func sizesAPlanCannotCountOrHoldAreOneTypedError() throws {
        let refused = DSPError.resourceAllocationFailed(what: "a plan of 1 kernels")
        #expect(throws: refused) { _ = try Pipeline { TestZeroStuff(factor: 4_096) }.process([0, 1, 2, 3], format: format, blockSize: 1 << 20) }
        #expect(throws: refused) { _ = try Pipeline { TestZeroStuff(factor: 512) }.process([0, 1, 2, 3], format: format, blockSize: 1 << 20) }
        #expect(throws: refused) { _ = try Pipeline { TestGain(2) }.process([0, 1, 2, 3], format: format, blockSize: (1 << 28) + 1) }
        #expect(throws: refused) { _ = try Pipeline { TestZeroStuff(factor: 4_096) }.process([0, 1, 2, 3], format: format, blockSize: Int.max) }
        #expect(throws: refused) { _ = try Pipeline { TestSubsample(by: 3) }.process([0, 1, 2, 3], format: format, blockSize: Int.max) }
        // The same count of samples in channels instead of frames.
        let wide = SignalFormat(sampleRate: 48_000, channelCount: 1 << 12)
        let silence = [[Float]](repeating: [0, 0], count: 1 << 12)
        #expect(throws: refused) { _ = try Pipeline { TestGain(2) }.process(channels: silence, format: wide, blockSize: (1 << 16) + 1) }

        // A switched group is held to the same bound: as one kernel, and with its steps in line.
        #expect(throws: refused) {
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestGain(2); TestDelay(1) } }
                .process([0, 1, 2, 3], format: format, blockSize: (1 << 28) + 1)
        }
        let group = DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: StagePath().appending("Group", index: 0))
        #expect(throws: group) {
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestSubsample(by: 2); TestZeroStuff(factor: 2) } }
                .process([0, 1, 2, 3], format: format, blockSize: (1 << 28) + 1)
        }

        // What a plan can hold, it holds: the largest block of the tests that needs no gigabyte.
        let output = try Pipeline { TestZeroStuff(factor: 4) }.process([1, 2, 3], format: format, blockSize: 1 << 16)
        #expect(output == [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0])
    }

    /// The frames a rate changer may hand on are computed without a trap, whatever the block:
    /// one more than the exact ratio, and the largest `Int` where that is no number.
    @Test func theFramesBehindARateChangerAreCountedWithoutATrap() {
        #expect(LoweringContext.maximumFrames(after: .zeroStuff(factor: 3), from: 64) == 193)
        #expect(LoweringContext.maximumFrames(after: .subsample(factor: 3, phase: 0), from: 64) == 23)
        #expect(LoweringContext.maximumFrames(after: .subsample(factor: 3, phase: 0), from: 63) == 22)
        #expect(LoweringContext.maximumFrames(after: .gain(factor: 2, ramp: 0), from: Int.max) == Int.max, "a kernel that keeps the rate keeps the count")
        #expect(LoweringContext.maximumFrames(after: .zeroStuff(factor: 4_096), from: Int.max) == Int.max)
        #expect(LoweringContext.maximumFrames(after: .zeroStuff(factor: 2), from: Int.max / 2 + 1) == Int.max)
        #expect(LoweringContext.maximumFrames(after: .subsample(factor: 1, phase: 0), from: Int.max) == Int.max, "a factor of 1 keeps the rate")
        #expect(LoweringContext.maximumFrames(after: .subsample(factor: 2, phase: 0), from: Int.max) == Int.max / 2 + 2)
        let slow = CustomKernel(name: "Slow", key: 0, interpolation: 1, decimation: Int.max) { _, _, _ in ztd_kernel_identity() }
        #expect(LoweringContext.maximumFrames(after: .custom(slow), from: 512) == 2)
        let fast = CustomKernel(name: "Fast", key: 0, interpolation: Int.max, decimation: 2) { _, _, _ in ztd_kernel_identity() }
        #expect(LoweringContext.maximumFrames(after: .custom(fast), from: 512) == Int.max)
        #expect(LoweringContext.maximumFrames(after: .custom(fast), from: 1) == Int.max / 2 + 2)
    }

    /// "Decided before anything is allocated": a plan that is refused for its size has asked the
    /// system for nothing of that size. What the refusal allocates is the bookkeeping of the
    /// attempt, kilobytes; the scratch of such a plan would have been gigabytes, zeroed.
    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aPlanThatIsRefusedForItsSizeAllocatesNothingOfThatSize() throws {
        let format = format
        var refusals = 0
        let counts = try countAllocations {
            for (factor, blockSize) in [(4_096, 1 << 20), (512, 1 << 20), (2, 1 << 28)] {
                do {
                    _ = try Pipeline { TestZeroStuff(factor: factor) }.process([0, 1, 2, 3], format: format, blockSize: blockSize)
                } catch {
                    refusals += 1
                }
            }
        }
        #expect(refusals == 3)
        #expect(counts.bytes < 1 << 20, "three refusals asked the system for \(counts.bytes) bytes in all")
    }
}
