import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-431a. Response values `LowPass`, `HighPass`, `BandPass`, `BandStop` over an IIR family
/// or an FIR method. Acceptance: each resolves to the design its arguments name; value
/// semantics.
@Suite("Response values (WP-431a)")
struct ResponseValueTests {
    let rate = 48_000.0
    let elliptic = EllipticFamily(ripple: .decibels(1), stopband: .decibels(60))

    @Test func anIIRFormResolvesToTheDesignItsArgumentsName() throws {
        let digital = IIRDesign.Domain.digital(sampleRate: rate)
        // By order.
        #expect(try LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).design(sampleRate: rate)
            == .iir(try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain: digital)))
        #expect(try HighPass(.chebyshev1(ripple: .decibels(1)), cutoff: .hertz(90), order: 5).design(sampleRate: rate)
            == .iir(try IIRDesign(.chebyshev1(ripple: .decibels(1)), .highPass(cutoff: 90), order: 5, domain: digital)))
        #expect(try BandPass(elliptic, from: .hertz(300), to: .hertz(3_400), order: 3).design(sampleRate: rate)
            == .iir(try IIRDesign(elliptic, .bandPass(from: 300, to: 3_400), order: 3, domain: digital)))
        #expect(try BandStop(.bessel(normalization: .delay), from: .hertz(45), to: .hertz(55), order: 2).design(sampleRate: rate)
            == .iir(try IIRDesign(.bessel(normalization: .delay), .bandStop(from: 45, to: 55), order: 2, domain: digital)))
        // By roll-off (§6.3.4): 24 dB per octave is order 4; 25 needs a rounding.
        #expect(try LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(24)).design(sampleRate: rate)
            == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).design(sampleRate: rate))
        #expect(try HighPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(25), rounding: .up).design(sampleRate: rate).iir?.order == 5)
        #expect(try BandPass(.butterworth, from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerDecade(40)).design(sampleRate: rate).iir?.order == 2)
        #expect(try BandStop(.chebyshev2(stopband: .decibels(40)), from: .hertz(300), to: .hertz(3_400), rollOff: .order(3)).design(sampleRate: rate).iir?.order == 3)
        #expect(thrownError { _ = try LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(25)).design(sampleRate: rate) }?.invalidParameterName == "rollOff")
        // By tolerance scheme (§6.3.2): the family's order strategy finds the order.
        let scheme = try LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).design(sampleRate: rate)
        #expect(scheme == .iir(try IIRDesign(.butterworth, passband: .lowPass(cutoff: 1_000), stopband: .lowPass(cutoff: 2_000), maximumLoss: .decibels(1),
                                             minimumAttenuation: .decibels(40), domain: digital)))
        #expect(scheme.iir?.order == 8 && scheme.fir == nil)
        let high = try HighPass(.chebyshev1(ripple: .decibels(3)), passband: .hertz(2_000), stopband: .hertz(1_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).design(sampleRate: rate)
        #expect(high == .iir(try IIRDesign(.chebyshev1(ripple: .decibels(3)), passband: .highPass(cutoff: 2_000), stopband: .highPass(cutoff: 1_000),
                                           maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: digital)))
        let band = try BandPass(elliptic, passband: (.hertz(300), .hertz(3_400)), stopband: (.hertz(200), .hertz(4_000)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(60)).design(sampleRate: rate)
        #expect(band == .iir(try IIRDesign(elliptic, passband: .bandPass(from: 300, to: 3_400), stopband: .bandPass(from: 200, to: 4_000), maximumLoss: .decibels(1),
                                           minimumAttenuation: .decibels(60), domain: digital)))
        let notch = try BandStop(.butterworth, passband: (from: .hertz(200), to: .hertz(4_000)), stopband: (from: .hertz(300), to: .hertz(3_400)), maximumLoss: .decibels(1),
                                 minimumAttenuation: .decibels(40)).design(sampleRate: rate)
        #expect(notch == .iir(try IIRDesign(.butterworth, passband: .bandStop(from: 200, to: 4_000), stopband: .bandStop(from: 300, to: 3_400), maximumLoss: .decibels(1),
                                            minimumAttenuation: .decibels(40), domain: digital)))
    }

    @Test func anFIRFormResolvesToTheDesignItsArgumentsName() throws {
        // By length (§6.3.3).
        #expect(try LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(window: .kaiser(beta: 8.6)), .lowPass(cutoff: 4_000), length: 255, sampleRate: rate)))
        #expect(try HighPass(.windowedSinc(), cutoff: .hertz(4_000), length: 101).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), .highPass(cutoff: 4_000), length: 101, sampleRate: rate)))
        #expect(try BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401).design(sampleRate: rate)
            == .fir(try FIRDesign(.leastSquares, .bandPass(from: 300, to: 3_400), length: 401, transition: 200, sampleRate: rate)))
        #expect(try BandStop(.windowedSinc(window: .hann), from: .hertz(3_000), to: .hertz(9_000), length: 101).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(window: .hann), .bandStop(from: 3_000, to: 9_000), length: 101, sampleRate: rate)))
        // By roll-off (§6.3.4).
        let slope = try LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80)).design(sampleRate: rate)
        #expect(slope == .fir(try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80), sampleRate: rate)))
        #expect(slope.fir != nil && slope.iir == nil)
        #expect(try HighPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), .highPass(cutoff: 4_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60), sampleRate: rate)))
        #expect(try BandPass(.windowedSinc(), from: .hertz(1_000), to: .hertz(2_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), .bandPass(from: 1_000, to: 2_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60), sampleRate: rate)))
        #expect(try BandStop(.windowedSinc(), from: .hertz(100), to: .hertz(20_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), .bandStop(from: 100, to: 20_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(60), sampleRate: rate)))
        // By tolerance scheme.
        #expect(try LowPass(.windowedSinc(), passband: .hertz(4_000), stopband: .hertz(5_000), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), passband: .lowPass(cutoff: 4_000), stopband: .lowPass(cutoff: 5_000), maximumLoss: .decibels(0.1),
                                  minimumAttenuation: .decibels(80), sampleRate: rate)))
        #expect(try HighPass(.windowedSinc(), passband: .hertz(5_000), stopband: .hertz(4_000), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), passband: .highPass(cutoff: 5_000), stopband: .highPass(cutoff: 4_000), maximumLoss: .decibels(0.1),
                                  minimumAttenuation: .decibels(80), sampleRate: rate)))
        #expect(try BandPass(.windowedSinc(), passband: (.hertz(300), .hertz(3_400)), stopband: (.hertz(200), .hertz(4_000)), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(60)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), passband: .bandPass(from: 300, to: 3_400), stopband: .bandPass(from: 200, to: 4_000), maximumLoss: .decibels(0.1),
                                  minimumAttenuation: .decibels(60), sampleRate: rate)))
        #expect(try BandStop(.windowedSinc(), passband: (.hertz(200), .hertz(4_000)), stopband: (.hertz(300), .hertz(3_400)), maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(60)).design(sampleRate: rate)
            == .fir(try FIRDesign(.windowedSinc(), passband: .bandStop(from: 200, to: 4_000), stopband: .bandStop(from: 300, to: 3_400), maximumLoss: .decibels(0.1),
                                  minimumAttenuation: .decibels(60), sampleRate: rate)))
    }

    @Test func aFrequencyIsResolvedAgainstTheRateTheStageIsResolvedAt() throws {
        // §6.1: the unit is kept; the number of hertz follows the rate.
        let relative = LowPass(.butterworth, cutoff: .fractionOfNyquist(0.25), order: 4)
        #expect(try relative.design(sampleRate: 48_000) == LowPass(.butterworth, cutoff: .hertz(6_000), order: 4).design(sampleRate: 48_000))
        #expect(try relative.design(sampleRate: 44_100) == LowPass(.butterworth, cutoff: .hertz(5_512.5), order: 4).design(sampleRate: 44_100))
        #expect(try LowPass(.butterworth, cutoff: .midiNote(69), order: 2).design(sampleRate: rate).iir?.response == .lowPass(cutoff: 440))
        #expect(try BandPass(.butterworth, from: .normalized(0.01), to: .radiansPerSample(0.5), order: 2).design(sampleRate: rate).iir?.response
            == .bandPass(from: 480, to: 0.5 / (2 * .pi) * 48_000))
        // What depends on the rate, as an element of a system.
        #expect(LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).dependsOnSampleRate)
        #expect(!relative.dependsOnSampleRate)
        #expect(BandPass(.butterworth, from: .normalized(0.01), to: .hertz(4_000), order: 2).dependsOnSampleRate)
        #expect(LowPass(.windowedSinc(), cutoff: .fractionOfNyquist(0.2), transition: .hertz(100), length: 31).dependsOnSampleRate)
        #expect(!LowPass(.windowedSinc(), passband: .fractionOfNyquist(0.2), stopband: .fractionOfNyquist(0.3), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).dependsOnSampleRate)
        // A value that makes no filter is reported when the stage is resolved, not before.
        let wrong = LowPass(.butterworth, cutoff: .hertz(-5), order: 0)
        #expect(thrownError { _ = try wrong.design(sampleRate: rate) } != nil)
        #expect(thrownError { _ = try LowPass(.bessel(), passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).design(sampleRate: rate) }?.isUnsupportedConfiguration == true)
        #expect(thrownError { _ = try LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).design(sampleRate: 0) }?.invalidParameterName == "sampleRate")
    }

    @Test func theStagesAreValues() throws {
        // Equal arguments, equal values; one argument apart, another value (API-3, IMM-1).
        let base = LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
        #expect(base == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        #expect(base.hashValue == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).hashValue)
        let others: [LowPass] = [
            LowPass(.butterworth, cutoff: .hertz(1_001), order: 4), LowPass(.butterworth, cutoff: .hertz(1_000), order: 5),
            LowPass(.chebyshev1(ripple: .decibels(1)), cutoff: .hertz(1_000), order: 4), LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .order(4)),
            LowPass(.butterworth, cutoff: .fractionOfNyquist(1.0 / 24), order: 4), LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false),
            LowPass(.windowedSinc(), cutoff: .hertz(1_000), length: 31), LowPass(.windowedSinc(window: .hann), cutoff: .hertz(1_000), length: 31),
            LowPass(.windowedSinc(), cutoff: .hertz(1_000), transition: .hertz(100), length: 31), LowPass(.leastSquares, cutoff: .hertz(1_000), transition: .hertz(100), length: 31),
            LowPass(.windowedSinc(), cutoff: .hertz(1_000), rollOff: .order(8), stopband: .decibels(60)),
            LowPass(.windowedSinc(), cutoff: .hertz(1_000), rollOff: .order(8), stopband: .decibels(61)),
            LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)),
            LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(41)),
            LowPass(.windowedSinc(), passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)),
        ]
        #expect(Set(others + [base]).count == others.count + 1, "every one of them is another value")
        // The four responses are four types: the same arguments are not the same stage.
        #expect(Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) } != Pipeline { HighPass(.butterworth, cutoff: .hertz(1_000), order: 4) })
        #expect(Pipeline { BandPass(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) } != Pipeline { BandStop(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) })
        #expect(LowPass.stageName == "LowPass" && BandStop.stageName == "BandStop")
        // A value crosses threads and is the same value there.
        let sendable: any Sendable = base
        #expect(sendable as? LowPass == base)
    }

    @Test func theContinuousValuesAreTheFrequenciesInLogTwoHertz() throws {
        // ANI-2: frequencies as log₂ of the stated number; orders, lengths and strategies are structure.
        #expect(LowPass(.butterworth, cutoff: .hertz(1_024), order: 4).parameters == [10])
        #expect(HighPass(.butterworth, cutoff: .hertz(64), rollOff: .order(2)).parameters == [6])
        #expect(BandPass(.butterworth, from: .hertz(256), to: .hertz(4_096), order: 2).parameters == [8, 12])
        #expect(BandStop(.windowedSinc(), from: .hertz(256), to: .hertz(4_096), transition: .hertz(128), length: 101).parameters == [8, 12, 7])
        #expect(LowPass(.windowedSinc(), cutoff: .hertz(1_024), rollOff: .order(8), stopband: .decibels(60)).parameters == [10])
        #expect(LowPass(.butterworth, passband: .hertz(1_024), stopband: .hertz(2_048), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).parameters == [10, 11])
        #expect(BandPass(.butterworth, passband: (.hertz(512), .hertz(1_024)), stopband: (.hertz(256), .hertz(2_048)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).parameters
            == [9, 10, 8, 11])
        // Replacing: the stage's own values give the stage, bit for bit; other values, the stage at those frequencies.
        let stages: [any StageValue] = [
            LowPass(.butterworth, cutoff: .hertz(997), order: 4), HighPass(.windowedSinc(), cutoff: .fractionOfNyquist(0.123), length: 31),
            BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401),
            BandStop(.butterworth, passband: (.hertz(200), .hertz(4_000)), stopband: (.hertz(300), .hertz(3_400)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)),
        ]
        for stage in stages {
            func same<S: StageValue>(_ stage: S) -> Bool { stage.replacingParameters(stage.parameters[...]) == stage }
            let unchanged = same(stage)
            #expect(unchanged, "\(type(of: stage))")
        }
        let moved = LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false).replacingParameters([11][...])
        #expect(moved == LowPass(.butterworth, cutoff: .hertz(2_048), order: 4, isActive: false), "the switch and the structure stay")
        let band = BandPass(.windowedSinc(), from: .hertz(256), to: .hertz(4_096), transition: .hertz(128), length: 101).replacingParameters([9, 11, 6][...])
        #expect(band == BandPass(.windowedSinc(), from: .hertz(512), to: .hertz(2_048), transition: .hertz(64), length: 101))
        let scheme = LowPass(.butterworth, passband: .hertz(1_024), stopband: .hertz(2_048), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)).replacingParameters([9, 10][...])
        #expect(scheme == LowPass(.butterworth, passband: .hertz(512), stopband: .hertz(1_024), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)))
        // A vector of another length belongs to another stage and changes nothing.
        #expect(LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).replacingParameters([1, 2][...]) == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        // In a pipeline: one vector, in the order of the stages; halfway in pitch is the geometric mean.
        let from = Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4); HighPass(.butterworth, cutoff: .hertz(100), order: 2) }
        let to = Pipeline { LowPass(.butterworth, cutoff: .hertz(4_000), order: 4); HighPass(.butterworth, cutoff: .hertz(25), order: 2) }
        let halfway = from.replacingParameters(from.parameters + (to.parameters - from.parameters).scaled(by: 0.5))
        expectClose(halfway.parameters.values, [log2(2_000.0), log2(50.0)], .absolute(1e-12))
    }

    @Test func theFluentSpellingAndTheBuilderGiveEqualPipelines() throws {
        // API-1, for every initialiser of the four stages.
        let on = StateBox(true)
        #expect(Pipeline().lowPass(.butterworth, cutoff: .hertz(1_000), order: 4) == Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) })
        #expect(Pipeline().lowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .order(4), rounding: .nearest, isActive: false)
            == Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .order(4), rounding: .nearest, isActive: false) })
        #expect(Pipeline().lowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })
        #expect(Pipeline().lowPass(.windowedSinc(), cutoff: .hertz(1_000), transition: .hertz(100), length: 31) == Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(1_000), transition: .hertz(100), length: 31) })
        #expect(Pipeline().lowPass(.windowedSinc(), cutoff: .hertz(1_000), rollOff: .order(8), stopband: .decibels(60)) == Pipeline { LowPass(.windowedSinc(), cutoff: .hertz(1_000), rollOff: .order(8), stopband: .decibels(60)) })
        #expect(Pipeline().lowPass(.windowedSinc(), passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { LowPass(.windowedSinc(), passband: .hertz(1_000), stopband: .hertz(2_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })

        #expect(Pipeline().highPass(.butterworth, cutoff: .hertz(90), order: 4, isActive: on.binding) == Pipeline { HighPass(.butterworth, cutoff: .hertz(90), order: 4, isActive: on.binding) })
        #expect(Pipeline().highPass(.butterworth, cutoff: .hertz(90), rollOff: .order(4)) == Pipeline { HighPass(.butterworth, cutoff: .hertz(90), rollOff: .order(4)) })
        #expect(Pipeline().highPass(.butterworth, passband: .hertz(2_000), stopband: .hertz(1_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { HighPass(.butterworth, passband: .hertz(2_000), stopband: .hertz(1_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })
        #expect(Pipeline().highPass(.windowedSinc(), cutoff: .hertz(90), length: 31) == Pipeline { HighPass(.windowedSinc(), cutoff: .hertz(90), length: 31) })
        #expect(Pipeline().highPass(.windowedSinc(), cutoff: .hertz(90), rollOff: .order(8), stopband: .decibels(60)) == Pipeline { HighPass(.windowedSinc(), cutoff: .hertz(90), rollOff: .order(8), stopband: .decibels(60)) })
        #expect(Pipeline().highPass(.windowedSinc(), passband: .hertz(2_000), stopband: .hertz(1_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { HighPass(.windowedSinc(), passband: .hertz(2_000), stopband: .hertz(1_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })

        #expect(Pipeline().bandPass(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) == Pipeline { BandPass(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) })
        #expect(Pipeline().bandPass(.butterworth, from: .hertz(300), to: .hertz(900), rollOff: .order(2)) == Pipeline { BandPass(.butterworth, from: .hertz(300), to: .hertz(900), rollOff: .order(2)) })
        #expect(Pipeline().bandPass(.butterworth, passband: (.hertz(300), .hertz(900)), stopband: (.hertz(200), .hertz(1_200)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { BandPass(.butterworth, passband: (.hertz(300), .hertz(900)), stopband: (.hertz(200), .hertz(1_200)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })
        #expect(Pipeline().bandPass(.leastSquares, from: .hertz(300), to: .hertz(900), transition: .hertz(100), length: 101) == Pipeline { BandPass(.leastSquares, from: .hertz(300), to: .hertz(900), transition: .hertz(100), length: 101) })
        #expect(Pipeline().bandPass(.windowedSinc(), from: .hertz(300), to: .hertz(900), rollOff: .order(8), stopband: .decibels(60)) == Pipeline { BandPass(.windowedSinc(), from: .hertz(300), to: .hertz(900), rollOff: .order(8), stopband: .decibels(60)) })
        #expect(Pipeline().bandPass(.windowedSinc(), passband: (.hertz(300), .hertz(900)), stopband: (.hertz(200), .hertz(1_200)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { BandPass(.windowedSinc(), passband: (.hertz(300), .hertz(900)), stopband: (.hertz(200), .hertz(1_200)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })

        #expect(Pipeline().bandStop(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) == Pipeline { BandStop(.butterworth, from: .hertz(300), to: .hertz(900), order: 2) })
        #expect(Pipeline().bandStop(.butterworth, from: .hertz(300), to: .hertz(900), rollOff: .order(2)) == Pipeline { BandStop(.butterworth, from: .hertz(300), to: .hertz(900), rollOff: .order(2)) })
        #expect(Pipeline().bandStop(.butterworth, passband: (.hertz(200), .hertz(1_200)), stopband: (.hertz(300), .hertz(900)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { BandStop(.butterworth, passband: (.hertz(200), .hertz(1_200)), stopband: (.hertz(300), .hertz(900)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })
        #expect(Pipeline().bandStop(.windowedSinc(), from: .hertz(300), to: .hertz(900), length: 101) == Pipeline { BandStop(.windowedSinc(), from: .hertz(300), to: .hertz(900), length: 101) })
        #expect(Pipeline().bandStop(.windowedSinc(), from: .hertz(300), to: .hertz(900), rollOff: .order(8), stopband: .decibels(60)) == Pipeline { BandStop(.windowedSinc(), from: .hertz(300), to: .hertz(900), rollOff: .order(8), stopband: .decibels(60)) })
        #expect(Pipeline().bandStop(.windowedSinc(), passband: (.hertz(200), .hertz(1_200)), stopband: (.hertz(300), .hertz(900)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
            == Pipeline { BandStop(.windowedSinc(), passband: (.hertz(200), .hertz(1_200)), stopband: (.hertz(300), .hertz(900)), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) })
        // The switch is part of the description: a bound one differs from every constant (ACT-12).
        #expect(Pipeline().lowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: on.binding) != Pipeline().lowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        #expect(LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: on.binding).activation.isBound)
    }

    @Test func aResponseIsAnElementOfTheSystemItsDesignBelongsTo() throws {
        let iir = BandPass(.butterworth, from: .hertz(300), to: .hertz(3_400), order: 3)
        let system = try iir.zeroPoleGain(sampleRate: rate)
        #expect(system == (try IIRDesign(.butterworth, .bandPass(from: 300, to: 3_400), order: 3, domain: .digital(sampleRate: rate))).zeroPoleGain)
        #expect(thrownError { _ = try iir.taps(sampleRate: rate) }?.invalidParameterReason?.contains("pole") == true, "an IIR form has poles away from the origin")
        let fir = BandPass(.windowedSinc(), from: .hertz(300), to: .hertz(3_400), length: 101)
        #expect(try fir.taps(sampleRate: rate) == FIRDesign(.windowedSinc(), .bandPass(from: 300, to: 3_400), length: 101, sampleRate: rate).taps)
        #expect(thrownError { _ = try fir.zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "method")
    }
}

/// WP-431b. Equaliser values `BandBoost`, `LowShelf`, `HighShelf`. Acceptance: each resolves
/// to its design; the bandwidth forms of §6.3.5; a band past the limit is rejected.
@Suite("Equaliser values (WP-431b)")
struct EqualizerValueTests {
    let rate = 48_000.0

    @Test func eachResolvesToItsDesign() throws {
        #expect(try BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1)).design(sampleRate: rate)
            == EqualizerDesign.bandBoost(center: 2_800, gain: .decibels(4), bandwidth: .octaves(1), order: 1, sampleRate: rate))
        #expect(try BandBoost(center: .hertz(2_800), gain: .decibels(-9), bandwidth: .hertz(700), order: 4).design(sampleRate: rate)
            == EqualizerDesign.bandBoost(center: 2_800, gain: .decibels(-9), bandwidth: .hertz(700), order: 4, sampleRate: rate))
        #expect(try BandBoost(center: .hertz(2_800), gain: .linear(2), bandwidth: .q(3), rollOff: .decibelsPerOctave(24)).design(sampleRate: rate)
            == EqualizerDesign.bandBoost(center: 2_800, gain: .linear(2), bandwidth: .q(3), order: 4, sampleRate: rate))
        #expect(try BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .q(3), rollOff: .decibelsPerOctave(20), rounding: .nearest).design(sampleRate: rate)
            == EqualizerDesign.bandBoost(center: 2_800, gain: .decibels(4), bandwidth: .q(3), order: 3, sampleRate: rate))
        #expect(try LowShelf(midpoint: .hertz(200), gain: .decibels(3)).design(sampleRate: rate)
            == EqualizerDesign.lowShelf(midpoint: 200, gain: .decibels(3), slope: .slope(1), sampleRate: rate))
        #expect(try LowShelf(midpoint: .hertz(200), gain: .decibels(-6), slope: .q(0.9)).design(sampleRate: rate)
            == EqualizerDesign.lowShelf(midpoint: 200, gain: .decibels(-6), slope: .q(0.9), sampleRate: rate))
        #expect(try HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3), slope: .slope(0.5)).design(sampleRate: rate)
            == EqualizerDesign.highShelf(midpoint: 6_000, gain: .decibels(-3), slope: .slope(0.5), sampleRate: rate))
        #expect(try MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .octaves(1)).design(sampleRate: rate)
            == MatchedPeakDesign(center: 12_000, gain: .decibels(6), bandwidth: .octaves(1), sampleRate: rate))
        // The centre follows the rate when its unit does.
        #expect(try BandBoost(center: .fractionOfNyquist(0.25), gain: .decibels(4), bandwidth: .octaves(1)).design(sampleRate: 44_100)
            == EqualizerDesign.bandBoost(center: 5_512.5, gain: .decibels(4), bandwidth: .octaves(1), sampleRate: 44_100))
        // As elements of an IIR system: the design's zeros and poles.
        #expect(try BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 3).zeroPoleGain(sampleRate: rate)
            == EqualizerDesign.bandBoost(center: 2_800, gain: .decibels(4), bandwidth: .octaves(1), order: 3, sampleRate: rate).zeroPoleGain)
        #expect(try HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3)).zeroPoleGain(sampleRate: rate)
            == EqualizerDesign.highShelf(midpoint: 6_000, gain: .decibels(-3), sampleRate: rate).zeroPoleGain)
    }

    /// The two frequencies at which a design has half its gain in decibels, by bisection on its
    /// response, in hertz.
    private func halfGainEdges(_ system: some LTISystem, center: Double, gain: Double) throws -> (Double, Double) {
        func level(_ hertz: Double) throws -> Double {
            try system.magnitudeResponse(at: [2 * .pi * hertz / rate], in: .decibels)[0] - gain / 2
        }
        func crossing(_ inside: Double, _ outside: Double) throws -> Double {
            var a = inside, b = outside
            for _ in 0 ..< 200 {
                let middle = (a + b) / 2
                if try level(middle) * gain > 0 { a = middle } else { b = middle }
            }
            return (a + b) / 2
        }
        return (try crossing(center, 1e-3), try crossing(center, rate / 2 - 1e-3))
    }

    @Test func theThreeBandwidthFormsMeanWhatTheySay() throws {
        // §6.3.5: the width is measured between the frequencies of half the gain in decibels.
        for order in [1, 2, 5] {
            for gain in [6.0, -12] {
                // `.hertz(w)`: met exactly on the digital axis.
                let hertz = try BandBoost(center: .hertz(3_000), gain: .decibels(gain), bandwidth: .hertz(900), order: order).design(sampleRate: rate)
                let edges = try halfGainEdges(hertz.zeroPoleGain, center: 3_000, gain: gain)
                expectClose(edges.1 - edges.0, 900.0, .relative(1e-8), "order \(order), \(gain) dB, 900 Hz")
                // `.octaves(b)`: the width in hertz of b octaves around the centre, then met exactly.
                let octaves = try BandBoost(center: .hertz(3_000), gain: .decibels(gain), bandwidth: .octaves(0.5), order: order).design(sampleRate: rate)
                let width = 3_000 * (pow(2, 0.25) - pow(2, -0.25))
                let octaveEdges = try halfGainEdges(octaves.zeroPoleGain, center: 3_000, gain: gain)
                expectClose(octaveEdges.1 - octaveEdges.0, width, .relative(1e-8), "order \(order), \(gain) dB, half an octave")
                #expect(octaves == (try BandBoost(center: .hertz(3_000), gain: .decibels(gain), bandwidth: .hertz(width), order: order).design(sampleRate: rate)))
            }
        }
        // `.q(Q)`: the Cookbook's definition, α = sin ω₀ / 2Q, which is tan(Δω/2) of the width.
        let q = try BandBoost(center: .hertz(3_000), gain: .decibels(6), bandwidth: .q(4)).design(sampleRate: rate)
        let qEdges = try halfGainEdges(q.zeroPoleGain, center: 3_000, gain: 6)
        let omega = 2 * Double.pi * 3_000 / rate
        expectClose(tan(Double.pi * (qEdges.1 - qEdges.0) / rate), sin(omega) / 8, .relative(1e-8))
        // The matched peak: `.hertz` and `.octaves` exactly, `.q` the quality of the analog prototype.
        let matched = try MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .hertz(3_000)).design(sampleRate: rate)
        let matchedEdges = try halfGainEdges(matched.zeroPoleGain, center: 12_000, gain: 6)
        expectClose(matchedEdges.1 - matchedEdges.0, 3_000.0, .relative(1e-8))
    }

    @Test func aBandPastTheLimitIsRejected() throws {
        // §6.3.5: a band whose upper half-gain frequency would reach 0.49·fs.
        let wide = BandBoost(center: .hertz(21_600), gain: .decibels(6), bandwidth: .octaves(1))
        let error = thrownError { _ = try wide.design(sampleRate: rate) }
        #expect(error?.invalidParameterName == "bandwidth" && error?.invalidParameterReason?.contains("0.49") == true)
        // Rejected at attach time, with the stage's path.
        let attached = thrownError { _ = try Pipeline { Gain(.decibels(-3)); wide }.process(TestSignal.silence(count: 64), format: SignalFormat(sampleRate: rate)) }
        #expect(attached?.invalidParameterName == "bandwidth" && attached?.stage?.description == "BandBoost[1]")
        // The same band fits at a higher rate, and a narrower one fits here.
        #expect(try wide.design(sampleRate: 96_000).secondOrderSections.sections.count == 1)
        #expect(try BandBoost(center: .hertz(20_000), gain: .decibels(6), bandwidth: .hertz(2_000), order: 4).design(sampleRate: rate).secondOrderSections.sections.count == 4)
        for stage in [BandBoost(center: .hertz(20_000), gain: .decibels(6), bandwidth: .hertz(18_000), order: 3),
                      BandBoost(center: .hertz(23_000), gain: .decibels(-6), bandwidth: .q(0.5)),
                      BandBoost(center: .hertz(23_000), gain: .decibels(6), bandwidth: .hertz(3_000), rollOff: .order(2))] {
            #expect(thrownError { _ = try stage.design(sampleRate: rate) }?.invalidParameterName == "bandwidth")
        }
        #expect(thrownError { _ = try MatchedPeak(center: .hertz(20_000), gain: .decibels(6), bandwidth: .octaves(1)).design(sampleRate: rate) }?.invalidParameterName == "bandwidth")
        // Other values that make no band.
        #expect(thrownError { _ = try BandBoost(center: .hertz(30_000), gain: .decibels(6), bandwidth: .octaves(1)).design(sampleRate: rate) }?.invalidParameterName == "center")
        #expect(thrownError { _ = try BandBoost(center: .hertz(1_000), gain: .linear(0), bandwidth: .octaves(1)).design(sampleRate: rate) }?.invalidParameterName == "gain")
        #expect(thrownError { _ = try BandBoost(center: .hertz(1_000), gain: .decibels(6), bandwidth: .octaves(1), order: 0).design(sampleRate: rate) }?.invalidParameterName == "order")
        #expect(thrownError { _ = try LowShelf(midpoint: .hertz(1_000), gain: .decibels(6), slope: .slope(-1)).design(sampleRate: rate) }?.invalidParameterName == "slope")
        #expect(thrownError { _ = try HighShelf(midpoint: .hertz(0), gain: .decibels(6)).design(sampleRate: rate) }?.invalidParameterName == "midpoint")
    }

    @Test func theStagesAreValuesWithTheirContinuousValues() throws {
        // ANI-2: the centre in log₂ hertz, the gain in decibels, the width as a logarithm (or in octaves).
        #expect(BandBoost(center: .hertz(1_024), gain: .decibels(4), bandwidth: .octaves(1.5), order: 3).parameters == [10, 4, 1.5])
        expectClose(BandBoost(center: .hertz(1_024), gain: .linear(2), bandwidth: .hertz(256)).parameters, [10, 20 * log10(2.0), 8], .absolute(1e-12))
        #expect(BandBoost(center: .hertz(1_024), gain: .decibels(-4), bandwidth: .q(4)).parameters == [10, -4, 2])
        #expect(LowShelf(midpoint: .hertz(256), gain: .decibels(3), slope: .slope(0.8)).parameters == [8, 3, 0.8])
        #expect(HighShelf(midpoint: .hertz(8_192), gain: .decibels(-3), slope: .q(2)).parameters == [13, -3, 1])
        #expect(MatchedPeak(center: .hertz(8_192), gain: .decibels(6), bandwidth: .octaves(1)).parameters == [13, 6, 1])
        let boost = BandBoost(center: .hertz(997), gain: .decibels(4.5), bandwidth: .hertz(333), order: 3, isActive: false)
        #expect(boost.replacingParameters(boost.parameters[...]) == boost)
        #expect(boost.replacingParameters([10, -3, 8][...]) == BandBoost(center: .hertz(1_024), gain: .decibels(-3), bandwidth: .hertz(256), order: 3, isActive: false))
        #expect(boost.replacingParameters([10][...]) == boost)
        let shelf = LowShelf(midpoint: .hertz(997), gain: .decibels(-4.5), slope: .q(0.9))
        #expect(shelf.replacingParameters(shelf.parameters[...]) == shelf)
        #expect(shelf.replacingParameters([8, 3, 1][...]) == LowShelf(midpoint: .hertz(256), gain: .decibels(3), slope: .q(2)))
        let high = HighShelf(midpoint: .hertz(997), gain: .linear(0.5), slope: .slope(0.7))
        #expect(high.replacingParameters(high.parameters[...]) == high)
        expectClose(high.replacingParameters([13, -12, 0.5][...]).gain.decibels, -12.0, .absolute(1e-12))
        let peak = MatchedPeak(center: .hertz(997), gain: .decibels(4.5), bandwidth: .q(3))
        #expect(peak.replacingParameters(peak.parameters[...]) == peak)
        // Values: equal arguments, equal stages; one apart, another stage.
        #expect(Set([boost, BandBoost(center: .hertz(997), gain: .decibels(4.5), bandwidth: .hertz(333), order: 3, isActive: false),
                     BandBoost(center: .hertz(997), gain: .decibels(4.5), bandwidth: .hertz(333), order: 2, isActive: false),
                     BandBoost(center: .hertz(997), gain: .decibels(4.5), bandwidth: .octaves(333), order: 3, isActive: false),
                     BandBoost(center: .hertz(997), gain: .decibels(4.5), bandwidth: .hertz(333), rollOff: .order(3), isActive: false)]).count == 4)
        // What depends on the rate.
        #expect(BandBoost(center: .hertz(1_000), gain: .decibels(4), bandwidth: .octaves(1)).dependsOnSampleRate)
        #expect(!BandBoost(center: .normalized(0.1), gain: .decibels(4), bandwidth: .octaves(1)).dependsOnSampleRate)
        #expect(BandBoost(center: .normalized(0.1), gain: .decibels(4), bandwidth: .hertz(100)).dependsOnSampleRate)
        #expect(LowShelf(midpoint: .hertz(200), gain: .decibels(3)).dependsOnSampleRate && !HighShelf(midpoint: .fractionOfNyquist(0.2), gain: .decibels(3)).dependsOnSampleRate)
        #expect(!MatchedPeak(center: .fractionOfNyquist(0.2), gain: .decibels(3), bandwidth: .q(2)).dependsOnSampleRate)
    }

    @Test func theFluentSpellingAndTheBuilderGiveEqualPipelines() throws {
        let on = StateBox(true)
        #expect(Pipeline().bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1)) == Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1)) })
        #expect(Pipeline().bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 4, isActive: on.binding)
            == Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 4, isActive: on.binding) })
        #expect(Pipeline().bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), rollOff: .order(3), rounding: .up, isActive: false)
            == Pipeline { BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), rollOff: .order(3), rounding: .up, isActive: false) })
        #expect(Pipeline().lowShelf(midpoint: .hertz(200), gain: .decibels(3)) == Pipeline { LowShelf(midpoint: .hertz(200), gain: .decibels(3)) })
        #expect(Pipeline().lowShelf(midpoint: .hertz(200), gain: .decibels(3), slope: .q(1), isActive: .bypassed) == Pipeline { LowShelf(midpoint: .hertz(200), gain: .decibels(3), slope: .q(1), isActive: .bypassed) })
        #expect(Pipeline().highShelf(midpoint: .hertz(6_000), gain: .decibels(-3), slope: .slope(0.5)) == Pipeline { HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3), slope: .slope(0.5)) })
        #expect(Pipeline().matchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .q(2)) == Pipeline { MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .q(2)) })
        #expect(Pipeline().bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1)) != Pipeline().bandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 2))
    }
}
