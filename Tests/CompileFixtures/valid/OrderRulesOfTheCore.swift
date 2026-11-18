// The order rules of the core, as far as they accept (§5.8): sequence stages on sampled sequences,
// self-typed stages where their input domain is, sinks after what they can hold, taps from the
// domain they tap, and control flow around stages that keep the domain (ORD-3).
import SwiftUI
import ZTronDSPCore

// Stages every order-rule fixture of the core brings along: the core holds no processing stage
// (EXT-1), so a fixture writes its own against the public API, as a client would.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

struct Frames: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

struct Bins: PipelineStage {
    typealias Input = Spectrum<LinearFrequency, ComplexValues>
    typealias Output = Spectrum<LinearFrequency, MagnitudeValues>
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

struct Loudness: PipelineStage {
    typealias Input = Samples
    typealias Output = Scalar
    func lower(_ context: inout LoweringContext) throws(DSPError) {}
}

@MainActor func accepted(flag: Bool, level: Binding<Float>, frame: Binding<ScalarFrame>, vector: Binding<[Float]>, shown: Binding<Bool>,
                         heat: HeatmapFeed, stream: FeatureStream<Samples>, callback: FeatureCallback<Scalar>) {
    // O-1, O-13: sequence stages on samples, with `if`, `for` and `if #available` around them.
    let sequence: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        if flag { Halve() }
        for _ in 0 ..< 2 { Halve() }
        if #available(iOS 16, *) { Halve() }
        Emit(to: stream)
    }
    // O-11, O-15: branches start where they tap; each sink follows a domain it can hold.
    let analysis: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        Tap {
            Frames()
            Bins()
            Emit(to: heat)
            Emit(to: vector)
        }
        Tap(isActive: shown) {
            Loudness()
            Halve()                         // a sequence stage on a scalar track
            Emit(to: level)
            Emit(to: frame)
            Emit(to: callback)
        }
        Halve().active(shown)
    }
    // O-14: both branches of `if … else` end in the same domain.
    let either: Pipeline<Samples, Samples> = Pipeline {
        if flag { Halve() } else { Group { Halve(); Halve() } }
    }
    // The fluent spelling gives the same descriptions (API-1).
    let fluent = Pipeline().appending(Halve()).tap { $0.appending(Frames()).appending(Bins()).emit(to: heat).emit(to: vector) }
    // A main line may end in any domain; only its start is fixed (O-12).
    let spectral: Pipeline<Samples, Spectrum<LinearFrequency, MagnitudeValues>> = Pipeline { Frames(); Bins(); Emit(to: heat) }
    _ = (sequence, analysis, either, fluent, spectral)
}

func attached(engine: DSPEngine, source: any SampleSource) async throws {
    let session = try await engine.attach(Pipeline { Frames(); Bins() }, to: source.processed(by: Pipeline { Halve() }))
    try await session.update(try DynamicPipeline().appending(Halve()))
}
