import Accelerate
import ZTronDSPCore

extension DSP {
    /// The masks of the harmonic–percussive separation of a whole magnitude spectrogram,
    /// offline (§6.10): for every bin of every frame, the share that is harmonic and the share
    /// that is percussive. What they leave, `1 − harmonic − percussive`, is the residual.
    ///
    /// ```swift
    /// let frames: [[Float]] = try Pipeline { STFT(frame: 2_048, hop: 512); Magnitude() }.process(samples, format: format)
    /// let masks = try await DSP.harmonicPercussiveMasks(of: frames.flatMap { $0 }, binCount: 1_025)
    /// ```
    ///
    /// The medians are centred, with the edges of the spectrogram reflected (§6.1): it is what
    /// `HarmonicPercussive(alignment: .centered)` gives frame by frame, with the frames at the
    /// end of the spectrogram that a stream would still be waiting for.
    ///
    /// The work runs on the background executor (BG-1): the call may be made from any context,
    /// the main actor included, and can be cancelled (BG-3).
    ///
    /// - Parameters:
    ///   - magnitudes: `binCount` values per frame, frame after frame, as a `FeedSnapshot`
    ///     holds them; not negative.
    ///   - median: `.automatic`, the default, follows `crossovers`: the CPU lanes below
    ///     `medianGPU`, counted as kernel × bins × frames, the GPU from there on, and the CPU
    ///     wherever there is no Metal device (GPU-1, GPU-4). `.selectionNetwork` is the CPU
    ///     whatever the size; `.metal` is the GPU, and `backendUnavailable` without a device.
    ///     The result is the same value for value (GPU-3).
    ///   - mask, harmonicMargin, percussiveMargin, floor: as for ``HarmonicPercussive``.
    /// - Returns: the two masks, each as long as `magnitudes` and in its order.
    /// - Throws: `DSPError.invalidParameter` for magnitudes that do not fill whole frames, a
    ///   kernel that is not odd, a margin below 1 or a mask that is none;
    ///   `DSPError.backendUnavailable` for `.metal` without a device; `DSPError.cancelled`.
    public static func harmonicPercussiveMasks(
        of magnitudes: [Float], binCount: Int, timeKernel: Int = 31, frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2),
        harmonicMargin: Double = 1, percussiveMargin: Double = 1, floor: Double = 1e-10, median: some MedianStrategy = .automatic,
        crossovers: CrossoverTable = .shipped
    ) async throws(DSPError) -> (harmonic: [Float], percussive: [Float]) {
        try await BackgroundWork.run { checkpoint throws(DSPError) in
            let separation = try OfflineSeparation(
                magnitudes, binCount: binCount, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask, harmonicMargin: harmonicMargin,
                percussiveMargin: percussiveMargin, floor: floor, median: median, crossovers: crossovers, checkpoint: checkpoint)
            return (try separation.masked(.harmonic, applied: false, checkpoint: checkpoint), try separation.masked(.percussive, applied: false, checkpoint: checkpoint))
        }
    }

    /// One component of the harmonic–percussive separation of a whole magnitude spectrogram,
    /// offline (§6.10): the magnitudes under the mask of the component. The three components
    /// add up to the magnitudes again.
    ///
    /// The medians, the masks, the threading and the errors are those of
    /// ``harmonicPercussiveMasks(of:binCount:timeKernel:frequencyKernel:mask:harmonicMargin:percussiveMargin:floor:median:crossovers:)``.
    ///
    /// - Returns: as many values as `magnitudes`, in the same order.
    public static func harmonicPercussive(
        _ magnitudes: [Float], binCount: Int, select component: HarmonicPercussiveComponent, timeKernel: Int = 31, frequencyKernel: Int = 31,
        mask: some MaskStrategy = .soft(power: 2), harmonicMargin: Double = 1, percussiveMargin: Double = 1, floor: Double = 1e-10,
        median: some MedianStrategy = .automatic, crossovers: CrossoverTable = .shipped
    ) async throws(DSPError) -> [Float] {
        try await BackgroundWork.run { checkpoint throws(DSPError) in
            try OfflineSeparation(
                magnitudes, binCount: binCount, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask, harmonicMargin: harmonicMargin,
                percussiveMargin: percussiveMargin, floor: floor, median: median, crossovers: crossovers, checkpoint: checkpoint
            ).masked(component, applied: true, checkpoint: checkpoint)
        }
    }
}

/// The offline separation of a whole spectrogram (WP-612): the two medians, by whichever
/// side the strategy and the table name, and the masks of the streaming node on top.
///
/// Background work: everything here allocates and may block on the GPU.
struct OfflineSeparation {
    let magnitudes: [Float]
    let binCount: Int
    let timeMedian: [Float]
    let frequencyMedian: [Float]
    let mask: any MaskStrategy
    let harmonicMargin: Float
    let percussiveMargin: Float
    let floor: Float

    init(
        _ magnitudes: [Float], binCount: Int, timeKernel: Int, frequencyKernel: Int, mask: any MaskStrategy, harmonicMargin: Double,
        percussiveMargin: Double, floor: Double, median: any MedianStrategy, crossovers: CrossoverTable, checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) {
        guard binCount >= 1, magnitudes.count % binCount == 0 else {
            throw .invalidParameter(stage: .none, parameter: "magnitudes", reason: "\(magnitudes.count) values do not fill frames of \(binCount) bins")
        }
        try HarmonicPercussive.check(
            timeKernel: timeKernel, frequencyKernel: frequencyKernel, harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: floor,
            mask: mask)
        self.magnitudes = magnitudes
        self.binCount = binCount
        self.mask = mask
        self.harmonicMargin = Float(harmonicMargin)
        self.percussiveMargin = Float(percussiveMargin)
        self.floor = Float(floor)
        timeMedian = try median.filter(magnitudes, rowCount: binCount, kernel: timeKernel, along: .time, crossovers: crossovers, checkpoint: checkpoint)
        try checkpoint?.check()
        frequencyMedian = try median.filter(magnitudes, rowCount: binCount, kernel: frequencyKernel, along: .frequency, crossovers: crossovers, checkpoint: checkpoint)
    }

    /// The mask of `component` for every frame, or, with `applied`, the magnitudes under it.
    func masked(_ component: HarmonicPercussiveComponent, applied: Bool, checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) -> [Float] {
        let frameCount = magnitudes.count / binCount
        var result = [Float](repeating: 0, count: magnitudes.count)
        guard frameCount > 0 else { return result }
        let masks = try SeparationMasks(binCount: binCount, strategy: mask, harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, floor: floor)
        var failure: DSPError?
        magnitudes.withUnsafeBufferPointer { spectrum in
            timeMedian.withUnsafeBufferPointer { harmonic in
                frequencyMedian.withUnsafeBufferPointer { percussive in
                    result.withUnsafeMutableBufferPointer { target in
                        guard let values = spectrum.baseAddress, let along = harmonic.baseAddress, let across = percussive.baseAddress, let to = target.baseAddress
                        else { return }
                        for frame in 0 ..< frameCount {
                            if frame % MedianOffline.framesPerCheck == 0, checkpoint?.isCancelled == true {
                                failure = .cancelled
                                return
                            }
                            let offset = frame * binCount
                            masks.mask(component, timeMedian: along + offset, frequencyMedian: across + offset, into: to + offset)
                            if applied { vDSP_vmul(values + offset, 1, to + offset, 1, to + offset, 1, vDSP_Length(binCount)) }
                        }
                    }
                }
            }
        }
        if let failure { throw failure }
        return result
    }
}
