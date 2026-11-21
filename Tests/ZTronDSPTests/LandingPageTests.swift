import Testing
import ZTronDSP

// The code of the landing page, Sources/ZTronDSP/ZTronDSP.docc/ZTronDSP.md, is the regions marked
// below, as they are: `Scripts/docs.sh --audit` holds each Swift block of the page equal to its
// region (check [example]), so the page cannot show code that does not build and run (WP-901b).
// Like the rest of this target, the file imports the facade and nothing else.

/// The landing page's example, describe → compile → run (§5.5): the two spellings describe one
/// pipeline (API-1), and that pipeline compiles into a plan and runs on a generator.
@Suite("Landing page")
struct LandingPageTests {
    @Test func theExampleIsOnePipelineInBothSpellingsThatCompilesAndRuns() async throws {
        // snippet:begin builder
        let spectrogram = HeatmapFeed()

        let pipeline = Pipeline {
            HighPass(.butterworth, cutoff: .hertz(90), order: 4)
            STFT(frame: 1_024, hop: 256)
            Magnitude()
            Decibels()
            Emit(to: spectrogram)
        }
        // snippet:end builder

        // snippet:begin fluent
        let same = Pipeline()
            .highPass(.butterworth, cutoff: .hertz(90), order: 4)
            .stft(frame: 1_024, hop: 256)
            .magnitude()
            .decibels()
            .emit(to: spectrogram)
        // snippet:end fluent
        #expect(same == pipeline, "the builder and the fluent spelling make one description (API-1)")

        // snippet:begin run
        let engine = DSPEngine()
        let source = GeneratorSource(.sine(frequency: .hertz(440)), duration: 0.25)
        let session = try await engine.attach(pipeline, to: source)    // compiles the plan
        try session.start()                                           // runs it
        // snippet:end run

        // The source ends after a quarter of a second. The listener exists before the state is
        // read, so the end is seen whether it comes before that read or after it.
        let events = session.events
        if session.state != .finished {
            for await event in events {
                if case .stateChanged(let state) = event, state != .idle, state != .running { break }
            }
        }
        #expect(session.state == .finished, "the session ran its source to the end: it is \(session.state)")
        #expect(spectrogram.rowCount == 513, "a frame of 1 024 samples has 513 bins: the feed has \(spectrogram.rowCount) rows")
        #expect(spectrogram.columnCount > 0, "the feed received the frames of the run")
        session.detach()
    }
}
