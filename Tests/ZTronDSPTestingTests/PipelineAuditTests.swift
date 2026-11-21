import Darwin
import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

// Everything here is written on the public API alone, as a test target outside the package is:
// a stage, its node, and the audit that runs them (EXT-3).

/// What a test sees of the node a stage made: the thread it ran on, and how often.
private final class Witness: Hashable, @unchecked Sendable {
    // Threading: written by the node on the thread that runs it, which is the test's own, and
    // read by the test when the run is over.
    private(set) var thread: pthread_t?
    private(set) var otherThreads = 0
    private(set) var blocks = 0

    func note() {
        let current = pthread_self()
        if thread == nil { thread = current } else if thread != current { otherThreads += 1 }
        blocks += 1
    }

    static func == (lhs: Witness, rhs: Witness) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A node that hands blocks of samples on as they come, and allocates on every block when it
/// is told to: what RT-2 forbids.
private final class PassingNode: AnalysisNode {
    let latencyFrames = 0
    let settlingFrames = 0
    private let allocates: Bool
    private let witness: Witness

    init(allocates: Bool, witness: Witness) {
        self.allocates = allocates
        self.witness = witness
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        witness.note()
        if allocates { forceAllocation(byteCount: 48) }
        guard let block = input.samples, let target = output.samples else { return }
        var channel = 0
        while channel < min(block.channelCount, target.channelCount) {
            memcpy(target.channel(channel), block.channel(channel), block.frameCount * MemoryLayout<Float>.stride)
            channel += 1
        }
        output.emit(count: block.frameCount)
    }

    func reset() {}
}

private struct Passing: PipelineStage {
    typealias Input = Samples
    typealias Output = Samples
    let allocates: Bool
    let witness: Witness

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let channels = context.channelCount, block = context.maximumBlockFrames
        let allocates = allocates, witness = witness
        context.emit(.analysis(AnalysisStep(
            name: "Passing", key: self, output: .samples(channelCount: channels, maximumFrames: block),
            scope: .samples(maximumBlockFrames: block, channelCount: channels)
        ) { () throws(DSPError) -> any AnalysisNode in PassingNode(allocates: allocates, witness: witness) }))
    }
}

/// A gain on a stock kernel.
private struct Halving: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.gain(factor: 0.5, ramp: 0))
    }
}

/// EXT-3 (CR-025 item 4): "the tools are public". A node written outside the package could not
/// be run on the test's thread: `FrameWriter` has no public initialiser and the plan's runner
/// is internal, so only the package's own tests, with `@testable`, could hold a node inside
/// `expectNoAllocations`. `expectNoAllocationsRunning` compiles a pipeline and runs it block by
/// block on the calling thread inside the audit.
@Suite("The audit of a pipeline on the caller's thread (EXT-3)")
struct PipelineAuditTests {
    // Under the Thread Sanitizer the audit counts nothing (`AllocationAudit.isUnderThreadSanitizer`):
    // a test that needs the probe to catch an allocation runs in the plain runs only.
    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aNodeThatAllocatesIsCaughtOnTheTestsOwnThread() throws {
        let witness = Witness()
        var counts = AllocationCounts(allocations: 0, deallocations: 0, bytes: 0)
        try withKnownIssue {
            counts = try expectNoAllocationsRunning(Pipeline { Halving(); Passing(allocates: true, witness: witness) }, blocks: 50, "a node that allocates")
        } matching: { issue in
            issue.description.contains("a node that allocates") && issue.description.contains("50 allocation(s) of 2400 byte(s), 50 deallocation(s)")
        }
        #expect(counts == AllocationCounts(allocations: 50, deallocations: 50, bytes: 50 * 48), "one allocation per block inside the audit: \(counts)")
        // Eight blocks before the audit opens, fifty inside it, all of them on this thread.
        #expect(witness.blocks == 58 && witness.otherThreads == 0 && witness.thread == pthread_self())
    }

    @Test func aPipelineThatAllocatesNothingPasses() throws {
        let witness = Witness()
        let quiet = try expectNoAllocationsRunning(Pipeline { Halving(); Passing(allocates: false, witness: witness) }, blocks: 200)
        #expect(quiet == AllocationCounts(allocations: 0, deallocations: 0, bytes: 0) && witness.blocks == 208)
        // Another format and another block size: two channels, blocks of 64 frames.
        let stereo = Witness()
        try expectNoAllocationsRunning(
            Pipeline { Passing(allocates: false, witness: stereo); Halving() }, format: SignalFormat(sampleRate: 44_100, channelCount: 2), blockSize: 64, blocks: 30)
        #expect(stereo.blocks == 38 && stereo.thread == pthread_self())
    }

    @Test func aPipelineThatCannotBeCompiledThrowsWhatCompilingThrows() {
        let witness = Witness()
        #expect(throws: DSPError.self) {
            try expectNoAllocationsRunning(Pipeline { Passing(allocates: false, witness: witness) }, blockSize: 0)
        }
        #expect(throws: DSPError.self) {
            try expectNoAllocationsRunning(Pipeline { Passing(allocates: false, witness: witness) }, format: SignalFormat(sampleRate: 0))
        }
        #expect(witness.blocks == 0)
    }
}
