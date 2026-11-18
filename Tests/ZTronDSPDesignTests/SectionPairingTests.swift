import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-404: zeros and poles paired into second-order sections by the nearest rule, the poles
/// closest to the unit circle last. Acceptance: parity with the reference pairing,
/// `scipy.signal.zpk2sos(pairing='nearest')`, section for section.
@Suite("ZPK → SOS: nearest pairing and ordering (WP-404)")
struct SectionPairingTests {
    /// A golden section is SciPy's row `b0 b1 b2 a0 a1 a2` with `a0 = 1`. Each coefficient is
    /// held to 1e-9 of the largest coefficient of its own section.
    static func compare(_ sections: SecondOrderSections, _ golden: GoldenCase, key: String = "sos", label: String) throws {
        let rows = try golden.real(key)
        try #require(rows.count % 6 == 0)
        let count = rows.count / 6
        guard sections.sections.count == count else {
            Issue.record("\(golden.name): \(sections.sections.count) sections, \(count) expected")
            return
        }
        for index in 0 ..< count {
            let row = Array(rows[index * 6 ..< index * 6 + 6])
            #expect(row[3] == 1, "the reference normalises a0")
            let expected = [row[0], row[1], row[2], row[4], row[5]]
            let actual = sections.sections[index].coefficients
            let peak = expected.map { abs($0) }.max() ?? 0
            for (a, e) in zip(actual, expected) {
                Measurements.shared.record(label, peak > 0 ? abs(a - e) / peak : abs(a - e), bound: 1e-9)
            }
            expectClose(actual, expected, .relativeToMaximum(1e-9), "\(golden.name), section \(index)")
        }
    }

    @Test func thePairingMatchesTheReferenceSectionForSection() throws {
        let file = try Golden.sectionPairing.get()
        #expect(file.cases.count == 27)
        for golden in file.cases {
            let system = ZeroPoleGain(zeros: try golden.complexes("zeros"), poles: try golden.complexes("poles"),
                                      gain: try golden.scalar("gain"), domain: .digital)
            let sections = try system.secondOrderSections()
            #expect(sections.sections.count == (try golden.integer("sections")), "\(golden.name)")
            try Self.compare(sections, golden, label: "WP-404 section coefficients against zpk2sos, relative to the section's largest")
        }
    }

    @Test func theCascadeIsTheSystemItWasMadeFrom() throws {
        let file = try Golden.sectionPairing.get()
        let frequencies = (1 ..< 200).map { Double($0) * .pi / 200 }
        for golden in file.cases {
            let system = ZeroPoleGain(zeros: try golden.complexes("zeros"), poles: try golden.complexes("poles"),
                                      gain: try golden.scalar("gain"), domain: .digital)
            let sections = try system.secondOrderSections()
            // Padding with roots at the origin changes the delay, not the magnitude.
            let fromRoots = try system.magnitudeResponse(at: frequencies)
            let fromSections = try sections.magnitudeResponse(at: frequencies)
            let peak = try #require(fromRoots.max())
            for (a, e) in zip(fromSections, fromRoots) {
                #expect(abs(a - e) <= 1e-10 * peak, "\(golden.name)")
            }
        }
    }

    @Test func thePolesClosestToTheUnitCircleComeLast() throws {
        let file = try Golden.sectionPairing.get()
        for golden in file.cases where try golden.string("family") != "hand-made" {
            let system = ZeroPoleGain(zeros: try golden.complexes("zeros"), poles: try golden.complexes("poles"),
                                      gain: try golden.scalar("gain"), domain: .digital)
            let sections = try system.secondOrderSections()
            // The distance of each section's nearest pole from the unit circle never grows.
            let distances = sections.sections.map { section in
                SecondOrderSections(sections: [section]).poles.map { abs(1 - $0.magnitude) }.min() ?? 1
            }
            for (earlier, later) in zip(distances, distances.dropFirst()) {
                #expect(later <= earlier + 1e-15, "\(golden.name): \(distances)")
            }
        }
    }

    @Test func theGainGoesIntoTheFirstSection() throws {
        let system = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 6, domain: .digital(sampleRate: 48_000)).zeroPoleGain
        let sections = try system.secondOrderSections().sections
        #expect(sections.count == 3)
        #expect(sections[0].b0 == system.gain)
        expectClose([sections[0].b1, sections[0].b2], [2 * system.gain, system.gain], .relative(1e-15))
        for section in sections.dropFirst() {
            expectClose([section.b0, section.b1, section.b2], [1, 2, 1], .relative(1e-15))
        }
    }

    @Test func aSystemWithoutRootsIsOneGainSection() throws {
        let sections = try ZeroPoleGain(zeros: [], poles: [], gain: -2.5, domain: .digital).secondOrderSections()
        #expect(sections.sections == [.init(b0: -2.5, b1: 0, b2: 0, a1: 0, a2: 0)])
    }

    @Test func anOddOrderGetsAFirstOrderSection() throws {
        let system = ZeroPoleGain(zeros: [Complex(-1)], poles: [Complex(0.5)], gain: 0.25, domain: .digital)
        let sections = try system.secondOrderSections().sections
        // (z + 1)·z / ((z − 0.5)·z): the padding roots at the origin leave b2 = a2 = 0.
        #expect(sections == [.init(b0: 0.25, b1: 0.25, b2: 0, a1: -0.5, a2: 0)])
        let back = SecondOrderSections(sections: sections).zeroPoleGain()
        #expect(back == system, "and they cancel again when the section is read")
    }

    /// The stress test of §7.5 row 3/4 for the pairing: a low cutoff at high order, drawn from
    /// the fixture library. Forming the cascade keeps the poles; expanding the same system
    /// into one polynomial and finding its roots again loses them. That is what the pairing
    /// in zero-pole form is for.
    @Test func stressSectionsKeepThePolesThatAnExpandedPolynomialLoses() throws {
        let fixture = try #require(StressFixture.filtersNearZero.first { $0.name == "hp-20Hz-96k-order8" })
        let design = try IIRDesign(.butterworth, .highPass(cutoff: fixture.cutoff), order: fixture.order,
                                   domain: .digital(sampleRate: fixture.sampleRate))
        let system = design.zeroPoleGain
        let sections = try system.secondOrderSections()

        // Read back from the sections, in closed form: the poles are those of the design.
        let fromSections = try #require(expectRootsClose(sections.poles, system.poles, relative: 1e-9, "poles read from the sections",
                                                         measure: "WP-404 stress hp-20Hz-96k-order8: poles read back from sections, relative"))
        #expect(fromSections < 1e-12)

        // The hazard: the same poles through an expanded denominator.
        let expanded = try system.transferFunction().poles
        let fromPolynomial = RootMatching.bottleneck(expanded, system.poles)
        Measurements.shared.record("WP-404 stress hp-20Hz-96k-order8: poles through the expanded polynomial, relative (hazard)", fromPolynomial, bound: 1e-9)
        #expect(fromPolynomial > 1e-6, "an expanded order-8 denominator at 20 Hz / 96 kHz cannot return its poles: off by \(fromPolynomial)")

        // And the cascade is stable where it matters, with the margin of the design.
        #expect(try sections.isStable)
        expectClose(sections.stabilityMargin, try system.stabilityMargin, .relative(1e-9))
    }

    /// Ordering: with the sections in the order the pairing gives, no partial cascade has a
    /// gain above the filter's own peak; with the order reversed the sharpest resonance comes
    /// first and overshoots.
    @Test func stressTheOrderingKeepsPartialCascadesBelowThePeak() throws {
        let fixture = try #require(StressFixture.filtersNearZero.first { $0.name == "hp-90Hz-48k-order8" })
        let design = try IIRDesign(.butterworth, .highPass(cutoff: fixture.cutoff), order: fixture.order,
                                   domain: .digital(sampleRate: fixture.sampleRate))
        let sections = try design.secondOrderSections.sections
        // Normalise each section's gain so that the comparison is about resonances only.
        let frequencies = (1 ... 2_000).map { fixture.normalizedAngle * 4 * Double($0) / 2_000 }
        func worstPartialPeak(_ order: [SecondOrderSections.Section]) throws -> Double {
            var worst = 0.0
            for count in 1 ... order.count {
                let partial = order.prefix(count).map { SecondOrderSections.Section(b0: 1, b1: $0.b1 / $0.b0, b2: $0.b2 / $0.b0, a1: $0.a1, a2: $0.a2) }
                let cascade = SecondOrderSections(sections: Array(partial))
                // A high-pass section with b = [1, −2, 1] has gain 4/(1 − a1 + a2) at Nyquist.
                let nyquist = try cascade.magnitudeResponse(at: [.pi])[0]
                let peak = try #require(try cascade.magnitudeResponse(at: frequencies).max())
                worst = max(worst, peak / nyquist)
            }
            return worst
        }
        let asPaired = try worstPartialPeak(sections)
        let reversed = try worstPartialPeak(sections.reversed())
        Measurements.shared.record("WP-404 stress hp-90Hz-48k-order8: worst partial-cascade peak, as ordered", asPaired, bound: 1.01)
        Measurements.shared.record("WP-404 stress hp-90Hz-48k-order8: worst partial-cascade peak, order reversed (hazard)", reversed, bound: 1.01)
        #expect(asPaired <= 1.01, "a partial cascade overshoots by \(asPaired)")
        #expect(reversed > 2, "with the sharpest section first the overshoot is \(reversed)")
    }
}
