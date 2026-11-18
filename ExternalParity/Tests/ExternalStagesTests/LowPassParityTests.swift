import CExternalKernels
import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// EXT-4, the second of the three: `ExternalLowPass`, an IIR low-pass on a C kernel of its
/// own, against the stock `LowPass(_:cutoff:order:)`.
///
/// In single precision both kernels run on `vDSP_biquad`, or from three channels up on
/// `vDSP_biquadm` with one setup for all channels, or on a C loop where a block holds only a
/// few frames, each chosen by the same rule; in double precision both are the transposed
/// direct form II of the same recurrence. The kernel is the same in every case, so the
/// comparison is bit for bit throughout.
@Suite("Low-pass parity")
struct LowPassParityTests {
    let noise = TestSignal.whiteNoise(count: 20_480, seed: 432, amplitude: 0.9)

    /// One filter of the grid: what both stages are given.
    struct Filter: Sendable, CustomStringConvertible {
        let name: String
        let cutoff: Double
        let order: Int
        let sampleRate: Double
        let stock: @Sendable () -> LowPass
        let external: @Sendable () -> ExternalLowPass

        init(_ name: String, _ family: some FilterFamily, cutoff: Double, order: Int, sampleRate: Double = 48_000) {
            self.name = name
            self.cutoff = cutoff
            self.order = order
            self.sampleRate = sampleRate
            stock = { LowPass(family, cutoff: .hertz(cutoff), order: order) }
            external = { ExternalLowPass(family, cutoff: .hertz(cutoff), order: order) }
        }

        var description: String { "\(name), \(cutoff) Hz, order \(order), at \(sampleRate) Hz" }
        var format: SignalFormat { SignalFormat(sampleRate: sampleRate) }
    }

    static let filters: [Filter] = [
        Filter("Butterworth", .butterworth, cutoff: 1_000, order: 4),
        Filter("Butterworth", .butterworth, cutoff: 200, order: 2),
        Filter("Butterworth", .butterworth, cutoff: 8_000, order: 8),
        Filter("Butterworth", .butterworth, cutoff: 3_000, order: 5, sampleRate: 44_100),
        Filter("Butterworth", .butterworth, cutoff: 1_000, order: 1),
        Filter("Chebyshev I", .chebyshev1(ripple: .decibels(1)), cutoff: 2_500, order: 5),
        Filter("Chebyshev II", .chebyshev2(stopband: .decibels(60)), cutoff: 4_000, order: 6),
        Filter("elliptic", .elliptic(ripple: .decibels(0.5), stopband: .decibels(70)), cutoff: 5_000, order: 7),
        Filter("Bessel", .bessel(), cutoff: 1_500, order: 3),
        Filter("Butterworth near Nyquist", .butterworth, cutoff: 21_600, order: 8),
        // Poles within 3.3e-4 of z = 1: the measurement chooses double precision (REAL-3).
        Filter("Butterworth at the low corner", .butterworth, cutoff: 10, order: 8, sampleRate: 192_000),
    ]

    @Test(arguments: LowPassParityTests.filters)
    func outputEqualsTheStockFilterBitForBit(_ filter: Filter) throws {
        for blockSize in [1, 7, 64, 333, 512, 1_000, 4_096] {
            let stock = try Pipeline { filter.stock() }.process(noise, format: filter.format, blockSize: blockSize)
            let external = try Pipeline { filter.external() }.process(noise, format: filter.format, blockSize: blockSize)
            #expect(external == stock, "\(filter) in blocks of \(blockSize): \(deviation(external, from: stock)) of the peak apart")
            #expect(external.count == noise.count)
        }
    }

    @Test(arguments: LowPassParityTests.filters)
    func itRunsInThePrecisionTheEnvironmentAsksFor(_ filter: Filter) throws {
        for precision in [BiquadPrecision.single, .double, .automatic] {
            let stock = try Pipeline { filter.stock() }.environment(\.biquadPrecision, precision).process(noise, format: filter.format)
            let external = try Pipeline { filter.external() }.environment(\.biquadPrecision, precision).process(noise, format: filter.format)
            #expect(external == stock, "\(filter), \(precision): \(deviation(external, from: stock)) of the peak apart")
        }
        // The two precisions are two kernels: they agree to the accuracy of single precision, not bit for bit.
        let single = try Pipeline { filter.external() }.environment(\.biquadPrecision, .single).process(noise, format: filter.format)
        let double = try Pipeline { filter.external() }.environment(\.biquadPrecision, .double).process(noise, format: filter.format)
        if filter.cutoff > 100 {
            expectClose(single, double, .relativeToMaximum(1e-3), "\(filter)")
        }
    }

    @Test(arguments: LowPassParityTests.filters)
    func itIsBoundToTheImplementationTheEnvironmentAsksFor(_ filter: Filter) throws {
        // SEL-3: vDSP or the C loop, by the block size at the stage's position or by what the
        // environment forces, as for the stock stage.
        for implementation in [Implementation.native, .accelerate, .automatic] {
            for blockSize in [1, 3, 4, 512] {
                let stock = try Pipeline { filter.stock() }.environment(\.implementation, implementation).process(noise, format: filter.format, blockSize: blockSize)
                let external = try Pipeline { filter.external() }.environment(\.implementation, implementation).process(noise, format: filter.format, blockSize: blockSize)
                #expect(external == stock, "\(filter), \(implementation), blocks of \(blockSize): \(deviation(external, from: stock)) of the peak apart")
            }
        }
    }

    @Test func theLowCornerRunsInDoublePrecisionAsTheStockFilterDoes() throws {
        // What `.automatic` chose is seen in the output: it equals the double-precision run and not the single one.
        let filter = LowPassParityTests.filters[LowPassParityTests.filters.count - 1]
        let automatic = try Pipeline { filter.external() }.process(noise, format: filter.format)
        let double = try Pipeline { filter.external() }.environment(\.biquadPrecision, .double).process(noise, format: filter.format)
        let single = try Pipeline { filter.external() }.environment(\.biquadPrecision, .single).process(noise, format: filter.format)
        #expect(automatic == double && automatic != single)
        #expect(try filter.external().design(sampleRate: filter.sampleRate).secondOrderSections.recommendedPrecision() == .double)
    }

    @Test func otherSignalsGiveTheSameFloats() throws {
        let filter = LowPassParityTests.filters[0]
        for signal in StressFixture.signals(count: 6_000) {
            let stock = try Pipeline { filter.stock() }.process(signal.samples, format: mono48, blockSize: 512)
            let external = try Pipeline { filter.external() }.process(signal.samples, format: mono48, blockSize: 512)
            #expect(external == stock, "\(signal.name)")
            #expect(external.allSatisfy { $0.isFinite }, "\(signal.name)")
        }
    }

    @Test func twoChannelsAreFilteredApartAndEqualTheStockFilter() throws {
        let left = TestSignal.whiteNoise(count: 9_000, seed: 21), right = TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 9_000)
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let filter = LowPassParityTests.filters[0]
        let stock = try Pipeline { filter.stock() }.process(channels: [left, right], format: stereo, blockSize: 480)
        let external = try Pipeline { filter.external() }.process(channels: [left, right], format: stereo, blockSize: 480)
        #expect(external == stock)
        // A channel does not hear the other one.
        #expect(external[0] == (try Pipeline { filter.external() }.process(left, format: mono48, blockSize: 480)))
    }

    @Test func fromThreeChannelsUpItRunsOnOneSetupLikeTheStockFilter() throws {
        // The stock stage then runs on vDSP_biquadm, one setup for all channels: another routine
        // than vDSP_biquad, about -97 dB from it by the header of the stock kernels. The kernel
        // of the suite changes routine by the same rule, so the floats stay the same. That
        // routine keeps its memory where no value can be flushed, so both kernels park a channel
        // that has gone quiet: the signals here go quiet and come back, one channel while the
        // others play, and all at once.
        let filter = LowPassParityTests.filters[0]
        for count in [3, 4, 6] {
            var channels = (0 ..< count).map { TestSignal.whiteNoise(count: 9_600, seed: UInt64(70 + $0), amplitude: 0.9) }
            for index in 2_000 ..< 4_500 { channels[0][index] = 0 }
            for channel in 0 ..< count {
                for index in 6_000 ..< 8_000 { channels[channel][index] = 0 }
            }
            let format = SignalFormat(sampleRate: 48_000, channelCount: count)
            for blockSize in [512, 64, 480, 7, 2] {
                let stock = try Pipeline { filter.stock() }.process(channels: channels, format: format, blockSize: blockSize)
                let external = try Pipeline { filter.external() }.process(channels: channels, format: format, blockSize: blockSize)
                #expect(external == stock, "\(count) channels, blocks of \(blockSize)")
                #expect(external.count == count && external.allSatisfy { $0.count == 9_600 && $0.allSatisfy { $0.isFinite } })
            }
            // A channel does not hear what the others carry: other signals beside it, the same floats.
            var others = channels
            for channel in 1 ..< count { others[channel] = TestSignal.whiteNoise(count: 9_600, seed: UInt64(170 + channel), amplitude: 0.5) }
            let beside = try Pipeline { filter.external() }.process(channels: channels, format: format)
            let besideOthers = try Pipeline { filter.external() }.process(channels: others, format: format)
            #expect(beside[0] == besideOthers[0] && beside[1] != besideOthers[1], "\(count) channels")
            // In double precision both run the same recurrence on every channel.
            let stockDouble = try Pipeline { filter.stock() }.environment(\.biquadPrecision, .double).process(channels: channels, format: format)
            let externalDouble = try Pipeline { filter.external() }.environment(\.biquadPrecision, .double).process(channels: channels, format: format)
            #expect(externalDouble == stockDouble, "\(count) channels, double precision")
        }
    }

    @Test func itStandsWhereAStockFilterStandsInAChain() throws {
        // A kernel of the caller's own is a fusion barrier (EXT-2); fused or not, a cascade gives the same floats (F2).
        let stock = try Pipeline {
            Gain(.decibels(-2))
            LowPass(.butterworth, cutoff: .hertz(2_000), order: 4)
            HighPass(.butterworth, cutoff: .hertz(100), order: 2)
            Gain(.decibels(1))
        }.process(noise, format: mono48, blockSize: 256)
        let external = try Pipeline {
            Gain(.decibels(-2))
            ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 4)
            HighPass(.butterworth, cutoff: .hertz(100), order: 2)
            Gain(.decibels(1))
        }.process(noise, format: mono48, blockSize: 256)
        #expect(external == stock)

        // On a feature-rate sequence the cutoff is a frequency of that sequence (§5.2).
        let stockLevels: [ScalarFrame] = try Pipeline {
            Level(.rms, window: 0.02, hop: 0.005); LowPass(.butterworth, cutoff: .hertz(20), order: 2)
        }.process(noise, format: mono48)
        let externalLevels: [ScalarFrame] = try Pipeline {
            Level(.rms, window: 0.02, hop: 0.005); ExternalLowPass(.butterworth, cutoff: .hertz(20), order: 2)
        }.process(noise, format: mono48)
        #expect(externalLevels == stockLevels && !stockLevels.isEmpty)
    }

    @Test func theDesignIsTheStockDesign() throws {
        for filter in LowPassParityTests.filters {
            let external = try filter.external().design(sampleRate: filter.sampleRate)
            let stock = try #require(try filter.stock().design(sampleRate: filter.sampleRate).iir)
            #expect(external == stock, "\(filter)")
            #expect(try external.secondOrderSections.sections.count == (filter.order + 1) / 2)
        }
    }

    @Test func bothSpellingsGiveOneDescription() throws {
        let stage = ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
        #expect(Pipeline { stage } == Pipeline().externalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        #expect(Pipeline { stage } != Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_001), order: 4) })
        #expect(Pipeline { stage } != Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 5) })
        #expect(Pipeline { stage } != Pipeline { ExternalLowPass(.bessel(), cutoff: .hertz(1_000), order: 4) })
        #expect(Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: true) } == Pipeline { stage })
        #expect(Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: false) } != Pipeline { stage })
        #expect(try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: .bypassed) }.process(noise, format: mono48) == noise)
        // ANI-2: the cutoff is the stage's continuous value, carried as the stock stage carries it.
        #expect(stage.parameters == LowPass(.butterworth, cutoff: .hertz(1_000), order: 4).parameters)
        #expect(stage.replacingParameters(stage.parameters[...]) == stage)
        let moved = stage.replacingParameters(ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 4).parameters[...])
        #expect(moved == ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 4))
    }

    @Test func aCutoffBeyondNyquistIsRejectedWithTheStagesPath() throws {
        // ENV-2, O-16: the edge is checked against the environment at the stage's position.
        let error = #expect(throws: DSPError.self) {
            try Pipeline { Gain(.decibels(-1)); ExternalLowPass(.butterworth, cutoff: .hertz(30_000), order: 4) }.process(noise, format: mono48)
        }
        guard case .invalidParameter(let stage, let parameter, let reason)? = error else {
            Issue.record("a cutoff above Nyquist: \(String(describing: error))")
            return
        }
        #expect(parameter == "cutoff" && stage.stageName == "ExternalLowPass" && reason.contains("Nyquist"))
        let stock = #expect(throws: DSPError.self) {
            try Pipeline { Gain(.decibels(-1)); LowPass(.butterworth, cutoff: .hertz(30_000), order: 4) }.process(noise, format: mono48)
        }
        guard case .invalidParameter(_, let stockParameter, let stockReason)? = stock else {
            Issue.record("the stock filter: \(String(describing: stock))")
            return
        }
        #expect(stockParameter == parameter && stockReason == reason)
        // Positional (ENV-1): legal at 48 kHz, not after a decimation by four.
        #expect(throws: Never.self) { try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(10_000), order: 2) }.process(noise, format: mono48) }
        #expect(throws: DSPError.self) {
            try Pipeline { Decimate(by: 4); ExternalLowPass(.butterworth, cutoff: .hertz(10_000), order: 2) }.process(noise, format: mono48)
        }
        #expect(throws: DSPError.self) { try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(0), order: 2) }.process(noise, format: mono48) }
        #expect(throws: DSPError.self) { try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 0) }.process(noise, format: mono48) }
    }

    @Test func theSameSamplesThroughEverySourceGiveTheSameOutput() async throws {
        let pipeline = Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
        let stock = try Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }.process(noise, format: mono48)
        let offline = try pipeline.process(noise, format: mono48)
        let buffered = try await throughEngine(pipeline, on: BufferSource(noise, sampleRate: 48_000))
        let scripted = try await throughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [1, 7, 300, 513, 64, 2, 4_000]))
        #expect(buffered == [offline] && scripted == [offline])
        #expect(offline == stock)
        // In blocks that are not multiples of four frames vDSP_biquad rounds differently, for both stages alike.
        let odd = try await throughEngine(pipeline, on: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [33]), blockSize: 333)
        let oddStock = try await throughEngine(
            Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }, on: BufferSource(noise, sampleRate: 48_000), blockSize: 333)
        #expect(odd == oddStock)
    }

    @Test func itIsCheckedAtAttachTimeLikeAnyStage() throws {
        var dynamic = try DynamicPipeline().appending(ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        try dynamic.append(STFT(frame: 256, hop: 64))
        let error = #expect(throws: DSPError.self) { try dynamic.append(ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)) }
        guard case .invalidStageOrder(let stage, _)? = error else {
            Issue.record("a filter after a spectrum: \(String(describing: error))")
            return
        }
        #expect(stage.stageName == "ExternalLowPass")
    }
}

/// The C kernel itself, against the stock kernels the public C header offers.
@Suite("The biquad kernel")
struct BiquadKernelTests {
    /// The three forms the kernel runs in, each with the stock kernel of the same form.
    enum Form: CaseIterable, CustomStringConvertible, Sendable {
        /// Single precision on vDSP_biquad.
        case accelerated
        /// Single precision in a C loop.
        case loop
        /// Double precision, transposed direct form II.
        case double

        var description: String {
            switch self {
            case .accelerated: "single precision on vDSP"
            case .loop: "single precision in a C loop"
            case .double: "double precision"
            }
        }

        func external(_ channels: UInt32, _ coefficients: [Double]) -> ztd_kernel_t {
            let sections = UInt32(coefficients.count / 5)
            switch self {
            case .accelerated: return extk_biquad_create(channels, sections, coefficients, false, ZTD_IMPLEMENTATION_ACCELERATE)
            case .loop: return extk_biquad_create(channels, sections, coefficients, false, ZTD_IMPLEMENTATION_NATIVE)
            case .double: return extk_biquad_create(channels, sections, coefficients, true, ZTD_IMPLEMENTATION_ACCELERATE)
            }
        }

        func stock(_ channels: UInt32, _ coefficients: [Double]) -> ztd_kernel_t {
            let sections = UInt32(coefficients.count / 5)
            switch self {
            case .accelerated: return ztd_biquad_create(channels, sections, coefficients, ZTD_IMPLEMENTATION_ACCELERATE)
            case .loop: return ztd_biquad_create(channels, sections, coefficients, ZTD_IMPLEMENTATION_NATIVE)
            case .double: return ztd_biquad_double_create(channels, sections, coefficients)
            }
        }
    }

    /// A Butterworth low-pass of order 6 at 1 kHz and 48 kHz, as the stage realises it.
    static func coefficients(cutoff: Double = 1_000, order: Int = 6, sampleRate: Double = 48_000) throws -> [Double] {
        try IIRDesign(.butterworth, .lowPass(cutoff: cutoff), order: order, domain: .digital(sampleRate: sampleRate))
            .secondOrderSections.spreadingGain().coefficients
    }

    /// Runs a kernel over `signal` in blocks of the given sizes, the last size repeating, with
    /// its output `displacement` floats away from an aligned address.
    static func run(_ kernel: ztd_kernel_t, on signal: [Float], blockSizes: [Int], displacement: Int = 0) throws -> [Float] {
        let largest = blockSizes.max() ?? 1
        let input = try AudioBuffer(channelCount: 1, capacity: largest)
        let output = try AudioBuffer(channelCount: 1, capacity: largest + 8)
        var result: [Float] = []
        var position = 0, turn = 0
        while position < signal.count {
            let frames = min(blockSizes[min(turn, blockSizes.count - 1)], signal.count - position)
            for index in 0 ..< frames { input.channel(0)[index] = signal[position + index] }
            var target: UnsafeMutablePointer<Float>? = output.channel(0) + displacement
            let written = withUnsafePointer(to: &target) { table in
                kernel.process?(kernel.state, input.block(frameCount: frames).constantChannelTable, table, 1, UInt32(frames)) ?? 0
            }
            #expect(Int(written) == frames)
            result.append(contentsOf: UnsafeBufferPointer(start: output.channel(0) + displacement, count: frames))
            position += frames
            turn += 1
        }
        return result
    }

    let noise = TestSignal.whiteNoise(count: 9_000, seed: 208, amplitude: 0.9)

    @Test(arguments: Form.allCases)
    func itEqualsTheStockKernelOfItsFormWhereverTheBufferSits(_ form: Form) throws {
        let coefficients = try BiquadKernelTests.coefficients()
        for displacement in [0, 1, 2, 3] {
            for blockSizes in [[512], [64], [1], [3], [7, 300, 13, 64], [4_096]] {
                var mine = form.external(1, coefficients)
                var stock = form.stock(1, coefficients)
                defer {
                    ztd_kernel_destroy(&mine)
                    ztd_kernel_destroy(&stock)
                }
                try #require(!ztd_kernel_is_null(&mine) && !ztd_kernel_is_null(&stock))
                let a = try BiquadKernelTests.run(mine, on: noise, blockSizes: blockSizes, displacement: displacement)
                let b = try BiquadKernelTests.run(stock, on: noise, blockSizes: blockSizes, displacement: displacement)
                #expect(a == b, "\(form), blocks of \(blockSizes), output displaced by \(displacement) floats")
            }
        }
        // Where the caller keeps its buffer changes nothing.
        var kernel = form.external(1, coefficients)
        var other = form.external(1, coefficients)
        defer {
            ztd_kernel_destroy(&kernel)
            ztd_kernel_destroy(&other)
        }
        #expect(try BiquadKernelTests.run(kernel, on: noise, blockSizes: [512]) == BiquadKernelTests.run(other, on: noise, blockSizes: [512], displacement: 3))
    }

    @Test func theTwoLoopsDoNotDependOnTheBlocksAndVDSPOnlyOnTheirRemainders() throws {
        // What the header of the stock kernels says of its three forms holds for these.
        let coefficients = try BiquadKernelTests.coefficients()
        func output(_ form: Form, _ blockSizes: [Int]) throws -> [Float] {
            var kernel = form.external(1, coefficients)
            defer { ztd_kernel_destroy(&kernel) }
            return try BiquadKernelTests.run(kernel, on: noise, blockSizes: blockSizes)
        }
        for form in [Form.loop, .double] {
            let reference = try output(form, [512])
            for blockSizes in [[1], [3], [7, 300, 13, 64], [4_096]] {
                #expect(try output(form, blockSizes) == reference, "\(form), blocks of \(blockSizes)")
            }
        }
        // vDSP_biquad filters four frames at a time: any multiple of four gives the same floats,
        // other sizes differ by round-off.
        let reference = try output(.accelerated, [512])
        #expect(try output(.accelerated, [64]) == reference)
        #expect(try output(.accelerated, [4, 8, 1_024, 12]) == reference)
        expectClose(try output(.accelerated, [7, 300, 13, 64]), reference, .deviationBelow(decibels: -90))
        // The two single-precision forms are two computations of one filter.
        expectClose(try output(.loop, [512]), reference, .deviationBelow(decibels: -90))
        expectClose(try output(.double, [512]), reference, .deviationBelow(decibels: -90))
    }

    @Test func theStockDoublePrecisionCascadeDependsOnTheBlocksWhileASectionStartsBelowTheFloor() throws {
        // FINDING. ztd_kernels.h says of the double-precision cascade "block-size invariant bit
        // for bit". RT-6 clears every state value below 1e-20 at the end of each block, so where a
        // section's memory is still that small when a block ends (the later sections of a 10 Hz
        // low-pass of order 8 at 192 kHz, in the first frames after a cold start), what is
        // cleared depends on where the blocks end. The kernel of the suite follows the same rule
        // and shows the same dependence: it equals the stock kernel for every way of cutting the
        // signal into blocks.
        let coefficients = try BiquadKernelTests.coefficients(cutoff: 10, order: 8, sampleRate: 192_000)
        func output(_ make: (UInt32, [Double]) -> ztd_kernel_t, _ blockSizes: [Int]) throws -> [Float] {
            var kernel = make(1, coefficients)
            defer { ztd_kernel_destroy(&kernel) }
            return try BiquadKernelTests.run(kernel, on: noise, blockSizes: blockSizes)
        }
        let stock = try output(Form.double.stock, [512])
        for blockSizes in [[512], [1], [7, 300, 13, 64], [4_096]] {
            #expect(try output(Form.double.external, blockSizes) == output(Form.double.stock, blockSizes), "blocks of \(blockSizes)")
        }
        let single = try output(Form.double.stock, [1])
        withKnownIssue("FINDING: the stock double-precision cascade is not block-size invariant bit for bit while a section's memory is below the state floor") {
            #expect(single == stock)
        }
        // How far apart: what RT-6 cleared, as the rest of the cascade passes it on.
        var worst = 0.0, first = -1
        for index in 0 ..< min(single.count, stock.count) where single[index] != stock[index] {
            if first < 0 { first = index }
            worst = max(worst, abs(Double(single[index]) - Double(stock[index])))
        }
        let peak = Double(stock.map { abs($0) }.max() ?? 0)
        print("PARITY stock double-precision cascade, blocks of 1 against blocks of 512: first difference at frame \(first), largest \(worst) for a peak of \(peak)")
        #expect(first >= 0 && worst <= 1.0e-6 * peak)
    }

    @Test func itDeclaresTheSettlingTimeOfTheStockKernelAndNoLatency() throws {
        let designs: [(Double, Int, Double)] = [(1_000, 6, 48_000), (200, 2, 48_000), (8_000, 8, 48_000), (10, 8, 192_000), (21_600, 8, 48_000), (1_000, 1, 44_100)]
        for (cutoff, order, rate) in designs {
            let coefficients = try BiquadKernelTests.coefficients(cutoff: cutoff, order: order, sampleRate: rate)
            for form in Form.allCases {
                var mine = form.external(2, coefficients)
                var stock = form.stock(2, coefficients)
                defer {
                    ztd_kernel_destroy(&mine)
                    ztd_kernel_destroy(&stock)
                }
                #expect(mine.settling_frames == stock.settling_frames, "\(form), \(cutoff) Hz, order \(order): \(mine.settling_frames) against \(stock.settling_frames)")
                #expect(mine.settling_frames == extk_biquad_settling(coefficients, UInt32(coefficients.count / 5)))
                #expect(mine.latency_frames == 0 && stock.latency_frames == 0)
                #expect(mine.settling_frames > 0)
            }
        }
        // The slowest pole decays by 100 dB in that many frames, and not in two fewer.
        let coefficients = try BiquadKernelTests.coefficients()
        let radius = try 1 - IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 6, domain: .digital(sampleRate: 48_000)).secondOrderSections.stabilityMargin
        let frames = Double(extk_biquad_settling(coefficients, 3))
        #expect(pow(radius, frames) <= 1.0e-5 * 1.000_001 && pow(radius, frames - 2) > 1.0e-5)
        #expect(extk_biquad_settling([1, 0, 0, 0, 0], 1) == 0, "a section without poles has nothing to settle")
        #expect(extk_biquad_settling([1, 0, 0, -2, 1], 1) == 1 << 24, "a pole on the unit circle never settles: the cap")
        #expect(extk_biquad_settling(nil, 3) == 0)
    }

    @Test(arguments: Form.allCases)
    func newCoefficientsAreSetInPlaceAndTheFilterKeepsItsMemory(_ form: Form) throws {
        // The kernel takes ZTD_COMMAND_SET_VALUES as the ABI defines it, like the stock kernels.
        let first = try BiquadKernelTests.coefficients(cutoff: 1_000), second = try BiquadKernelTests.coefficients(cutoff: 3_000)
        var mine = form.external(1, first)
        var stock = form.stock(1, first)
        defer {
            ztd_kernel_destroy(&mine)
            ztd_kernel_destroy(&stock)
        }
        var a = try BiquadKernelTests.run(mine, on: Array(noise[..<4_096]), blockSizes: [512])
        var b = try BiquadKernelTests.run(stock, on: Array(noise[..<4_096]), blockSizes: [512])
        second.withUnsafeBufferPointer { values in
            var command = ztd_command_t()
            command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
            command.count = UInt32(values.count)
            command.values = UnsafeRawPointer(values.baseAddress)
            mine.command?(mine.state, &command)
            stock.command?(stock.state, &command)
            // A command that is not for the kernel is ignored: another count, another kind, no payload, none at all.
            command.count = 7
            mine.command?(mine.state, &command)
            command.count = UInt32(values.count)
            command.kind = UInt32(ZTD_COMMAND_CUSTOM)
            mine.command?(mine.state, &command)
            command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
            command.values = nil
            mine.command?(mine.state, &command)
            mine.command?(mine.state, nil)
        }
        a += try BiquadKernelTests.run(mine, on: Array(noise[4_096 ..< 8_192]), blockSizes: [512])
        b += try BiquadKernelTests.run(stock, on: Array(noise[4_096 ..< 8_192]), blockSizes: [512])
        #expect(a == b, "\(form)")
        // The memory was kept: a kernel that starts cold on the new coefficients says something else at first.
        var cold = form.external(1, second)
        defer { ztd_kernel_destroy(&cold) }
        let fresh = try BiquadKernelTests.run(cold, on: Array(noise[4_096 ..< 8_192]), blockSizes: [512])
        #expect(Array(a[4_096 ..< 4_160]) != Array(fresh[..<64]))
        // And it runs the new filter from then on: the two meet once the old memory has decayed.
        expectClose(Array(a[7_168...]), Array(fresh[3_072...]), .absolute(1.0e-4))
    }

    @Test(arguments: Form.allCases)
    func aResetIsAColdStartThatKeepsTheCoefficients(_ form: Form) throws {
        let coefficients = try BiquadKernelTests.coefficients()
        var kernel = form.external(1, coefficients)
        defer { ztd_kernel_destroy(&kernel) }
        let first = try BiquadKernelTests.run(kernel, on: Array(noise[..<2_048]), blockSizes: [512])
        kernel.reset?(kernel.state)
        let again = try BiquadKernelTests.run(kernel, on: Array(noise[..<2_048]), blockSizes: [512])
        #expect(first == again)
    }

    @Test(arguments: Form.allCases)
    func noStateBelowTheFloorIsLeftBehind(_ form: Form) throws {
        // RT-6: a tail that decays through the floor, then silence. What is left in the kernel is
        // cleared at the end of a block, so the output becomes exact zeros, as the stock kernel's does.
        let coefficients = try BiquadKernelTests.coefficients()
        let signal = TestSignal.decayingTail(count: 2_048, ratio: 0.9) + TestSignal.silence(count: 16_384)
        var kernel = form.external(1, coefficients)
        var stock = form.stock(1, coefficients)
        defer {
            ztd_kernel_destroy(&kernel)
            ztd_kernel_destroy(&stock)
        }
        let output = try BiquadKernelTests.run(kernel, on: signal, blockSizes: [512])
        #expect(output.suffix(512).allSatisfy { $0 == 0 }, "\(form)")
        #expect(output == (try BiquadKernelTests.run(stock, on: signal, blockSizes: [512])), "\(form)")
        #expect(output.prefix(512).contains { $0 != 0 })
    }

    @Test func fromThreeChannelsUpItEqualsTheStockMultichannelKernel() throws {
        // vDSP_biquadm against vDSP_biquadm: the same floats through blocks of every size, a
        // channel that goes quiet and is parked, all channels quiet at once, new coefficients
        // while it runs, and a reset.
        let first = try BiquadKernelTests.coefficients(), second = try BiquadKernelTests.coefficients(cutoff: 2_500)
        let sections = UInt32(first.count / 5)
        var signals = (0 ..< 3).map { TestSignal.whiteNoise(count: 12_000, seed: UInt64(300 + $0), amplitude: 0.9) }
        for index in 1_500 ..< 4_000 { signals[1][index] = 0 }
        for channel in 0 ..< 3 {
            for index in 7_000 ..< 9_500 { signals[channel][index] = 0 }
        }
        func run(_ kernel: ztd_kernel_t) throws -> [[Float]] {
            let input = try AudioBuffer(channelCount: 3, capacity: 512), output = try AudioBuffer(channelCount: 3, capacity: 512)
            let sizes = [512, 64, 1, 7, 300, 3, 480]
            var result = [[Float]](repeating: [], count: 3)
            var position = 0, turn = 0
            while position < signals[0].count {
                let frames = min(sizes[turn % sizes.count], signals[0].count - position)
                for channel in 0 ..< 3 {
                    for index in 0 ..< frames { input.channel(channel)[index] = signals[channel][position + index] }
                }
                if turn == 30 {
                    second.withUnsafeBufferPointer { values in
                        var command = ztd_command_t()
                        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
                        command.count = UInt32(values.count)
                        command.values = UnsafeRawPointer(values.baseAddress)
                        kernel.command?(kernel.state, &command)
                        // A command that is not for the kernel is ignored.
                        command.count = 7
                        kernel.command?(kernel.state, &command)
                        kernel.command?(kernel.state, nil)
                    }
                }
                if turn == 50 { kernel.reset?(kernel.state) }
                let written = kernel.process?(kernel.state, input.block(frameCount: frames).constantChannelTable, output.block(frameCount: frames).channelTable, 3, UInt32(frames)) ?? 0
                try #require(Int(written) == frames)
                for channel in 0 ..< 3 { result[channel].append(contentsOf: UnsafeBufferPointer(start: output.channel(channel), count: frames)) }
                position += frames
                turn += 1
            }
            return result
        }
        var mine = extk_biquad_create(3, sections, first, false, ZTD_IMPLEMENTATION_ACCELERATE)
        var stock = ztd_biquadm_create(3, sections, first)
        defer {
            ztd_kernel_destroy(&mine)
            ztd_kernel_destroy(&stock)
        }
        try #require(!ztd_kernel_is_null(&mine) && !ztd_kernel_is_null(&stock))
        #expect(mine.latency_frames == stock.latency_frames && mine.settling_frames == stock.settling_frames)
        let a = try run(mine), b = try run(stock)
        #expect(a == b)
        // The parked channel gave exact zeros, and came back.
        #expect(a[1][3_900 ..< 4_000].allSatisfy { $0 == 0 } && a[1][4_100 ..< 4_200].contains { $0 != 0 })
        #expect(a[0][9_400 ..< 9_500].allSatisfy { $0 == 0 } && a[0][11_000...].contains { $0 != 0 })
        // The setup filters all its channels or none: with fewer buffers nothing is done, and with no frames nothing either.
        let input = try AudioBuffer(channelCount: 3, capacity: 8), output = try AudioBuffer(channels: [[3, 3, 3, 3, 3, 3, 3, 3], [3, 3, 3, 3, 3, 3, 3, 3], [3, 3, 3, 3, 3, 3, 3, 3]])
        #expect(mine.process?(mine.state, input.block().constantChannelTable, output.block().channelTable, 2, 8) == 0)
        #expect(mine.process?(mine.state, input.block().constantChannelTable, output.block().channelTable, 3, 0) == 0)
        #expect(output.array(ofChannel: 0) == [3, 3, 3, 3, 3, 3, 3, 3])
        // Two channels stay on vDSP_biquad, and the C loop and double precision take any number of channels.
        var pair = extk_biquad_create(2, sections, first, false, ZTD_IMPLEMENTATION_ACCELERATE)
        var stockPair = ztd_biquad_create(2, sections, first, ZTD_IMPLEMENTATION_ACCELERATE)
        defer {
            ztd_kernel_destroy(&pair)
            ztd_kernel_destroy(&stockPair)
        }
        let two = try AudioBuffer(channels: [Array(signals[0][..<512]), Array(signals[2][..<512])])
        let outA = try AudioBuffer(channelCount: 2, capacity: 512), outB = try AudioBuffer(channelCount: 2, capacity: 512)
        _ = pair.process?(pair.state, two.block().constantChannelTable, outA.block().channelTable, 2, 512)
        _ = stockPair.process?(stockPair.state, two.block().constantChannelTable, outB.block().channelTable, 2, 512)
        #expect(outA.array(ofChannel: 0) == outB.array(ofChannel: 0) && outA.array(ofChannel: 1) == outB.array(ofChannel: 1))
    }

    @Test func argumentsThatMakeNoKernelGiveANullKernel() throws {
        let coefficients = try BiquadKernelTests.coefficients()
        func isNull(_ kernel: ztd_kernel_t) -> Bool {
            var copy = kernel
            defer { ztd_kernel_destroy(&copy) }
            return ztd_kernel_is_null(&copy)
        }
        #expect(isNull(extk_biquad_create(0, 3, coefficients, false, ZTD_IMPLEMENTATION_ACCELERATE)))
        #expect(isNull(extk_biquad_create(1, 0, coefficients, false, ZTD_IMPLEMENTATION_NATIVE)))
        #expect(isNull(extk_biquad_create(1, 3, nil, true, ZTD_IMPLEMENTATION_ACCELERATE)))
        #expect(isNull(extk_biquad_create(1, 1, [1, 0, .nan, 0, 0], false, ZTD_IMPLEMENTATION_ACCELERATE)))
        #expect(isNull(extk_biquad_create(1, 1, [1, 0, 0, .infinity, 0], true, ZTD_IMPLEMENTATION_ACCELERATE)))
        #expect(isNull(extk_biquad_create(1, 3, coefficients, false, ztd_implementation_t(rawValue: 7))))
        #expect(isNull(extk_biquad_create(1 << 25, 3, coefficients, false, ZTD_IMPLEMENTATION_NATIVE)))
        for form in Form.allCases {
            #expect(!isNull(form.external(1, coefficients)) && !isNull(form.external(4, coefficients)), "\(form)")
            // A block of no frames is no work and no error.
            var kernel = form.external(1, coefficients)
            defer { ztd_kernel_destroy(&kernel) }
            let input = try AudioBuffer(channelCount: 1, capacity: 8), output = try AudioBuffer(channels: [[3, 3, 3, 3, 3, 3, 3, 3]])
            #expect(kernel.process?(kernel.state, input.block().constantChannelTable, output.block().channelTable, 1, 0) == 0)
            #expect(output.array(ofChannel: 0) == [3, 3, 3, 3, 3, 3, 3, 3], "nothing is written for a block of no frames")
        }
    }
}
