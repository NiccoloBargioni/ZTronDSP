import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting

/// A strategy written outside the stock set whose first median cancels the work it is part
/// of, as a user does in the middle of it. Its own medians do not look at the checkpoint.
struct TrippingMedian: MedianStrategy {
    let log: MedianLog

    func makeFilter(kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable) throws(DSPError) -> any MedianFilter {
        try SelectionNetworkMedian().makeFilter(kernel: kernel, binCount: binCount, along: axis, implementation: implementation, crossovers: crossovers)
    }

    func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable, checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> [Float] {
        log.record(axis, onBackground: BackgroundWork.isCurrent)
        let medians = try SelectionNetworkMedian().filter(values, rowCount: rowCount, kernel: kernel, along: axis, crossovers: crossovers, checkpoint: nil)
        checkpoint?.state.set(true)
        return medians
    }

    static func == (lhs: TrippingMedian, rhs: TrippingMedian) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// A strategy that does not start before the work it is part of was cancelled (or five
/// seconds have passed): what makes the cancellation of a running separation a matter of
/// order, not of speed.
struct WaitingMedian: MedianStrategy {
    func makeFilter(kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable) throws(DSPError) -> any MedianFilter {
        try SelectionNetworkMedian().makeFilter(kernel: kernel, binCount: binCount, along: axis, implementation: implementation, crossovers: crossovers)
    }

    func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable, checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> [Float] {
        var spins = 0
        while checkpoint?.isCancelled == false, spins < 5_000 {
            usleep(1_000)
            spins += 1
        }
        return try SelectionNetworkMedian().filter(values, rowCount: rowCount, kernel: kernel, along: axis, crossovers: crossovers, checkpoint: checkpoint)
    }
}

/// `Implementation` resolved for the offline separation: the `.metal` median with its CPU
/// fall-back (WP-612; GPU-1, GPU-3, GPU-4).
@Suite("Offline separation")
struct OfflineSeparationTests {
    /// A small spectrogram whose windows hold ties: 48 frames of 33 bins.
    private let values = randomFrames(count: 48, bins: 33, seed: 612, ties: true).flatMap { $0 }
    /// Tables that put any spectrogram on the GPU, and none.
    private let always = CrossoverTable(medianGPU: 1), never = CrossoverTable(medianGPU: .max)

    /// Runs `body` and says which side each offline median it started was dispatched to.
    private func dispatched<T>(_ body: () throws -> T) rethrows -> (result: T, sides: [Implementation]) {
        let sides = Locked<[Implementation]>([])
        let result = try MedianOffline.$observer.withValue({ side in sides.withLock { $0.append(side) } }) { try body() }
        return (result, sides.get())
    }

    /// The error an asynchronous call ends with, or `nil` when it returns.
    private func failure(_ body: @Sendable () async throws -> Void) async -> DSPError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? DSPError
        }
    }

    // MARK: `.automatic` follows the table (GPU-1, SEL-5)

    @Test func automaticFollowsTheTable() async throws {
        // The shaders are compiled once, on the background executor, before anything here blocks on them.
        _ = try await MetalContext.shared()
        for axis in [MedianAxis.time, .frequency] {
            let cpu = try SelectionNetworkMedian().filter(values, rowCount: 33, kernel: 9, along: axis)
            let below = try dispatched { try AutomaticMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: never) }
            #expect(below.sides == [.native] && below.result == cpu, "\(axis): below the crossover, the CPU lanes")
            let above = try dispatched { try AutomaticMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: always) }
            #expect(above.sides == [.metal] && above.result.map { $0.bitPattern } == cpu.map { $0.bitPattern }, "\(axis): above it, the GPU, and the same medians")
            // The size is kernel × bins × frames, and the crossover is the first size on the GPU.
            let size = 9 * values.count
            let at = try dispatched { try AutomaticMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: CrossoverTable(medianGPU: size)) }
            let under = try dispatched { try AutomaticMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: CrossoverTable(medianGPU: size + 1)) }
            #expect(at.sides == [.metal] && under.sides == [.native], "\(axis): \(size) is the size of this work")
            // The other two strategies do not ask the table.
            let lanes = try dispatched { try SelectionNetworkMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: always) }
            let gpu = try dispatched { try MetalMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: never) }
            #expect(lanes.sides == [.native] && gpu.sides == [.metal] && gpu.result == cpu)
        }
        // The shipped table: 2²⁴ of kernel × bins × frames.
        #expect(CrossoverTable.shipped.medianGPU == 1 << 24)
        #expect(AutomaticMedian.implementation(kernel: 31, elements: 541_201, crossovers: .shipped) == .metal)
        #expect(AutomaticMedian.implementation(kernel: 31, elements: 541_200, crossovers: .shipped) == .native)
        #expect(AutomaticMedian.implementation(kernel: 255, elements: .max, crossovers: .shipped) == .metal, "a size beyond what an Int holds is the largest there is")
        #expect(AutomaticMedian.implementation(kernel: 255, elements: .max, crossovers: never) == .metal)
        // The whole separation: both medians go where the table says.
        let separation = try dispatched {
            try OfflineSeparation(values, binCount: 33, timeKernel: 9, frequencyKernel: 5, mask: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10,
                                  median: AutomaticMedian(), crossovers: always, checkpoint: nil)
        }
        #expect(separation.sides == [.metal, .metal])
        let onLanes = try dispatched {
            try OfflineSeparation(values, binCount: 33, timeKernel: 9, frequencyKernel: 5, mask: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10,
                                  median: AutomaticMedian(), crossovers: .shipped, checkpoint: nil)
        }
        #expect(onLanes.sides == [.native, .native], "a spectrogram this small stays on the CPU under the shipped table")
        #expect(separation.result.timeMedian == onLanes.result.timeMedian && separation.result.frequencyMedian == onLanes.result.frequencyMedian)
    }

    // MARK: `.metal` without a device is `backendUnavailable`; `.automatic` falls back (GPU-4)

    @Test func metalWithoutADeviceIsBackendUnavailable() async {
        let orphan = MetalMedian(device: .absent), values = values
        for axis in [MedianAxis.time, .frequency] {
            var thrown: DSPError?
            do throws(DSPError) { _ = try orphan.filter(values, rowCount: 33, kernel: 9, along: axis) } catch { thrown = error }
            guard case .backendUnavailable(let reason, _)? = thrown else { Issue.record("\(axis): \(String(describing: thrown))"); continue }
            #expect(reason.contains("no Metal device"))
        }
        // The same through the separation, which does not hide it behind the CPU: `.metal` was asked for.
        let masks = await failure { _ = try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, timeKernel: 9, frequencyKernel: 9, median: orphan) }
        let component = await failure { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, timeKernel: 9, frequencyKernel: 9, median: orphan) }
        for error in [masks, component] {
            guard case .backendUnavailable? = error else { Issue.record("\(String(describing: error))"); continue }
        }
        #expect(MetalMedian() == MetalMedian() && MetalMedian() != orphan && AutomaticMedian() != AutomaticMedian(device: .absent))
    }

    @Test func automaticFallsBackToTheCPUWithoutADevice() async throws {
        let orphan = AutomaticMedian(device: .absent), values = values
        for axis in [MedianAxis.time, .frequency] {
            let cpu = try SelectionNetworkMedian().filter(values, rowCount: 33, kernel: 9, along: axis)
            let run = try dispatched { try orphan.filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: always) }
            #expect(run.sides == [.metal, .native] && run.result == cpu, "\(axis): the GPU was tried, the CPU did the work")
            let small = try dispatched { try orphan.filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: never) }
            #expect(small.sides == [.native], "\(axis): below the crossover the GPU is not asked at all")
        }
        let reference = try await DSP.harmonicPercussive(values, binCount: 33, select: .percussive, timeKernel: 9, frequencyKernel: 9, median: .selectionNetwork)
        let fallen = try await DSP.harmonicPercussive(values, binCount: 33, select: .percussive, timeKernel: 9, frequencyKernel: 9, median: orphan, crossovers: always)
        #expect(fallen == reference, "the separation is the same without a device")
        // What the caller got wrong is not a missing device: it is thrown on either side.
        #expect(errorMessage { _ = try orphan.filter(values, rowCount: 33, kernel: 8, along: .time, crossovers: always) }?.contains("Invalid parameter") == true)
        #expect(errorMessage { _ = try AutomaticMedian().filter(values, rowCount: 33, kernel: 8, along: .time, crossovers: always) }?.contains("Invalid parameter") == true)
        #expect(errorMessage { _ = try AutomaticMedian().filter(values, rowCount: 32, kernel: 9, along: .time, crossovers: always) }?.contains("Invalid parameter values") == true)
    }

    // MARK: Results ≡ CPU (GPU-3)

    @Test(arguments: [1, 3, 17, 31])
    func theGPUMedianEqualsTheCPULanesAndTheOracle(kernel: Int) async throws {
        _ = try await MetalContext.shared()
        var compared = 0
        for ties in [false, true] {
            let values = randomFrames(count: 70, bins: 65, seed: UInt64(6_120 + kernel), ties: ties).flatMap { $0 }
            for axis in [MedianAxis.time, .frequency] {
                let gpu = try MetalMedian().filter(values, rowCount: 65, kernel: kernel, along: axis)
                let cpu = try SelectionNetworkMedian().filter(values, rowCount: 65, kernel: kernel, along: axis)
                let oracle = MedianOracle.filter(values, rowCount: 65, kernel: kernel, along: axis == .time ? .time : .frequency)
                #expect(gpu.map { $0.bitPattern } == cpu.map { $0.bitPattern }, "kernel \(kernel), \(axis)\(ties ? ", with ties" : ""): the GPU and the CPU lanes, bit for bit")
                #expect(cpu == oracle, "kernel \(kernel), \(axis)\(ties ? ", with ties" : ""): and both the median a sort gives")
                compared += values.count
            }
        }
        print("measured WP-612: kernel \(kernel): \(compared) medians of the GPU equal those of the CPU lanes bit for bit, and the sort-based oracle")
    }

    @Test func theSeparationIsTheSameOnEitherSide() async throws {
        let spectrogram = try separationSpectrogram(of: "music", hop: 512).frames
        let magnitudes = spectrogram.flatMap { $0 }, bins = spectrogram[0].count
        var components: [[Float]] = []
        for component in HarmonicPercussiveComponent.allCases {
            let cpu = try await DSP.harmonicPercussive(
                magnitudes, binCount: bins, select: component, timeKernel: 17, frequencyKernel: 17, harmonicMargin: 2, percussiveMargin: 2, median: .selectionNetwork)
            let gpu = try await DSP.harmonicPercussive(
                magnitudes, binCount: bins, select: component, timeKernel: 17, frequencyKernel: 17, harmonicMargin: 2, percussiveMargin: 2, median: .metal)
            let chosen = try await DSP.harmonicPercussive(
                magnitudes, binCount: bins, select: component, timeKernel: 17, frequencyKernel: 17, harmonicMargin: 2, percussiveMargin: 2, crossovers: always)
            let byDefault = try await DSP.harmonicPercussive(magnitudes, binCount: bins, select: component, timeKernel: 17, frequencyKernel: 17, harmonicMargin: 2, percussiveMargin: 2)
            #expect(gpu == cpu && chosen == cpu && byDefault == cpu, "\(component): the same values whichever side computed the medians")
            components.append(cpu)
        }
        // The three components are the magnitudes again.
        var worst = 0.0
        for frame in spectrogram.indices {
            let peak = Double(spectrogram[frame].max() ?? 0) + 1e-12
            for bin in 0 ..< bins {
                let index = frame * bins + bin
                worst = max(worst, abs(Double(components[0][index]) + Double(components[1][index]) + Double(components[2][index]) - Double(magnitudes[index])) / peak)
            }
        }
        #expect(worst <= 1e-6, "off by \(worst) of the frame maximum")
        // The masks: shares, the same on either side, and what the components are made with.
        let cpu = try await DSP.harmonicPercussiveMasks(of: magnitudes, binCount: bins, timeKernel: 17, frequencyKernel: 17, mask: .hard, median: .selectionNetwork)
        let gpu = try await DSP.harmonicPercussiveMasks(of: magnitudes, binCount: bins, timeKernel: 17, frequencyKernel: 17, mask: .hard, median: .metal)
        #expect(gpu.harmonic == cpu.harmonic && gpu.percussive == cpu.percussive)
        #expect(cpu.harmonic.count == magnitudes.count && cpu.harmonic.allSatisfy { $0 == 0 || $0 == 1 } && zip(cpu.harmonic, cpu.percussive).allSatisfy { $0 + $1 <= 1 })
        let hard = try await DSP.harmonicPercussive(magnitudes, binCount: bins, select: .harmonic, timeKernel: 17, frequencyKernel: 17, mask: .hard, median: .metal)
        #expect(hard == zip(magnitudes, cpu.harmonic).map { $0 * $1 })
        print("measured WP-612: music, kernels 17 and 17: \(magnitudes.count) values of each component equal on the GPU and on the CPU lanes; the components add up within \(worst) of the frame maximum")
    }

    @Test func theOfflineSeparationOnTheGPUEqualsTheCentredStream() async throws {
        let (spectrogram, format) = try separationSpectrogram(of: "speech", hop: 256)
        let samples = try GoldenFile(named: "fixtures", in: .module).require("speech").floats("samples")
        let bins = spectrogram[0].count
        let offline = try await DSP.harmonicPercussive(spectrogram.flatMap { $0 }, binCount: bins, select: .percussive, timeKernel: 17, frequencyKernel: 17, median: .metal)
        let stream: [[Float]] = try Pipeline {
            STFT(frame: 1_024, hop: 256, alignment: .centered); Magnitude()
            HarmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 17, alignment: .centered)
        }.process(samples, format: format)
        #expect(stream.count == spectrogram.count - 8 && offline.count == spectrogram.count * bins)
        #expect(stream.flatMap { $0 } == Array(offline[..<(stream.count * bins)]), "frame by frame what the stream gives, with the last frames it is still waiting for")
    }

    // MARK: Background work, cancellable (BG-1, BG-3)

    @Test @MainActor func theSeparationRunsInTheBackground() async throws {
        let log = MedianLog(), values = values
        let masks = try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, timeKernel: 9, frequencyKernel: 5, median: CountingMedian(log: log))
        #expect(log.axes == [.time, .frequency] && log.allOnBackground, "called on the main actor, the medians are taken on the background executor")
        // A strategy that supplies its filters only gets the whole spectrogram filtered by them.
        let reference = try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, timeKernel: 9, frequencyKernel: 5, median: .selectionNetwork)
        #expect(masks.harmonic == reference.harmonic && masks.percussive == reference.percussive)
        let own = try CountingMedian(log: log).filter(values, rowCount: 33, kernel: 9, along: .time)
        #expect(own == MedianOracle.filter(values, rowCount: 33, kernel: 9, along: .time))
    }

    @Test func aSeparationCanBeCancelled() async throws {
        let values = values
        // A separation that is running: its median does not begin before the cancellation.
        let running = Task { try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, timeKernel: 9, frequencyKernel: 9, median: WaitingMedian()) }
        running.cancel()
        let result = await running.result
        #expect(throws: DSPError.cancelled) { _ = try result.get() }
        let masks = Task { try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, timeKernel: 9, frequencyKernel: 9, median: WaitingMedian()) }
        masks.cancel()
        let other = await masks.result
        #expect(throws: DSPError.cancelled) { _ = try other.get() }

        // Every part looks at the checkpoint: the medians of each side, and the masks.
        let cancelled = BackgroundWork.Checkpoint(state: Locked(true)), live = BackgroundWork.Checkpoint(state: Locked(false))
        _ = try await MetalContext.shared()
        for axis in [MedianAxis.time, .frequency] {
            #expect(throws: DSPError.cancelled) { _ = try SelectionNetworkMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: .shipped, checkpoint: cancelled) }
            #expect(throws: DSPError.cancelled) { _ = try MetalMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: .shipped, checkpoint: cancelled) }
            // A cancellation is not a missing device: the fall-back does not swallow it.
            let chosen = dispatched { errorMessage { _ = try AutomaticMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: always, checkpoint: cancelled) } }
            #expect(chosen.sides == [.metal] && chosen.result?.lowercased().contains("cancel") == true, "\(chosen)")
            #expect(try SelectionNetworkMedian().filter(values, rowCount: 33, kernel: 9, along: axis, crossovers: .shipped, checkpoint: live).count == values.count)
        }
        let separation = try OfflineSeparation(
            values, binCount: 33, timeKernel: 9, frequencyKernel: 9, mask: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10, median: SelectionNetworkMedian(),
            crossovers: .shipped, checkpoint: live)
        #expect(throws: DSPError.cancelled) { _ = try separation.masked(.harmonic, applied: true, checkpoint: cancelled) }
        #expect(try separation.masked(.harmonic, applied: true, checkpoint: live).count == values.count)

        // Cancelled between the two medians, the second is never begun.
        let log = MedianLog()
        #expect(throws: DSPError.cancelled) {
            _ = try OfflineSeparation(
                values, binCount: 33, timeKernel: 9, frequencyKernel: 9, mask: SoftMask(), harmonicMargin: 1, percussiveMargin: 1, floor: 1e-10, median: TrippingMedian(log: log),
                crossovers: .shipped, checkpoint: BackgroundWork.Checkpoint(state: Locked(false)))
        }
        #expect(log.axes == [.time])
    }

    // MARK: What is no separation is refused

    @Test func whatMakesNoSeparationIsRefused() async throws {
        let values = values
        func refusal(_ body: @Sendable () async throws -> Void) async -> String { await failure(body).map { "\($0)" } ?? "no error" }
        let ragged = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 32, select: .harmonic) }
        #expect(ragged.contains("Invalid parameter magnitudes") && ragged.contains("do not fill frames of 32 bins"), "\(ragged)")
        let binless = await refusal { _ = try await DSP.harmonicPercussiveMasks(of: values, binCount: 0) }
        #expect(binless.contains("Invalid parameter magnitudes"), "\(binless)")
        let even = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, timeKernel: 30) }
        #expect(even.contains("Invalid parameter timeKernel"), "\(even)")
        let none = await refusal { _ = try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, frequencyKernel: 0) }
        #expect(none.contains("Invalid parameter frequencyKernel"), "\(none)")
        let narrow = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .residual, harmonicMargin: 0.5) }
        #expect(narrow.contains("Invalid parameter harmonicMargin"), "\(narrow)")
        let wide = await refusal { _ = try await DSP.harmonicPercussiveMasks(of: values, binCount: 33, percussiveMargin: .nan) }
        #expect(wide.contains("Invalid parameter percussiveMargin"), "\(wide)")
        let sunk = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, floor: -1) }
        #expect(sunk.contains("Invalid parameter floor"), "\(sunk)")
        let flat = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, mask: .soft(power: 0)) }
        #expect(flat.contains("Invalid parameter mask"), "\(flat)")
        // Refused before any median is taken, on either side.
        let onGPU = await refusal { _ = try await DSP.harmonicPercussive(values, binCount: 33, select: .harmonic, timeKernel: 30, median: .metal) }
        #expect(onGPU.contains("Invalid parameter timeKernel"), "\(onGPU)")

        // No frames at all are nothing to separate, and no error.
        let empty = try await DSP.harmonicPercussive([], binCount: 33, select: .harmonic, median: .selectionNetwork)
        let emptyMasks = try await DSP.harmonicPercussiveMasks(of: [], binCount: 33, median: .selectionNetwork)
        #expect(empty.isEmpty && emptyMasks.harmonic.isEmpty && emptyMasks.percussive.isEmpty)
        #expect(try SelectionNetworkMedian().filter([], rowCount: 4, kernel: 3, along: .time).isEmpty)
        #expect(errorMessage { _ = try SelectionNetworkMedian().filter([], rowCount: 4, kernel: 4, along: .time) }?.contains("Invalid parameter") == true, "a kernel that is none is refused even so")
        #expect(errorMessage { _ = try SelectionNetworkMedian().filter([1, 2, 3], rowCount: 2, kernel: 3, along: .frequency) }?.contains("do not fill frames of 2") == true)
        // One frame is its own reflection along time.
        #expect(try SelectionNetworkMedian().filter([3, 1, 2], rowCount: 3, kernel: 5, along: .time) == [3, 1, 2])
        // The GPU median makes no filter for a live frame (GPU-1).
        let live = errorMessage { _ = try MetalMedian().makeFilter(kernel: 3, binCount: 4, along: .time, implementation: .automatic, crossovers: .shipped) }
        #expect(live?.contains("the GPU median filters whole spectrograms offline") == true)
        // `.automatic` is the CPU lanes for one.
        let filter = try AutomaticMedian().makeFilter(kernel: 3, binCount: 4, along: .frequency, implementation: .automatic, crossovers: always)
        #expect(filter is FrequencyLaneMedian)
        #expect(MedianOffline.reflected(-1, count: 4) == 0 && MedianOffline.reflected(4, count: 4) == 3 && MedianOffline.reflected(9, count: 4) == 1 && MedianOffline.reflected(-5, count: 4) == 3)
    }
}
