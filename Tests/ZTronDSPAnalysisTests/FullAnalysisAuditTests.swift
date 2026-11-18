import Foundation
import SwiftUI
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPTesting

// The real-time audit of the stock full-analysis pipeline (WP-541; RT-7, layer 3; the exit
// criterion of M5). Everything here is written against the public API, as an app writes it:
// this file imports no module `@testable`.

/// Sits at the head of the main line and sees every block on the thread that runs the plan:
/// after `warmUp` blocks it opens the allocation audit of that thread, `audited` blocks later
/// it closes it. What lies between is everything the thread does for those blocks: the source,
/// the plan with all its branches, and the engine's own turn around them.
final class AuditProbe: @unchecked Sendable {
    // Threading: `take` belongs to the thread that runs the plan. The audit's results are
    // atomic words; the other counters are read by the test once the audit is closed.
    let audit = ThreadAllocationAudit()
    let warmUp: Int
    let audited: Int
    private(set) var blocks = 0
    /// Frames that went through the plan while the audit was open.
    private(set) var frames = 0
    /// The clock when the audit was opened and when it was closed, in nanoseconds.
    private(set) var opened: UInt64 = 0
    private(set) var closed: UInt64 = 0
    /// The processor time the audited thread had used at those two moments, in nanoseconds:
    /// what the blocks cost, however busy the machine is with other work.
    private(set) var openedProcessor: UInt64 = 0
    private(set) var closedProcessor: UInt64 = 0

    init(warmUp: Int, audited: Int) {
        self.warmUp = warmUp
        self.audited = audited
    }

    /// One block of the main line. No allocation, no lock (RT-2).
    func take(_ frame: FrameView) {
        if blocks == warmUp + audited {
            audit.end()
            closed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            closedProcessor = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        }
        if blocks == warmUp {
            opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            openedProcessor = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            audit.begin()
        }
        if blocks >= warmUp, blocks < warmUp + audited, let block = frame.samples { frames &+= block.frameCount }
        blocks &+= 1
    }

    /// Seconds of processor time the audited blocks cost their thread, seconds that passed
    /// meanwhile, and seconds of signal the blocks hold.
    func seconds(sampleRate: Double) -> (processing: Double, elapsed: Double, audio: Double) {
        (Double(closedProcessor &- openedProcessor) / 1e9, Double(closed &- opened) / 1e9, Double(frames) / sampleRate)
    }
}

/// What the stock full analysis leaves for an app: three heat maps and a value.
struct FullAnalysisOutputs: Sendable {
    let spectrogram = HeatmapFeed(history: 256)
    let chroma = HeatmapFeed(history: 256)
    let tempogram = HeatmapFeed(history: 256)
    let centroid = StateBox(Float(0))
}

@Suite("Full-analysis audit", .serialized)
struct FullAnalysisAuditTests {
    static let sampleRate = 48_000.0
    static let blockSize = 512

    /// The stock full-analysis pipeline of §10.4, mono at 48 kHz: a spectrogram of 2 048 / 512,
    /// the spectral centroid, chroma from a constant-Q transform over 6 octaves, the
    /// harmonic–percussive separation with kernels of 17 and 17, and the autocorrelation
    /// tempogram. Recipes and taps, as an app declares them: the three branches that start from
    /// the spectrum are written with the framing of the `Spectrogram` recipe, so the plan
    /// transforms each frame once for all of them (F5). `probe` stands where an app would have
    /// nothing.
    static func fullAnalysis(into outputs: FullAnalysisOutputs, probe: AuditProbe) -> Pipeline<Samples, Samples> {
        Pipeline {
            Emit(to: FeatureCallback<Samples> { probe.take($0) })
            Spectrogram(frame: 2_048, hop: 512, to: outputs.spectrogram)
            Tap {
                STFT(frame: 2_048, hop: 512, normalization: .amplitude)
                Power()
                SpectralCentroid(to: outputs.centroid.binding)
            }
            ChromaCQT(octaves: 6, to: outputs.chroma)
            Tap {
                STFT(frame: 2_048, hop: 512, normalization: .amplitude); Power(); MelScale(bands: 128); Decibels()
                OnsetStrength()
                Tempogram(.autocorrelation)
                Emit(to: outputs.tempogram)
            }
            HPSS(select: .harmonic, timeKernel: 17, frequencyKernel: 17)
        }
    }

    /// A signal that gives every analysis something to do: two partials a fifth apart, a click
    /// twice a second (120 beats per minute) and a floor of noise. A pure function of the frame.
    static let signal = GeneratorSource.Signal.function { frame, time in
        let tones = 0.25 * sin(2 * Double.pi * 440 * time) + 0.15 * sin(2 * Double.pi * 659.255 * time)
        let click = frame % 24_000 < 48 ? 0.5 * (1 - Double(frame % 24_000) / 48) : 0
        // A linear congruential step of the frame number: the same noise on every run.
        let state = UInt32(truncatingIfNeeded: frame) &* 1_664_525 &+ 1_013_904_223
        let noise = (Double(state >> 8) / Double(1 << 24) - 0.5) * 0.02
        return Float(tones + click + noise)
    }

    /// Attaches the pipeline to a generator, runs it until the probe has closed its audit, and
    /// returns what the audited thread asked of the heap.
    private func audit(warmUp: Int, audited: Int, pacing: Pacing) async throws -> (counts: AllocationCounts?, probe: AuditProbe, outputs: FullAnalysisOutputs, events: [SessionEvent]) {
        let probe = AuditProbe(warmUp: warmUp, audited: audited)
        let outputs = FullAnalysisOutputs()
        let engine = DSPEngine(blockSize: Self.blockSize)
        // Enough signal for the warm-up, the audited blocks and the block that closes the audit.
        let duration = Double((warmUp + audited + 64) * Self.blockSize) / Self.sampleRate
        let source = GeneratorSource(Self.signal, sampleRate: Self.sampleRate, channelCount: 1, duration: duration, pacing: pacing)
        let session = try await engine.attach(Self.fullAnalysis(into: outputs, probe: probe), to: source)
        let listener = Task { () -> [SessionEvent] in
            var seen: [SessionEvent] = []
            for await event in session.events { seen.append(event) }
            return seen
        }
        try session.start()
        // The stream is run to its end, so that what the feeds hold afterwards is the same on
        // every run. How long that takes is the machine's business: the limit below is there for
        // a session that never ends, and is hours of processing away from one that does.
        var waited = 0
        while session.state == .running, waited < 90_000 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        #expect(session.state == .finished, "the stream ran to its end: the session is \(session.state) after \(waited) looks")
        let counts = probe.audit.counts
        session.detach()
        return (counts, probe, outputs, await listener.value)
    }

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func tenThousandBlocksOfTheStockFullAnalysisAllocateNothing() async throws {
        // 640 blocks first: the tempogram's window of 384 frames is full, the medians of the
        // separation, the atoms of the constant-Q transform and every feed's ring have wrapped.
        let run = try await audit(warmUp: 640, audited: 10_000, pacing: .asFastAsPossible)
        #expect(!run.probe.audit.failedToOpen, "the audit could be opened on the thread that runs the plan")
        let counts = try #require(run.counts, "the audit was closed after \(run.probe.blocks) blocks")
        #expect(counts.allocations == 0 && counts.deallocations == 0, "the stock full analysis, 10 000 blocks of 512 frames at 48 kHz: \(counts)")
        #expect(run.probe.frames == 10_000 * Self.blockSize, "\(run.probe.frames) frames were audited")

        // The analyses did run: every feed is full of columns of the right shape.
        #expect(run.outputs.spectrogram.columnCount == 256 && run.outputs.spectrogram.rowCount == 1_025)
        #expect(run.outputs.chroma.columnCount == 256 && run.outputs.chroma.rowCount == 12)
        #expect(run.outputs.tempogram.columnCount == 256 && run.outputs.tempogram.rowCount > 100)
        guard case .tempo(let tempi)? = run.outputs.tempogram.axis else {
            Issue.record("the tempogram's axis is \(String(describing: run.outputs.tempogram.axis))")
            return
        }
        // The clicks are 120 beats per minute: the newest column says so.
        let snapshot = run.outputs.tempogram.snapshot()
        let column = Array(snapshot.column(snapshot.columnCount - 1))
        let strongest = try #require(column.indices.max { column[$0] < column[$1] })
        #expect(abs(tempi[strongest] - 120) < 2, "the strongest row of the tempogram is \(tempi[strongest]) beats per minute")
        #expect(!run.events.contains { if case .overrun = $0 { true } else { false } }, "a pull source drops nothing: \(run.events)")

        // The figure of §10.4, measured: the processor time of the thread that ran the blocks,
        // the source included, over the duration of the signal. No budget is held here: this
        // machine is no reference device, and other work may run on it at the same time.
        let seconds = run.probe.seconds(sampleRate: Self.sampleRate)
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        print("measured WP-541: stock full analysis, \(configuration), simulator: 10 000 blocks of 512 frames (\(seconds.audio) s of signal) took their thread \(seconds.processing) s of processor time, source included: processing time ÷ audio time \(seconds.processing / seconds.audio) (\(seconds.elapsed) s passed meanwhile); \(counts)")
        // For the benchmark harness (PERF-1), where a run asks for it: the cost of one block.
        // A block of 512 frames at 48 kHz lasts 10 666 667 ns.
        let perBlock = seconds.processing * 1e9 / 10_000
        Benchmark.record([BenchmarkResult(
            name: "stock full analysis (§10.4), source included, one block of 512 frames at 48 kHz", iterations: 10_000, samples: 1,
            minimum: perBlock, median: perBlock, mean: perBlock)])
    }

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func pacedAsAMicrophoneTheAnalysisThreadAllocatesNothing() async throws {
        // The same pipeline on the engine's analysis thread, one block per block duration, as a
        // live source is asked: 448 blocks to fill every history, then 300 under audit (8 s in all).
        let run = try await audit(warmUp: 448, audited: 300, pacing: .realTime)
        #expect(!run.probe.audit.failedToOpen, "the audit could be opened on the analysis thread")
        let counts = try #require(run.counts, "the audit was closed after \(run.probe.blocks) blocks")
        #expect(counts.allocations == 0 && counts.deallocations == 0, "the stock full analysis on the analysis thread, 300 blocks: \(counts)")
        #expect(run.outputs.tempogram.columnCount > 0 && run.outputs.chroma.columnCount > 0 && run.outputs.spectrogram.columnCount > 0)
    }
}
