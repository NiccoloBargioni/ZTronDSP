import ExtensionGuide
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

// WP-908, rows 7 to 10 of §5.11.1: a design or a strategy, a window, an inverse with its
// report, an export.

/// Row 7, a design or a strategy: `CriticallyDampedFamily`, a `FilterFamily`.
@Suite("Guide 7: a design or a strategy")
struct DesignExampleTests {
    /// The gain of `pipeline` for a sine at `frequency`, a whole number of hertz, measured over
    /// whole periods once the filter has settled.
    static func gain(of pipeline: Pipeline<Samples, Samples>, at frequency: Double) throws -> Double {
        let signal = TestSignal.sine(frequency: frequency, sampleRate: 48_000, count: 48_000)
        let output = try pipeline.process(signal, format: mono48)
        func rms(_ values: ArraySlice<Float>) -> Double {
            (values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)).squareRoot()
        }
        return rms(output[24_000...]) / rms(signal[24_000...])
    }

    @Test(arguments: [1, 2, 4, 8])
    func theCutoffIsTheHalfPowerPointAtEveryOrder(order: Int) throws {
        // What the family supplies: `order` poles on one real point, a gain of 1 at 0 rad/s and of 1/√2 at 1 rad/s.
        let prototype = try CriticallyDampedFamily().prototype(order: order)
        #expect(prototype.zeros.isEmpty && prototype.poles.count == order && prototype.domain == .analog)
        #expect(prototype.poles.allSatisfy { $0 == prototype.poles[0] && $0.imaginary == 0 && $0.real < 0 })
        expectClose(try prototype.magnitudeResponse(at: [0, 1]), [1, 0.5.squareRoot()], .absolute(1.0e-12))
        // What the package adds: the transformation to the cutoff and the bilinear transform,
        // which pre-warps the edge, so the digital filter has its −3 dB point at the cutoff.
        let lowPass = Pipeline { LowPass(.criticallyDamped, cutoff: .hertz(1_000), order: order) }
        expectClose(try DesignExampleTests.gain(of: lowPass, at: 1_000), 0.5.squareRoot(), .absolute(1.0e-3))
        expectClose(try DesignExampleTests.gain(of: lowPass, at: 20), 1.0, .absolute(1.0e-3))
        // The same prototype through another of the package's transformations.
        let highPass = Pipeline { HighPass(.criticallyDamped, cutoff: .hertz(1_000), order: order) }
        expectClose(try DesignExampleTests.gain(of: highPass, at: 1_000), 0.5.squareRoot(), .absolute(1.0e-3))
        expectClose(try DesignExampleTests.gain(of: highPass, at: 20_000), 1.0, .absolute(1.0e-3))
    }

    @Test func itsStepResponseNeverOvershoots() throws {
        let step = TestSignal.step(count: 4_800)
        let damped = try Pipeline { LowPass(.criticallyDamped, cutoff: .hertz(1_000), order: 4) }.process(step, format: mono48)
        let butterworth = try Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }.process(step, format: mono48)
        let peak = damped.max() ?? 0, stockPeak = butterworth.max() ?? 0
        #expect(peak <= 1.000_01, "the critically damped filter peaks at \(peak)")
        #expect(stockPeak > 1.1, "a Butterworth filter of the same order overshoots by a tenth: \(stockPeak)")
        var falls = 0
        for index in 1 ..< damped.count where damped[index] < damped[index - 1] - 1.0e-6 { falls += 1 }
        #expect(falls == 0, "the response rises and never falls")
        expectClose(damped[4_799], 1.0, .absolute(1.0e-4))
    }

    @Test func theFamilyIsAValueLikeAStockOne() throws {
        let built = Pipeline { LowPass(.criticallyDamped, cutoff: .hertz(1_000), order: 4) }
        #expect(built == Pipeline().lowPass(.criticallyDamped, cutoff: .hertz(1_000), order: 4))
        #expect(built != Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) })
        #expect(built != Pipeline { LowPass(.criticallyDamped, cutoff: .hertz(1_000), order: 2) })
        // In a design of its own: four poles inside the unit circle, on the real axis.
        let design = try IIRDesign(.criticallyDamped, .lowPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate: 48_000))
        let isStable = try design.zeroPoleGain.isStable
        #expect(design.order == 4 && isStable && design.zeroPoleGain.poles.count == 4)
        #expect(design.zeroPoleGain.poles.allSatisfy { abs($0.imaginary) < 1.0e-3 && $0.real > 0 && $0.real < 1 })
        // An order the family does not design is an error that says so.
        for order in [0, -1, 65] {
            let error = #expect(throws: DSPError.self) { try CriticallyDampedFamily().prototype(order: order) }
            guard case .invalidParameter(_, let parameter, _)? = error else {
                Issue.record("order \(order): \(String(describing: error))")
                continue
            }
            #expect(parameter == "order")
        }
    }
}

/// Row 8, a window: `Window.sine`, a custom window.
@Suite("Guide 8: a window")
struct WindowExampleTests {
    let noise = TestSignal.whiteNoise(count: 16_384, seed: 88, amplitude: 0.5)

    @Test func theWindowIsSampledFromItsClosure() throws {
        // Periodic, the default: t = n / N.
        expectClose(try Window.sine.doubleSamples(count: 8), (0 ..< 8).map { sin(.pi * Double($0) / 8) }, .absolute(1.0e-15))
        // The symmetric form closes the window: t runs to 1.
        expectClose(try Window.sine.symmetric.doubleSamples(count: 9), (0 ..< 9).map { sin(.pi * Double($0) / 8) }, .absolute(1.0e-15))
        // WIN-2: two custom windows are equal when their closures agree, so the pipelines that hold them are.
        let same = Window.custom({ t in sin(.pi * t) }), squared = Window.custom({ t in sin(.pi * t) * sin(.pi * t) })
        #expect(Window.sine == same && Window.sine != squared && Window.sine != Window.hann && Window.sine != Window.sine.symmetric)
        #expect(sineWindowRoundTrip(frame: 1_024) == sineWindowRoundTrip(frame: 1_024))
        #expect(sineWindowRoundTrip(frame: 1_024) != sineWindowRoundTrip(frame: 2_048))
        // WIN-3: a window that is zero everywhere, or not finite, is refused when it is sampled.
        let zero = Window.custom({ _ in 0 }), unbounded = Window.custom({ t in 1 / t })
        #expect(throws: DSPError.self) { try zero.samples(count: 64) }
        #expect(throws: DSPError.self) { try unbounded.samples(count: 64) }
    }

    @Test func analysedItIsWhatTheTextbookSays() async throws {
        let analysis = try await Window.sine.analysis(frame: 1_024, hop: 512)
        expectClose(analysis.peak, 1.0, .absolute(1.0e-12))
        expectClose(analysis.coherentGain, 2 / Double.pi, .absolute(1.0e-5))
        expectClose(analysis.noiseGain, 0.5, .absolute(1.0e-12))
        // Squared, the sine window is a Hann window: at half a frame its squares add up to one …
        #expect(analysis.isNonZeroOverlapAdd == true)
        expectClose(analysis.frameBoundRatio ?? 0, 1.0, .absolute(1.0e-9))
        // … and the windows themselves do not: sin + cos runs between 1 and √2.
        #expect(analysis.isConstantOverlapAdd == false)
        expectClose(analysis.overlapRipple ?? 0, 1 - 0.5.squareRoot(), .absolute(1.0e-3))
        // The window is continuous and its slope jumps at the edges: side lobes that fall by
        // 12 dB per octave from a highest one 23 dB down.
        #expect(analysis.smoothness == 1 && analysis.predictedSideLobeFallOff == -12)
        expectClose(analysis.leadingEdgeValue, 0.0, .absolute(1.0e-9))
        expectClose(analysis.trailingEdgeValue, 0.0, .absolute(1.0e-9))
        expectClose(analysis.peakSideLobe ?? 0, -23.0, .absolute(1.0))
        expectClose(analysis.sideLobeFallOff ?? 0, -12.0, .absolute(1.5))
    }

    @Test func analysisAndSynthesisWithItGiveTheSignalBackOneHopLate() async throws {
        let frame = 1_024, hop = 512
        let output = try sineWindowRoundTrip(frame: frame).process(noise, format: mono48)
        // The synthesis delays by frame − hop samples, here one hop, and says so (REAL-5).
        let engine = DSPEngine(blockSize: 512)
        let session = try await engine.attach(sineWindowRoundTrip(frame: frame), to: BufferSource(noise, sampleRate: 48_000))
        #expect(session.environment.latency == Double(hop) / 48_000)
        session.detach()
        try #require(output.count >= noise.count - 2 * frame)
        let compared = frame ..< (output.count - hop - frame)
        let apart = deviation(compared.map { output[$0 + hop] }, from: compared.map { noise[$0] })
        #expect(apart < 1.0e-5, "\(apart) of the peak apart")
        // The report of the analysis says so before anything runs (§6.13).
        let report = try await STFT(frame: frame, hop: hop, window: .sine).inversionReport(for: noise, sampleRate: 48_000)
        #expect(report.isExactlyInvertible && (report.measuredError?.signalToNoiseRatio ?? 0) >= 100, "\(report.conditions)")
        // At a hop of a whole frame nothing overlaps, and the first sample of every frame is
        // lost under the window's zero: the pair is refused (O-17), and the report says why.
        #expect(throws: DSPError.self) {
            try Pipeline { STFT(frame: 1_024, hop: 1_024, window: .sine); InverseSTFT(window: .sine) }.process(noise, format: mono48)
        }
        let lost = try await STFT(frame: 1_024, hop: 1_024, window: .sine).inversionReport(for: noise, sampleRate: 48_000)
        #expect(!lost.isExactlyInvertible)
    }
}

/// Row 9, an inverse with its report: `PreEmphasis`, an `InvertibleStage`.
@Suite("Guide 9: an inverse with its report")
struct InverseExampleTests {
    let noise = TestSignal.whiteNoise(count: 12_800, seed: 97, amplitude: 0.5)

    @Test func theStageAndItsInverseUndoEachOther() throws {
        let emphasized = try Pipeline { PreEmphasis() }.process(noise, format: mono48)
        var previous: Float = 0
        let expected = noise.map { sample -> Float in
            defer { previous = sample }
            return sample - 0.97 * previous
        }
        expectClose(emphasized, expected, .absolute(1.0e-6))
        let back = try Pipeline { PreEmphasis(); PreEmphasis().inverse }.process(noise, format: mono48)
        expectClose(back, noise, .absolute(1.0e-5))
        #expect(PreEmphasis(coefficient: 0.9).inverse == DeEmphasis(coefficient: 0.9))
        #expect(Pipeline { PreEmphasis(); DeEmphasis() } == Pipeline().preEmphasis().deEmphasis())
        #expect(Pipeline { PreEmphasis() } != Pipeline { PreEmphasis(coefficient: 0.9) })
        // An inverse whose pole does not lie inside the unit circle is refused where it would run (REAL-2).
        for coefficient in [1.0, -1.5] {
            let error = #expect(throws: DSPError.self) { try Pipeline { DeEmphasis(coefficient: coefficient) }.process(noise, format: mono48) }
            guard case .unstableDesign(let radius, _)? = error else {
                Issue.record("a de-emphasis of \(coefficient): \(String(describing: error))")
                continue
            }
            #expect(radius == abs(coefficient))
        }
        #expect(throws: DSPError.self) { try Pipeline { PreEmphasis(coefficient: .nan) }.process(noise, format: mono48) }
    }

    @Test func theReportStatesTheConditionAndMeasuresTheRoundTrip() async throws {
        // snippet:begin report-use
        let report = try await PreEmphasis().inversionReport(for: noise, sampleRate: 48_000)
        #expect(report.stage == "PreEmphasis" && report.inverse == "DeEmphasis" && report.isExactlyInvertible)
        try #require(report.conditions.count == 1)
        let condition = report.conditions[0]
        #expect(condition.name == "a stable inverse" && condition.holds && condition.isNecessary && condition.observed == 0.97)
        expectClose(condition.margin, 0.03, .absolute(1.0e-12))
        // The prediction is the round-off of single precision times what the inverse amplifies it by.
        expectClose(report.predictedError, Double(Float.ulpOfOne) / 0.03, .relative(1.0e-9))
        let measured = try #require(report.measuredError)
        #expect(measured.count == noise.count && measured.signalToNoiseRatio > 100, "\(measured)")
        #expect(measured.relativeError <= report.predictedError, "measured \(measured.relativeError), predicted \(report.predictedError)")
        // snippet:end report-use
        #expect(report.roundTrip?.original == noise)
        // Without a signal: the condition, which does not depend on one, and nothing measured.
        let bare = try await PreEmphasis().inversionReport()
        #expect(bare.conditions == report.conditions && bare.measuredError == nil && bare.roundTrip == nil)
        // Where the stage follows something, it is examined on what arrives (§6.13).
        let after = try await PreEmphasis().inversionReport(for: noise, sampleRate: 48_000, after: Pipeline { Gain(.decibels(-6)) })
        let scaled = try Pipeline { Gain(.decibels(-6)) }.process(noise, format: mono48)
        #expect(after.roundTrip?.original == scaled && after.isExactlyInvertible)
        // INV-4: the report exports like a stock one.
        let script = try await report.matlabScript()
        #expect(script.contains("% Inversion report: PreEmphasis and back through DeEmphasis") && script.contains("% a stable inverse: holds, margin"))
    }

    @Test func aFailedConditionIsReportedNotThrown() async throws {
        // INV-3.
        let report = try await PreEmphasis(coefficient: 1.25).inversionReport(for: noise, sampleRate: 48_000)
        try #require(report.conditions.count == 1)
        #expect(!report.isExactlyInvertible && !report.conditions[0].holds && report.conditions[0].margin == -0.25)
        #expect(report.predictedError == 1 && report.measuredError == nil, "there is no stable inverse to measure with")
        let script = try await report.matlabScript()
        #expect(script.contains("% A necessary condition fails.") && script.contains("% a stable inverse: fails"))
    }

    @Test func aChangedCoefficientIsSetInPlace() async throws {
        // EXT-2: the stage lowers to a stock kernel spec, so a session that is handed the same
        // topology with another value sends the value to the kernel that runs: no plan is
        // compiled, and a sink behind the stage misses nothing. (A kernel of the caller's own
        // gets no such update: the finding of the parity suite's LatencyAndUpdateTests.)
        let block = 64, cut = 60 * block
        let signal = Array(noise[..<(200 * block)])
        let run = try await HandFedRun(Pipeline { PreEmphasis(coefficient: 0.5) }, blockSize: block)
        let log = EventLog(run.session)
        try #require(await run.feed(Array(signal[..<cut])))
        try await run.session.update(run.framed(Pipeline { PreEmphasis(coefficient: 0.9) }))
        try #require(await run.feed(Array(signal[cut...]), awaitingOutput: false))
        try #require(await run.finish())
        try #require(await eventually { log.contains(.stateChanged(.finished)) })
        #expect(!log.contains(.replanned(.update)), "no plan was compiled: \(log.all)")
        let heard = run.output.timeline(sampleRate: 48_000, count: signal.count)
        #expect(heard.allSatisfy { $0 != nil }, "the sink behind the stage heard every frame")
        let old = try Pipeline { PreEmphasis(coefficient: 0.5) }.process(signal, format: mono48, blockSize: block)
        let new = try Pipeline { PreEmphasis(coefficient: 0.9) }.process(signal, format: mono48, blockSize: block)
        let output = run.output.samples
        try #require(output.count == signal.count)
        expectClose(Array(output[..<cut]), Array(old[..<cut]), .absolute(1.0e-6))
        expectClose(Array(output[(cut + 4_800)...]), Array(new[(cut + 4_800)...]), .absolute(1.0e-6))
    }
}

/// Row 10, an export: `NoveltyCurve`, a `MATLABExportable`.
@Suite("Guide 10: an export")
struct ExportExampleTests {
    let signal = TestSignal.silence(count: 12_000) + TestSignal.sine(frequency: 1_000, sampleRate: 48_000, count: 12_000, amplitude: 0.5)

    private func curve() throws -> NoveltyCurve {
        let flux: [ScalarFrame] = try Pipeline { STFT(frame: 1_024, hop: 256); Magnitude(); SpectralFlux() }.process(signal, format: mono48)
        return NoveltyCurve(flux, rate: 48_000.0 / 256)
    }

    @Test func theScriptDefinesItsDataAndPlotsIt() async throws {
        // snippet:begin export-use
        let curve = try curve()
        let script = try await curve.matlabScript()
        // snippet:end export-use
        let lines = script.split(separator: "\n").map { String($0) }
        try #require(lines.count == 8 && script.hasSuffix("\n"))
        #expect(lines[0] == "% Novelty curve: \(curve.values.count) values at 187.5 per second")
        #expect(lines[1].hasPrefix("t = [0 0.0053333333333333332 ") && lines[2].hasPrefix("novelty = ["))
        #expect(Array(lines[3...]) == ["plot(t, novelty);", "xlabel('Time (s)');", "ylabel('Novelty');", "title('Novelty curve');", "grid on;"])
        // MAT-3: the numbers read back exactly.
        let written = lines[2].dropFirst("novelty = [".count).dropLast("];".count).split(separator: " ").map { Float(String($0)) }
        #expect(written == curve.values.map { Optional($0) })
        // MAT-4: no date, no machine name: equal curves give equal text.
        let again = try await NoveltyCurve(curve.values.map { ScalarFrame(value: $0) }, rate: curve.rate).matlabScript()
        #expect(again == script)
    }

    @Test func aCurveWithoutARateIsRefusedAndACancelledExportStops() async throws {
        for rate in [0, -1, Double.nan, Double.infinity] {
            let error = await #expect(throws: DSPError.self) { _ = try await NoveltyCurve([], rate: rate).matlabScript() }
            guard case .invalidParameter(_, let parameter, _)? = error else {
                Issue.record("a rate of \(rate): \(String(describing: error))")
                continue
            }
            #expect(parameter == "rate")
        }
        // BG-3: the export runs as background work and sees that the task that awaits it was cancelled.
        let curve = try curve()
        let task = Task { () -> DSPError? in
            while !Task.isCancelled { await Task.yield() }
            do throws(DSPError) {
                _ = try await curve.matlabScript()
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let outcome = await task.value
        guard case .cancelled? = outcome else {
            Issue.record("a cancelled export: \(String(describing: outcome))")
            return
        }
    }
}
