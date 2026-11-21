import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

private enum GateThresholdKey: SettableDSPEnvironmentKey {
    static var defaultValue: Double { -60 }
}

private enum ReadOnlyHintKey: DSPEnvironmentKey {
    static var defaultValue: String { "none" }
}

extension DSPEnvironment.SettableKeys {
    fileprivate var gateThreshold: GateThresholdKey.Type { GateThresholdKey.self }
}

@Suite("DSPEnvironment (WP-108)")
struct DSPEnvironmentTests {
    @Test func derivedKeysFollowTheSampleRate() {
        for rate in [8_000.0, 44_100, 48_000, 96_000] {
            let environment = DSPEnvironment(sampleRate: rate)
            #expect(environment.sampleRate == rate)
            #expect(environment.nyquistFrequency == rate / 2)
            #expect(environment[SampleRateKey.self] == rate)
            #expect(environment[NyquistFrequencyKey.self] == rate / 2)
            let framed = environment.enteringSpectralScope(frameSize: 2_048, hopSize: 512, axis: .linearFrequency(binCount: 1_025, nyquist: rate / 2))
            #expect(framed.frequencyResolution == rate / 2_048)
            #expect(framed.featureRate == rate / 512)
            #expect(framed[FrequencyResolutionKey.self] == rate / 2_048)
            #expect(framed[FeatureRateKey.self] == rate / 512)
        }
    }

    @Test func defaultsAreTheReferenceEnvironment() {
        let environment = DSPEnvironment()
        #expect(environment == .reference)
        #expect(environment.sampleRate == 48_000 && environment.channelCount == 1 && environment.blockSize == 512)
        #expect(environment.frameSize == nil && environment.hopSize == nil && environment.frequencyAxis == nil)
        #expect(environment.frequencyResolution == nil && environment.featureRate == nil)
        #expect(environment.latency == 0 && !environment.isRealTime && environment.sourceKind == .offline)
        #expect(environment.implementation == .automatic && environment.biquadPrecision == .automatic && environment.resultRate == 30)
        #expect(!environment.isInSpectralScope)
        #expect(environment.format == SignalFormat(sampleRate: 48_000, channelCount: 1))
        #expect(environment[ChannelCountKey.self] == 1 && environment[BlockSizeKey.self] == 512)
        #expect(environment[FrameSizeKey.self] == nil && environment[HopSizeKey.self] == nil && environment[FrequencyAxisKey.self] == nil)
        #expect(environment[LatencyKey.self] == 0 && environment[IsRealTimeKey.self] == false && environment[SourceKindKey.self] == .offline)
        let stereo = DSPEnvironment(sampleRate: 44_100, channelCount: 2, blockSize: 256, isRealTime: true)
        #expect(stereo.channelCount == 2 && stereo.blockSize == 256 && stereo.isRealTime)
    }

    @Test func settableKeysAreOverriddenByValue() {
        let base = DSPEnvironment()
        let forced = base.setting(ImplementationKey.self, to: .native)
        #expect(forced.implementation == .native)
        #expect(base.implementation == .automatic, "the original is unchanged: an environment is a value (IMM-5)")
        #expect(forced != base)
        #expect(forced.setting(ImplementationKey.self, to: .automatic).implementation == .automatic)
        #expect(base.setting(BiquadPrecisionKey.self, to: .double).biquadPrecision == .double)
        #expect(base.setting(ResultRateKey.self, to: 60).resultRate == 60)
        #expect(base.setting(\.implementation, to: .accelerate).implementation == .accelerate, "the key-path spelling")
        #expect(base.setting(\.biquadPrecision, to: .single).biquadPrecision == .single)
        #expect(base.setting(\.resultRate, to: 15).resultRate == 15)
        #expect(base.setting(\.resultRate, to: 15) == base.setting(ResultRateKey.self, to: 15))
        #expect(Set([base, forced, base.setting(ImplementationKey.self, to: .native)]).count == 2)
    }

    @Test func customKeysHaveDefaultsAndOverrides() {
        let base = DSPEnvironment()
        #expect(base[GateThresholdKey.self] == -60, "a key that was never set reads its default")
        #expect(base[ReadOnlyHintKey.self] == "none")
        let set = base.setting(GateThresholdKey.self, to: -40)
        #expect(set[GateThresholdKey.self] == -40)
        #expect(base[GateThresholdKey.self] == -60)
        #expect(base.setting(\.gateThreshold, to: -20)[GateThresholdKey.self] == -20)
        #expect(set.setting(ImplementationKey.self, to: .native)[GateThresholdKey.self] == -40, "overrides accumulate")
    }

    @Test func overridesOfAScopeAreLaidOverTheEnvironmentThatReachesIt() {
        let outer = DSPEnvironment().setting(ResultRateKey.self, to: 10)
        let scope = DSPEnvironment().setting(ImplementationKey.self, to: .native).setting(ResultRateKey.self, to: 60)
        let inner = outer.applyingOverrides(of: [
            ObjectIdentifier(ImplementationKey.self): AnyStrategy(Implementation.native),
            ObjectIdentifier(ResultRateKey.self): AnyStrategy(60.0),
        ])
        #expect(inner.implementation == scope.implementation && inner.resultRate == 60)
        #expect(outer.applyingOverrides(of: [:]) == outer)
    }
}

@Suite("Positional environment (WP-109)")
struct PositionalEnvironmentTests {
    @Test func aDecimatorHalvesNyquistDownstreamOnly() {
        let upstream = DSPEnvironment(sampleRate: 48_000)
        let downstream = upstream.changingRate(interpolation: 1, decimation: 2)
        #expect(downstream.sampleRate == 24_000 && downstream.nyquistFrequency == 12_000)
        #expect(upstream.sampleRate == 48_000 && upstream.nyquistFrequency == 24_000, "upstream is untouched")
        #expect(downstream.changingRate(interpolation: 2, decimation: 1) == upstream)
        #expect(upstream.changingRate(interpolation: 3, decimation: 2).sampleRate == 72_000)
        #expect(downstream.blockSize == upstream.blockSize && downstream.channelCount == upstream.channelCount)
    }

    @Test func spectralKeysExistOnlyInsideASpectralScope() {
        let samples = DSPEnvironment(sampleRate: 48_000, channelCount: 2)
        #expect(samples.frameSize == nil && samples.hopSize == nil && samples.featureRate == nil)
        #expect(samples.frequencyResolution == nil && samples.frequencyAxis == nil && !samples.isInSpectralScope)

        let axis = FeedAxis.linearFrequency(binCount: 1_025, nyquist: 24_000)
        let spectral = samples.enteringSpectralScope(frameSize: 2_048, hopSize: 512, axis: axis)
        #expect(spectral.isInSpectralScope)
        #expect(spectral.frameSize == 2_048 && spectral.hopSize == 512 && spectral.frequencyAxis == axis)
        #expect(spectral.frequencyResolution == 48_000.0 / 2_048 && spectral.featureRate == 93.75)
        #expect(spectral.sampleRate == 48_000, "inside the scope the sample rate is still that of the framed signal (§5.2)")
        #expect(spectral.channelCount == 1, "a framing step reduces the channels")

        let mel = spectral.replacingAxis(.mel(centers: [100, 200]))
        #expect(mel.frequencyAxis == .mel(centers: [100, 200]) && mel.frameSize == 2_048)

        let back = spectral.leavingSpectralScope()
        #expect(!back.isInSpectralScope && back.frameSize == nil && back.hopSize == nil && back.frequencyAxis == nil)
        #expect(back.featureRate == nil && back.frequencyResolution == nil && back.sampleRate == 48_000)
        #expect(spectral.leavingSpectralScope(channelCount: 2).channelCount == 2)
    }

    @Test func aFeatureSequenceIsANewSampledSequenceAtTheFeatureRate() {
        let spectral = DSPEnvironment(sampleRate: 48_000)
            .enteringSpectralScope(frameSize: 1_024, hopSize: 256, axis: .linearFrequency(binCount: 513, nyquist: 24_000))
        let novelty = spectral.beginningFeatureSequence(rate: spectral.featureRate!)
        #expect(novelty.sampleRate == 187.5 && novelty.nyquistFrequency == 93.75)
        #expect(novelty.frameSize == nil && novelty.hopSize == nil && novelty.frequencyAxis == nil && novelty.featureRate == nil)
        #expect(!novelty.isInSpectralScope)
        // LowPass(cutoff: .hertz(4)) on a novelty curve means 4 Hz of the novelty signal (§5.2).
        #expect(4 < novelty.nyquistFrequency)
    }

    @Test func latencyAccumulates() {
        let environment = DSPEnvironment().addingLatency(0.010).addingLatency(0.0025)
        #expect(abs(environment.latency - 0.0125) < 1e-15)
        #expect(DSPEnvironment().latency == 0)
    }

    @Test func sourceValuesAreSetByTheEngine() {
        let environment = DSPEnvironment()
            .withFormat(SignalFormat(sampleRate: 44_100, channelCount: 2))
            .withBlockSize(256)
            .withSource(kind: .push, isRealTime: true)
        #expect(environment.sampleRate == 44_100 && environment.channelCount == 2 && environment.blockSize == 256)
        #expect(environment.sourceKind == .push && environment.isRealTime)
        #expect(environment.withChannelCount(1).channelCount == 1)
    }
}

@Suite("BackgroundWork (WP-112)")
struct BackgroundWorkTests {
    private struct Observation: Sendable {
        let isMain: Bool
        let isBackground: Bool
        let quality: UInt32
    }

    private static func onMainThread() -> Bool { pthread_main_np() != 0 }

    @Test @MainActor func workRunsOffTheMainThread() async throws {
        #expect(Self.onMainThread())
        #expect(!BackgroundWork.isCurrent)
        let observed = try await BackgroundWork.run { _ in
            Observation(isMain: Self.onMainThread(), isBackground: BackgroundWork.isCurrent, quality: qos_class_self().rawValue)
        }
        #expect(!observed.isMain)
        #expect(observed.isBackground)
        #expect(observed.quality == QOS_CLASS_UTILITY.rawValue, "utility quality of service (BG-1)")
        #expect(Self.onMainThread(), "the caller is resumed where it was")
    }

    @Test func resultsAndErrorsComeBack() async throws {
        let value = try await BackgroundWork.run { _ in [1.0, 2.0, 3.0].reduce(0, +) }
        #expect(value == 6)
        do {
            _ = try await BackgroundWork.run { (_: BackgroundWork.Checkpoint) throws(DSPError) -> Int in
                throw DSPError.unsupportedConfiguration(reason: "seeded")
            }
            Issue.record("the error did not come back")
        } catch {
            #expect(error == .unsupportedConfiguration(reason: "seeded"), "typed: a DSPError, not any Error")
        }
    }

    @Test func cancellationStopsTheWorkBetweenItsSteps() async {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let task = Task { () -> Result<Int, DSPError> in
            do throws(DSPError) {
                let steps = try await BackgroundWork.run { (checkpoint: BackgroundWork.Checkpoint) throws(DSPError) -> Int in
                    startedSignal.yield()
                    var steps = 0
                    // Steps until the cancellation is seen; the bound only guards against a broken checkpoint.
                    while steps < 50_000_000 {
                        try checkpoint.check()
                        steps += 1
                        sched_yield()
                    }
                    return steps
                }
                return .success(steps)
            } catch {
                return .failure(error)
            }
        }
        for await _ in started { break }
        task.cancel()
        switch await task.value {
        case .success(let steps): Issue.record("the work ran to completion (\(steps) steps)")
        case .failure(let error): #expect(error == .cancelled)
        }
    }

    @Test func aCallThatIsAlreadyCancelledDoesNotStart() async {
        let ran = Locked(false)
        let task = Task { () -> Result<Int, DSPError> in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(DSPError) {
                let value = try await BackgroundWork.run { (_: BackgroundWork.Checkpoint) throws(DSPError) -> Int in
                    ran.set(true)
                    return 1
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        let outcome = await task.value
        #expect(outcome == .failure(.cancelled))
        #expect(!ran.get())
    }

    @Test func aCheckpointReportsCancellationWithoutThrowing() async throws {
        let seen = try await BackgroundWork.run { checkpoint in checkpoint.isCancelled }
        #expect(!seen)
    }

    @Test func workRunsConcurrently() async throws {
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0 ..< 16 {
                group.addTask { try await BackgroundWork.run { _ in index * index } }
            }
            var all: [Int] = []
            for try await value in group { all.append(value) }
            return all.sorted()
        }
        #expect(values == (0 ..< 16).map { $0 * $0 })
    }
}

/// A lock-guarded box for the tests above (the package's own is internal).
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
