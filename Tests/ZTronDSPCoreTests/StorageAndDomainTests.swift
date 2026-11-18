import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("AlignedBuffer (WP-105)")
struct AlignedBufferTests {
    @Test(arguments: [16, 64, 128, 4_096])
    func storageIsAlignedAndZeroFilled(alignment: Int) throws {
        for count in [0, 1, 3, 1_000] {
            let buffer = try AlignedBuffer<Float>(count: count, alignment: alignment)
            #expect(UInt(bitPattern: buffer.baseAddress) % UInt(alignment) == 0)
            #expect(buffer.alignment == alignment)
            #expect(buffer.count == count)
            #expect(buffer.buffer.count == count)
            #expect(buffer.buffer.allSatisfy { $0 == 0 })
        }
    }

    @Test func defaultAlignmentIsACacheLine() throws {
        let floats = try AlignedBuffer<Float>(count: 10)
        #expect(UInt(bitPattern: floats.baseAddress) % 64 == 0)
        let doubles = try AlignedBuffer<Double>(count: 10, alignment: 1)
        #expect(doubles.alignment >= MemoryLayout<Double>.alignment, "never below the element's own alignment")
        #expect(UInt(bitPattern: doubles.baseAddress) % UInt(MemoryLayout<Double>.alignment) == 0)
    }

    @Test func invalidRequestsAreTypedErrors() {
        #expect(throws: DSPError.self) { try AlignedBuffer<Float>(count: -1) }
        #expect(throws: DSPError.self) { try AlignedBuffer<Float>(count: 4, alignment: 48) }
        #expect(throws: DSPError.self) { try AlignedBuffer<Float>(count: 4, alignment: 0) }
        #expect(throws: DSPError.self) { try AlignedBuffer<Double>(count: Int.max / 2) }
        do {
            _ = try AlignedBuffer<Float>(count: -1)
        } catch {
            guard case .resourceAllocationFailed = error else { Issue.record("unexpected \(error)"); return }
        }
    }

    @Test func readsAndWritesAreAllocationFree() throws {
        let buffer = try AlignedBuffer<Float>(count: 4_096)
        let source = try AlignedBuffer<Float>(count: 4_096)
        source.fill(with: 2)
        expectNoAllocations {
            let pointer = buffer.baseAddress
            var index = 0
            while index < 4_096 {
                pointer[index] = Float(index)
                index += 1
            }
            var sum: Float = 0
            index = 0
            while index < 4_096 {
                sum += buffer[index]
                index += 1
            }
            Benchmark.blackHole(sum)
            buffer.clear()
            buffer.fill(with: 1)
            buffer.copy(from: source.baseAddress, count: 4_096)
        }
        #expect(buffer[0] == 2 && buffer[4_095] == 2)
    }

    @Test func fillCopyAndClear() throws {
        let buffer = try AlignedBuffer<Float>(copying: [1, 2, 3, 4])
        #expect(buffer.array == [1, 2, 3, 4])
        #expect(buffer[2] == 3)
        #expect(buffer[-1] == 1 && buffer[99] == 1, "an index outside the storage does not read out of bounds")
        buffer.fill(with: 7)
        #expect(buffer.array == [7, 7, 7, 7])
        let source: [Float] = [9, 8, 7, 6, 5, 4]
        source.withUnsafeBufferPointer { buffer.copy(from: $0.baseAddress!, count: 6) }
        #expect(buffer.array == [9, 8, 7, 6], "a copy stops at the capacity")
        source.withUnsafeBufferPointer { buffer.copy(from: $0.baseAddress!, count: -3) }
        #expect(buffer.array == [9, 8, 7, 6])
        buffer.clear()
        #expect(buffer.array == [0, 0, 0, 0])
        let empty = try AlignedBuffer<Float>(copying: [Float]())
        #expect(empty.count == 0 && empty.array.isEmpty && empty[0] == 0)
    }

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func storageIsFreedWithTheBuffer() throws {
        var buffer: AlignedBuffer<Double>? = try AlignedBuffer<Double>(count: 1_000_000)
        weak let observed = buffer
        #expect(observed != nil)
        let counts = try countAllocations { buffer = nil }
        #expect(observed == nil)
        #expect(counts.deallocations >= 1, "releasing the buffer frees its storage")
    }

    @Test func aBufferIsAReferenceNotACopy() throws {
        let first = try AlignedBuffer<Int32>(count: 4)
        let second = first
        second.baseAddress[1] = 42
        #expect(first[1] == 42, "no copy-on-write")
    }
}

@Suite("Signal format and audio blocks (WP-104)")
struct AudioBlockTests {
    @Test func formatIsAValue() {
        let format = SignalFormat(sampleRate: 48_000, channelCount: 2)
        #expect(format == SignalFormat(sampleRate: 48_000, channelCount: 2))
        #expect(format != SignalFormat(sampleRate: 44_100, channelCount: 2))
        #expect(SignalFormat(sampleRate: 48_000).channelCount == 1)
        #expect(format.isValid)
        #expect(!SignalFormat(sampleRate: 0).isValid)
        #expect(!SignalFormat(sampleRate: .nan).isValid)
        #expect(!SignalFormat(sampleRate: 48_000, channelCount: 0).isValid)
        #expect(format.withChannelCount(1) == SignalFormat(sampleRate: 48_000, channelCount: 1))
        #expect(format.withSampleRate(8_000) == SignalFormat(sampleRate: 8_000, channelCount: 2))
        #expect(format.description == "48000.0 Hz, 2 channels")
        #expect(SignalFormat(sampleRate: 8_000).description == "8000.0 Hz, 1 channel")
        #expect(ChannelPolicy.channel(1) != .channel(0))
        #expect(Set([ChannelPolicy.mixdown, .perChannel, .channel(0), .mixdown]).count == 3)
        #expect(Set([SourceKind.push, .pull, .derived, .offline]).count == 4)
    }

    @Test func blockLayoutIsPlanar() throws {
        let buffer = try AudioBuffer(channelCount: 3, capacity: 512)
        #expect(buffer.channelCount == 3 && buffer.capacity == 512)
        var block = buffer.block()
        #expect(block.channelCount == 3 && block.capacity == 512 && block.frameCount == 512)
        // One buffer per channel, each aligned and none overlapping another.
        for channel in 0 ..< 3 {
            #expect(UInt(bitPattern: block.channel(channel)) % 64 == 0)
            block.channel(channel).update(repeating: Float(channel + 1), count: 512)
        }
        for channel in 0 ..< 3 {
            #expect(block.samples(ofChannel: channel).allSatisfy { $0 == Float(channel + 1) })
            #expect(block.samples(ofChannel: channel).count == 512)
        }
        #expect(block.channel(1) - block.channel(0) >= 512)
        #expect(block.channel(7) == block.channel(0), "a channel outside the block does not read out of bounds")
        #expect(buffer.channel(-1) == buffer.channel(0))

        block.setFrameCount(100)
        #expect(block.frameCount == 100)
        #expect(block.samples(ofChannel: 0).count == 100)
        block.setFrameCount(9_999)
        #expect(block.frameCount == 512, "clamped to the capacity")
        block.setFrameCount(-5)
        #expect(block.frameCount == 0)
        #expect(buffer.block(frameCount: 7).frameCount == 7)
    }

    @Test func theChannelTablesAreWhatCKernelsTake() throws {
        let buffer = try AudioBuffer(channels: [[1, 2, 3], [4, 5, 6]])
        let block = buffer.block()
        #expect(block.channelTable[1]![2] == 6)
        #expect(block.constantChannelTable[0]![1] == 2)
        #expect(buffer.array(ofChannel: 1) == [4, 5, 6])
        #expect(buffer.array(ofChannel: 0, frameCount: 2) == [1, 2])
    }

    @Test func copyAndClear() throws {
        let source = try AudioBuffer(channels: [[1, 2, 3, 4], [5, 6, 7, 8]])
        let target = try AudioBuffer(channelCount: 2, capacity: 3)
        var block = target.block(frameCount: 0)
        #expect(block.copy(from: source.block()) == 3, "a copy stops at the capacity")
        #expect(block.frameCount == 3)
        #expect(target.array(ofChannel: 0) == [1, 2, 3] && target.array(ofChannel: 1) == [5, 6, 7])
        block.clear()
        #expect(target.array(ofChannel: 0) == [0, 0, 0])
        let mono = try AudioBuffer(channelCount: 1, capacity: 4)
        var monoBlock = mono.block()
        #expect(monoBlock.copy(from: source.block(frameCount: 2)) == 2)
        #expect(mono.array(ofChannel: 0, frameCount: 2) == [1, 2], "only the channels both blocks have are copied")
        source.clear()
        #expect(source.array(ofChannel: 1) == [0, 0, 0, 0])
    }

    @Test func invalidStorageIsATypedError() {
        #expect(throws: DSPError.self) { try AudioBuffer(channelCount: 0, capacity: 16) }
        #expect(throws: DSPError.self) { try AudioBuffer(channelCount: 1, capacity: -1) }
        #expect(throws: DSPError.self) { try AudioBuffer(channels: [[1, 2], [3]]) }
        #expect(throws: DSPError.self) { try AudioBuffer(channels: []) }
    }

    @Test func blockAccessIsAllocationFree() throws {
        let buffer = try AudioBuffer(channelCount: 2, capacity: 512)
        let other = try AudioBuffer(channelCount: 2, capacity: 512)
        expectNoAllocations {
            var block = buffer.block()
            var channel = 0
            while channel < 2 {
                let samples = block.channel(channel)
                var frame = 0
                while frame < 512 {
                    samples[frame] = 0.25
                    frame += 1
                }
                channel += 1
            }
            block.setFrameCount(256)
            var target = other.block()
            target.copy(from: block)
            target.clear()
        }
    }
}

@Suite("Signal domains (WP-110a)")
struct SignalDomainTests {
    @Test func tagsAreDistinct() {
        let tags: [DomainTag] = [
            Samples.tag, Quefrency.tag, MelCepstrum.tag, Chroma.tag, Lags.tag, TempoSpectrum.tag, Envelope.tag, Novelty.tag, Scalar.tag,
            Spectrum<LinearFrequency, ComplexValues>.tag, Spectrum<LinearFrequency, MagnitudeValues>.tag,
            Spectrum<LinearFrequency, PowerValues>.tag, Spectrum<LinearFrequency, DecibelValues>.tag,
            Spectrum<MelFrequency, ComplexValues>.tag, Spectrum<MelFrequency, MagnitudeValues>.tag,
            Spectrum<MelFrequency, PowerValues>.tag, Spectrum<MelFrequency, DecibelValues>.tag,
            Spectrum<ConstantQFrequency, ComplexValues>.tag, Spectrum<ConstantQFrequency, MagnitudeValues>.tag,
            Spectrum<ConstantQFrequency, PowerValues>.tag, Spectrum<ConstantQFrequency, DecibelValues>.tag,
            .custom("Loudness"),
        ]
        #expect(Set(tags).count == tags.count)
        #expect(Set(tags.map(\.description)).count == tags.count, "each domain reads differently")
        #expect(Spectrum<MelFrequency, PowerValues>.tag == .spectrum(axis: .mel, values: .power))
        #expect(Spectrum<LinearFrequency, DecibelValues>.tag.description == "linear-frequency spectrum in decibels")
        #expect(DomainTag.custom("Loudness").description == "Loudness")
    }

    /// The table of §5.2: which domains are sampled sequences.
    @Test func sampledSequencesAreSamplesNoveltyAndScalar() {
        func isSequence<D: SignalDomain>(_: D.Type) -> Bool { D.self is any SampledSequence.Type }
        #expect(isSequence(Samples.self) && isSequence(Novelty.self) && isSequence(Scalar.self))
        #expect(!isSequence(Quefrency.self) && !isSequence(MelCepstrum.self) && !isSequence(Chroma.self))
        #expect(!isSequence(Lags.self) && !isSequence(TempoSpectrum.self) && !isSequence(Envelope.self))
        #expect(!isSequence(Spectrum<LinearFrequency, ComplexValues>.self))
        // The run-time tag says the same thing as the type.
        for (tag, expected) in [(Samples.tag, true), (Novelty.tag, true), (Scalar.tag, true), (Chroma.tag, false),
                                (Spectrum<MelFrequency, DecibelValues>.tag, false), (Envelope.tag, false), (DomainTag.custom("X"), false)] {
            #expect(tag.isSampledSequence == expected, "\(tag)")
        }
    }

    /// The sinks table of §5.2: which domains a feed and which a scalar binding can take.
    @Test func sinkCapabilitiesFollowTheTable() {
        func isRealVector<D: SignalDomain>(_: D.Type) -> Bool { D.self is any RealVectorDomain.Type }
        func isScalarValued<D: SignalDomain>(_: D.Type) -> Bool { D.self is any ScalarValuedDomain.Type }
        #expect(isRealVector(Spectrum<LinearFrequency, MagnitudeValues>.self))
        #expect(isRealVector(Spectrum<MelFrequency, PowerValues>.self))
        #expect(isRealVector(Spectrum<ConstantQFrequency, DecibelValues>.self))
        #expect(!isRealVector(Spectrum<LinearFrequency, ComplexValues>.self), "a complex spectrum is nothing to draw (O-11)")
        #expect(isRealVector(Quefrency.self) && isRealVector(MelCepstrum.self) && isRealVector(Chroma.self))
        #expect(isRealVector(Lags.self) && isRealVector(TempoSpectrum.self))
        #expect(!isRealVector(Samples.self) && !isRealVector(Envelope.self) && !isRealVector(Scalar.self) && !isRealVector(Novelty.self))
        #expect(isScalarValued(Scalar.self) && isScalarValued(Novelty.self))
        #expect(!isScalarValued(Samples.self) && !isScalarValued(Chroma.self))

        #expect(DomainTag.spectrum(axis: .linear, values: .complex).isRealVector == false)
        #expect(DomainTag.spectrum(axis: .mel, values: .decibel).isRealVector)
        #expect(DomainTag.chroma.isRealVector && DomainTag.lags.isRealVector && DomainTag.quefrency.isRealVector)
        #expect(DomainTag.melCepstrum.isRealVector && DomainTag.tempoSpectrum.isRealVector)
        #expect(!DomainTag.samples.isRealVector && !DomainTag.envelope.isRealVector && !DomainTag.custom("X").isRealVector)
        #expect(DomainTag.scalar.isScalarValued && DomainTag.novelty.isScalarValued && !DomainTag.chroma.isScalarValued)
        #expect(DomainTag.spectrum(axis: .constantQ, values: .magnitude).isSpectrum && !DomainTag.chroma.isSpectrum)
    }

    /// The "Delivered as" column of §5.2.
    @Test func framesAreDeliveredAsTheTableSays() {
        #expect(Samples.tag.frameKind == .samples)
        #expect(Spectrum<LinearFrequency, ComplexValues>.tag.frameKind == .complex)
        #expect(Spectrum<ConstantQFrequency, ComplexValues>.tag.frameKind == .complex)
        #expect(Spectrum<LinearFrequency, PowerValues>.tag.frameKind == .real)
        for tag in [Quefrency.tag, MelCepstrum.tag, Chroma.tag, Lags.tag, TempoSpectrum.tag, .custom("X")] {
            #expect(tag.frameKind == .real, "\(tag)")
        }
        #expect(Envelope.tag.frameKind == .envelope)
        #expect(Novelty.tag.frameKind == .scalar && Scalar.tag.frameKind == .scalar)
    }

    @Test func valueKindsFollowTheirProtocols() {
        func isLinear<V: SpectralValues>(_: V.Type) -> Bool { V.self is any LinearValued.Type }
        func isReal<V: SpectralValues>(_: V.Type) -> Bool { V.self is any RealValued.Type }
        #expect(isLinear(MagnitudeValues.self) && isLinear(PowerValues.self))
        #expect(!isLinear(DecibelValues.self) && !isLinear(ComplexValues.self), "decibels do not add (O-5)")
        #expect(isReal(MagnitudeValues.self) && isReal(PowerValues.self) && isReal(DecibelValues.self) && !isReal(ComplexValues.self))
        #expect(LinearFrequency.axisTag == .linear && MelFrequency.axisTag == .mel && ConstantQFrequency.axisTag == .constantQ)
    }
}

@Suite("Frames (WP-110b)")
struct FrameTests {
    @Test func aViewReadsItsStorageWithoutCopying() throws {
        let storage = try AlignedBuffer<Float>(copying: [1, 2, 3, 4])
        let frame = FrameView(real: UnsafeBufferPointer(storage.buffer), index: 7, time: 0.25)
        #expect(frame.kind == .real && frame.count == 4 && frame.index == 7 && frame.time == 0.25 && frame.channelCount == 1)
        let real = try #require(frame.real)
        #expect(real.values.baseAddress == UnsafePointer(storage.baseAddress), "the same memory, not a copy")
        #expect(real.count == 4 && real.index == 7 && real.time == 0.25)
        // A change to the storage is seen through the view: it borrows.
        storage.baseAddress[2] = 99
        #expect(real.values[2] == 99)
        #expect(frame.complex == nil && frame.samples == nil && frame.scalar == nil && frame.envelope == nil)
    }

    @Test func complexFramesAreSplit() throws {
        let re = try AlignedBuffer<Float>(copying: [1, 2, 3])
        let im = try AlignedBuffer<Float>(copying: [-1, -2, -3])
        let frame = FrameView(real: UnsafeBufferPointer(re.buffer), imaginary: UnsafeBufferPointer(im.buffer), index: 2, time: 1.5)
        let complex = try #require(frame.complex)
        #expect(frame.kind == .complex && complex.count == 3 && complex.index == 2 && complex.time == 1.5)
        #expect(complex.real.baseAddress == UnsafePointer(re.baseAddress) && complex.imaginary.baseAddress == UnsafePointer(im.baseAddress))
        #expect(Array(complex.imaginary) == [-1, -2, -3])
        #expect(frame.real == nil)
        let short = FrameView(real: UnsafeBufferPointer(rebasing: re.buffer[0 ..< 2]), imaginary: UnsafeBufferPointer(im.buffer), index: 0, time: 0)
        #expect(short.count == 2, "the shorter half sets the bin count")
    }

    @Test func sampleFramesWrapABlock() throws {
        let buffer = try AudioBuffer(channels: [[1, 2, 3, 4], [5, 6, 7, 8]])
        let frame = FrameView(samples: buffer.block(frameCount: 3), index: 480, time: 0.01)
        #expect(frame.kind == .samples && frame.count == 3 && frame.channelCount == 2 && frame.index == 480)
        let block = try #require(frame.samples)
        #expect(block.frameCount == 3 && block.channelCount == 2 && block.capacity == 4)
        #expect(block.channel(1) == buffer.channel(1), "the same memory, not a copy")
        #expect(frame.real == nil)
    }

    @Test func scalarFramesCarryAValueAndAConfidence() throws {
        let frame = FrameView(scalar: ScalarFrame(value: 440, confidence: 0.9), index: 3, time: 0.5)
        #expect(frame.kind == .scalar && frame.count == 1)
        #expect(frame.scalar == ScalarFrame(value: 440, confidence: 0.9))
        #expect(frame.real == nil && frame.samples == nil)
        #expect(ScalarFrame(value: 2).confidence == 1)
        #expect(ScalarFrame.none == ScalarFrame(value: 0, confidence: 0), "no value yet: 0 with confidence 0 (§5.2)")
        #expect(ScalarFrame(value: 1, confidence: 0.5) != ScalarFrame(value: 1, confidence: 0.6))
    }

    @Test func envelopeFramesHoldPairs() throws {
        let minima = try AlignedBuffer<Float>(copying: [-1, -0.5])
        let maxima = try AlignedBuffer<Float>(copying: [1, 0.25])
        let frame = FrameView(minima: UnsafeBufferPointer(minima.buffer), maxima: UnsafeBufferPointer(maxima.buffer), index: 0, time: 0)
        let envelope = try #require(frame.envelope)
        #expect(frame.kind == .envelope && envelope.count == 2)
        #expect(Array(envelope.minima) == [-1, -0.5] && Array(envelope.maxima) == [1, 0.25])
        #expect(frame.real == nil && frame.scalar == nil)
    }

    @Test func typedFramesAreConstructible() throws {
        let storage = try AlignedBuffer<Float>(copying: [1, 2])
        let values = UnsafeBufferPointer(storage.buffer)
        #expect(RealFrame(values: values, index: 1, time: 2).count == 2)
        #expect(ComplexFrame(real: values, imaginary: values, index: 1, time: 2).count == 2)
        #expect(EnvelopeFrame(minima: values, maxima: values, index: 1, time: 2).count == 2)
    }

    @Test func formatsNameTheirKind() {
        #expect(FrameFormat.samples(channelCount: 2, maximumFrames: 512).kind == .samples)
        #expect(FrameFormat.real(count: 128).kind == .real)
        #expect(FrameFormat.complex(count: 1_025).kind == .complex)
        #expect(FrameFormat.scalar.kind == .scalar)
        #expect(FrameFormat.envelope(maximumCount: 8).kind == .envelope)
        #expect(FrameFormat.real(count: 4) != .real(count: 5))
    }

    @Test func readingAFrameAllocatesNothing() throws {
        let storage = try AlignedBuffer<Float>(count: 1_025)
        let frame = FrameView(real: UnsafeBufferPointer(storage.buffer), index: 0, time: 0)
        expectNoAllocations {
            var round = 0
            var sum: Float = 0
            while round < 1_000 {
                if let real = frame.real, let base = real.values.baseAddress { sum += base[round] }
                round += 1
            }
            Benchmark.blackHole(sum)
        }
    }
}

@Suite("FeedAxis (WP-111)")
struct FeedAxisTests {
    @Test func linearFrequencyRowsRunFromZeroToNyquist() {
        let axis = FeedAxis.linearFrequency(binCount: 1_025, nyquist: 24_000)
        #expect(axis.rowCount == 1_025 && axis.unit == .hertz && axis.isLinearFrequency)
        #expect(axis.value(ofRow: 0) == 0)
        #expect(axis.value(ofRow: 1_024) == 24_000)
        #expect(axis.value(ofRow: 512) == 12_000)
        expectClose(axis.value(ofRow: 1), 23.4375, .relative(1e-15))
        #expect(axis.value(ofRow: -3) == 0 && axis.value(ofRow: 9_999) == 24_000, "rows outside the axis are clamped")
        #expect(FeedAxis.linearFrequency(binCount: 1, nyquist: 24_000).value(ofRow: 0) == 0)
        #expect(FeedAxis.linearFrequency(binCount: 0, nyquist: 24_000).value(ofRow: 0) == 0)
    }

    @Test func melRowsAreBandCentres() {
        let axis = FeedAxis.mel(centers: [100, 250, 700])
        #expect(axis.rowCount == 3 && axis.unit == .hertz && !axis.isLinearFrequency)
        #expect(axis.value(ofRow: 1) == 250 && axis.value(ofRow: 2) == 700)
    }

    @Test func constantQRowsAreAConstantRatioApart() {
        let axis = FeedAxis.constantQ(minimumFrequency: 32.703, binsPerOctave: 36, binCount: 252)
        #expect(axis.rowCount == 252 && axis.unit == .hertz)
        #expect(axis.value(ofRow: 0) == 32.703)
        expectClose(axis.value(ofRow: 36), 65.406, .relative(1e-14))
        expectClose(axis.value(ofRow: 3) / axis.value(ofRow: 0), pow(2, 1.0 / 12), .relative(1e-14))
    }

    @Test func pitchClassesAreTwelve() {
        #expect(FeedAxis.pitchClasses.rowCount == 12 && FeedAxis.pitchClasses.unit == .pitchClass)
        #expect(FeedAxis.pitchClasses.value(ofRow: 9) == 9)
        #expect(FeedAxis.pitchClassNames.count == 12 && FeedAxis.pitchClassNames[0] == "C" && FeedAxis.pitchClassNames[9] == "A")
    }

    @Test func lagsAndQuefrenciesAreInSeconds() {
        let lags = FeedAxis.lags(count: 2_048, sampleRate: 48_000)
        #expect(lags.rowCount == 2_048 && lags.unit == .seconds)
        #expect(lags.value(ofRow: 480) == 0.01)
        let quefrency = FeedAxis.quefrency(count: 1_024, sampleRate: 44_100)
        #expect(quefrency.unit == .seconds)
        expectClose(quefrency.value(ofRow: 441), 0.01, .relative(1e-15))
        #expect(FeedAxis.lags(count: 4, sampleRate: 0).value(ofRow: 2) == 0, "no rate, no time: never a division by zero")
    }

    @Test func tempoAndIndexRows() {
        let tempo = FeedAxis.tempo(beatsPerMinute: [30, 60, 120, 240])
        #expect(tempo.rowCount == 4 && tempo.unit == .beatsPerMinute && tempo.value(ofRow: 2) == 120)
        let indices = FeedAxis.indices(count: 13)
        #expect(indices.rowCount == 13 && indices.unit == .index && indices.value(ofRow: 12) == 12)
    }

    @Test func equality() {
        #expect(FeedAxis.pitchClasses == .pitchClasses)
        #expect(FeedAxis.mel(centers: [1, 2]) == .mel(centers: [1, 2]))
        #expect(FeedAxis.mel(centers: [1, 2]) != .mel(centers: [1, 3]))
        #expect(FeedAxis.lags(count: 4, sampleRate: 48_000) != .quefrency(count: 4, sampleRate: 48_000))
        #expect(FeedAxis.linearFrequency(binCount: 513, nyquist: 24_000) != .linearFrequency(binCount: 513, nyquist: 22_050))
        let all: [FeedAxis] = [.linearFrequency(binCount: 2, nyquist: 1), .mel(centers: [1]), .constantQ(minimumFrequency: 1, binsPerOctave: 12, binCount: 2),
                               .pitchClasses, .lags(count: 2, sampleRate: 1), .quefrency(count: 2, sampleRate: 1), .tempo(beatsPerMinute: [1]), .indices(count: 2)]
        #expect(Set(all).count == 8)
    }
}

@Suite("AnyStrategy")
struct AnyStrategyTests {
    struct Formula: Hashable, Sendable { let exponent: Int }
    struct Other: Hashable, Sendable { let exponent: Int }

    @Test func boxesCompareByTypeAndValue() {
        #expect(AnyStrategy(Formula(exponent: 2)) == AnyStrategy(Formula(exponent: 2)))
        #expect(AnyStrategy(Formula(exponent: 2)) != AnyStrategy(Formula(exponent: 3)))
        #expect(AnyStrategy(Formula(exponent: 2)) != AnyStrategy(Other(exponent: 2)), "equal fields, another type")
        #expect(Set([AnyStrategy(Formula(exponent: 2)), AnyStrategy(Formula(exponent: 2)), AnyStrategy(Other(exponent: 2))]).count == 2)
        #expect(AnyStrategy(Formula(exponent: 5)).value(as: Formula.self)?.exponent == 5)
        #expect(AnyStrategy(Formula(exponent: 5)).value(as: Other.self) == nil)
        #expect(AnyStrategy(3.5).value(as: Double.self) == 3.5)
    }
}
