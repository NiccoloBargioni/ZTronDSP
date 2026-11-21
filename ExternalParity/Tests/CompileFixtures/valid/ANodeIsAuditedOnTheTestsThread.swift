// EXT-3: the author of a node holds it to RT-2 in a test of his own. A node writes through a
// FrameWriter, which only a plan makes, so a node runs inside a plan: `expectNoAllocationsRunning`
// of ZTronDSPTesting compiles the pipeline and runs that plan block by block on the test's own
// thread, inside the audit. (This fixture replaced the finding that a node could be audited
// only on an engine's thread.)
import ExternalStages
import Testing
import ZTronDSP
import ZTronDSPTesting

typealias Mel = Spectrum<MelFrequency, PowerValues>

/// The mel node of the suite, 1 000 blocks on the calling thread: what the heap was asked for.
func theMelNodeOnTheTestsThread() throws(DSPError) -> AllocationCounts {
    try expectNoAllocationsRunning(
        Pipeline { STFT(frame: 2_048, hop: 512); Power(); ExternalMelScale(bands: 40); Emit(to: FeatureCallback<Mel> { _ in }) },
        blockSize: 512, blocks: 1_000, "ExternalMelScale on the test's thread")
}
