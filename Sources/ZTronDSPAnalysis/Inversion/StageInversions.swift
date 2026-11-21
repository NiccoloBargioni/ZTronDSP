import Foundation
import ZTronDSPCore

// The inversion reports of the stock steps (§6.13): for each forward step, the conditions of
// the table, the error they predict, and the round trip through the step and its inverse.

/// Round-off the reports allow a round trip that is exact in theory.
enum InversionRoundOff {
    /// A single-precision transform and its inverse: a few units in the last place per level
    /// of the transform (§7.5 row 1), with head-room.
    static func transform(length: Int) -> Double {
        16 * Double(Float.ulpOfOne) * log2(Double(Swift.max(length, 2)))
    }

    /// A single-precision logarithm and exponential, and the double-precision cepstral
    /// transforms rounded to single-precision frames.
    static let logarithm = 1e-5
}

// MARK: STFT ↔ InverseSTFT (WP-538)

extension STFT: InvertibleStage {
    /// The overlap-add conditions of the window and the hop (Griffin & Lim 1984): they do not
    /// depend on the signal. As every requirement of an invertible stage, it runs in the
    /// background, never on the analysis thread, and allocates.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        guard frame >= 1, hop >= 1 else {
            throw .invalidParameter(stage: .none, parameter: "hop", reason: "a frame of \(frame) samples and a hop of \(hop) frame nothing")
        }
        let sampled = try SampledWindow(window, frame: frame)
        let bounds = OverlapAdd.frameBounds(sampled.double, hop: hop)
        let ratio = bounds.greatest > 0 ? bounds.least / bounds.greatest : 0
        let nonZero = OverlapAdd.isNonZero(bounds)
        let roundOff = InversionRoundOff.transform(length: transformLength)
        return [
            InversionCondition(
                name: "non-zero overlap-add",
                theorem: "Σₖ w²(n − k·hop) > 0 for every n: every sample is weighed by at least one frame, so overlap-add with window-sum-of-squares normalisation returns it (Griffin & Lim 1984)",
                quantity: "the least value of Σ w² over shifts by the hop, as a fraction of its greatest: the reciprocal of the frame-bound ratio B/A",
                observed: ratio, holds: nonZero, margin: nonZero ? ratio : ratio - OverlapAdd.nonZeroFloor,
                // Round-off is amplified by B/A; where no frame weighs a sample, the sample is lost.
                predictedError: nonZero ? Swift.min(roundOff / ratio, 1) : 1),
            InversionCondition(
                name: "constant overlap-add",
                theorem: "Σₖ w²(n − k·hop) is the same for every n: the frames form a tight frame, the response is flat and round-off is not amplified",
                quantity: "the least value of Σ w² over shifts by the hop, as a fraction of its greatest",
                observed: ratio, holds: ratio >= 1 - 1e-9, margin: ratio - (1 - 1e-9), isNecessary: false),
        ]
    }

    /// The signal through the analysis and the synthesis. What a causal analysis cannot recover,
    /// the samples its first window barely weighs, is left out, as is the end of the signal that no
    /// complete frame covers. As every requirement of an invertible stage, it runs in the
    /// background, never on the analysis thread, and it allocates and compiles plans.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil else { return nil }
        let original = try context.samples()
        // A failing window is measured, not refused (INV-3).
        let synthesis = InverseSTFT(window: window, normalization: normalization, alignment: alignment, backendBox: backendBox,
                                    activation: .active, enforcesOverlapAdd: false)
        let output = try context.samples(after: stageDescriptions + synthesis.stageDescriptions)
        let delay = InverseSTFT.delay(frame: frame, hop: hop, alignment: alignment).total
        let first = alignment == .centered ? 0 : frame
        let count = Swift.min(original.count - first, output.count - delay - first)
        guard count > 0 else { return InversionRoundTrip(original: [], reconstruction: []) }
        return InversionRoundTrip(original: Array(original[first ..< first + count]), reconstruction: Array(output[(delay + first) ..< (delay + first + count)]))
    }
}

// MARK: Cepstrum(.complex) ↔ InverseCepstrum (WP-539)

extension Cepstrum: InvertibleStage {
    /// The step that undoes `Cepstrum(.complex)` (INV-1); after the other two kinds there is no way
    /// back, as the conditions say. Usable on any thread; it does not allocate.
    public var inverse: InverseCepstrum { InverseCepstrum() }

    /// The phase must be kept; and, on the frames of the signal, the logarithm must be finite and
    /// the phase unwrapped without ambiguity. As every requirement of an invertible stage, it runs
    /// in the background, never on the analysis thread, and it allocates and compiles plans.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        let keepsPhase = kind == .complex
        var conditions = [InversionCondition(
            name: "the phase is kept",
            theorem: "IDFT(ln |X| + j·unwrap(∠X)) holds everything the exponential needs to return X; the real and the power cepstrum discard the phase",
            quantity: "1 for the complex cepstrum, 0 otherwise",
            observed: keepsPhase ? 1 : 0, holds: keepsPhase, margin: keepsPhase ? 0 : -1, predictedError: keepsPhase ? 0 : 1)]
        guard context.samples != nil else { return conditions }

        let frames = try context.complexFrames()
        var least = Double.infinity, largestStep = 0.0, lost = 0.0, atFloor = 0, total = 0
        var largest = 0.0, hasSilentFrame = false
        for frame in frames {
            let bins = frame.count / 2
            var peak = 0.0, floored = false
            var previous = 0.0
            for bin in 0 ..< bins {
                let real = Double(frame[bin]), imaginary = Double(frame[bins + bin])
                let magnitude = (real * real + imaginary * imaginary).squareRoot()
                peak = Swift.max(peak, magnitude)
                least = Swift.min(least, magnitude)
                if magnitude <= floor {
                    floored = true
                    atFloor += 1
                }
                let angle = atan2(imaginary, real)
                if bin > 0, magnitude > floor {
                    var step = abs(angle - previous)
                    if step > .pi { step = 2 * .pi - step }
                    largestStep = Swift.max(largestStep, step)
                }
                previous = angle
            }
            total += bins
            largest = Swift.max(largest, peak)
            // A bin at the floor comes back as the floor: an error of up to the floor, held
            // against its frame's maximum.
            if floored, peak > 0 { lost = Swift.max(lost, floor / peak) }
            if floored, peak == 0 { hasSilentFrame = true }
            try context.check()
        }
        // A frame of exact silence has no maximum to be held against: its error is held
        // against the largest value of the signal, and has no bound when that is zero too.
        if hasSilentFrame { lost = Swift.max(lost, largest > 0 ? floor / largest : .infinity) }
        let finite = atFloor == 0
        let headroom = total > 0 ? Swift.max(20 * log10(Swift.max(least, 1e-300) / floor), -400) : 0
        conditions.append(InversionCondition(
            name: "a finite log spectrum",
            theorem: "ln |X| is finite: no bin lies at or below the floor of the logarithm. A bin that does comes back as the floor",
            quantity: "the least magnitude of a bin over the floor, in decibels (\(atFloor) of \(total) bins are at the floor)",
            observed: headroom, holds: finite, margin: finite ? headroom : Swift.min(headroom, 0),
            // The floor itself comes back rounded: the round-off is relative to it as well.
            predictedError: lost * (1 + InversionRoundOff.logarithm) + InversionRoundOff.logarithm))
        conditions.append(InversionCondition(
            name: "a phase unwrapped without ambiguity",
            theorem: "the phase moves by less than π from one bin to the next, so unwrapping it has one answer. Where it does not, the cepstrum is not the cepstrum of the signal's phase, though the exponential still returns the spectrum",
            quantity: "π minus the largest phase step between neighbouring bins, in radians",
            observed: .pi - largestStep, holds: largestStep < .pi - 1e-3, margin: .pi - 1e-3 - largestStep, isNecessary: false))
        return conditions
    }

    /// The spectra through the cepstrum and back. A real or a power cepstrum has no way back: there
    /// is nothing to measure. As every requirement of an invertible stage, it runs in the
    /// background, never on the analysis thread, and it allocates and compiles plans.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil, kind == .complex else { return nil }
        let original = try context.complexFrames()
        let restored = try context.complexFrames(after: stageDescriptions + inverse.stageDescriptions)
        return InversionRoundTrip(original: original.flatMap { $0 }, reconstruction: restored.flatMap { $0 }, frameLength: original.first?.count ?? 1)
    }
}

// MARK: CepstralCoefficients ↔ InverseCepstralCoefficients (WP-539)

extension CepstralCoefficients: InvertibleStage {
    /// Full rank: as many coefficients as the spectrum has bands. The bands are those of the frames
    /// that reach the step, so the pipeline that produces them is needed: ask for the report with
    /// `after:`. As every requirement of an invertible stage, it runs in the background, never on
    /// the analysis thread, and it allocates and compiles plans.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        let frames = try context.samples == nil ? context.probeFrames() : context.frames()
        guard let bands = frames.first?.count, bands >= 1 else {
            throw .invalidParameter(
                stage: .none, parameter: "after",
                reason: "CepstralCoefficients follows a mel spectrum in decibels: the report needs the pipeline that produces one, and a signal long enough for a frame")
        }
        let fullRank = count >= bands
        // What the dropped coefficients carry, as a share of the energy of all of them.
        var dropped = 0.0, total = 0.0
        if !fullRank, context.samples != nil {
            let basis = CosineBasis.orthonormal(bands: bands, count: bands)
            for frame in frames {
                for row in 0 ..< bands {
                    var coefficient = 0.0
                    for column in 0 ..< bands { coefficient += Double(basis[row * bands + column]) * Double(frame[column]) }
                    total += coefficient * coefficient
                    if row >= count { dropped += coefficient * coefficient }
                }
                try context.check()
            }
        }
        let loss = fullRank ? 0 : (total > 0 ? (dropped / total).squareRoot() : 1)
        return [InversionCondition(
            name: "full rank",
            theorem: "the orthonormal DCT-II is undone by its transpose when it is square: as many coefficients as bands. With fewer, what the dropped coefficients carried is gone",
            quantity: "coefficients kept minus bands (\(count) of \(bands))",
            observed: Double(count - bands), holds: fullRank, margin: Double(count - bands),
            predictedError: Swift.min(loss + InversionRoundOff.logarithm, 1))]
    }

    /// The mel spectrum through the coefficients and back to as many bands as it had. As every
    /// requirement of an invertible stage, it runs in the background, never on the analysis thread,
    /// and it allocates and compiles plans.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil else { return nil }
        let original = try context.frames()
        guard let bands = original.first?.count, count <= bands else { return nil }
        let restored = try context.frames(after: stageDescriptions + InverseCepstralCoefficients(bands: bands).stageDescriptions)
        return InversionRoundTrip(original: original.flatMap { $0 }, reconstruction: restored.flatMap { $0 }, frameLength: bands)
    }
}

// MARK: Decibels ↔ InverseDecibels (WP-539)

/// `Decibels` where it follows one kind of value: the pairing that has an inverse. `Decibels`
/// itself is a step of a family, whose inverse depends on what precedes it (ORD-1).
struct DecibelsInversion<Values: LinearValued>: InvertibleStage {
    let base: Decibels

    static var stageName: String { "Decibels" }
    var inverse: InverseDecibels<Values> { base.inverse(of: LinearValueKind<Values>()) }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        try base.lower(&context)
    }

    /// The linear value the floor stands for.
    private var linearFloor: Double {
        base.reference * pow(10, base.floor / (Values.valuesTag == .power ? 10 : 20))
    }

    func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        guard context.samples != nil else { return [] }
        let frames = try context.frames()
        let limit = linearFloor
        var atFloor = 0, total = 0, lost = 0.0, largest = 0.0, hasSilentFrame = false
        for frame in frames {
            var peak = 0.0, floored = false
            for value in frame {
                peak = Swift.max(peak, abs(Double(value)))
                if abs(Double(value)) <= limit {
                    floored = true
                    atFloor += 1
                }
            }
            total += frame.count
            largest = Swift.max(largest, peak)
            if floored, peak > 0 { lost = Swift.max(lost, limit / peak) }
            if floored, peak == 0 { hasSilentFrame = true }
            try context.check()
        }
        // A frame of exact silence is held against the largest value of the signal, and has
        // no bound when that is zero too.
        if hasSilentFrame { lost = Swift.max(lost, largest > 0 ? limit / largest : .infinity) }
        let share = total > 0 ? Double(atFloor) / Double(total) : 0
        return [InversionCondition(
            name: "values above the floor",
            theorem: "10^(dB / 20) for magnitudes, 10^(dB / 10) for powers, returns a value that was not clamped: every value lies above the floor of the conversion. One at the floor comes back as the floor",
            quantity: "the share of bins at the floor (\(atFloor) of \(total))",
            observed: share, holds: atFloor == 0, margin: -share,
            predictedError: lost * (1 + InversionRoundOff.logarithm) + InversionRoundOff.logarithm)]
    }

    func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil else { return nil }
        let original = try context.frames()
        let restored = try context.frames(after: [base.stageDescription, inverse.stageDescription])
        return InversionRoundTrip(original: original.flatMap { $0 }, reconstruction: restored.flatMap { $0 }, frameLength: original.first?.count ?? 1)
    }
}

extension Decibels {
    /// The step that undoes this one after magnitudes, or after powers: `InverseDecibels` of that
    /// kind with this step's reference (INV-1). A `Decibels` follows either kind of value, so its
    /// inverse is named for one of them. Usable on any thread; it does not allocate.
    public func inverse<Values: LinearValued>(of values: LinearValueKind<Values>) -> InverseDecibels<Values> {
        InverseDecibels(values, reference: reference)
    }

    /// The inversion report of the step where it follows `upstream`, whose output says whether
    /// the values are magnitudes or powers (§6.13): the share of bins at the floor, which come
    /// back as the floor, and the error of the round trip on the frames of `samples`.
    ///
    /// The call may be made from any context; the work runs on the background executor (BG-1) and
    /// can be cancelled (BG-3). A condition that fails is part of the report, not an error (INV-3).
    /// Without samples the report holds no condition: the only one there is asks about the signal.
    /// It allocates, in the background.
    public func inversionReport<Axis, Values: LinearValued>(
        for samples: [Float]? = nil, sampleRate: Double = 48_000, after upstream: Pipeline<Samples, Spectrum<Axis, Values>>
    ) async throws(DSPError) -> InversionReport {
        try await DecibelsInversion<Values>(base: self).report(samples: samples, sampleRate: sampleRate, upstream: upstream.stages)
    }
}
