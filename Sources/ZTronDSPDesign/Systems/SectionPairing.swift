import ZTronDSPCore

extension ZeroPoleGain {
    /// The system as cascaded second-order sections, paired by the "nearest" rule (§6.3.2,
    /// §7.2 row 4):
    ///
    /// 1. Zeros or poles are added at the origin until there are as many of one as of the
    ///    other, and an even number of each. They change nothing but the delay.
    /// 2. The pole closest to the unit circle is taken with its conjugate (or, when it is
    ///    real, with the real pole that is next closest), and paired with the zero nearest to
    ///    it (and that zero's conjugate, or the nearest real zero).
    /// 3. That pair forms the *last* section; the rule is applied again to what is left for
    ///    the section before it. The poles closest to the unit circle therefore come last,
    ///    where the signal has already been shaped by the tamer sections.
    /// 4. The gain goes into the first section.
    ///
    /// This is the pairing of `scipy.signal.zpk2sos(pairing='nearest')`, section for section.
    /// Each section's coefficients are formed from two roots only, which is why the cascade
    /// keeps the accuracy that an expanded polynomial loses (`Docs/Numerics/section-pairing.md`).
    ///
    /// Only a digital system is converted. Control or background context; allocates.
    ///
    /// - Throws: `DSPError.unsupportedConfiguration` for an analog system;
    ///   `DSPError.invalidParameter` when a value is not finite or the zeros or poles are not
    ///   closed under conjugation.
    public func secondOrderSections() throws(DSPError) -> SecondOrderSections {
        guard domain == .digital else {
            throw .unsupportedConfiguration(reason: "second-order sections are formed for a digital system; an analog system of odd order has a first-order factor that a section with a0 = 1 cannot hold")
        }
        guard gain.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "the gain must be finite, not \(gain)")
        }
        if zeros.isEmpty, poles.isEmpty {
            return SecondOrderSections(sections: [.init(b0: gain, b1: 0, b2: 0, a1: 0, a2: 0)], domain: .digital)
        }

        // As many zeros as poles, and an even number of each.
        var paddedPoles = poles
        var paddedZeros = zeros
        if paddedPoles.count < paddedZeros.count {
            paddedPoles += [Complex](repeating: .zero, count: paddedZeros.count - paddedPoles.count)
        } else if paddedZeros.count < paddedPoles.count {
            paddedZeros += [Complex](repeating: .zero, count: paddedPoles.count - paddedZeros.count)
        }
        if paddedPoles.count % 2 == 1 {
            paddedPoles.append(.zero)
            paddedZeros.append(.zero)
        }
        let sectionCount = paddedPoles.count / 2

        // One entry per conjugate pair (positive imaginary part), then the real roots.
        var remainingPoles = SectionPairing.entries(try ConjugatePairs.split(paddedPoles, parameter: "poles"))
        var remainingZeros = SectionPairing.entries(try ConjugatePairs.split(paddedZeros, parameter: "zeros"))

        var sections = [SecondOrderSections.Section](repeating: .identity, count: sectionCount)
        for sectionIndex in stride(from: sectionCount - 1, through: 0, by: -1) {
            // The pole closest to the unit circle, and its partner.
            let first = remainingPoles.remove(at: try SectionPairing.worst(remainingPoles, among: { _ in true }))
            let poleCoefficients: (Double, Double)
            if first.isReal {
                let second = remainingPoles.remove(at: try SectionPairing.worst(remainingPoles, among: { $0.isReal }))
                poleCoefficients = (-(first.real + second.real), first.real * second.real)
            } else {
                poleCoefficients = (-2 * first.real, first.squaredMagnitude)
            }

            // The zero nearest to that pole, and its partner.
            let zero = remainingZeros.remove(at: try SectionPairing.nearest(remainingZeros, to: first, among: { _ in true }))
            let zeroCoefficients: (Double, Double)
            if zero.isReal {
                let partner = remainingZeros.remove(at: try SectionPairing.nearest(remainingZeros, to: first, among: { $0.isReal }))
                zeroCoefficients = (-(zero.real + partner.real), zero.real * partner.real)
            } else {
                zeroCoefficients = (-2 * zero.real, zero.squaredMagnitude)
            }
            sections[sectionIndex] = .init(b0: 1, b1: zeroCoefficients.0, b2: zeroCoefficients.1,
                                           a1: poleCoefficients.0, a2: poleCoefficients.1)
        }

        // The gain goes into the first section.
        let head = sections[0]
        sections[0] = .init(b0: gain * head.b0, b1: gain * head.b1, b2: gain * head.b2, a1: head.a1, a2: head.a2)
        return SecondOrderSections(sections: sections, domain: .digital)
    }
}

/// The two selections of the nearest-pairing rule. Ties go to the earlier entry, as in the
/// reference.
///
/// The padding makes the number of zeros and of poles equal and even, and conjugate pairs
/// count as one entry, so the real entries of either list come in an even number: a
/// selection always finds a candidate. Should that ever fail, it is reported as a typed
/// error and not as a trap.
enum SectionPairing {
    static func entries(_ split: (pairs: [Complex], reals: [Double])) -> [Complex] {
        split.pairs + split.reals.map { Complex($0) }
    }

    /// The index of the entry closest to the unit circle among those that satisfy `among`.
    static func worst(_ poles: [Complex], among: (Complex) -> Bool) throws(DSPError) -> Int {
        try selection(poles, among: among) { abs(1 - $0.magnitude) }
    }

    /// The index of the entry nearest to `target` among those that satisfy `among`.
    static func nearest(_ zeros: [Complex], to target: Complex, among: (Complex) -> Bool) throws(DSPError) -> Int {
        try selection(zeros, among: among) { ($0 - target).magnitude }
    }

    private static func selection(_ entries: [Complex], among: (Complex) -> Bool, distance: (Complex) -> Double) throws(DSPError) -> Int {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, entry) in entries.enumerated() where among(entry) {
            let candidate = distance(entry)
            if best == nil || candidate < bestDistance {
                best = index
                bestDistance = candidate
            }
        }
        guard let best else {
            throw .invalidParameter(stage: .none, parameter: "system", reason: "the zeros and poles cannot be paired into second-order sections")
        }
        return best
    }
}
