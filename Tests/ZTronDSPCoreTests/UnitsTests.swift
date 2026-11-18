import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("Frequency (WP-101)")
struct FrequencyTests {
    private func ulp(_ value: Double) -> Double { value.ulp }

    @Test func linearUnitsRoundTripToOneUlp() throws {
        var generator = SeededGenerator(seed: 101)
        for rate in [8_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            for _ in 0 ..< 200 {
                let hertz = generator.nextUnit() * rate / 2
                let normalized = try Frequency.hertz(hertz).normalized(sampleRate: rate)
                let back = try Frequency.normalized(normalized).hertz(sampleRate: rate)
                #expect(abs(back - hertz) <= ulp(hertz), "hertz → normalized → hertz at \(rate)")

                let fraction = try Frequency.hertz(hertz).fractionOfNyquist(sampleRate: rate)
                #expect(abs(try Frequency.fractionOfNyquist(fraction).hertz(sampleRate: rate) - hertz) <= ulp(hertz))

                let radians = try Frequency.hertz(hertz).radiansPerSample(sampleRate: rate)
                #expect(abs(try Frequency.radiansPerSample(radians).hertz(sampleRate: rate) - hertz) <= 2 * ulp(hertz))
            }
        }
    }

    @Test func aUnitResolvedInItselfIsExact() throws {
        #expect(try Frequency.hertz(1_234.5).hertz(sampleRate: 48_000) == 1_234.5)
        #expect(try Frequency.normalized(0.123).normalized(sampleRate: 48_000) == 0.123)
        #expect(try Frequency.fractionOfNyquist(0.321).fractionOfNyquist(sampleRate: 48_000) == 0.321)
        #expect(try Frequency.radiansPerSample(1.5).radiansPerSample(sampleRate: 48_000) == 1.5)
        #expect(try Frequency.midiNote(61.5).midiNote(sampleRate: 48_000) == 61.5)
        #expect(try Frequency.mel(12.5).mel(sampleRate: 48_000) == 12.5)
        #expect(try Frequency.mel(1_200, formula: .htk).mel(sampleRate: 48_000, formula: .htk) == 1_200)
        // Half a cycle per sample is the whole of Nyquist, exactly.
        #expect(try Frequency.normalized(0.25).fractionOfNyquist(sampleRate: 44_100) == 0.5)
        #expect(try Frequency.fractionOfNyquist(0.5).normalized(sampleRate: 44_100) == 0.25)
    }

    @Test func knownValues() throws {
        #expect(try Frequency.midiNote(69).hertz(sampleRate: 48_000) == 440)
        expectClose(try Frequency.midiNote(60).hertz(sampleRate: 48_000), 261.6255653005986, .relative(1e-14))
        expectClose(try Frequency.midiNote(24).hertz(sampleRate: 48_000), 32.70319566257483, .relative(1e-14))
        #expect(try Frequency.normalized(0.5).hertz(sampleRate: 48_000) == 24_000)
        #expect(try Frequency.fractionOfNyquist(1).hertz(sampleRate: 44_100) == 22_050)
        expectClose(try Frequency.radiansPerSample(.pi).hertz(sampleRate: 48_000), 24_000, .relative(1e-15))
        #expect(try Frequency.mel(15).hertz(sampleRate: 48_000) == 1_000, "1 000 Hz is 15 mel (Slaney)")
        #expect(try Frequency.hertz(1_000).mel(sampleRate: 48_000) == 15)
        expectClose(try Frequency.hertz(1_000).mel(sampleRate: 48_000, formula: .htk), 999.9855, .absolute(1e-3))
    }

    @Test func logarithmicUnitsRoundTripWithinTenToTheMinusFourteen() throws {
        var generator = SeededGenerator(seed: 102)
        for _ in 0 ..< 500 {
            let note = generator.nextUnit() * 127
            let hertz = try Frequency.midiNote(note).hertz(sampleRate: 48_000)
            expectClose(try Frequency.hertz(hertz).midiNote(sampleRate: 48_000), note, .absolute(1e-12))
            expectClose(try Frequency.midiNote(try Frequency.hertz(hertz).midiNote(sampleRate: 48_000)).hertz(sampleRate: 48_000), hertz, .relative(1e-14))

            let mel = generator.nextUnit() * 60
            let melHertz = try Frequency.mel(mel).hertz(sampleRate: 48_000)
            expectClose(try Frequency.mel(try Frequency.hertz(melHertz).mel(sampleRate: 48_000)).hertz(sampleRate: 48_000), melHertz, .relative(1e-14))
            let htkHertz = try Frequency.mel(mel * 60, formula: .htk).hertz(sampleRate: 48_000)
            expectClose(try Frequency.mel(try Frequency.hertz(htkHertz).mel(sampleRate: 48_000, formula: .htk), formula: .htk).hertz(sampleRate: 48_000), htkHertz, .relative(1e-14))
        }
    }

    @Test func aNegativeOrNonFiniteValueIsATypedError() {
        let bad: [Frequency] = [.hertz(-1), .hertz(.nan), .hertz(.infinity), .normalized(-0.1), .normalized(.nan),
                                .fractionOfNyquist(-0.5), .radiansPerSample(-.pi), .midiNote(.nan), .midiNote(.infinity),
                                .mel(-3), .mel(.nan), .mel(-10, formula: .htk)]
        for frequency in bad {
            #expect(throws: DSPError.self, "\(frequency)") { try frequency.hertz(sampleRate: 48_000) }
            #expect(throws: DSPError.self, "\(frequency)") { try frequency.normalized(sampleRate: 48_000) }
            #expect(throws: DSPError.self, "\(frequency)") { try frequency.fractionOfNyquist(sampleRate: 48_000) }
            #expect(throws: DSPError.self, "\(frequency)") { try frequency.radiansPerSample(sampleRate: 48_000) }
        }
        for rate in [0.0, -48_000, .nan, .infinity] {
            #expect(throws: DSPError.self) { try Frequency.hertz(100).hertz(sampleRate: rate) }
        }
        #expect(throws: DSPError.self) { try Frequency.hertz(0).midiNote(sampleRate: 48_000) }
        do {
            _ = try Frequency.hertz(-5).hertz(sampleRate: 48_000)
        } catch {
            guard case .invalidParameter(_, let parameter, let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(parameter == "frequency")
            #expect(reason.contains("-5.0 Hz"))
        }
    }

    @Test func zeroHertzIsAFrequency() throws {
        #expect(try Frequency.hertz(0).hertz(sampleRate: 48_000) == 0)
        #expect(try Frequency.hertz(0).normalized(sampleRate: 48_000) == 0)
        #expect(try Frequency.midiNote(-12).hertz(sampleRate: 48_000) > 0, "a negative note number is a low note")
    }

    @Test func valueSemantics() {
        #expect(Frequency.hertz(440) == Frequency.hertz(440))
        #expect(Frequency.hertz(440) != Frequency.hertz(441))
        #expect(Frequency.hertz(440) != Frequency.midiNote(69), "a frequency keeps the unit it was stated in")
        #expect(Frequency.mel(15) == Frequency.mel(15, formula: .slaney))
        #expect(Frequency.mel(15) != Frequency.mel(15, formula: .htk))
        #expect(Set([Frequency.hertz(1), .hertz(1), .normalized(1)]).count == 2)
        #expect(Frequency.hertz(90).value == 90)
        #expect(!Frequency.hertz(90).dependsOnSampleRate)
        #expect(!Frequency.midiNote(60).dependsOnSampleRate)
        #expect(!Frequency.mel(10).dependsOnSampleRate)
        #expect(Frequency.normalized(0.1).dependsOnSampleRate)
        #expect(Frequency.fractionOfNyquist(0.1).dependsOnSampleRate)
        #expect(Frequency.radiansPerSample(0.1).dependsOnSampleRate)
        let all: [Frequency] = [.hertz(1), .normalized(0.1), .fractionOfNyquist(0.2), .radiansPerSample(0.3), .midiNote(60), .mel(5)]
        #expect(Set(all.map(\.description)).count == 6)
    }

    @Test func animatableValuesGlideInPitch() {
        // One octave is one unit, in every linear unit and for MIDI notes.
        #expect(Frequency.hertz(2_000).animatableValue - Frequency.hertz(1_000).animatableValue == 1)
        #expect(Frequency.normalized(0.25).animatableValue - Frequency.normalized(0.125).animatableValue == 1)
        #expect(Frequency.midiNote(72).animatableValue - Frequency.midiNote(60).animatableValue == 1)
        #expect(Frequency.mel(20).animatableValue == 20)
        #expect(Frequency.hertz(0).animatableValue.isFinite)

        let cutoff = Frequency.hertz(1_000)
        #expect(cutoff.replacing(animatableValue: cutoff.animatableValue) == cutoff, "the round trip is the identity")
        expectClose(cutoff.replacing(animatableValue: cutoff.animatableValue + 1).value, 2_000, .relative(1e-12))
        #expect(Frequency.midiNote(60).replacing(animatableValue: 6) == .midiNote(72))
        #expect(Frequency.mel(10).replacing(animatableValue: 12) == .mel(12))
        #expect(Frequency.mel(10, formula: .htk).replacing(animatableValue: 12) == .mel(12, formula: .htk))
        let odd = Frequency.fractionOfNyquist(0.3)
        #expect(odd.replacing(animatableValue: odd.animatableValue) == odd)
    }
}

@Suite("Mel formulas")
struct MelFormulaTests {
    @Test func slaneyIsLinearBelowOneKilohertzAndLogarithmicAbove() {
        #expect(DSP.mel(fromHertz: 0) == 0)
        #expect(DSP.mel(fromHertz: 200) == 3)
        #expect(DSP.mel(fromHertz: 1_000) == 15)
        expectClose(DSP.mel(fromHertz: 6_400), 42, .relative(1e-14))
        #expect(DSP.hertz(fromMel: 15) == 1_000)
        expectClose(DSP.hertz(fromMel: 42), 6_400, .relative(1e-14))
    }

    @Test func htkMatchesItsDefinition() {
        #expect(DSP.mel(fromHertz: 0, formula: .htk) == 0)
        expectClose(DSP.mel(fromHertz: 700, formula: .htk), 2_595 * log10(2.0), .relative(1e-15))
        expectClose(DSP.hertz(fromMel: 2_595 * log10(2.0), formula: .htk), 700, .relative(1e-14))
    }

    @Test func conversionsRoundTripWithinTenToTheMinusNine() {
        let grid = stride(from: 0.0, through: 24_000, by: 37.5).map { $0 }
        expectClose(DSP.hertz(fromMel: DSP.mel(fromHertz: grid)), grid, .relative(1e-9))
        expectClose(DSP.hertz(fromMel: DSP.mel(fromHertz: grid, formula: .htk), formula: .htk), grid.map { max($0, 0) }, .absolute(1e-8))
        for hertz in grid.dropFirst() {
            expectClose(DSP.hertz(fromMel: DSP.mel(fromHertz: hertz, formula: .htk), formula: .htk), hertz, .relative(1e-9))
        }
    }

    @Test func bothFormulasAreMonotonic() {
        var previousSlaney = -1.0, previousHTK = -1.0
        for hertz in stride(from: 0.0, through: 22_050, by: 10) {
            let slaney = DSP.mel(fromHertz: hertz), htk = DSP.mel(fromHertz: hertz, formula: .htk)
            #expect(slaney > previousSlaney)
            #expect(htk > previousHTK)
            previousSlaney = slaney
            previousHTK = htk
        }
    }

    @Test func aFormulaWrittenOutsideThePackageIsPassedTheSameWay() throws {
        struct Octaves: MelFormula {
            func mel(fromHertz hertz: Double) -> Double { log2(hertz / 55) }
            func hertz(fromMel mel: Double) -> Double { 55 * pow(2, mel) }
        }
        #expect(DSP.hertz(fromMel: 3, formula: Octaves()) == 440)
        #expect(try Frequency.mel(3, formula: Octaves()).hertz(sampleRate: 48_000) == 440)
        #expect(Frequency.mel(3, formula: Octaves()) != Frequency.mel(3))
    }
}

@Suite("Amplification and decibels (WP-102)")
struct AmplificationTests {
    @Test(arguments: [
        (1.0, 0.0), (10.0, 20.0), (0.1, -20.0), (2.0, 6.020599913279624), (0.5, -6.020599913279624),
        (1e-8, -160.0), (0.0, -160.0), (1e-12, -160.0), (-1.0, 0.0), (-0.1, -20.0),
    ])
    func amplitudeDecibelsTable(amplitude: Double, decibels: Double) {
        expectClose(DSP.decibels(fromAmplitude: amplitude), decibels, .absolute(1e-12))
    }

    @Test(arguments: [
        (1.0, 0.0), (10.0, 10.0), (0.1, -10.0), (2.0, 3.010299956639812), (1e-16, -160.0), (0.0, -160.0),
        (1e-30, -160.0), (-1.0, -160.0), (-1e9, -160.0),
    ])
    func powerDecibelsTable(power: Double, decibels: Double) {
        expectClose(DSP.decibels(fromPower: power), decibels, .absolute(1e-12))
    }

    @Test func referenceAndFloorAreHonoured() {
        expectClose(DSP.decibels(fromAmplitude: 2, reference: 2), 0, .absolute(1e-12))
        expectClose(DSP.decibels(fromPower: 4, reference: 2), 3.010299956639812, .absolute(1e-12))
        #expect(DSP.decibels(fromAmplitude: 1e-5, floor: -80) == -80)
        #expect(DSP.decibels(fromAmplitude: 0, floor: -80) == -80)
        #expect(DSP.decibels(fromPower: 0, floor: -90) == -90)
        #expect(DSP.decibels(fromAmplitude: 1, reference: 0) == -160, "a reference that is not positive gives the floor")
        #expect(DSP.decibels(fromPower: 1, reference: -1) == -160)
        #expect(DSP.decibels(fromAmplitude: .nan) == -160, "no NaN comes back (NUM-1)")
        #expect(DSP.decibels(fromPower: .nan) == -160)
        #expect(DSP.decibels(fromAmplitude: .infinity).isFinite)
        #expect(DSP.decibels(fromPower: .infinity).isFinite)
    }

    @Test func inversesUndoTheConversions() {
        for decibels in stride(from: -150.0, through: 60, by: 7.5) {
            expectClose(DSP.decibels(fromAmplitude: DSP.amplitude(fromDecibels: decibels)), decibels, .absolute(1e-10))
            expectClose(DSP.decibels(fromPower: DSP.power(fromDecibels: decibels)), decibels, .absolute(1e-10))
        }
        #expect(DSP.amplitude(fromDecibels: 0) == 1)
        #expect(DSP.power(fromDecibels: 0) == 1)
        expectClose(DSP.amplitude(fromDecibels: 20, reference: 3), 30, .relative(1e-14))
        expectClose(DSP.power(fromDecibels: 20, reference: 3), 300, .relative(1e-14))
    }

    @Test func vectorFormsAgreeWithTheScalarOnes() {
        let amplitudes: [Float] = [1, 10, 0.1, 2, 0.5, 0, -1, -0.1, 1e-9, 3.3e-4, .nan, 123.456]
        let expectedAmplitude = amplitudes.map { Float(DSP.decibels(fromAmplitude: Double($0))) }
        expectClose(DSP.decibels(fromAmplitude: amplitudes), expectedAmplitude, .absolute(2e-5))

        let powers: [Float] = [1, 10, 0.1, 2, 0, -1, 1e-20, 7.7e-6, .nan, 5_000]
        let expectedPower = powers.map { Float(DSP.decibels(fromPower: Double($0))) }
        expectClose(DSP.decibels(fromPower: powers), expectedPower, .absolute(2e-5))

        expectClose(DSP.decibels(fromAmplitude: [1, 1e-6, 0], reference: 2, floor: -90), [-6.0206, -90, -90], .absolute(1e-4))
        expectClose(DSP.decibels(fromPower: [4, 0], reference: 2, floor: -30), [3.0103, -30], .absolute(1e-4))
        #expect(DSP.decibels(fromAmplitude: [1, 2], reference: 0) == [-160, -160])
        #expect(DSP.decibels(fromAmplitude: [Float]()).isEmpty)
        #expect(DSP.decibels(fromPower: [Float]()).isEmpty)
    }

    @Test func vectorInversesUndoTheConversions() {
        let decibels: [Float] = [-120, -60, -20, -6.0206, 0, 6.0206, 20]
        expectClose(DSP.amplitude(fromDecibels: decibels), [1e-6, 1e-3, 0.1, 0.5, 1, 2, 10], .relative(1e-5))
        expectClose(DSP.power(fromDecibels: decibels), [1e-12, 1e-6, 0.01, 0.25, 1, 4, 100], .relative(1e-5))
        expectClose(DSP.amplitude(fromDecibels: [0, 20], reference: 3), [3, 30], .relative(1e-5))
        expectClose(DSP.power(fromDecibels: [0, 10], reference: 3), [3, 30], .relative(1e-5))
        expectClose(DSP.decibels(fromAmplitude: DSP.amplitude(fromDecibels: decibels)), decibels, .absolute(1e-3))
        #expect(DSP.amplitude(fromDecibels: [Float]()).isEmpty)
        #expect(DSP.power(fromDecibels: [Float]()).isEmpty)
    }

    @Test func vectorConversionsWorkInPlaceAndAllocateNothing() {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1_024)
        defer { buffer.deallocate() }
        var index = 0
        while index < 1_024 { buffer[index] = Float(index + 1) / 1_024; index += 1 }
        expectNoAllocations {
            DSP.decibels(fromAmplitude: buffer, into: buffer, count: 1_024)
            DSP.amplitude(fromDecibels: buffer, into: buffer, count: 1_024)
            DSP.decibels(fromPower: buffer, into: buffer, count: 1_024)
            DSP.power(fromDecibels: buffer, into: buffer, count: 1_024)
            DSP.decibels(fromAmplitude: buffer, into: buffer, count: 0)
        }
        expectClose(buffer[1_023], 1, .relative(1e-4))
        expectClose(buffer[511], 0.5, .relative(1e-4))
    }

    @Test func amplificationCarriesItsUnit() {
        #expect(Amplification.linear(2).linear == 2)
        expectClose(Amplification.linear(2).decibels, 6.020599913279624, .absolute(1e-12))
        #expect(Amplification.decibels(-3).decibels == -3)
        expectClose(Amplification.decibels(-3).linear, 0.7079457843841379, .relative(1e-14))
        expectClose(Amplification.decibels(-3).powerRatio, 0.5011872336272722, .relative(1e-14))
        #expect(Amplification.linear(0).decibels == -160, "clamped at the floor, not −∞")
        #expect(Amplification.linear(0).decibels(floor: -100) == -100)
        #expect(Amplification.decibels(-200).decibels == -160)
        #expect(Amplification.decibels(-200).decibels(floor: -300) == -200)
        #expect(Amplification.unity.isUnity)
        #expect(Amplification.decibels(0).isUnity)
        #expect(!Amplification.decibels(0.1).isUnity)
        #expect(Amplification.linear(-1).linear == -1, "a negative factor inverts")
        #expect(Amplification.linear(1) != Amplification.decibels(0), "an amplification keeps the unit it was stated in")
        #expect(Amplification.linear(2).value == 2)
        #expect(Amplification.linear(2).description == "×2.0")
        #expect(Amplification.decibels(-3).description == "-3.0 dB")
    }

    @Test func animatableValuesAreDecibels() {
        #expect(Amplification.decibels(-12).animatableValue == -12)
        expectClose(Amplification.linear(0.5).animatableValue, -6.0206, .absolute(1e-4))
        let gain = Amplification.linear(0.5)
        #expect(gain.replacing(animatableValue: gain.animatableValue) == gain, "the round trip is the identity")
        expectClose(gain.replacing(animatableValue: 0).linear, 1, .relative(1e-12))
        #expect(Amplification.linear(-0.5).replacing(animatableValue: 0).linear == -1, "the sign of a linear factor is kept")
        #expect(Amplification.decibels(-12).replacing(animatableValue: -6) == .decibels(-6))
    }
}

@Suite("Roll-off (WP-103)")
struct RollOffTests {
    @Test(arguments: [(12.0, 2), (24.0, 4), (48.0, 8), (96.0, 16), (6.0, 1), (6.0206, 1), (18.0, 3), (36.0, 6)])
    func decibelsPerOctaveMapToOrders(slope: Double, order: Int) throws {
        #expect(try RollOff.decibelsPerOctave(slope).order() == order)
        #expect(try RollOff.decibelsPerOctave(slope).order(rounding: .nearest) == order)
        #expect(try RollOff.decibelsPerOctave(slope).order(rounding: .up) == order)
    }

    @Test func aSlopeBetweenOrdersThrowsUnderExactAndRoundsOtherwise() throws {
        #expect(throws: DSPError.self) { try RollOff.decibelsPerOctave(25).order() }
        #expect(try RollOff.decibelsPerOctave(25).order(rounding: .up) == 5)
        #expect(try RollOff.decibelsPerOctave(25).order(rounding: .nearest) == 4)
        #expect(try RollOff.decibelsPerOctave(27.5).order(rounding: .nearest) == 5)
        #expect(try RollOff.decibelsPerOctave(24.1).order(rounding: .up) == 5, "four orders are 24.08 dB, short of 24.1")
        #expect(try RollOff.decibelsPerOctave(25).order(rounding: .exact(relativeTolerance: 0.05)) == 4)
        #expect(throws: DSPError.self) { try RollOff.decibelsPerOctave(24).order(rounding: .exact(relativeTolerance: 0.001)) }
        do {
            _ = try RollOff.decibelsPerOctave(25).order()
        } catch {
            guard case .invalidParameter(_, let parameter, let reason) = error else { Issue.record("unexpected \(error)"); return }
            #expect(parameter == "rollOff")
            #expect(reason.contains("24.08") && reason.contains("30.10"), "the reason names the nearest slopes: \(reason)")
        }
    }

    @Test func decadesAndOrdersAreTheSameScale() throws {
        #expect(try RollOff.decibelsPerDecade(80).order() == 4)
        #expect(try RollOff.decibelsPerDecade(20).order() == 1)
        #expect(try RollOff.order(7).order() == 7)
        #expect(RollOff.order(4).decibelsPerDecade == 80)
        expectClose(RollOff.order(4).decibelsPerOctave, 24.08239965311849, .relative(1e-15))
        expectClose(RollOff.decibelsPerDecade(80).decibelsPerOctave, 24.08239965311849, .relative(1e-15))
        expectClose(RollOff.decibelsPerOctave(24.08239965311849).decibelsPerDecade, 80, .relative(1e-15))
        #expect(RollOff.decibelsPerOctave(24).decibelsPerOctave == 24)
        #expect(RollOff.decibelsPerDecade(80).decibelsPerDecade == 80)
        expectClose(RollOff.decibelsPerOctavePerOrder, 6.020599913279624, .relative(1e-15))
        expectClose(RollOff.decibelsPerOctave(24).fractionalOrder, 3.986, .absolute(1e-3))
        #expect(RollOff.decibelsPerDecade(50).fractionalOrder == 2.5)
        #expect(RollOff.order(3).fractionalOrder == 3)
    }

    @Test func slopesThatAreNoFilterAreTypedErrors() throws {
        for slope in [0.0, -24, .nan, .infinity] {
            for rounding in [RollOffRounding.exact(), .nearest, .up] {
                #expect(throws: DSPError.self, "\(slope) under \(rounding)") { try RollOff.decibelsPerOctave(slope).order(rounding: rounding) }
            }
        }
        #expect(throws: DSPError.self) { try RollOff.order(0).order() }
        #expect(throws: DSPError.self) { try RollOff.order(-2).order(rounding: .up) }
        #expect(throws: DSPError.self) { try RollOff.decibelsPerOctave(2).order(rounding: .nearest) }
        #expect(try RollOff.decibelsPerOctave(2).order(rounding: .up) == 1)
        #expect(throws: DSPError.self) { try RollOff.decibelsPerOctave(1e9).order(rounding: .nearest) }
    }

    @Test func valueSemantics() {
        #expect(RollOff.decibelsPerOctave(24) == .decibelsPerOctave(24))
        #expect(RollOff.decibelsPerOctave(24) != .order(4))
        #expect(RollOff.order(4).value == 4)
        #expect(RollOffRounding.exact() == .exact(relativeTolerance: 0.02))
        #expect(RollOffRounding.exact() != .nearest)
        #expect(Set([RollOff.order(4).description, RollOff.decibelsPerOctave(24).description, RollOff.decibelsPerDecade(80).description]).count == 3)
    }
}
