import Foundation

/// What a stage lowers itself into (§5.11.1): the environment at its position, and a place to
/// emit kernels and nodes.
///
/// The context is handed to `StageValue.lower(_:)` on the control context while a plan is
/// compiled. Everything a stage gets without writing it comes through here (EXT-2): the
/// positional environment, errors that carry the stage's path, latency accounting, and
/// fusion for stages that emit stock specs. The compiler applies the stage's activation and
/// checks its place in the order; a stage does neither.
///
/// A stage uses it inside `lower(_:)` only, on the control context; emitting a spec may
/// allocate.
public struct LoweringContext {
    private let position: IRPosition
    private var emitted: [KernelSpec] = []
    private var running: DSPEnvironment
    private var runningDomainIsSequence: Bool
    private var runningMaximumFrames: Int

    /// The stage's place in the pipeline, for errors.
    public let path: StagePath
    /// The measured crossovers the plan is being compiled with (§7.4).
    public let crossovers: CrossoverTable

    init(position: IRPosition, path: StagePath, crossovers: CrossoverTable) {
        self.position = position
        self.path = path
        self.crossovers = crossovers
        self.running = position.environment
        self.runningDomainIsSequence = position.domain.isSampledSequence
        self.runningMaximumFrames = position.maximumFrames
    }

    /// The environment at this position (ENV-1): what the stage resolves its frequencies and
    /// sizes against. After the stage has emitted a spec that changes the rate or the scope,
    /// it is the environment after that spec.
    public var environment: DSPEnvironment { running }

    /// The domain of the signal the stage receives.
    public var domain: DomainTag { position.domain }

    /// The most frames one block of samples holds at this position: what a sample-domain
    /// stage sizes its buffers for. 1 on a feature-rate sequence.
    public var maximumBlockFrames: Int { runningMaximumFrames }

    /// Channels of the sequence a kernel emitted here runs on.
    public var channelCount: Int { position.kernelChannels }

    /// The implementation a primitive of the given size is bound to here: the table's choice,
    /// or the one the environment forces (SEL-2, SEL-3).
    public func implementation(for primitive: Primitive, size: Int) -> Implementation {
        crossovers.implementation(for: primitive, size: size, requested: running.implementation)
    }

    /// Emits a kernel, a processor or an analysis node. Specs run in the order they are
    /// emitted. The environment the stage reads afterwards reflects the spec: a rate changer
    /// changes the sample rate, a framing step opens a spectral scope, and every spec's
    /// latency is added (REAL-5).
    public mutating func emit(_ spec: KernelSpec) {
        emitted.append(spec)
        running = LoweringContext.environment(after: spec, from: running)
        runningMaximumFrames = LoweringContext.maximumFrames(after: spec, from: runningMaximumFrames)
    }

    /// An `invalidParameter` error for this stage.
    public func invalid(_ parameter: String, _ reason: String) -> DSPError {
        .invalidParameter(stage: path, parameter: parameter, reason: reason)
    }

    /// The error of a structural stage whose `lower` was called: structure is lowered by the
    /// plan compiler from its description, never by itself.
    public func structuralStage() -> DSPError {
        .unsupportedConfiguration(reason: "this stage is structure: it is lowered by the plan compiler, not by itself", stage: path)
    }

    /// What the stage emitted, for the compiler.
    var specs: [KernelSpec] { emitted }

    // MARK: How a spec moves the position (ENV-1)

    static func environment(after spec: KernelSpec, from environment: DSPEnvironment) -> DSPEnvironment {
        var result = environment
        let rate = spec.rate
        let latencyFrames = spec.latencyFrames
        if latencyFrames > 0, environment.sampleRate > 0 {
            result = result.addingLatency(Double(latencyFrames) / environment.sampleRate)
        }
        if rate.interpolation != rate.decimation {
            result = result.changingRate(interpolation: rate.interpolation, decimation: rate.decimation)
        }
        if case .analysis(let step) = spec {
            if step.latency > 0 { result = result.addingLatency(step.latency) }
            switch step.scope {
            case .none: break
            case .spectral(let frameSize, let hopSize, let axis):
                result = result.enteringSpectralScope(frameSize: frameSize, hopSize: hopSize, axis: axis)
            case .axis(let axis):
                result = result.replacingAxis(axis)
            case .featureSequence(let rate):
                result = result.beginningFeatureSequence(rate: rate)
            case .samples(_, let channelCount):
                result = result.leavingSpectralScope(channelCount: channelCount)
            }
        }
        return result
    }

    static func maximumFrames(after spec: KernelSpec, from frames: Int) -> Int {
        if case .analysis(let step) = spec {
            switch step.scope {
            case .samples(let maximumBlockFrames, _): return max(maximumBlockFrames, 1)
            case .featureSequence: return 1
            default: return frames
            }
        }
        let rate = spec.rate
        guard rate.interpolation != rate.decimation else { return frames }
        // One more than the exact ratio: a rate changer carries a phase across blocks. A count
        // that no `Int` holds stays at the largest one: the plan is then refused for its size,
        // with a typed error, where it would otherwise have trapped here (§9.3).
        let (product, overflow) = frames.multipliedReportingOverflow(by: rate.interpolation)
        guard !overflow else { return Int.max }
        let whole = product / rate.decimation + (product % rate.decimation == 0 ? 0 : 1)
        return whole < Int.max ? whole + 1 : Int.max
    }
}
